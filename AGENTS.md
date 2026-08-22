# AGENTS.md

Guidance for AI agents (and humans) working in this repository.

## Project overview

`local_llm_agent` runs **Qwen3.8-27B (NVFP4)** on an **NVIDIA DGX Spark** (GB10, 128 GB
unified memory, aarch64) via vLLM, and drives it from **macOS** through **OpenHands**
over an SSH tunnel.

Two self-contained stacks:

- `dgx_spark_host/` — vLLM server (Docker image + compose + entrypoint). Serves the
  model at `:8000/v1` on the Spark.
- `macos_client/` — OpenHands container (Docker) plus a DuckDuckGo MCP search service.
  Reaches the Spark's vLLM at `http://host.docker.internal:8000/v1` through the SSH
  tunnel; UI at `http://localhost:3000`.

## Deployment constraints (do not change without a reason)

- **Single user, at most 4 concurrent agents.** `MAX_NUM_SEQS=4` is deliberate: above
  4 in-flight decodes the per-token memory-bandwidth tax on GB10 outweighs
  continuous-batching gains.
- **The DGX Spark runs the LLM only.** `GPU_MEMORY_UTILIZATION=0.8` relies on nothing
  else sharing the unified memory pool. If the Spark gains other workloads, lower it.
- Quality over speed: agentic tool-calling quality (vLLM tool-eval ~90/100 for this
  model) is prioritized over raw tok/s.

## Key tuning decisions (why they exist)

- **Model**: `unsloth/Qwen3.8-27B-NVFP4`. NVFP4, 23.4 GB, ships a built-in **MTP head**
  (registered in `model.safetensors.index.json`), so speculative decoding needs only
  `--speculative-config '{"method":"mtp","num_speculative_tokens":5}'` — no `model`
  field, no separate download. MTP roughly doubles decode (~11 -> ~24 tok/s on GB10).
  Earlier Unsloth revision had a tokenizer bug (prompts truncated at 2048 tokens);
  the published revision fixed it — if you pin a snapshot, check
  `tokenizer.json["truncation"] is None`.
- **vLLM image**: `vllm/vllm-openai:v0.27.1-ubuntu2404` (multi-arch, pulls arm64 on
  the Spark). Qwen3.8 needs a recent release (the `qwen3_5` hybrid-attention
  architecture); v0.24.0 predates it.
- **`--language-model-only`**: Qwen3.8 is a VLM; dropping the ~0.5 GB vision tower
  buys KV cache. Remove the flag if image inputs are needed.
- **`--kv-cache-dtype fp8`**: halves KV memory (~37 KB/token including the
  DeltaNet linear-attention state). The checkpoint ships `kv_cache_quant_algo: FP8`,
  so keep it — disabling it degrades outputs.
- **Parsers**: `--tool-call-parser qwen3_coder` (the chat template emits
  <tool_call> tags whose payload contains the function name and parameters, e.g. a
  <function=name> line) and `--reasoning-parser qwen3` (emits
  <think>...</think> blocks). Do not switch either without checking the
  model's `chat_template.jinja`.
- **Context**: 262144 is native. `ENABLE_LONG_CONTEXT=1` in `entrypoint.sh` switches
  to 1,048,576 via YaRN (factor 4.0, must land in `text_config.rope_parameters` and
  include `mrope_*` fields or multimodal RoPE breaks). It is static and costs ~36 GiB
  of KV, so it stays off by default.
- **OpenHands**: `AGENT_SERVER_IMAGE_TAG` must track the agent-server bundled in the
  `docker.openhands.dev/openhands/openhands:1.8` image (1.42.1). Older pins cause
  version-skew failures.
- **DuckDuckGo MCP**: the SSE client is the OpenHands agent-server inside the
  openhands container, which dials http://host.docker.internal:8001/sse. The
  server's DNS-rebinding allowlist must accept host.docker.internal
  (localhost/127.0.0.1 cover a non-Docker OpenHands on the Mac).

## Common commands

```bash
# DGX Spark side
cd dgx_spark_host
docker compose -f compose.yml up --build     # first run downloads ~24 GB of weights

# macOS side (SSH tunnel first: ssh -N -L 8000:localhost:8000 USER@DGX_SPARK_IP)
cd macos_client
cp example.env .env
mkdir -p workspace openhands-state
docker compose up
```

Sanity checks that do not need a GPU:

```bash
bash -n dgx_spark_host/entrypoint.sh
python3 -c "import yaml; yaml.safe_load(open('macos_client/compose.yml'))"
# entrypoint dry-run: put a stub `vllm` script in PATH and run entrypoint.sh
```

## Repo layout & conventions

- `.env` files (e.g. `dgx_spark_host/.env`) are local-only and hold secrets
  (`HF_TOKEN`). `macos_client/example.env` is the template; copy it to `.env`.
- `context/` holds exported OpenHands conversation events and is git-ignored —
  never commit it.
- All runtime defaults live as `ENV` in `dgx_spark_host/Dockerfile`;
  `entrypoint.sh` only composes the `vllm serve` command from those variables.
  Keep the README's env-var tables in sync when adding or changing defaults.
- Config changes should stay overridable via environment variables — no
  hard-coded per-machine values.
