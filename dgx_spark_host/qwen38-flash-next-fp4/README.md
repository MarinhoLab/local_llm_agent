# Qwen3.8 Flash Next FP4-Local (`qwen38-flash-next-fp4`)

Self-contained stack that serves **`nvidia/Qwen3.8-Flash-Next-FP4-Local`** —
NVIDIA Model Optimizer's QAD (quantization-aware distillation) NVFP4/MXFP8
build of `Qwen/Qwen3.8-Flash-Next`, ~96 GiB on disk — via vLLM on the DGX
Spark. This is the **largest model that fits one Spark**: a 125B-parameter
multimodal MoE (6B active, plus a 51B n-gram embedding table and a 4B MTP
module).

This is currently the only stack in `dgx_spark_host/` (see `../README.md`). It
is self-contained (own image, compose, entrypoint, defaults) and binds port
8000, so no other DGX stack may run at the same time.

## Provenance

- Checkpoint: [`nvidia/Qwen3.8-Flash-Next-FP4-Local`](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-FP4-Local)
  (NVFP4 routed experts via QAD, MXFP8 attention, FP8 PLE n-gram table, NVFP4
  MTP experts), released 2026-10-05. Governed by the [NVIDIA Open Model
  Agreement](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-agreement/);
  the `Qwen/Qwen3.8-Flash-Next` base is under the Qwen Community License 1.0.
- Image: [`eugr/spark-vllm-b12x`](https://hub.docker.com/r/eugr/spark-vllm-b12x)
  — the container NVIDIA prescribes for this checkpoint, built with the B12X
  kernels/loader for GB10. Needed because the checkpoint's compressed NVFP4
  scale factors are not yet supported by upstream `vllm/vllm-openai`.
- Serve flags and the `VLLM_*`/`B12X_*` environment follow the model card's
  **DGX Spark** recipe; upstream is the source of truth for those values.

## Run

```bash
cd dgx_spark_host/qwen38-flash-next-fp4
docker compose -f compose.yml up --build   # first run downloads ~96 GiB
# wait for the load (long: weight load + AOT compile), then:
curl http://localhost:8000/v1/models
```

The API is available at `http://localhost:8000/v1`, served under the alias
**`qwen-local`**. For shared networks, bind to `127.0.0.1` in `compose.yml`.

Downloads need `HF_TOKEN` in this folder's `.env` (the checkpoint is
gated-agreed: accept the NVIDIA Open Model Agreement on the model page first).
Set `HF_CACHE=/some/big/disk` there if the repo volume is too small.

## Environment Variables

Defaults live in `Dockerfile` (and are re-declared in `entrypoint.sh`);
override via this folder's `.env` (passed into the container by `compose.yml`'s
`env_file`) or `compose.yml`.

