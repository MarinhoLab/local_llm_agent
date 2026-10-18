#!/usr/bin/env bash
#
# run.sh — start the *native* Agent Canvas stack (no Docker): UI + agent-server
# + automation server + ingress as a local process, per
# https://docs.openhands.dev/openhands/usage/agent-canvas/setup ("npm").
#
# Steps:
#   1. source agent_canvas_native/.env if present;
#   2. verify the agent-canvas binary is available (run install.sh if not);
#   3. preflight: fail unless AGENT_CANVAS_PORT and PORT+1 are both free, and
#      warn (without failing) if the vLLM endpoint is not reachable yet — the
#      Canvas itself starts fine without it, you just configure the LLM profile
#      afterwards;
#   4. start bind_guard.py, which publishes PORT on this machine's local
#      addresses only, then exec the agent-canvas launcher on loopback at
#      PORT+1. With LAN_BIND=off, step 4 execs agent-canvas on PORT directly instead, with
#      nothing listening off-loopback.
#
# The agent-server keeps per-conversation runtime state (conversations,
# workspaces, terminal history, logs) under AGENT_CANVAS_STATE
# (default: ./openhands-state). The auto-generated API key, the encryption key
# and your LLM profile always live in ~/.openhands. Agents work on local files
# directly — there is no container boundary, so the agent sees the whole
# filesystem your user can read.
#
# Usage:
#   ./agent_canvas_native/run.sh                  # + reachable on LAN/tailnet IPs
#   LAN_BIND=off ./agent_canvas_native/run.sh     # loopback only
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
_env_LAN="${LAN_BIND:-}"
_env_LAN_CIDRS="${BIND_ALLOW_CIDRS:-}"
_env_LAN_HOSTS="${BIND_ALLOW_HOSTS:-}"

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

[[ -n "$_env_PORT" ]]      && AGENT_CANVAS_PORT="$_env_PORT"
[[ -n "$_env_STATE" ]]     && AGENT_CANVAS_STATE="$_env_STATE"
[[ -n "$_env_VLLM_URL" ]]  && VLLM_BASE_URL="$_env_VLLM_URL"
[[ -n "$_env_VLLM_KEY" ]]  && VLLM_API_KEY="$_env_VLLM_KEY"
[[ -n "$_env_LAN" ]]       && LAN_BIND="$_env_LAN"
[[ -n "$_env_LAN_CIDRS" ]] && BIND_ALLOW_CIDRS="$_env_LAN_CIDRS"
[[ -n "$_env_LAN_HOSTS" ]] && BIND_ALLOW_HOSTS="$_env_LAN_HOSTS"
unset _env_PORT _env_STATE _env_VLLM_URL _env_VLLM_KEY _env_LAN _env_LAN_CIDRS _env_LAN_HOSTS

AGENT_CANVAS_PORT="${AGENT_CANVAS_PORT:-8020}"
AGENT_CANVAS_STATE="${AGENT_CANVAS_STATE:-${SCRIPT_DIR}/openhands-state}"
VLLM_BASE_URL="${VLLM_BASE_URL:-http://localhost:8000/v1}"
VLLM_API_KEY="${VLLM_API_KEY:-local-dgx-key}"
LAN_BIND="${LAN_BIND:-on}"
BIND_ALLOW_CIDRS="${BIND_ALLOW_CIDRS:-127.0.0.0/8,::1/128,192.168.0.0/16,100.64.0.0/10}"
BIND_ALLOW_HOSTS="${BIND_ALLOW_HOSTS:-}"

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

# --- 3a. ingress port preflight ---------------------------------------------
if [[ ! "${AGENT_CANVAS_PORT}" =~ ^[0-9]+$ ]] || (( AGENT_CANVAS_PORT < 1 || AGENT_CANVAS_PORT > 65533 )); then
  echo "ERROR: AGENT_CANVAS_PORT must be a number between 1 and 65533 (got '${AGENT_CANVAS_PORT}')." >&2
  echo "       LAN_BIND (on by default) also uses AGENT_CANVAS_PORT + 1, hence the bound." >&2
  exit 1
fi

# With LAN_BIND on, two ingress ports are needed: the published one (the
# bind_guard front door) and one above it for the loopback-only launcher.
LAN_BIND_LC="$(printf '%s' "${LAN_BIND}" | tr '[:upper:]' '[:lower:]')"
if [[ "${LAN_BIND_LC}" != "off" && "${LAN_BIND_LC}" != "false" && "${LAN_BIND_LC}" != "0" ]]; then
  LAN_INTERNAL_PORT=$((AGENT_CANVAS_PORT + 1))
