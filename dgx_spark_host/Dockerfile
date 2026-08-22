# Dockerfile
# DGX Spark local LLM server using vLLM OpenAI-compatible API.

FROM vllm/vllm-openai:v0.27.1-ubuntu2404

ENV DEBIAN_FRONTEND=noninteractive

# Defaults can be overridden in compose.yml or .env
# Qwen3.8-27B is NVFP4 with a built-in MTP head (see entrypoint.sh).
ENV MODEL_NAME=unsloth/Qwen3.8-27B-NVFP4
ENV HOST=0.0.0.0
ENV PORT=8000
ENV API_KEY=local-dgx-key
ENV MAX_MODEL_LEN=262144
ENV GPU_MEMORY_UTILIZATION=0.8
ENV MAX_NUM_SEQS=4
ENV MAX_NUM_BATCHED_TOKENS=8192
ENV SERVED_MODEL_NAME=qwen-local
ENV HF_HOME=/root/.cache/huggingface
ENV TRANSFORMERS_CACHE=/root/.cache/huggingface
ENV HF_XET_HIGH_PERFORMANCE=1

RUN apt-get update && apt-get install -y --no-install-recommends     git     curl     ca-certificates     && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir -U huggingface_hub

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
