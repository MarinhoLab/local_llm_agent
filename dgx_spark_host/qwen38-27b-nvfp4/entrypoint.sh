#!/usr/bin/env bash
set -euo pipefail

# Self-contained entrypoint for the Qwen3.8-27B NVFP4 stack
# (nvidia/Qwen3.8-27B-NVFP4, NVIDIA Model Optimizer NVFP4+FP8 quantization,
# ~22 GB). Composes the `vllm serve` command from the env defaults set in
# this stack's Dockerfile; everything is overridable via .env / compose.

SPECULATIVE_CONFIG='{"method":"'"${SPEC_METHOD}"'","num_speculative_tokens":'"${NUM_SPEC_TOKENS}"'}'

echo "[entrypoint] NVFP4 stack: MODEL_NAME=${MODEL_NAME}  gpu_mem_util=${GPU_MEMORY_UTILIZATION}" >&2

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
