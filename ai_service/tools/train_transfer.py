import tensorflow as tf
from tensorflow.keras.callbacks import EarlyStopping, ModelCheckpoint, ReduceLROnPlateau
from tensorflow.keras import layers, models
from pathlib import Path
import json
import os
import numpy as np
from sklearn.utils.class_weight import compute_class_weight

# ======================
# Paths
# ======================
BASE_DIR = Path(__file__).parent.parent
train_dir = BASE_DIR / "dataset_split" / "train"
val_dir   = BASE_DIR / "dataset_split" / "val"
test_dir  = BASE_DIR / "dataset_split" / "test"

MODEL_BEST_PATH = BASE_DIR / "plant_disease_best.h5"
MODEL_LAST_PATH = BASE_DIR / "plant_disease_cnn.h5"
CLASS_NAMES_PATH = BASE_DIR / "class_names.json"

# ======================
# Hyperparameters
# ======================
IMG_SIZE = (128, 128)
BATCH_SIZE = 32
INITIAL_EPOCHS = 15
FINE_TUNE_EPOCHS = 25
TOTAL_EPOCHS = INITIAL_EPOCHS + FINE_TUNE_EPOCHS

# ======================
# Load datasets
# ======================
print("📁 Loading datasets...")
train_ds = tf.keras.utils.image_dataset_from_directory(
    train_dir,
    image_size=IMG_SIZE,
    batch_size=BATCH_SIZE,
    shuffle=True
)
val_ds = tf.keras.utils.image_dataset_from_directory(
    val_dir,
    image_size=IMG_SIZE,
    batch_size=BATCH_SIZE,
    shuffle=False
)
test_ds = tf.keras.utils.image_dataset_from_directory(
    test_dir,
    image_size=IMG_SIZE,
    batch_size=BATCH_SIZE,
    shuffle=False
)

# Save class names
class_names = train_ds.class_names
with open(CLASS_NAMES_PATH, "w") as f:
    json.dump(class_names, f, indent=2)
print(f"✅ Saved class names: {len(class_names)} classes")

# Prefetch and cache for performance
AUTOTUNE = tf.data.AUTOTUNE
train_ds = train_ds.cache().shuffle(1000).prefetch(buffer_size=AUTOTUNE)
val_ds   = val_ds.cache().prefetch(buffer_size=AUTOTUNE)
test_ds  = test_ds.cache().prefetch(buffer_size=AUTOTUNE)

# ======================
# Optional: Compute class weights for imbalanced data
# ======================
# Extract labels from train_ds to compute weights
train_labels = np.concatenate([y.numpy() for x, y in train_ds], axis=0)
class_weights = compute_class_weight(
    class_weight='balanced',
    classes=np.unique(train_labels),
    y=train_labels
)
class_weight_dict = dict(enumerate(class_weights))

# ======================
# Data augmentation
# ======================
data_augmentation = tf.keras.Sequential([
    layers.RandomFlip("horizontal"),
    layers.RandomRotation(0.2),
    layers.RandomZoom(0.2),
    # Optionally add more augmentations here
])

# ======================
# Build model
# ======================
num_classes = len(class_names)

# Load MobileNetV2 base
base_model = tf.keras.applications.MobileNetV2(
    input_shape=(128,128,3),
    include_top=False,
    weights='imagenet'
)
base_model.trainable = False  # Freeze base initially

model = models.Sequential([
    data_augmentation,
    layers.Rescaling(1./127.5, offset=-1),  # MobileNetV2 preprocess
    base_model,
    layers.GlobalAveragePooling2D(),
    layers.Dropout(0.5),
    layers.Dense(num_classes, activation='softmax')
])

model.compile(
    optimizer=tf.keras.optimizers.Adam(learning_rate=1e-4),
    loss='sparse_categorical_crossentropy',
    metrics=['accuracy']
)

# ======================
# Callbacks
# ======================
callbacks = [
    EarlyStopping(monitor='val_accuracy', patience=3, restore_best_weights=True),
    ModelCheckpoint(MODEL_BEST_PATH, monitor='val_accuracy', save_best_only=True),
    ReduceLROnPlateau(monitor='val_loss', factor=0.2, patience=2, min_lr=1e-6)
]

# ======================
# Initial training
# ======================
print("🤖 Starting initial training...")
history = model.fit(
    train_ds,
    validation_data=val_ds,
    epochs=INITIAL_EPOCHS,
    callbacks=callbacks,
    class_weight=class_weight_dict  # Comment out if not needed
)

# ======================
# Fine-tuning
# ======================
print("🔓 Unfreezing top layers for fine-tuning...")

base_model.trainable = True

fine_tune_at = 100  # freeze all layers before this index

for layer in base_model.layers[:fine_tune_at]:
    layer.trainable = False

model.compile(
    optimizer=tf.keras.optimizers.Adam(learning_rate=1e-5),
    loss='sparse_categorical_crossentropy',
    metrics=['accuracy']
)

print("🤖 Starting fine-tuning...")
history_fine = model.fit(
    train_ds,
    validation_data=val_ds,
    epochs=TOTAL_EPOCHS,
    initial_epoch=history.epoch[-1] + 1,
    callbacks=callbacks,
    class_weight=class_weight_dict  # Comment out if not needed
)

# Save final model
model.save(MODEL_LAST_PATH)
print("✅ Training complete!")
print(f"👉 Best model saved at: {MODEL_BEST_PATH}")
print(f"👉 Last model saved at: {MODEL_LAST_PATH}")

# ======================
# Evaluate on test dataset
# ======================
print("📊 Evaluating on test dataset...")
test_loss, test_acc = model.evaluate(test_ds)
print(f"Test accuracy: {test_acc * 100:.2f}%")
