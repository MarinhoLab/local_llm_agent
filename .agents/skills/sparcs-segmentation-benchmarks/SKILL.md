---
name: sparcs-segmentation-benchmarks
description: >-
  How to benchmark and audit the SPARCS segmentation pipeline (`~/git/sparcs/dgx/segmentation`)
  on the DGX Spark: the container invocation, the ephemeral `transformers` install, the GPU and
  ownership gotchas, the committed tools (`bench_inference.py`, `compare_masks.py --against`,
  `render_results.py`), the published numbers, and the scripts in this folder that reproduce them.
license: MIT
compatibility: Docker on the DGX Spark (aarch64, GB10); image `docker-dgx_inference:latest`, `tools-pyright`
triggers:
  - segmentation benchmark
  - bench_inference
  - prompt net
  - compare_masks against
  - how fast is segmentation
  - render segmentation video
  - sparcs gpu
---

`~/git/sparcs/dgx/segmentation` segments a camera on the Spark: a classical GrabCut stage, a learned
DeepLabV3+ crop box (`bbox_net.py`), and SAM 2 (`sam2.py`). Its benchmarks live in
`INFERENCE.md` (inference) and `TRAINING.md` (training); the tools are committed, so **measure with
them rather than writing new probes**.

## The container, once and for all

```bash
cd ~/git/sparcs
docker run --rm --gpus all \
  -v $HOME/Dataset/segmentation_out:/mnt/out \
  -v $PWD:/mnt/repo:ro \
  -w /mnt/repo/dgx/segmentation \
  -e OMP_NUM_THREADS=1 \
  --entrypoint /bin/bash docker-dgx_inference:latest -c \
  'pip install --no-cache-dir --break-system-packages -q transformers==4.57.6 && python3 -u <tool> ...'
```

Five things that are not obvious and each cost a run when forgotten:

- **`transformers==4.57.6` is not in the image.** Every SAM 2 or net run must pip-install it inside the
  container (`--no-cache-dir --break-system-packages`), or `import transformers` fails.
- **`--gpus all`**, or everything silently runs on CPU and the numbers are ~100x wrong.
- **`-e OMP_NUM_THREADS=1`** for timing runs, so host thread count is not part of the measurement.
- **Outputs are root-owned.** Finish the command with
  `chown -R "$(id -u):$(id -g)" /mnt/out/<new stuff>` or the host cannot delete them.
- **One GPU container at a time.** A second one sharing the GPU inflates every `p50`
  (`--jobs 12` turns the net's 10 ms into 47 ms and SAM 2's 71 ms into 164-194 ms).

Datasets live outside the repo: frames `~/Dataset/segmentation_out/full/frames/<source>/<clip>/frame_*.jpg`
(17 258 of them, 5 clips, 1920x1080), source mp4s `~/Dataset/segmentation_videos/videos/wd_new/video1/`,
checkpoint `~/Dataset/segmentation_out/bbox_net/deeplabv3.pth`, runs `~/Dataset/segmentation_out/run_*`.

## The tools

