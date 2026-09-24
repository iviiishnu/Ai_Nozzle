"""
Crop Scanner — Model Evaluation Script (Fixed)
===============================================
Fixes from original:
  - Normalization changed from /127.5-1.0 to /255.0 (matches training)
  - Uses preprocessing.py pipeline (same as inference — consistent results)
  - Per-class accuracy breakdown
  - Saves confusion matrix as PNG (no display required on headless server)
  - Prints actionable feedback per class
"""

import os
import numpy as np
import tensorflow as tf
from tensorflow.keras.models import load_model
from sklearn.metrics import (
    confusion_matrix, classification_report, accuracy_score
)
import matplotlib
matplotlib.use("Agg")   # Non-interactive backend — works on servers without display
import matplotlib.pyplot as plt
import seaborn as sns
from pathlib import Path

from preprocessing import apply_clahe, IMG_SIZE

# ─────────────────────────────────────────────
# PATHS
# ─────────────────────────────────────────────
BASE_DIR   = Path(__file__).parent
MODEL_PATH = BASE_DIR / "models" / "crop_model_best.h5"
TEST_DIR   = BASE_DIR / "images"
OUTPUT_DIR = BASE_DIR / "models"

# Fallback to old model name
if not MODEL_PATH.exists():
    MODEL_PATH = BASE_DIR / "models" / "new_model.h5"

BATCH_SIZE = 32

# ─────────────────────────────────────────────
# LOAD MODEL
# ─────────────────────────────────────────────
print(f"Loading model: {MODEL_PATH}")
model = load_model(str(MODEL_PATH))

# Determine input size from model
model_input_size = tuple(model.input_shape[1:3])
print(f"Model input size: {model_input_size}")

# ─────────────────────────────────────────────
# LOAD TEST DATASET
# ─────────────────────────────────────────────
test_ds = tf.keras.utils.image_dataset_from_directory(
    str(TEST_DIR),
    image_size=model_input_size,
    batch_size=BATCH_SIZE,
    shuffle=False,
)

CLASS_NAMES = test_ds.class_names
print(f"Classes ({len(CLASS_NAMES)}): {CLASS_NAMES}")

AUTOTUNE = tf.data.AUTOTUNE
test_ds = test_ds.cache().prefetch(buffer_size=AUTOTUNE)


# ─────────────────────────────────────────────
# PREPROCESSING FUNCTION (matches inference)
# ─────────────────────────────────────────────
def preprocess_batch(images, labels):
    """
    Applies the same normalization used during training and inference.
    FIXED: was /127.5 - 1.0 (MobileNetV2 native), now /255.0 (matches training).
    Also applies CLAHE for consistency with inference pipeline.
    """
    # Normalize to [0, 1]
    images = tf.cast(images, tf.float32) / 255.0

    # Apply CLAHE per image (numpy function wrapped in tf.py_function)
    def apply_clahe_tf(img):
        img_uint8 = tf.cast(img * 255, tf.uint8).numpy()
        img_clahe = apply_clahe(img_uint8)
        return tf.cast(img_clahe, tf.float32) / 255.0

    images = tf.stack([
        tf.py_function(apply_clahe_tf, [img], tf.float32)
        for img in tf.unstack(images)
    ])
    images.set_shape([None, *model_input_size, 3])
    return images, labels


test_ds = test_ds.map(preprocess_batch, num_parallel_calls=AUTOTUNE)


# ─────────────────────────────────────────────
# PREDICT
# ─────────────────────────────────────────────
print("\nRunning predictions...")
true_labels = []
pred_labels = []
all_probs   = []

for images, labels in test_ds:
    preds = model.predict(images, verbose=0)
    pred_classes = np.argmax(preds, axis=1)

    true_labels.extend(labels.numpy())
    pred_labels.extend(pred_classes)
    all_probs.extend(preds)

true_labels = np.array(true_labels)
pred_labels = np.array(pred_labels)
all_probs   = np.array(all_probs)


# ─────────────────────────────────────────────
# METRICS
# ─────────────────────────────────────────────
cm       = confusion_matrix(true_labels, pred_labels)
accuracy = accuracy_score(true_labels, pred_labels)
report   = classification_report(true_labels, pred_labels, target_names=CLASS_NAMES)

