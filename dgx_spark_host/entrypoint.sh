#!/usr/bin/env bash
set -euo pipefail

exec vllm serve "${MODEL_NAME}"   \
--host "${HOST}" \
--port "${PORT}" \
--dtype auto \
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
--speculative-config '{"method":"mtp","num_speculative_tokens":3}' \
--load-format fastsafetensors \
--enable-auto-tool-choice \
--tool-call-parser qwen3_coder \
--reasoning-parser qwen3 \
--language-model-only \
--api-key "${API_KEY}" \
