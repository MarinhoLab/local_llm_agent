# MEMORIES.md

> **Note (2026-10): the two 27B DGX stacks — `dgx_spark_host/qwen38-27b-nvfp4/`
> and `dgx_spark_host/qwen38-27b-bf16/` — have been removed as unused.**
> `dgx_spark_host/qwen38-flash-next-fp4/` is the only remaining DGX-side stack.
> Entries below that describe the "three sibling stacks", their per-stack
> `MAX_NUM_SEQS`/`GPU_MEMORY_UTILIZATION` values, or their container names are
> kept as history and no longer describe anything in the repo.

A persistent, append-friendly record of **what we tried, what worked, and why**
for this repo. New findings are appended to
[Investigation log](#investigation-log) rather than rewriting history.

---

## Investigation log

### 2026-09 — Checkpoint swap: official FP8 → NVIDIA NVFP4, vLLM → nightly

The `dgx_spark_host/` stack moved away from the official FP8 checkpoint to
NVIDIA's repack, and the pinned vLLM image to a nightly build. This entry
records the current state so the README/AGENTS tuning notes do not read as if
the old FP8 setup were still live.

**What changed in `dgx_spark_host/`:**

- `Dockerfile`: `MODEL_NAME` is now `nvidia/Qwen3.8-27B-NVFP4` (was
  `Qwen/Qwen3.8-27B-FP8`); `FROM` is now `vllm/vllm-openai:nightly` (was pinned
  `vllm/vllm-openai:v0.28.0-ubuntu2404`); `GPU_MEMORY_UTILIZATION` is now `0.80`
  (was `0.85`). `MAX_NUM_SEQS` is `8`, `NUM_SPEC_TOKENS` is `5`, `SPEC_METHOD`
  is `mtp`.
- `entrypoint.sh`: `--kv-cache-dtype fp8_e4m3` (was `fp8`); `--seed 0` added;
  speculative decoding is back on via
  `--speculative-config '{"method":"mtp","num_speculative_tokens":5}'`.
  Removed from an earlier revision and **not re-added**: `--dtype auto`,
  `--async-scheduling`, `--load-format fastsafetensors`, and the
  `ENABLE_LONG_CONTEXT`/YaRN 1M-token switch.

**Why (per the commit messages):** the NVFP4 checkpoint was tried to merge the
server settings toward the values in the model card; the pinned v0.28.0 image
was swapped to `nightly` because the `qwen3_5` hybrid-attention architecture and
Qwen MTP / fused-decode kernels track the nightly line rather than a stable
tag.

**Verified checkpoint facts** (`nvidia/Qwen3.8-27B-NVFP4`, cross-checked against
the Hugging Face `config.json` / index / `hf_quant_config.json`):

- It is an **NVIDIA Model Optimizer** quantization (`quant_method: modelopt`,
  `quant_algo: MIXED_PRECISION`) of the official `Qwen/Qwen3.8-27B` base:
  linear-attention + full-attention projections are **FP8** (FP8 weight +
  dynamic FP8 input activation), the MLP and `lm_head` are **NVFP4**
  (`group_size: 16`). Total weight download is **~22 GB** (was ~27 GB for the
  FP8 repack).
- `model_type` is **`qwen3_5`**, `architectures` is
  `Qwen3_5ForConditionalGeneration`, with a `vision_config` and
  `language_model_only: false` — a native VLM (image + video), which is why the
  entrypoint keeps `--limit-mm-per-prompt '{"image":4}'` and there is no
  `--language-model-only` flag.
- It ships a **1-layer MTP head**: `text_config.mtp_num_hidden_layers: 1`, with
  `mtp.layers.0.*` tensors in `model.safetensors.index.json`. So MTP
  speculative decoding needs no separate draft model.
- `text_config.max_position_embeddings` is **262144** (the native context the
  stack serves; `--max-model-len` is fixed at `MAX_MODEL_LEN`).
- `hf_quant_config.json` sets `kv_cache_quant_algo` to **`None`** for this
  NVFP4 repack — the checkpoint does **not** itself request FP8 KV, so the
  entrypoint sets `--kv-cache-dtype fp8_e4m3` explicitly. (The FP8 model card's
  `kv_cache_quant_algo: FP8` note applied to the previous `Qwen/Qwen3.8-27B-FP8`
  checkpoint, not this one.)

**Docs brought back in sync (this change):** the `dgx_spark_host` env-var table
and tuning notes in `README.md`, the project overview + Key-tuning-decisions in
`AGENTS.md` (model, vLLM image, image-inputs, `--kv-cache-dtype`, context), the
opencode display name (`Qwen3.8-27B-NVFP4`) in `opencode_client/example.env`,
`opencode.example.json`, and `scripts/lib_vllm.sh`, the LLM-profile example in
the retired client's README, and the `docker-usage` skill (model + ~22 GB
download size). No code changed — `entrypoint.sh`, `Dockerfile`, `compose.yml`,
and the client scripts were already on the NVFP4/nightly path; only the prose
was stale.

