#!/usr/bin/env bash
set -euo pipefail

# Self-contained entrypoint for the Qwen3.8-Flash-Next NVFP4 stack
# (nvidia/Qwen3.8-Flash-Next-NVFP4, NVIDIA Model Optimizer's official
# mixed-precision quant of Qwen/Qwen3.8-Flash-Next: NVFP4 routed experts,
# FP8 MTP experts + PLE table). Composes `vllm serve` from the env defaults
# set in this stack's Dockerfile; everything is overridable via .env / compose.

set -u

# PLE n-gram table placement is an engine env var, not a serve flag: it keeps
# the ~51 GB table out of the gpu-memory-utilization budget, which is what lets
# this checkpoint fit one Spark.
if [[ "${PLE_CPU_OFFLOAD}" == "1" ]]; then
  export VLLM_PLE_CPU_OFFLOAD=1
fi

ARGS=(
  --host "${HOST}"
  --port "${PORT}"
  --served-model-name "${SERVED_MODEL_NAME}"
  --max-model-len "${MAX_MODEL_LEN}"
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}"
  --max-num-seqs "${MAX_NUM_SEQS}"
  --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS}"
  --quantization modelopt
  --trust-remote-code
  --seed 0
  --speculative-config "{\"method\":\"${SPEC_METHOD}\",\"num_speculative_tokens\":${NUM_SPEC_TOKENS}}"
  --enable-chunked-prefill
  --enable-auto-tool-choice
  --tool-call-parser qwen3_xml
  --reasoning-parser qwen3
  --api-key "${API_KEY}"
)

# --no-enable-flashinfer-autotune: keeps the first warmup bounded to seconds on
# GB10 (NVIDIA's own documented serve snippet uses it).
ARGS+=(--no-enable-flashinfer-autotune)

if [[ -n "${ROPE_SCALING}" ]]; then
  ARGS+=(--hf-overrides "{\"rope_scaling\":${ROPE_SCALING}}")
fi

echo "[entrypoint] flash-next-nvfp4: model=${MODEL_NAME} len=${MAX_MODEL_LEN} seqs=${MAX_NUM_SEQS} ple_offload=${PLE_CPU_OFFLOAD}" >&2

# First boot downloads ~133 GB into the mounted HF cache; slow NVMe makes that
# look like a hang. Say so instead of going quiet.
if [[ ! -d "${HF_HOME}/hub/models--nvidia--Qwen3.8-Flash-Next-NVFP4" ]]; then
  echo "[entrypoint] first run: downloading ~133 GB of weights into ${HF_HOME} (hours on slow NVMe; watch ~/.cache/huggingface for progress)" >&2
fi

exec vllm serve "${MODEL_NAME}" "${ARGS[@]}"
