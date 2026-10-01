# Dockerfile
# DGX Spark local LLM server using vLLM OpenAI-compatible API.
#
FROM vllm/vllm-openai:nightly

ENV DEBIAN_FRONTEND=noninteractive

# Selectable model configurations (see entrypoint.sh):
#   MODEL_CONFIG=nvfp4  -> nvidia/Qwen3.8-27B-NVFP4   (NVFP4+FP8, ~22 GB) [default]
#   MODEL_CONFIG=b16    -> Qwen/Qwen3.8-27B           (official BF16, ~55 GB)
# Per-checkpoint defaults (MODEL_NAME, GPU_MEMORY_UTILIZATION, SPEC_METHOD,
# NUM_SPEC_TOKENS) are applied by entrypoint.sh based on MODEL_CONFIG; they can
# still be overridden in .env or compose.yml.

# Selection knob + defaults that are the same for both configurations.
ENV MODEL_CONFIG=nvfp4
ENV HOST=0.0.0.0
ENV PORT=8000
ENV API_KEY=local-dgx-key
ENV MAX_MODEL_LEN=262144
ENV MAX_NUM_SEQS=8
ENV MAX_NUM_BATCHED_TOKENS=8192
ENV SERVED_MODEL_NAME=qwen-local
ENV HF_HOME=/root/.cache/huggingface
ENV TRANSFORMERS_CACHE=/root/.cache/huggingface
ENV HF_XET_HIGH_PERFORMANCE=1

RUN apt-get update && apt-get install -y --no-install-recommends     git     curl     ca-certificates     && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade \
    huggingface_hub \
    "transformers>=5.8.0"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
