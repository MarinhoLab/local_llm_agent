#!/usr/bin/env bash
set -euo pipefail

# Qwen3.8-27B (NVFP4) hybrid-attention model.
# - The checkpoint ships a built-in MTP head (registered in the safetensors
#   index), so speculative decoding needs only method + num_speculative_tokens.
#   MTP roughly doubles decode speed (~11 -> ~24 tok/s single stream on GB10).
# - `--language-model-only` drops the ~0.5 GB vision tower for KV headroom.
# - Tool calls use the Qwen3-Coder format (<tool_call> tags with <function=...>),
#   reasoning uses <think>...</think> blocks (see the model's chat template).
# - fp8 KV cache halves KV memory (37 KB/token); it is the checkpoint's
#   native scheme, so it must stay enabled.

SPECULATIVE_CONFIG='{"method":"'"${SPEC_METHOD:-mtp}"'","num_speculative_tokens":'"${NUM_SPEC_TOKENS:-5}"'}'

EXTRA_ARGS=()
# Native max_position_embeddings is 262144. Set ENABLE_LONG_CONTEXT=1 to
# stretch to 1048576 with YaRN (factor 4.0). YaRN is static and costs KV
# memory (~36 GiB at 1M); keep it off for agentic workloads.
if [ "${ENABLE_LONG_CONTEXT:-0}" = "1" ]; then
  MAX_MODEL_LEN=1048576
  EXTRA_ARGS+=(
    --hf-overrides '{"text_config":{"rope_parameters":{"rope_type":"yarn","factor":4.0,"original_max_position_embeddings":262144,"mrope_interleaved":true,"mrope_section":[11,11,10],"partial_rotary_factor":0.25,"rope_theta":10000000}}}'
  )
fi

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
--speculative-config "${SPECULATIVE_CONFIG}" \
--load-format fastsafetensors \
--enable-auto-tool-choice \
--tool-call-parser qwen3_coder \
--reasoning-parser qwen3 \
--language-model-only \
--api-key "${API_KEY}" \
"${EXTRA_ARGS[@]}"
