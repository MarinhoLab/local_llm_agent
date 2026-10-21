#!/usr/bin/env bash
#
# run.sh — start the *native* Agent Canvas stack (no Docker): UI + agent-server
# + automation server + ingress as a local process, per
# https://docs.openhands.dev/openhands/usage/agent-canvas/setup ("npm").
#
# Steps:
#   1. source agent_canvas_native/.env if present;
#   2. verify the agent-canvas binary is available (run install.sh if not);
#   3. pin the Python the launcher's uvx environments use to 3.14 and verify
#      that interpreter exists (install.sh installs it via Homebrew); warn if
#      the ingress port is already taken, and warn (without failing) if the
#      vLLM endpoint is not reachable yet — the Canvas itself starts fine
#      without it, you just configure the LLM profile afterwards;
#   4. exec the agent-canvas launcher on AGENT_CANVAS_PORT, in public mode
#      (--host CANVAS_BIND_HOST --public) unless CANVAS_PUBLIC=false.
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
#
# By default the Canvas runs in public mode: the API key is not injected into
# the page, so every browser (this machine included) pastes it once. Set
# CANVAS_PUBLIC=false for the old local mode, where the launcher generates a
# key, writes it to ~/.openhands/agent-canvas/api-key.txt and injects it, so
# nothing listens off-loopback and no key entry screen appears.
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
_env_PUBLIC="${CANVAS_PUBLIC:-}"
_env_BIND="${CANVAS_BIND_HOST:-}"
_env_APIKEY="${LOCAL_BACKEND_API_KEY:-}"

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
[[ -n "$_env_PUBLIC" ]]   && CANVAS_PUBLIC="$_env_PUBLIC"
[[ -n "$_env_BIND" ]]     && CANVAS_BIND_HOST="$_env_BIND"
[[ -n "$_env_APIKEY" ]]   && LOCAL_BACKEND_API_KEY="$_env_APIKEY"
unset _env_PORT _env_STATE _env_VLLM_URL _env_VLLM_KEY _env_PUBLIC _env_BIND _env_APIKEY

AGENT_CANVAS_PORT="${AGENT_CANVAS_PORT:-8020}"
AGENT_CANVAS_STATE="${AGENT_CANVAS_STATE:-${SCRIPT_DIR}/openhands-state}"
VLLM_BASE_URL="${VLLM_BASE_URL:-http://localhost:8000/v1}"
VLLM_API_KEY="${VLLM_API_KEY:-local-dgx-key}"
CANVAS_PUBLIC="${CANVAS_PUBLIC:-true}"
CANVAS_BIND_HOST="${CANVAS_BIND_HOST:-0.0.0.0}"

