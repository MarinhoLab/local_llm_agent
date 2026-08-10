# Dockerfile
# DGX Spark local LLM server using vLLM OpenAI-compatible API.

FROM vllm/vllm-openai:latest

ENV DEBIAN_FRONTEND=noninteractive

# Defaults can be overridden in compose.yml or .env
ENV MODEL_NAME=Qwen/Qwen3-Coder-30B-A3B-Instruct
ENV HOST=0.0.0.0
ENV PORT=8000
ENV API_KEY=local-dgx-key
ENV MAX_MODEL_LEN=32768
ENV GPU_MEMORY_UTILIZATION=0.85
ENV MAX_NUM_SEQS=1
ENV SERVED_MODEL_NAME=qwen-local

# Hugging Face cache and high-performance Xet transfers.
ENV HF_HOME=/root/.cache/huggingface
ENV TRANSFORMERS_CACHE=/root/.cache/huggingface
ENV HF_XET_HIGH_PERFORMANCE=1

RUN apt-get update && apt-get install -y --no-install-recommends     git     curl     ca-certificates     && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir -U huggingface_hub

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
