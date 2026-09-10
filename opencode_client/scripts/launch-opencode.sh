#!/usr/bin/env bash
#
# launch-opencode.sh — verify the endpoint, then launch OpenCode in a project.
#
# Steps:
#   1. source opencode_client/.env;
#   2. verify the vLLM endpoint is reachable and the model is advertised;
#   3. accept an optional project-directory argument (default: current dir);
#   4. change to that project directory;
#   5. launch OpenCode with the DGX provider + model selected;
#   6. return OpenCode's exit status.
#
# This script does NOT create or manage the SSH tunnel. If the tunnel is
# missing it prints the command to run and exits.
#
# Usage:
#   ./opencode_client/scripts/launch-opencode.sh [project-dir]
#
# Example:
#   ./opencode_client/scripts/launch-opencode.sh ~/git/my_robotics_project
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091  # lib path is computed at runtime
source "${SCRIPT_DIR}/lib_vllm.sh"

if [[ -f "${CLIENT_DIR}/.env" ]]; then
  # shellcheck disable=SC1090,SC1091  # .env is git-ignored / runtime
  source "${CLIENT_DIR}/.env"
fi
: "${OPENCODE_PROVIDER_ID:=dgx-vllm}"
: "${OPENCODE_MODEL_ID:=qwen-local}"
MODEL_REF="${OPENCODE_PROVIDER_ID}/${OPENCODE_MODEL_ID}"
TUNNEL_PORT="$(printf '%s' "${OPENCODE_BASE_URL}" | sed -n 's#.*/:\([0-9]\{1,5\}\).*$#\1#p')"
TUNNEL_PORT="8000"

echo "== launch-opencode =="
echo "model : ${MODEL_REF}"
echo "url   : ${OPENCODE_BASE_URL}"

# --- 2. verify endpoint + model; if the tunnel is down, show the command ---
if ! check_vllm_endpoint >/dev/null; then
  echo
  echo "Could not reach the vLLM endpoint at ${OPENCODE_BASE_URL}."
  echo "It looks like the SSH tunnel is not running. On the Mac, run:"
  echo
  echo "  ssh -N \\"
  echo "    -o ServerAliveInterval=30 \\"
  echo "    -o ServerAliveCountMax=3 \\"
  echo "    -o ExitOnForwardFailure=yes \\"
  echo "    -L ${TUNNEL_PORT}:127.0.0.1:${TUNNEL_PORT} \\"
  echo "    <user>@<spark-host>"
  echo
  echo "Then re-run this command."
  exit 1
fi
if ! check_vllm_model "${OPENCODE_MODEL_ID}" >/dev/null; then
  echo "Endpoint reachable but model '${OPENCODE_MODEL_ID}' was not advertised." >&2
  echo "Check OPENCODE_MODEL_ID in ${CLIENT_DIR}/.env matches vLLM's served name." >&2
  exit 1
fi
echo "endpoint OK"

# --- 3/4. project directory ---
PROJECT_DIR="${1:-$(pwd)}"
if [[ ! -d "${PROJECT_DIR}" ]]; then
  echo "ERROR: project directory not found: ${PROJECT_DIR}" >&2
  exit 1
fi
cd "${PROJECT_DIR}" || exit 1
echo "project dir: $(pwd)"

# --- 5. launch OpenCode ---
resolve_opencode() {
  if command -v opencode >/dev/null 2>&1; then
    command -v opencode
  elif [[ -x "${HOME}/.opencode/bin/opencode" ]]; then
    "${HOME}/.opencode/bin/opencode"
  fi
}
OC_BIN="$(resolve_opencode || true)"
if [[ -z "${OC_BIN}" ]]; then
  echo "ERROR: 'opencode' not found on PATH or ~/.opencode/bin." >&2
  echo "       Run install-opencode.sh first, or add ~/.opencode/bin to PATH." >&2
  exit 1
fi

echo "launching: ${OC_BIN} -m ${MODEL_REF}"
# exec replaces the shell, so OpenCode's exit status is returned directly.
exec "${OC_BIN}" -m "${MODEL_REF}"
