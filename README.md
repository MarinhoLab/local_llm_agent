# Local LLM Agent

Run a Qwen model on a DGX Spark and connect to it from macOS using
[Agent Canvas](https://docs.openhands.dev/openhands/usage/agent-canvas/setup)
(native, no Docker) or [OpenCode](https://opencode.ai) (terminal client, no Docker).
Push notifications of agent activity to your phone via
[ntfy](https://ntfy.sh) are included (`ntfy/` + `agent_canvas_native/README.md`
→ *Notifications*).

The DGX side offers three serving options, all on port 8000 (run one at a
time):

- **`qwen38-27b-nvfp4`** — the current NVFP4 quantization from NVIDIA (default),
- **`qwen38-27b-b16`** — the original BF16 Qwen checkpoint, and
- **`flash_ultrafast`** — the [Qwen3.8 Flash DGX UltraFast v16b recipe](https://github.com/dime-online/qwen3.8-Flash-DGX-UltraFast).

See [`dgx_spark_host/`](#dgx_spark_host) → *The three stacks*.

## `dgx_spark_host/`

Host a Qwen model via vLLM on the DGX Spark machine — one self-contained stack
per model, in its own folder (own image, compose, entrypoint, defaults; they
share no code or parameters). All bind port 8000; run only ONE at a time.

### The three stacks

| Stack | Serves | How it's run | Served alias |
|---|---|---|---|
| `qwen38-27b-nvfp4/` | `nvidia/Qwen3.8-27B-NVFP4` (NVFP4+FP8, ~22 GB) — the current default | `cd dgx_spark_host/qwen38-27b-nvfp4 && docker compose up --build` | `qwen-local` |
| `qwen38-27b-b16/` | `Qwen/Qwen3.8-27B` (official BF16, ~55 GB) | `cd dgx_spark_host/qwen38-27b-b16 && docker compose up --build` | `qwen-local` |
| `flash_ultrafast/` | Qwen3.8 Flash DGX UltraFast v16b recipe | `cd dgx_spark_host/flash_ultrafast && ./setup-upstream.sh && docker compose up --build` | `qwen` |

Run the current default:

```bash
cd dgx_spark_host/qwen38-27b-nvfp4
docker compose -f compose.yml up --build
```

The API is available at `http://localhost:8000/v1`. For shared networks, bind
to `127.0.0.1` in the stack's `compose.yml`.

Each stack's `README.md` documents its own environment variables (defaults
live in its `Dockerfile`; override via `.env` or `compose.yml`) and tuning
notes (DGX Spark, GB10, 128 GB unified memory, LLM-only box). Both 27B
checkpoints ship a 1-layer MTP head, so MTP speculative decoding is on by
default for them; both are native vision-language models with image inputs
enabled via `--limit-mm-per-prompt '{"image":4}'`.

### `flash_ultrafast/` — the Qwen3.8 Flash DGX UltraFast option

- **What it is**: the [dime-online/qwen3.8-Flash-DGX-UltraFast](https://github.com/dime-online/qwen3.8-Flash-DGX-UltraFast)
  **v16b** recipe — a patched vLLM image (CUDA 13.0, custom low-latency
  GEMM/Mamba/PLE/MTP kernels) serving the W4A16/FP8 AutoRound-hybrid
  `Qwen3.8-Flash-Next` checkpoint. The PLE table is memory-mapped from
  storage, so the model stays ~71 GiB resident with a 16 GB KV pool at the
  full 262,144-token context. A dense T80 MTP drafter (depth 3, block
  rejection) provides the speed — upstream reports **74 tok/s single stream**
  and **212 tok/s aggregate at 8 streams** on one GB10 (re-verify on your
  hardware).
- **Why fully isolated**: it uses a different (patched) image, extra
  downloads (~135 GB), and a drafter build — so it has its own folder with its
  own compose/entrypoint/pinned env, rather than sharing parameters with the
  two 27B stacks. It is served on the same port 8000 but with the alias
  **`qwen`** (the other two use `qwen-local`).
- **One-time setup** (on the Spark): `./dgx_spark_host/flash_ultrafast/setup-upstream.sh`
  — clones the upstream Apache-2.0 repo, downloads the pinned checkpoint +
  PLE table, builds the patched image and the T80 drafter, and installs the
  draft vocabulary.
- **Run**: `cd dgx_spark_host/flash_ultrafast && docker compose -f compose.yml up --build`.
  Stop the other stacks first — the three stacks share port 8000.

Full details, provenance, the upstream's claims, and the overridable
parameters are in [`dgx_spark_host/flash_ultrafast/README.md`](dgx_spark_host/flash_ultrafast/README.md).

## `agent_canvas_native/`

Run [Agent Canvas](https://docs.openhands.dev/openhands/usage/agent-canvas/setup)
natively: UI + agent-server + automation server + ingress run as local
processes via Node.js and uv, with **no Docker**. Agents run as your user on
the local filesystem (there is no container sandbox).

### Run

```bash
./agent_canvas_native/install.sh   # one-time (upgrades on re-run)
./agent_canvas_native/run.sh
```

- Address `http://localhost:8020` (avoids 8000, the vLLM tunnel).
- LLM profile: Settings → LLM, provider **OpenAI-compatible**, base `http://localhost:8000/v1`, key `local-dgx-key`, model `qwen-local` (the alias both 27B stacks — `qwen38-27b-nvfp4` and `qwen38-27b-b16` — serve). The `flash_ultrafast` stack serves the alias `qwen` on the same port instead.
- Optional **ntfy push notifications** for the phone: with `NTFY_ENABLED=true` in `agent_canvas_native/.env`, `run.sh` also starts the notifier daemon (and the per-PC ntfy server from `ntfy/`) that pings you when your agent finishes, needs input, or errors. See `agent_canvas_native/README.md` → *Notifications (ntfy)*.

| Variable             | Default                | Description                                                                 |
|----------------------|------------------------|-----------------------------------------------------------------------------|
| `AGENT_CANVAS_PORT`  | `8020`                 | Ingress (UI + proxied API) port                                              |
| `AGENT_CANVAS_STATE` | `./openhands-state`    | Where agent-server keeps per-conversation runtime state (conversations, workspaces, terminal history, logs). API key + LLM profile live in `~/.openhands`. |
| `VLLM_BASE_URL`      | `http://localhost:8000/v1` | Endpoint `run.sh` checks before launch (the value for the LLM profile)   |
| `VLLM_API_KEY`       | `local-dgx-key`        | API key for the vLLM preflight check                                       |

Needs Node.js ≥ 22.12 and `uv`. Ports, overrides, and troubleshooting are
documented in [`agent_canvas_native/README.md`](agent_canvas_native/README.md).

## `opencode_client/`

Drive the model from a plain terminal with
[OpenCode](https://opencode.ai) — no Docker required. It targets the served
alias `qwen-local` (both 27B stacks); set `OPENCODE_MODEL_ID=qwen` in
`opencode_client/.env` when the `flash_ultrafast` configuration is running.
Works on macOS (behind
the SSH tunnel) or directly on the DGX Spark (no tunnel, use `OPENCODE_BASE_URL=http://127.0.0.1:8000/v1`).

### Setup (once)

```bash
cd opencode_client
cp example.env .env        # then edit .env if the defaults do not fit
./scripts/install-opencode.sh
```

`install-opencode.sh` installs the OpenCode binary (official installer into
`~/.opencode/bin`, or `npm install -g opencode-ai` with `OPENCODE_INSTALL=npm`)
and generates, from `.env`:

- the provider config at `~/.config/opencode/opencode.json`
  (`OPENCODE_CONFIG_DIR` to relocate it), and
- the API key at OpenCode's auth store (`auth.json` in the XDG data dir;
  `chmod 600`). The key is never written into the tracked config.

### Use

```bash
./scripts/check-vllm.sh                 # endpoint + model + chat smoke test
./scripts/launch-opencode.sh ~/git/my_project
```

`launch-opencode.sh` re-verifies the endpoint (and prints the exact
`ssh -N -L ...` command if the tunnel is down), then runs
`opencode -m dgx-vllm/qwen-local` in the given project directory (with the
`flash_ultrafast` stack active, use `OPENCODE_MODEL_ID=qwen` in
`opencode_client/.env`).
`opencode_client/AGENTS.md` is a template of agent instructions: copy it into
a target project's root for OpenCode to pick up project-specific rules.

### Environment Variables

| Variable                 | Default                     | Description                                                                     |
|--------------------------|-----------------------------|---------------------------------------------------------------------------------|
| `OPENCODE_PROVIDER_ID`   | `dgx-vllm`                  | Provider ID; the key in `opencode.json` and `auth.json` — all three must match   |
| `OPENCODE_PROVIDER_NAME` | `DGX Spark vLLM`            | Display name in the OpenCode model picker (quote it in `.env` — it is sourced)   |
| `OPENCODE_MODEL_ID`      | `qwen-local`                | Model ID exactly as vLLM serves it (from `GET /v1/models`); `qwen` for the `flash_ultrafast` stack |
| `OPENCODE_MODEL_NAME`    | `Qwen3.8-27B`             | Model display name in the picker (config-neutral)                          |
| `OPENCODE_BASE_URL`      | `http://127.0.0.1:8000/v1`  | vLLM API as reachable from THIS machine (tunnel port is derived from it)         |
| `OPENCODE_API_KEY`       | `local-dgx-key`             | Must match the vLLM server's `API_KEY`; written to the git-ignored `auth.json`   |
| `OPENCODE_CONTEXT_LENGTH`| `262144`                    | Model context window in tokens                                                    |
| `OPENCODE_OUTPUT_LENGTH` | `16384`                     | Max output tokens                                                                 |
| `OPENCODE_REQUEST_TIMEOUT` | `120`                     | Per-request curl timeout in seconds for the checks                                |
| `OPENCODE_VERSION`       | *(unset)*                   | Pin an OpenCode release for the installer; unset = latest                         |
| `OPENCODE_INSTALL`       | `official`                  | `official` (default) or `npm`                                                     |
| `OPENCODE_CONFIG_DIR`    | `~/.config/opencode`        | Where the generated `opencode.json` goes (global OpenCode config dir)             |

Generated files (`.env`, `opencode.json`, `auth.json` next to the config) are
git-ignored; only `example.env`, `opencode.example.json`, and
`auth.example.json` are tracked as templates.

## `ntfy/`

Per-PC [ntfy](https://ntfy.sh) push server (single Docker container, port
`2020`). Pairs with the Agent Canvas notifier
(`agent_canvas_native/ntfy_notifier.py`) to send push notifications to your
phone when an agent finishes a turn, needs input, or hits an error. Designed
for **multiple PCs on Tailscale**, each running its own server + notifier:
the notifier publishes to `127.0.0.1:2020`, the phone subscribes over
Tailscale at `http://<pc>.tail:2020/<topic>`.

```bash
cd ntfy
cp example.env .env     # set NTFY_BASE_URL=http://<this-pc>.tail:2020
docker compose up -d    # healthcheck via docker compose ps
```

Security model (unguessable topic = credential on Tailscale), optional
account auth, phone setup (Android instant delivery / iOS relay) and the
Firebase/custom-APK caveat are documented in
[`ntfy/README.md`](ntfy/README.md). Enable end-to-end notifications via
`NTFY_ENABLED=true` in `agent_canvas_native/.env` (see
`agent_canvas_native/README.md` → *Notifications (ntfy)*).
