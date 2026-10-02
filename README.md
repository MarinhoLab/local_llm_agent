# Local LLM Agent

Run a Qwen model on a DGX Spark and connect to it from macOS using
[Agent Canvas](https://docs.openhands.dev/openhands/usage/agent-canvas/setup)
(native, no Docker) or [OpenCode](https://opencode.ai) (terminal client, no Docker).
Push notifications of agent activity to your phone via
[ntfy](https://ntfy.sh) are included (`ntfy/` + `agent_canvas_native/README.md`
→ *Notifications*).

The DGX side offers three serving options, all on port 8000 (run one at a
time):

- **`nvfp4`** — the current NVFP4 quantization from NVIDIA (`MODEL_CONFIG=nvfp4`,
  default in `dgx_spark_host/`),
- **`b16`** — the original BF16 Qwen checkpoint (`MODEL_CONFIG=b16`), and
- **`flash_ultrafast`** — the [Qwen3.8 Flash DGX UltraFast v16b recipe](https://github.com/dime-online/qwen3.8-Flash-DGX-UltraFast)
  as a separate substack (`dgx_spark_host/flash_ultrafast/`).

See [`dgx_spark_host/`](#dgx_spark_host) → *Model configurations*.

## `dgx_spark_host/`

Host a Qwen model via vLLM on the DGX Spark machine.

### Run

```bash
cd dgx_spark_host
docker compose up --build
```

The API is available at `http://localhost:8000/v1`. For shared networks, bind to `127.0.0.1` in `compose.yml`.

### Model configurations

Three serving options for the DGX Spark, all on port 8000 — run only ONE at a
time:

| Option | Serves | How it's run | Served alias |
|---|---|---|---|
| `nvfp4` (default) | `nvidia/Qwen3.8-27B-NVFP4` (NVFP4+FP8, ~22 GB) | `MODEL_CONFIG=nvfp4` in `dgx_spark_host/.env` | `qwen-local` |
| `b16` | `Qwen/Qwen3.8-27B` (official BF16, ~55 GB) | `MODEL_CONFIG=b16` in `dgx_spark_host/.env` | `qwen-local` |
| `flash_ultrafast` | Qwen3.8-Flash-Next W4A16/FP8 AutoRound-hybrid + dense MTP drafter | separate substack | `qwen` |

The first two are checkpoint presets of this stack's standard vLLM
`nightly` image, selected with `MODEL_CONFIG` in `dgx_spark_host/.env`.
Both ship a 1-layer MTP head, so MTP speculative decoding is on by default for
either; per-preset defaults (`MODEL_NAME`, `GPU_MEMORY_UTILIZATION`,
`SPEC_METHOD`, `NUM_SPEC_TOKENS`) are applied by `entrypoint.sh` and remain
overridable in `.env`. To switch between them:

```bash
cd dgx_spark_host
echo 'MODEL_CONFIG=b16' >> .env     # or edit an existing .env
docker compose -f compose.yml up --build
```

The third option, `flash_ultrafast`, is **not** a plain checkpoint — it is the
[dime-online/qwen3.8-Flash-DGX-UltraFast](https://github.com/dime-online/qwen3.8-Flash-DGX-UltraFast)
**v16b** recipe (a patched vLLM image serving a W4A16/FP8 AutoRound-hybrid
checkpoint with a dense MTP drafter), run from the dedicated
`dgx_spark_host/flash_ultrafast/` substack. It is the throughput option
(~74 tok/s single stream, ~212 aggregate at 8 streams per the upstream's GB10
measurements; ~71 GiB resident, 16 GB KV) and serves the alias `qwen` instead
of `qwen-local`. See
[`dgx_spark_host/flash_ultrafast/README.md`](dgx_spark_host/flash_ultrafast/README.md).

### Environment Variables

| Variable                 | Default                     | Description                                                                    |
|--------------------------|-----------------------------|--------------------------------------------------------------------------------|
| `MODEL_CONFIG`           | `nvfp4`                     | Selectable checkpoint configuration: `nvfp4` (`nvidia/Qwen3.8-27B-NVFP4`) or `b16` (`Qwen/Qwen3.8-27B`) |
| `MODEL_NAME`             | per `MODEL_CONFIG`          | Hugging Face model to serve (default set by `MODEL_CONFIG` in `entrypoint.sh`) |
| `SERVED_MODEL_NAME`      | `qwen-local`              | Alias exposed by the API                                                       |
| `HOST`                   | `0.0.0.0`                 | Bind address                                                                   |
| `PORT`                   | `8000`                    | Listen port                                                                    |
| `API_KEY`                | `local-dgx-key`           | API key for authentication                                                     |
| `MAX_MODEL_LEN`          | `262144`                  | Maximum sequence length                                                        |
| `GPU_MEMORY_UTILIZATION` | per `MODEL_CONFIG`        | Fraction of GPU memory to use (0.80 for `nvfp4`, 0.70 for `b16`)               |
| `MAX_NUM_SEQS`           | `8`                       | Maximum concurrent sequences                                                   |
| `MAX_NUM_BATCHED_TOKENS` | `8192`                    | Max tokens per batch                                                           |
| `SPEC_METHOD`            | per `MODEL_CONFIG`        | Speculative decoding method (`mtp`; both checkpoints ship an MTP head)         |
| `NUM_SPEC_TOKENS`        | per `MODEL_CONFIG`        | Speculative draft tokens (5 for both; ~2x decode speed at 3-5, tune per workload) |
| `HF_CACHE`               | `./hf-cache`              | Volume mount path for Hugging Face cache                                       |
| `HF_TOKEN`               | *(unset)*                 | Hugging Face token for gated models                                            |

Common defaults are set in `Dockerfile`; per-checkpoint defaults are applied by
`entrypoint.sh` from `MODEL_CONFIG`. Everything can be overridden via `.env` or
`compose.yml`.

Tuning notes (DGX Spark, GB10, 128 GB unified memory, LLM-only box):

- **Model configurations**: `MODEL_CONFIG=nvfp4` serves
  `nvidia/Qwen3.8-27B-NVFP4` (~22 GB, NVIDIA Model Optimizer NVFP4 + FP8
  mixed-precision quantization of the official `Qwen/Qwen3.8-27B` base) — the
  default. `MODEL_CONFIG=b16` serves the original `Qwen/Qwen3.8-27B` in BF16
  (~55 GB). Both ship a 1-layer MTP head, so MTP speculative decoding needs no
  separate draft model (~2x decode speed on GB10). Both are native
  vision-language models (`qwen3_5`, image + video) and image inputs stay
  enabled via `--limit-mm-per-prompt '{"image":4}'`; there is no
  `--language-model-only` flag in this stack.
- **Memory**: `GPU_MEMORY_UTILIZATION` is a fraction of the unified CPU+GPU
  pool, defaulting to 0.80 for the `nvfp4` config and 0.70 for the larger
  `b16` config. 0.80 is appropriate for the NVFP4 checkpoint when the Spark
  runs nothing but the LLM; lower it if you host other workloads on the box.
- **Concurrency**: `MAX_NUM_SEQS` is 8 in this stack. Early measurements
  suggested the per-token bandwidth tax above 4 in-flight decodes outweighed
  continuous-batching gains on GB10; the value was raised to 8 and is kept
  overridable via `.env` — drop it back down if multi-agent latency regresses.
- **Context**: 262144 is the native max (`text_config.max_position_embeddings`).
  The `--enable-long-context`/YaRN 1M-token option that was in an earlier
  revision of this stack has been removed; there is no `ENABLE_LONG_CONTEXT`
  knob anymore.

### `flash_ultrafast/` — the Qwen3.8 Flash DGX UltraFast option

A self-contained third DGX-side configuration, in its own substack:
[`dgx_spark_host/flash_ultrafast/`](dgx_spark_host/flash_ultrafast/).

- **What it is**: the [dime-online/qwen3.8-Flash-DGX-UltraFast](https://github.com/dime-online/qwen3.8-Flash-DGX-UltraFast)
  **v16b** recipe — a patched vLLM image (CUDA 13.0, custom low-latency
  GEMM/Mamba/PLE/MTP kernels) serving the W4A16/FP8 AutoRound-hybrid
  `Qwen3.8-Flash-Next` checkpoint. The PLE table is memory-mapped from
  storage, so the model stays ~71 GiB resident with a 16 GB KV pool at the
  full 262,144-token context. A dense T80 MTP drafter (depth 3, block
  rejection) provides the speed — upstream reports **74 tok/s single stream**
  and **212 tok/s aggregate at 8 streams** on one GB10 (re-verify on your
  hardware).
- **Why a separate substack**: it uses a different (patched) image, extra
  downloads (~135 GB), and a drafter build, so it cannot be a `MODEL_CONFIG`
  value of the standard `nvfp4`/`b16` stack. It is served on the same port
  8000 but with the alias **`qwen`** (the other two use `qwen-local`).
- **One-time setup** (on the Spark): `./dgx_spark_host/flash_ultrafast/setup-upstream.sh`
  — clones the upstream Apache-2.0 repo, downloads the pinned checkpoint +
  PLE table, builds the patched image and the T80 drafter, and installs the
  draft vocabulary.
- **Run**: `cd dgx_spark_host/flash_ultrafast && docker compose -f compose.yml up --build`.
  Stop the `nvfp4`/`b16` stack first — the three options share port 8000.

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
- LLM profile: Settings → LLM, provider **OpenAI-compatible**, base `http://localhost:8000/v1`, key `local-dgx-key`, model `qwen-local` (the alias the `nvfp4`/`b16` stack serves; the underlying checkpoint is `nvidia/Qwen3.8-27B-NVFP4` for `MODEL_CONFIG=nvfp4` or `Qwen/Qwen3.8-27B` for `MODEL_CONFIG=b16`). The `flash_ultrafast` configuration serves the alias `qwen` on the same port instead.
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

Drive the same `qwen-local` model from a plain terminal with
[OpenCode](https://opencode.ai) — no Docker required. Works on macOS (behind
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
`opencode -m dgx-vllm/qwen-local` in the given project directory.
`opencode_client/AGENTS.md` is a template of agent instructions: copy it into
a target project's root for OpenCode to pick up project-specific rules.

### Environment Variables

| Variable                 | Default                     | Description                                                                     |
|--------------------------|-----------------------------|---------------------------------------------------------------------------------|
| `OPENCODE_PROVIDER_ID`   | `dgx-vllm`                  | Provider ID; the key in `opencode.json` and `auth.json` — all three must match   |
| `OPENCODE_PROVIDER_NAME` | `DGX Spark vLLM`            | Display name in the OpenCode model picker (quote it in `.env` — it is sourced)   |
| `OPENCODE_MODEL_ID`      | `qwen-local`                | Model ID exactly as vLLM serves it (from `GET /v1/models`)                       |
| `OPENCODE_MODEL_NAME`    | `Qwen3.8-27B`             | Model display name in the picker (same for both `MODEL_CONFIG` options)          |
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