else
  LAN_INTERNAL_PORT=""
  LAN_BIND_LC="off"
fi
# Running run.sh again replaces whatever an earlier run left behind — a live
# stack, a launcher whose guard died, a guard whose launcher died, or services
# orphaned by a killed launcher. A process counts as ours only if its command
# line names this stack; anything else on these ports is reported, not killed.
STACK_PORTS=("${AGENT_CANVAS_PORT}" "$((AGENT_CANVAS_PORT + 1))"
  "${OH_CANVAS_SAFE_BACKEND_PORT:-18000}" "${OH_CANVAS_SAFE_AUTOMATION_PORT:-18001}"
  "${OH_CANVAS_SAFE_VITE_PORT:-3001}" "${OH_CANVAS_SAFE_VSCODE_PORT:-19000}")
STACK_RE='bind_guard\.py|agent-canvas|openhands|agent-server'

_listeners() {  # pids listening on TCP port $1
  if command -v lsof >/dev/null 2>&1; then
    lsof -t -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null
  else
    ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2
  fi | sort -u
}
_cmd() { ps -o command= -p "$1" 2>/dev/null; }
_ppid() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }
_stack_pids() {  # every listener of ours, plus its ancestors that are ours too
  local port pid
  for port in "${STACK_PORTS[@]}"; do
    for pid in $(_listeners "${port}"); do
      while [[ -n "${pid}" && "${pid}" -gt 1 ]] && _cmd "${pid}" | grep -Eq "${STACK_RE}"; do
        echo "${pid}"
        pid="$(_ppid "${pid}")"
      done
    done
  done | sort -u
}
_alive() { local p; for p in "$@"; do kill -0 "${p}" 2>/dev/null && return 0; done; return 1; }

