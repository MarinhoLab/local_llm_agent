# Dockerfile
# DGX Spark local LLM server using vLLM OpenAI-compatible API.
#
FROM vllm/vllm-openai:nightly

ENV DEBIAN_FRONTEND=noninteractive

# Defaults can be overridden in compose.yml or .env
ENV MODEL_NAME=nvidia/Qwen3.8-27B-NVFP4
ENV HOST=0.0.0.0
ENV PORT=8000
ENV API_KEY=local-dgx-key
ENV MAX_MODEL_LEN=262144
ENV GPU_MEMORY_UTILIZATION=0.80
ENV MAX_NUM_SEQS=4
ENV MAX_NUM_BATCHED_TOKENS=8192
ENV SERVED_MODEL_NAME=qwen-local
ENV HF_HOME=/root/.cache/huggingface
ENV TRANSFORMERS_CACHE=/root/.cache/huggingface
ENV HF_XET_HIGH_PERFORMANCE=1
ENV SPEC_METHOD=mtp
ENV NUM_SPEC_TOKENS=3

RUN apt-get update && apt-get install -y --no-install-recommends     git     curl     ca-certificates     && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade \
    huggingface_hub \
    "transformers>=5.8.0"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
