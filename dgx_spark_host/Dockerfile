# Dockerfile
# DGX Spark local LLM server using vLLM OpenAI-compatible API.
#
# vLLM v0.28.0 (2026-08-26) was the current `latest` tag when this was pinned.
# Pin a specific version instead of `latest`: Qwen3.8 needs the qwen3_5
# hybrid-attention support and Qwen MTP/fused-GDN fixes that landed in
# v0.27/v0.28, and `latest` silently drifts on every rebuild. The -ubuntu2404
# variant is multi-arch (arm64 for the GB10). Bump deliberately when a newer
# vLLM release is tested.

FROM vllm/vllm-openai:v0.28.0-ubuntu2404

ENV DEBIAN_FRONTEND=noninteractive

# Defaults can be overridden in compose.yml or .env
ENV MODEL_NAME=Qwen/Qwen3.8-27B-FP8
ENV HOST=0.0.0.0
ENV PORT=8000
ENV API_KEY=local-dgx-key
ENV MAX_MODEL_LEN=262144
ENV GPU_MEMORY_UTILIZATION=0.85
ENV MAX_NUM_SEQS=8
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
