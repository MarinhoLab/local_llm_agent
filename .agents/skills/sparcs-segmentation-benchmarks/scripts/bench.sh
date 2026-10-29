#!/usr/bin/env bash
# One-stream cost of the SPARCS segmentation pipeline (see ../SKILL.md).
#
#   bench.sh                      # all eight profiles, ~10 min
#   bench.sh frame_net_live       # one row, ~2 min
#   JSON=/mnt/out/bench_other.json bench.sh frame_net
set -euo pipefail

REPO=${REPO:-"$HOME/git/sparcs"}
OUT=${OUT:-"$HOME/Dataset/segmentation_out"}
FRAMES=${FRAMES:-/mnt/out/full/frames}
WEIGHTS=${WEIGHTS:-/mnt/out/bbox_net/deeplabv3.pth}
JSON=${JSON:-/mnt/out/bench_live.json}
PROFILES=${1:-decode,box,sam_box,sam_box_cached,frame_cv,frame_net,frame_auto,frame_net_live}

docker run --rm --gpus all \
  -v "$OUT":/mnt/out \
  -v "$REPO":/mnt/repo:ro \
  -w /mnt/repo/dgx/segmentation \
  -e OMP_NUM_THREADS=1 \
  --entrypoint /bin/bash docker-dgx_inference:latest -c \
  "pip install --no-cache-dir --break-system-packages -q transformers==4.57.6 && python3 -u bench_inference.py --frames $FRAMES --clips 3 --per-clip 60 --bbox-weights $WEIGHTS --profiles $PROFILES --json $JSON; chown -R \"\$(id -u):\$(id -g)\" $JSON"
