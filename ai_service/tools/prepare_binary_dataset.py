from pathlib import Path
import shutil

AI_SERVICE_DIR = Path(__file__).resolve().parent.parent
SRC_BASE = AI_SERVICE_DIR / "dataset_split"
DST_BASE = AI_SERVICE_DIR / "dataset_split_binary"

for split in ["train", "val"]:  # remove 'test' if not available
    src_split = SRC_BASE / split
    dst_split = DST_BASE / split

    for cls_type in ["healthy", "diseased"]:
        (dst_split / cls_type).mkdir(parents=True, exist_ok=True)

    for cls in src_split.iterdir():
        if not cls.is_dir():
            continue
        target = "healthy" if "healthy" in cls.name.lower() else "diseased"
        for img in cls.iterdir():
            if img.suffix.lower() in [".jpg", ".jpeg", ".png"]:
                shutil.copy(img, dst_split / target / img.name)

print("✅ Binary dataset prepared at:", DST_BASE)
