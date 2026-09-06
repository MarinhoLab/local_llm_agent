#!/usr/bin/env python3
"""Bootstrap OpenHands settings from environment variables.

The OpenHands V1 web app does NOT read ``LLM_*`` or ``TAVILY_API_KEY`` from the
environment. It resolves the LLM and MCP servers from its own *settings store*
(the same store the GUI writes to, persisted in the ``OPENHANDS_STATE`` volume).
This script bridges the gap: it reads a few env vars and writes them into the
settings store through the official V1 REST API, so a fresh ``docker compose up``
comes up already-configured without anyone touching the GUI.

Semantics:
- The LLM in the env (``.env``) is the **source of truth**. If the live model or
  base URL differs from the env, the full LLM (model, base URL, key) from the
  env is written. If only the API key is missing, just the key is filled in. A
  key the user set by hand is otherwise left alone.
- The named LLM profile is created/kept in sync so the GUI shows it.
- MCP servers are added only if a server at that URL is not already present.
- Idempotent and non-destructive: it never overwrites a hand-set key or removes
  a user's MCP servers, and is a no-op once everything matches.

Stdlib only (urllib) — runs inside the OpenHands image, which already has Python.
See MEMORIES.md for the investigation notes behind this.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

# ── environment ────────────────────────────────────────────────────────────────
OH_URL = os.environ.get("OH_URL", "http://openhands:3000").rstrip("/")
LLM_MODEL = os.environ.get("LLM_MODEL", "").strip()
LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "").strip()
LLM_API_KEY = os.environ.get("LLM_API_KEY", "").strip()
LLM_PROFILE_NAME = os.environ.get("LLM_PROFILE_NAME", "").strip()
DUCKDUCKGO_MCP_URL = os.environ.get("DUCKDUCKGO_MCP_URL", "").strip()
TAVILY_URL = os.environ.get("TAVILY_URL", "https://mcp.tavily.com/mcp").strip()
TAVILY_API_KEY = os.environ.get("TAVILY_API_KEY", "").strip()

# Readiness window: how long to wait for the app server, and how often to poll.
READY_TIMEOUT = int(os.environ.get("OH_READY_TIMEOUT", "300"))
POLL_INTERVAL = float(os.environ.get("OH_POLL_INTERVAL", "2"))


# ── HTTP helper (stdlib) ───────────────────────────────────────────────────────
def http_json(method: str, url: str, body: dict | None = None):
    """Return ``(status_code_or_None, parsed_json_or_None)``.

    Status is ``None`` on connection-level failure (server not up, refused, ...).
    Never raises on HTTP errors — returns the status code so callers can branch.
    """
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method=method
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, _try_json(resp.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, _try_json(e.read().decode())
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        return None, {"_error": str(e)}


def _try_json(raw: str):
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        return None


# ── readiness ──────────────────────────────────────────────────────────────────
def wait_ready(base: str, timeout: int = READY_TIMEOUT, poll: float = POLL_INTERVAL):
    """Block until /health answers 200 and the settings store answers (200 or 404).

    A 404 from ``GET /api/v1/settings`` is *ready*: it means a fresh install with
    no settings saved yet. Returns True on success, False if the window elapses.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status, _ = http_json("GET", f"{base}/health")
        if status == 200:
            s, _ = http_json("GET", f"{base}/api/v1/settings")
            if s in (200, 404):
                return True
        time.sleep(poll)
    log(f"timed out after {timeout}s waiting for the app server")
    return False


# ── pure decision functions (unit-testable, no I/O) ────────────────────────────
def compute_llm_action(cur_settings: dict, model: str, base_url: str, api_key: str):
    """Decide the LLM patch to send.

    File is the source of truth: if the live model or base URL differs from the
    env, the full LLM from the env is written. Otherwise, only a missing API key
    is filled in. Returns ``(need: bool, payload: dict)``.
    """
    llm = (cur_settings.get("agent_settings") or {}).get("llm") or {}
    cur_model = llm.get("model") or ""
    cur_base = (llm.get("base_url") or "").rstrip("/")
    key_set = bool(cur_settings.get("llm_api_key_set"))
    env_base = (base_url or "").rstrip("/")

    model_or_base_differs = (
        (bool(model) and model != cur_model)
        or (bool(env_base) and env_base != cur_base)
    )
    if model_or_base_differs:
        payload: dict = {}
        if model:
            payload["model"] = model
        if env_base:
            payload["base_url"] = env_base
        if api_key:
            payload["api_key"] = api_key
        return True, payload
    if (not key_set) and api_key:
        return True, {"api_key": api_key}
    return False, {}


def compute_profile_action(profiles: dict, name: str, llm_needed: bool):
    """Decide whether to (re)save + activate the named LLM profile.

    Returns ``(do_it: bool, reason: str)``. When the LLM was just (re)written the
    profile is saved from the env values; otherwise, if the profile is missing or
    has no key, it is *snapshotted* from the current live settings (empty body) so
    a hand-edited key is preserved.
    """
    if not name:
        return False, "no profile name"
    if llm_needed:
        return True, "llm being written; save profile to match"
    entry = next(
        (p for p in (profiles.get("profiles") or []) if p.get("name") == name), None
    )
    if entry is None:
        return True, "profile missing; snapshot from live settings"
    if not entry.get("api_key_set"):
        return True, "profile has no api key; refresh from live settings"
    return False, "profile present and up to date"


