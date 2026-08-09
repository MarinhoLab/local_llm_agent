#!/usr/bin/env bash
set -euo pipefail

: "${DGX_SSH_TARGET:?DGX_SSH_TARGET is required, e.g. user@192.168.1.50}"
DGX_REMOTE_HOST="${DGX_REMOTE_HOST:-localhost}"
DGX_REMOTE_PORT="${DGX_REMOTE_PORT:-8000}"
LOCAL_TUNNEL_PORT="${LOCAL_TUNNEL_PORT:-8000}"
SSH_EXTRA_OPTS="${SSH_EXTRA_OPTS:-}"

mkdir -p /root/.ssh
chmod 700 /root/.ssh || true
chmod 600 /root/.ssh/id_* 2>/dev/null || true

exec ssh -N \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=accept-new \
  ${SSH_EXTRA_OPTS} \
  -L 0.0.0.0:${LOCAL_TUNNEL_PORT}:${DGX_REMOTE_HOST}:${DGX_REMOTE_PORT} \
  "${DGX_SSH_TARGET}"
