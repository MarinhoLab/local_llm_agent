#!/usr/bin/env bash
# Audit the --prompt net live mode against the classical-seeded reference run (see ../SKILL.md).
#
#   live_audit.sh                      # 120 consecutive frames per clip, all clips
#   PER_CLIP=200 live_audit.sh
#
# Ends by printing the agreement table; check "compared=N" with N > 0 -- compared=0 means the two runs
# were given different --frames root depths and the mask names do not line up (see ../SKILL.md).
set -euo pipefail

REPO=${REPO:-"$HOME/git/sparcs"}
OUT=${OUT:-"$HOME/Dataset/segmentation_out"}
WEIGHTS=${WEIGHTS:-/mnt/out/bbox_net/deeplabv3.pth}
SOURCE=${SOURCE:-/mnt/out/full/frames/wd_full}   # the reference run's --frames root depth
SAMPLE=${SAMPLE:-/mnt/out/live_sample/wd_full}
CANDIDATE=${CANDIDATE:-/mnt/out/run_live_sample}
REFERENCE=${REFERENCE:-/mnt/out/run_full}
PER_CLIP=${PER_CLIP:-120}

python3 - "$OUT" "$PER_CLIP" <<'PY'
"""! Rebuild the hardlinked sample: consecutive frames, 30% into each clip, cheap on purpose."""
import shutil
import sys
from pathlib import Path

out, per_clip = Path(sys.argv[1]), int(sys.argv[2])
src, dst = out / "full/frames/wd_full", out / "live_sample/wd_full"
shutil.rmtree(out / "live_sample", ignore_errors=True)
total = 0
for clip in sorted(p for p in src.iterdir() if p.is_dir()):
    images = sorted(clip.glob("frame_*.jpg"))
    start = int(len(images) * 0.3)
    target = dst / clip.name
    target.mkdir(parents=True)
    for frame in images[start : start + per_clip]:
        link = target / frame.name
        try:
            link.hardlink_to(frame)
        except OSError:
            shutil.copy2(frame, link)
        total += 1
print(f"sample: {total} frames under {dst}")
PY

docker run --rm --gpus all \
  -v "$OUT":/mnt/out \
  -v "$REPO":/mnt/repo:ro \
  -w /mnt/repo/dgx/segmentation \
  -e OMP_NUM_THREADS=1 \
  --entrypoint /bin/bash docker-dgx_inference:latest -c \
  "pip install --no-cache-dir --break-system-packages -q transformers==4.57.6 && rm -rf $CANDIDATE && python3 -u cli.py $SAMPLE --out $CANDIDATE --sam2 --sam2-cache 0.02 --bbox net --bbox-weights $WEIGHTS --prompt net && python3 -u compare_masks.py $CANDIDATE --against $REFERENCE --out /mnt/out/compare_live.json; chown -R \"\$(id -u):\$(id -g)\" $CANDIDATE /mnt/out/compare_live.json"
