#!/usr/bin/env bash
set -euo pipefail

SPECULATIVE_CONFIG='{"method":"'"${SPEC_METHOD}"'","num_speculative_tokens":'"${NUM_SPEC_TOKENS}"'}'

exec vllm serve "${MODEL_NAME}"   \
--host "${HOST}" \
--port "${PORT}" \
--dtype auto \
--limit-mm-per-prompt '{"image":4}' \
--served-model-name "${SERVED_MODEL_NAME}" \
--max-model-len "${MAX_MODEL_LEN}" \
--gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}" \
--max-num-seqs "${MAX_NUM_SEQS}" \
--max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS}" \
--trust-remote-code \
--kv-cache-dtype fp8 \
--enable-chunked-prefill \
--async-scheduling \
--enable-prefix-caching \
--speculative-config "${SPECULATIVE_CONFIG}" \
--load-format fastsafetensors \
--enable-auto-tool-choice \
--tool-call-parser qwen3_coder \
--reasoning-parser qwen3 \
--api-key "${API_KEY}"