OLD_PIDS=($(_stack_pids))
if (( ${#OLD_PIDS[@]} )); then
  echo "Stopping the previous Agent Canvas run (pids ${OLD_PIDS[*]})..."
  # Topmost first, so the launcher can stop its own services gracefully.
  ROOTS=()
  for _pid in "${OLD_PIDS[@]}"; do
    [[ " ${OLD_PIDS[*]} " == *" $(_ppid "${_pid}") "* ]] || ROOTS+=("${_pid}")
  done
  kill -TERM "${ROOTS[@]}" 2>/dev/null
  for _ in $(seq 60); do _alive "${OLD_PIDS[@]}" || break; sleep 0.5; done
  # Whatever did not go: everything we found, plus anything newly listening.
  OLD_PIDS+=($(_stack_pids))
  if _alive "${OLD_PIDS[@]}"; then
    kill -TERM "${OLD_PIDS[@]}" 2>/dev/null
    for _ in $(seq 10); do _alive "${OLD_PIDS[@]}" || break; sleep 0.5; done
    kill -KILL "${OLD_PIDS[@]}" 2>/dev/null
    sleep 0.5
  fi
fi

for _port in "${STACK_PORTS[@]}"; do
  [[ "${_port}" == "$((AGENT_CANVAS_PORT + 1))" && "${LAN_BIND_LC}" == "off" ]] && continue
  for _pid in $(_listeners "${_port}"); do
    echo "ERROR: port ${_port} is held by pid ${_pid}, which is not part of this stack:" >&2
    echo "         $(_cmd "${_pid}")" >&2
    echo "  Stop it, or choose another port:  AGENT_CANVAS_PORT=8030 ./agent_canvas_native/run.sh" >&2
    echo "  (8000 = vLLM tunnel, 8020 = this stack's default ingress; with LAN_BIND=on" >&2
    echo "   the launcher also needs AGENT_CANVAS_PORT + 1; the services use" >&2
    echo "   OH_CANVAS_SAFE_BACKEND/AUTOMATION/VITE/VSCODE_PORT.)" >&2
    exit 1
  done
done
unset _port _pid OLD_PIDS ROOTS

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

  # 4b. notifier daemon (Python stdlib only — no venv needed). Point it at the
  #     agent-server through the ingress (AGENT_CANVAS_PORT), which proxies
  #     /api; NTFY_BASE_URL overrides this if the agent-server is reachable
  #     directly on another port.
  NOTIFY_LOG="${STATE_LOG_DIR}/ntfy.log"
  NTFY_BASE_URL="http://localhost:${AGENT_CANVAS_PORT}" \
  NTFY_STATE_FILE="${AGENT_CANVAS_STATE}/ntfy_notifier_state.json" \
    nohup python3 "${SCRIPT_DIR}/ntfy_notifier.py" \
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
# Internal service ports default to 18000/18001. They are NOT shifted with the
# ingress port, so if they collide on your machine (a second Canvas stack, or a
# sandbox whose own Agent Canvas occupies them) set OH_CANVAS_SAFE_BACKEND_PORT
# / OH_CANVAS_SAFE_AUTOMATION_PORT in .env or on the command line.
echo
echo "Agent Canvas (native) : http://localhost:${AGENT_CANVAS_PORT}"
echo "state dir             : ${AGENT_CANVAS_STATE}"
echo "LLM profile (UI)      : Settings > LLM — provider OpenAI-compatible, base URL ${VLLM_BASE_URL}"
echo

if [[ "${LAN_BIND_LC}" == "off" ]]; then
  # exec replaces the shell so Ctrl+C / the process lifecycle is clean.
  # --public is deliberately NOT passed: local mode auto-generates the API key
  # and injects the UI (no login). Nothing listens off-loopback.
  exec agent-canvas \
    --port "${AGENT_CANVAS_PORT}"
fi

# --- LAN_BIND: publish on local addresses only (the default) ----------------
# The launcher has exactly one bind knob: 127.0.0.1 (default) or everything
# (--host 0.0.0.0). Neither is what we want, and off-loopback it also refuses to
# inject the session key, so every browser — including this one — would need a
# manual key. Instead the launcher runs on loopback at PORT+1 and bind_guard.py
# listens on PORT across the addresses inside BIND_ALLOW_CIDRS (by
# default: loopback, 192.168/16 and 100.64/10 — the Tailscale range). Addresses
# outside the allowlist bind nothing and answer nothing, and browsing from a
# LAN or tailnet address still needs no key. See its docstring.
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found in PATH — bind_guard.py needs it." >&2
  echo "       Install Python 3 (e.g. brew install python3), or set LAN_BIND=off" >&2
  echo "       to run the launcher directly with nothing listening off-loopback." >&2
  exit 1
fi
# The macOS application firewall silently drops inbound connections for a
# binary it has never been asked about — the bind succeeds and localhost keeps
# working, so the only symptom is a timeout from every other machine. The
# firewall keys on the binary path, so a Homebrew/uv upgrade that changes that
# path can quietly turn the stack off-network again.
if [[ "$(uname)" == "Darwin" ]] && [[ -x /usr/libexec/ApplicationFirewall/socketfilterfw ]]; then
  FW_STATE="$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)"
  case "${FW_STATE}" in *"enabled"*)
    PY_BIN="$(python3 -c 'import os,sys; print(os.path.realpath(sys.executable))' 2>/dev/null)"
    if ! /usr/libexec/ApplicationFirewall/socketfilterfw --listapps 2>/dev/null \
         | grep -Fq -- "${PY_BIN:-!/nonexistent}"; then
      echo "WARNING: the macOS application firewall is on and ${PY_BIN:-python3} is not" >&2
      echo "         in its allow list — LAN clients will time out even though the" >&2
      echo "         guard is listening. Allow it once with:" >&2
      echo "           sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add ${PY_BIN:-\$(command -v python3)}" >&2
      echo "           sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp ${PY_BIN:-\$(command -v python3)}" >&2
      echo "         (A GUI prompt usually appears on the first LAN bind instead.)" >&2
    fi
  ;;
  esac
fi
export BIND_PUBLIC_PORT="${AGENT_CANVAS_PORT}"
export BIND_INTERNAL_PORT="${LAN_INTERNAL_PORT}"
export BIND_ALLOW_CIDRS BIND_ALLOW_HOSTS
echo "LAN_BIND              : on — also served on this machine's LAN/tailnet IPs"
echo "                        (see the 'listening on' lines below; allowlist: ${BIND_ALLOW_CIDRS}${BIND_ALLOW_HOSTS:+ + hosts})"
echo "                        LAN_BIND=off in .env makes it loopback-only again"
echo
# The guard is only a proxy. It runs beside the launcher rather than above it,
# so Ctrl+C and the launcher's own shutdown work exactly as with LAN_BIND=off;
# the exec makes this shell's pid the launcher's, and the guard exits when that
# pid (its parent) does — nothing is left holding a port for the next run.
python3 "${SCRIPT_DIR}/bind_guard.py" &
exec agent-canvas --host 127.0.0.1 --port "${LAN_INTERNAL_PORT}"
