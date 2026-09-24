"""
Crop Scanner — TFLite Conversion with Quantization
====================================================
Converts the trained Keras .h5 model to TFLite format.

Three conversion modes:
  1. float32  — No quantization. Largest file, highest accuracy.
  2. float16  — Half-precision weights. ~2x smaller, minimal accuracy loss.
                Best for GPU-accelerated Android devices.
  3. int8     — Full integer quantization. ~4x smaller, fastest on CPU.
                Best for low-end phones. Requires representative dataset.

Usage:
    python convert_tflite.py --mode float16
    python convert_tflite.py --mode int8
    python convert_tflite.py --mode float32
"""

import os
import sys
import argparse
import numpy as np
import tensorflow as tf

# ─────────────────────────────────────────────
# PATHS
# ─────────────────────────────────────────────
BASE_DIR    = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR   = os.path.join(BASE_DIR, "models")
DATASET_DIR = os.path.join(BASE_DIR, "images")

INPUT_MODEL  = os.path.join(MODEL_DIR, "crop_model_best.h5")
# Fallback to old name
if not os.path.exists(INPUT_MODEL):
    INPUT_MODEL = os.path.join(MODEL_DIR, "new_model.h5")


# ─────────────────────────────────────────────
# REPRESENTATIVE DATASET (for int8 quantization)
# ─────────────────────────────────────────────
def get_representative_dataset(n_samples: int = 100):
    """
    Yields sample images from the training dataset.
    Required for int8 quantization — the converter uses these
    to calibrate the quantization scale factors.

    n_samples: How many images to use (100 is usually enough)
    """
    from preprocessing import preprocess_for_inference, IMG_SIZE

    count = 0
    for disease_dir in os.listdir(DATASET_DIR):
        disease_path = os.path.join(DATASET_DIR, disease_dir)
        if not os.path.isdir(disease_path):
            continue
        for img_file in os.listdir(disease_path):
            if count >= n_samples:
                return
            if not img_file.lower().endswith((".jpg", ".jpeg", ".png")):
                continue
            img_path = os.path.join(disease_path, img_file)
            try:
                preprocessed = preprocess_for_inference(img_path, target_size=IMG_SIZE)
                yield [preprocessed]
                count += 1
            except Exception:
                continue


# ─────────────────────────────────────────────
# CONVERSION FUNCTIONS
# ─────────────────────────────────────────────
def convert_float32(model) -> bytes:
    """No quantization — baseline conversion."""
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    return converter.convert()


def convert_float16(model) -> bytes:
    """
    Float16 quantization.
    Weights stored as float16, activations remain float32.
    ~2x size reduction with negligible accuracy loss.
    Recommended for most Android devices.
    """
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.target_spec.supported_types = [tf.float16]
    return converter.convert()


def convert_int8(model) -> bytes:
    """
    Full integer quantization.
    Both weights and activations quantized to int8.
    ~4x size reduction, fastest inference on CPU.
    Requires representative dataset for calibration.
    """
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.representative_dataset = get_representative_dataset
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    converter.inference_input_type  = tf.uint8
    converter.inference_output_type = tf.uint8
    return converter.convert()


# ─────────────────────────────────────────────
# VERIFY TFLITE MODEL
# ─────────────────────────────────────────────
def verify_tflite(tflite_path: str):
    """
    Runs a dummy inference on the saved TFLite model to verify it works.
    """
    interpreter = tf.lite.Interpreter(model_path=tflite_path)
    interpreter.allocate_tensors()

    input_details  = interpreter.get_input_details()
    output_details = interpreter.get_output_details()

    input_shape = input_details[0]['shape']
    input_dtype = input_details[0]['dtype']

    print(f"  Input shape: {input_shape}, dtype: {input_dtype}")
    print(f"  Output shape: {output_details[0]['shape']}")

    # Create dummy input
    if input_dtype == np.uint8:
        dummy = np.random.randint(0, 255, input_shape, dtype=np.uint8)
    else:
        dummy = np.random.rand(*input_shape).astype(np.float32)

    interpreter.set_tensor(input_details[0]['index'], dummy)
    interpreter.invoke()
    output = interpreter.get_tensor(output_details[0]['index'])
    print(f"  Dummy inference output shape: {output.shape} ✅")


# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Convert Keras model to TFLite")
    parser.add_argument(
        "--mode",
        choices=["float32", "float16", "int8"],
        default="float16",
        help="Quantization mode (default: float16)"
    )
    parser.add_argument(
        "--input",
        default=INPUT_MODEL,
        help=f"Input .h5 model path (default: {INPUT_MODEL})"
    )
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"ERROR: Model not found: {args.input}")
        sys.exit(1)

    print(f"Loading model: {args.input}")
    model = tf.keras.models.load_model(args.input)
    print(f"Model input shape: {model.input_shape}")

    output_path = os.path.join(MODEL_DIR, f"crop_model_{args.mode}.tflite")

    print(f"\nConverting to TFLite ({args.mode})...")
    if args.mode == "float32":
        tflite_bytes = convert_float32(model)
    elif args.mode == "float16":
        tflite_bytes = convert_float16(model)
    elif args.mode == "int8":
        print("  Calibrating with representative dataset (this may take a minute)...")
        tflite_bytes = convert_int8(model)

    with open(output_path, "wb") as f:
        f.write(tflite_bytes)

    original_size = os.path.getsize(args.input) / (1024 * 1024)
    tflite_size   = len(tflite_bytes) / (1024 * 1024)
    reduction     = (1 - tflite_size / original_size) * 100

    print(f"\nSaved: {output_path}")
    print(f"Original size: {original_size:.1f} MB")
    print(f"TFLite size:   {tflite_size:.1f} MB  ({reduction:.0f}% reduction)")

    print("\nVerifying TFLite model...")
    verify_tflite(output_path)
    print("\nConversion complete.")


if __name__ == "__main__":
    main()
