---
name: docker-usage
description: >-
  How to work with the Docker stacks in this repository (the DGX Spark vLLM
  server and the Agent Canvas client), including compose commands, GPU and
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

This repository is **two independent Docker stacks**; they must run on two
different machines. Get the mapping right first:

| Stack | Directory | Machine | What it runs | Command |
|---|---|---|---|---|
| vLLM server | `dgx_spark_host/` | NVIDIA DGX Spark (aarch64, GPU) | Qwen3.8-27B (FP8) served at `:8000/v1` | `docker compose -f compose.yml up --build` |
| Agent Canvas | `agent_canvas/` | macOS | Canvas UI `:8010/canvas` + agent-server + automation server + ingress (single container) | `docker compose up -d` |

They talk to each other over an **SSH tunnel** (see below). There is no single
compose file that spans both machines.

## Bringing a stack up

**DGX Spark (server)** — first run downloads ~24 GB of weights:

```bash
cd dgx_spark_host
docker compose -f compose.yml up --build
```

**Agent Canvas** — needs the tunnel first (below), then:

```bash
cd agent_canvas
cp example.env .env        # first time only; keep bind paths Mac-absolute when
mkdir -p openhands-state projects   # also driven from the OpenHands sandbox
docker compose up -d       # UI: http://localhost:8010/canvas
```

The Canvas UI reaches the model at `http://host.docker.internal:8000/v1`.

LLM profile: set in Settings → LLM (base URL `http://host.docker.internal:8000/v1`,
model `openai/qwen-local`, key `local-dgx-key`) or via API — `POST /api/profiles/<name>`
+ `/activate` with the session key from
`openhands-state/agent-canvas/api-key.txt` (see README). The container runs
`--privileged` by default (`AGENT_CANVAS_PRIVILEGED=true`) so the in-container
Docker can pull images — see "Docker inside the Canvas container" below. No
`docker.sock`/`gpus` are exposed.

### When driving this stack from the OpenHands sandbox

