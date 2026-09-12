# Dockerfile
# DGX Spark local LLM server using vLLM OpenAI-compatible API.
#
# Pinned (multi-arch; pulls arm64 on the Spark). v0.28.0 is the release this
# stack is validated against — it carries the Qwen MTP / fused-GDN decode-kernel
# fixes for the qwen3_5 hybrid-attention architecture. Pin a specific tag rather
# than `nightly`/`latest` so rebuilds do not drift (bump deliberately).
FROM vllm/vllm-openai:v0.28.0-ubuntu2404

ENV DEBIAN_FRONTEND=noninteractive

# Defaults can be overridden in compose.yml or .env
ENV MODEL_NAME=nvidia/Qwen3.8-27B-NVFP4
ENV HOST=0.0.0.0
ENV PORT=8000
ENV API_KEY=local-dgx-key
# Native context. 262144 is the model's native max; with ENABLE_LONG_CONTEXT=1
# the entrypoint instead serves LONG_CONTEXT_MAX_MODEL_LEN via YaRN (see below).
ENV MAX_MODEL_LEN=262144
ENV GPU_MEMORY_UTILIZATION=0.85
# 8 in-flight decodes so up to 8 agent conversations can be served concurrently.
# GB10 is bandwidth-bound: above ~4 the per-token bandwidth tax outweighs the
# continuous-batching gain, so drop back toward 4 via .env if multi-agent
# latency regresses.
ENV MAX_NUM_SEQS=8
ENV MAX_NUM_BATCHED_TOKENS=8192
ENV SERVED_MODEL_NAME=qwen-local
ENV HF_HOME=/root/.cache/huggingface
ENV TRANSFORMERS_CACHE=/root/.cache/huggingface
ENV HF_XET_HIGH_PERFORMANCE=1
# MTP speculative decoding: the checkpoint ships a built-in MTP head, so no
# separate draft model is needed. NUM_SPEC_TOKENS=0 disables it (and restores
# full CUDA graphs). 5 is the sweet spot measured on GB10 (~2x decode).
ENV SPEC_METHOD=mtp
ENV NUM_SPEC_TOKENS=5
# 0 = native 262144 context. 1 = static YaRN RoPE scaling to LONG_CONTEXT_MAX_MODEL_LEN
# (factor 4.0 -> 1,048,576 tokens). Static scaling costs KV memory on every
# request (~36 GiB at 1M) and slightly degrades short-context quality, so it
# stays off unless you actually need the long window.
ENV ENABLE_LONG_CONTEXT=0
ENV LONG_CONTEXT_MAX_MODEL_LEN=1048576

RUN apt-get update && apt-get install -y --no-install-recommends     git     curl     ca-certificates     && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade \
    huggingface_hub \
    "transformers>=5.8.0"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
