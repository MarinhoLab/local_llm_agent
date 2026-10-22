#!/usr/bin/env bash
#
# run.sh — start the *native* OpenCode stack (no Docker).
#
# Modes:
#   ./run.sh [dir]        TUI in <dir> (default: current directory) — the usual
#                         way to use it, mirroring `opencode [project]`.
#   ./run.sh server       `opencode serve` (headless HTTP API + web UI at /).
#                         Attach later with:
#                           ./run.sh attach [dir]
#   ./run.sh attach [dir] TUI attached to the running server.
#   ./run.sh run ARGS...  non-interactive; the model is taken from the profile,
#                         so `./run.sh run "prompt"` needs no -m. Use
#                         `./run.sh run -m provider/model ...` to override.
#   ./run.sh upgrade      upgrade the binary (re-runs install.sh).
#
# What this adds over calling opencode directly (the reason to always use it):
#   1. sources agent_canvas-style .env, with caller env vars winning;
#   2. points OPENCODE_CONFIG at this folder's generated config, so the DGX
#      profile exists (opencode has no UI to add a provider) ;
#   3. isolates XDG config/data/cache inside opencode_native/opencode-state/
#      instead of ~/.config/opencode + ~/.local/share/opencode;
#   4. exports the {env:...} values the config substitutes (endpoint + key);
#   5. disables the background network behaviour that would otherwise phone
#      home (update checks, share, LSP downloads);
#   6. preflights the vLLM tunnel and (for server mode) requires a real
#      OPENCODE_SERVER_PASSWORD before binding a shell-capable port;
#   7. starts the ntfy notifier when NTFY_ENABLED=true.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_stack.sh
source "${SCRIPT_DIR}/lib_stack.sh"

usage() {
  sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

MODE="${1:-tui}"
case "${MODE}" in
  tui | server | attach | run | upgrade | -h | --help) : ;;
  *) MODE="tui" ;;  # first arg is a project dir
esac
if [[ "${MODE}" != "tui" ]]; then
  shift || true
else
  : # keep the dir argument in $1
fi

if [[ "${MODE}" == "-h" || "${MODE}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${MODE}" == "upgrade" ]]; then
  exec "${SCRIPT_DIR}/install.sh"
fi

# --- 1. config + environment -------------------------------------------------
oc_load_env
oc_apply_defaults
oc_resolve_paths

if [[ ! -f "${OPENCODE_CONFIG_FILE}" ]]; then
  oc_die "no config at ${OPENCODE_CONFIG_FILE}.
  Run ./opencode_native/install.sh first — opencode has no UI for adding a
  provider, so the DGX profile has to be generated."
fi

# --- 2. binary ---------------------------------------------------------------
if ! oc_resolve_binary >/dev/null 2>&1; then
  oc_die "'opencode' not found. Run ./opencode_native/install.sh first."
fi
OPENCODE_BIN="$(oc_resolve_binary)"

# The TUI is an interactive program: never wrap it in a pipe or subshell.
PY="$(command -v python3 || true)"

# --- 3. preflight: the model -------------------------------------------------
# Non-fatal: opencode starts fine without the tunnel, you just cannot chat.
VLLM_CHECK="$(oc_check_vllm)"
case "${VLLM_CHECK}" in
  ok) echo "vLLM endpoint reachable: ${VLLM_BASE_URL} (model ${VLLM_MODEL_ID})" ;;
  served-models-mismatch)
    oc_warn "${VLLM_BASE_URL} is up but does not serve '${VLLM_MODEL_ID}'."
    echo "        Fix VLLM_MODEL_ID in ${SCRIPT_DIR}/.env, or start the stack you meant:"
    echo "          curl -H 'Authorization: Bearer <key>' ${VLLM_BASE_URL%/}/models"
    ;;
  *)
    echo "note: vLLM endpoint ${VLLM_BASE_URL} is not reachable — OpenCode will start,"
    echo "      but every turn will fail until the tunnel is up."
    oc_print_tunnel_hint
    ;;
esac

