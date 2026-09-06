---
name: docker-usage
description: >-
  How to work with the Docker stacks in this repository (the DGX Spark vLLM
  server and the macOS OpenHands client), including compose commands, GPU and
  volume setup, the SSH tunnel, host.docker.internal networking, .env handling,
  and everyday container operations and troubleshooting.
license: MIT
compatibility: Docker + Docker Compose; NVIDIA Container Toolkit on the Spark
triggers:
  - docker
  - docker compose
  - dockerfile
  - container
  - vllm container
  - openhands container
  - start the stack
  - gpu not available
---

This repository is **three independent Docker stacks**; two must run on two
different machines. Get the mapping right first:

| Stack | Directory | Machine | What it runs | Command |
|---|---|---|---|---|
| vLLM server | `dgx_spark_host/` | NVIDIA DGX Spark (aarch64, GPU) | Qwen3.8-27B (NVFP4) served at `:8000/v1` | `docker compose -f compose.yml up --build` |
| OpenHands client | `macos_client/` | macOS | OpenHands container (UI `:3000`) + DuckDuckGo MCP | `docker compose up` |
| Agent Canvas | `agent_canvas/` | macOS | Canvas UI `:8010/canvas` + agent-server + automation server + ingress (single container) | `docker compose up -d` |

They talk to each other over an **SSH tunnel** (see below). There is no single
compose file that spans both machines.

## Bringing a stack up

**DGX Spark (server)** — first run downloads ~24 GB of weights:

```bash
cd dgx_spark_host
docker compose -f compose.yml up --build
```

**macOS (client)** — needs the tunnel first (below), then:

```bash
cd macos_client
cp example.env .env          # first time only; then fill in LLM_*/OPENHANDS_*
mkdir -p workspace openhands-state
docker compose up
```

The client reaches the model at `http://host.docker.internal:8000/v1`, and the
agent-server reaches DuckDuckGo at `http://host.docker.internal:8001/sse`.

**Agent Canvas** — needs the tunnel too:

```bash
cd agent_canvas
cp example.env .env        # first time only; keep bind paths Mac-absolute when
mkdir -p openhands-state projects   # also driven from the OpenHands sandbox
docker compose up -d       # UI: http://localhost:8010/canvas
```

LLM profile: set in Settings → LLM (base URL `http://host.docker.internal:8000/v1`,
model `qwen-local`, key `local-dgx-key`) or via API — `POST /api/profiles/<name>`
+ `/activate` with the session key from
`openhands-state/agent-canvas/api-key.txt` (see README). Deliberately no
`docker.sock`/`gpus`: canvas agents are untrusted, the container is the
sandbox boundary. When driving this stack from the OpenHands sandbox, run
`bash agent_canvas/sync_to_mac.sh` first — the sandbox filesystem is not a
path the Mac's Docker daemon can bind (its `/workspace` is a virtiofs share,
not the Mac checkout), so compose files and bind dirs must live in the Mac
checkout (`/Users/user/git/local_llm_agent`).

## The SSH tunnel (why `host.docker.internal:8000` works)

Before starting the macOS stack, forward the Spark's vLLM port to the Mac in a
separate terminal:

```bash
ssh -L 8000:localhost:8000 USER@DGX_SPARK_IP
```

- `dgx_spark_host/compose.yml` publishes `8000:8000`; the tunnel maps that onto
  the Mac's `localhost:8000`.
- `macos_client/compose.yml` sets `extra_hosts: host.docker.internal:host-gateway`,
  so from inside the OpenHands container `host.docker.internal:8000` resolves
  back to the Mac's localhost — i.e. through the tunnel — to the Spark.
- If `docker compose up` starts before the tunnel, LLM calls fail with
  connection-refused. Fix the tunnel, then `docker compose restart openhands`.

## Docker-specific config that matters here

Read the `Dockerfile`/`compose.yml` before changing any of these — most are
deliberate:

- **`gpus: all` + `ipc: host`** in `dgx_spark_host/compose.yml` require the
  **NVIDIA Container Toolkit** on the Spark. If the container starts but the
  log shows no GPU / vLLM OOMs, the toolkit is missing or not on the PATH.
- **`HF_CACHE:-./hf-cache:/root/.cache/huggingface`** persists downloaded weights
  across runs. Do not delete it or the next start re-downloads ~24 GB.
- **`pull_policy: always`** on the OpenHands image plus
  `${OPENHANDS_TAG}` — the tag must track the agent-server version bundled in
  the base image or you get version-skew failures.
- **`SANDBOX_VOLUMES`** on the OpenHands service mounts `${WORKSPACE_DIR}:/workspace:rw`
  and the docker socket into the agent's sandbox container, so the agent can
  run containers and edit the workspace.
- **`stdin_open: true` / `tty: true`** keep the OpenHands container's shell
  interactive for terminal actions.

## Everyday container operations

```bash
# Which stack? Always be explicit with -f in dgx_spark_host; default in macos_client.
docker compose -f dgx_spark_host/compose.yml logs -f --tail=200 qwen-vllm
docker compose -f dgx_spark_host/compose.yml ps
docker compose -f dgx_spark_host/compose.yml down            # stop, keep volumes
docker compose -f dgx_spark_host/compose.yml down -v         # also remove volumes

docker compose logs -f --tail=200 openhands
docker compose restart openhands
docker compose down

cd agent_canvas   # or: docker compose -f agent_canvas/compose.yml ...
sudo docker compose up -d
sudo docker compose logs -f --tail=200 agent-canvas
sudo docker compose restart agent-canvas
sudo docker compose down

# One-off shell / exec into a running container
docker exec -it dgx-qwen-vllm bash
docker exec -it openhands bash
docker exec -it agent-canvas bash
```

## `.env` and secrets (do not leak)

- `.env` files are local-only and git-ignored. `macos_client/example.env` is the
  tracked template — copy it to a local `.env` and fill the real values there.
  (The tracked template keeps only non-secret defaults; the LLM is now
  configured in the OpenHands GUI, not in `.env` — see README.)
- The vLLM API key (`local-dgx-key`) is a local placeholder — vLLM does not
  authenticate, so it is not a real secret, but never commit a real one.
- If a token is ever committed, rotate it at the provider and purge it from git
  history (`git filter-repo`).

## Troubleshooting quick hits

- **`port is already allocated`** — a previous container or tunnel holds the port.
  `docker compose -f ... ps` + `lsof -i :8000` (or `:3000`/`:8001`/`:8010`) to find the
  holder; stop it or `docker compose down` the stack.
- **GPU not visible in the vLLM container** — NVIDIA Container Toolkit not
  installed/enabled on the Spark host; `docker run --rm --gpus all nvidia/cuda:12.4.0-base nvidia-smi`.
- **`host.docker.internal` does not resolve** — the service lacks the
  `extra_hosts`/`host-gateway` mapping (or you are not on Docker Desktop).
- **Stale build after `Dockerfile`/env change** — rebuild with
  `docker compose -f dgx_spark_host/compose.yml up --build` (or add `--no-cache`).
- **Sandbox can't reach the network** — the agent's sandbox is a separate
  container launched from the OpenHands container; `host.docker.internal`
  resolves to the Mac, not the sandbox, so LLM/MCP URLs must point at the Mac.
