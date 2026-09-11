# Local LLM Agent

Run a Qwen model on a DGX Spark and connect to it from macOS using
[Agent Canvas](https://docs.openhands.dev/openhands/usage/agent-canvas/setup).

## `dgx_spark_host/`

Host a Qwen model via vLLM on the DGX Spark machine.

### Run

```bash
cd dgx_spark_host
docker compose up --build
```

The API is available at `http://localhost:8000/v1`. For shared networks, bind to `127.0.0.1` in `compose.yml`.

### Environment Variables

| Variable                 | Default                | Description                                                                    |
|--------------------------|------------------------|--------------------------------------------------------------------------------|
| `MODEL_NAME`             | `Qwen/Qwen3.8-27B-FP8` | Hugging Face model to serve                                                    |
| `SERVED_MODEL_NAME`      | `qwen-local`           | Alias exposed by the API                                                       |
| `HOST`                   | `0.0.0.0`              | Bind address                                                                   |
| `PORT`                   | `8000`                 | Listen port                                                                    |
| `API_KEY`                | `local-dgx-key`        | API key for authentication                                                     |
| `MAX_MODEL_LEN`          | `262144`               | Maximum sequence length                                                        |
| `GPU_MEMORY_UTILIZATION` | `0.85`                 | Fraction of GPU memory to use                                                  |
| `MAX_NUM_SEQS`           | `8`                    | Maximum concurrent sequences                                                   |
| `MAX_NUM_BATCHED_TOKENS` | `8192`                 | Max tokens per batch                                                           |
| `SPEC_METHOD`            | `mtp`                  | Speculative decoding method (the checkpoint ships an MTP head)                 |
| `NUM_SPEC_TOKENS`        | `5`                    | Speculative draft tokens; ~2x decode speed at 3-5, tune per workload           |
| `ENABLE_LONG_CONTEXT`    | `0`                    | `1` stretches context to 1M tokens via YaRN (costs ~36 GiB KV; off by default) |
| `HF_CACHE`               | `./hf-cache`           | Volume mount path for Hugging Face cache                                       |
| `HF_TOKEN`               | *(unset)*              | Hugging Face token for gated models                                            |

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

## `agent_canvas/`

Run [Agent Canvas](https://docs.openhands.dev/openhands/usage/agent-canvas/setup) —
the OpenHands client plus agent-server, automation server, and ingress — as a
single Docker container on macOS, pointed at the local Qwen model.

### Run

```bash
cd agent_canvas
docker compose up -d
```

- SSH Tunnel `ssh -L 8000:localhost:8000 <USERNAME>@<DGX_SPARK_HOST>`.
- Address `http://localhost:8010`.

| Variable     | Value                                 |
|--------------|---------------------------------------|
| Custom model | `openai/qwen-local`                   |
| API base     | `http://host.docker.internal:8000/v1` |
| API key      | `local-dgx-key`                       |


### Environment Variables

| Variable                     | Default                | Description                                                                                                                                                   |
|------------------------------|------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `AGENT_CANVAS_PORT`          | `8010`                 | Host port for the Canvas ingress (avoids 8000, the vLLM SSH tunnel)                                                                                           |
| `AGENT_CANVAS_TAG`           | `latest`               | `ghcr.io/openhands/agent-canvas` image tag; pin for reproducibility                                                                                           |
| `AGENT_CANVAS_STATE`         | `./openhands-state`    | Host dir mounted at `/home/openhands/.openhands` (settings, LLM profile, API key, conversations)                                                              |
| `PROJECTS_DIR`               | `./projects`           | Host dir mounted at `/projects` — the project files canvas agents may work in                                                                                 |
| `AGENT_CANVAS_DOCKER_SOCKET` | `/var/run/docker.sock` | Host Docker socket bind-mounted into the container, so agents drive the host daemon (no nested `dockerd`). Override for non-standard socket paths             |
| `AGENT_CANVAS_PRIVILEGED`    | `false`                | Off: agents use the shared host socket. Set to `true` only to let an agent run its own nested `dockerd` (needs `CAP_SYS_ADMIN`; weakens the sandbox boundary) |
| `LOCAL_BACKEND_API_KEY`      | *(auto-generated)*     | API key for the agent-server API; auto-persisted, required only in `--public` mode                                                                            |
| `OH_SECRET_KEY`              | *(auto-generated)*     | Secret protecting stored settings and secrets                                                                                                                 |
| `OH_AGENT_SERVER_VERSION`    | *(unset)*              | Pin a specific agent-server version                                                                                                                           |

Canvas agents drive the **host** Docker daemon by default: the host socket is
bind-mounted into the container (`AGENT_CANVAS_DOCKER_SOCKET`) and
`DOCKER_HOST` points the in-container client at it, so no nested `dockerd` is
needed. This avoids the docker-in-docker problems — overlay-on-overlay mount
failures, image-layer extraction requiring `CAP_SYS_ADMIN`, a duplicate network
stack — and it also means the container no longer needs `--privileged`
(`AGENT_CANVAS_PRIVILEGED` defaults to `false`). Set it to `true` only if an
agent should run its **own** nested `dockerd` (e.g. the host has no daemon, or
you want the agent's containers isolated from the host daemon).

Trade-off to be aware of: sharing the socket means an agent that escapes its
process sandbox can run arbitrary containers on the host daemon — a weaker
boundary than the nested-daemon setup, which at least kept the agent's
containers on a throwaway daemon. If that is unacceptable for your setup,
remove the socket line from `compose.yml` and set `AGENT_CANVAS_PRIVILEGED=true`.
No GPUs are exposed either way.

## `agent_canvas_native/`

The same Agent Canvas stack — but **native**: UI + agent-server + automation
server + ingress run as local processes via Node.js and uv, with **no Docker**.
Same model, same LLM-profile setup, just without the container sandbox (agents
run as your user on the local filesystem).

### Run

```bash
./agent_canvas_native/install.sh   # one-time (upgrades on re-run)
./agent_canvas_native/run.sh
```

- Address `http://localhost:8020` (avoids 8000, the vLLM tunnel, and 8010, the Docker stack).
- LLM profile: Settings → LLM, provider **OpenAI-compatible**, base `http://localhost:8000/v1`, key `local-dgx-key`, model `Qwen/Qwen3.8-27B-FP8` (or the `qwen-local` alias).

| Variable             | Default                | Description                                                                 |
|----------------------|------------------------|-----------------------------------------------------------------------------|
| `AGENT_CANVAS_PORT`  | `8020`                 | Ingress (UI + proxied API) port                                              |
| `AGENT_CANVAS_STATE` | `./openhands-state`    | Where agent-server keeps per-conversation runtime state (conversations, workspaces, terminal history, logs). API key + LLM profile live in `~/.openhands`. |
| `VLLM_BASE_URL`      | `http://localhost:8000/v1` | Endpoint `run.sh` checks before launch (the value for the LLM profile)   |
| `VLLM_API_KEY`       | `local-dgx-key`        | API key for the vLLM preflight check                                       |

Needs Node.js ≥ 22.12 and `uv`. Ports, overrides, and troubleshooting are
documented in [`agent_canvas_native/README.md`](agent_canvas_native/README.md).
