# Local LLM Agent

Run a Qwen model on a DGX Spark and connect to it from macOS using OpenHands and Aider.

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

Run OpenHands and Aider on macOS, connecting to the DGX Spark vLLM server.

### Run

```bash
cd macos_client
cp .env.example .env
mkdir -p workspace openhands-state
# Edit .env: set DGX_SSH_TARGET=USER@DGX_SPARK_IP
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
| `DGX_SSH_TARGET` | *(required)* | SSH target for DGX Spark (`user@host`) |
| `DGX_REMOTE_HOST` | `localhost` | Remote host for SSH tunnel |
| `DGX_REMOTE_PORT` | `8000` | Remote port for SSH tunnel |
| `LOCAL_TUNNEL_PORT` | `8000` | Local port for SSH tunnel |
| `SSH_DIR` | `${HOME}/.ssh` | SSH configuration directory |
| `SSH_EXTRA_OPTS` | *(unset)* | Additional SSH options |
| `AIDER_MODEL` | `openai/qwen-local` | Model used by Aider |
| `OPENAI_API_BASE` | `http://host.docker.internal:8000/v1` | API base for Aider |
| `GITCONFIG` | `${HOME}/.gitconfig` | Git config mount path |

Defaults are in `compose.yml` and `.env.example`; override in `.env`.
