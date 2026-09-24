"""
Crop Scanner — Training Pipeline (Stability Fix)
=================================================
Root causes fixed in this version:
  1. Augmentation was too aggressive → simplified to mild, stable transforms
  2. CLAHE/HSV jitter/blur removed from training → kept only in inference
  3. Class weights capped at 2.0 → prevents extreme gradient bias
  4. Phase 1 LR lowered 1e-3 → 3e-4 → smoother convergence
  5. Fine-tuning unfreezes only last 15 layers (was 40) → prevents collapse
  6. Gradient clipping added → prevents loss spikes
  7. Label smoothing reduced 0.1 → 0.05 → less interference with learning signal
  8. EarlyStopping patience tuned per phase
  9. Validation generator has NO preprocessing_function → clean baseline
"""

import os
import json
import numpy as np
import tensorflow as tf
from tensorflow.keras import layers, Model, callbacks
from tensorflow.keras.applications import MobileNetV2
from tensorflow.keras.preprocessing.image import ImageDataGenerator
import matplotlib
matplotlib.use("Agg")   # works on machines without a display
import matplotlib.pyplot as plt
from sklearn.utils.class_weight import compute_class_weight

# ─────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────
BASE_DIR        = os.path.dirname(os.path.abspath(__file__))
DATASET_DIR     = os.path.join(BASE_DIR, "images")
MODEL_DIR       = os.path.join(BASE_DIR, "models")
MODEL_SAVE_PATH = os.path.join(MODEL_DIR, "crop_model.h5")
BEST_MODEL_PATH = os.path.join(MODEL_DIR, "crop_model_best.h5")
CLASS_JSON_PATH = os.path.join(MODEL_DIR, "class_names.json")

os.makedirs(MODEL_DIR, exist_ok=True)

IMG_SIZE   = (224, 224)   # MobileNetV2 pretrained at 224 — do not change
BATCH_SIZE = 32
SEED       = 42

# ─────────────────────────────────────────────
# DATA GENERATORS
# ─────────────────────────────────────────────
# Training augmentation: mild and stable.
# Heavy transforms (CLAHE, HSV jitter, blur) are intentionally removed.
# They distort the training distribution too far from what the frozen
# MobileNetV2 base expects, causing the val accuracy collapse seen in logs.
#
# Rule of thumb for transfer learning:
#   Keep augmentation gentle enough that the augmented image still looks
#   like a natural photo — not a processed artifact.
train_datagen = ImageDataGenerator(
    rescale=1.0 / 255.0,
    validation_split=0.2,
    rotation_range=15,          # was 30 — reduced to avoid distortion
    width_shift_range=0.1,      # was 0.2
    height_shift_range=0.1,     # was 0.2
    shear_range=0.05,           # was 0.15 — nearly removed
    zoom_range=0.1,             # was 0.25
    brightness_range=[0.8, 1.2],# was [0.7, 1.3] — tighter range
    horizontal_flip=True,
    vertical_flip=False,
    fill_mode='nearest',        # safer than 'reflect' for small datasets
    # NO preprocessing_function — CLAHE/blur/HSV removed from training
)

# Validation: rescale only. No augmentation, no preprocessing_function.
# This gives a clean, unmodified baseline to measure real accuracy.
val_datagen = ImageDataGenerator(
    rescale=1.0 / 255.0,
    validation_split=0.2,
)

train_gen = train_datagen.flow_from_directory(
    DATASET_DIR,
    target_size=IMG_SIZE,
    batch_size=BATCH_SIZE,
    class_mode='categorical',
    subset='training',
    seed=SEED,
    shuffle=True,
)

val_gen = val_datagen.flow_from_directory(
    DATASET_DIR,
    target_size=IMG_SIZE,
    batch_size=BATCH_SIZE,
    class_mode='categorical',
    subset='validation',
    seed=SEED,
    shuffle=False,
)

CLASS_NAMES = list(train_gen.class_indices.keys())
NUM_CLASSES = len(CLASS_NAMES)
print(f"Classes ({NUM_CLASSES}): {CLASS_NAMES}")

# Save class names so inference can load them dynamically
with open(CLASS_JSON_PATH, "w") as f:
    json.dump(CLASS_NAMES, f, indent=2)
print(f"Class names saved to: {CLASS_JSON_PATH}")


