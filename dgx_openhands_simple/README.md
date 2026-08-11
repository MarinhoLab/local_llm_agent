# DGX OpenHands + Qwen3.6

## Server (DGX)

```bash
cd dgx_openhands_simple
cp .env.example .env
docker compose build --no-cache
docker compose up -d
docker logs -f qwen-vllm
```

OpenHands will be available on:

```text
http://<dgx-ip>:3000
```

## Client (macOS)

```bash
ssh -L 3000:localhost:3000 <user>@<dgx-ip>
```

Then open:

```text
http://localhost:3000
```

in your browser.

## Workspace

Place repositories under:

```text
workspace/
```

Example:

```bash
cd workspace
git clone <repository-url>
```

Inside OpenHands:

```text
/workspace
```

## Useful Commands

```bash
docker logs -f openhands
docker logs -f qwen-vllm
docker restart openhands
docker restart qwen-vllm
docker compose down
```