# Resolve a relative AGENT_CANVAS_STATE against this folder — like docker
# compose resolves relative volume paths against the compose file — so
# `AGENT_CANVAS_STATE=./openhands-state` in .env always means
# "<this folder>/openhands-state" no matter where you run run.sh from.
# A ~-prefix is expanded to $HOME; absolute paths are left untouched.
case "${AGENT_CANVAS_STATE}" in
  "~") AGENT_CANVAS_STATE="${HOME}" ;;
  "~/"*) AGENT_CANVAS_STATE="${HOME}/${AGENT_CANVAS_STATE#\~/}" ;;
  /*) : ;;
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

# --- 2b. Python and tmux ----------------------------------------------------
# The launcher runs the agent-server and the automation backend through
# `uv tool uvx` and pins only the openhands-* packages, so the interpreter
# floats: without a request uv takes the newest python3 on PATH (or the newest
# Homebrew python it can find), and this stack does not build on 3.15. Pin it
# to 3.14 — install.sh installs python@3.14 via Homebrew — unless the caller
# set UV_PYTHON (or a uv-managed 3.14) themselves.
if ! command -v uv >/dev/null 2>&1; then
  echo "ERROR: 'uv' not found in PATH — the launcher runs the agent-server through it." >&2
  echo "  Install it:  brew install uv   (or: curl -LsSf https://astral.sh/uv/install.sh | sh)" >&2
  exit 1
fi
if [ -n "${UV_PYTHON:-}" ]; then
  # Explicit request: honor it strictly.
  if ! CANVAS_PYTHON="$(uv python find "${UV_PYTHON}" 2>/dev/null)"; then
    echo "ERROR: no Python ${UV_PYTHON} interpreter found for uv (UV_PYTHON=${UV_PYTHON})." >&2
    echo "  Install it:  brew install python@${UV_PYTHON}    (or: uv python install ${UV_PYTHON})" >&2
    echo "  Check it:    uv python find ${UV_PYTHON}" >&2
    exit 1
  fi
elif CANVAS_PYTHON="$(uv python find 3.14 2>/dev/null)"; then
  export UV_PYTHON=3.14
else
  # No 3.14 (e.g. Ubuntu 24.04): fall back to uv's default interpreter.
  if ! CANVAS_PYTHON="$(uv python find 2>/dev/null)"; then
    echo "ERROR: no Python interpreter found for uv." >&2
    echo "  Install one:  uv python install 3.14   (or your distro's python3)" >&2
    exit 1
  fi
  export UV_PYTHON="${CANVAS_PYTHON}"
  echo "WARNING: Python 3.14 not found; falling back to ${CANVAS_PYTHON}." >&2
  echo "         (If the agent-server fails to build, run: uv python install 3.14)" >&2
fi
# The agent-server's terminal needs tmux; without it the SDK falls back to a
# subprocess-based terminal and warns on every conversation start.
if ! command -v tmux >/dev/null 2>&1; then
  echo "WARNING: tmux is not installed — agents fall back to the less stable" >&2
  echo "         subprocess-based terminal. Install it:  brew install tmux" >&2
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
  echo "  (8000 = vLLM tunnel, 8020 = this stack's default.)" >&2
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

# --- 3c. mode (public by default) -------------------------------------------
# Public mode serves the UI on CANVAS_BIND_HOST (all interfaces, so the LAN /
# Tailscale addresses work) and does NOT inject the API key into the page:
# every browser pastes LOCAL_BACKEND_API_KEY once, then the launcher remembers
# it. The launcher exits at startup when --public has no key, hence this check
# runs before anything is spawned. The same key is what the notifier
# authenticates with (ntfy_notifier.py reads this env var first).
#
# CANVAS_PUBLIC=false restores the old local mode: loopback-only, key
# auto-generated under ~/.openhands and injected, no login screen.
CANVAS_ARGS=("--port" "${AGENT_CANVAS_PORT}")
PUBLIC_LC="$(printf '%s' "${CANVAS_PUBLIC}" | tr '[:upper:]' '[:lower:]')"
LAN_HINT=""
if [[ "${PUBLIC_LC}" == "off" || "${PUBLIC_LC}" == "false" || "${PUBLIC_LC}" == "0" ]]; then
  MODE_LINE="local — loopback only, API key auto-injected (no login)"
else
  # An empty key makes the launcher exit on its own; the template placeholder
  # would "work" with a key published in a public repo. Neither is acceptable.
  if [[ -z "${LOCAL_BACKEND_API_KEY:-}" || "${LOCAL_BACKEND_API_KEY}" == "REPLACE_ME" ]]; then
    echo "ERROR: public mode needs a real LOCAL_BACKEND_API_KEY — it is the key you" >&2
    echo "       paste in the browser, and currently it is '${LOCAL_BACKEND_API_KEY:-<empty>}'." >&2
    echo "  Fix it in ${SCRIPT_DIR}/.env, e.g.:" >&2
    echo "    node -e 'console.log(\"LOCAL_BACKEND_API_KEY=\"+require(\"crypto\").randomBytes(32).toString(\"base64url\"))' >> ${SCRIPT_DIR}/.env" >&2
    echo "  (./install.sh does this when it creates .env), or run loopback-only" >&2
    echo "  with no login:  CANVAS_PUBLIC=false $0" >&2
    exit 1
  fi
  CANVAS_ARGS=("--host" "${CANVAS_BIND_HOST}" "${CANVAS_ARGS[@]}" "--public")
  # Show the addresses the UI is reachable on, since --host 0.0.0.0 means
  # "from the LAN / tailnet too" — without this you would only ever see the
  # localhost line and wonder how to connect from another machine. macOS
  # reports addresses in ifconfig field 2, Linux in ip field 4 (with a /prefix).
  LAN_HINT="also on: $(
    { ifconfig -a 2>/dev/null | awk '/inet [0-9]/ {print $2}';
      ip -o -4 addr show 2>/dev/null | awk '{print $4}'; } \
      | sed 's|/.*||' | grep -vE '^(127\.|169\.254\.)' | sort -u | head -4 \
      | awk -v p="${AGENT_CANVAS_PORT}" '{printf "http://%s:%s ", $1, p}'
  )"
  [[ "${LAN_HINT}" == "also on: " ]] && LAN_HINT=""
  MODE_LINE="public on ${CANVAS_BIND_HOST} — paste the API key in the browser (once per browser)"
fi

# --- 4. ntfy notifications --------------------------------------------------
# Optionally start the ntfy push server (../ntfy, if Docker is available) and
# the notifier daemon (ntfy_notifier.py) so conversation status changes are
# pushed to the ntfy app on the user's phone over Tailscale. Both are no-ops
# when NTFY_ENABLED is not true, which is the default.
#
# The notifier is backgrounded via nohup so the `exec agent-canvas` below can
# replace this shell cleanly; it keeps running independently and dies with
# the machine, or is stopped with `pkill -f ntfy_notifier.py`.
if [[ "${NTFY_ENABLED:-}" == "true" || "${NTFY_ENABLED:-}" == "1" ]]; then
  STATE_LOG_DIR="${AGENT_CANVAS_STATE}/logs"
  mkdir -p "${STATE_LOG_DIR}"

  # Without account auth the topic name is the only credential (ntfy/README.md),
  # so the example.env default is not safe to publish to.
  if [[ -z "${NTFY_AUTH_TOKEN:-}" && "${NTFY_TOPIC:-}" == "agent-canvas" ]]; then
    echo "WARNING: NTFY_TOPIC is the default 'agent-canvas' — on an unauthenticated" >&2
    echo "         ntfy server anyone who guesses it can read these notifications." >&2
    echo "         Set a random NTFY_TOPIC in ${SCRIPT_DIR}/.env (install.sh generates one)." >&2
  fi

  # 4a. local ntfy server — only when pointing at the loopback default and
  #     Docker is present. A remote NTFY_SERVER (e.g. https://ntfy.sh) skips
  #     this entirely.
  if [[ "${NTFY_SERVER:-http://127.0.0.1:2020}" == http://127.0.0.1:* \
        || "${NTFY_SERVER:-http://127.0.0.1:2020}" == http://localhost:* ]]; then
    NTFY_DIR="$(cd "${SCRIPT_DIR}/../ntfy" && pwd)"
    if command -v docker >/dev/null 2>&1; then
      if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ntfy; then
        echo "starting local ntfy server (ntfy/compose.yml, port ${NTFY_PORT:-2020})..."
        if (cd "${NTFY_DIR}" && docker compose up -d); then
          echo "ntfy server starting — http://127.0.0.1:${NTFY_PORT:-2020}"
        else
          echo "WARNING: 'docker compose up -d' in ${NTFY_DIR} failed — see ntfy/README.md" >&2
        fi
      fi
    else
      echo "WARNING: NTFY_ENABLED=true but docker is not on PATH — the local ntfy server was not started." >&2
      echo "         Install Docker, or point NTFY_SERVER at a remote ntfy (e.g. https://ntfy.sh)." >&2
    fi
  fi

  # 4b. notifier daemon (Python stdlib only — no venv needed). Run it with the
  #     same pinned interpreter as the rest of the stack, so it does not pick up
  #     whatever python3 happens to be first on PATH. Point it at the
  #     agent-server through the ingress (AGENT_CANVAS_PORT), which proxies
  #     /api; NTFY_BASE_URL overrides this if the agent-server is reachable
  #     directly on another port.
  NOTIFY_LOG="${STATE_LOG_DIR}/ntfy.log"
  NTFY_BASE_URL="http://localhost:${AGENT_CANVAS_PORT}" \
  NTFY_STATE_FILE="${AGENT_CANVAS_STATE}/ntfy_notifier_state.json" \
    nohup "${CANVAS_PYTHON}" "${SCRIPT_DIR}/ntfy_notifier.py" \
    >>"${NOTIFY_LOG}" 2>&1 < /dev/null &
  NOTIFY_PID=$!
  if [[ -n "${NOTIFY_PID}" ]] && kill -0 "${NOTIFY_PID}" 2>/dev/null; then
    echo "ntfy notifier running (pid ${NOTIFY_PID}) — log: ${NOTIFY_LOG}"
    echo "stop it with: pkill -f ntfy_notifier.py"
  else
    echo "WARNING: ntfy notifier failed to start — see ${NOTIFY_LOG}" >&2
  fi
fi

# --- 5. launch --------------------------------------------------------------
# Everything runs as your user on the local machine. The launcher's default
# state dir is ~/.openhands/agent-canvas; we point it at AGENT_CANVAS_STATE so
# the state lives next to this folder (git-ignored) instead of in $HOME.
export OH_CANVAS_SAFE_STATE_DIR="${AGENT_CANVAS_STATE}"
# The launcher pins only the openhands-* packages it runs through uvx; every
# other dependency floats. uv-constraints.txt holds back the known-bad
# releases (see its comments). A UV_CONSTRAINT you set yourself wins.
export UV_CONSTRAINT="${UV_CONSTRAINT:-${SCRIPT_DIR}/uv-constraints.txt}"
# Internal service ports default to 18000/18001. They are NOT shifted with the
# ingress port, so if they collide on your machine (a second Canvas stack, or a
# sandbox whose own Agent Canvas occupies them) set OH_CANVAS_SAFE_BACKEND_PORT
# / OH_CANVAS_SAFE_AUTOMATION_PORT in .env or on the command line.

echo
echo "Agent Canvas (native) : http://localhost:${AGENT_CANVAS_PORT}"
[[ -n "${LAN_HINT:-}" ]] && echo "                        ${LAN_HINT}"
echo "mode                  : ${MODE_LINE}"
echo "state dir             : ${AGENT_CANVAS_STATE}"
echo "python (uvx envs)     : ${CANVAS_PYTHON}"
echo "LLM profile (UI)      : Settings > LLM — provider OpenAI-compatible, base URL ${VLLM_BASE_URL}"
echo
# exec replaces the shell so Ctrl+C / the process lifecycle is clean.
exec agent-canvas "${CANVAS_ARGS[@]}"
