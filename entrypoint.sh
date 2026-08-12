#!/usr/bin/env bash
set -euo pipefail

exec vllm serve "${MODEL_NAME}" \
  --host 0.0.0.0 \
  --port 8000 \
  --dtype auto \
  --served-model-name "${SERVED_MODEL_NAME}" \
  --max-model-len "${MAX_MODEL_LEN}" \
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}" \
  --max-num-seqs "${MAX_NUM_SEQS}" \
  --enable-prefix-caching \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_xml \
  --reasoning-parser qwen3 \
  --language-model-only \
  --api-key "${API_KEY}"