def compute_mcp_action(
    cur_mcp: dict, duckduckgo_url: str, tavily_url: str, tavily_key: str
):
    """Build the full desired ``mcp_config`` and whether it differs from current.

    Returns ``(changed: bool, desired: dict)``. ``desired`` always contains every
    current entry — ``mcp_config`` is applied *wholesale* by OpenHands — plus any
    missing desired server, matched by URL so nothing is ever duplicated or a
    user's server removed.
    """
    current = cur_mcp if isinstance(cur_mcp, dict) else {}
    desired = {k: v for k, v in current.items() if isinstance(v, dict)}

    def has_url(url: str) -> bool:
        return any(s.get("url") == url for s in desired.values())

    changed = False
    if duckduckgo_url and not has_url(duckduckgo_url):
        desired["duckduckgo"] = {"url": duckduckgo_url, "transport": "sse"}
        changed = True
    if tavily_key and tavily_url and not has_url(tavily_url):
        desired["tavily"] = {
            "url": tavily_url,
            "transport": "streamable-http",
            "auth": {"strategy": "bearer", "value": tavily_key},
        }
        changed = True
    return changed, desired


# ── side effects ───────────────────────────────────────────────────────────────
def log(msg: str) -> None:
    print(f"[oh-bootstrap] {msg}", flush=True)


def write_llm_diff(base: str, payload: dict) -> bool:
    """POST an ``agent_settings_diff.llm`` patch; True on 200/201."""
    status, _ = http_json(
        "POST", f"{base}/api/v1/settings", {"agent_settings_diff": {"llm": payload}}
    )
    return status in (200, 201)


def save_profile(base: str, name: str, llm_payload: dict | None) -> bool:
    """Save a named profile.

    ``llm_payload`` None → empty body → OpenHands snapshots the current
    ``agent_settings.llm`` (used when the live LLM is already correct).
    """
    body = {"llm": llm_payload} if llm_payload else None
    status, _ = http_json("POST", f"{base}/api/v1/settings/profiles/{name}", body)
    return status in (200, 201)


def activate_profile(base: str, name: str) -> bool:
    status, _ = http_json(
        "POST", f"{base}/api/v1/settings/profiles/{name}/activate", {}
    )
    return status in (200, 201)


def write_mcp(base: str, desired: dict) -> bool:
    status, _ = http_json(
        "POST",
        f"{base}/api/v1/settings",
        {"agent_settings_diff": {"mcp_config": desired}},
    )
    return status in (200, 201)


# ── main ───────────────────────────────────────────────────────────────────────
def main() -> int:
    base = OH_URL
    if not wait_ready(base):
        log("FAILED: app server never became ready (will be retried by compose)")
        return 1

    # Current settings (404 on a fresh install → empty).
    s, settings = http_json("GET", f"{base}/api/v1/settings")
    cur_settings = settings if s == 200 and isinstance(settings, dict) else {}
    cur_mcp = (cur_settings.get("agent_settings") or {}).get("mcp_config") or {}

    ps, profiles = http_json("GET", f"{base}/api/v1/settings/profiles")
    cur_profiles = (
        profiles if ps == 200 and isinstance(profiles, dict) else {"profiles": []}
    )

    summary: dict = {"oh_url": base, "llm": {}, "mcp": {}}

    # ── LLM + profile ────────────────────────────────────────────────────────
    if not LLM_MODEL:
        summary["llm"] = {"skipped": "LLM_MODEL not set"}
        log("LLM: skipped (LLM_MODEL not set)")
    else:
        llm_need, llm_payload = compute_llm_action(
            cur_settings, LLM_MODEL, LLM_BASE_URL, LLM_API_KEY
        )
        prof_do, prof_reason = compute_profile_action(
            cur_profiles, LLM_PROFILE_NAME, llm_needed=llm_need
        )

        if llm_need:
            written = write_llm_diff(base, llm_payload)
            summary["llm"] = {"written": written, "diff": sorted(llm_payload)}
            log(f"LLM: wrote {sorted(llm_payload)} -> ok={written}")
        else:
            summary["llm"] = {"written": False, "skipped": "already configured"}
            log("LLM: skipped (already configured)")

        if prof_do:
            # Save from env when the LLM was just (re)written; otherwise
            # snapshot the current live settings (preserves a hand-set key).
            from_env = bool(llm_need and llm_payload)
            saved = save_profile(
                base, LLM_PROFILE_NAME, llm_payload if from_env else None
            )
            activated = activate_profile(base, LLM_PROFILE_NAME) if saved else False
            summary["llm"]["profile_saved"] = saved
            summary["llm"]["profile_activated"] = activated
            summary["llm"]["profile_reason"] = prof_reason
            log(
                f"Profile {LLM_PROFILE_NAME}: saved={saved} "
                f"activated={activated} ({prof_reason})"
            )
        elif LLM_PROFILE_NAME:
            summary["llm"]["profile_saved"] = False
            summary["llm"]["profile_activated"] = False
            summary["llm"]["profile_reason"] = "up to date"

    # ── MCP servers ──────────────────────────────────────────────────────────
    mcp_changed, mcp_desired = compute_mcp_action(
        cur_mcp, DUCKDUCKGO_MCP_URL, TAVILY_URL, TAVILY_API_KEY
    )
    if mcp_changed:
        ok = write_mcp(base, mcp_desired)
        summary["mcp"] = {
            "written": ok,
            "servers": sorted(mcp_desired.keys()),
            "tavily": "configured" if TAVILY_API_KEY else "skipped (no key)",
        }
        log(f"MCP: wrote {sorted(mcp_desired.keys())} -> ok={ok}")
    else:
        summary["mcp"] = {
            "written": False,
            "skipped": "already configured",
            "tavily": "configured" if TAVILY_API_KEY else "skipped (no key)",
        }
        log(f"MCP: skipped (already configured) — {summary['mcp']['tavily']}")

    print(json.dumps(summary), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