# ─────────────────────────────────────────────
# CLASS WEIGHTS (capped to prevent extreme bias)
# ─────────────────────────────────────────────
# compute_class_weight('balanced') can produce weights like 5.8 vs 0.3
# when classes are very imbalanced. Extreme weights destabilize training —
# the model overcorrects on rare classes and forgets common ones.
# Capping at 2.0 gives mild balancing without gradient explosions.
MAX_CLASS_WEIGHT = 2.0

all_labels = train_gen.classes
raw_weights = compute_class_weight(
    class_weight='balanced',
    classes=np.unique(all_labels),
    y=all_labels
)
class_weight_dict = {
    i: min(float(w), MAX_CLASS_WEIGHT)
    for i, w in enumerate(raw_weights)
}
print("Class weights (capped):", {CLASS_NAMES[k]: round(v, 3) for k, v in class_weight_dict.items()})


# ─────────────────────────────────────────────
# MODEL DEFINITION
# ─────────────────────────────────────────────
def build_model(num_classes, img_size=(224, 224), trainable_base=False):
    """
    MobileNetV2 + stable top layers.

    Design decisions:
      - training=False on base_model call: keeps BatchNorm layers in the
        frozen base running in inference mode even during training.
        Without this, BN statistics shift every batch and cause instability.
      - Two Dense blocks with BatchNorm: stable, proven pattern.
      - Dropout 0.4 / 0.3: moderate regularization.
      - Label smoothing 0.05 (was 0.1): small enough to not interfere
        with the learning signal on a 7-class problem.
    """
    base_model = MobileNetV2(
        weights='imagenet',
        include_top=False,
        input_shape=(*img_size, 3)
    )
    base_model.trainable = trainable_base

    inputs = tf.keras.Input(shape=(*img_size, 3))
    # training=False is critical — keeps frozen BN layers stable
    x = base_model(inputs, training=False)

    x = layers.GlobalAveragePooling2D()(x)

    x = layers.Dense(512)(x)
    x = layers.BatchNormalization()(x)
    x = layers.Activation('relu')(x)
    x = layers.Dropout(0.4)(x)

    x = layers.Dense(256)(x)
    x = layers.BatchNormalization()(x)
    x = layers.Activation('relu')(x)
    x = layers.Dropout(0.3)(x)

    outputs = layers.Dense(num_classes, activation='softmax')(x)

    model = Model(inputs, outputs)
    return model, base_model


# ─────────────────────────────────────────────
# PHASE 1 — Train top layers only (base frozen)
# ─────────────────────────────────────────────
print("\n=== PHASE 1: Training top layers (base frozen) ===")
model, base_model = build_model(NUM_CLASSES, IMG_SIZE, trainable_base=False)

model.compile(
    # LR lowered from 1e-3 → 3e-4.
    # 1e-3 is too aggressive for transfer learning — causes the optimizer
    # to overshoot the loss minimum, producing the unstable val curve seen in logs.
    # clipnorm=1.0 prevents gradient spikes from large class-weight corrections.
    optimizer=tf.keras.optimizers.Adam(learning_rate=3e-4, clipnorm=1.0),
    loss=tf.keras.losses.CategoricalCrossentropy(label_smoothing=0.05),
    metrics=['accuracy']
)
model.summary()

cb_phase1 = [
    # Monitor val_loss (more stable signal than val_accuracy for early stopping).
    # patience=8: give the model enough time to climb out of local minima.
    callbacks.EarlyStopping(
        monitor='val_loss',
        patience=8,
        restore_best_weights=True,
        verbose=1
    ),
    # Halve LR when val_loss plateaus for 3 epochs.
    callbacks.ReduceLROnPlateau(
        monitor='val_loss',
        factor=0.5,
        patience=3,
        min_lr=1e-6,
        verbose=1
    ),
    callbacks.ModelCheckpoint(
        BEST_MODEL_PATH,
        monitor='val_accuracy',
        save_best_only=True,
        verbose=1
    ),
]

history1 = model.fit(
    train_gen,
    validation_data=val_gen,
    epochs=40,
    class_weight=class_weight_dict,
    callbacks=cb_phase1,
)

val_acc_phase1 = max(history1.history['val_accuracy'])
print(f"\nPhase 1 best val accuracy: {val_acc_phase1 * 100:.2f}%")