The sandbox's filesystem is **not** a path the Mac's Docker daemon can bind
(the sandbox's `/workspace` is a virtiofs share, not the Mac checkout), so the
compose file and the bind dirs must live in the Mac checkout
(`/Users/user/git/local_llm_agent`). The old `agent_canvas/sync_to_mac.sh`
helper has been removed. The supported flow is now **push to the remote and
pull on the Mac**:

1. From the sandbox: commit and push your changes to `origin`.
2. On the Mac: `git -C /Users/user/git/local_llm_agent pull`, then
   `cd agent_canvas && sudo docker compose pull && sudo docker compose up -d`
   (`pull` + `up -d` because `AGENT_CANVAS_TAG` may have moved).

The `.env` on the Mac uses Mac-absolute bind paths for `AGENT_CANVAS_STATE` /
`PROJECTS_DIR`, so the Mac daemon can mount them. Do not try to `docker compose
up` from the sandbox against the Mac daemon.

## The SSH tunnel (why `host.docker.internal:8000` works)

Before starting the macOS stack, forward the Spark's vLLM port to the Mac in a
separate terminal:

```bash
ssh -L 8000:localhost:8000 USER@DGX_SPARK_IP
```

- `dgx_spark_host/compose.yml` publishes `8000:8000`; the tunnel maps that onto
  the Mac's `localhost:8000`.
- `agent_canvas/compose.yml` sets `extra_hosts: host.docker.internal:host-gateway`,
  so from inside the Canvas container `host.docker.internal:8000` resolves
  back to the Mac's localhost — i.e. through the tunnel — to the Spark.
- If `docker compose up` starts before the tunnel, LLM calls fail with
  connection-refused. Fix the tunnel, then `docker compose restart agent-canvas`.

## Docker-specific config that matters here

Read the `Dockerfile`/`compose.yml` before changing any of these — most are
deliberate:

- **`gpus: all` + `ipc: host`** in `dgx_spark_host/compose.yml` require the
  **NVIDIA Container Toolkit** on the Spark. If the container starts but the
  log shows no GPU / vLLM OOMs, the toolkit is missing or not on the PATH.
- **`HF_CACHE:-./hf-cache:/root/.cache/huggingface`** persists downloaded weights
  across runs. Do not delete it or the next start re-downloads ~24 GB.
- **`AGENT_CANVAS_TAG`** — the `ghcr.io/openhands/agent-canvas` image is
  multi-arch (pulls arm64 on Apple Silicon). Pin a specific tag in `.env` before
  a release for reproducibility; otherwise `docker compose pull` +
  `docker compose up -d` to update.
- **`AGENT_CANVAS_STATE`** (mounted at `/home/openhands/.openhands`) persists
  settings, the LLM profile, the session API key, and conversation data — it
  survives `--rm` / image updates. Do not delete it or you lose the persisted
  profile and history.
- **No `docker.sock`, no `gpus`** on the Canvas container: `PROJECTS_DIR`
  (mounted at `/projects`) is the only host path the agents can touch. The
  container is otherwise `--privileged` (see below) so agents can run their own
  Docker daemon.
- **`AGENT_CANVAS_PRIVILEGED`** (default `true`) — the Canvas container runs
  with `--privileged` so the in-container Docker can `docker pull`. A nested
  daemon must extract image layers, which needs `CAP_SYS_ADMIN` to mount /
  `unshare`; the default *unprivileged* capability set (`CapBnd 0xa80425fb`,
  no `CAP_SYS_ADMIN`/`CAP_NET_ADMIN`) can't do it. Set it to `false` to restore
  the "canvas agents are untrusted, the container is the sandbox boundary"
  posture — in-container docker pulls then stop working.

## Docker inside the Canvas container (nested daemon)

The Canvas image ships the `docker` client and `dockerd` (and passwordless
`sudo`). An agent in the container can run its own daemon to build/pull/run
images — this is what `--privileged` enables. Inside the container:

```bash
sudo dockerd --iptables=false --bridge=none &   # nested daemon
# wait for the socket, then:
sudo docker pull <image>
```

- `--iptables=false --bridge=none` are needed because the nested daemon shares
  the container's network namespace; the host's iptables are off-limits.
- Without `--privileged` (i.e. `AGENT_CANVAS_PRIVILEGED=false`), `dockerd`
  starts but `docker pull` fails at layer extraction with
  `operation not permitted` — on the default `overlayfs` driver the bind-mount
  of the snapshot is denied, and the `vfs` driver still fails on `unshare`.
  That's exactly why this flag exists; don't try to work around it.
- The nested daemon's state lives in the container's `/var/lib/docker`; it is
  not one of the persistent mounts and is lost when the container is removed.

## Everyday container operations

```bash
# Which stack? Always be explicit with -f in dgx_spark_host; default in agent_canvas.
docker compose -f dgx_spark_host/compose.yml logs -f --tail=200 qwen-vllm
docker compose -f dgx_spark_host/compose.yml ps
docker compose -f dgx_spark_host/compose.yml down            # stop, keep volumes
docker compose -f dgx_spark_host/compose.yml down -v         # also remove volumes

cd agent_canvas   # or: docker compose -f agent_canvas/compose.yml ...
sudo docker compose up -d
sudo docker compose logs -f --tail=200 agent-canvas
sudo docker compose restart agent-canvas
sudo docker compose down

# One-off shell / exec into a running container
docker exec -it dgx-qwen-vllm bash
docker exec -it agent-canvas bash
```

## `.env` and secrets (do not leak)

- `.env` files are local-only and git-ignored. `agent_canvas/example.env` is the
  tracked template — copy it to a local `.env` and fill the real values there.
  The LLM is configured in the Canvas GUI (Settings → LLM), not in `.env` — see
  README.
- The vLLM API key (`local-dgx-key`) is a local placeholder — vLLM does not
  authenticate, so it is not a real secret, but never commit a real one.
- If a token is ever committed, rotate it at the provider and purge it from git
  history (`git filter-repo`).

## Troubleshooting quick hits

- **`port is already allocated`** — a previous container or tunnel holds the port.
  `docker compose -f ... ps` + `lsof -i :8000` (or `:8010`) to find the
  holder; stop it or `docker compose down` the stack.
- **GPU not visible in the vLLM container** — NVIDIA Container Toolkit not
  installed/enabled on the Spark host; `docker run --rm --gpus all nvidia/cuda:12.4.0-base nvidia-smi`.
- **`host.docker.internal` does not resolve** — the service lacks the
  `extra_hosts`/`host-gateway` mapping (or you are not on Docker Desktop).
- **Stale build after `Dockerfile`/env change** — rebuild with
  `docker compose -f dgx_spark_host/compose.yml up --build` (or add `--no-cache`).
- **A container can't reach the Spark** — it lacks the
  `extra_hosts: host.docker.internal:host-gateway` mapping, or the SSH tunnel
  is down. `host.docker.internal` resolves to the Mac, so LLM/MCP URLs must go
  through the tunnel at `http://host.docker.internal:8000/v1`.
