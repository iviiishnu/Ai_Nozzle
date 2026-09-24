"""
Crop Scanner — Shared Preprocessing Module
===========================================
Single source of truth for inference preprocessing.

Training uses plain rescale=1/255 (no custom preprocessing_function).
Inference uses: resize → bilateral filter → CLAHE → normalize.

The gap between training and inference preprocessing is intentional and small:
  - Bilateral filter + CLAHE are applied at inference to handle real-world
    phone photos with variable lighting.
  - They are NOT applied during training because they change the image
    distribution in ways that destabilize transfer learning from ImageNet weights.
  - TTA (test-time augmentation) in inference.py further compensates for
    the train/inference domain gap.
"""

import cv2
import numpy as np


# ─────────────────────────────────────────────
# CONSTANTS — must match training exactly
# ─────────────────────────────────────────────
IMG_SIZE = (224, 224)       # Must match train_model.py IMG_SIZE
NORM_SCALE = 1.0 / 255.0   # Must match train_model.py rescale


# ─────────────────────────────────────────────
# LEAF DETECTION
# ─────────────────────────────────────────────
def is_leaf_present(img_bgr: np.ndarray, threshold: float = 0.04) -> bool:
    """
    Checks whether the image contains a leaf using HSV green-range masking.

    Improvements over original:
      - Also checks for yellow/brown tones (diseased leaves lose green)
      - Slightly higher default threshold (0.04 vs 0.02) to reduce false positives
        from green backgrounds

    Args:
        img_bgr: OpenCV BGR image array
        threshold: Minimum fraction of leaf-colored pixels required

    Returns:
        True if a leaf is likely present
    """
    if img_bgr is None:
        return False

    hsv = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2HSV)

    # Green range (healthy leaves)
    green_mask = cv2.inRange(hsv, np.array([25, 40, 40]), np.array([90, 255, 255]))

    # Yellow-brown range (diseased/dry leaves — still valid leaf images)
    yellow_mask = cv2.inRange(hsv, np.array([10, 30, 40]), np.array([30, 255, 255]))

    combined_mask = cv2.bitwise_or(green_mask, yellow_mask)
    leaf_ratio = np.sum(combined_mask > 0) / (img_bgr.shape[0] * img_bgr.shape[1])

    return leaf_ratio > threshold


# ─────────────────────────────────────────────
# CORE PREPROCESSING STEPS
# ─────────────────────────────────────────────
def apply_clahe(img_rgb: np.ndarray) -> np.ndarray:
    """
    CLAHE on the L channel of LAB color space.
    Normalizes local contrast without affecting color.

    Why: Phone cameras produce very different exposures depending on
    lighting. CLAHE makes the model see consistent contrast regardless
    of whether the photo was taken in bright sunlight or shade.

    Args:
        img_rgb: uint8 RGB array

    Returns:
        uint8 RGB array with normalized contrast
    """
    lab = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2LAB)
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    lab[:, :, 0] = clahe.apply(lab[:, :, 0])
    return cv2.cvtColor(lab, cv2.COLOR_LAB2RGB)


def remove_noise(img_rgb: np.ndarray) -> np.ndarray:
    """
    Bilateral filter — removes noise while preserving edges.
    Better than Gaussian blur for leaf images because it keeps
    the sharp boundaries between healthy and diseased tissue.

    Args:
        img_rgb: uint8 RGB array

    Returns:
        uint8 RGB array with noise reduced
    """
    # d=5: small neighborhood (fast), sigmaColor/sigmaSpace=75: moderate smoothing
    return cv2.bilateralFilter(img_rgb, d=5, sigmaColor=75, sigmaSpace=75)


def resize_and_pad(img_rgb: np.ndarray, target_size: tuple = IMG_SIZE) -> np.ndarray:
    """
    Resize with aspect-ratio-preserving padding (letterbox).

    Why not just cv2.resize?
    Direct resize distorts the aspect ratio. A square leaf becomes
    a rectangle, changing the shape features the model learned.
    Letterboxing preserves shape while fitting the target size.

    Args:
        img_rgb: uint8 RGB array (any size)
        target_size: (width, height) tuple

    Returns:
        uint8 RGB array of exactly target_size
    """
    target_w, target_h = target_size
    h, w = img_rgb.shape[:2]

    scale = min(target_w / w, target_h / h)
    new_w = int(w * scale)
    new_h = int(h * scale)

    resized = cv2.resize(img_rgb, (new_w, new_h), interpolation=cv2.INTER_AREA)

    # Pad to target size with black (neutral background)
    canvas = np.zeros((target_h, target_w, 3), dtype=np.uint8)
    pad_top  = (target_h - new_h) // 2
    pad_left = (target_w - new_w) // 2
    canvas[pad_top:pad_top + new_h, pad_left:pad_left + new_w] = resized

    return canvas


