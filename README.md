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

| Variable                  | Default             | Description                                                                                                                                                                       |
|---------------------------|---------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `AGENT_CANVAS_PORT`       | `8010`              | Host port for the Canvas ingress (avoids 8000, the vLLM SSH tunnel)                                                                                                               |
| `AGENT_CANVAS_TAG`        | `latest`            | `ghcr.io/openhands/agent-canvas` image tag; pin for reproducibility                                                                                                               |
| `AGENT_CANVAS_STATE`      | `./openhands-state` | Host dir mounted at `/home/openhands/.openhands` (settings, LLM profile, API key, conversations)                                                                                  |
| `PROJECTS_DIR`            | `./projects`        | Host dir mounted at `/projects` — the project files canvas agents may work in                                                                                                     |
| `AGENT_CANVAS_PRIVILEGED` | `true`              | Run the container with `--privileged` so the in-container Docker can pull images. Set to `false` to restore the stricter sandbox boundary (and give up in-container docker pulls) |
| `LOCAL_BACKEND_API_KEY`   | *(auto-generated)*  | API key for the agent-server API; auto-persisted, required only in `--public` mode                                                                                                |
| `OH_SECRET_KEY`           | *(auto-generated)*  | Secret protecting stored settings and secrets                                                                                                                                     |
| `OH_AGENT_SERVER_VERSION` | *(unset)*           | Pin a specific agent-server version                                                                                                                                               |

The container runs `--privileged` by default so canvas agents can start a
Docker daemon and `docker pull` images (extracting image layers needs
`CAP_SYS_ADMIN`, which the default unprivileged set lacks). Trade-off: a
privileged container weakens the "canvas agents are untrusted, the container
is the sandbox boundary" posture. Set `AGENT_CANVAS_PRIVILEGED=false` in
`.env` to restore that boundary — in-container docker pulls then stop working.
Either way the service still gets no `docker.sock` and no GPUs.
