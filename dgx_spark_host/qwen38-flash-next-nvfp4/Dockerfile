# Dockerfile — Qwen3.8-Flash-Next NVFP4 on the DGX Spark, vLLM OpenAI-compatible API.
#
# Self-contained per-model stack. All defaults live here; override via .env
# or compose.yml.
#
# Unlike the stack this replaces, this one builds nothing: a stock vLLM nightly
# plus a gated weight download from Hugging Face.
FROM vllm/vllm-openai:nightly

ENV DEBIAN_FRONTEND=noninteractive

ENV MODEL_NAME=nvidia/Qwen3.8-Flash-Next-NVFP4
ENV HOST=0.0.0.0
ENV PORT=8000
ENV API_KEY=local-dgx-key
ENV MAX_MODEL_LEN=262144
# 0.80 is the repo-wide ceiling; the published single-Spark recipes for this
# checkpoint use 0.80 too. The ~51 GB PLE n-gram table lives in unified memory
# at these settings -- see README "Tuning notes" before hosting other workloads.
ENV GPU_MEMORY_UTILIZATION=0.80
ENV MAX_NUM_SEQS=4
ENV MAX_NUM_BATCHED_TOKENS=4096
ENV SERVED_MODEL_NAME=qwen-local
ENV HF_HOME=/root/.cache/huggingface
ENV TRANSFORMERS_CACHE=/root/.cache/huggingface
ENV HF_XET_HIGH_PERFORMANCE=1
ENV SPEC_METHOD=mtp
ENV NUM_SPEC_TOKENS=3
# PLE n-gram table placement: 1 = keep the ~51 GB table out of the GPU budget
# (the published recipes' trick for fitting one Spark), 0 = let the engine hold
# it normally. If boot fails on OOM, this is the first thing to flip.
ENV PLE_CPU_OFFLOAD=1
# Long-context extension via YaRN; off by default (native 262,144).
# Set MAX_MODEL_LEN=1048576 together with ROPE_SCALING to use it.
ENV ROPE_SCALING=

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade \
    huggingface_hub \
    "transformers>=5.8.0"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
