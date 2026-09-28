#!/usr/bin/env python3
"""Check how full the current conversation's context window is.

Exit codes:
    0  usage >= threshold (default 90%) -> trigger the handover workflow
    3  usage below threshold -> keep working normally
    2  cannot determine usage (config/API error, unknown window)

The session API key is resolved from the environment or the Agent Canvas
key file and is never printed.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

DEFAULT_THRESHOLD = 90.0


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


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
    fail("no Agent Canvas session API key found (SESSION_API_KEY / ~/.openhands/agent-canvas/api-key.txt)")


def resolve_base() -> str:
    for var in ("AGENT_CANVAS_BACKEND", "AGENT_SERVER_URL", "OH_AGENT_SERVER_URL"):
        val = os.environ.get(var, "").strip()
        if val:
            return val.rstrip("/")
    return "http://localhost:18000"


def get_json(url: str, key: str, headers=None):
    req = urllib.request.Request(url, headers={"X-Session-API-Key": key, **(headers or {})})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode("utf-8"))


def conversation_id_from_cwd() -> str:
    base = os.path.basename(os.getcwd().rstrip("/"))
    if re.fullmatch(r"[0-9a-f]{32}", base):
        return f"{base[:8]}-{base[8:12]}-{base[12:16]}-{base[16:20]}-{base[20:]}"
    if re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", base):
        return base
    fail(f"cannot derive conversation id from working directory {os.getcwd()}")


def extract_usage(stats):
    """Return (current_prompt_tokens, context_window, model) for this conversation.

    The current context size is the LATEST per-turn prompt_tokens, not the
    accumulated total. `accumulated_token_usage.prompt_tokens` sums every
    turn and must not be used.
    """
    model = None
    for entry in stats.values():
        tu = entry.get("accumulated_token_usage") or {}
        model = model or tu.get("model")
    for entry in stats.values():
        tues = entry.get("token_usages") or []
        if tues:
            last = tues[-1]
            return (last.get("prompt_tokens") or 0,
                    last.get("context_window") or 0,
                    model or last.get("model"))
    for entry in stats.values():
        acc = entry.get("accumulated_token_usage") or {}
        if acc.get("prompt_tokens"):
            return (acc.get("prompt_tokens") or 0,
                    acc.get("context_window") or 0,
                    model or acc.get("model"))
    return 0, 0, model


def main() -> None:
    threshold = DEFAULT_THRESHOLD
    if "--threshold" in sys.argv:
        try:
            threshold = float(sys.argv[sys.argv.index("--threshold") + 1])
        except (IndexError, ValueError):
            fail("--threshold requires a number, e.g. --threshold 90")

    key = resolve_key()
    base = resolve_base()
    conv_id = conversation_id_from_cwd()

    try:
        conv = get_json(f"{base}/api/conversations/{conv_id}", key)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
        fail(f"cannot reach agent server at {base}: {exc}")

    stats = (conv.get("stats") or {}).get("usage_to_metrics") or {}
    prompt_tokens, context_window, model = extract_usage(stats)

    # Operator override for models whose provider does not report the window.
    override = os.environ.get("HANDOVER_CONTEXT_WINDOW", "").strip()
    if override.isdigit():
        context_window = int(override)

    if not prompt_tokens:
        print(f"conversation {conv_id}: no token usage recorded yet")
        sys.exit(2)

    if context_window:
        pct = 100.0 * prompt_tokens / context_window
        status = "AT/ABOVE threshold -> HAND OVER now" if pct >= threshold else "below threshold"
        bar = "#" * int(min(pct, 100) // 5) + "-" * (20 - int(min(pct, 100) // 5))
        print(f"conversation: {conv_id}")
        print(f"context:      {prompt_tokens} / {context_window} tokens ({pct:.1f}%) [{bar}]")
        print(f"threshold:    {threshold:.0f}%  -> {status}")
        sys.exit(0 if pct >= threshold else 3)

    # Unknown context window: fall back to a growth heuristic.
    heuristic = int(threshold) * 1000
    print(f"conversation: {conv_id}")
    print(f"context:      {prompt_tokens} prompt tokens (context window unknown, model={model})")
    print("set HANDOVER_CONTEXT_WINDOW=<tokens> for exact percentages; otherwise heuristic:")
    if prompt_tokens >= heuristic:
        print(f">= {heuristic} prompt tokens — treat as >= {threshold:.0f}% and hand over.")
        sys.exit(0)
    print(f"below {heuristic} prompt tokens — keep working; re-check after heavy steps.")
    sys.exit(3)


if __name__ == "__main__":
    main()
