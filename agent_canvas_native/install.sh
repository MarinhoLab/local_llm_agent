#!/usr/bin/env bash
#
# install.sh — one-time setup for the *native* Agent Canvas stack (no Docker).
#
# This is the "npm" install path from
# https://docs.openhands.dev/openhands/usage/agent-canvas/setup — it runs the
# whole all-in-one stack (UI + agent-server + automation server + ingress)
# as a local process on your machine, with no Docker.
#
# Steps:
#   1. verify prerequisites: Node.js >= 22.12, npm, uv (the agent-server and
#      automation backend run via `uvx`, so `uv` must be on PATH);
#   2. npm install -g @openhands/agent-canvas (safe to re-run: it upgrades);
#   3. if the npm global prefix is not writable, fall back to a per-user
#      prefix (~/.npm-global) so the install succeeds without sudo;
#   4. create the persistent state dir;
#   5. create .env from example.env if it does not already exist.
#
# Usage:
#   ./agent_canvas_native/install.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 1. prerequisites -------------------------------------------------------
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: '$1' not found in PATH." >&2
    echo "  $2" >&2
    exit 1
  fi
}
need node "Install Node.js >= 22.12: https://nodejs.org/en/download (or: brew install node)"
need npm  "npm ships with Node.js — reinstall Node.js."
need uv   "Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh   (or: brew install uv)"
need curl "Needed for the post-install reachability check (or install curl)."

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if (( NODE_MAJOR < 22 )); then
  echo "ERROR: Node.js $(node --version) is too old; Agent Canvas needs >= 22.12." >&2
  echo "Install a current Node.js (e.g. via https://nodejs.org or nvm) and re-run." >&2
  exit 1
fi
echo "node $(node --version) OK"
echo "npm  $(npm --version) OK"
echo "uv   $(uv --version) OK"

# --- 2/3. install or upgrade the npm package --------------------------------
# A global npm install needs a writable prefix. On managed machines (and in
# some sandboxes) the system prefix (e.g. /usr/local/lib/node_modules) is not
# writable by the current user. Detect that and fall back to a per-user prefix
# under ~/.npm-global so the install never needs sudo.
if ! npm install -g @openhands/agent-canvas >/dev/null 2>&1; then
  echo "global npm install failed (prefix likely not writable) — retrying with a per-user prefix."
  npm config set prefix "${HOME}/.npm-global"
  export PATH="${HOME}/.npm-global/bin:${PATH}"
  npm install -g @openhands/agent-canvas || {
    echo "ERROR: npm install -g @openhands/agent-canvas failed even with the per-user prefix." >&2
    exit 1
  }
fi

# Make sure the freshly installed binary is reachable in this shell.
if ! command -v agent-canvas >/dev/null 2>&1; then
  if [[ -x "${HOME}/.npm-global/bin/agent-canvas" ]]; then
    export PATH="${HOME}/.npm-global/bin:${PATH}"
  else
    echo "ERROR: package installed but 'agent-canvas' is not on PATH." >&2
    echo "Add your npm global bin dir to PATH:  echo \"\$(npm prefix -g)/bin\"" >&2
    exit 1
  fi
fi
echo "agent-canvas $(agent-canvas --version 2>/dev/null || echo 'installed')"

# --- 4. persistent state dir -------------------------------------------------
# Native mode has no /projects volume: when you create a conversation you pick
# a host path to work in (the launcher has no PROJECTS_DIR setting). So install
# only needs the state dir, where agent-server keeps per-conversation runtime
# state (conversations, workspaces, terminal history, logs). The API key,
# encryption key and LLM profile live in ~/.openhands, independent of it.
NATIVE_STATE_DIR="${AGENT_CANVAS_STATE:-${SCRIPT_DIR}/openhands-state}"
mkdir -p "${NATIVE_STATE_DIR}"
echo "state dir   : ${NATIVE_STATE_DIR}"

# --- 5. .env template --------------------------------------------------------
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  echo ".env already exists — left untouched"
else
  cp "${SCRIPT_DIR}/example.env" "${SCRIPT_DIR}/.env"
  echo "created .env from example.env — edit it to taste"
fi

echo
echo "done. Start the stack with:  ./agent_canvas_native/run.sh"
