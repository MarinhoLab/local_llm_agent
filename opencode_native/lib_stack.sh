#!/usr/bin/env bash
#
# lib_stack.sh — shared helpers for install.sh and run.sh. Sourced, not run.
#
# Holds the pieces both scripts must agree on exactly: where the stack's state
# lives, how .env is loaded without letting it clobber caller-set variables,
# the environment exported to the opencode binary, and the endpoint/model
# checks.
#
# Everything is functions plus the two module-level constants below; nothing
# here runs at source time except defining them.

# Version of this stack's tooling (not the opencode version).
OPENCODE_STACK_VERSION="1.0.0"

# Default ingress/server port and the pinned-by-default model alias, kept here
# so install.sh and run.sh cannot drift.
OPENCODE_DEFAULT_PORT=4096
OPENCODE_DEFAULT_MODEL_ID=qwen-local

# --- logging ----------------------------------------------------------------

oc_warn() { echo "WARNING: $*" >&2; }

oc_die() {
  echo "ERROR: $*" >&2
  exit 1
}

# --- paths ------------------------------------------------------------------

# Absolutize a path the way docker compose resolves a relative volume: "~" and
# "~/x" against $HOME, bare/./-relative against $1 (the stack folder), absolute
# untouched. Echoes the result.
oc_abs_path() {
  local base="$1" value="$2"
  case "${value}" in
    "~") echo "${HOME}" ;;
    "~/"*) echo "${HOME}/${value#\~/}" ;;
    /*) echo "${value}" ;;
    *) echo "${base}/${value#./}" ;;
  esac
}

# Resolve the stack's directories into globals. Requires SCRIPT_DIR.
oc_resolve_paths() {
  OPENCODE_STATE_DIR="$(oc_abs_path "${SCRIPT_DIR}" "${OPENCODE_STATE_DIR:-./opencode-state}")"
  OPENCODE_CONFIG_FILE="${OPENCODE_CONFIG_FILE:-${OPENCODE_STATE_DIR}/config/opencode.json}"
  OPENCODE_CONFIG_FILE="$(oc_abs_path "${SCRIPT_DIR}" "${OPENCODE_CONFIG_FILE}")"
  OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${OPENCODE_STATE_DIR}/config/opencode-dir}"
  OPENCODE_CONFIG_DIR="$(oc_abs_path "${SCRIPT_DIR}" "${OPENCODE_CONFIG_DIR}")"
  OPENCODE_DATA_DIR="${OPENCODE_STATE_DIR}/data"
  OPENCODE_XDG_CONFIG="${OPENCODE_STATE_DIR}/xdg-config"
  OPENCODE_XDG_CACHE="${OPENCODE_STATE_DIR}/cache"
  OPENCODE_LOG_DIR="${OPENCODE_STATE_DIR}/logs"
}

# --- .env -------------------------------------------------------------------

# Source .env without letting it override what the caller set on the command
# line (`OPENCODE_SERVER_PORT=5000 ./run.sh server` must win), via the
# snapshot/restore trick below. Values are exported
# because the opencode process inherits them.
oc_load_env() {
  local env_file="${SCRIPT_DIR}/.env"
  local _k _i=0
  local -a _keys=(
    VLLM_BASE_URL VLLM_API_KEY VLLM_MODEL_ID
    OPENCODE_SERVER_PORT OPENCODE_BIND_HOST OPENCODE_SERVER_PASSWORD
    OPENCODE_SERVER_USERNAME OPENCODE_AUTO
    OPENCODE_STATE_DIR OPENCODE_CONFIG_FILE OPENCODE_CONFIG_DIR
    OPENCODE_VERSION OPENCODE_INSTALL_METHOD
    NTFY_ENABLED NTFY_SERVER NTFY_TOPIC NTFY_AUTH_TOKEN NTFY_TOPIC_MODE
    NTFY_HOSTNAME NTFY_DEEP_LINK_PREFIX NTFY_DEEP_LINK_BASE
    NTFY_POLL_SECONDS NTFY_COOLDOWN_SECONDS
    NTFY_EVENTS NTFY_PRIORITIES NTFY_INCLUDE_MESSAGE NTFY_BASE_URL
    NTFY_STATE_FILE NTFY_DRY_RUN
  )
  # Snapshot the caller's values (only non-empty ones count as "set"), clear
  # the variables so .env starts from a clean slate, source .env, then put the
  # caller's values back. `VAR=x ./run.sh` therefore beats .env, and an empty
  # value in .env never masks a real export inherited from the shell.
  # Parallel arrays rather than an associative one: macOS ships bash 3.2.
  local -a _vals=()
  for _k in "${_keys[@]}"; do
    _vals+=("${!_k:-}")
    unset "${_k}" 2>/dev/null || true
  done

  if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090,SC1091  # .env is git-ignored / runtime
    # set -a exports everything, because the opencode process inherits these.
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
  fi

  for _i in "${!_keys[@]}"; do
    _k="${_keys[$_i]}"
    if [[ -n "${_vals[$_i]}" ]]; then
      # Braces inside the eval string are required: `$_vals[$_i]` would expand
      # the scalar $_vals (element 0) followed by a literal subscript.
      eval "${_k}=\${_vals[$_i]}"
      export "${_k}"
    fi
  done
}

# Apply defaults for everything the stack reads. Call after oc_load_env.
oc_apply_defaults() {
  VLLM_BASE_URL="${VLLM_BASE_URL:-http://localhost:8000/v1}"
  VLLM_API_KEY="${VLLM_API_KEY:-local-dgx-key}"
  VLLM_MODEL_ID="${VLLM_MODEL_ID:-${OPENCODE_DEFAULT_MODEL_ID}}"
  OPENCODE_SERVER_PORT="${OPENCODE_SERVER_PORT:-${OPENCODE_DEFAULT_PORT}}"
  OPENCODE_BIND_HOST="${OPENCODE_BIND_HOST:-127.0.0.1}"
  OPENCODE_SERVER_USERNAME="${OPENCODE_SERVER_USERNAME:-opencode}"
  OPENCODE_AUTO="${OPENCODE_AUTO:-no}"
  case "${OPENCODE_AUTO}" in
    yes | true | 1 | on | YES | TRUE) OPENCODE_AUTO=yes ;;
    *) OPENCODE_AUTO=no ;;
  esac
}

# --- opencode environment ---------------------------------------------------

# Export the environment the opencode binary runs with. This is the whole
# isolation story: config, XDG dirs, endpoint substitution, and the
# background-download kill switches. Anything not set here is opencode's
# default, which is what we do not want (it would touch ~/.config/opencode and
# phone home for updates/LSPs).
oc_export_env() {
  # Profile + endpoint substitution ({env:...} in the config template).
  export OPENCODE_CONFIG="${OPENCODE_CONFIG_FILE}"
  export OPENCODE_DGX_BASE_URL="${VLLM_BASE_URL}"
  export OPENCODE_DGX_API_KEY="${VLLM_API_KEY}"

  # Isolate config/data/cache per stack instead of ~/.config and ~/.local/share.
  export XDG_CONFIG_HOME="${OPENCODE_XDG_CONFIG}"
  export XDG_DATA_HOME="${OPENCODE_DATA_DIR}"
  export XDG_CACHE_HOME="${OPENCODE_XDG_CACHE}"
  if [[ -d "${OPENCODE_CONFIG_DIR}" ]]; then
    # Home for this stack's agents/commands/skills/plugins (see README).
    export OPENCODE_CONFIG_DIR
  fi

  # Self-contained, quiet background behaviour (see README → Design notes).
  export OPENCODE_DISABLE_AUTOUPDATE=true
  export OPENCODE_DISABLE_AUTO_SHARE="${OPENCODE_DISABLE_AUTO_SHARE:-true}"
  export OPENCODE_DISABLE_LSP_DOWNLOAD="${OPENCODE_DISABLE_LSP_DOWNLOAD:-true}"
  export OPENCODE_DISABLE_MOUSE="${OPENCODE_DISABLE_MOUSE:-false}"

  # Permission posture. The TUI also gets --auto from run.sh; `serve` has no
  # --auto flag, so the inlined JSON is what makes server mode unattended.
  if [[ "${OPENCODE_AUTO}" == "yes" ]]; then
    export OPENCODE_PERMISSION='{"edit":"allow","shell":"allow"}'
  else
    unset OPENCODE_PERMISSION 2>/dev/null || true
  fi
}

# --- binary -----------------------------------------------------------------

# Put opencode's own install dir and a per-user npm prefix on PATH if the
# binary is not reachable yet. Echoes nothing; call before oc_resolve_binary.
oc_extend_path() {
  if ! command -v opencode >/dev/null 2>&1 && [[ -x "${HOME}/.opencode/bin/opencode" ]]; then
    export PATH="${HOME}/.opencode/bin:${PATH}"
  fi
  if ! command -v opencode >/dev/null 2>&1 && [[ -x "${HOME}/.npm-global/bin/opencode" ]]; then
    export PATH="${HOME}/.npm-global/bin:${PATH}"
  fi
}

# Echo the opencode binary path, or return 1 (caller prints the install hint).
oc_resolve_binary() {
  oc_extend_path
  command -v opencode >/dev/null 2>&1 && { command -v opencode; return 0; }
  return 1
}

# Echo the installed version (e.g. 1.18.30) or nothing.
oc_installed_version() {
  command -v opencode >/dev/null 2>&1 || return 0
  opencode --version 2>/dev/null | tr -d '[:space:]' | grep -E '^[0-9]+' || true
}

# --- endpoint checks --------------------------------------------------------

# Echo the port from VLLM_BASE_URL (pure bash: no sed/IP-octet traps).
oc_vllm_port() {
  local rest="${VLLM_BASE_URL#*://}" port
  rest="${rest%%/*}"           # host:port
  port="${rest##*:}"
  [[ "${port}" =~ ^[0-9]+$ ]] && echo "${port}" || echo "8000"
}

# 0 = the model is reachable and served, 1 = not. Prints a one-line reason on
# failure (non-fatal for the caller).
oc_check_vllm() {
  local url="${VLLM_BASE_URL%/}"
  if ! curl -fsS --max-time 5 "${url}/models" \
        -H "Authorization: Bearer ${VLLM_API_KEY}" >/dev/null 2>&1; then
    echo "unreachable"
    return 1
  fi
  if ! curl -fsS --max-time 5 "${url}/models" \
        -H "Authorization: Bearer ${VLLM_API_KEY}" \
        | grep -q "\"id\"[[:space:]]*:[[:space:]]*\"${VLLM_MODEL_ID}\""; then
    echo "served-models-mismatch"
    return 1
  fi
  echo "ok"
  return 0
}

# Print the SSH tunnel to start when the endpoint is down.
oc_print_tunnel_hint() {
  local port; port="$(oc_vllm_port)"
  echo "      Start the tunnel, then re-run:"
  echo
  echo "        ssh -N \\"
  echo "          -o ServerAliveInterval=30 \\"
  echo "          -o ServerAliveCountMax=3 \\"
  echo "          -o ExitOnForwardFailure=yes \\"
  echo "          -L ${port}:127.0.0.1:${port} \\"
  echo "          <user>@<spark-host>"
  echo
}

# --- server health ----------------------------------------------------------

# Echo "ok" when the opencode server answers /global/health, "auth" when it
# answers 401 (up, wrong password), "unreachable" otherwise.
oc_check_server() {
  local url="http://127.0.0.1:${OPENCODE_SERVER_PORT}" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}/global/health" 2>/dev/null)"
  case "${code}" in
    200) echo "ok"; return 0 ;;
    401) echo "auth"; return 1 ;;
    *) echo "unreachable"; return 1 ;;
  esac
}

# --- tailscale (web-UI publishing) ------------------------------------------

# Why this exists: macOS's application firewall drops inbound connections to
# the ad-hoc-signed opencode binary (codesign flags=0x20002) on every
# non-loopback interface, so `serve --hostname <tailnet-ip>` binds fine but is
# unreachable. Tailscale's own signed process is firewall-allowed, so
# `tailscale serve` can proxy the tailnet to the loopback server instead —
# no firewall changes, no relay, and still tailnet-only.
# Echo the Tailscale CLI path, or return 1. The App Store build ships the CLI
# inside the app bundle rather than on PATH.
oc_find_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
    return 0
  fi
  local candidate="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  [[ -x "${candidate}" ]] && { echo "${candidate}"; return 0; }
  return 1
}

# Run the Tailscale CLI bounded by `timeout` when available. The CLI blocks
# forever when Serve is not enabled in the tailnet ACLs (it prints an enable
# URL but never exits), so an unbounded call would hang run.sh.
# Usage: oc_tailscale_cli <cli> [args...]
oc_tailscale_cli() {
  local cli="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout 15 "${cli}" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 15 "${cli}" "$@"
  else
    # No timeout available: background, poll briefly, and abandon if it hangs.
    "${cli}" "$@" &
    local pid=$! waited=0
    while kill -0 "${pid}" 2>/dev/null && (( waited < 15 )); do
      sleep 1
      (( waited += 1 ))
    done
    kill -0 "${pid}" 2>/dev/null && kill "${pid}" 2>/dev/null
    wait "${pid}" 2>/dev/null || true
  fi
}
