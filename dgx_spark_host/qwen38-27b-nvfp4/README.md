# Qwen3.8-27B NVFP4 (`qwen38-27b-nvfp4`)

Self-contained stack that serves **`nvidia/Qwen3.8-27B-NVFP4`** — NVIDIA Model
Optimizer's NVFP4 + FP8 mixed-precision quantization of the official
`Qwen/Qwen3.8-27B` base (~22 GB) — via vLLM on the DGX Spark.

The DGX Spark host offers three sibling stacks, one folder per model (see
`../README.md`); they are fully isolated (own image, compose, entrypoint,
defaults) and all bind port 8000 — run only ONE at a time:

- `../qwen38-27b-nvfp4/` — this stack (NVFP4, ~22 GB)
- `../qwen38-27b-bf16/` — the official `Qwen/Qwen3.8-27B` in BF16 (~55 GB)
- `../flash_ultrafast/` — the Qwen3.8 Flash DGX UltraFast v16b recipe

## Run

```bash
cd dgx_spark_host/qwen38-27b-nvfp4
docker compose -f compose.yml up --build     # first run downloads ~22 GB
```

The API is available at `http://localhost:8000/v1`, served under the alias
**`qwen-local`**. For shared networks, bind to `127.0.0.1` in `compose.yml`.

## Environment Variables

Defaults live in `Dockerfile`; override via this folder's `.env` (passed into
the container by `compose.yml`'s `env_file`) or `compose.yml`.

| Variable                 | Default                     | Description                                              |
|--------------------------|-----------------------------|----------------------------------------------------------|
| `MODEL_NAME`             | `nvidia/Qwen3.8-27B-NVFP4` | Hugging Face model to serve                              |
| `SERVED_MODEL_NAME`      | `qwen-local`              | Alias exposed by the API                                 |
| `HOST`                   | `0.0.0.0`                 | Bind address                                             |
| `PORT`                   | `8000`                    | Listen port                                              |
| `API_KEY`                | `local-dgx-key`           | API key for authentication                               |
| `MAX_MODEL_LEN`          | `262144`                  | Maximum sequence length (native max of the checkpoint)   |
| `GPU_MEMORY_UTILIZATION` | `0.80`                    | Fraction of GPU memory to use                            |
| `MAX_NUM_SEQS`           | `8`                       | Maximum concurrent sequences                             |
| `MAX_NUM_BATCHED_TOKENS` | `8192`                    | Max tokens per batch                                     |
| `SPEC_METHOD`            | `mtp`                     | Speculative decoding method (the checkpoint ships an MTP head) |
| `NUM_SPEC_TOKENS`        | `5`                       | Speculative draft tokens; ~2x decode speed at 3-5, tune per workload |
| `HF_CACHE`               | `./hf-cache`              | Volume mount path for Hugging Face cache                 |
| `HF_TOKEN`               | *(unset)*                 | Hugging Face token for gated models                      |

## Tuning notes (DGX Spark, GB10, 128 GB unified memory, LLM-only box)

- **Model**: `nvidia/Qwen3.8-27B-NVFP4` (~22 GB). It ships a 1-layer MTP head,
  so MTP speculative decoding needs no separate draft model (~2x decode speed
  on GB10). It is a native vision-language model (`qwen3_5`, image + video) and
  image inputs stay enabled via `--limit-mm-per-prompt '{"image":4}'`.
- **Memory**: `GPU_MEMORY_UTILIZATION=0.80` assumes the Spark runs nothing but
  the LLM; lower it if you host other workloads.
- **Concurrency**: `MAX_NUM_SEQS=8`; early GB10 measurements suggested the
  per-token bandwidth tax above ~4 in-flight decodes outweighed continuous
  batching — drop it back down if multi-agent latency regresses.
- **Context**: 262144 is the native max (`text_config.max_position_embeddings`).
