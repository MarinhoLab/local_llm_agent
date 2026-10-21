# AGENTS.md

Guidance for AI agents (and humans) working in this repository.

## Project overview

`local_llm_agent` runs a Qwen model on an **NVIDIA DGX Spark** (GB10, 128 GB unified memory, aarch64) via vLLM, and drives it from **macOS** through **the retired client**
over an SSH tunnel. The DGX side has one self-contained stack per model under `dgx_spark_host/`, all on port 8000 (run one at a time): **`qwen38-27b-nvfp4`** (the current default) serving `nvidia/Qwen3.8-27B-NVFP4` (NVIDIA's NVFP4 + FP8 quantization of the official `Qwen/Qwen3.8-27B`), **`qwen38-27b-bf16`** serving the original `Qwen/Qwen3.8-27B` in BF16, and **`qwen38-flash-next-fp4`** serving [`nvidia/Qwen3.8-Flash-Next-FP4-Local`](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-FP4-Local) (NVIDIA's QAD NVFP4/MXFP8 quantization of the 125B MoE `Qwen/Qwen3.8-Flash-Next`, ~96 GiB, on the community B12X vLLM image). All three serve the alias `qwen-local`. The stacks are fully isolated — own image, compose, entrypoint, and defaults; the three stacks share no code or parameters.

Three self-contained stacks plus a notification sidecar:

- `dgx_spark_host/` — the DGX Spark side, **one self-contained stack per
  model**, each with its own `Dockerfile` (holding all `ENV` defaults),
  `entrypoint.sh`, `compose.yml`, and `README.md` (they share no code or
  parameters; all bind port 8000, so run one at a time):
  - `qwen38-27b-nvfp4/` — `nvidia/Qwen3.8-27B-NVFP4` (NVFP4+FP8, ~22 GB), the
    current default, served as `qwen-local`.
  - `qwen38-27b-bf16/` — `Qwen/Qwen3.8-27B` (official BF16, ~55 GB), served as
    `qwen-local`.
  - `qwen38-flash-next-fp4/` — `nvidia/Qwen3.8-Flash-Next-FP4-Local` (QAD
    NVFP4/MXFP8 of the 125B MoE `Qwen3.8-Flash-Next`, ~96 GiB) on the B12X
    image, served as `qwen-local`.