**Caveats / things to re-verify on the real Spark:** the `nightly` base image
is unpinned, so a rebuild can drift — record the working nightly tag if
reproducible builds are needed. The "~2x decode" figure for MTP at
`NUM_SPEC_TOKENS=5` was carried over from the earlier FP8 measurements; re-measure
if the NVFP4 repack changes decode behaviour.

### 2026-10-02 — Restructure: one self-contained stack folder per model

Requested: fully isolate the three DGX-side stacks — the two Qwen3.8-27B
models must not share parameters or code. The `MODEL_CONFIG` switch (which
shared one `Dockerfile`/`entrypoint.sh`/`compose.yml` between `nvfp4` and
`b16`) was removed and replaced with one self-contained folder per stack:

- `dgx_spark_host/qwen38-27b-nvfp4/` — `Dockerfile` (defaults: `MODEL_NAME=
  nvidia/Qwen3.8-27B-NVFP4`, `GPU_MEMORY_UTILIZATION=0.80`), `entrypoint.sh`,
  `compose.yml` (container `dgx-qwen-nvfp4-vllm`), `README.md` with its own
  env table and tuning notes. Served alias `qwen-local`.
- `dgx_spark_host/qwen38-27b-b16/` — independent copy with `MODEL_NAME=
  Qwen/Qwen3.8-27B` and `GPU_MEMORY_UTILIZATION=0.70` (larger BF16 weights).
  Container `dgx-qwen-b16-vllm`. Served alias `qwen-local`.

The old shared `dgx_spark_host/Dockerfile`, `entrypoint.sh`, and
`compose.yml` were deleted; `MODEL_CONFIG` no longer exists anywhere. A thin
`dgx_spark_host/README.md` index now lists the three stacks (all port 8000,
run one at a time). Docs updated: top-level `README.md` (stack table, run
commands, per-stack pointers), `AGENTS.md` (overview, stack list, constraints,
Key tuning decisions, Common commands, sanity checks, conventions),
the retired client's README (LLM-profile note), the `docker-usage` skill
(server row + bring-up + tunnel bullets).

**Consequence for existing Spark deployments:** the compose project name and
container name change (`dgx-qwen-vllm` → `dgx-qwen-nvfp4-vllm` /
`dgx-qwen-b16-vllm`), and each stack's `.env` (e.g. `HF_TOKEN`) now lives in
the stack's own folder — move it when redeploying.

**Verification:** `bash -n` on all entrypoints; stub-`vllm` dry-runs of the
nvfp4 and b16 entrypoints (correct model/memory flags per stack); `docker
compose config` renders for all three stacks.

### 2026-10-02 — Fact-check fixes for the per-stack restructure


Checked against the Hugging Face API and the model cards:
- `.env` overrides never reached the containers: compose only used `.env` for
  `${...}` interpolation, so `GPU_MEMORY_UTILIZATION`, `MAX_NUM_SEQS`,
  `HF_TOKEN`, ... were silently ignored (this predates the restructure). Each
  stack's compose now has an optional `env_file: .env`.
- The BF16 README said 0.70 is lower *because* the weights are larger; the
  fraction caps weights + KV together, so larger weights shrink KV at a given
  fraction. 0.70 still leaves ~25 GiB of fp8 KV (~32 KiB/token, ~3 full
  262144-token sequences); the rationale was corrected, the value kept.
- Stale references to the removed shared `dgx_spark_host/compose.yml`,
  `dgx-qwen-vllm`, and `MODEL_CONFIG` in the docker-usage skill and
  `opencode_client/example.env` were updated.

**Verification:** `bash -n` + `shellcheck -S warning` on all scripts;
`docker compose config` for all three stacks with and without a `.env` (the
`.env` values now appear in the container environment, 0 of them before). Not
run on a GPU.

### 2026-10-02 — `qwen38-27b-b16` renamed to `qwen38-27b-bf16`

The folder serves the BF16 checkpoint, so "b16" was a misnomer. Renamed the
folder to `dgx_spark_host/qwen38-27b-bf16/`, the compose service to
`qwen-bf16-vllm`, and the container to `dgx-qwen-bf16-vllm`, and updated every
reference (READMEs, `AGENTS.md`, the docker-usage skill,
`opencode_client/example.env`). Earlier MEMORIES entries that say `b16` are
history. Migration: `docker compose down` the old stack from the old folder
before switching (a running `dgx-qwen-b16-vllm` would still hold port 8000),
and move any `.env` / `hf-cache` from the old folder into the new one.

**Verification:** `bash -n` on the entrypoint; `docker compose config` renders
with service `qwen-bf16-vllm` / container `dgx-qwen-bf16-vllm`; no `b16`
references remain outside this history file.

