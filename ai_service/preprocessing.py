"""
Crop Scanner — Shared Preprocessing Module
===========================================
Single source of truth for inference preprocessing.

The model was trained with plain resize (stretch) + rescale 1/255
(ImageDataGenerator in train_model.py), so inference does exactly the same:
    decode → RGB → resize to 224×224 → /255

Measured on dataset samples: this matches training and scores ~98%, while
the previous letterbox + bilateral + CLAHE pipeline dropped to ~83%.
The Flutter app (tflite_service.dart) uses the same steps.

This module also holds the leaf mask used for leaf detection and the
pixel-based damage estimate. The same HSV thresholds are mirrored in
flutter_app/lib/services/damage_estimator.dart — keep them in sync.
"""

import cv2
import numpy as np


# ─────────────────────────────────────────────
# CONSTANTS — must match training exactly
# ─────────────────────────────────────────────
IMG_SIZE = (224, 224)       # Must match train_model.py IMG_SIZE
NORM_SCALE = 1.0 / 255.0   # Must match train_model.py rescale

# HSV thresholds (OpenCV scale: H 0–180, S/V 0–255).
# Mirrored in flutter_app/lib/services/damage_estimator.dart.
LEAF_MIN_SAT     = 40    # below → grey/white background
LEAF_MIN_VAL     = 40    # below → black background / deep shadow
LEAF_HUE_RANGE   = (5, 90)    # red-brown … yellow … green = plant tissue
HEALTHY_HUE_RANGE = (35, 85)  # green = healthy tissue
DAMAGE_WORK_SIZE = (224, 224)
MIN_LEAF_FRACTION = 0.04      # below → "no leaf in image"


# ─────────────────────────────────────────────
# LEAF MASK / DAMAGE ESTIMATE
# ─────────────────────────────────────────────
def _leaf_masks(img_bgr: np.ndarray):
    """Returns (leaf_mask, healthy_mask) as boolean arrays at DAMAGE_WORK_SIZE."""
    small = cv2.resize(img_bgr, DAMAGE_WORK_SIZE, interpolation=cv2.INTER_AREA)
    h, s, v = cv2.split(cv2.cvtColor(small, cv2.COLOR_BGR2HSV))
    leaf = (
        (s >= LEAF_MIN_SAT) & (v >= LEAF_MIN_VAL)
        & (h >= LEAF_HUE_RANGE[0]) & (h <= LEAF_HUE_RANGE[1])
    )
    healthy = leaf & (h >= HEALTHY_HUE_RANGE[0]) & (h <= HEALTHY_HUE_RANGE[1])
    return leaf, healthy


def leaf_fraction(img_bgr: np.ndarray) -> float:
    """Fraction of the image covered by plant tissue (0–1)."""
    leaf, _ = _leaf_masks(img_bgr)
    return float(leaf.mean())


def is_leaf_present(img_bgr: np.ndarray, threshold: float = MIN_LEAF_FRACTION) -> bool:
    """True if enough of the image looks like plant tissue."""
    if img_bgr is None:
        return False
    return leaf_fraction(img_bgr) >= threshold


def estimate_damage_percent(img_bgr: np.ndarray) -> float:
    """
    Pixel-based damage estimate: share of leaf tissue that is not green
    (yellow, brown, rust-coloured lesions).

        damage% = (leaf pixels − green pixels) / leaf pixels × 100

    This measures what the farmer sees on the leaf, independent of how
    confident the classifier is.
    """
    leaf, healthy = _leaf_masks(img_bgr)
    leaf_px = int(leaf.sum())
    if leaf_px == 0:
        return 0.0
    return round(float(1.0 - healthy.sum() / leaf_px) * 100.0, 2)


# ─────────────────────────────────────────────
# CONTRAST HELPER (used by evalute_model.py)
# ─────────────────────────────────────────────
def apply_clahe(img_rgb: np.ndarray) -> np.ndarray:
    """CLAHE on the L channel of LAB color space."""
    lab = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2LAB)
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    lab[:, :, 0] = clahe.apply(lab[:, :, 0])
    return cv2.cvtColor(lab, cv2.COLOR_LAB2RGB)


# ─────────────────────────────────────────────
# DECODING
# ─────────────────────────────────────────────
def load_bgr(img_input) -> np.ndarray:
    """
    Decodes a file path, raw bytes, or numpy array to a BGR uint8 image.
    """
    if isinstance(img_input, str):
        img_bgr = cv2.imread(img_input)
        if img_bgr is None:
            raise ValueError(f"Could not read image from path: {img_input}")
        return img_bgr
    if isinstance(img_input, bytes):
        img_bgr = cv2.imdecode(np.frombuffer(img_input, np.uint8), cv2.IMREAD_COLOR)
        if img_bgr is None:
            raise ValueError("Could not decode image bytes")
        return img_bgr
    if isinstance(img_input, np.ndarray):
        if img_input.ndim == 2:
            return cv2.cvtColor(img_input, cv2.COLOR_GRAY2BGR)
        if img_input.shape[2] == 4:
            return cv2.cvtColor(img_input, cv2.COLOR_BGRA2BGR)
        return img_input
    raise TypeError(f"Unsupported input type: {type(img_input)}")


# ─────────────────────────────────────────────
# MAIN PREPROCESSING PIPELINE
# ─────────────────────────────────────────────
def preprocess_for_inference(img_input, target_size: tuple = IMG_SIZE) -> np.ndarray:
    """
    Same steps as training: RGB → resize (stretch) → /255 → batch dim.

    Args:
        img_input: file path, raw bytes, or BGR numpy array

    Returns:
        float32 numpy array of shape (1, H, W, 3), values in [0, 1]
    """
    img_rgb = cv2.cvtColor(load_bgr(img_input), cv2.COLOR_BGR2RGB)
    img_rgb = cv2.resize(img_rgb, target_size, interpolation=cv2.INTER_LINEAR)
    img_float = img_rgb.astype(np.float32) * NORM_SCALE
    return np.expand_dims(img_float, axis=0)


# ─────────────────────────────────────────────
# MULTI-FRAME AGGREGATION
# ─────────────────────────────────────────────
def aggregate_predictions(predictions_list: list) -> np.ndarray:
    """Averages softmax outputs from multiple frames/augmentations."""
    if not predictions_list:
        raise ValueError("predictions_list is empty")
    return np.mean(np.stack(predictions_list, axis=0), axis=0)


def generate_tta_variants(img_input, n_variants: int = 5) -> list:
    """
    Test-Time Augmentation (TTA): original, horizontal flip, ±10° rotation,
    slight brightness boost. Mild changes that the training augmentation
    (train_model.py) already covers.

    Returns:
        List of preprocessed arrays, each shape (1, H, W, 3)
    """
    base = preprocess_for_inference(img_input)[0]  # (H, W, 3) in [0, 1]
    h, w = base.shape[:2]

    variants = [base]
    if n_variants >= 2:
        variants.append(cv2.flip(base, 1))
    if n_variants >= 3:
        M = cv2.getRotationMatrix2D((w // 2, h // 2), 10, 1.0)
        variants.append(cv2.warpAffine(base, M, (w, h), borderMode=cv2.BORDER_REFLECT))
    if n_variants >= 4:
        M = cv2.getRotationMatrix2D((w // 2, h // 2), -10, 1.0)
        variants.append(cv2.warpAffine(base, M, (w, h), borderMode=cv2.BORDER_REFLECT))
    if n_variants >= 5:
        variants.append(np.clip(base * 1.15, 0, 1))

    return [np.expand_dims(v, axis=0) for v in variants[:n_variants]]
