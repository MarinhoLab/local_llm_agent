# AGENTS.md

Guidance for AI agents (and humans) working in this repository.

## Project overview

`local_llm_agent` runs **Qwen3.8-27B (FP8, official `Qwen/Qwen3.8-27B-FP8`)** on an **NVIDIA DGX Spark** (GB10, 128 GB unified memory, aarch64) via vLLM, and drives it from **macOS** through **OpenHands**
over an SSH tunnel.

Two self-contained stacks:

- `dgx_spark_host/` — vLLM server (Docker image + compose + entrypoint). Serves the
  model at `:8000/v1` on the Spark.
- `agent_canvas/` — [Agent Canvas](https://docs.openhands.dev/openhands/usage/agent-canvas/setup)
  all-in-one image (UI + agent-server + automation server + ingress) on macOS, also
  reaching vLLM through the tunnel; UI at `http://localhost:8010/canvas`. No
  `docker.sock`, no GPUs — canvas agents are untrusted and the container is the
  sandbox boundary.

## Deployment constraints (do not change without a reason)

- **Single user, small concurrent-agent count.** `MAX_NUM_SEQS` is 8 in this
  stack. Earlier GB10 measurements suggested the per-token memory-bandwidth
  tax above ~4 in-flight decodes outweighed continuous-batching gains, but the
  value was raised to 8 for multi-agent use; if multi-agent latency regresses,
  drop it back toward 4 via `.env`.
- **The DGX Spark runs the LLM only.** `GPU_MEMORY_UTILIZATION=0.85` relies on
  nothing else sharing the unified memory pool. If the Spark gains other
  workloads, lower it.
- Quality over speed: agentic tool-calling quality (vLLM tool-eval ~90/100 for this
  model) is prioritized over raw tok/s.

## Key tuning decisions (why they exist)

- **Model**: `Qwen/Qwen3.8-27B-FP8` (official Qwen checkpoint, fine-grained
  FP8 block-128, ~27 GB; the model card reports quality nearly identical to the
  original). It ships a built-in **MTP head** (the model card lists
  "MTP: trained with multiple steps", registered in
  `model.safetensors.index.json`), so speculative decoding needs only
  `--speculative-config '{"method":"mtp","num_speculative_tokens":5}'` — no
  `model` field, no separate download. MTP roughly doubles decode on GB10.
  (If you ever switch to `unsloth/Qwen3.8-27B-NVFP4` instead, check
  `tokenizer.json["truncation"] is None`: an early unsloth repack baked in a
  2048-token prompt truncation that the official Qwen repo does not have.)
- **vLLM image**: `vllm/vllm-openai:v0.28.0-ubuntu2404` (pinned, multi-arch,
  pulls arm64 on the Spark). Qwen3.8 needs a recent release (the `qwen3_5`
  hybrid-attention architecture; v0.24.0 predates it), and v0.28.0 also carries
  the Qwen MTP / fused GDN decode-kernel fixes. Pin a specific tag rather than
  `latest` so rebuilds do not drift.
- **Image inputs enabled**: Qwen3.8 is a native VLM (image + video). This stack
  keeps the vision tower and passes
  `--limit-mm-per-prompt '{"image":4}'`; there is no
  `--language-model-only` flag. (That flag was used while experimenting with
  the NVFP4 revision and was removed in favor of working image analysis.)
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
- **OpenHands / Agent Canvas images**: the `agent_canvas` stack uses the
  all-in-one `ghcr.io/openhands/agent-canvas` image, which bundles the
  agent-server — there is no separate agent-server image to pin and no
  `AGENT_SERVER_IMAGE_*` runtime variable (older OpenHands images did; that
  guidance is retired). `AGENT_CANVAS_TAG=latest` keeps the image current; pin a
  specific tag before a release if reproducibility matters.
- **LLM configuration (model, base URL, API key)**: the OpenHands V1 web app
  does **not** read `LLM_MODEL` / `LLM_BASE_URL` / `LLM_API_KEY` container env
  vars. It resolves the LLM and MCP servers from its own settings store (GUI:
  `Settings → LLM` / `Settings → MCP`), persisted in the state volume
  (`AGENT_CANVAS_STATE`, mounted at `/home/openhands/.openhands`). Those env
  vars are only honored by the V0/CLI path
  (`LLM.load_from_env` + `--override-with-envs`), and the agent-server config
  loader only parses `OH_*` prefixed vars (see `agent_server/config.py`
  `ENVIRONMENT_VARIABLE_PREFIX`). So the LLM profile is set in the Canvas UI
  (Settings → LLM) or via the V1 REST API — see the `agent_canvas` section of
  the README for the profile example. Rationale + verified API surface:
  `MEMORIES.md`.
- **MCP search servers**: web-search servers (e.g. Tavily, remote
  streamable-http, API key) are registered in OpenHands → Settings → MCP, or via
  the V1 REST API (`POST /api/v1/settings` with
  `agent_settings_diff.mcp_config`, which is applied wholesale — send the full
  desired map). Keep any MCP API key out of git.

## Common commands

```bash
# DGX Spark side
cd dgx_spark_host
docker compose -f compose.yml up --build     # first run downloads ~24 GB of weights

# Agent Canvas side (macOS, SSH tunnel first: ssh -N -L 8000:localhost:8000 USER@DGX_SPARK_IP)
cd agent_canvas
mkdir -p openhands-state projects
docker compose up -d          # UI: http://localhost:8010/canvas
```

Sanity checks that do not need a GPU:

```bash
bash -n dgx_spark_host/entrypoint.sh
python3 -c "import yaml; yaml.safe_load(open('agent_canvas/compose.yml'))"
# entrypoint dry-run: put a stub `vllm` script in PATH and run entrypoint.sh
```

## Repo layout & conventions

- `.env` files are local-only and hold secrets (`HF_TOKEN`) — they are
  git-ignored. `dgx_spark_host/` reads `HF_CACHE`/`HF_TOKEN` from `.env` when
  present (compose defaults work without it). `agent_canvas/example.env` is the
  Canvas stack's tracked template — copy it to `.env`.
- `context/` holds exported OpenHands conversation events and is git-ignored —
  never commit it.
- `agent_canvas/openhands-state/` and `agent_canvas/projects/` are runtime
  mounts (state + project files), git-ignored. When driven from the OpenHands
  sandbox, sync tracked files to the Mac checkout first via
  `agent_canvas/sync_to_mac.sh` (the sandbox filesystem is not bind-mountable
  by the Mac's Docker daemon); the Mac-side `.env` uses Mac-absolute bind paths.
- All runtime defaults live as `ENV` in `dgx_spark_host/Dockerfile`;
  `entrypoint.sh` only composes the `vllm serve` command from those variables.
  Keep the README's env-var tables in sync when adding or changing defaults.
- Config changes should stay overridable via environment variables — no
  hard-coded per-machine values.