- `retired-stack/` — [the retired client](https://docs.the retired client.dev/the retired client/usage/retired-stack/setup)
  (UI + retired-server + automation server + ingress) running as local processes via
  Node.js ≥ 22.12 and `uv`, with **no Docker**; also reaches vLLM through the
  tunnel; UI at `http://localhost:8020`. Agents run as your user on the local
  filesystem. See `retired-stack/README.md` for ports and overrides.
- `ntfy/` — per-PC [ntfy](https://ntfy.sh) push server (single Docker container,
  port `2020`). With `NTFY_ENABLED=true` in `retired-stack/.env`, `run.sh`
  also starts `retired-stack/ntfy_notifier.py`, a stdlib-only daemon that
  polls the local retired-server and pushes phone notifications on conversation
  status transitions (finished / idle = needs input / waiting_for_confirmation /
  error / stuck). Designed for multiple PCs on Tailscale, each running its own
  server + notifier. See `ntfy/README.md` and `retired-stack/README.md`
  → *Notifications (ntfy)*.

## Deployment constraints (do not change without a reason)

- **Single user, small concurrent-agent count.** `MAX_NUM_SEQS` is 8 in the
  `qwen38-27b-nvfp4` stack and 4 in `qwen38-27b-bf16`, where the smaller KV
  pool (~38 GiB) holds about four full 262144-token sequences. Earlier GB10
  measurements suggested the per-token memory-bandwidth tax above ~4
  in-flight decodes outweighed continuous-batching gains, but the NVFP4 value
  was raised to 8 for multi-agent use; if multi-agent latency regresses, drop
  it back toward 4 via `.env`.
- **The DGX Spark runs the LLM only.** `GPU_MEMORY_UTILIZATION` defaults to
  0.80 in both 27B stacks (`qwen38-27b-nvfp4` and `qwen38-27b-bf16`), and
  relies on nothing else sharing the unified memory pool. If the Spark gains other workloads, lower it.
- Quality over speed: agentic tool-calling quality (vLLM tool-eval ~90/100 for this
  model) is prioritized over raw tok/s.

## Key tuning decisions (why they exist)

- **Model**: one stack per checkpoint, fully isolated
  (`dgx_spark_host/qwen38-27b-nvfp4/` and `dgx_spark_host/qwen38-27b-bf16/`).
  `qwen38-27b-nvfp4` serves `nvidia/Qwen3.8-27B-NVFP4` (NVIDIA Model Optimizer
  NVFP4 + FP8 mixed-precision quantization of the official `Qwen/Qwen3.8-27B`
  base, ~22 GB); `qwen38-27b-bf16` serves the original `Qwen/Qwen3.8-27B` in
  BF16 (~55 GB). Both use `GPU_MEMORY_UTILIZATION=0.80`; the fraction caps
  weights + KV together, so the larger BF16 weights leave a smaller KV pool. Both checkpoints ship
  a built-in **1-layer MTP head** (`text_config.mtp_num_hidden_layers: 1`,
  `mtp.layers.0.*` tensors in `model.safetensors.index.json`), so speculative
  decoding needs only
  `--speculative-config '{"method":"mtp","num_speculative_tokens":5}'` — no
  `model` field, no separate download. MTP roughly doubles decode on GB10.
  The stacks intentionally share no code or parameters — copy a stack folder
  (and adjust its `MODEL_NAME`/`GPU_MEMORY_UTILIZATION`/README) to add another
  checkpoint.
- **Model (third option, `qwen38-flash-next-fp4`)**: the "biggest model that
  fits one Spark" path is NVIDIA's own
  [`nvidia/Qwen3.8-Flash-Next-FP4-Local`](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-FP4-Local)
  checkpoint, kept as its own self-contained stack
  (`dgx_spark_host/qwen38-flash-next-fp4/`). It is isolated from the two 27B
  stacks because it is a different model family (125B multimodal MoE, 6B
  active, hybrid GDN+QSA attention, 51B n-gram/PLE embedding table, MTP module)
  and needs the community B12X vLLM image (`eugr/spark-vllm-b12x`) rather than
  `vllm/vllm-openai:nightly` — upstream vLLM does not yet read the checkpoint's
  compressed NVFP4 scale factors. Its serve flags (`--load-format b12x`,
  `--quantization modelopt_mixed`, the `b12x` GDN/linear/MoE backends, MTP
  depth 4, `qwen3_xml` tool parser) and `VLLM_*`/`B12X_*` environment follow
  the model card's DGX Spark recipe; the PLE table stays in NVMe
  (`VLLM_PLE_TABLE_MEMORY=disk` + io_uring) so the full 262144-token context
  fits alongside the resident weights. It serves the same alias `qwen-local` as
  the other stacks on the same port 8000; run only one stack at a time. The
  NVIDIA model card is the source of truth for the pinned values — do not
  re-tune beyond what it documents.
- **vLLM image**: `vllm/vllm-openai:nightly` in the two 27B stacks. Qwen3.8 uses
  the `qwen3_5` hybrid-attention architecture (linear + full attention layers),
  which a pinned stable release may predate, so those stacks track a nightly
  build rather than a specific tag. If you need reproducible builds, record the
  working nightly tag and pin it. The Flash Next stack instead pins
  `eugr/spark-vllm-b12x:latest` (the community B12X image NVIDIA prescribes for
  that checkpoint) — pin a `nightly-YYYYMMDD` sibling for reproducibility.
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
- **LLM configuration (model, base URL, API key)**: the the retired client V1 web app
  does **not** read `LLM_MODEL` / `LLM_BASE_URL` / `LLM_API_KEY` env vars. It
  resolves the LLM and MCP servers from its own settings store (GUI:
  `Settings → LLM` / `Settings → MCP`), persisted under `~/.the retired client`. Those env
  vars are only honored by the V0/CLI path
  (`LLM.load_from_env` + `--override-with-envs`), and the retired-server config
  loader only parses `OH_*` prefixed vars (see `agent_server/config.py`
  `ENVIRONMENT_VARIABLE_PREFIX`). So the LLM profile is set in the Canvas UI
  (Settings → LLM) or via the V1 REST API — see the `retired-stack`
  section of the README for the profile example. Rationale + verified API
  surface: `MEMORIES.md`.
- **MCP search servers**: web-search servers (e.g. Tavily, remote
  streamable-http, API key) are registered in the retired client → Settings → MCP, or via
  the V1 REST API (`POST /api/v1/settings` with
  `agent_settings_diff.mcp_config`, which is applied wholesale — send the full
  desired map). Keep any MCP API key out of git.
- **the retired client runs in public mode by default.** `run.sh` execs
  `retired-stack --host 0.0.0.0 --port 8020 --public`, so the UI answers on the
  LAN / tailnet addresses too and the API key is not injected into the page —
  every browser pastes `LOCAL_BACKEND_API_KEY` (generated into
  `retired-stack/.env` by install.sh) once. That key is the only gate, and
  agents run as your user on the local filesystem, so it is effectively a shell
  credential; `run.sh` refuses to start without it. `CANVAS_PUBLIC=false`
  restores loopback-only mode with the key auto-injected and no login. (An
  earlier attempt at this used a custom `bind_guard.py` proxy — reverted, it
  broke too much.)
- **the retired client runtime = Python 3.14 + tmux.** The launcher runs retired-server
  and the automation backend through `uv tool uvx` and pins only the
  `the retired client-*` packages, so the interpreter floats to whatever `python3` is
  newest on the machine. On 3.15 that environment fails to build, so `run.sh`
  exports `UV_PYTHON=3.14` (and `install.sh` installs `python@3.14` via
  Homebrew). `tmux` is what the SDK uses for agent terminals — without it every
  conversation logs "tmux is not installed. Falling back to subprocess-based
  terminal". Both are checked by `install.sh`/`run.sh`.

## Common commands

```bash
# DGX Spark side — one self-contained stack per model (port 8000; run one at a time)
cd dgx_spark_host/qwen38-27b-nvfp4     # the current default
docker compose -f compose.yml up --build   # first run downloads ~22 GB of weights

# or the other 27B stack (original BF16 checkpoint, ~55 GB):
cd ../qwen38-27b-bf16 && docker compose -f compose.yml up --build

# or the Flash Next stack (125B MoE, ~96 GiB; stop the other stacks first —
# they share port 8000; needs HF_TOKEN + license acceptance in its .env)
cd ../qwen38-flash-next-fp4
docker compose -f compose.yml up --build

# the retired client side (macOS, SSH tunnel first: ssh -N -L 8000:localhost:8000 USER@DGX_SPARK_IP)
./retired-stack/install.sh   # one-time (upgrades on re-run)
./retired-stack/run.sh       # UI: http://localhost:8020
```

Sanity checks that do not need a GPU:

```bash
# one file per `bash -n` invocation: with several paths it checks only the first
bash -n dgx_spark_host/qwen38-27b-nvfp4/entrypoint.sh
bash -n dgx_spark_host/qwen38-27b-bf16/entrypoint.sh
bash -n dgx_spark_host/qwen38-flash-next-fp4/entrypoint.sh
bash -n retired-stack/install.sh
bash -n retired-stack/run.sh
python3 -m py_compile retired-stack/ntfy_notifier.py
# entrypoint dry-run: put a stub `vllm` script in PATH and run an entrypoint.sh
# compose rendering: (cd dgx_spark_host/<stack> && docker compose config)
```

## Repo layout & conventions

- `.env` files are local-only and hold secrets (`HF_TOKEN`) — they are
  git-ignored. Each `dgx_spark_host/<stack>/` reads its own optional `.env`:
  compose uses it for `${...}` interpolation (`HF_CACHE` and the other cache
  mounts) and passes it into the container via `env_file`, so `HF_TOKEN` and
  overrides of the `Dockerfile` `ENV` defaults reach `entrypoint.sh` (compose
  defaults work without it). `retired-stack/example.env` is the native
  Canvas stack's tracked template — `install.sh` copies it to `.env`.
- `context/` holds exported the retired client conversation events and is git-ignored —
  never commit it.
- `retired-stack/the retired client-state/` is the native stack's runtime state
  (conversations, workspaces, terminal history, logs) and is git-ignored. The
  LLM profile, session API key, and encryption key live in `~/.the retired client`
  (also git-ignored / outside the repo).
- **One stack per model, fully isolated.** Each `dgx_spark_host/<stack>/`
  folder holds its own `Dockerfile` (with all `ENV` defaults for that
  checkpoint), `entrypoint.sh` (composes the `vllm serve` command from those
  environment variables), `compose.yml`, and `README.md`. The stacks share no
  code or parameters — the three stacks are independent copies, not a shared
  file with presets.
  Keep each stack's README env-var table in sync when its defaults change, and
  keep the top-level README/AGENTS.md stack tables accurate.
- Config changes should stay overridable via environment variables — no
  hard-coded per-machine values.
