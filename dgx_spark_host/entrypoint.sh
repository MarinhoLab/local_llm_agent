#!/usr/bin/env bash
set -euo pipefail

# --- selectable model configurations ----------------------------------------
# MODEL_CONFIG picks which checkpoint variant to serve:
#   nvfp4 (default) : NVIDIA Model Optimizer NVFP4+FP8 quantization,
#                     nvidia/Qwen3.8-27B-NVFP4 (~22 GB).
#   b16             : official Qwen checkpoint in BF16, Qwen/Qwen3.8-27B
#                     (~55 GB).
# Both ship a 1-layer MTP head, so MTP speculative decoding works on either.
#
# Per-config defaults are applied only when the variable is not already set in
# the environment (i.e. via .env / compose override), so everything stays
# overridable; the config merely sets sensible defaults per checkpoint.

MODEL_CONFIG="${MODEL_CONFIG:-nvfp4}"

case "${MODEL_CONFIG}" in
  nvfp4)
    : "${MODEL_NAME:=nvidia/Qwen3.8-27B-NVFP4}"
    : "${GPU_MEMORY_UTILIZATION:=0.80}"
    : "${SPEC_METHOD:=mtp}"
    : "${NUM_SPEC_TOKENS:=5}"
    ;;
  b16)
    : "${MODEL_NAME:=Qwen/Qwen3.8-27B}"
    : "${GPU_MEMORY_UTILIZATION:=0.70}"
    : "${SPEC_METHOD:=mtp}"
    : "${NUM_SPEC_TOKENS:=5}"
    ;;
  *)
    echo "ERROR: MODEL_CONFIG='${MODEL_CONFIG}' is not recognized." >&2
    echo "Valid values: nvfp4, b16" >&2
    exit 1
    ;;
esac

SPECULATIVE_CONFIG='{"method":"'"${SPEC_METHOD}"'","num_speculative_tokens":'"${NUM_SPEC_TOKENS}"'}'

echo "[entrypoint] MODEL_CONFIG=${MODEL_CONFIG}  MODEL_NAME=${MODEL_NAME}  gpu_mem_util=${GPU_MEMORY_UTILIZATION}" >&2

exec vllm serve "${MODEL_NAME}"   \
--host "${HOST}" \
--port "${PORT}" \
--limit-mm-per-prompt '{"image":4}' \
--served-model-name "${SERVED_MODEL_NAME}" \
--max-model-len "${MAX_MODEL_LEN}" \
--gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}" \
--max-num-seqs "${MAX_NUM_SEQS}" \
--max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS}" \
--trust-remote-code \
--seed 0 \
--kv-cache-dtype fp8_e4m3 \
--speculative-config "${SPECULATIVE_CONFIG}" \
--enable-chunked-prefill \
--enable-prefix-caching \
--enable-auto-tool-choice \
--tool-call-parser qwen3_coder \
--reasoning-parser qwen3 \
--api-key "${API_KEY}"
