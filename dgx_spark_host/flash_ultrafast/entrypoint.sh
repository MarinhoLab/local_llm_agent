#!/usr/bin/env bash
# entrypoint.sh — run the Qwen3.8 Flash DGX UltraFast "v16b" serving recipe
# inside the (pre-built) patched vLLM image produced by the upstream repo
# https://github.com/dime-online/qwen3.8-Flash-DGX-UltraFast
#
# This entrypoint does NOT build anything: the patched image, the checkpoint,
# the FP8 PLE table, and the T80 drafter + draft vocab are prepared one time
# by setup-upstream.sh (which delegates to the upstream build scripts). This
# script only assembles the pinned v16b `vllm serve` invocation and preflights
# the mounted assets.
#
# Pinned defaults below are the upstream promoted v16b values
# (recipe/config/v16b/env + serve.sh). Every value is overridable via .env.

set -euo pipefail

# --- assets (mounted read-only into the container by compose.yml) ----------
MODEL_DIR="${FLASH_MODEL_DIR:-/model}"
TABLE_DIR="${FLASH_TABLE_DIR:-/ple-table}"
DRAFT_VOCAB="${FLASH_DRAFT_VOCAB:-/draft-vocab/ids.txt}"

# --- v16b serving parameters (defaults = promoted values) ------------------
: "${SERVED_NAME:=qwen}"
: "${HOST:=0.0.0.0}"
: "${PORT:=8000}"
: "${LOAD_FORMAT:=fastsafetensors}"
: "${CTX:=262144}"
: "${SEQS:=8}"
: "${GPU_MEM:=0.01}"
: "${KV_BYTES:=16g}"
: "${PREFIX_CACHE:=1}"
: "${MTP:=3}"
: "${TOOL_PARSER:=qwen3_xml}"
: "${REASONING_PARSER:=qwen3}"
: "${MAX_NUM_BATCHED_TOKENS:=8192}"
: "${FLASHINFER_AUTOTUNE:=0}"
: "${PIN_PROMPT:=}"
: "${PIN_MAX_FRACTION:=0.25}"
# JSON defaults are set with explicit if-blocks (not `: :=`) so the quoting is
# unambiguous; both are still overridable via .env.
if [ -z "${SPEC_EXTRA:-}" ]; then
  SPEC_EXTRA='{"rejection_sample_method":"block","draft_sample_method":"probabilistic"}'
fi
# CUDA-graph compilation flags (the patched image understands the -cc. prefix;
# twelve splitting ops keep PLE CPU gathering outside graph capture).
: "${CC_CUDAGRAPH_MODE:=PIECEWISE}"
if [ -z "${CC_SPLITTING_OPS:-}" ]; then
  CC_SPLITTING_OPS='["vllm::unified_attention_with_output","vllm::unified_mla_attention_with_output","vllm::mamba_mixer2","vllm::mamba_mixer","vllm::short_conv","vllm::qwen3_8_flash_next_ple_short_conv","vllm::qwen3_8_flash_next_qsa_with_output","vllm::linear_attention","vllm::qwen_gdn_attention_core","vllm::qwen_gdn_attention_core_fused_norm_packed","vllm::sparse_attn_indexer","vllm::ple_mmap_lookup"]'
fi

# --- preflight: the mounted assets must be present -------------------------
fail=0
for pair in "checkpoint:${MODEL_DIR}" "PLE table:${TABLE_DIR}" "draft vocab:${DRAFT_VOCAB}"; do
  label="${pair%%:*}"; path="${pair#*:}"
  if [ ! -e "${path}" ]; then
    echo "ERROR: ${label} not found at ${path}." >&2
    echo "       Run setup-upstream.sh first (it downloads/builds these assets)." >&2
    fail=1
  fi
done
[ "${fail}" -eq 0 ] || exit 1

echo "[flash_ultrafast] SERVED_NAME=${SERVED_NAME}  ctx=${CTX}  seqs=${SEQS}  gpu_mem=${GPU_MEM}  kv=${KV_BYTES}  mtp=${MTP}" >&2

# --- build the vllm argument list (mirrors upstream recipe/config/v16b/serve.sh) ---
args=(
  "${MODEL_DIR}"
  --served-model-name "${SERVED_NAME}"
  --host "${HOST}" --port "${PORT}"
  --load-format "${LOAD_FORMAT}"
  --max-model-len "${CTX}"
  --max-num-seqs "${SEQS}"
  --gpu-memory-utilization "${GPU_MEM}"
  --enable-chunked-prefill
  --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS}"
  --kv-cache-dtype auto
  --kv-cache-memory-bytes "${KV_BYTES}"
  --enable-prompt-tokens-details
  --enable-auto-tool-choice
  --tool-call-parser "${TOOL_PARSER}"
  --reasoning-parser "${REASONING_PARSER}"
)

# Prefix caching (on by default in v16b).
if [ "${PREFIX_CACHE}" = "1" ]; then args+=(--enable-prefix-caching); fi

# CUDA-graph compilation flags (the -cc. prefixed pair).
args+=("-cc.cudagraph_mode=${CC_CUDAGRAPH_MODE}" "-cc.splitting_ops=${CC_SPLITTING_OPS}")

# FlashInfer autotune (off by default in v16b).
if [ "${FLASHINFER_AUTOTUNE}" = "1" ]; then :; else args+=(--no-enable-flashinfer-autotune); fi

# Optional pinned-prompt prefix-cache retention.
if [ -n "${PIN_PROMPT}" ] && [ "${PREFIX_CACHE}" = "1" ]; then
  args+=(--never-evict-kv-cache-prompt-includes "${PIN_PROMPT}"
         --never-evict-kv-cache-max-fraction "${PIN_MAX_FRACTION}")
fi

# MTP speculative decoding (depth 3 by default); merge any extra spec options.
if [ "${MTP}" != "0" ]; then
  spec="{\"method\":\"mtp\",\"num_speculative_tokens\":${MTP}}"
  if [ -n "${SPEC_EXTRA}" ]; then
    if command -v python3 >/dev/null 2>&1; then
      spec="$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); a.update(b); print(json.dumps(a))' "${spec}" "${SPEC_EXTRA}")"
    elif command -v jq >/dev/null 2>&1; then
      spec="$(jq -c -n --argjson a "${spec}" --argjson b "${SPEC_EXTRA}" '$a + $b')"
    else
      echo "ERROR: SPEC_EXTRA is set but neither python3 nor jq is available to merge it." >&2
      exit 1
    fi
  fi
  args+=(--speculative-config "${spec}")
fi

exec vllm serve "${args[@]}"
