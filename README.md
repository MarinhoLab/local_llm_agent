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
| `MODEL_NAME` | `unsloth/Qwen3.8-27B-NVFP4` | Hugging Face model to serve |
| `SERVED_MODEL_NAME` | `qwen-local` | Alias exposed by the API |
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8000` | Listen port |
| `API_KEY` | `local-dgx-key` | API key for authentication |
| `MAX_MODEL_LEN` | `262144` | Maximum sequence length |
| `GPU_MEMORY_UTILIZATION` | `0.8` | Fraction of GPU memory to use |
| `MAX_NUM_SEQS` | `4` | Maximum concurrent sequences |
| `MAX_NUM_BATCHED_TOKENS` | `8192` | Max tokens per batch |
| `SPEC_METHOD` | `mtp` | Speculative decoding method (the checkpoint ships an MTP head) |
| `NUM_SPEC_TOKENS` | `5` | Speculative draft tokens; ~2x decode speed at 3-5, tune per workload |
| `ENABLE_LONG_CONTEXT` | `0` | `1` stretches context to 1M tokens via YaRN (costs ~36 GiB KV; off by default) |
| `HF_CACHE` | `./hf-cache` | Volume mount path for Hugging Face cache |
| `HF_TOKEN` | *(unset)* | Hugging Face token for gated models |

All vLLM defaults are set in `Dockerfile`; override via `.env` or `compose.yml`.

Tuning notes (DGX Spark, GB10, 128 GB unified memory, LLM-only box):

- **Model**: Qwen3.8-27B NVFP4 (23.4 GB) with a built-in MTP head. MTP
  speculative decoding roughly doubles decode speed (~11 -> ~24 tok/s
  single-stream, measured on GB10). `--language-model-only` drops the vision
  tower for KV headroom; drop the flag if you need image inputs.
- **Memory**: `GPU_MEMORY_UTILIZATION` is a fraction of the unified CPU+GPU
  pool. 0.8 is appropriate when the Spark runs nothing but the LLM; lower it
  if you host other workloads on the box.
- **Concurrency**: keep `MAX_NUM_SEQS` at 4 or below; above that the
  per-token bandwidth tax outweighs continuous-batching gains on GB10.
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
mkdir -p workspace openhands-state
docker compose up
```

Open OpenHands at `http://localhost:3000`. Configure the model as:

- **Custom model:** `openai/qwen-local`
- **Base URL:** `http://host.docker.internal:8000/v1`
- **API key:** `local-dgx-key`

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `OPENHANDS_TAG` | `1.8` | OpenHands image tag |
| `OPENHANDS_PORT` | `3000` | Host port for the OpenHands UI |
| `AGENT_SERVER_IMAGE_REPOSITORY` | `ghcr.io/openhands/agent-server` | Agent-server image repo |
| `AGENT_SERVER_IMAGE_TAG` | `1.42.1-python` | Agent-server image tag (keep in sync with the OpenHands image) |
| `LLM_MODEL` | `openai/qwen-local` | LLM model identifier |
| `LLM_BASE_URL` | `http://host.docker.internal:8000/v1` | LLM API endpoint |
| `LLM_API_KEY` | `local-dgx-key` | LLM API key |
| `LOG_ALL_EVENTS` | `true` | Log all OpenHands events |
| `WORKSPACE_DIR` | `./workspace` | Workspace mount path |
| `OPENHANDS_STATE` | `./openhands-state` | OpenHands state directory |

All defaults are listed in the table above; override in `.env`.

### MCP: DuckDuckGo search

A `duckduckgo-mcp` service ships in `compose.yml`, exposing an SSE endpoint at
`http://localhost:8001/sse` on the macOS host.

Add it to OpenHands (Settings > MCP) as:

- **Server type:** SSE
- **URL:** `http://host.docker.internal:8001/sse` (from the OpenHands container)
  or `http://localhost:8001/sse` if OpenHands runs on the host