print(f"\n{'='*50}")
print(f"Overall Test Accuracy: {accuracy * 100:.2f}%")
print(f"{'='*50}")
print("\nClassification Report:\n", report)


# ─────────────────────────────────────────────
# PER-CLASS ANALYSIS
# ─────────────────────────────────────────────
print("\nPer-Class Analysis:")
print(f"{'Class':<25} {'Correct':>8} {'Total':>8} {'Accuracy':>10} {'Status':>12}")
print("-" * 70)

for i, cls in enumerate(CLASS_NAMES):
    cls_mask    = true_labels == i
    cls_total   = cls_mask.sum()
    cls_correct = (pred_labels[cls_mask] == i).sum()
    cls_acc     = cls_correct / cls_total if cls_total > 0 else 0

    if cls_acc >= 0.85:
        status = "✅ Good"
    elif cls_acc >= 0.70:
        status = "⚠️  Acceptable"
    else:
        status = "❌ Needs work"

    print(f"{cls:<25} {cls_correct:>8} {cls_total:>8} {cls_acc*100:>9.1f}%  {status}")


# ─────────────────────────────────────────────
# CONFUSION MATRIX PLOT
# ─────────────────────────────────────────────
plt.figure(figsize=(10, 8))
sns.heatmap(
    cm, annot=True, fmt="d", cmap="Blues",
    xticklabels=CLASS_NAMES, yticklabels=CLASS_NAMES
)
plt.xlabel("Predicted", fontsize=12)
plt.ylabel("True", fontsize=12)
plt.title(f"Confusion Matrix — Accuracy: {accuracy*100:.2f}%", fontsize=14)
plt.xticks(rotation=45, ha='right')
plt.yticks(rotation=0)
plt.tight_layout()

cm_path = OUTPUT_DIR / "confusion_matrix.png"
plt.savefig(str(cm_path), dpi=150)
print(f"\nConfusion matrix saved to: {cm_path}")


# ─────────────────────────────────────────────
# CONFIDENCE DISTRIBUTION
# ─────────────────────────────────────────────
top_confidences = np.max(all_probs, axis=1)

plt.figure(figsize=(8, 4))
plt.hist(top_confidences, bins=20, color='steelblue', edgecolor='white')
plt.axvline(x=0.50, color='red', linestyle='--', label='Threshold (0.50)')
plt.axvline(x=0.80, color='green', linestyle='--', label='High confidence (0.80)')
plt.xlabel("Top Prediction Confidence")
plt.ylabel("Count")
plt.title("Confidence Distribution on Test Set")
plt.legend()
plt.tight_layout()

conf_path = OUTPUT_DIR / "confidence_distribution.png"
plt.savefig(str(conf_path), dpi=150)
print(f"Confidence distribution saved to: {conf_path}")

uncertain_count = (top_confidences < 0.50).sum()
print(f"\nPredictions below 0.50 threshold: {uncertain_count}/{len(top_confidences)} "
      f"({uncertain_count/len(top_confidences)*100:.1f}%) — these return 'Uncertain'")


# ─────────────────────────────────────────────
# ACTIONABLE FEEDBACK
# ─────────────────────────────────────────────
def performance_feedback(acc):
    print(f"\n{'='*50}")
    if acc < 0.70:
        print("❌ Model underperforming.")
        print("   → Collect more training data (aim for 500+ images per class)")
        print("   → Check for class imbalance (run with class_weight='balanced')")
        print("   → Try training for more epochs or reducing learning rate")
    elif acc < 0.85:
        print("⚠️  Decent accuracy — room for improvement.")
        print("   → Fine-tune more layers (increase from 40 to 60 in train_model.py)")
        print("   → Add more augmentation variety")
        print("   → Check which classes are underperforming above")
    else:
        print("✅ Good accuracy — suitable for demo/deployment.")
        print("   → Run on real phone images to verify real-world performance")
        print("   → Consider TFLite quantization for mobile deployment")

performance_feedback(accuracy)
