# AGENTS.md

Guidance for AI agents (and humans) working in this repository.

## Project overview

`local_llm_agent` runs **Qwen3.8-27B (`nvidia/Qwen3.8-27B-NVFP4`, NVIDIA's NVFP4 + FP8 quantization of the official `Qwen/Qwen3.8-27B`)** on an **NVIDIA DGX Spark** (GB10, 128 GB unified memory, aarch64) via vLLM, and drives it from **macOS** through **OpenHands**
over an SSH tunnel (or a plain terminal via **OpenCode**).

Three self-contained stacks plus a notification sidecar:

- `dgx_spark_host/` — vLLM server (Docker image + compose + entrypoint). Serves the
  model at `:8000/v1` on the Spark.
- `agent_canvas_native/` — [Agent Canvas](https://docs.openhands.dev/openhands/usage/agent-canvas/setup)
  (UI + agent-server + automation server + ingress) running as local processes via
  Node.js ≥ 22.12 and `uv`, with **no Docker**; also reaches vLLM through the
  tunnel; UI at `http://localhost:8020`. Agents run as your user on the local
  filesystem. See `agent_canvas_native/README.md` for ports and overrides.
- `opencode_client/` — [OpenCode](https://opencode.ai) terminal client (no Docker) that
  connects to the same `qwen-local` model. `scripts/install-opencode.sh` installs the
  binary and generates the provider `opencode.json` + `auth.json` from `opencode_client/.env`;
  `scripts/check-vllm.sh` verifies the endpoint; `scripts/launch-opencode.sh` verifies
  then launches `opencode -m dgx-vllm/qwen-local`. Shared vLLM checks live in
  `scripts/lib_vllm.sh`. Config precedence: environment > `.env` > built-in defaults.
- `ntfy/` — per-PC [ntfy](https://ntfy.sh) push server (single Docker container,
  port `2020`). With `NTFY_ENABLED=true` in `agent_canvas_native/.env`, `run.sh`
  also starts `agent_canvas_native/ntfy_notifier.py`, a stdlib-only daemon that
  polls the local agent-server and pushes phone notifications on conversation
  status transitions (finished / idle = needs input / waiting_for_confirmation /
  error / stuck). Designed for multiple PCs on Tailscale, each running its own
  server + notifier. See `ntfy/README.md` and `agent_canvas_native/README.md`
  → *Notifications (ntfy)*.

## Deployment constraints (do not change without a reason)

- **Single user, small concurrent-agent count.** `MAX_NUM_SEQS` is 8 in this
  stack. Earlier GB10 measurements suggested the per-token memory-bandwidth
  tax above ~4 in-flight decodes outweighed continuous-batching gains, but the
  value was raised to 8 for multi-agent use; if multi-agent latency regresses,
  drop it back toward 4 via `.env`.
- **The DGX Spark runs the LLM only.** `GPU_MEMORY_UTILIZATION=0.80` relies on
  nothing else sharing the unified memory pool. If the Spark gains other
  workloads, lower it.
- Quality over speed: agentic tool-calling quality (vLLM tool-eval ~90/100 for this
  model) is prioritized over raw tok/s.

## Key tuning decisions (why they exist)

- **Model**: `nvidia/Qwen3.8-27B-NVFP4` (NVIDIA Model Optimizer NVFP4 + FP8
  mixed-precision quantization of the official `Qwen/Qwen3.8-27B` base, ~22 GB).
  It ships a built-in **1-layer MTP head** (`text_config.mtp_num_hidden_layers: 1`,
  `mtp.layers.0.*` tensors in `model.safetensors.index.json`), so speculative
  decoding needs only
  `--speculative-config '{"method":"mtp","num_speculative_tokens":5}'` — no
  `model` field, no separate download. MTP roughly doubles decode on GB10.
- **vLLM image**: `vllm/vllm-openai:nightly`. Qwen3.8 uses the `qwen3_5`
  hybrid-attention architecture (linear + full attention layers), which a
  pinned stable release may predate, so the stack tracks a nightly build rather
  than a specific tag. If you need reproducible builds, record the working
  nightly tag and pin it.
- **Image inputs enabled**: Qwen3.8 is a native VLM (image + video; the
  checkpoint's `config.json` has `language_model_only: false`). This stack keeps
  the vision tower and passes
  `--limit-mm-per-prompt '{"image":4}'`; there is no
  `--language-model-only` flag. (That flag was used while experimenting with an
  earlier revision and was removed in favor of working image analysis.)
- **`--kv-cache-dtype fp8_e4m3`**: quantizes the KV cache to fp8_e4m3 to cut KV
  memory (the checkpoint's `text_config.rope_parameters` are already set up for
  the model's native 262144 context). It is set in `entrypoint.sh`, not an env
  var — to change it, edit the entrypoint.
- **Parsers**: `--tool-call-parser qwen3_coder` (the chat template emits
  <tool_call> tags whose payload contains the function name and parameters, e.g. a
  <function=name> line) and `--reasoning-parser qwen3` (emits
  <think>...</think> blocks). Do not switch either without checking the
  model's `chat_template.jinja`.
- **Context**: 262144 is the native max (`text_config.max_position_embeddings`).
  An earlier revision of `entrypoint.sh` had an `ENABLE_LONG_CONTEXT` switch that
  stretched this to 1,048,576 via YaRN (factor 4.0); it was removed, so there is
  no long-context knob in the current stack — `--max-model-len` is fixed at
  `MAX_MODEL_LEN` (262144).
- **LLM configuration (model, base URL, API key)**: the OpenHands V1 web app
  does **not** read `LLM_MODEL` / `LLM_BASE_URL` / `LLM_API_KEY` env vars. It
  resolves the LLM and MCP servers from its own settings store (GUI:
  `Settings → LLM` / `Settings → MCP`), persisted under `~/.openhands`. Those env
  vars are only honored by the V0/CLI path
  (`LLM.load_from_env` + `--override-with-envs`), and the agent-server config
  loader only parses `OH_*` prefixed vars (see `agent_server/config.py`
  `ENVIRONMENT_VARIABLE_PREFIX`). So the LLM profile is set in the Canvas UI
  (Settings → LLM) or via the V1 REST API — see the `agent_canvas_native`
  section of the README for the profile example. Rationale + verified API
  surface: `MEMORIES.md`.
- **MCP search servers**: web-search servers (e.g. Tavily, remote
  streamable-http, API key) are registered in OpenHands → Settings → MCP, or via
  the V1 REST API (`POST /api/v1/settings` with
  `agent_settings_diff.mcp_config`, which is applied wholesale — send the full
  desired map). Keep any MCP API key out of git.

## Common commands

```bash
# DGX Spark side
cd dgx_spark_host
docker compose -f compose.yml up --build     # first run downloads ~22 GB of weights

# Agent Canvas side (macOS, SSH tunnel first: ssh -N -L 8000:localhost:8000 USER@DGX_SPARK_IP)
./agent_canvas_native/install.sh   # one-time (upgrades on re-run)
./agent_canvas_native/run.sh       # UI: http://localhost:8020

# OpenCode terminal client (macOS, SSH tunnel first — same tunnel as Canvas)
cd opencode_client
cp example.env .env           # then edit .env if the defaults do not fit
./scripts/install-opencode.sh # install binary + generate provider config/auth
./scripts/check-vllm.sh       # endpoint + model + chat smoke test
./scripts/launch-opencode.sh ~/git/my_project
```

Sanity checks that do not need a GPU:

```bash
bash -n dgx_spark_host/entrypoint.sh
bash -n agent_canvas_native/install.sh agent_canvas_native/run.sh
# entrypoint dry-run: put a stub `vllm` script in PATH and run entrypoint.sh
```

## Repo layout & conventions

- `.env` files are local-only and hold secrets (`HF_TOKEN`) — they are
  git-ignored. `dgx_spark_host/` reads `HF_CACHE`/`HF_TOKEN` from `.env` when
  present (compose defaults work without it). `agent_canvas_native/example.env`
  is the native Canvas stack's tracked template — `install.sh` copies it to
  `.env`.
- `context/` holds exported OpenHands conversation events and is git-ignored —
  never commit it.
- `agent_canvas_native/openhands-state/` is the native stack's runtime state
  (conversations, workspaces, terminal history, logs) and is git-ignored. The
  LLM profile, session API key, and encryption key live in `~/.openhands`
  (also git-ignored / outside the repo).
- All runtime defaults live as `ENV` in `dgx_spark_host/Dockerfile`;
  `entrypoint.sh` only composes the `vllm serve` command from those variables.
  Keep the README's env-var tables in sync when adding or changing defaults.
- Config changes should stay overridable via environment variables — no
  hard-coded per-machine values.
