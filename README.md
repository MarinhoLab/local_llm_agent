# Local LLM Agent

Run a Qwen model on a DGX Spark and connect to it from macOS using
[the retired client](https://docs.the retired client.dev/the retired client/usage/retired-stack/setup)
(native, no Docker) or [OpenCode](https://opencode.ai) (terminal client, no Docker).
Push notifications of agent activity to your phone via
[ntfy](https://ntfy.sh) are included (`ntfy/` + `retired-stack/README.md`
→ *Notifications*).

## `dgx_spark_host/`

Host a Qwen model via vLLM on the DGX Spark machine.

### Run

```bash
cd dgx_spark_host
docker compose up --build
```

The API is available at `http://localhost:8000/v1`. For shared networks, bind to `127.0.0.1` in `compose.yml`.

### Environment Variables

| Variable                 | Default                   | Description                                                                    |
|--------------------------|---------------------------|--------------------------------------------------------------------------------|
| `MODEL_NAME`             | `nvidia/Qwen3.8-27B-NVFP4` | Hugging Face model to serve                                                    |
| `SERVED_MODEL_NAME`      | `qwen-local`              | Alias exposed by the API                                                       |
| `HOST`                   | `0.0.0.0`                 | Bind address                                                                   |
| `PORT`                   | `8000`                    | Listen port                                                                    |
| `API_KEY`                | `local-dgx-key`           | API key for authentication                                                     |
| `MAX_MODEL_LEN`          | `262144`                  | Maximum sequence length                                                        |
| `GPU_MEMORY_UTILIZATION` | `0.80`                    | Fraction of GPU memory to use                                                  |
| `MAX_NUM_SEQS`           | `8`                       | Maximum concurrent sequences                                                   |
| `MAX_NUM_BATCHED_TOKENS` | `8192`                    | Max tokens per batch                                                           |
| `SPEC_METHOD`            | `mtp`                     | Speculative decoding method (the checkpoint ships an MTP head)                 |
| `NUM_SPEC_TOKENS`        | `5`                       | Speculative draft tokens; ~2x decode speed at 3-5, tune per workload           |
| `HF_CACHE`               | `./hf-cache`              | Volume mount path for Hugging Face cache                                       |
| `HF_TOKEN`               | *(unset)*                 | Hugging Face token for gated models                                            |

All vLLM defaults are set in `Dockerfile`; override via `.env` or `compose.yml`.

Tuning notes (DGX Spark, GB10, 128 GB unified memory, LLM-only box):

- **Model**: `nvidia/Qwen3.8-27B-NVFP4` (~22 GB, NVIDIA Model Optimizer NVFP4 +
  FP8 mixed-precision quantization of the official `Qwen/Qwen3.8-27B` base). The
  checkpoint ships a 1-layer MTP head, so MTP speculative decoding needs no
  separate draft model (~2x decode speed on GB10). It is a native
  vision-language model (`qwen3_5`, image + video) and image inputs stay
  enabled via `--limit-mm-per-prompt '{"image":4}'`; there is no
  `--language-model-only` flag in this stack.
- **Memory**: `GPU_MEMORY_UTILIZATION` is a fraction of the unified CPU+GPU
  pool. 0.80 is appropriate when the Spark runs nothing but the LLM; lower it
  if you host other workloads on the box.
- **Concurrency**: `MAX_NUM_SEQS` is 8 in this stack. Early measurements
  suggested the per-token bandwidth tax above 4 in-flight decodes outweighed
  continuous-batching gains on GB10; the value was raised to 8 and is kept
  overridable via `.env` — drop it back down if multi-agent latency regresses.
- **Context**: 262144 is the native max (`text_config.max_position_embeddings`).
  The `--enable-long-context`/YaRN 1M-token option that was in an earlier
  revision of this stack has been removed; there is no `ENABLE_LONG_CONTEXT`
  knob anymore.

## `retired-stack/`

Run [the retired client](https://docs.the retired client.dev/the retired client/usage/retired-stack/setup)
natively: UI + retired-server + automation server + ingress run as local
processes via Node.js and uv, with **no Docker**. Agents run as your user on
the local filesystem (there is no container sandbox).

### Run

```bash
./retired-stack/install.sh   # one-time (upgrades on re-run)
./retired-stack/run.sh
```

- Address `http://localhost:8020` (avoids 8000, the vLLM tunnel).
- LLM profile: Settings → LLM, provider **OpenAI-compatible**, base `http://localhost:8000/v1`, key `local-dgx-key`, model `qwen-local` (the alias the stack serves; the underlying checkpoint is `nvidia/Qwen3.8-27B-NVFP4`).
- Optional **ntfy push notifications** for the phone: with `NTFY_ENABLED=true` in `retired-stack/.env`, `run.sh` also starts the notifier daemon (and the per-PC ntfy server from `ntfy/`) that pings you when your agent finishes, needs input, or errors. See `retired-stack/README.md` → *Notifications (ntfy)*.

| Variable             | Default                | Description                                                                 |
|----------------------|------------------------|-----------------------------------------------------------------------------|
| `RETIRED_STACK_PORT`  | `8020`                 | Ingress (UI + proxied API) port                                              |
| `RETIRED_STACK_STATE` | `./the retired client-state`    | Where retired-server keeps per-conversation runtime state (conversations, workspaces, terminal history, logs). API key + LLM profile live in `~/.the retired client`. |
| `VLLM_BASE_URL`      | `http://localhost:8000/v1` | Endpoint `run.sh` checks before launch (the value for the LLM profile)   |
| `VLLM_API_KEY`       | `local-dgx-key`        | API key for the vLLM preflight check                                       |

Needs Node.js ≥ 22.12 and `uv`. Ports, overrides, and troubleshooting are
documented in [`retired-stack/README.md`](retired-stack/README.md).

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
| `OPENCODE_MODEL_NAME`    | `Qwen3.8-27B-NVFP4`       | Model display name in the picker                                                  |
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
`2020`). Pairs with the the retired client notifier
(`retired-stack/ntfy_notifier.py`) to send push notifications to your
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
`NTFY_ENABLED=true` in `retired-stack/.env` (see
`retired-stack/README.md` → *Notifications (ntfy)*).
