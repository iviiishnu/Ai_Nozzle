"""
Crop Scanner — Inference Engine
================================
Handles all prediction logic: confidence thresholding,
damage estimation, and multi-frame (TTA) prediction.

Separated from farm_app.py so it can be tested independently
and reused by TFLite inference if needed.
"""

import os
import json
import numpy as np
from scipy.stats import entropy as scipy_entropy

from preprocessing import (
    preprocess_for_inference,
    generate_tta_variants,
    aggregate_predictions,
    is_leaf_present,
    IMG_SIZE,
)

# ─────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────
BASE_DIR        = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR       = os.path.join(BASE_DIR, "models")
CLASS_JSON_PATH = os.path.join(MODEL_DIR, "class_names.json")

# Confidence thresholds
CONFIDENCE_THRESHOLD = 0.50   # Below this → return "Uncertain"
HIGH_CONFIDENCE      = 0.80   # Above this → high trust result

# Damage severity bands (used for spray decision)
DAMAGE_LOW    = 30   # < 30%  → no spray
DAMAGE_MEDIUM = 60   # 30–60% → short spray
# > 60% → long spray


# ─────────────────────────────────────────────
# MODEL LOADER
# ─────────────────────────────────────────────
def _patch_h5_batch_shape(model_path: str):
    """
    Patches the h5 model_config so InputLayer uses 'input_shape' instead of
    'batch_shape' or 'shape'.  Keras 2.15 InputLayer takes 'input_shape'
    (without the leading batch dimension), but models saved with some earlier
    builds stored 'batch_shape': [null, H, W, C].

    The patch:
      - Replaces the key name  "batch_shape" → "input_shape"
      - Strips the leading null (batch) dimension from the value
    """
    import h5py, json

    with h5py.File(model_path, "r") as f:
        cfg_raw = f.attrs.get("model_config")
    if not cfg_raw:
        return

    cfg_str = cfg_raw if isinstance(cfg_raw, str) else cfg_raw.decode("utf-8")
    if '"batch_shape"' not in cfg_str and '"shape"' not in cfg_str:
        return  # Already compatible

    try:
        cfg = json.loads(cfg_str)
    except json.JSONDecodeError:
        return

    def _fix_layer(layer_cfg: dict):
        """Recursively fix InputLayer configs in the model JSON."""
        if not isinstance(layer_cfg, dict):
            return
        # Fix this layer's config if it's an InputLayer
        if layer_cfg.get("class_name") == "InputLayer":
            c = layer_cfg.get("config", {})
            for bad_key in ("batch_shape", "shape"):
                if bad_key in c:
                    val = c.pop(bad_key)
                    # val is [None, H, W, C] — drop the leading None (batch dim)
                    if isinstance(val, list) and len(val) > 1 and val[0] is None:
                        val = val[1:]
                    c["input_shape"] = val
        # Recurse into sub-dicts/lists
        for v in layer_cfg.values():
            if isinstance(v, dict):
                _fix_layer(v)
            elif isinstance(v, list):
                for item in v:
                    if isinstance(item, dict):
                        _fix_layer(item)

    _fix_layer(cfg)
    patched = json.dumps(cfg)

    with h5py.File(model_path, "r+") as f:
        f.attrs["model_config"] = patched
    print("Patched model_config: batch_shape -> input_shape (batch dim stripped)")


def load_keras_model(model_path: str = None):
    """
    Loads the Keras .h5 model with graceful error handling
    and a warm-up inference to compile the TF graph.

    Returns:
        Loaded Keras model, or raises RuntimeError on failure.
    """
    import keras  # Use standalone Keras 3.x — models were saved with Keras 3.x

    if model_path is None:
        model_path = os.path.join(MODEL_DIR, "crop_model_best.h5")
        # Fallback to old name if new one doesn't exist
        if not os.path.exists(model_path):
            model_path = os.path.join(MODEL_DIR, "new_model.h5")

    if not os.path.exists(model_path):
        raise RuntimeError(
            f"Model file not found: {model_path}\n"
            f"Run train_model.py first to generate the model."
        )

    try:
        # Use keras.saving.load_model which is Keras-3-native and handles
        # the DTypePolicy / batch_shape formats used by the saved models.
        model = keras.saving.load_model(model_path, compile=False)
        print(f"Model loaded: {model_path}")
        print(f"Input shape: {model.input_shape}")

        # Warm-up: compiles the compute graph so first real request is fast
        dummy = np.zeros((1, *model.input_shape[1:]), dtype=np.float32)
        model.predict(dummy, verbose=0)
        print("Model warm-up complete.")
        return model

    except Exception as e:
        raise RuntimeError(f"Failed to load model from {model_path}: {e}")


def load_class_names() -> list:
    """
    Loads class names from class_names.json.
    Falls back to hardcoded list if JSON not found.
    """
    if os.path.exists(CLASS_JSON_PATH):
        with open(CLASS_JSON_PATH, "r") as f:
            names = json.load(f)
        print(f"Loaded {len(names)} class names from {CLASS_JSON_PATH}")
        return names

    # Fallback — hardcoded 7 classes
    print("WARNING: class_names.json not found, using hardcoded fallback.")
    return [
        "Anthracnose", "Bacterial_Leaf_Spot", "Black_rot",
        "Downy_Mildew", "Mosaic_Disease", "Powdery_Mildew", "Rust"
    ]


