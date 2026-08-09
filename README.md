# DGX Spark Qwen Agent Setup

This archive separates the setup into two parts.

## `dgx_spark_host/`

Run on the DGX Spark. It hosts vLLM and Qwen.

```bash
cd dgx_spark_host
cp .env.example .env
docker compose -f compose.yml up --build
```

## `macos_client/`

Run on macOS. It starts OpenHands, Aider, and an SSH tunnel to the DGX Spark.

```bash
cd macos_client
cp .env_host.example .env
mkdir -p workspace openhands-state
# edit .env and set DGX_SSH_TARGET=USER@DGX_SPARK_IP
docker compose -f compose_host.yml up
```