### 2026-10-02 — BF16 stack `GPU_MEMORY_UTILIZATION` standardized to 0.80

Requested: use the same `GPU_MEMORY_UTILIZATION` as the NVFP4 stack. The
`qwen38-27b-bf16` default is now 0.80 (was 0.70). Since the fraction caps
weights + KV together, this grows the BF16 KV pool from ~25 GiB to ~38 GiB
(~four full 262144-token sequences at ~32 KiB/token fp8 KV). Updated the
stack's `Dockerfile` and README and `AGENTS.md`.

**Verification:** `docker compose config` + stub-`vllm` dry-run of the BF16
entrypoint emits `--gpu-memory-utilization 0.80`. Not run on a GPU.

### 2026-10-02 — BF16 stack `MAX_NUM_SEQS` limited to 4

Requested: since the BF16 KV pool (~38 GiB at `GPU_MEMORY_UTILIZATION=0.80`)
holds only about four full 262144-token sequences, cap concurrency there at
4. `qwen38-27b-bf16` now defaults to `MAX_NUM_SEQS=4` (was 8); the NVFP4
stack stays at 8. Updated the stack's `Dockerfile` and README and
`AGENTS.md`. Sequences share the KV pool, so with short contexts it can be
raised again via `.env`.

**Verification:** stub-`vllm` dry-run of the BF16 entrypoint emits
`--max-num-seqs 4`. Not run on a GPU.
### 2026-10-21 — Third DGX stack: `qwen38-flash-next-fp4`

Added `dgx_spark_host/qwen38-flash-next-fp4/`, serving
**[`nvidia/Qwen3.8-Flash-Next-FP4-Local`](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-FP4-Local)**
— NVIDIA's official QAD (quantization-aware distillation) NVFP4/MXFP8
quantization of `Qwen/Qwen3.8-Flash-Next` (125B multimodal MoE, 6B active,
+51B n-gram/PLE table, +4B MTP; ~96 GiB on disk), released 2026-10-05 and
validated by NVIDIA on the DGX Spark. It replaces an earlier community
Flash-Next recipe that has been removed from the repo. NVIDIA's model card is
the source of truth for the pinned values.

**What was added:** a fully isolated stack in the repo's standard shape
(`Dockerfile` with all `ENV` defaults, `entrypoint.sh`, `compose.yml`,
`README.md`). Base image is the community B12X container NVIDIA prescribes,
`eugr/spark-vllm-b12x:latest` (upstream vLLM cannot yet read the checkpoint's
compressed NVFP4 scale factors). `entrypoint.sh` mirrors the model card's DGX
Spark serve command — `--load-format b12x --quantization modelopt_mixed`, the
`b12x` GDN/linear/MoE backends, `--mamba-cache-mode align`, `--block-size 16`,
`--kv-cache-dtype fp8`, `--max-num-seqs 8`, `--max-num-batched-tokens 4096`, MTP
depth 4, `--tool-call-parser qwen3_xml`, `--reasoning-parser qwen3`,
`--no-enable-flashinfer-autotune` and
`--compilation-config '{"pass_config":{"fuse_act_quant":true}}'` — plus the
card's `VLLM_*`/`B12X_*` environment, where `VLLM_PLE_TABLE_MEMORY=disk` with
`B12X_DISK_BACKEND=io_uring` keeps the PLE table in NVMe (`CUTE_DSL_ARCH=sm_121a`
for GB10). Serving identity is unchanged: alias **`qwen-local`** on port
**8000**, so the macOS clients still need no changes when switching stacks.

**Consequences for existing Spark deployments:** stop and remove any older
Flash-Next container on the Spark before starting this one (port 8000), and
reclaim its old model assets. The new stack downloads ~96 GiB into its own
`hf-cache` on first start and needs the NVIDIA Open Model Agreement accepted
plus `HF_TOKEN` in its `.env`.

**Docs updated:** top-level `README.md`, `AGENTS.md`, `dgx_spark_host/README.md`,
both 27B siblings' "three sibling stacks" lists, the retired client's README
(model-ID note) and the `docker-usage` skill. `.gitignore` now also ignores the
per-stack `*cache/` and `.triton/` mount directories.

**Verification:** `bash -n` on the new entrypoint; `docker compose config`
renders the stack (image, environment, mounts, ulimits); stub-`vllm` dry-runs of
`entrypoint.sh` for the defaults and for `MTP=0`, `PREFIX_CACHE=0` and a `.env`
override.

### 2026-10-21 — Fix: invalid `COMPILATION_CONFIG` JSON in the flash-next stack

The Dockerfile `ENV COMPILATION_CONFIG={"pass_config":...}` line had its quotes
stripped by Docker, so vLLM exited with `Invalid JSON`. The `ENV` line was
removed; `entrypoint.sh` supplies the default. Do not set JSON via Dockerfile
`ENV`.

