# ai_service/tools/train_transfer_two_step.py
import tensorflow as tf
from tensorflow.keras.callbacks import EarlyStopping, ModelCheckpoint
from pathlib import Path
import json
import os
import sys

BASE_DIR = Path(__file__).parent.parent  # ai_service
DATASET_BINARY_DIR = BASE_DIR / "dataset_split_binary"
DATASET_MULTICLASS_DIR = BASE_DIR / "dataset_split"
BINARY_MODEL_PATH = BASE_DIR / "plant_binary_best.h5"
DISEASE_MODEL_PATH = BASE_DIR / "plant_disease_best.h5"
CLASS_NAMES_PATH = BASE_DIR / "disease_class_names.json"

IMG_SIZE = (128, 128)
BATCH_SIZE = 32
EPOCHS = 10

# ------------------------
# Step 0: Check datasets
# ------------------------
for split in ["train", "val"]:
    path = DATASET_BINARY_DIR / split
    if not path.exists():
        print(f"❌ Binary dataset folder not found: {path}")
        print("Run prepare_binary_dataset.py first!")
        sys.exit(1)

    healthy = path / "healthy"
    diseased = path / "diseased"
    if not healthy.exists() or not diseased.exists():
        print(f"❌ Binary dataset structure incorrect in {path}")
        sys.exit(1)

# ------------------------
# Step 1: Binary classifier (Healthy vs Diseased)
# ------------------------
print("📁 Loading binary dataset...")

train_ds_binary = tf.keras.utils.image_dataset_from_directory(
    DATASET_BINARY_DIR / "train",
    label_mode="binary",
    image_size=IMG_SIZE,
    batch_size=BATCH_SIZE,
    shuffle=True
)

val_ds_binary = tf.keras.utils.image_dataset_from_directory(
    DATASET_BINARY_DIR / "val",
    label_mode="binary",
    image_size=IMG_SIZE,
    batch_size=BATCH_SIZE,
    shuffle=False
)

AUTOTUNE = tf.data.AUTOTUNE
train_ds_binary = train_ds_binary.prefetch(buffer_size=AUTOTUNE)
val_ds_binary = val_ds_binary.prefetch(buffer_size=AUTOTUNE)

binary_model = tf.keras.Sequential([
    tf.keras.applications.MobileNetV2(input_shape=(128,128,3), include_top=False, weights='imagenet'),
    tf.keras.layers.GlobalAveragePooling2D(),
    tf.keras.layers.Dense(128, activation='relu'),
    tf.keras.layers.Dense(1, activation='sigmoid')
])

binary_model.compile(
    optimizer=tf.keras.optimizers.Adam(1e-4),
    loss='binary_crossentropy',
    metrics=['accuracy']
)

callbacks_binary = [
    EarlyStopping(monitor='val_accuracy', patience=3, restore_best_weights=True),
    ModelCheckpoint(BINARY_MODEL_PATH, monitor='val_accuracy', save_best_only=True)
]

print("🤖 Training binary classifier...")
binary_model.fit(train_ds_binary, validation_data=val_ds_binary, epochs=EPOCHS, callbacks=callbacks_binary)
print(f"✅ Binary model saved: {BINARY_MODEL_PATH}")

# ------------------------
# Step 2: Disease classifier (multiclass)
# ------------------------
print("📁 Loading multiclass dataset...")

if not (DATASET_MULTICLASS_DIR / "train").exists():
    print(f"❌ Multiclass dataset not found at {DATASET_MULTICLASS_DIR / 'train'}")
    sys.exit(1)

train_ds_disease = tf.keras.utils.image_dataset_from_directory(
    DATASET_MULTICLASS_DIR / "train",
    image_size=IMG_SIZE,
    batch_size=BATCH_SIZE,
    shuffle=True
)

val_ds_disease = tf.keras.utils.image_dataset_from_directory(
    DATASET_MULTICLASS_DIR / "val",
    image_size=IMG_SIZE,
    batch_size=BATCH_SIZE,
    shuffle=False
)

disease_class_names = train_ds_disease.class_names
with open(CLASS_NAMES_PATH, "w") as f:
    json.dump(disease_class_names, f, indent=2)
print(f"✅ Disease class names saved: {len(disease_class_names)}")

train_ds_disease = train_ds_disease.prefetch(buffer_size=AUTOTUNE)
val_ds_disease = val_ds_disease.prefetch(buffer_size=AUTOTUNE)

num_classes = len(disease_class_names)

disease_model = tf.keras.Sequential([
    tf.keras.applications.MobileNetV2(input_shape=(128,128,3), include_top=False, weights='imagenet'),
    tf.keras.layers.GlobalAveragePooling2D(),
    tf.keras.layers.Dense(256, activation='relu'),
    tf.keras.layers.Dense(num_classes, activation='softmax')
])

disease_model.compile(
    optimizer=tf.keras.optimizers.Adam(1e-4),
    loss='sparse_categorical_crossentropy',
    metrics=['accuracy']
)

callbacks_disease = [
    EarlyStopping(monitor='val_accuracy', patience=3, restore_best_weights=True),
    ModelCheckpoint(DISEASE_MODEL_PATH, monitor='val_accuracy', save_best_only=True)
]

print("🤖 Training disease classifier...")
disease_model.fit(train_ds_disease, validation_data=val_ds_disease, epochs=EPOCHS, callbacks=callbacks_disease)
print(f"✅ Disease model saved: {DISEASE_MODEL_PATH}")
