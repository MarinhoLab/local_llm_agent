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
| `MODEL_NAME` | `nvidia/Qwen3.6-27B-NVFP4` | Hugging Face model to serve |
| `SERVED_MODEL_NAME` | `qwen-local` | Alias exposed by the API |
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8000` | Listen port |
| `API_KEY` | `local-dgx-key` | API key for authentication |
| `MAX_MODEL_LEN` | `262144` | Maximum sequence length |
| `GPU_MEMORY_UTILIZATION` | `0.5` | Fraction of GPU memory to use |
| `MAX_NUM_SEQS` | `8` | Maximum concurrent sequences |
| `MAX_NUM_BATCHED_TOKENS` | `8192` | Max tokens per batch |
| `HF_CACHE` | `./hf-cache` | Volume mount path for Hugging Face cache |
| `HF_TOKEN` | *(unset)* | Hugging Face token for gated models |

All vLLM defaults are set in `Dockerfile`; override via `.env` or `compose.yml`.

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
| `AGENT_SERVER_IMAGE_TAG` | `1.26.0-python` | Agent-server image tag |
| `LLM_MODEL` | `openai/qwen-local` | LLM model identifier |
| `LLM_BASE_URL` | `http://host.docker.internal:8000/v1` | LLM API endpoint |
| `LLM_API_KEY` | `local-dgx-key` | LLM API key |
| `LOG_ALL_EVENTS` | `true` | Log all OpenHands events |
| `WORKSPACE_DIR` | `./workspace` | Workspace mount path |
| `OPENHANDS_STATE` | `./openhands-state` | OpenHands state directory |

All defaults are listed in the table above; override in `.env`.
