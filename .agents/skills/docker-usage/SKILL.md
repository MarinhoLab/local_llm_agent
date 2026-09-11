---
name: docker-usage
description: >-
  How to work with the Docker stack in this repository (the DGX Spark vLLM
  server), including compose commands, GPU and volume setup, the SSH tunnel,
  .env handling, and everyday container operations and troubleshooting.
license: MIT
compatibility: Docker + Docker Compose; NVIDIA Container Toolkit on the Spark
triggers:
  - docker
  - docker compose
  - dockerfile
  - container
  - vllm container
  - start the stack
  - gpu not available
---

This repository has **one Docker stack** — the DGX Spark vLLM server. The
Agent Canvas client and the OpenCode client run **natively** (no Docker); see
`agent_canvas_native/` and `opencode_client/` respectively.

| Stack | Directory | Machine | What it runs | Command |
|---|---|---|---|---|
| vLLM server | `dgx_spark_host/` | NVIDIA DGX Spark (aarch64, GPU) | Qwen3.8-27B (FP8) served at `:8000/v1` | `docker compose -f compose.yml up --build` |

The macOS-side clients reach the model over an **SSH tunnel** (see below).
There is no Docker compose on the Mac.

## Bringing the stack up

**DGX Spark (server)** — first run downloads ~24 GB of weights:

```bash
cd dgx_spark_host
docker compose -f compose.yml up --build
```

The API is available at `http://localhost:8000/v1` on the Spark.

## The SSH tunnel (why the Mac can reach the model)

The vLLM server binds on the Spark; the Mac clients can't reach it directly, so
forward the Spark's vLLM port to the Mac in a separate terminal:

```bash
ssh -L 8000:localhost:8000 USER@DGX_SPARK_IP
```

- `dgx_spark_host/compose.yml` publishes `8000:8000`; the tunnel maps that onto
  the Mac's `localhost:8000`.
- The native Agent Canvas stack (`agent_canvas_native`) and the OpenCode client
  both target `http://localhost:8000/v1` on the Mac, which resolves through the
  tunnel to the Spark.
- If the server is restarted or the tunnel drops, model calls fail with
  connection-refused. Fix the tunnel, then retry.

## Docker-specific config that matters here

Read the `Dockerfile`/`compose.yml` before changing any of these — most are
deliberate:

- **`gpus: all` + `ipc: host`** in `dgx_spark_host/compose.yml` require the
  **NVIDIA Container Toolkit** on the Spark. If the container starts but the
  log shows no GPU / vLLM OOMs, the toolkit is missing or not on the PATH.
- **`HF_CACHE:-./hf-cache:/root/.cache/huggingface`** persists downloaded weights
  across runs. Do not delete it or the next start re-downloads ~24 GB.
- All runtime defaults live as `ENV` in `dgx_spark_host/Dockerfile`;
  `entrypoint.sh` composes the `vllm serve` command from those variables. Keep
  the README's env-var table in sync when changing defaults.

## Everyday container operations

```bash
# vLLM server (DGX Spark)
docker compose -f dgx_spark_host/compose.yml logs -f --tail=200 qwen-vllm
docker compose -f dgx_spark_host/compose.yml ps
docker compose -f dgx_spark_host/compose.yml down            # stop, keep volumes
docker compose -f dgx_spark_host/compose.yml down -v         # also remove volumes

# One-off shell / exec into a running container
docker exec -it dgx-qwen-vllm bash
```

## `.env` and secrets (do not leak)

- `.env` files are local-only and git-ignored. `dgx_spark_host` reads
  `HF_CACHE`/`HF_TOKEN` from `.env` when present (compose defaults work without
  it). Copy the tracked template to a local `.env` and fill the real values
  there.
- The vLLM API key (`local-dgx-key`) is a local placeholder — vLLM does not
  authenticate, so it is not a real secret, but never commit a real one.
- If a token is ever committed, rotate it at the provider and purge it from git
  history (`git filter-repo`).

## Troubleshooting quick hits

- **`port is already allocated`** — a previous container or tunnel holds the
  port. `docker compose -f ... ps` + `lsof -i :8000` to find the holder; stop it
  or `docker compose down` the stack.
- **GPU not visible in the vLLM container** — NVIDIA Container Toolkit not
  installed/enabled on the Spark host;
  `docker run --rm --gpus all nvidia/cuda:12.4.0-base nvidia-smi`.
- **Stale build after `Dockerfile`/env change** — rebuild with
  `docker compose -f dgx_spark_host/compose.yml up --build` (or add `--no-cache`).
