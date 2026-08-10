# DGX Spark Qwen vLLM Server

Run this directory on the DGX Spark. It serves a Qwen model through vLLM's OpenAI-compatible API.

## Quick start

```bash
cp .env.example .env
docker compose up --build
```

The server listens on:

```text
http://localhost:8000/v1
```

Default served model alias:

```text
qwen-local
```

## Safer networking

For a shared network, edit `compose.yml` and change:

```yaml
ports:
  - "8000:8000"
```

to:

```yaml
ports:
  - "127.0.0.1:8000:8000"
```

Then access it from the macOS client stack through SSH tunnelling.
