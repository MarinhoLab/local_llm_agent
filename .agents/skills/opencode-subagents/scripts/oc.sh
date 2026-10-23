#!/usr/bin/env bash
#
# oc.sh — drive the opencode_native server's HTTP API as "subagents".
#
# Each `run` creates a fresh opencode session scoped to a directory, sends one
# prompt, blocks until the turn ends, and prints the session's final text.
# Run several in the background (`&` + `wait`) for parallel subagents.
#
# Usage:
#   oc.sh ping                         HTTP status of the server (200 = up + auth ok)
#   oc.sh run <dir> <title> <prompt>   new session in <dir>; prints final reply
#   oc.sh list [dir]                   sessions of <dir> (default: the server's): id, title, directory
#   oc.sh pending [dir]                permission prompts waiting for an answer in <dir>'s sessions
#   oc.sh abort <session-id>           stop a running turn (does not clear its pending prompts)
#   oc.sh delete <session-id>          delete a session
#
# The basic-auth password is read from opencode_native/.env and never printed.
# Override the model with OC_PROVIDER / OC_MODEL, the server with OC_URL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
ENV_FILE="${OC_ENV_FILE:-${REPO_ROOT}/opencode_native/.env}"
OC_URL="${OC_URL:-http://127.0.0.1:4096}"
OC_PROVIDER="${OC_PROVIDER:-dgx-vllm}"
OC_MODEL="${OC_MODEL:-qwen-local}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found — run opencode_native/install.sh" >&2
  exit 1
fi
PW="$(grep -E '^OPENCODE_SERVER_PASSWORD=' "${ENV_FILE}" | cut -d= -f2-)"
USER_NAME="$(grep -E '^OPENCODE_SERVER_USERNAME=' "${ENV_FILE}" | cut -d= -f2- || true)"
USER_NAME="${USER_NAME:-opencode}"

api() { curl -sS -u "${USER_NAME}:${PW}" "$@"; }
json() { python3 -c "$1" "${@:2}"; }

cmd="${1:-}"; shift || true
case "${cmd}" in
  ping)
    api -o /dev/null -w '%{http_code}\n' "${OC_URL}/config"
    ;;
  run)
    [[ $# -eq 3 ]] || { echo "usage: oc.sh run <dir> <title> <prompt>" >&2; exit 2; }
    dir="$(cd "$1" && pwd)" title="$2" prompt="$3"
    q="directory=$(json 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "${dir}")"
    sid="$(api -X POST "${OC_URL}/session?${q}" -H 'Content-Type: application/json' \
            -d "$(json 'import json,sys;print(json.dumps({"title":sys.argv[1]}))' "${title}")" \
          | json 'import json,sys;print(json.load(sys.stdin)["id"])')"
    echo "session: ${sid}" >&2
    body="$(json 'import json,sys;print(json.dumps({"model":{"providerID":sys.argv[1],"modelID":sys.argv[2]},"parts":[{"type":"text","text":sys.argv[3]}]}))' \
            "${OC_PROVIDER}" "${OC_MODEL}" "${prompt}")"
    api --max-time "${OC_TIMEOUT:-3600}" -X POST "${OC_URL}/session/${sid}/message?${q}" \
        -H 'Content-Type: application/json' -d "${body}" \
      | json '
import json, sys
d = json.load(sys.stdin)
text = "\n".join(p.get("text", "") for p in d.get("parts", []) if p.get("type") == "text").strip()
print(text or json.dumps(d)[:2000])'
    ;;
  list|pending)
    # Sessions are filed per directory: without ?directory= the server lists only its own.
    q=""
    [[ -n "${1:-}" ]] && q="?directory=$(json 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$(cd "$1" && pwd)")"
    if [[ "${cmd}" == list ]]; then
      api "${OC_URL}/session${q}" \
        | json 'import json,sys
for s in json.load(sys.stdin): print(s["id"], "|", s.get("title",""), "|", s.get("directory",""))'
    else
      api "${OC_URL}/permission${q}" \
        | json 'import json,sys
for p in json.load(sys.stdin): print(p["sessionID"], "|", p["permission"], "|", " ".join(p.get("patterns", [])))'
    fi
    ;;
  abort)
    api -X POST "${OC_URL}/session/${1:?session id}/abort"; echo
    ;;
  delete)
    api -X DELETE "${OC_URL}/session/${1:?session id}"; echo
    ;;
  *)
    sed -n '3,18p' "$0" >&2
    exit 2
    ;;
esac