# ─────────────────────────────────────────────
# PHASE 2 — Fine-tune last 15 layers of base
# ─────────────────────────────────────────────
# Only run fine-tuning if Phase 1 reached a reasonable baseline.
# If Phase 1 val accuracy is below 50%, fine-tuning will make things worse —
# the top layers haven't converged yet, so the gradients flowing back into
# the base are noisy and will corrupt the pretrained weights.

FINETUNE_THRESHOLD = 0.50   # skip fine-tuning if Phase 1 didn't reach this

if val_acc_phase1 < FINETUNE_THRESHOLD:
    print(f"\n⚠️  Phase 1 val accuracy ({val_acc_phase1*100:.1f}%) is below "
          f"{FINETUNE_THRESHOLD*100:.0f}%. Skipping fine-tuning.")
    print("   → Check your dataset, class balance, and run Phase 1 again.")
    history2 = None
else:
    print("\n=== PHASE 2: Fine-tuning last 15 base layers ===")

    # Freeze everything first, then selectively unfreeze.
    # Unfreezing only the last 15 layers (was 40) is the key fix.
    # The first ~140 layers of MobileNetV2 are generic feature detectors
    # (edges, textures, colors) — they don't need updating for leaf diseases.
    # The last 15 layers are higher-level feature combiners — these benefit
    # from fine-tuning on domain-specific data.
    for layer in base_model.layers:
        layer.trainable = False
    for layer in base_model.layers[-15:]:
        layer.trainable = True

    trainable_count = sum(1 for l in base_model.layers if l.trainable)
    print(f"Trainable base layers: {trainable_count} / {len(base_model.layers)}")

    model.compile(
        # LR kept at 1e-5 — correct for fine-tuning.
        # clipnorm=1.0 still applied — important when base layers are unfrozen.
        optimizer=tf.keras.optimizers.Adam(learning_rate=1e-5, clipnorm=1.0),
        loss=tf.keras.losses.CategoricalCrossentropy(label_smoothing=0.05),
        metrics=['accuracy']
    )

    cb_phase2 = [
        callbacks.EarlyStopping(
            monitor='val_loss',
            patience=6,
            restore_best_weights=True,
            verbose=1
        ),
        callbacks.ReduceLROnPlateau(
            monitor='val_loss',
            factor=0.3,
            patience=3,
            min_lr=1e-7,
            verbose=1
        ),
        callbacks.ModelCheckpoint(
            BEST_MODEL_PATH,
            monitor='val_accuracy',
            save_best_only=True,
            verbose=1
        ),
    ]

    history2 = model.fit(
        train_gen,
        validation_data=val_gen,
        epochs=20,
        class_weight=class_weight_dict,
        callbacks=cb_phase2,
    )

    val_acc_phase2 = max(history2.history['val_accuracy'])
    print(f"\nPhase 2 best val accuracy: {val_acc_phase2 * 100:.2f}%")


# ─────────────────────────────────────────────
# SAVE FINAL MODEL
# ─────────────────────────────────────────────
model.save(MODEL_SAVE_PATH)
print(f"\nFinal model saved to: {MODEL_SAVE_PATH}")


# ─────────────────────────────────────────────
# TRAINING CURVES
# ─────────────────────────────────────────────
def plot_history(h1, h2=None):
    acc1  = h1.history['accuracy']
    vacc1 = h1.history['val_accuracy']

    if h2 is not None:
        acc2  = h2.history['accuracy']
        vacc2 = h2.history['val_accuracy']
        all_acc  = acc1 + acc2
        all_vacc = vacc1 + vacc2
        split = len(acc1)
    else:
        all_acc  = acc1
        all_vacc = vacc1
        split = None

    epochs = range(1, len(all_acc) + 1)

    plt.figure(figsize=(10, 5))
    plt.plot(epochs, all_acc,  label='Train Accuracy')
    plt.plot(epochs, all_vacc, label='Val Accuracy')
    if split:
        plt.axvline(x=split, color='gray', linestyle='--', label='Fine-tune start')
    plt.title('Training Accuracy')
    plt.xlabel('Epoch')
    plt.ylabel('Accuracy')
    plt.ylim([0, 1])
    plt.legend()
    plt.tight_layout()
    curve_path = os.path.join(MODEL_DIR, "training_curve.png")
    plt.savefig(curve_path, dpi=150)
    plt.close()
    print(f"Training curve saved to: {curve_path}")

plot_history(history1, history2)
