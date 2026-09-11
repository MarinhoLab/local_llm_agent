#!/usr/bin/env bash
#
# run.sh — start the *native* Agent Canvas stack (no Docker): UI + agent-server
# + automation server + ingress as a local process, per
# https://docs.openhands.dev/openhands/usage/agent-canvas/setup ("npm").
#
# Steps:
#   1. source agent_canvas_native/.env if present;
#   2. verify the agent-canvas binary is available (run install.sh if not);
#   3. preflight: warn if the ingress port is already taken, and warn (without
#      failing) if the vLLM endpoint is not reachable yet — the Canvas itself
#      starts fine without it, you just configure the LLM profile afterwards;
#   4. exec the agent-canvas launcher on AGENT_CANVAS_PORT.
#
# The agent-server keeps per-conversation runtime state (conversations,
# workspaces, terminal history, logs) under AGENT_CANVAS_STATE
# (default: ./openhands-state). The auto-generated API key, the encryption key
# and your LLM profile always live in ~/.openhands. Agents work on local files
# directly — there is no container boundary, so the agent sees the whole
# filesystem your user can read.
#
# Usage:
#   ./agent_canvas_native/run.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 1. .env (env vars always win over .env) --------------------------------
# Snapshot any value the caller set on the command line, source .env for the
# rest, then restore the caller's values so e.g. `AGENT_CANVAS_PORT=8030
# ./run.sh` is never clobbered by the port baked into .env.
_env_PORT="${AGENT_CANVAS_PORT:-}"
_env_STATE="${AGENT_CANVAS_STATE:-}"
_env_VLLM_URL="${VLLM_BASE_URL:-}"
_env_VLLM_KEY="${VLLM_API_KEY:-}"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck disable=SC1090,SC1091  # .env is git-ignored / runtime
  # set -a exports everything .env defines. run.sh consumes AGENT_CANVAS_PORT /
  # AGENT_CANVAS_STATE / VLLM_* itself, but the launcher reads its own knobs
  # (OH_CANVAS_SAFE_*, LOCAL_BACKEND_API_KEY, ...) straight from the process
  # environment — so they must be exported for the `exec` below to inherit them.
  set -a
  source "${SCRIPT_DIR}/.env"
  set +a
fi

[[ -n "$_env_PORT" ]]     && AGENT_CANVAS_PORT="$_env_PORT"
[[ -n "$_env_STATE" ]]    && AGENT_CANVAS_STATE="$_env_STATE"
[[ -n "$_env_VLLM_URL" ]] && VLLM_BASE_URL="$_env_VLLM_URL"
[[ -n "$_env_VLLM_KEY" ]] && VLLM_API_KEY="$_env_VLLM_KEY"
unset _env_PORT _env_STATE _env_VLLM_URL _env_VLLM_KEY

AGENT_CANVAS_PORT="${AGENT_CANVAS_PORT:-8020}"
AGENT_CANVAS_STATE="${AGENT_CANVAS_STATE:-${SCRIPT_DIR}/openhands-state}"
VLLM_BASE_URL="${VLLM_BASE_URL:-http://localhost:8000/v1}"
VLLM_API_KEY="${VLLM_API_KEY:-local-dgx-key}"

# Resolve a relative AGENT_CANVAS_STATE against this folder — like docker
# compose resolves relative volume paths against the compose file — so
# `AGENT_CANVAS_STATE=./openhands-state` in .env always means
# "<this folder>/openhands-state" no matter where you run run.sh from.
# Absolute paths (/...) and ~-paths are left untouched.
case "${AGENT_CANVAS_STATE}" in
  /*|~*) : ;;
  *) AGENT_CANVAS_STATE="${SCRIPT_DIR}/${AGENT_CANVAS_STATE#./}" ;;
esac

# --- 2. binary --------------------------------------------------------------
# agent-canvas may live in a per-user npm prefix (~/.npm-global/bin) that is
# not on PATH yet — add it, mirroring install.sh, so a fresh shell works too.
if ! command -v agent-canvas >/dev/null 2>&1 && [[ -x "${HOME}/.npm-global/bin/agent-canvas" ]]; then
  export PATH="${HOME}/.npm-global/bin:${PATH}"
fi
if ! command -v agent-canvas >/dev/null 2>&1; then
  echo "ERROR: 'agent-canvas' not found. Run ./agent_canvas_native/install.sh first." >&2
  exit 1
fi

# --- 3a. ingress port preflight ---------------------------------------------
PORT_IN_USE=0
if command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:"${AGENT_CANVAS_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    PORT_IN_USE=1
  fi
fi
if (( PORT_IN_USE )); then
  echo "WARNING: port ${AGENT_CANVAS_PORT} is already in use." >&2
  echo "  Choose another:  AGENT_CANVAS_PORT=8030 ./agent_canvas_native/run.sh" >&2
  echo "  (8000 = vLLM tunnel, 8010 = the Docker Agent Canvas stack, 8020 = this stack's default.)" >&2
  exit 1
fi

# --- 3b. vLLM preflight (warn only) -----------------------------------------
# The Canvas starts without the model; this only tells you early whether the
# SSH tunnel is up so you can set Settings > LLM right away. Non-fatal.
if curl -fsS --max-time 5 "${VLLM_BASE_URL}/models" \
     -H "Authorization: Bearer ${VLLM_API_KEY}" >/dev/null 2>&1; then
  echo "vLLM endpoint reachable: ${VLLM_BASE_URL}"
else
  TUNNEL_PORT="$(printf '%s' "${VLLM_BASE_URL}" | sed -n 's#.*/:\([0-9][0-9]*\).*$#\1#p')"
  echo "note: vLLM endpoint ${VLLM_BASE_URL} is not reachable."
  echo "      Agent Canvas will still start; start the tunnel to point it at the model:"
  echo
  echo "        ssh -N \\"
  echo "          -o ServerAliveInterval=30 \\"
  echo "          -o ServerAliveCountMax=3 \\"
  echo "          -o ExitOnForwardFailure=yes \\"
  echo "          -L ${TUNNEL_PORT:-8000}:127.0.0.1:${TUNNEL_PORT:-8000} \\"
  echo "          <user>@<spark-host>"
  echo
fi

# --- 4. launch --------------------------------------------------------------
# Everything runs as your user on the local machine. The launcher's default
# state dir is ~/.openhands/agent-canvas; we point it at AGENT_CANVAS_STATE so
# the state lives next to this folder (git-ignored) instead of in $HOME.
export OH_CANVAS_SAFE_STATE_DIR="${AGENT_CANVAS_STATE}"
# Internal service ports default to 18000/18001. They are NOT shifted with the
# ingress port, so if they collide on your machine (a second Canvas stack, or a
# sandbox whose own Agent Canvas occupies them) set OH_CANVAS_SAFE_BACKEND_PORT
# / OH_CANVAS_SAFE_AUTOMATION_PORT in .env or on the command line.
echo
echo "Agent Canvas (native) : http://localhost:${AGENT_CANVAS_PORT}"
echo "state dir             : ${AGENT_CANVAS_STATE}"
echo "LLM profile (UI)      : Settings > LLM — provider openai, base URL ${VLLM_BASE_URL}"
echo
# exec replaces the shell so Ctrl+C / the process lifecycle is clean.
# --public is deliberately NOT passed: local mode auto-generates the API key
# and injects it into the UI (no login). For a network-exposed stack, switch
# to:  exec agent-canvas --port "${AGENT_CANVAS_PORT}" --public
# (requires LOCAL_BACKEND_API_KEY; users then paste the key in the browser).
exec agent-canvas \
  --port "${AGENT_CANVAS_PORT}"
