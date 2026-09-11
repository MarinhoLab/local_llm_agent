#!/usr/bin/env bash
#
# install-opencode.sh — install OpenCode and generate its provider config.
#
# Steps:
#   1. source opencode_client/.env (or fall back to the stack defaults);
#   2. install the OpenCode binary if it is not already present:
#        - via the official script  (curl -fsSL https://opencode.ai/install | bash)
#          into ~/.opencode/bin, honoring OPENCODE_VERSION when set; or
#        - via npm (npm install -g opencode-ai) when OPENCODE_INSTALL=npm;
#   3. generate ~/.config/opencode/opencode.json (or the directory named by
#      OPENCODE_CONFIG_DIR) with the DGX Spark vLLM provider and model;
#   4. write the API key to the OpenCode auth store next to that config
#      directory (auth.json) — the key never goes into the tracked config.
#
# The generated config makes `opencode -m dgx-vllm/qwen-local` work from any
# project directory without per-project config files.
#
# Usage:
#   ./opencode_client/scripts/install-opencode.sh
#   OPENCODE_VERSION=1.18.30 ./opencode_client/scripts/install-opencode.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091  # lib path is computed at runtime
source "${SCRIPT_DIR}/lib_vllm.sh"

# Defaults are set by the lib; .env overrides them (existing environment
# variables take precedence over .env).
if [[ -f "${CLIENT_DIR}/.env" ]]; then
  vllm_load_env "${CLIENT_DIR}/.env"
fi

CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}"
# OpenCode keeps auth.json in its *data* dir, which it resolves via the
# xdg-basedir package on EVERY platform — including macOS — so it is always
# $XDG_DATA_HOME/opencode, or ~/.local/share/opencode when XDG_DATA_HOME is
# unset. It is NOT the macOS "Application Support" convention, so do not branch
# on the OS here (that made the key invisible to OpenCode and every prompt fail
# with 401 unauthorized). OPENCODE_DATA_DIR still wins as an override.
DATA_DIR="${OPENCODE_DATA_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/opencode}"

echo "== install-opencode =="
echo "provider: ${OPENCODE_PROVIDER_ID}  (${OPENCODE_PROVIDER_NAME})"
echo "model   : ${OPENCODE_MODEL_ID}"
echo "url     : ${OPENCODE_BASE_URL}"

# --- 1. install the binary ---

install_official() {
  local args=()
  if [[ -n "${OPENCODE_VERSION:-}" ]]; then
    args+=("--version" "${OPENCODE_VERSION}")
  fi
  echo "installing via the official installer${OPENCODE_VERSION:+ (pinned to ${OPENCODE_VERSION})} ..."
  if curl -fsSL https://opencode.ai/install | bash -s -- ${args[@]+"${args[@]}"}; then
    return 0
  fi
  echo "WARNING: official installer failed." >&2
  return 1
}

install_npm() {
  if ! command -v npm >/dev/null 2>&1; then
    echo "ERROR: OPENCODE_INSTALL=npm but npm is not on PATH." >&2
    return 1
  fi
  local pkg="opencode-ai"
  if [[ -n "${OPENCODE_VERSION:-}" ]]; then
    pkg="opencode-ai@${OPENCODE_VERSION}"
  fi
  echo "installing via npm (${pkg}) ..."
  npm install -g "${pkg}"
}

resolve_opencode() {
  if command -v opencode >/dev/null 2>&1; then
    command -v opencode
  elif [[ -x "${HOME}/.opencode/bin/opencode" ]]; then
    # Print the path (do NOT execute it — the result is captured by
    # command substitution in the caller).
    printf '%s\n' "${HOME}/.opencode/bin/opencode"
  fi
}

