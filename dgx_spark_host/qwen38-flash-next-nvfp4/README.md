# Qwen3.8-Flash-Next NVFP4 — the official-quant stack

Serves **`nvidia/Qwen3.8-Flash-Next-NVFP4`** — NVIDIA's official
mixed-precision quant of `Qwen/Qwen3.8-Flash-Next` (NVFP4 routed experts, FP8
MTP experts and PLE n-gram table, ~133 GB) — on one DGX Spark (GB10) via a
stock `vllm/vllm-openai:nightly`. It replaced a patched-image community recipe
on grounds of checkpoint provenance and maintainability rather than measured
speed: that stack was observed here at 38 tok/s single-stream against its
recipe's claimed 74, and published single-Spark numbers for this checkpoint
cluster around the same 40–50 range.

## Run

```bash
cd dgx_spark_host/qwen38-flash-next-nvfp4
docker compose -f compose.yml up --build
```

First boot downloads ~133 GB into `./hf-cache` (hours on slow NVMe; set
`HF_TOKEN` in `.env` — the repo is public but XET throughput needs it).
Served as the same `qwen-local` alias on port 8000 as the other stacks; run
only one stack at a time.

## Environment variables (defaults in `Dockerfile`, override via `.env`)

| Variable | Default | Notes |
|---|---|---|
| `MODEL_NAME` | `nvidia/Qwen3.8-Flash-Next-NVFP4` | gated-weight download |
| `MAX_MODEL_LEN` | `262144` | native; 1,048,576 possible with `ROPE_SCALING` (see Tuning notes) |
| `GPU_MEMORY_UTILIZATION` | `0.80` | repo-wide ceiling; PLE placement interacts — see below |
| `MAX_NUM_SEQS` | `4` | 6 in the published recipes; 4 matches the repo's bandwidth-tax rule |
| `MAX_NUM_BATCHED_TOKENS` | `4096` | published recipes' value for this checkpoint |
| `SPEC_METHOD` / `NUM_SPEC_TOKENS` | `mtp` / `3` | NVIDIA's snippet uses 1; recipes use 3–4 |
| `PLE_CPU_OFFLOAD` | `1` | exports `VLLM_PLE_CPU_OFFLOAD=1`; flip to `0` only if the engine OOMs |
| `ROPE_SCALING` | empty | e.g. `{"rope_type":"yarn","factor":4.0,"original_max_position_embeddings":262144}` with `MAX_MODEL_LEN=1048576` |

## Tuning notes

- **The 51 GB PLE n-gram table decides whether this fits.** With
  `VLLM_PLE_CPU_OFFLOAD=1` it stays out of the engine's memory budget;
  otherwise a single copy sits in the unified pool **and** ~57 GB of BF16
  attention/shared-expert weights are loaded, and the 0.80 utilization target
  (≈97 GiB) can fail at boot. This is the first thing to check if the engine
  dies during load.
- **Patches are the risk, not the flags.** HF's model card requires a vLLM
  nightly at/after `d4d703ca` (no-MTP serving) and notes MTP needs PR #55513 —
  that PR is **merged**, so a current `nightly` should satisfy both. It also
  lists an open issue (`vllm#60275`): PLE gather fails under CUDA-graph
  piecewise compile (workaround `compilation_config={"mode":"eager"}`), and
  recommends pinning `transformers` to 4.57.6 for exact sampling.
  Published single-Spark recipes add their own patch series on top
  (`salient-data/qwen38-next-dgx-recipe`: 14 patches, all tied to upstream
  PR numbers; kubesimplify/tonyd2wild: disk-backed PLE gather). **This stack
  ships none of them** — first boot is the experiment; if it fails, their
  patch series is the documented fallback.
- **Speed expectations (others' measurements, one GB10):** median ~37–54,
  peak ~64 tok/s single stream; prefill ~1,700–2,800 tok/s; ~1M-token KV pool
  (≈4 concurrent full-context sequences) with FP8 KV. vLLM tool-eval reported
  89/100 for this checkpoint — above the 86 the 27B scores here.
- **Concurrency**: the published recipes run 6 sequences at 4096-token prefill
  chunks with `torch.compile` off; with compile on, prefill chunking tanks
  decode to 8–15 tok/s. This stack's stock entrypoint leaves compile at the
  nightly default — if decode is anomalously slow, try
  `--enforce-eager` via `.env` before tuning anything else.

## Sources of truth

- Checkpoint: <https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4>
  (requirements, serve snippet, quantization details)
- NVIDIA forum, measured single-Spark numbers + benchmark:
  <https://forums.developer.nvidia.com/t/qwen3-8-flash-next-on-1-2-and-4-dgx-sparks-with-nvidias-official-nvfp4-quant-64-tok-s-peak-single-stream/382476>
- Community Spark recipes (patch series, launchers, KV ledgers):
  <https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks> (TP2/TP4;
  single-Spark lane documented inside),
  <https://github.com/tonyd2wild/Qwen3.8-Flash-Next-NVFP4-DGX-Spark>,
  <https://github.com/salient-data/qwen38-next-dgx-recipe>
