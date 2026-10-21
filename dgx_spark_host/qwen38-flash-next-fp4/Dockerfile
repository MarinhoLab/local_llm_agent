# Dockerfile — Qwen3.8-Flash-Next FP4-Local on the DGX Spark, vLLM OpenAI-compatible API.
#
# Self-contained per-model stack. All defaults live here; override via .env
# or compose.yml.
#
# Base image: NVIDIA points at the community B12X container for this checkpoint
# (the NVFP4 scale factors use a compressed format upstream vLLM does not read
# yet). `latest` is the tag NVIDIA names; pin a `nightly-YYYYMMDD` sibling here
# for reproducible builds.
FROM eugr/spark-vllm-b12x:latest

ENV DEBIAN_FRONTEND=noninteractive

ENV MODEL_NAME=nvidia/Qwen3.8-Flash-Next-FP4-Local
ENV HOST=0.0.0.0
ENV PORT=8000
ENV API_KEY=local-dgx-key
ENV SERVED_MODEL_NAME=qwen-local
ENV MAX_MODEL_LEN=262144
ENV GPU_MEMORY_UTILIZATION=0.8
ENV MAX_NUM_SEQS=8
ENV MAX_NUM_BATCHED_TOKENS=4096
ENV DTYPE=bfloat16
ENV KV_CACHE_DTYPE=fp8
ENV QUANTIZATION=modelopt_mixed
ENV LOAD_FORMAT=b12x
ENV BLOCK_SIZE=16
ENV MAMBA_CACHE_MODE=align
ENV GDN_DECODE_KERNEL=b12x
ENV LINEAR_BACKEND=b12x
ENV MOE_BACKEND=b12x
ENV REASONING_PARSER=qwen3
ENV TOOL_PARSER=qwen3_xml
ENV PREFIX_CACHE=1
ENV FLASHINFER_AUTOTUNE=0
ENV MM_ENCODER_TP_MODE=data
ENV COMPILATION_CONFIG={"pass_config":{"fuse_act_quant":true}}
ENV MTP=4
ENV PLE_TABLE_MEMORY=disk
ENV DISK_BACKEND=io_uring
ENV CUTE_DSL_ARCH=sm_121a
ENV USE_AOT_COMPILE=1
ENV USE_V2_MODEL_RUNNER=1
ENV HF_HOME=/root/.cache/huggingface
ENV TRANSFORMERS_CACHE=/root/.cache/huggingface
ENV HF_XET_HIGH_PERFORMANCE=1

# entrypoint.sh re-declares every default above with `: "${VAR:=...}"`, so the
# container runs correctly even if this Dockerfile is bypassed via `image:`.
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
