#!/usr/bin/env bash
#
# install.sh — one-time setup for the *native* OpenCode stack (no Docker).
#
# OpenCode (https://opencode.ai/docs/) is a terminal coding agent, here as the
# alternative macOS-side client to retired-stack/. Both drive the same
# vLLM endpoint over the same SSH tunnel.
#
# Steps:
#   1. verify prerequisites: bash, curl, git (opencode itself needs no
#      Node/Python — it is a single binary);
#   2. install or upgrade the opencode binary (official installer, npm
#      fallback, OPENCODE_INSTALL_METHOD/OPENCODE_VERSION to force either);
#   3. create the isolated state dirs (config, XDG data/cache, logs) so the
#      stack never touches ~/.config/opencode or ~/.local/share/opencode;
#   4. generate config/opencode.json from opencode.example.jsonc (never
#      overwriting an edited copy), sanity-check the JSON, and create
#      config/opencode-dir for this stack's agents/commands/skills;
#   5. create .env from example.env if missing, filling a random server
#      password and NTFY_TOPIC (both are credentials, so neither may survive
#      as a placeholder).
#
# Usage:
#   ./opencode_native/install.sh            # install/upgrade + configure
#   ./opencode_native/install.sh --check    # verify the install, change nothing
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_stack.sh
source "${SCRIPT_DIR}/lib_stack.sh"

CHECK_ONLY=0
if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=1
fi

# --- 1. prerequisites -------------------------------------------------------
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: '$1' not found in PATH." >&2
    echo "  $2" >&2
    exit 1
  fi
}
need bash  "This script needs bash (macOS ships 3.2, which is enough)."
need curl  "Install curl:  brew install curl"
need git   "opencode snapshots worktree changes with git:  brew install git"

oc_load_env
oc_apply_defaults
oc_resolve_paths

if [[ "${CHECK_ONLY}" == "1" ]]; then
  echo "opencode_native stack v${OPENCODE_STACK_VERSION} — check mode"
  echo "  state dir : ${OPENCODE_STATE_DIR}"
  echo "  config    : ${OPENCODE_CONFIG_FILE}"
  echo "  model     : ${VLLM_MODEL_ID} @ ${VLLM_BASE_URL}"
fi

# --- 2. the opencode binary -------------------------------------------------
# Install methods, in the order install.sh considers them:
#   curl  — official installer, binary under ~/.opencode/bin (no Node needed);
#   npm   — the opencode-ai package into your npm global prefix.
# An existing binary is kept (and upgraded in place) unless
# OPENCODE_INSTALL_METHOD forces a specific one, so re-running never surprises
# you by swapping how opencode arrived.
INSTALL_METHOD="${OPENCODE_INSTALL_METHOD:-}"
HAVE_OPENCODE=0
if oc_resolve_binary >/dev/null 2>&1; then
  HAVE_OPENCODE=1
fi

