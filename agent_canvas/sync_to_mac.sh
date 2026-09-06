#!/usr/bin/env bash
# Sync this folder (and .gitignore) from the OpenHands sandbox into the
# Mac's git checkout, where Docker Desktop's file sharing can see it.
#
# Why: the sandbox's /workspace is a virtiofs share that is NOT a subpath of
# the Mac repo checkout the Docker daemon can bind
# (/Users/user/git/local_llm_agent). Containers started from here must mount
# Mac-side paths, so the tracked files are copied over before
# `sudo docker compose up -d`.
#
# Untracked state dirs (openhands-state/, projects/) are created on the Mac
# directly; their contents persist there and are never copied back.
#
# Usage (from the sandbox): bash agent_canvas/sync_to_mac.sh
set -euo pipefail

REPO="/workspace/project/local_llm_agent"
MAC_REPO="/Users/user/git/local_llm_agent"

tar -C "$REPO" -cf - \
  agent_canvas/compose.yml \
  agent_canvas/example.env \
  agent_canvas/sync_to_mac.sh \
  .gitignore \
  README.md \
  AGENTS.md \
  .agents/skills/docker-usage/SKILL.md \
| sudo docker run -i --rm --entrypoint sh -v "$MAC_REPO":/repo ghcr.io/openhands/agent-canvas:latest \
  -c "mkdir -p /repo/agent_canvas/openhands-state /repo/agent_canvas/projects &&
      tar -C /repo -xf - &&
      echo '--- synced files:' &&
      ls -la /repo/agent_canvas"
