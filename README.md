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

Open OpenHands at `http://localhost:3000`. The LLM is **pre-configured from
`.env`**: a small `oh-bootstrap` sidecar (see `oh_bootstrap.py`) copies
`LLM_MODEL` / `LLM_BASE_URL` / `LLM_API_KEY` into the OpenHands settings store
on every start, plus the DuckDuckGo MCP server and — if `TAVILY_API_KEY` is set
— the Tavily MCP server. It is idempotent (a no-op once configured) and the
`.env` file is the source of truth for the model and base URL.

To **change** the LLM later, either edit `.env` (takes effect on next
`docker compose up`), or use **Settings → LLM** in the GUI. If you edit the GUI
and also have the `.env` values set, the `.env` wins on the next start.

Why a sidecar: the V1 web app does *not* read `LLM_*` / `TAVILY_API_KEY` from
the environment — it reads the LLM and MCP servers from its own settings store
(GUI: *Settings → LLM* / *Settings → MCP*), persisted in `OPENHANDS_STATE`. The
sidecar writes through the same V1 API the GUI uses. Full rationale:
`MEMORIES.md`.

### Environment Variables

The LLM and MCP servers are configured via `.env` (written into OpenHands by
the `oh-bootstrap` sidecar), with the GUI as an alternative. The remaining
vars control ports, logging, and mounts:

| Variable | Default | Description |
|---|---|---|
| `OPENHANDS_TAG` | `latest` | OpenHands image tag (bumped to `1.16.0` as of 2026-08; the image bundles its agent-server, so there is no separate agent-server image to pin) |
| `OPENHANDS_PORT` | `3000` | Host port for the OpenHands UI |
| `LOG_ALL_EVENTS` | `false` | Log all OpenHands events |
| `LOG_LEVEL` | `INFO` | OpenHands log level |
| `WORKSPACE_DIR` | `./workspace` | Workspace mount path |
| `OPENHANDS_STATE` | `./openhands-state` | OpenHands state directory (holds the persisted LLM profile + MCP config) |
| `LLM_MODEL` | `openai/qwen-local` | LLM model id written into OpenHands by the bootstrap |
| `LLM_BASE_URL` | `http://host.docker.internal:8000/v1` | vLLM base URL (through the SSH tunnel) |
| `LLM_API_KEY` | `local-dgx-key` | Placeholder key (vLLM does not authenticate); a key you set by hand in the GUI is preserved |
| `LLM_PROFILE_NAME` | `openai_qwen-local` | Name of the saved LLM profile in the GUI (matches the GUI's own naming for the default model) |
| `DUCKDUCKGO_MCP_URL` | `http://host.docker.internal:8001/sse` | SSE URL of the local DuckDuckGo MCP service |
| `TAVILY_URL` | `https://mcp.tavily.com/mcp` | Tavily MCP endpoint |
| `TAVILY_API_KEY` | *(empty)* | Tavily API key — leave blank to skip registering Tavily; keep the real key in the git-ignored `.env` only |

Blank `LLM_MODEL` disables LLM bootstrapping (GUI-only); blank
`TAVILY_API_KEY` disables Tavily.

Sandbox (agent-server container) startup timeouts are also hard-coded in
`compose.yml`: `SANDBOX_STARTUP_GRACE_SECONDS=600` and
`OH_APP_CONVERSATION_SANDBOX_STARTUP_TIMEOUT=600` (OpenHands defaults are 15
and 120 — too short for the agent-server image on a macOS Docker VM).

> **Note on `LLM_MODEL` / `LLM_BASE_URL` / `LLM_API_KEY` / `LLM_TIMEOUT`:**
> the OpenHands web app itself does *not* read these container env vars — they
> are only consumed by the V0/CLI path (`LLM.load_from_env` +
> `--override-with-envs`), and the `AUTO_FORWARD_PREFIXES` mechanism that once
> pushed `LLM_*` into the agent-server no longer exists in the SDK. In this
> stack the `oh-bootstrap` sidecar reads them from `.env` (via compose
> interpolation) and writes them into the OpenHands settings store, which is
> why they work here without being "container env vars" as far as the web app
> is concerned. `LLM_TIMEOUT` is still a no-op: the V1 web app uses the SDK
> default (300s) per-LLM-request timeout with no env knob.

All defaults are listed in the table above; override in `.env`.

### MCP: DuckDuckGo search (and optionally Tavily)

A `duckduckgo-mcp` service ships in `compose.yml`, exposing an SSE endpoint at
`http://localhost:8001/sse` on the macOS host. The `oh-bootstrap` sidecar
registers it in OpenHands automatically on each start (from
`DUCKDUCKGO_MCP_URL` in `.env`), so there is nothing to add by hand. If you
prefer to do it manually, add it under **Settings > MCP** as:

- **Server type:** SSE
- **URL:** `http://host.docker.internal:8001/sse` (from the OpenHands container)
  or `http://localhost:8001/sse` if OpenHands runs on the host

Tavily (remote, key required) is registered the same way: set `TAVILY_API_KEY`
in `.env` and the bootstrap adds the `streamable-http` server at `TAVILY_URL`.
Leave the key blank to keep Tavily off. Keep the real key in the git-ignored
`.env` only — never commit it. Details in
`.agents/skills/mcp-search-servers/SKILL.md`.