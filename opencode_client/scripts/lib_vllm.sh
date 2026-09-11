# shellcheck shell=bash
#
# lib_vllm.sh — shared defaults and vLLM endpoint checks for the OpenCode client.
#
# Sourced by check-vllm.sh and launch-opencode.sh. Sourcing this file does not
# print anything or access the network.
#
# Configuration is read from the environment first, then from
# opencode_client/.env (which the scripts source before using these functions).
# Any variable still unset falls back to the stack's documented defaults, so
# the scripts work out of the box against a fresh dgx_spark_host deployment.

# --- defaults (must match dgx_spark_host/ and example.env) ---
: "${OPENCODE_PROVIDER_ID:=dgx-vllm}"
: "${OPENCODE_PROVIDER_NAME:=DGX Spark vLLM}"
: "${OPENCODE_MODEL_ID:=qwen-local}"
: "${OPENCODE_MODEL_NAME:=Qwen3.8-27B-FP8}"
: "${OPENCODE_BASE_URL:=http://127.0.0.1:8000/v1}"
: "${OPENCODE_API_KEY:=local-dgx-key}"
: "${OPENCODE_CONTEXT_LENGTH:=262144}"
: "${OPENCODE_OUTPUT_LENGTH:=16384}"
: "${OPENCODE_REQUEST_TIMEOUT:=120}"

# --- helpers ---

# vllm_load_env <file> — source a .env file, but variables already present in
# the environment win. This keeps one-off overrides such as
#   OPENCODE_MODEL_ID=other ./scripts/check-vllm.sh
# working even when .env sets the same variable. Precedence:
#   environment > .env > built-in defaults (set below).
vllm_load_env() {
  local file="$1" kv
  local -a saved=()
  while IFS= read -r kv; do
    [[ -n "${kv}" ]] && saved+=("${kv}")
  done < <(env | grep -E '^OPENCODE_[A-Z0-9_]+=' || true)
  # shellcheck disable=SC1090  # caller verified the file exists
  source "${file}"
  for kv in ${saved[@]+"${saved[@]}"}; do
    export "${kv}"
  done
}

# Print the port the tunnel must forward, derived from OPENCODE_BASE_URL
# (the port of the client-side URL). Defaults to 8000 when the URL carries
# no explicit numeric port.
vllm_tunnel_port() {
  local rest="${OPENCODE_BASE_URL#*://}"   # strip scheme
  local port="${rest#*:}"                  # strip host up to the port
  port="${port%%/*}"                       # strip any path
  if [[ "${port}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${port}"
  else
    printf '8000\n'
  fi
}

# check_vllm_endpoint — GET /models must return HTTP 200.
# Prints one line describing the result; returns 0 on success.
check_vllm_endpoint() {
  local url="${OPENCODE_BASE_URL%/}/models"
  local code
  code="$(curl -sS --max-time "${OPENCODE_REQUEST_TIMEOUT}" -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${OPENCODE_API_KEY}" "${url}" 2>&1)" || {
    echo "  FAIL: endpoint unreachable at ${url} (${code})"
    return 1
  }
  if [[ "${code}" -ne 200 ]]; then
    echo "  FAIL: endpoint returned HTTP ${code} (expected 200). Wrong key or no tunnel?"
    return 1
  fi
  echo "  ok: endpoint reachable and authenticated (${url})"
}

# check_vllm_model <model-id> — the model must be advertised by /models.
# Returns 0 when advertised.
check_vllm_model() {
  local model_id="$1"
  local url="${OPENCODE_BASE_URL%/}/models"
  local body
  body="$(curl -sS --max-time "${OPENCODE_REQUEST_TIMEOUT}" \
    -H "Authorization: Bearer ${OPENCODE_API_KEY}" "${url}" 2>/dev/null)" || {
    echo "  FAIL: could not fetch ${url}"
    return 1
  }
  if printf '%s' "${body}" | grep -q "\"id\"[[:space:]]*:[[:space:]]*\"${model_id}\""; then
    echo "  ok: model '${model_id}' is advertised"
    return 0
  fi
  echo "  FAIL: model '${model_id}' not advertised. Advertised models: ${body}"
  return 1
}

# check_vllm_chat <expected-token> [model-id] — minimal chat-completions smoke
# test; the response content must contain the expected token.
# Returns 0 on success.
check_vllm_chat() {
  local expected="$1"
  local model_id="${2:-${OPENCODE_MODEL_ID}}"
  local url="${OPENCODE_BASE_URL%/}/chat/completions"
  local payload
  payload=$(cat <<EOF
{"model": "${model_id}", "messages": [{"role": "user", "content": "Reply with exactly this token and nothing else: ${expected}"}], "max_tokens": 64, "temperature": 0}
EOF
)
  local body
  body="$(curl -sS --max-time "${OPENCODE_REQUEST_TIMEOUT}" \
    -H "Authorization: Bearer ${OPENCODE_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${payload}" "${url}" 2>/dev/null)" || {
    echo "  FAIL: chat-completions request to ${url} failed"
    return 1
  }
  if printf '%s' "${body}" | grep -q "${expected}"; then
    echo "  ok: chat-completions smoke test returned the expected token"
    return 0
  fi
  echo "  FAIL: chat-completions response did not contain '${expected}': ${body}"
  return 1
}