# --- 4. ntfy notifications --------------------------------------------------
# Same design as agent_canvas_native: a stdlib-only daemon that polls the
# agent-server and publishes on status transitions. For OpenCode the server is
# `opencode serve`, so notifications only make sense once the stack runs in
# server mode (the TUI spawns its own private server on a random port).
start_notifier() {
  local base_url="$1"
  local log_dir="${OPENCODE_LOG_DIR}"
  mkdir -p "${log_dir}"

  # Without account auth the topic name is the only credential (ntfy/README.md),
  # so the example.env default must not survive into a real deployment.
  if [[ -z "${NTFY_AUTH_TOKEN:-}" && "${NTFY_TOPIC:-opencode}" == "opencode" ]]; then
    oc_warn "NTFY_TOPIC is the default 'opencode' — on an unauthenticated ntfy"
    oc_warn "        server anyone who guesses it can read these notifications."
    oc_warn "        Set a random NTFY_TOPIC in ${SCRIPT_DIR}/.env (install.sh generates one)."
  fi

  # 4a. local ntfy server — only when pointing at the loopback default and
  #     Docker is present; a remote NTFY_SERVER (e.g. https://ntfy.sh) skips it.
  if [[ "${NTFY_SERVER:-http://127.0.0.1:2020}" == http://127.0.0.1:* \
        || "${NTFY_SERVER:-http://127.0.0.1:2020}" == http://localhost:* ]]; then
    if command -v docker >/dev/null 2>&1; then
      if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ntfy; then
        local ntfy_dir
        ntfy_dir="$(cd "${SCRIPT_DIR}/../ntfy" && pwd)"
        echo "starting local ntfy server (ntfy/compose.yml)..."
        if ! (cd "${ntfy_dir}" && docker compose up -d); then
          oc_warn "'docker compose up -d' in ${ntfy_dir} failed — see ntfy/README.md"
        fi
      fi
    else
      oc_warn "NTFY_ENABLED=true but docker is not on PATH — the local ntfy server"
      oc_warn "        was not started. Install Docker or point NTFY_SERVER at ntfy.sh."
    fi
  fi

  # 4b. the notifier. python3 is optional in this stack, so it is a warning,
  #     not a failure — the agent works without notifications.
  if [[ -z "${PY}" ]]; then
    oc_warn "NTFY_ENABLED=true but python3 is not on PATH — notifications disabled."
    oc_warn "        Install it:  brew install python@3.12   (or any python3)"
    return 0
  fi
  local notify_log="${log_dir}/ntfy.log"
  NTFY_BASE_URL="${base_url}" \
  NTFY_STATE_FILE="${NTFY_STATE_FILE:-${OPENCODE_STATE_DIR}/ntfy_notifier_state.json}" \
    nohup "${PY}" "${SCRIPT_DIR}/ntfy_notifier.py" >>"${notify_log}" 2>&1 </dev/null &
  local pid=$!
  if kill -0 "${pid}" 2>/dev/null; then
    echo "ntfy notifier running (pid ${pid}) — log: ${notify_log}"
    echo "stop it with: pkill -f 'opencode_native/ntfy_notifier.py'"
  else
    oc_warn "ntfy notifier failed to start — see ${notify_log}"
  fi
}

maybe_start_notifier() {
  if [[ "${NTFY_ENABLED:-}" == "true" || "${NTFY_ENABLED:-}" == "1" ]]; then
    start_notifier "${NTFY_BASE_URL:-http://127.0.0.1:${OPENCODE_SERVER_PORT}}"
  fi
}

oc_export_env

# Attach the TUI to the server already running on OPENCODE_SERVER_PORT. Shared
# by `run.sh attach` and by `run.sh server` when it finds its own server up.
# Defined after oc_export_env so every exec below inherits the exported stack
# environment (config path, XDG dirs, {env:...} values, kill switches).
do_attach() {
  local project_dir="$1"
  [[ -d "${project_dir}" ]] || oc_die "'${project_dir}' is not a directory"
  local status
  status="$(oc_check_server)"
  if [[ "${status}" != "ok" ]]; then
    oc_die "no server answering on 127.0.0.1:${OPENCODE_SERVER_PORT} (${status}).
  Start one in another terminal:  ${SCRIPT_DIR}/run.sh server"
  fi
  cd "${project_dir}" || exit 1
  # No --auto here: `opencode attach` has no such flag (only the TUI and `run`
  # do). OPENCODE_PERMISSION from oc_export_env carries the posture instead.
  echo "attaching TUI to http://localhost:${OPENCODE_SERVER_PORT} (dir ${project_dir})"
  exec "${OPENCODE_BIN}" attach "http://localhost:${OPENCODE_SERVER_PORT}" \
    --dir "${project_dir}" --password "${OPENCODE_SERVER_PASSWORD}" \
    --username "${OPENCODE_SERVER_USERNAME}"
}

echo
echo "OpenCode (native)     : ${OPENCODE_BIN} ($(oc_installed_version))"
echo "config                : ${OPENCODE_CONFIG_FILE}"
echo "state dir             : ${OPENCODE_STATE_DIR}"
echo "model                 : dgx-vllm/${VLLM_MODEL_ID} -> ${VLLM_BASE_URL}"
echo "permissions           : $([[ "${OPENCODE_AUTO}" == "yes" ]] && echo "auto-approved (OPENCODE_AUTO=yes)" || echo "ask before edit/shell")"
# Set by oc_export_env only when the directory exists.
if [[ -n "${OPENCODE_CONFIG_DIR:-}" ]]; then
  echo "config dir            : ${OPENCODE_CONFIG_DIR} (agents/ commands/ skills/ plugins/)"
fi
echo

# --- 5. modes ----------------------------------------------------------------
case "${MODE}" in
  tui)
    PROJECT_DIR="${1:-$PWD}"
    if [[ ! -d "${PROJECT_DIR}" ]]; then
      oc_die "'${PROJECT_DIR}' is not a directory (usage: ./run.sh [project-dir])"
    fi
    cd "${PROJECT_DIR}" || exit 1
    AUTO_ARGS=()
    [[ "${OPENCODE_AUTO}" == "yes" ]] && AUTO_ARGS=("--auto")
    # exec so Ctrl+C and the process lifecycle stay clean.
    if (( ${#AUTO_ARGS[@]} > 0 )); then
      exec "${OPENCODE_BIN}" "${AUTO_ARGS[@]}" "${PROJECT_DIR}"
    else
      exec "${OPENCODE_BIN}" "${PROJECT_DIR}"
    fi
    ;;

  server)
    # The server runs agents that execute shell as you. Loopback by default;
    # without basic auth anything on the machine can drive it, so refuse to
    # start with the placeholder (same policy as agent_canvas_native/run.sh
    # for its public-mode API key).
    if [[ -z "${OPENCODE_SERVER_PASSWORD:-}" || "${OPENCODE_SERVER_PASSWORD}" == "REPLACE_ME" ]]; then
      oc_die "server mode needs a real OPENCODE_SERVER_PASSWORD — it is currently
       '${OPENCODE_SERVER_PASSWORD:-<empty>}'. Generate one into .env:
         python3 -c 'import secrets;print(\"OPENCODE_SERVER_PASSWORD=\"+secrets.token_urlsafe(24))' >> ${SCRIPT_DIR}/.env
       (./install.sh does this when it creates .env), or run the TUI instead:
         ${SCRIPT_DIR}/run.sh"
    fi
    if command -v lsof >/dev/null 2>&1 \
       && lsof -nP -iTCP:"${OPENCODE_SERVER_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
      # Re-running `run.sh server` while a server is already up is the common
      # case: attach to it rather than dying like a port collision.
      if [[ "$(oc_check_server)" == "ok" ]]; then
        echo "a server is already listening on ${OPENCODE_SERVER_PORT} — attaching the TUI to it."
        do_attach "${1:-$PWD}"
      fi
      oc_die "port ${OPENCODE_SERVER_PORT} is already in use by something else.
  Choose another:  OPENCODE_SERVER_PORT=5000 ./opencode_native/run.sh server
  (8000 = vLLM tunnel, 8020 = Agent Canvas, 4096 = this stack's default.)"
    fi
    maybe_start_notifier
    echo "web UI      : http://localhost:${OPENCODE_SERVER_PORT}/"
    echo "API         : http://localhost:${OPENCODE_SERVER_PORT}/doc  (basic auth: ${OPENCODE_SERVER_USERNAME})"
    echo "attach TUI  : ./opencode_native/run.sh attach [dir]"
    echo "stop        : Ctrl+C"
    echo
    exec "${OPENCODE_BIN}" serve \
      --port "${OPENCODE_SERVER_PORT}" --hostname "${OPENCODE_BIND_HOST}"
    ;;

  attach)
    do_attach "${1:-$PWD}"
    ;;

  run)
    if [[ $# -eq 0 ]]; then
      echo "usage: ./opencode_native/run.sh run \"your prompt\"   (or run --help)"
      exit 2
    fi
    # opencode needs a project dir; use the CWD the caller ran from. A -m is
    # optional because the profile already selects dgx-vllm/<model>.
    AUTO_ARGS=()
    [[ "${OPENCODE_AUTO}" == "yes" ]] && AUTO_ARGS=("--auto")
    if (( ${#AUTO_ARGS[@]} > 0 )); then
      exec "${OPENCODE_BIN}" run "${AUTO_ARGS[@]}" "$@"
    fi
    exec "${OPENCODE_BIN}" run "$@"
    ;;

  *)
    usage
    exit 2
    ;;
esac