install_via_curl() {
  local script args=()
  script="$(mktemp "${TMPDIR:-/tmp}/opencode-install.XXXXXX")" || return 1
  if ! curl -fsSL --max-time 60 https://opencode.ai/install -o "${script}"; then
    rm -f "${script}"
    return 1
  fi
  [[ -n "${OPENCODE_VERSION:-}" ]] && args+=("--version" "${OPENCODE_VERSION#v}")
  # "${args[@]}" on an empty array is an unset-variable error under bash 3.2
  # with set -u, hence the length guard.
  if (( ${#args[@]} > 0 )); then
    bash "${script}" "${args[@]}"
  else
    bash "${script}"
  fi
  local rc=$?
  rm -f "${script}"
  return "${rc}"
}

install_via_npm() {
  command -v npm >/dev/null 2>&1 || return 1
  local pkg="opencode-ai${OPENCODE_VERSION:+@${OPENCODE_VERSION#v}}"
  if npm install -g "${pkg}" >/dev/null 2>&1; then
    return 0
  fi
  # Global prefix not writable (common on managed Macs): fall back to a
  # per-user prefix rather than sudo, like retired-stack/install.sh.
  oc_warn "npm install -g ${pkg} failed (prefix not writable) — retrying with ~/.npm-global"
  npm config set prefix "${HOME}/.npm-global" >/dev/null 2>&1 || true
  export PATH="${HOME}/.npm-global/bin:${PATH}"
  npm install -g "${pkg}" >/dev/null 2>&1
}

if [[ "${CHECK_ONLY}" != "1" ]]; then
  case "${INSTALL_METHOD}" in
    curl)
      echo "installing opencode with the official installer..."
      install_via_curl || oc_die "official installer failed (set OPENCODE_INSTALL_METHOD=npm to try npm)"
      ;;
    npm)
      command -v npm >/dev/null 2>&1 || oc_die "OPENCODE_INSTALL_METHOD=npm but npm is not on PATH"
      echo "installing opencode-ai from npm..."
      install_via_npm || oc_die "npm install -g opencode-ai failed"
      ;;
    "")
      if [[ "${HAVE_OPENCODE}" == "1" ]]; then
        echo "opencode found: $(oc_resolve_binary)"
      elif command -v curl >/dev/null 2>&1 && install_via_curl; then
        :
      elif install_via_npm; then
        :
      else
        oc_die "could not install opencode. Install it yourself:
  curl -fsSL https://opencode.ai/install | bash     (binary in ~/.opencode/bin)
  npm install -g opencode-ai                        (needs Node)
then re-run this script."
      fi
      ;;
    *)
      oc_die "OPENCODE_INSTALL_METHOD must be 'curl' or 'npm' (got '${INSTALL_METHOD}')"
      ;;
  esac
fi

if ! oc_resolve_binary >/dev/null 2>&1; then
  oc_die "'opencode' is not on PATH. Its installer puts it in ~/.opencode/bin —
add that to PATH (run.sh adds it automatically for its own use):
  export PATH=\"\$HOME/.opencode/bin:\$PATH\""
fi

OPENCODE_BIN="$(oc_resolve_binary)"
OPENCODE_VER="$(oc_installed_version)"
echo "opencode  ${OPENCODE_VER:-unknown} (${OPENCODE_BIN})"
if [[ -n "${OPENCODE_VERSION:-}" && "${OPENCODE_VER}" != "${OPENCODE_VERSION#v}" ]]; then
  oc_die "opencode on PATH is ${OPENCODE_VER:-unknown} but you pinned OPENCODE_VERSION=${OPENCODE_VERSION}.
A stale copy elsewhere on PATH is shadowing it (check: type -a opencode)."
fi
if [[ -z "${OPENCODE_VERSION:-}" ]]; then
  echo "note: unpinned — opencode tracks whatever is installed. Record a validated"
  echo "      version as OPENCODE_VERSION in .env for reproducible installs."
fi
# The TUI needs a real terminal; warn early rather than mid-session.
if [[ "${TERM:-}" == "dumb" || -z "${TERM:-}" ]]; then
  oc_warn "TERM=${TERM:-<unset>} — the TUI needs a modern terminal (WezTerm,"
  oc_warn "        Alacritty, Ghostty, Kitty, iTerm2). 'run.sh server' works anywhere."
fi

if [[ "${CHECK_ONLY}" == "1" ]]; then
  echo "  binary    : OK"
else
  # --- 3. isolated state dirs ----------------------------------------------
  # XDG_* are repointed into the state dir by run.sh; create them here so a
  # first run has somewhere to write, and so `--check` can assert the layout.
  mkdir -p "${OPENCODE_DATA_DIR}" "${OPENCODE_XDG_CONFIG}/opencode" \
           "${OPENCODE_XDG_CACHE}" "${OPENCODE_LOG_DIR}" "${OPENCODE_CONFIG_DIR}" \
    || oc_die "could not create the state dir under ${OPENCODE_STATE_DIR}"
  echo "state dir : ${OPENCODE_STATE_DIR}"

  # --- 4. config ------------------------------------------------------------
  if [[ ! -f "${OPENCODE_CONFIG_FILE}" ]]; then
    install -m 600 "${SCRIPT_DIR}/opencode.example.jsonc" "${OPENCODE_CONFIG_FILE}"
    echo "config    : generated ${OPENCODE_CONFIG_FILE}"
  else
    echo "config    : kept existing ${OPENCODE_CONFIG_FILE}"
  fi
  # Strip // comments and trailing commas, then parse — a broken template
  # should fail here rather than as an opaque opencode error later.
  if ! python3 - "${OPENCODE_CONFIG_FILE}" <<'PY' 2>/dev/null
