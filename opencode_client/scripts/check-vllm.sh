#!/usr/bin/env bash
#
# check-vllm.sh — verify the DGX vLLM endpoint that OpenCode will use.
#
# Validates, independently of OpenCode:
#   1. the endpoint is reachable and authenticated (GET /v1/models);
#   2. the expected model ID (default qwen-local) is advertised;
#   3. a minimal chat-completions smoke test returns the expected token.
#
# Usage:
#   ./opencode_client/scripts/check-vllm.sh
#
# Reads OPENCODE_BASE_URL / OPENCODE_API_KEY / OPENCODE_MODEL_ID from the
# environment; falls back to opencode_client/.env, then to the documented
# defaults. Exits non-zero if any check fails.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091  # lib path is computed at runtime
source "${SCRIPT_DIR}/lib_vllm.sh"

# Load .env if present (defaults are already set by the lib; existing
# environment variables take precedence over .env).
if [[ -f "${CLIENT_DIR}/.env" ]]; then
  vllm_load_env "${CLIENT_DIR}/.env"
fi
# OPENCODE_MODEL_ID defaults to qwen-local in the lib; .env can override it.
MODEL_ID="${OPENCODE_MODEL_ID}"

echo "== check-vllm =="
echo "base url : ${OPENCODE_BASE_URL}"
echo "model id : ${MODEL_ID}"
echo

fail=0
check_vllm_endpoint || fail=1
check_vllm_model "${MODEL_ID}" || fail=1
check_vllm_chat "OPENCODE_VLLM_OK" "${MODEL_ID}" || fail=1

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "RESULT: all vLLM checks passed — the endpoint is ready for OpenCode."
else
  echo "RESULT: one or more vLLM checks failed. See messages above."
fi
exit "${fail}"
