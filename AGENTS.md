# AGENTS.md

Guidance for AI agents (and humans) working in this repository.

## Project overview

`local_llm_agent` runs a Qwen model on an **NVIDIA DGX Spark** (GB10, 128 GB unified memory, aarch64) via vLLM, and drives it from **macOS**
over an SSH tunnel with the native **OpenCode** client (`opencode_native/`).
The DGX side has one self-contained stack per model under `dgx_spark_host/`, all on port 8000 (run one at a time); the currently served model is **`qwen38-flash-next-fp4`**, serving [`nvidia/Qwen3.8-Flash-Next-FP4-Local`](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-FP4-Local) (NVIDIA's QAD NVFP4/MXFP8 quantization of the 125B MoE `Qwen/Qwen3.8-Flash-Next`, ~96 GiB, on the community B12X vLLM image) under the alias `qwen-local`. Earlier 27B stacks (`qwen38-27b-nvfp4`, `qwen38-27b-bf16`) have been removed. Stacks are fully isolated — own image, compose, entrypoint, and defaults; they share no code or parameters.

One serving stack, one client stack, plus a notification sidecar:

- `dgx_spark_host/` — the DGX Spark side, **one self-contained stack per
  model**, each with its own `Dockerfile` (holding all `ENV` defaults),
  `entrypoint.sh`, `compose.yml`, and `README.md` (they share no code or
  parameters; all bind port 8000, so run one at a time):
  - `qwen38-flash-next-fp4/` — `nvidia/Qwen3.8-Flash-Next-FP4-Local` (QAD
    NVFP4/MXFP8 of the 125B MoE `Qwen3.8-Flash-Next`, ~96 GiB) on the B12X
    image, served as `qwen-local`.
- `opencode_native/` — [OpenCode](https://opencode.ai), the macOS-side
  client: a terminal coding agent shipped as one self-contained
  binary (**no Docker, no Node.js**; npm is only used if you install OpenCode
  *plugins*). It reaches the vLLM endpoint through the same SSH tunnel and
  uses the same ntfy server.
  `install.sh` installs the binary and generates
  `opencode-state/config/opencode.json` — OpenCode has no provider UI, and the
  endpoint/key are `{env:...}`-substituted from `.env`, so launches must go
  through `run.sh` (which also does the XDG isolation). `run.sh` modes: `tui`
  (default) / `server` / `attach` / `run` / `mcp` / `upgrade`; the headless server
  listens on `http://localhost:4096` (loopback + basic auth, and `run.sh`
  refuses to bind it without a password). Web search comes from Tavily's hosted
  MCP server, `{env:TAVILY_MCP_URL}`-substituted from `.env` (empty = `run.sh`
  injects `enabled:false`; OpenCode's own `websearch` tool is unavailable on a
  local provider). All state — generated config,
  sessions (`opencode.db`), snapshots, logs — lives inside `opencode-state/`,
  never `~/.config/opencode` or `~/.local/share/opencode`. Agents run as your
  user on the local filesystem, so `permission.edit`/`shell` default to `ask`
  (`OPENCODE_AUTO=yes` = `--auto`). Its own `ntfy_notifier.py` polls the
  opencode server for finished / waiting_for_input / error / retrying and
  links taps to the session in the web UI. See `opencode_native/README.md`.
- `ntfy/` — per-PC [ntfy](https://ntfy.sh) push server (single Docker container,
  port `2020`). With `NTFY_ENABLED=true` in a stack's `.env`, that stack's
  `run.sh` also starts its `ntfy_notifier.py`, a stdlib-only daemon that polls
  the local agent process and pushes phone notifications on status transitions
  (OpenCode: finished / waiting_for_input / error / retrying). Designed
  for multiple PCs on Tailscale, each running its own server + notifier. See
  `ntfy/README.md` and the stack's README → *Notifications (ntfy)*.

## Deployment constraints (do not change without a reason)

- **Single user, small concurrent-agent count.** `MAX_NUM_SEQS` is 4 in the
  `qwen38-flash-next-fp4` stack (the NVIDIA card uses 8): with the ~1M-token FP8
  KV pool a Spark holds about four full 262144-token sequences, so 4 matches the
  memory ceiling. If agents usually run far below full context it can be raised
  via `.env` — check the startup log's `Maximum concurrency for 262,144 tokens
  per request` line first.
- **The DGX Spark runs the LLM only.** `GPU_MEMORY_UTILIZATION` defaults to
  0.8 in `qwen38-flash-next-fp4`, and relies on nothing else sharing the unified
  memory pool. If the Spark gains other workloads, lower it.
- Quality over speed: agentic tool-calling quality (vLLM tool-eval ~90/100 for this
  model) is prioritized over raw tok/s.

## Key tuning decisions (why they exist)

- **Model**: one stack per checkpoint, fully isolated. The served checkpoint is
  NVIDIA's own
  [`nvidia/Qwen3.8-Flash-Next-FP4-Local`](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-FP4-Local)
  (QAD NVFP4/MXFP8 quantization of the 125B MoE `Qwen/Qwen3.8-Flash-Next`,
  ~96 GiB), kept as its own self-contained stack
  (`dgx_spark_host/qwen38-flash-next-fp4/`). The two 27B stacks that used to sit
  beside it (`qwen38-27b-nvfp4`, `qwen38-27b-bf16`) have been removed as unused.
  The stack is isolated in shape as well as content: a different model family
  (125B multimodal MoE, 6B active, hybrid GDN+QSA attention, 51B n-gram/PLE
  embedding table, MTP module) on the community B12X vLLM image
  (`eugr/spark-vllm-b12x`) rather than `vllm/vllm-openai:nightly` — upstream
  vLLM does not yet read the checkpoint's compressed NVFP4 scale factors. Its
  serve flags (`--load-format b12x`, `--quantization modelopt_mixed`, the `b12x`
  GDN/linear/MoE backends, MTP depth 4, `qwen3_xml` tool parser) and
  `VLLM_*`/`B12X_*` environment follow the model card's DGX Spark recipe; the
  PLE table stays in NVMe (`VLLM_PLE_TABLE_MEMORY=disk` + io_uring) so the full
  262144-token context fits alongside the resident weights. It serves the alias
  `qwen-local` on port 8000; run only one stack at a time. The NVIDIA model card
  is the source of truth for the pinned values — do not re-tune beyond what it
  documents.
- **MTP speculative decoding**: the checkpoint ships the MTP module, so it needs
  only `--speculative-config '{"method":"mtp","num_speculative_tokens":4}'` — no
  `model` field, no separate download; `MTP=0` disables it. MTP roughly doubles
  decode on GB10.
- **Adding a checkpoint**: copy the stack folder (and adjust its
  `MODEL_NAME`/`GPU_MEMORY_UTILIZATION`/README) rather than parameterising the
  existing one — stacks intentionally share no code or parameters.
- **vLLM image**: `eugr/spark-vllm-b12x:latest` — the community B12X image NVIDIA
  prescribes for this checkpoint, built with the B12X kernels/loader for GB10.
  Pin a `nightly-YYYYMMDD` sibling for reproducibility. Qwen3.8 uses the
  `qwen3_5` hybrid-attention architecture (linear + full attention layers), which
  a pinned stable vLLM release may predate, so any future 27B-style stack should
  track a `vllm/vllm-openai:nightly` build rather than a specific tag.
- **Image inputs enabled**: Qwen3.8 is a native VLM (image + video; the
  checkpoint's `config.json` has `language_model_only: false`). This stack keeps
  the vision tower and — following the NVIDIA card, which does not set it — does
  not pass `--limit-mm-per-prompt`; add it in `entrypoint.sh` to cap per-request
  images. There is no `--language-model-only` flag. (That flag was used while
  experimenting with an earlier revision and was removed in favor of working
  image analysis.)
- **`KV_CACHE_DTYPE=fp8`**: quantizes the KV cache to fp8 to cut KV memory (the
  checkpoint's `text_config.rope_parameters` are already set up for the model's
  native 262144 context).
- **Parsers**: `--tool-call-parser qwen3_xml` (this checkpoint's chat template
  emits XML-shaped tool calls, which is what the model card prescribes for it)
  and `--reasoning-parser qwen3` (emits the reasoning blocks). Do not switch
  either without checking the model's `chat_template.jinja`.
- **Context**: 262144 is the native max (`text_config.max_position_embeddings`)
  and the default `MAX_MODEL_LEN`. Long context is an opt-in knob, not a
  default: set `YARN_FACTOR` (e.g. `2.0` for 524288, `4.0` for ~1M) **and**
  raise `MAX_MODEL_LEN` to match in the stack's `.env` — static YaRN can hurt
  short-prompt quality, so it ships off (`YARN_FACTOR=0`).

## Common commands

```bash
# DGX Spark side — one self-contained stack per model (port 8000; run one at a
# time). Needs HF_TOKEN + license acceptance in the stack's .env.
cd dgx_spark_host/qwen38-flash-next-fp4
docker compose -f compose.yml up --build   # first run downloads ~96 GiB of weights

# macOS side — the OpenCode client (SSH tunnel first:
# ssh -N -L 8000:localhost:8000 USER@DGX_SPARK_IP)
./opencode_native/install.sh       # one-time (upgrades on re-run)
./opencode_native/run.sh /path/to/repo   # TUI
./opencode_native/run.sh server    # headless API + web UI: http://localhost:4096
./opencode_native/run.sh web       # + published on the tailnet (tailscale serve)
```

Sanity checks that do not need a GPU:

```bash
bash -n dgx_spark_host/qwen38-flash-next-fp4/entrypoint.sh
bash -n opencode_native/install.sh
bash -n opencode_native/run.sh
bash -n opencode_native/lib_stack.sh
python3 -m py_compile opencode_native/ntfy_notifier.py
# entrypoint dry-run: put a stub `vllm` script in PATH and run an entrypoint.sh
# compose rendering: (cd dgx_spark_host/<stack> && docker compose config)
```

## Repo layout & conventions

- `.env` files are local-only and hold secrets (`HF_TOKEN`) — they are
  git-ignored. Each `dgx_spark_host/<stack>/` reads its own optional `.env`:
  compose uses it for `${...}` interpolation (`HF_CACHE` and the other cache
  mounts) and passes it into the container via `env_file`, so `HF_TOKEN` and
  overrides of the `Dockerfile` `ENV` defaults reach `entrypoint.sh` (compose
  defaults work without it). `opencode_native/example.env` is the OpenCode
  stack's tracked template — `install.sh` copies it to `.env` and fills a
  random `OPENCODE_SERVER_PASSWORD` + `NTFY_TOPIC`.
- `context/` holds exported agent conversation events and is git-ignored —
  never commit it.
- `opencode_native/opencode-state/` is the OpenCode stack's runtime state
  (generated `config/opencode.json`, `config/opencode-dir/` for custom
  agents/commands/skills, XDG `data/`+`cache/`+`xdg-config/`, `logs/`, the
  notifier's state file) and is git-ignored. Nothing of it lives under
  `~/.config/opencode` or `~/.local/share/opencode` — `run.sh` repoints the
  `XDG_*` variables into this folder, which is what keeps the stack, its
  notifier, and any personal OpenCode install separated. Two conventions
  worth preserving there: the notifier stays **stdlib-only** (no `jq`, no venv
  — the stack's only non-binary dependency is `python3`), and no script may
  read or write a global OpenCode config path.
- **One stack per model, fully isolated.** Each `dgx_spark_host/<stack>/`
  folder holds its own `Dockerfile` (with all `ENV` defaults for that
  checkpoint), `entrypoint.sh` (composes the `vllm serve` command from those
  environment variables), `compose.yml`, and `README.md`. Stacks share no code
  or parameters — a new checkpoint is added by copying a stack folder, not by
  turning one file into a shared one with presets.
  Keep the stack's README env-var table in sync when its defaults change, and
  keep the top-level README/AGENTS.md stack tables accurate.
- Config changes should stay overridable via environment variables — no
  hard-coded per-machine values.