import json, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
src = re.sub(r'"(?:\\.|[^"\\])*"', lambda m: re.sub(r'//', '\x00\x00', m.group(0)), src)
src = re.sub(r'^\s*//.*$', '', src, flags=re.M)
src = src.replace('\x00\x00', '//')
src = re.sub(r',(\s*[}\]])', r'\1', src)
json.loads(src)
PY
  then
    oc_die "${OPENCODE_CONFIG_FILE} is not valid JSON/JSONC — fix or delete it and re-run."
  fi
fi

# --- 5. .env ----------------------------------------------------------------
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  echo ".env      : already exists — left untouched"
elif [[ "${CHECK_ONLY}" == "1" ]]; then
  oc_die "no .env yet — run ./opencode_native/install.sh (without --check)"
else
  cp "${SCRIPT_DIR}/example.env" "${SCRIPT_DIR}/.env"
  echo ".env      : created from example.env — edit it to taste"
  # Both values are credentials and must never survive as placeholders: the
  # server password guards an endpoint that runs shell as you, and on an
  # unauthenticated ntfy server the topic name IS the credential
  # (see ntfy/README.md).
  FILLED="$(python3 - "${SCRIPT_DIR}/.env" <<'PY' 2>/dev/null
import re, secrets, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
pw = secrets.token_urlsafe(24)
topic = "opencode-" + secrets.token_hex(8)
text = re.sub(r"(?m)^OPENCODE_SERVER_PASSWORD=.*$", "OPENCODE_SERVER_PASSWORD=" + pw, text)
text = re.sub(r"(?m)^NTFY_TOPIC=.*$", "NTFY_TOPIC=" + topic, text)
open(path, "w", encoding="utf-8").write(text)
print(topic)
PY
)"
  if [[ -n "${FILLED}" ]]; then
    chmod 600 "${SCRIPT_DIR}/.env" 2>/dev/null || true
    echo "            random OPENCODE_SERVER_PASSWORD generated (server mode uses it)"
    echo "            random NTFY_TOPIC set (${FILLED}) — use the same topic on the"
    echo "            phone and in ntfy/.env once you enable notifications"
  else
    oc_warn "could not fill in OPENCODE_SERVER_PASSWORD / NTFY_TOPIC — set both in"
    oc_warn "        ${SCRIPT_DIR}/.env before starting server mode or enabling ntfy"
  fi
fi

# --- 6. reachability (warn only) --------------------------------------------
VLLM_CHECK="$(oc_check_vllm)"
case "${VLLM_CHECK}" in
  ok)
    echo "vLLM      : ${VLLM_BASE_URL} serving '${VLLM_MODEL_ID}'"
    ;;
  served-models-mismatch)
    oc_warn "the endpoint answers but does not serve '${VLLM_MODEL_ID}'."
    echo "          Check VLLM_MODEL_ID in .env against:"
    echo "            curl -H \"Authorization: Bearer \$VLLM_API_KEY\" ${VLLM_BASE_URL%/}/models"
    ;;
  *)
    echo "note:     vLLM endpoint ${VLLM_BASE_URL} is not reachable — that is fine now,"
    oc_print_tunnel_hint
    ;;
esac

echo
if [[ "${CHECK_ONLY}" == "1" ]]; then
  echo "check passed."
else
  echo "done. Start it with:"
  echo "  ./opencode_native/run.sh                 # TUI in the current directory"
  echo "  ./opencode_native/run.sh /path/to/repo    # TUI on a project"
  echo "  ./opencode_native/run.sh server            # headless API + web UI"
fi