OC_BIN="$(resolve_opencode || true)"
if [[ -z "${OC_BIN}" ]]; then
  case "${OPENCODE_INSTALL:-official}" in
    npm) install_npm ;;
    *)   install_official || {
           echo "       Retrying with npm ... (OPENCODE_INSTALL=npm can pin this)" >&2
           install_npm || {
             echo "ERROR: could not install OpenCode (no curl? no npm?)." >&2
             exit 1
           }
         }
         ;;
    *)
      echo "ERROR: unknown OPENCODE_INSTALL='${OPENCODE_INSTALL}' (use 'official' or 'npm')." >&2
      exit 1
      ;;
  esac
  OC_BIN="$(resolve_opencode || true)"
  if [[ -z "${OC_BIN}" ]]; then
    echo "ERROR: installation finished but 'opencode' is not resolvable." >&2
    echo "       Add ~/.opencode/bin to PATH or check the npm global bin directory." >&2
    exit 1
  fi
fi
echo "opencode: ${OC_BIN} ($("${OC_BIN}" --version 2>/dev/null || echo version unknown))"

# --- 2. generate the provider config (global) ---

CONFIG_FILE="${CONFIG_DIR}/opencode.json"
mkdir -p "${CONFIG_DIR}"

BACKED_UP=""
if [[ -f "${CONFIG_FILE}" ]]; then
  if cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak"; then
    BACKED_UP=" (existing copy saved as ${CONFIG_FILE}.bak)"
  else
    echo "WARNING: could not back up existing ${CONFIG_FILE}" >&2
  fi
fi
echo "writing: ${CONFIG_FILE}${BACKED_UP}"

cat > "${CONFIG_FILE}" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "${OPENCODE_PROVIDER_ID}/${OPENCODE_MODEL_ID}",
  "provider": {
    "${OPENCODE_PROVIDER_ID}": {
      "name": "${OPENCODE_PROVIDER_NAME}",
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "${OPENCODE_BASE_URL}"
      },
      "models": {
        "${OPENCODE_MODEL_ID}": {
          "name": "${OPENCODE_MODEL_NAME}",
          "reasoning": true,
          "tool_call": true,
          "limit": {
            "context": ${OPENCODE_CONTEXT_LENGTH},
            "output": ${OPENCODE_OUTPUT_LENGTH}
          }
        }
      }
    }
  }
}
EOF

# --- 3. write the API key to the auth store ---

AUTH_FILE="${DATA_DIR}/auth.json"
mkdir -p "${DATA_DIR}"

# Merge the provider into any existing auth.json (other providers are kept).
if [[ -f "${AUTH_FILE}" ]]; then
  tmp="$(mktemp)"
  if jq --arg id "${OPENCODE_PROVIDER_ID}" --arg key "${OPENCODE_API_KEY}" \
      '.[$id] = {"type":"api","key":$key}' "${AUTH_FILE}" > "${tmp}"; then
    mv "${tmp}" "${AUTH_FILE}"
  else
    rm -f "${tmp}"
    echo "WARNING: existing ${AUTH_FILE} is not valid JSON; leaving it untouched." >&2
    echo "         Fix or delete it, then re-run this script." >&2
  fi
else
  jq -n --arg id "${OPENCODE_PROVIDER_ID}" --arg key "${OPENCODE_API_KEY}" \
    '{($id): {type: "api", key: $key}}' > "${AUTH_FILE}"
fi
chmod 600 "${AUTH_FILE}"
echo "wrote: ${AUTH_FILE} (API key, chmod 600)"

# --- 4. summary ---
echo
echo "install-opencode done."
echo
echo "  provider : ${OPENCODE_PROVIDER_ID}"
echo "  model ref: ${OPENCODE_PROVIDER_ID}/${OPENCODE_MODEL_ID}"
echo "  config   : ${CONFIG_FILE}"
echo "  auth     : ${AUTH_FILE}"
echo
echo "Next steps:"
echo "  1. Start the vLLM server on the DGX Spark (cd dgx_spark_host && docker compose up --build)."
echo "  2. Open the SSH tunnel:  ssh -N -L $(vllm_tunnel_port):127.0.0.1:$(vllm_tunnel_port) <user>@<spark-host>"
echo "  3. Verify the endpoint:  ./scripts/check-vllm.sh"
echo "  4. Launch OpenCode:      ./scripts/launch-opencode.sh [project-dir]"
