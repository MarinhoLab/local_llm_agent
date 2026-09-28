#!/usr/bin/env python3
"""Context-window handover for Agent Canvas.

Commits pending work in the current conversation's workspace, then starts a
fresh follow-up conversation whose only message is
"continue conversation <CONVERSATION_ID>" (the CURRENT conversation's id).
The follow-up recovers context itself from the parent's persisted events and
workspace (see the handover skill, "Follow-up side").

Monitors the follow-up until it is verified started; exits:
    0  follow-up verified started (running/idle with a real agent event)
    2  configuration problem (missing key, API unreachable, bad workspace)
    3  follow-up creation failed (HTTP error from POST)
    4  follow-up created but not verified started within the timeout

Usage:
    handover.py [--dry-run] [--no-commit] [--poll-every 10] [--timeout 600]
    handover.py --cleanup <conversation_id>
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

DEFAULT_POLL_EVERY = 10
DEFAULT_TIMEOUT = 600
COMMIT_MESSAGE = "WIP: checkpoint before context handover"
CLIENT_TOOLS = ["canvas_ui_control", "launch_child_conversation"]
DROP_FROM_AGENT_SETTINGS = ("schema_version", "mcp_config")


def log(msg: str) -> None:
    print(f"[handover] {msg}", flush=True)


def copy_skill_into(new_ws_dir: str) -> None:
    """Copy the handover skill into the follow-up's fresh workspace.

    The follow-up's project-skill loader reads <workspace>/.agents/skills/,
    so copying guarantees it receives the "Follow-up side" recovery workflow
    without depending on exploratory behavior.
    """
    skill_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if not os.path.isfile(os.path.join(skill_dir, "SKILL.md")):
        return
    dest = os.path.join(new_ws_dir, ".agents", "skills", os.path.basename(skill_dir))
    try:
        shutil.copytree(skill_dir, dest, ignore=shutil.ignore_patterns("__pycache__"))
        log(f"copied handover skill into {dest}")
    except OSError as exc:
        log(f"WARNING: could not copy the skill into the follow-up workspace: {exc}")


def fail(msg: str, code: int) -> None:
    log(f"ERROR: {msg}")
    sys.exit(code)


# ---------------------------------------------------------------- API basics

def resolve_key() -> str:
    for var in ("SESSION_API_KEY", "OH_SESSION_API_KEYS_0", "LOCAL_BACKEND_API_KEY"):
        val = os.environ.get(var, "").strip()
        if val:
            return val
    path = os.path.expanduser("~/.openhands/agent-canvas/api-key.txt")
    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as fh:
            val = fh.read().strip()
            if val:
                return val
    fail("no Agent Canvas session API key found", 2)


def resolve_base() -> str:
    for var in ("AGENT_CANVAS_BACKEND", "AGENT_SERVER_URL", "OH_AGENT_SERVER_URL"):
        val = os.environ.get(var, "").strip()
        if val:
            return val.rstrip("/")
    return "http://localhost:18000"


def api(base: str, key: str, method: str, path: str, body=None, headers=None):
    url = f"{base}{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"X-Session-API-Key": key, **(headers or {})},
    )
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            detail = json.loads(raw)
        except ValueError:
            detail = raw[:500]
        return exc.code, detail
    except (urllib.error.URLError, TimeoutError) as exc:
        fail(f"cannot reach agent server at {base}: {exc}", 2)


# ------------------------------------------------------- conversation identity

def own_workspace() -> dict:
    ws = os.getcwd().rstrip("/")
    if not ws:
        fail("empty working directory", 2)
    return {"kind": "LocalWorkspace", "working_dir": ws}


def resolve_own_conversation_id(base: str, key: str, ws: dict) -> str:
    """Derive this conversation's id from the workspace path, then verify via API."""
    base_name = os.path.basename(ws["working_dir"])
    if re.fullmatch(r"[0-9a-f]{32}", base_name):
        candidate = f"{base_name[:8]}-{base_name[8:12]}-{base_name[12:16]}-{base_name[16:20]}-{base_name[20:]}"
    elif re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", base_name):
        candidate = base_name
    else:
        fail(f"workspace {ws['working_dir']} does not look like a canvas conversation workspace", 2)

    status, items = api(base, key, "GET", "/api/conversations/search?limit=100")
    if status != 200:
        fail(f"conversation search failed (HTTP {status}) — cannot verify own conversation id", 2)
    for item in items.get("items", []):
        item_ws = item.get("workspace") or {}
        if item_ws.get("working_dir") == ws["working_dir"]:
            return item["id"]
    log(f"WARNING: {candidate} not found in /api/conversations; using derived id")
    return candidate


# ------------------------------------------------------------------- commit

