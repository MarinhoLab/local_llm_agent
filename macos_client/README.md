# macOS Client: OpenHands, Aider, and Continue.dev

Run this directory on macOS. It creates a tunnel to the DGX Spark vLLM server and starts OpenHands and Aider.

## Prerequisites

Before starting, establish an SSH tunnel to your DGX Spark host:

```bash
ssh -L 8000:localhost:8000 USER@DGX_SPARK_IP
```

## Quick start

```bash
cp .env.example .env
mkdir -p workspace openhands-state
# edit .env and set DGX_SSH_TARGET=USER@DGX_SPARK_IP
docker compose up
```

Open OpenHands at:

```text
http://localhost:3000
```

If OpenHands asks for model settings:

```text
Custom model: openai/qwen-local
Base URL: http://host.docker.internal:8000/v1
API key: local-dgx-key
```

## Aider

```bash
docker exec -it aider-dgx bash
cd /workspace/YOUR_REPO
aider --model openai/qwen-local --edit-format diff
```

## Continue.dev in PyCharm

```bash
mkdir -p ~/.continue
cp continue-config.yaml ~/.continue/config.yaml
```

Then reload Continue.dev in PyCharm.