| Variable                 | Default                              | Description |
|--------------------------|--------------------------------------|-------------|
| `MODEL_NAME`             | `nvidia/Qwen3.8-Flash-Next-FP4-Local` | Hugging Face model to serve |
| `SERVED_MODEL_NAME`      | `qwen-local`                         | Alias exposed by the API |
| `HOST` / `PORT`          | `0.0.0.0` / `8000`                   | Bind address / listen port |
| `API_KEY`                | `local-dgx-key`                      | API key for authentication |
| `MAX_MODEL_LEN`          | `262144`                             | Max sequence length (the checkpoint's native max; raise together with `YARN_FACTOR` for long context) |
| `YARN_FACTOR`            | `0` (off)                            | Static YaRN scaling over the 262144 native window (Qwen base card). `2.0` ↔ `MAX_MODEL_LEN=524288`; `4.0` ↔ `1000000`; `0` disables. Can slightly hurt short-prompt quality, so it is opt-in |
| `GPU_MEMORY_UTILIZATION` | `0.8`                                | Fraction of the unified pool for weights + KV |
| `MAX_NUM_SEQS`           | `4`                                  | Max concurrent sequences (card uses 8; 4 matches ~1M-token KV pool at ~250K per agent) |
| `MAX_NUM_BATCHED_TOKENS` | `4096`                               | Max tokens per batch |
| `MTP`                    | `4`                                  | MTP speculative tokens; `0` disables (checkpoint ships the MTP module) |
| `KV_CACHE_DTYPE`         | `fp8`                                | KV cache dtype |
| `QUANTIZATION` / `LOAD_FORMAT` | `modelopt_mixed` / `b12x`          | ModelOpt mixed-precision path + B12X loader |
| `PLE_TABLE_MEMORY`       | `disk`                               | `disk` keeps the 51B n-gram table in NVMe (read via `DISK_BACKEND=io_uring`); `cpu`/other values follow the card's offload variants |
| `CUTE_DSL_ARCH`          | `sm_121a`                            | GB10 kernel arch |
| `TOOL_PARSER` / `REASONING_PARSER` | `qwen3_xml` / `qwen3`          | Tool-call / reasoning parsers from the card |
| `PREFIX_CACHE`           | `1`                                  | Prefix caching (`0` passes `--no-enable-prefix-caching`) |
| `FLASHINFER_AUTOTUNE`    | `0`                                  | `0` passes `--no-enable-flashinfer-autotune` (card value) |
| `COMPILATION_CONFIG`     | `{"pass_config":{"fuse_act_quant":true}}` | vLLM compilation config JSON |
| `HF_CACHE`               | `./hf-cache`                         | Host path for the HF weights cache |
| `VLLM_CACHE` / `FLASHINFER_CACHE` / `TRITON_CACHE` / `B12X_CACHE` | `./<name>-cache` | Host paths for the compile caches (speed up restarts) |
| `HF_TOKEN`               | *(unset)*                            | Hugging Face token (agreement-gated checkpoint) |

## Tuning notes (DGX Spark, GB10, 128 GB unified memory, LLM-only box)

- **Fitting 128 GB**: the ~96 GiB checkpoint includes a 51B-parameter n-gram
  (PLE) embedding table that each token reads only a handful of rows from. With
  `PLE_TABLE_MEMORY=disk` it stays in NVMe and the GPU-resident weights drop
  enough for the full 262144-token context; NVIDIA's card says a Spark can run
  with or without that offload, and quotes up to ~1M tokens of FP8 KV **with**
  it. `DISK_BACKEND=io_uring` needs the `seccomp/apparmor=unconfined` and ulimit
  settings in `compose.yml`.
- **Image inputs**: the checkpoint is a native VLM (`language_model_only:
  false`), so text, `image_url` and `video_url` are accepted. This stack does not
  pass `--limit-mm-per-prompt` (the card does not set it); add it in
  `entrypoint.sh` if you want to cap per-request images.
- **Concurrency**: `MAX_NUM_SEQS=4` (the card uses 8) with
  `MAX_NUM_BATCHED_TOKENS=4096`. NVIDIA quotes ~1M tokens of FP8 KV on the
  Spark with PLE offload, i.e. roughly 3-4 agents at the full 262144 context
  sharing one pool; 4 matches that. Check the startup log's `Maximum
  concurrency for 262,144 tokens per request` line; raise it via `.env` if
  agents usually run far below full context.
- **Throughput**: community measurements on one Spark put decode near 45-50
  tok/s single-stream at short context, decaying to ~33 tok/s around 32K of
  context, with prefill holding ~2.1K tok/s. Re-verify on your hardware —
  MTP acceptance moves these by a few tok/s.

> **Port 8000 is the shared DGX port.** Run only ONE DGX stack at a time —
> stop any other stack first (e.g. `docker compose -f ../<stack>/compose.yml down`).

## Clients

The Agent Canvas client keys off the served model alias, and this stack uses the
**`qwen-local`** alias, so clients need no changes (see `../README.md` for the
Agent Canvas LLM-profile example).
