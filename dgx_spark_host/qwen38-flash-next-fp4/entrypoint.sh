#!/usr/bin/env bash
# entrypoint.sh — serve nvidia/Qwen3.8-Flash-Next-FP4-Local on the DGX Spark.
#
# Runs inside the community B12X container NVIDIA points at for this checkpoint
# (eugr/spark-vllm-b12x), because upstream vLLM does not yet support the NVFP4
# scale-factor format the checkpoint ships. Nothing is built here: this script
# only assembles the `vllm serve` invocation, mirroring the NVIDIA model card's
# DGX Spark recipe (https://huggingface.co/nvidia/Qwen3.8-Flash-Next-FP4-Local).
#
# Defaults below are the model card's DGX Spark values; every one is
# overridable via this stack's .env (compose.yml passes it in via env_file).

set -euo pipefail

# --- serving parameters -----------------------------------------------------
: "${MODEL_NAME:=nvidia/Qwen3.8-Flash-Next-FP4-Local}"
: "${SERVED_MODEL_NAME:=qwen-local}"
: "${HOST:=0.0.0.0}"
: "${PORT:=8000}"
: "${API_KEY:=local-dgx-key}"
: "${MAX_MODEL_LEN:=262144}"
: "${MAX_NUM_SEQS:=8}"
: "${MAX_NUM_BATCHED_TOKENS:=4096}"
: "${GPU_MEMORY_UTILIZATION:=0.8}"
: "${DTYPE:=bfloat16}"
: "${KV_CACHE_DTYPE:=fp8}"
: "${QUANTIZATION:=modelopt_mixed}"
: "${LOAD_FORMAT:=b12x}"
: "${BLOCK_SIZE:=16}"
: "${MAMBA_CACHE_MODE:=align}"
: "${GDN_DECODE_KERNEL:=b12x}"
: "${LINEAR_BACKEND:=b12x}"
: "${MOE_BACKEND:=b12x}"
: "${REASONING_PARSER:=qwen3}"
: "${TOOL_PARSER:=qwen3_xml}"
: "${PREFIX_CACHE:=1}"
: "${FLASHINFER_AUTOTUNE:=0}"
: "${MM_ENCODER_TP_MODE:=data}"
# MTP speculative decoding: the checkpoint ships the MTP module, so no separate
# draft model. MTP=0 disables it.
: "${MTP:=4}"
# JSON default set with an explicit if-block so the quoting is unambiguous.
if [ -z "${COMPILATION_CONFIG:-}" ]; then
  COMPILATION_CONFIG='{"pass_config":{"fuse_act_quant":true}}'
fi

# --- B12X / PLE environment (model card's DGX Spark block) ------------------
# The 51B-parameter n-gram (PLE) embedding table stays in NVMe and is read
# through io_uring, which is what keeps the unified-memory footprint low enough
# for the full 262144-token context on one Spark.
: "${PLE_TABLE_MEMORY:=disk}"
: "${DISK_BACKEND:=io_uring}"
: "${CUTE_DSL_ARCH:=sm_121a}"
: "${USE_AOT_COMPILE:=1}"
: "${USE_V2_MODEL_RUNNER:=1}"

export VLLM_PLE_TABLE_MEMORY="${PLE_TABLE_MEMORY}"
export B12X_DISK_BACKEND="${DISK_BACKEND}"
export CUTE_DSL_ARCH="${CUTE_DSL_ARCH}"
export SAFETENSORS_FAST_GPU=1
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export VLLM_SSM_CONV_STATE_LAYOUT=DS
export VLLM_USE_AOT_COMPILE="${USE_AOT_COMPILE}"
export VLLM_USE_MEGA_AOT_ARTIFACT="${USE_AOT_COMPILE}"
export VLLM_USE_V2_MODEL_RUNNER="${USE_V2_MODEL_RUNNER}"
export B12X_POLICY_MODE=auto
export VLLM_MXFP8_LM_HEAD=1
export VLLM_B12X_MOE_FP4_LAYER_MAX_INPUT_SCALE=w13
export VLLM_B12X_MOE_FP4_FORCE_A16=1
export B12X_W4A16_A4_PREFILL=1

echo "[qwen38-flash-next-fp4] MODEL_NAME=${MODEL_NAME} served_as=${SERVED_MODEL_NAME} ctx=${MAX_MODEL_LEN} seqs=${MAX_NUM_SEQS} gpu_mem=${GPU_MEMORY_UTILIZATION} mtp=${MTP} ple=${PLE_TABLE_MEMORY}" >&2

args=(
  "${MODEL_NAME}"
  --host "${HOST}" --port "${PORT}"
  --api-key "${API_KEY}"
  --served-model-name "${SERVED_MODEL_NAME}"
  --tensor-parallel-size 1
  --pipeline-parallel-size 1
  --mamba-cache-mode "${MAMBA_CACHE_MODE}"
  --dtype "${DTYPE}"
  --kv-cache-dtype "${KV_CACHE_DTYPE}"
  --quantization "${QUANTIZATION}"
  --block-size "${BLOCK_SIZE}"
  --load-format "${LOAD_FORMAT}"
  --max-model-len "${MAX_MODEL_LEN}"
  --max-num-seqs "${MAX_NUM_SEQS}"
  --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS}"
  --enable-chunked-prefill
  --gdn-decode-kernel "${GDN_DECODE_KERNEL}"
  --linear-backend "${LINEAR_BACKEND}"
  --moe-backend "${MOE_BACKEND}"
  --mm-encoder-tp-mode "${MM_ENCODER_TP_MODE}"
  --trust-remote-code
  --enable-auto-tool-choice
  --tool-call-parser "${TOOL_PARSER}"
  --reasoning-parser "${REASONING_PARSER}"
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}"
  --compilation-config "${COMPILATION_CONFIG}"
)

if [ "${PREFIX_CACHE}" = "1" ]; then args+=(--enable-prefix-caching); else args+=(--no-enable-prefix-caching); fi
if [ "${FLASHINFER_AUTOTUNE}" != "1" ]; then args+=(--no-enable-flashinfer-autotune); fi

if [ "${MTP}" != "0" ]; then
  args+=(--speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":${MTP}}")
fi

exec vllm serve "${args[@]}"
