# Dockerfile
# DGX Spark local LLM server using vLLM OpenAI-compatible API.
# Build with: docker compose build

FROM vllm/vllm-openai:latest

ENV DEBIAN_FRONTEND=noninteractive

# Defaults can be overridden in docker-compose.yml or .env
ENV MODEL_NAME=Qwen/Qwen2.5-72B-Instruct
ENV HOST=0.0.0.0
ENV PORT=8000
ENV API_KEY=local-dgx-key
ENV MAX_MODEL_LEN=32768
ENV GPU_MEMORY_UTILIZATION=0.85
ENV MAX_NUM_SEQS=1
ENV SERVED_MODEL_NAME=qwen-local

# Hugging Face cache and faster downloads
ENV HF_HOME=/root/.cache/huggingface
ENV TRANSFORMERS_CACHE=/root/.cache/huggingface
ENV HF_HUB_ENABLE_HF_TRANSFER=1

# Small set of debugging utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir -U "huggingface_hub[hf_transfer]"

EXPOSE 8000

# vLLM exposes an OpenAI-compatible API at /v1
CMD vllm serve "${MODEL_NAME}" \
    --host "${HOST}" \
    --port "${PORT}" \
    --dtype auto \
    --served-model-name "${SERVED_MODEL_NAME}" \
    --max-model-len "${MAX_MODEL_LEN}" \
    --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}" \
    --max-num-seqs "${MAX_NUM_SEQS}" \
    --enable-prefix-caching \
    --api-key "${API_KEY}"
