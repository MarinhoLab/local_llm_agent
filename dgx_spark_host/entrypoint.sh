#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_NAME:=nvidia/Qwen3.6-27B-NVFP4}"
: "${HOST:=0.0.0.0}"
: "${PORT:=8000}"
: "${API_KEY:=local-dgx-key}"
: "${MAX_MODEL_LEN:=65536}"
: "${GPU_MEMORY_UTILIZATION:=0.85}"
: "${MAX_NUM_SEQS:=1}"
: "${SERVED_MODEL_NAME:=qwen-local}"

exec vllm serve "${MODEL_NAME}"   --host "${HOST}"   --port "${PORT}"   --dtype auto   --served-model-name "${SERVED_MODEL_NAME}"   --max-model-len "${MAX_MODEL_LEN}"   --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}"   --max-num-seqs "${MAX_NUM_SEQS}"   --enable-prefix-caching   --enable-auto-tool-choice --tool-call-parser qwen3_coder --reasoning-parser qwen3 --language-model-only --api-key "${API_KEY}"
