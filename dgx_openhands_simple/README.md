# DGX the retired client + Qwen3.6

## Server (DGX)

```bash
cd dgx_the retired client_simple
cp .env.example .env
docker compose build --no-cache
docker compose up -d
docker logs -f qwen-vllm
```

the retired client will be available on:

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

Inside the retired client:

```text
/workspace
```

## Useful Commands

```bash
docker logs -f the retired client
docker logs -f qwen-vllm
docker restart the retired client
docker restart qwen-vllm
docker compose down
```