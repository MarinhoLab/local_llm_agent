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
#   2. npm install -g @openhands/agent-canvas@latest (safe to re-run: it
#      upgrades), then verify the agent-canvas on PATH is that latest version;
#   3. if the npm global prefix is not writable, fall back to a per-user
#      prefix (~/.npm-global) so the install succeeds without sudo;
#   4. create the persistent state dir;
#   5. create .env from example.env if it does not already exist, generating a
#      random NTFY_TOPIC (the topic is the credential on an unauthenticated
#      ntfy server — see ntfy/README.md).
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

if ! node -e 'const [maj, min] = process.versions.node.split(".").map(Number); process.exit(maj > 22 || (maj === 22 && min >= 12) ? 0 : 1)'; then
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
#
# Always ask for @latest explicitly: each agent-canvas release pins its own
# agent-server / openhands-sdk version (run via uvx), so staying on an old
# release also means staying on an old SDK.
LATEST_CANVAS="$(npm view @openhands/agent-canvas version 2>/dev/null || true)"
if [[ -z "${LATEST_CANVAS}" ]]; then
  echo "WARNING: could not query the npm registry for the latest agent-canvas version." >&2
fi
if ! npm install -g @openhands/agent-canvas@latest >/dev/null 2>&1; then
  echo "global npm install failed (prefix likely not writable) — retrying with a per-user prefix."
  npm config set prefix "${HOME}/.npm-global"
  export PATH="${HOME}/.npm-global/bin:${PATH}"
  npm install -g @openhands/agent-canvas@latest || {
    echo "ERROR: npm install -g @openhands/agent-canvas@latest failed even with the per-user prefix." >&2
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
# Verify the agent-canvas that will actually run (first on PATH) is the latest
# release. An older copy under another npm prefix (e.g. /opt/homebrew vs
# ~/.npm-global) can shadow the fresh install.
INSTALLED_CANVAS="$(agent-canvas --version 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
echo "agent-canvas ${INSTALLED_CANVAS:-unknown} ($(command -v agent-canvas))"
if [[ -n "${LATEST_CANVAS}" && "${INSTALLED_CANVAS}" != "${LATEST_CANVAS}" ]]; then
  echo "ERROR: agent-canvas on PATH is ${INSTALLED_CANVAS:-unknown}, but the latest release is ${LATEST_CANVAS}." >&2
  echo "Copies found on PATH (the first one runs):" >&2
  type -a agent-canvas 2>/dev/null | sed 's/^/  /' >&2
  echo "Remove the stale copy (or reorder PATH) and re-run this script." >&2
  exit 1
fi

# --- 4. persistent state dir -------------------------------------------------
# Native mode has no /projects volume: when you create a conversation you pick
# a host path to work in (the launcher has no PROJECTS_DIR setting). So install
# only needs the state dir, where agent-server keeps per-conversation runtime
# state (conversations, workspaces, terminal history, logs). The API key,
# encryption key and LLM profile live in ~/.openhands, independent of it.
NATIVE_STATE_DIR="${AGENT_CANVAS_STATE:-${SCRIPT_DIR}/openhands-state}"
# Expand ~ and make a relative path folder-relative, exactly like run.sh does,
# so install creates the same directory run.sh later uses.
case "${NATIVE_STATE_DIR}" in
  "~") NATIVE_STATE_DIR="${HOME}" ;;
  "~/"*) NATIVE_STATE_DIR="${HOME}/${NATIVE_STATE_DIR#\~/}" ;;
  /*) : ;;
  *) NATIVE_STATE_DIR="${SCRIPT_DIR}/${NATIVE_STATE_DIR#./}" ;;
esac
mkdir -p "${NATIVE_STATE_DIR}"
echo "state dir   : ${NATIVE_STATE_DIR}"

# --- 5. .env template --------------------------------------------------------
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  echo ".env already exists — left untouched"
else
  cp "${SCRIPT_DIR}/example.env" "${SCRIPT_DIR}/.env"
  echo "created .env from example.env — edit it to taste"
  # On an unauthenticated ntfy server the topic name is the credential (see
  # ntfy/README.md), so replace the example's fixed default with a random one.
  RANDOM_TOPIC="$(node -e '
      const fs = require("fs");
      const topic = "agent-canvas-" + require("crypto").randomBytes(8).toString("hex");
      const p = process.argv[1];
      fs.writeFileSync(p, fs.readFileSync(p, "utf8").replace(/^NTFY_TOPIC=.*$/m, "NTFY_TOPIC=" + topic));
      console.log(topic);
    ' "${SCRIPT_DIR}/.env" 2>/dev/null)"
  if [[ -n "${RANDOM_TOPIC}" ]]; then
    echo "random NTFY_TOPIC set (${RANDOM_TOPIC}) — use the same topic on the phone and in ntfy/.env once you enable notifications"
  else
    echo "WARNING: could not randomize NTFY_TOPIC — set an unguessable one in .env before enabling ntfy." >&2
  fi
fi

echo
echo "done. Start the stack with:  ./agent_canvas_native/run.sh"
