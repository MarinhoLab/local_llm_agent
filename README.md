# Local LLM Agent

Run a Qwen model on a DGX Spark and connect to it from macOS using OpenHands.

## `dgx_spark_host/`

Host a Qwen model via vLLM on the DGX Spark machine.

### Run

```bash
cd dgx_spark_host
docker compose up --build
```

The API is available at `http://localhost:8000/v1`. For shared networks, bind to `127.0.0.1` in `compose.yml`.

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `MODEL_NAME` | `Qwen/Qwen3.8-27B-FP8` | Hugging Face model to serve |
| `SERVED_MODEL_NAME` | `qwen-local` | Alias exposed by the API |
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8000` | Listen port |
| `API_KEY` | `local-dgx-key` | API key for authentication |
| `MAX_MODEL_LEN` | `262144` | Maximum sequence length |
| `GPU_MEMORY_UTILIZATION` | `0.85` | Fraction of GPU memory to use |
| `MAX_NUM_SEQS` | `8` | Maximum concurrent sequences |
| `MAX_NUM_BATCHED_TOKENS` | `8192` | Max tokens per batch |
| `SPEC_METHOD` | `mtp` | Speculative decoding method (the checkpoint ships an MTP head) |
| `NUM_SPEC_TOKENS` | `5` | Speculative draft tokens; ~2x decode speed at 3-5, tune per workload |
| `ENABLE_LONG_CONTEXT` | `0` | `1` stretches context to 1M tokens via YaRN (costs ~36 GiB KV; off by default) |
| `HF_CACHE` | `./hf-cache` | Volume mount path for Hugging Face cache |
| `HF_TOKEN` | *(unset)* | Hugging Face token for gated models |

All vLLM defaults are set in `Dockerfile`; override via `.env` or `compose.yml`.

Tuning notes (DGX Spark, GB10, 128 GB unified memory, LLM-only box):

- **Model**: official `Qwen/Qwen3.8-27B-FP8` (~27 GB, fine-grained FP8 block-128,
  quality nearly identical to the original per the model card). The checkpoint
  ships an MTP head, so MTP speculative decoding needs no separate draft model
  (~2x decode speed on GB10). It is a native vision-language model and image
  inputs stay enabled via `--limit-mm-per-prompt '{"image":4}'`; there is no
  `--language-model-only` flag in this stack.
- **Memory**: `GPU_MEMORY_UTILIZATION` is a fraction of the unified CPU+GPU
  pool. 0.85 is appropriate when the Spark runs nothing but the LLM; lower it
  if you host other workloads on the box.
- **Concurrency**: `MAX_NUM_SEQS` is 8 in this stack. Early measurements
  suggested the per-token bandwidth tax above 4 in-flight decodes outweighed
  continuous-batching gains on GB10; the value was raised to 8 and is kept
  overridable via `.env` — drop it back down if multi-agent latency regresses.
- **Context**: 262144 is the native max. `ENABLE_LONG_CONTEXT=1` enables YaRN
  to 1,048,576 tokens (static, costs KV memory on every request).

## `macos_client/`

Run OpenHands on macOS, connecting to the DGX Spark vLLM server.

### SSH Tunnel

Before starting the stack, create an SSH tunnel from macOS to the DGX Spark in a separate terminal:

```bash
ssh -L 8000:localhost:8000 USER@DGX_SPARK_IP
```

This forwards the vLLM API (port 8000) from the DGX Spark to your local machine, which OpenHands will reach at `host.docker.internal:8000`.

### Run

```bash
cd macos_client
cp example.env .env        # required: compose.yml reads ports / logging from it
mkdir -p workspace openhands-state
docker compose up
```

Open OpenHands at `http://localhost:3000`. On first launch it prompts for an
LLM — configure it once in the **Settings → LLM** page (Advanced → Custom
model):

- **Custom model:** `openai/qwen-local`
- **Base URL:** `http://host.docker.internal:8000/v1`
- **API key:** `local-dgx-key`

This is the *only* way to set the model: the V1 web app reads the LLM from its
profile store (persisted in `OPENHANDS_STATE`), not from `LLM_*` env vars. Once
saved, the setting survives restarts.

### Environment Variables

The LLM is configured in the GUI (above), **not** via env vars. The remaining
vars control ports, logging, and mounts:

| Variable | Default | Description |
|---|---|---|
| `OPENHANDS_TAG` | `latest` | OpenHands image tag (bumped to `1.16.0` as of 2026-08; the image bundles its agent-server, so there is no separate agent-server image to pin) |
| `OPENHANDS_PORT` | `3000` | Host port for the OpenHands UI |
| `LOG_ALL_EVENTS` | `false` | Log all OpenHands events |
| `LOG_LEVEL` | `INFO` | OpenHands log level |
| `WORKSPACE_DIR` | `./workspace` | Workspace mount path |
| `OPENHANDS_STATE` | `./openhands-state` | OpenHands state directory (holds the persisted LLM profile) |

Sandbox (agent-server container) startup timeouts are also hard-coded in
`compose.yml`: `SANDBOX_STARTUP_GRACE_SECONDS=600` and
`OH_APP_CONVERSATION_SANDBOX_STARTUP_TIMEOUT=600` (OpenHands defaults are 15
and 120 — too short for the agent-server image on a macOS Docker VM).

> **Note on `LLM_MODEL` / `LLM_BASE_URL` / `LLM_API_KEY` / `LLM_TIMEOUT`:**
> these container env vars were historically documented here, but in the
> current V1 web app they are ignored. They are only consumed by the V0/CLI
> path (`LLM.load_from_env` + `--override-with-envs`); the web app and its
> agent-server read the LLM solely from the GUI profile store, and the
> `AUTO_FORWARD_PREFIXES` mechanism that used to push `LLM_*` into the
> agent-server no longer exists in the SDK. If you see them in an older
> `compose.yml`, they are inert.

All defaults are listed in the table above; override in `.env`.

### MCP: DuckDuckGo search

A `duckduckgo-mcp` service ships in `compose.yml`, exposing an SSE endpoint at
`http://localhost:8001/sse` on the macOS host.

Add it to OpenHands (Settings > MCP) as:

- **Server type:** SSE
- **URL:** `http://host.docker.internal:8001/sse` (from the OpenHands container)
  or `http://localhost:8001/sse` if OpenHands runs on the host