"""
Crop Scanner — Inference Engine
================================
Handles all prediction logic: model loading, confidence thresholding,
damage estimation, and multi-frame (TTA) prediction.

Separated from farm_app.py so it can be tested independently.

All tunables can be overridden with environment variables (see .env.example).
"""

import os
import json
import threading

import numpy as np

from preprocessing import (
    preprocess_for_inference,
    generate_tta_variants,
    aggregate_predictions,
    estimate_damage_percent,
    load_bgr,
)

# ─────────────────────────────────────────────
# CONFIG (env-overridable)
# ─────────────────────────────────────────────
BASE_DIR        = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR       = os.getenv("MODEL_DIR", os.path.join(BASE_DIR, "models"))
MODEL_PATH      = os.getenv("MODEL_PATH")  # optional explicit model file
CLASS_JSON_PATH = os.getenv("CLASS_NAMES_PATH", os.path.join(MODEL_DIR, "class_names.json"))

# Below this confidence → "Uncertain" (no spray)
CONFIDENCE_THRESHOLD = float(os.getenv("CONFIDENCE_THRESHOLD", "0.50"))

# Damage severity bands (percent of leaf tissue that is not green).
# Mirrored in flutter_app/lib/config.dart and the ESP32 firmware.
DAMAGE_MEDIUM = float(os.getenv("DAMAGE_MEDIUM", "15"))  # ≥ → Medium, spray
DAMAGE_HIGH   = float(os.getenv("DAMAGE_HIGH", "35"))    # ≥ → High

# Model file search order when MODEL_PATH is not set
_MODEL_CANDIDATES = ("crop_model_best.h5", "new_model.h5", "crop_model_float16.tflite")


# ─────────────────────────────────────────────
# MODEL LOADER
# ─────────────────────────────────────────────
class TFLiteModel:
    """
    Minimal wrapper giving a TFLite interpreter the same `input_shape` /
    `predict(x, verbose=0)` interface as a Keras model, so the rest of the
    inference code works unchanged when no .h5 model is available.
    """

    def __init__(self, model_path: str):
        import tensorflow as tf

        self._interpreter = tf.lite.Interpreter(model_path=model_path)
        self._interpreter.allocate_tensors()
        self._input = self._interpreter.get_input_details()[0]
        self._output = self._interpreter.get_output_details()[0]
        self.input_shape = (None, *self._input["shape"][1:])
        # Interpreter is not thread-safe; the server handles requests on threads.
        self._lock = threading.Lock()

    def predict(self, x, verbose=0):
        outputs = []
        with self._lock:
            for sample in np.asarray(x, dtype=np.float32):
                self._interpreter.set_tensor(self._input["index"], sample[None])
                self._interpreter.invoke()
                outputs.append(self._interpreter.get_tensor(self._output["index"])[0])
        return np.stack(outputs)


def _resolve_model_path() -> str:
    if MODEL_PATH:
        return MODEL_PATH
    for name in _MODEL_CANDIDATES:
        path = os.path.join(MODEL_DIR, name)
        if os.path.exists(path):
            return path
    raise RuntimeError(
        f"No model found in {MODEL_DIR} (looked for {', '.join(_MODEL_CANDIDATES)}). "
        "Run train_model.py or set MODEL_PATH."
    )


def load_keras_model(model_path: str = None):
    """
    Loads a Keras .h5 or TFLite model and runs a warm-up inference.

    Returns:
        Model with `input_shape` and `predict(x, verbose=0)`.
    """
    model_path = model_path or _resolve_model_path()
    if not os.path.exists(model_path):
        raise RuntimeError(f"Model file not found: {model_path}")

    try:
        if model_path.endswith(".tflite"):
            model = TFLiteModel(model_path)
        else:
            import keras
            model = keras.saving.load_model(model_path, compile=False)
        print(f"Model loaded: {model_path}")
        print(f"Input shape: {model.input_shape}")

        # Warm-up so the first real request is fast
        dummy = np.zeros((1, *model.input_shape[1:]), dtype=np.float32)
        model.predict(dummy, verbose=0)
        return model

    except Exception as e:
        raise RuntimeError(f"Failed to load model from {model_path}: {e}")


def load_class_names() -> list:
    """Loads class names from class_names.json."""
    if not os.path.exists(CLASS_JSON_PATH):
        raise RuntimeError(f"Class names file not found: {CLASS_JSON_PATH}")
    with open(CLASS_JSON_PATH, "r") as f:
        names = json.load(f)
    print(f"Loaded {len(names)} class names from {CLASS_JSON_PATH}")
    return names


# ─────────────────────────────────────────────
# SEVERITY
# ─────────────────────────────────────────────
def get_severity_label(damage_percent: float) -> str:
    """Maps damage percentage to a human-readable severity label."""
    if damage_percent < DAMAGE_MEDIUM:
        return "Low"
    if damage_percent < DAMAGE_HIGH:
        return "Medium"
    return "High"


# ─────────────────────────────────────────────
# CORE PREDICTION FUNCTIONS
# ─────────────────────────────────────────────
def predict_single(model, img_input, class_names: list) -> dict:
    """Single-image prediction with confidence thresholding."""
    img_bgr = load_bgr(img_input)
    preds = model.predict(preprocess_for_inference(img_bgr), verbose=0)[0]
    return _build_result(preds, class_names, img_bgr, n_frames=1)


def predict_with_tta(model, img_input, class_names: list, n_variants: int = 5) -> dict:
    """
    Test-Time Augmentation prediction: averages softmax outputs over
    n_variants mildly augmented copies of the image.
    """
    img_bgr = load_bgr(img_input)
    variants = generate_tta_variants(img_bgr, n_variants=n_variants)
    avg_preds = aggregate_predictions([model.predict(v, verbose=0)[0] for v in variants])
    return _build_result(avg_preds, class_names, img_bgr, n_frames=len(variants))


def _build_result(preds: np.ndarray, class_names: list, img_bgr: np.ndarray,
                  n_frames: int) -> dict:
    """Builds the standardized result dictionary."""
    idx = int(np.argmax(preds))
    confidence = float(preds[idx])
    all_probs = {
        label: round(float(prob) * 100, 2)
        for label, prob in zip(class_names, preds)
    }

    if confidence < CONFIDENCE_THRESHOLD:
        return {
            "crop": "Unknown",
            "status": "Uncertain",
            "disease": "Uncertain",
            "confidence_percent": round(confidence * 100, 2),
            "damage_percent": 0.0,
            "severity": "Unknown",
            "spray_recommended": False,
            "message": (
                f"Model confidence too low ({confidence*100:.1f}%). "
                "Please retake the photo with better lighting and a clear leaf."
            ),
            "all_class_probs": all_probs,
            "frames_averaged": n_frames,
        }

    # None of the 7 classes is "healthy" — all are diseases.
    # If a "Healthy" class is added later, check class_names[idx] here.
    damage_percent = estimate_damage_percent(img_bgr)

    return {
        "crop": class_names[idx],
        "status": "Diseased",
        "disease": class_names[idx],
        "confidence_percent": round(confidence * 100, 2),
        "damage_percent": damage_percent,
        "severity": get_severity_label(damage_percent),
        "spray_recommended": damage_percent >= DAMAGE_MEDIUM,
        "all_class_probs": all_probs,
        "frames_averaged": n_frames,
    }