| tool | what it answers |
|---|---|
| `bench_inference.py --frames DIR [--clips N] [--per-clip N] [--profiles a,b] [--json F]` | what one frame costs on **one stream and an idle GPU**: `decode`, `box`, `sam_box`, `sam_box_cached`, `frame_cv`, `frame_net`, `frame_auto`, `frame_net_live` |
| `compare_masks.py RUN [--mode stored\|centre\|auto \| --against OTHER_RUN]` | mask agreement; `--against` compares two runs' SAM 2 masks, which is how a configuration change is audited |
| `render_results.py --frames DIR --run DIR [--clips DIR] --out DIR [--fps F] [--join]` | annotated mp4s with the play/source/**inference** rates, per-stage ms, fraction, score, coverage and mask agreement burned in |
| `bbox_net.py RUN [--json F]` | the two boxers of a run and their agreement |
| `python3 -m pytest -q` (in the container, `-e PYTHONPATH=/mnt/repo/dgx/training`) | 146 passed, 2 skipped (147 / 1 once `transformers` is installed) |
| `docker run --rm -v $PWD:/mnt/repo:ro -w /mnt/repo/dgx/segmentation --entrypoint /bin/bash tools-pyright -c 'pyright .'` | type check |

`bench_inference.py` samples **consecutive** frames on purpose: `--sam2-cache` only amortises over
near-duplicates, so a strided sample measures a cache that never hits. `--profiles` re-runs one row
(~2 min) without paying for the other seven (~10 min).

## Published numbers (2026-10-29, one stream, idle GB10, 180 consecutive frames)

| profile | p50 | p95 | fps |
|---|---|---|---|
| `decode` | 4.81 ms | 4.98 ms | 208 |
| `box` | 14.27 ms | 15.07 ms | 70.1 |
| `sam_box` | 107.31 ms | 108.30 ms | 9.32 |
| `sam_box_cached` | 54.26 ms | 55.38 ms | 18.4 |
| `frame_cv` | 636.34 ms | 655.40 ms | 1.57 |
| `frame_net` | 643.38 ms | 660.75 ms | 1.55 |
| `frame_auto` | 637.89 ms | 661.88 ms | 1.57 |
| `frame_net_live` (`--prompt net`) | 57.93 ms | 58.99 ms | **17.3** |

Stage p50: `decode 5.0`, `bbox 4.9`, `net 10.0`, `classical 539-543`, `sam2 44-45` ms. Read them this
way: GrabCut is ~83% of a production frame and the SAM 2 encoder (44 ms, ~39 ms cached) is the floor of
the live mode; the boxers are noise. `--bbox auto` consulted the net on **0 of these 180** frames (the
row's `net_calls` field says so) and on 11.43% of the full pass.

`--prompt net` against `run_full`'s classical-seeded masks, 562 frames of all five clips: IoU p5 0.9727
/ p50 0.9910 / p95 0.9944, `zero_iou_rate` and `low_iou_rate` 0.000, fractions 0.2002 vs 0.2014.

Run the bench in a **fresh container**: a profile measured right after a long run in the same container
came out ~14% slower (`frame_net_live` 66.06 ms / 15.1 fps against 57.93 ms / 17.3 fps fresh), so a
quoted `p50` has to say which it was.

## Scripts here

- `scripts/bench.sh [profiles]` -- the bench, chowned, in one line.
- `scripts/live_audit.sh` -- rebuilds the 562-frame hardlinked sample, runs
  `cli.py --bbox net --sam2 --sam2-cache 0.02 --prompt net`, then `compare_masks.py --against run_full`.
- `scripts/config_probe.py` -- what a knob is worth on the live path without touching repo code:
  `OMP_NUM_THREADS`, `TORCH_ALLOW_TF32_CUBLAS_OVERRIDE`, `PYTORCH_CUDA_ALLOC_CONF`, SAM 2's
  `ImageEmbeddingCache(max_change=, max_age=)`, `torch.backends.cudnn.benchmark`, TF32 matmul.

## Configuration knobs: already swept, nothing to take

`scripts/config_probe.py` measured, over the same 262 frames in one process (p50 / p95 ms): shipped
`ImageEmbeddingCache(0.02, 30)` 57.93 / 58.99, `0.05/120` 57.63 / 58.54, `0.02/120` 57.45 / 58.36,
`cudnn.benchmark=True` 57.82 / 59.30, `matmul.allow_tf32=True` 57.90 / **68.82**,
`TORCH_ALLOW_TF32_CUBLAS_OVERRIDE=1` 57.83 / 59.11, `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True`
59.06 / 60.30, `OMP_NUM_THREADS` 1 vs default nothing. Best is 0.8%, inside the spread; the ones that
"win" do it by letting the SAM 2 embedding go staler; **avoid TF32** (same median, 59 -> 69 ms tail).
The encoder is the floor and the encoder has no knob. Do not re-run this sweep to look for a win -- run
it only after a torch/SAM version change.

## The trap that produces a silent zero

`compare_masks.py --against` resolves the *other* run's mask file name out of this run's record, and
`cli.py` names masks by the frame path **folded against the `--frames` root it was given**. Two runs
made with different root depth (`.../frames` vs `.../frames/wd_full`) produce `wd_full_raw_..._` vs
`raw_..._` stems, and the comparison prints `compared=0 missing=562`. Always check `compared > 0`, and
pass both runs the same depth.

## What is *not* worth measuring again

fp16 nets and batching were already measured (`INFERENCE.md` -> *How fast is it?*): fp16 halves the net
(9.2 -> 3.8-5.1 ms, boxes unchanged) and batching the net is worthless (compute-bound). Cropping or
downscaling to speed SAM 2 up is a dead end -- the processor resizes every input to a 1024-long-side
tensor, so 1920x1080 and 384x216 both cost ~70 ms. `compare_masks.py --mode centre` (single interior
point) is the honest way to compare the two stages without the prompts making them agree by
construction.