def commit_pending(workdir: str, do_commit: bool) -> None:
    if not do_commit:
        log("commit skipped (--no-commit)")
        return
    try:
        proc = subprocess.run(
            ["git", "-C", workdir, "status", "--porcelain"],
            capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"WARNING: git status failed ({exc}); proceeding without commit")
        return
    if proc.returncode != 0:
        log(f"WARNING: git status exited {proc.returncode} ({proc.stderr.strip()[:200]}); proceeding without commit")
        return
    if not proc.stdout.strip():
        log("workspace clean — nothing to commit")
        return
    log(f"uncommitted changes detected; committing: {COMMIT_MESSAGE!r}")
    proc = subprocess.run(
        ["git", "-C", workdir, "add", "-A"],
        capture_output=True, text=True, timeout=120,
    )
    if proc.returncode != 0:
        log(f"WARNING: git add failed: {proc.stderr.strip()[:300]}")
        return
    proc = subprocess.run(
        ["git", "-C", workdir, "commit", "-m", COMMIT_MESSAGE],
        capture_output=True, text=True, timeout=120,
    )
    if proc.returncode != 0:
        log(f"WARNING: git commit failed (proceeding; follow-up can still recover from events):")
        log(f"  {proc.stderr.strip()[:300]}")
    else:
        head = subprocess.run(
            ["git", "-C", workdir, "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=30,
        )
        log(f"committed {head.stdout.strip() or 'checkpoint'} on current branch")


# ------------------------------------------------------------------- payload

def redact(obj):
    if isinstance(obj, dict):
        return {k: ("<fernet-encrypted>" if k == "api_key" else redact(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(v) for v in obj]
    return obj


def build_payload(base: str, key: str, own_id: str, own_ws: dict, settings, conv, make_dir=True):
    agent_settings = dict(settings.get("agent_settings") or {})
    for field in DROP_FROM_AGENT_SETTINGS:
        agent_settings.pop(field, None)

    # agent_settings.agent is the agent KIND string (e.g. "CodeActAgent"); the
    # agent context lives in agent_settings.agent_context.
    agent_ctx = dict(agent_settings.get("agent_context") or {})
    for flag in ("load_public_skills", "load_user_skills", "load_project_skills"):
        agent_ctx[flag] = True
    agent_settings["agent_context"] = agent_ctx

    # /api/settings returns agent_settings.tools == null; the Canvas frontend
    # computes the exec tool set (terminal, file_editor, task_tracker,
    # browser_tool_set, ...) at POST time. Mirror that here by copying the
    # CURRENT agent's concrete tools, minus the Canvas client tools, which are
    # delivered separately via the top-level `client_tools` field.
    own_tools = (conv.get("agent") or {}).get("tools") or []

    # client_tools must be full tool objects (name/description/parameters/
    # annotations), not bare names. The current agent carries these in
    # agent.tools[].params.spec — reuse that verbatim.
    client_tools = []
    for t in own_tools:
        if isinstance(t, dict) and t.get("name") in CLIENT_TOOLS:
            spec = (t.get("params") or {}).get("spec")
            if isinstance(spec, dict):
                client_tools.append(dict(spec))
    if not client_tools:
        client_tools = [{"name": n} for n in CLIENT_TOOLS]

    exec_tools = [
        dict(t) for t in own_tools
        if isinstance(t, dict) and t.get("name") not in CLIENT_TOOLS
    ]
    if not exec_tools:
        fail("could not derive the exec tool set from the current agent "
             "(agent.tools empty) — follow-up would have no tools", 2)
    agent_settings["tools"] = exec_tools

    new_conv_id = str(uuid.uuid4())
    new_ws_dir = os.path.join(os.path.dirname(own_ws["working_dir"]), new_conv_id.replace("-", ""))
    if make_dir:
        os.makedirs(new_ws_dir, exist_ok=True)
        copy_skill_into(new_ws_dir)

    max_iterations = conv.get("max_iterations") or 500
    security_analyzer = conv.get("security_analyzer")

    payload = {
        "agent_settings": agent_settings,
        "secrets_encrypted": True,
        "client_tools": client_tools,
        "workspace": {"kind": "LocalWorkspace", "working_dir": new_ws_dir},
        "confirmation_policy": {"kind": "NeverConfirm"},
        "security_analyzer": security_analyzer,
        "max_iterations": max_iterations,
        "stuck_detection": True,
        "autotitle": True,
        "worktree": False,
        "initial_message": {
            "role": "user",
            "content": [{"type": "text", "text": f"continue conversation {own_id}"}],
            "run": True,
        },
    }
    return payload, new_conv_id, new_ws_dir


# ----------------------------------------------------------------- monitoring

def verify_started(base: str, key: str, new_id: str, poll_every: int, timeout: int):
    start = time.time()
    deadline = start + timeout
    last_log = 0.0
    while time.time() < deadline:
        time.sleep(poll_every)
        status, conv = api(base, key, "GET", f"/api/conversations/{new_id}")
        if status != 200:
            log(f"WARNING: cannot read follow-up status (HTTP {status}), retrying")
            continue
        es = conv.get("execution_status")

        status, ev = api(base, key, "GET", f"/api/conversations/{new_id}/events/search?limit=50")
        events = ev.get("items", []) if status == 200 else []
        agent_actions = [e for e in events if e.get("source") == "agent" and e.get("kind") == "ActionEvent"]
        error_events = [
            e for e in events
            if e.get("kind") in ("ConversationErrorEvent", "ErrorEvent")
            or (e.get("kind") == "ObservationEvent" and bool((e.get("observation") or {}).get("is_error")))
        ]
        if error_events and not agent_actions:
            detail = json.dumps(error_events[0])[:400]
            fail(f"follow-up {new_id} produced an error event and no agent activity: {detail}", 4)

        now = time.time()
        if now - last_log > 45:
            last_log = now
            log(f"monitoring: status={es} agent_events={len(agent_actions)} "
                f"(elapsed {int(now - start)}s / {timeout}s)")

        if es in ("error", "stopped", "stuck"):
            fail(f"follow-up {new_id} entered terminal bad state: {es}", 4)
        if agent_actions and es in ("running", "idle", "finished"):
            log(f"VERIFIED: follow-up {new_id} is executing (status={es}, {len(agent_actions)} agent event(s))")
            return
        if es == "idle" and events and any(e.get("source") == "assistant" for e in events):
            log(f"VERIFIED: follow-up {new_id} idle with assistant activity")
            return
    fail(f"follow-up {new_id} never produced an agent event within {timeout}s; "
         f"inspect events at {base}/api/conversations/{new_id}/events/search", 4)


# ---------------------------------------------------------------------- main

def main() -> None:
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    no_commit = "--no-commit" in args
    poll_every, timeout = DEFAULT_POLL_EVERY, DEFAULT_TIMEOUT
    if "--poll-every" in args:
        poll_every = int(args[args.index("--poll-every") + 1])
    if "--timeout" in args:
        timeout = int(args[args.index("--timeout") + 1])

    # --cleanup <id>: delete a previously created follow-up conversation.
    if "--cleanup" in args:
        target = args[args.index("--cleanup") + 1]
        key = resolve_key()
        base = resolve_base()
        status, _ = api(base, key, "DELETE", f"/api/conversations/{target}")
        if status in (200, 202, 204):
            log(f"cleaned up conversation {target}")
        else:
            fail(f"DELETE /api/conversations/{target} -> HTTP {status} (leave it or delete from the UI)", 4)
        return

    key = resolve_key()
    base = resolve_base()
    ws = own_workspace()

    status, _ = api(base, key, "GET", "/api/conversations/search?limit=1")
    if status != 200:
        fail(f"agent server probe failed (HTTP {status})", 2)
    own_id = resolve_own_conversation_id(base, key, ws)
    status, conv = api(base, key, "GET", f"/api/conversations/{own_id}")
    if status != 200:
        fail(f"cannot read own conversation {own_id} (HTTP {status})", 2)
    log(f"own conversation: {own_id} (status={conv.get('execution_status')})")

    commit_pending(ws["working_dir"], do_commit=not no_commit)

    status, settings = api(base, key, "GET", "/api/settings",
                           headers={"X-Expose-Secrets": "encrypted"})
    if status != 200 or not isinstance(settings, dict):
        fail(f"cannot read agent settings (HTTP {status})", 2)
    llm = (settings.get("agent_settings") or {}).get("llm") or {}
    api_key = str(llm.get("api_key") or "")
    if not (api_key.startswith("gAAAAA") or api_key == "**********"):
        fail("encrypted LLM key not returned by /api/settings (X-Expose-Secrets: encrypted) — "
             "refusing to forward a plaintext/absent key", 2)

    payload, new_id, new_ws_dir = build_payload(base, key, own_id, ws, settings, conv,
                                                make_dir=not dry_run)

    log("plan:")
    log(f"  parent conversation : {own_id}")
    log(f"  follow-up id        : {new_id}")
    log(f"  follow-up workspace : {new_ws_dir}")
    log(f"  model               : {llm.get('model')}")
    log(f"  max_iterations      : {payload['max_iterations']}")
    log(f"  initial_message     : {payload['initial_message']['content'][0]['text']!r}")
    log(f"  client_tools        : {[t.get('name') for t in payload['client_tools']]}")
    if dry_run:
        redacted = redact(payload)
        path = os.path.join("/tmp", f"handover-dry-run-{new_id[:8]}.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(redacted, fh, indent=1)
        log(f"--dry-run: no POST performed; redacted payload written to {path}")
        return

    status, resp = api(base, key, "POST", "/api/conversations", body=payload)
    if status not in (200, 201) or not isinstance(resp, dict) or not resp.get("id"):
        fail(f"POST /api/conversations -> HTTP {status}: {json.dumps(resp)[:400]} "
             "(wait ~60s and re-run; after 3 failed attempts report to the user)", 3)
    new_id = resp["id"]
    log(f"created follow-up conversation {new_id}")

    ingress = os.environ.get("AGENT_CANVAS_PORT", "8020")
    log(f"UI link: http://localhost:{ingress}/conversations/{new_id}")
    log(f"API   : {base}/api/conversations/{new_id}")

    verify_started(base, key, new_id, poll_every, timeout)
    log(f"HANDOVER COMPLETE: task continues in conversation {new_id}")


if __name__ == "__main__":
    main()
