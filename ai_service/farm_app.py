# """
# Crop Scanner — Flask API Server (Upgraded)
# ==========================================
# Improvements over original:
#   - Relative paths (no hardcoded D:\)
#   - Graceful model loading with warm-up
#   - UUID filenames + file cleanup after prediction
#   - File type validation
#   - Leaf detection uses improved HSV (green + yellow-brown)
#   - TTA-based prediction (5 variants averaged)
#   - Confidence threshold → returns "Uncertain" instead of wrong prediction
#   - Fixed damage_percent formula (entropy-based)
#   - /health endpoint for Spring Boot to check liveness
#   - debug=False (set FLASK_DEBUG=true in env for dev)
#   - Request size limit (10MB)
# """

import os
import sys
import uuid
import logging

import cv2
import numpy as np
from flask import Flask, request, jsonify, Response

# ─────────────────────────────────────────────
# PATHS
# ─────────────────────────────────────────────
BASE_DIR    = os.path.dirname(os.path.abspath(__file__))
UPLOAD_DIR  = os.path.join(BASE_DIR, "uploads")
os.makedirs(UPLOAD_DIR, exist_ok=True)

# ─────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

# ─────────────────────────────────────────────
# FLASK APP
# ─────────────────────────────────────────────
app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 10 * 1024 * 1024  # 10 MB upload limit

# ─────────────────────────────────────────────
# LOAD MODEL + CLASS NAMES AT STARTUP
# ─────────────────────────────────────────────
try:
    from inference import load_keras_model, load_class_names, predict_with_tta
    from preprocessing import is_leaf_present

    model       = load_keras_model()
    CLASS_NAMES = load_class_names()
    logger.info(f"Ready. Classes: {CLASS_NAMES}")

except Exception as e:
    logger.critical(f"Startup failed: {e}")
    sys.exit(1)

# ─────────────────────────────────────────────
# ALLOWED FILE TYPES
# ─────────────────────────────────────────────
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}


def _validate_and_save(file) -> str:
    """
    Validates file type and saves with a UUID filename.
    Returns the saved file path.
    Raises ValueError on invalid file type.
    """
    original_ext = os.path.splitext(file.filename)[1].lower()
    if original_ext not in ALLOWED_EXTENSIONS:
        raise ValueError(f"Unsupported file type '{original_ext}'. Use JPG, PNG, or WebP.")

    safe_name = f"{uuid.uuid4().hex}{original_ext}"
    file_path = os.path.join(UPLOAD_DIR, safe_name)
    file.save(file_path)
    return file_path


# ─────────────────────────────────────────────
# ROUTES
# ─────────────────────────────────────────────
@app.route("/")
def index():
    return jsonify({
        "service": "Crop Scanner ML API",
        "endpoints": {
            "GET  /health":              "Liveness check",
            "POST /api/crop/analyze":    "Analyze crop image",
            "GET  /capture":             "Capture webcam frame",
        }
    })


@app.route("/health")
def health():
    """
    Liveness endpoint for Spring Boot to call before forwarding requests.
    Returns 200 if model is loaded and ready.
    """
    return jsonify({
        "status": "ok",
        "model_loaded": model is not None,
        "classes": CLASS_NAMES,
        "num_classes": len(CLASS_NAMES),
    }), 200


@app.route("/capture")
def capture():
    """Captures a single frame from the webcam."""
    cap = cv2.VideoCapture(0)
    ret, frame = cap.read()
    cap.release()
    if not ret:
        return jsonify({"error": "No frame captured from webcam"}), 500
    _, buffer = cv2.imencode(".jpg", frame)
    return Response(buffer.tobytes(), mimetype="image/jpeg")


@app.route("/api/crop/analyze", methods=["POST"])
def analyze_crop():
    """
    Main inference endpoint.

    Accepts: multipart/form-data with field 'file' (image)
    Returns: JSON with disease, confidence, damage%, severity, spray_recommended
    """
    logger.info("POST /api/crop/analyze")

    # ── 1. File presence check ───────────────────────────────────
    if "file" not in request.files:
        return jsonify({"error": "No file uploaded. Send image as 'file' field."}), 400

    file = request.files["file"]
    if file.filename == "":
        return jsonify({"error": "Empty filename."}), 400

    # ── 2. Validate type + save ──────────────────────────────────
    file_path = None
    try:
        file_path = _validate_and_save(file)
        logger.info(f"Saved upload: {os.path.basename(file_path)}")
    except ValueError as e:
        return jsonify({"error": str(e)}), 400

    try:
        # ── 3. Leaf presence check ───────────────────────────────
        img_bgr = cv2.imread(file_path)
        if img_bgr is None:
            return jsonify({"error": "Could not decode image. File may be corrupt."}), 400

        if not is_leaf_present(img_bgr):
            logger.info("No leaf detected in image.")
            return jsonify({
                "error": "No leaf detected.",
                "message": "Please capture a clear photo of a crop leaf."
            }), 400

        # ── 4. Run TTA prediction ────────────────────────────────
        # Uses 5 augmented variants averaged for stability.
        # Falls back to single prediction if TTA fails.
        try:
            result = predict_with_tta(model, file_path, CLASS_NAMES, n_variants=5)
        except Exception as tta_err:
            logger.warning(f"TTA failed ({tta_err}), falling back to single prediction.")
            from inference import predict_single
            result = predict_single(model, file_path, CLASS_NAMES)

        logger.info(
            f"Prediction: {result.get('disease')} | "
            f"Confidence: {result.get('confidence_percent')}% | "
            f"Damage: {result.get('damage_percent')}% | "
            f"Severity: {result.get('severity')}"
        )
        return jsonify(result), 200

    except Exception as e:
        logger.exception(f"Prediction error: {e}")
        return jsonify({"error": "Prediction failed.", "details": str(e)}), 500

    finally:
        # ── 5. Always clean up uploaded file ────────────────────
        if file_path and os.path.exists(file_path):
            os.remove(file_path)
            logger.debug(f"Cleaned up: {os.path.basename(file_path)}")


# ─────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────
if __name__ == "__main__":
    debug_mode = os.getenv("FLASK_DEBUG", "false").lower() == "true"
    port = int(os.getenv("FLASK_PORT", "5010"))

    logger.info(f"Starting server on port {port} | debug={debug_mode}")
    app.run(host="0.0.0.0", port=port, debug=debug_mode)
