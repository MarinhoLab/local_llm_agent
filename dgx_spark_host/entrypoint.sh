#!/usr/bin/env bash
set -euo pipefail

# Assemble the full `vllm serve` argv in one array (so the final expansion is
# always non-empty — safe under `set -u` even on bash 3.2, which the macOS dev
# machine runs for the dry-run) and append the conditional flags below.
VLLM_ARGS=(
  serve
  "${MODEL_NAME}"
  --host "${HOST}"
  --port "${PORT}"
  --limit-mm-per-prompt '{"image":4}'
  --served-model-name "${SERVED_MODEL_NAME}"
  --max-model-len "${MAX_MODEL_LEN}"
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}"
  --max-num-seqs "${MAX_NUM_SEQS}"
  --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS}"
  --trust-remote-code
  --seed 0
  --kv-cache-dtype fp8_e4m3
  --enable-chunked-prefill
  --enable-prefix-caching
  --enable-auto-tool-choice
  --tool-call-parser qwen3_coder
  --reasoning-parser qwen3
  --api-key "${API_KEY}"
)

# MTP speculative decoding: the checkpoint ships a built-in MTP head, so no
# separate draft model is needed (no "model" field). Roughly doubles decode on
# GB10. Set NUM_SPEC_TOKENS=0 to disable it — 0 is the only value that also
# restores full (vs PIECEWISE) CUDA graphs.
if [[ "${NUM_SPEC_TOKENS}" != "0" ]]; then
  VLLM_ARGS+=(
    "--speculative-config" '{"method":"'"${SPEC_METHOD}"'","num_speculative_tokens":'"${NUM_SPEC_TOKENS}"'}'
  )
fi

# ~1M-token context via static YaRN RoPE scaling. Off by default: static scaling
# degrades short-context quality, so enable only when you actually need 1M.
# The override must land in text_config.rope_parameters and keep the mrope_*
# fields (or multimodal image/video RoPE breaks). factor 4.0 -> 262144*4 = 1048576.
if [[ "${ENABLE_LONG_CONTEXT}" == "1" ]]; then
  export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
  # Serve the long-context window instead of the native one. Locate the
  # --max-model-len entry and overwrite its value (bash 3.2-safe, no
  # parameter-substitution patterns).
  for i in "${!VLLM_ARGS[@]}"; do
    if [[ "${VLLM_ARGS[i]}" == "--max-model-len" ]]; then
      VLLM_ARGS[i+1]="${LONG_CONTEXT_MAX_MODEL_LEN}"
      break
    fi
  done
  VLLM_ARGS+=(
    "--hf-overrides" '{"text_config":{"rope_parameters":{"rope_type":"yarn","factor":4.0,"original_max_position_embeddings":262144,"mrope_interleaved":true,"mrope_section":[11,11,10],"partial_rotary_factor":0.25,"rope_theta":10000000}}}'
  )
fi

exec vllm "${VLLM_ARGS[@]}"
