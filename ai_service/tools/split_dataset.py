# ai_service/tools/split_dataset.py
import os, shutil, random
from pathlib import Path

SRC = Path(__file__).parent.parent / "dataset" / "color"
OUT = Path(__file__).parent.parent / "dataset_split"  # <-- define OUT

TRAIN_RATIO = 0.7
VAL_RATIO = 0.2
TEST_RATIO = 0.1
random.seed(123)

def ensure_empty(path: Path):
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)

# ✅ Create empty train/val/test folders
ensure_empty(OUT / "train")
ensure_empty(OUT / "val")
ensure_empty(OUT / "test")

# Split dataset
classes = [d for d in SRC.iterdir() if d.is_dir()]
print(f"Found {len(classes)} classes.")

for cls in classes:
    images = [p for p in cls.iterdir() if p.suffix.lower() in ('.jpg','.jpeg','.png')]
    random.shuffle(images)
    n = len(images)
    n_train = int(n * TRAIN_RATIO)
    n_val = int(n * VAL_RATIO)
    train_files = images[:n_train]
    val_files = images[n_train:n_train+n_val]
    test_files = images[n_train+n_val:]

    for dst_root, files in [(OUT/"train", train_files), (OUT/"val", val_files), (OUT/"test", test_files)]:
        dst_dir = dst_root / cls.name
        dst_dir.mkdir(parents=True, exist_ok=True)
        for f in files:
            shutil.copy(f, dst_dir / f.name)

    print(f"{cls.name}: total={n}, train={len(train_files)}, val={len(val_files)}, test={len(test_files)}")

print("✅ Done splitting dataset.")