# ─────────────────────────────────────────────
# DAMAGE PERCENTAGE CALCULATION
# ─────────────────────────────────────────────
def calculate_damage_percent(preds: np.ndarray, pred_label: str, confidence: float) -> float:
    """
    Calculates a meaningful damage percentage.

    Strategy:
        - If model is uncertain (high entropy) → higher damage estimate
        - If model is confident in a disease → scale damage by confidence
        - Entropy captures "how spread out" the probabilities are,
          which correlates with how ambiguous/severe the disease pattern is

    Formula:
        entropy_ratio = H(preds) / H_max
        damage = entropy_ratio * 100 * confidence_weight

    This gives:
        - High confidence, clear disease → moderate-high damage (model is sure)
        - Low confidence, spread probs   → high damage (ambiguous = likely severe)
        - High confidence, healthy       → 0% damage

    Args:
        preds: softmax probability array (num_classes,)
        pred_label: predicted class name
        confidence: confidence of top prediction (0–1)

    Returns:
        damage_percent: float in [0, 100]
    """
    num_classes = len(preds)

    # Entropy of prediction distribution
    ent = scipy_entropy(preds)
    max_entropy = np.log(num_classes)  # maximum possible entropy
    entropy_ratio = float(ent / max_entropy) if max_entropy > 0 else 0.0

    # Confidence weight: high confidence = model is sure about the disease
    # We scale entropy by confidence so that:
    #   - Confident disease prediction → damage reflects severity
    #   - Uncertain prediction → damage is higher (caution)
    confidence_weight = 0.5 + (1.0 - confidence) * 0.5  # range [0.5, 1.0]

    damage = entropy_ratio * 100 * confidence_weight

    # Cap at 95% — we never claim 100% damage from a single image
    return round(min(damage, 95.0), 2)


def get_severity_label(damage_percent: float) -> str:
    """Maps damage percentage to a human-readable severity label."""
    if damage_percent < DAMAGE_LOW:
        return "Low"
    elif damage_percent < DAMAGE_MEDIUM:
        return "Medium"
    else:
        return "High"


# ─────────────────────────────────────────────
# CORE PREDICTION FUNCTION
# ─────────────────────────────────────────────
def predict_single(model, img_input, class_names: list) -> dict:
    """
    Single-image prediction with confidence thresholding.

    Args:
        model: Loaded Keras model
        img_input: File path, bytes, or numpy array
        class_names: List of class label strings

    Returns:
        dict with prediction results
    """
    preprocessed = preprocess_for_inference(img_input, target_size=IMG_SIZE)
    preds = model.predict(preprocessed, verbose=0)[0]

    idx        = int(np.argmax(preds))
    pred_label = class_names[idx]
    confidence = float(preds[idx])

    return _build_result(preds, pred_label, confidence, class_names, n_frames=1)


def predict_with_tta(model, img_input, class_names: list, n_variants: int = 5) -> dict:
    """
    Test-Time Augmentation prediction.
    Generates n_variants slightly different versions of the image,
    runs inference on each, and averages the softmax outputs.

    This is the recommended prediction method for real-world use.
    It reduces noise from single-frame predictions significantly.

    Args:
        model: Loaded Keras model
        img_input: File path, bytes, or numpy array
        class_names: List of class label strings
        n_variants: Number of TTA variants (3–5 recommended)

    Returns:
        dict with averaged prediction results
    """
    variants = generate_tta_variants(img_input, n_variants=n_variants)

    all_preds = []
    for variant in variants:
        p = model.predict(variant, verbose=0)[0]
        all_preds.append(p)

    # Average across all variants
    avg_preds  = aggregate_predictions(all_preds)
    idx        = int(np.argmax(avg_preds))
    pred_label = class_names[idx]
    confidence = float(avg_preds[idx])

    return _build_result(avg_preds, pred_label, confidence, class_names, n_frames=len(variants))


def _build_result(preds: np.ndarray, pred_label: str, confidence: float,
                  class_names: list, n_frames: int) -> dict:
    """
    Builds the standardized result dictionary.
    Applies confidence thresholding and damage calculation.
    """
    # ── Confidence threshold check ───────────────────────────────
    if confidence < CONFIDENCE_THRESHOLD:
        return {
            "crop": "Unknown",
            "status": "Uncertain",
            "disease": "Uncertain",
            "confidence_percent": round(confidence * 100, 2),
            "damage_percent": 0.0,
            "severity": "Unknown",
            "message": (
                f"Model confidence too low ({confidence*100:.1f}%). "
                "Please retake the photo with better lighting and a clear leaf."
            ),
            "all_class_probs": {
                label: round(float(prob) * 100, 2)
                for label, prob in zip(class_names, preds)
            },
            "frames_averaged": n_frames,
        }

    # ── Determine status ─────────────────────────────────────────
    # None of the 7 classes is "healthy" — all are diseases.
    # Status is always "Diseased" if confidence >= threshold.
    # If you add a "Healthy" class later, check pred_label here.
    status = "Diseased"
    damage_percent = calculate_damage_percent(preds, pred_label, confidence)
    severity = get_severity_label(damage_percent)

    return {
        "crop": pred_label,
        "status": status,
        "disease": pred_label,
        "confidence_percent": round(confidence * 100, 2),
        "damage_percent": damage_percent,
        "severity": severity,
        "spray_recommended": damage_percent >= DAMAGE_LOW,
        "all_class_probs": {
            label: round(float(prob) * 100, 2)
            for label, prob in zip(class_names, preds)
        },
        "frames_averaged": n_frames,
    }
