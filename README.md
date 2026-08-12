# DGX the retired client + Qwen3.6

## Server (DGX)

Do once to configure

```bash
cp .env.example .env
docker compose build --no-cache
```

```bash
docker compose up
```

the retired client will be available on:

```text
http://<dgx-ip>:3000
```

## Client (macOS)

```bash
ssh -L 3000:localhost:3000 <username>@<dgx-ip>
```

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

Inside the retired client:

```text
/workspace
```

## the retired client config

```text
Provider: OpenAI
Model: qwen-local
Base URL: http://qwen-vllm:8000/v1
API Key: local-dgx-key
```

## Useful Commands

```bash
docker logs -f the retired client
docker logs -f qwen-vllm
docker restart the retired client
docker restart qwen-vllm
docker compose down
```