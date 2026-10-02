# Qwen3.8 Flash · DGX UltraFast (`flash_ultrafast`)

Third DGX-side configuration: the [dime-online/qwen3.8-Flash-DGX-UltraFast](https://github.com/dime-online/qwen3.8-Flash-DGX-UltraFast)
**v16b** serving recipe, run through this repo's `compose.yml`.

Unlike the two `MODEL_CONFIG` options in `../` (`nvfp4` / `b16`, which are plain
Hugging Face checkpoints served by the standard `vllm/vllm-openai:nightly`
image), this is a **custom serving recipe**: a patched vLLM image (CUDA 13.0,
low-latency SM12x GEMM, custom Mamba/PLE/MTP kernels) serving a W4A16/FP8
AutoRound-hybrid checkpoint whose PLE table is memory-mapped from storage, with
a dense T80 MTP drafter. The speed comes from that drafter plus a leaner
per-step path — **not** from lower-bit target weights (every drafted token is
verified by the target model via block rejection, so output quality is
preserved).

## Provenance

- Recipe: [dime-online/qwen3.8-Flash-DGX-UltraFast](https://github.com/dime-online/qwen3.8-Flash-DGX-UltraFast),
  Apache-2.0. Based on
  [Saren-Arterius/qwen3.8-Flash-DGX-AutoRound](https://github.com/Saren-Arterius/qwen3.8-Flash-DGX-AutoRound).
- Weights: `Saren/Qwen3.8-Flash-Next-W4A16-AutoRound-hybrid` (pinned revision) +
  `Saren/Qwen3.8-Flash-Next-ple-table-fp8` (pinned revision). Keep whatever
  license terms the weights carry.
- This substack does **not** vendor the upstream image build, patches, or
  weights. The heavy one-time work is delegated to the upstream scripts by
  `setup-upstream.sh`.

## Upstream claims (v16b, one GB10) — re-verify on your hardware

- **74.1 tok/s** single stream, **212.2 tok/s** aggregate at 8 streams
  (copy-heavy, low-effort workload, shared cached prefix).
- Cold prefill up to **~4,016 tok/s** (16k), 2–3.4× faster than the base recipe.
- 93% on a 492-item eval suite; teacher-forced agreement with the original
  checkpoint within the noise band.
- Model residency **~71 GiB**, KV pool **16 GB** at the pinned 262,144-token
  context.

These are the upstream's measurements. The CJK caveat applies: the 65,536-id
draft vocabulary is English/code-weighted, so non-English output gets lower
draft *acceptance* (slower decode) but unchanged output quality.

## One-time setup (on the Spark)

Requires ~135 GB of free disk, the NVIDIA Container Toolkit, and a
CUDA-13-compatible driver. Downloads are large; the build is long.

```bash
cd dgx_spark_host/flash_ultrafast
./setup-upstream.sh        # clone upstream, download weights, build image + drafter, install vocab
```

`setup-upstream.sh` is idempotent per step and can be re-run; use `SKIP_CLONE=1
SKIP_DOWNLOAD=1 SKIP_IMAGE=1 SKIP_MODEL=1` to bypass what is already done.

## Run

```bash
cd dgx_spark_host/flash_ultrafast
docker compose -f compose.yml up --build
# wait for load, then:
curl http://localhost:8000/v1/models
```

Served model alias is **`qwen`** (not `qwen-local`). It accepts text, image
(`image_url`) and video (`video_url`).

> **Port 8000 is shared** with the `nvfp4`/`b16` configurations. Run only ONE
> of the three DGX configurations at a time on the Spark — stop the others
> first (`docker compose -f ../compose.yml down` for the MODEL_CONFIG stack).

## Clients

The Agent Canvas / OpenCode clients key off the served model alias, so point
them at model **`qwen`** on this stack (base URL and API key unchanged). See
`../README.md` for the Agent Canvas LLM-profile example and
`../../opencode_client/example.env` for OpenCode (`OPENCODE_MODEL_ID=qwen`).

## Overriding the pinned values

The promoted v16b values are the defaults here; they are overridable via
`.env` in this directory (sourced by `compose.yml` and `entrypoint.sh`):

| Variable | v16b default | Meaning |
|---|---|---|
| `FLASH_IMAGE` | `qwen38-flash-dgx:iter6d-20260910` | Patched image (pinned by upstream) |
| `SERVED_NAME` | `qwen` | API model alias |
| `CTX` | `262144` | Max model length |
| `SEQS` | `8` | Max concurrent sequences |
| `GPU_MEM` | `0.01` | Fraction (KV is set explicitly, not by this fraction) |
| `KV_BYTES` | `16g` | Explicit KV pool |
| `MTP` | `3` | MTP draft depth (`0` disables speculative decoding) |
| `TOOL_PARSER` | `qwen3_xml` | Tool-call parser |
| `PREFIX_CACHE` | `1` | Prefix caching |
| `FLASH_MODEL_HOST` / `FLASH_TABLE_HOST` / `FLASH_VOCAB_HOST` | `~/models/...` | Host asset paths |

Per the upstream docs, changing any pinned value produces a new variant whose
speed and quality must be measured separately — the published numbers only
apply to the promoted v16b settings. Keep `GPU_MEM`, `KV_BYTES`, `SEQS`,
`MTP`, and the batched-token count at the promoted values if you want the
published throughput.
