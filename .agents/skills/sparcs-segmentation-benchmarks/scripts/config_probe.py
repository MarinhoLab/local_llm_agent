"""!
@brief What a configuration knob is worth on the live segmentation path, without repo code changes.

Runs the production ``cli.process_frame`` in its ``--prompt net`` (live) form over consecutive frames
of three clips, once per configuration, and prints p50 / p95 / fps. Nothing is imported from the repo
as anything but the production entry points, so a number here is what a node would feel.

Covered: ``ImageEmbeddingCache(max_change=, max_age=)`` (the only two tuning knobs SAM 2's amortised
encoder has), ``torch.backends.cudnn.benchmark``, and ``torch.backends.cuda.matmul.allow_tf32``. The
process environment knobs -- ``OMP_NUM_THREADS``, ``TORCH_ALLOW_TF32_CUBLAS_OVERRIDE``,
``PYTORCH_CUDA_ALLOC_CONF`` -- are printed for the record and must be varied by launching this file
once per environment (see ``live_audit.sh`` / ``bench.sh`` for the container shape).

    docker run --rm --gpus all -v $HOME/Dataset/segmentation_out:/mnt/out \\
        -v $HOME/git/sparcs:/mnt/repo:ro -v $PWD:/probes:ro -w /mnt/repo/dgx/segmentation \\
        -e OMP_NUM_THREADS=1 --entrypoint /bin/bash docker-dgx_inference:latest -c \\
        'pip install --no-cache-dir --break-system-packages -q transformers==4.57.6 && \\
         python3 -u /probes/config_probe.py'

@file
@author Murilo Marques Marinho
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, "/mnt/repo/dgx/segmentation")

import cv2  # noqa: E402
import torch  # noqa: E402

import cli  # noqa: E402
import sam2 as sam2_module  # noqa: E402
from bbox_net import load_bbox_net  # noqa: E402

FRAMES_ROOT = Path("/mnt/out/full/frames")
WEIGHTS = Path("/mnt/out/bbox_net/deeplabv3.pth")

## Clips sampled, and consecutive frames taken from each (30% in, past the camera settling).
CLIPS: int = 3
PER_CLIP: int = 90

## Frames whose timing is discarded: the first SAM 2 call pays for kernel loading.
WARMUP: int = 8


def sample() -> list[Path]:
    """! Consecutive frames of a few clips, the way a real stream arrives."""
    clips = sorted({path.parent for path in FRAMES_ROOT.rglob("frame_*.jpg")})[:CLIPS]
    paths: list[Path] = []
    for clip in clips:
        images = sorted(clip.glob("frame_*.jpg"))
        paths.extend(images[int(len(images) * 0.3) :][:PER_CLIP])
    return paths


def measure(name: str, paths: list[Path], net: Any, pair: Any, cache: Any) -> None:
    """! Time ``process_frame --prompt net`` over the sample and print the row.

    @param name What is configured differently in this pass.
    @param paths The frames, in stream order.
    @param net The learned box as ``(model, device)``.
    @param pair The SAM 2 ``(model, processor, device)``.
    @param cache The embedding cache configuration under test.
    """
    def once(path: Path) -> None:
        image = cv2.imread(str(path), cv2.IMREAD_COLOR)
        cli.process_frame(
            image,
            use_sam2=True,
            model=pair[0],
            processor=pair[1],
            bbox_source="net",
            net=net,
            sam2_cache=cache,
            prompt_mode="net",
            crop=False,
        )

    for path in paths[:WARMUP]:
        once(path)
    wall: list[float] = []
    for path in paths:
        start = time.perf_counter()
        once(path)
        wall.append((time.perf_counter() - start) * 1000.0)
    wall.sort()
    p50 = wall[len(wall) // 2]
    p95 = wall[min(len(wall) - 1, int(0.95 * len(wall)) - 1)]
    print(
        f"{name:34} n={len(wall):>4}  p50 {p50:7.2f} ms  p95 {p95:7.2f} ms  {1000 / p50:6.2f} fps",
        flush=True,
    )


def main() -> int:
    """! Load the models once, then run every configuration against the same frames."""
    print(
        f"env: OMP_NUM_THREADS={os.environ.get('OMP_NUM_THREADS')} "
        f"TF32_override={os.environ.get('TORCH_ALLOW_TF32_CUBLAS_OVERRIDE')} "
        f"alloc={os.environ.get('PYTORCH_CUDA_ALLOC_CONF')}",
        flush=True,
    )
    model, _, device = load_bbox_net(WEIGHTS, None)
    net = (model, device)
    pair = sam2_module.load_sam2(sam2_module.SAM2_MODEL_ID, None)
    paths = sample()
    print(
        f"live frame, {len(paths)} consecutive frames; matmul_tf32="
        f"{torch.backends.cuda.matmul.allow_tf32} cudnn_tf32={torch.backends.cudnn.allow_tf32} "
        f"cudnn_benchmark={torch.backends.cudnn.benchmark}",
        flush=True,
    )

    def cache(max_change: float = sam2_module.ENCODER_MAX_CHANGE, max_age: int = 30) -> Any:
        return sam2_module.ImageEmbeddingCache(pair[0], pair[1], max_change=max_change, max_age=max_age)

    measure("cache 0.02 / age 30 (shipped)", paths, net, pair, cache())
    measure("cache 0.05 / age 120", paths, net, pair, cache(0.05, 120))
    measure("cache 0.02 / age 120", paths, net, pair, cache(0.02, 120))

    torch.backends.cudnn.benchmark = True
    measure("cudnn.benchmark = True", paths, net, pair, cache())
    torch.backends.cudnn.benchmark = False
    torch.backends.cuda.matmul.allow_tf32 = True
    measure("matmul allow_tf32 = True", paths, net, pair, cache())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