# ─────────────────────────────────────────────
# MAIN PREPROCESSING PIPELINE
# ─────────────────────────────────────────────
def preprocess_for_inference(img_input, target_size: tuple = IMG_SIZE) -> np.ndarray:
    """
    Full preprocessing pipeline for inference.
    Accepts multiple input types for flexibility.

    Pipeline:
        1. Decode to RGB uint8
        2. Resize with letterbox padding
        3. Noise reduction (bilateral filter)
        4. Contrast normalization (CLAHE)
        5. Normalize to [0, 1]
        6. Add batch dimension

    Args:
        img_input: One of:
            - str/Path: file path
            - bytes: raw image bytes (from Flask request)
            - np.ndarray: BGR (OpenCV) or RGB array

    Returns:
        float32 numpy array of shape (1, H, W, 3), values in [0, 1]
    """
    # ── Step 1: Decode to RGB uint8 ──────────────────────────────
    if isinstance(img_input, (str, bytes)) and not isinstance(img_input, np.ndarray):
        if isinstance(img_input, str):
            img_bgr = cv2.imread(img_input)
            if img_bgr is None:
                raise ValueError(f"Could not read image from path: {img_input}")
            img_rgb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
        else:
            # bytes from Flask request.files
            nparr = np.frombuffer(img_input, np.uint8)
            img_bgr = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
            if img_bgr is None:
                raise ValueError("Could not decode image bytes")
            img_rgb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
    elif isinstance(img_input, np.ndarray):
        if img_input.ndim == 2:
            # Grayscale — convert to RGB
            img_rgb = cv2.cvtColor(img_input, cv2.COLOR_GRAY2RGB)
        elif img_input.shape[2] == 4:
            # RGBA — drop alpha
            img_rgb = cv2.cvtColor(img_input, cv2.COLOR_BGRA2RGB)
        else:
            # Assume BGR (OpenCV default)
            img_rgb = cv2.cvtColor(img_input, cv2.COLOR_BGR2RGB)
    else:
        raise TypeError(f"Unsupported input type: {type(img_input)}")

    # ── Step 2: Resize with letterbox ────────────────────────────
    img_rgb = resize_and_pad(img_rgb, target_size)

    # ── Step 3: Noise reduction ───────────────────────────────────
    img_rgb = remove_noise(img_rgb)

    # ── Step 4: Contrast normalization ───────────────────────────
    img_rgb = apply_clahe(img_rgb)

    # ── Step 5: Normalize to [0, 1] ──────────────────────────────
    img_float = img_rgb.astype(np.float32) * NORM_SCALE

    # ── Step 6: Add batch dimension ──────────────────────────────
    return np.expand_dims(img_float, axis=0)


# ─────────────────────────────────────────────
# MULTI-FRAME AGGREGATION
# ─────────────────────────────────────────────
def aggregate_predictions(predictions_list: list) -> np.ndarray:
    """
    Averages predictions from multiple frames/augmentations.

    Why: A single image prediction is noisy. Averaging 3–5 predictions
    of the same leaf (slightly different crops/angles) gives a much
    more stable result — especially for borderline cases.

    Args:
        predictions_list: List of 1D numpy arrays (softmax outputs),
                          each of shape (num_classes,)

    Returns:
        Averaged probability array of shape (num_classes,)
    """
    if not predictions_list:
        raise ValueError("predictions_list is empty")
    return np.mean(np.stack(predictions_list, axis=0), axis=0)


def generate_tta_variants(img_input, n_variants: int = 5) -> list:
    """
    Test-Time Augmentation (TTA).
    Generates slightly different versions of the same image
    to average predictions over, improving stability.

    Augmentations applied:
        - Original (no change)
        - Horizontal flip
        - Small rotation (+10°)
        - Small rotation (-10°)
        - Slight brightness boost

    Args:
        img_input: Same types accepted as preprocess_for_inference
        n_variants: How many variants to generate (max 5)

    Returns:
        List of preprocessed arrays, each shape (1, H, W, 3)
    """
    # Get the base preprocessed image (float32, [0,1], no batch dim)
    base = preprocess_for_inference(img_input)[0]  # shape (H, W, 3)
    base_uint8 = (base * 255).astype(np.uint8)

    variants = [base]  # original always included

    if n_variants >= 2:
        # Horizontal flip
        flipped = cv2.flip(base_uint8, 1).astype(np.float32) / 255.0
        variants.append(flipped)

    if n_variants >= 3:
        # Rotate +10 degrees
        h, w = base_uint8.shape[:2]
        M = cv2.getRotationMatrix2D((w // 2, h // 2), 10, 1.0)
        rotated_pos = cv2.warpAffine(base_uint8, M, (w, h),
                                     borderMode=cv2.BORDER_REFLECT).astype(np.float32) / 255.0
        variants.append(rotated_pos)

    if n_variants >= 4:
        # Rotate -10 degrees
        M = cv2.getRotationMatrix2D((w // 2, h // 2), -10, 1.0)
        rotated_neg = cv2.warpAffine(base_uint8, M, (w, h),
                                     borderMode=cv2.BORDER_REFLECT).astype(np.float32) / 255.0
        variants.append(rotated_neg)

    if n_variants >= 5:
        # Slight brightness boost (+15%)
        brightened = np.clip(base * 1.15, 0, 1)
        variants.append(brightened)

    # Add batch dimension to each
    return [np.expand_dims(v, axis=0) for v in variants[:n_variants]]
