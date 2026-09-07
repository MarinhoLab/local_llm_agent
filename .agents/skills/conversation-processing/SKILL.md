---
name: conversation-processing
description: >-
  Where OpenHands conversations are stored in the Agent Canvas sandbox, their
  on-disk layout (per-conversation event dirs and the flat bash_events dump),
  how to read them, and safe, fast patterns for mining/processing them without
  leaking secrets or melting the machine.
license: MIT
compatibility: Linux Agent Canvas sandbox (state volume at /home/openhands/.openhands)
triggers:
  - conversations
  - conversation history
  - process conversations
  - mine conversations
  - read conversation events
  - where are conversations
---

OpenHands conversation data lives in the Agent Canvas **state volume**, mounted
at `/home/openhands/.openhands` (host dir `agent_canvas/openhands-state`). The
live runtime data sits under the `agent-canvas/` subdirectory of that volume.
There are **two on-disk formats** to be aware of.

## Where things are

| Location | Format | What it is |
|---|---|---|
| `/home/openhands/.openhands/agent-canvas/conversations/<conversation_id>/` | One directory per conversation | The canonical store. |
| `/home/openhands/.openhands/agent-canvas/bash_events/` | Flat directory, one JSON file per bash command/output | A global, timestamp-prefixed dump of all terminal traffic across conversations. |

> **Path caveat (important).** This skill documents the *current* Agent Canvas
> layout, where state lives under the per-user home
> (`/home/openhands/.openhands/agent-canvas/...`). Older OpenHands versions
> stored the same data under a `/workspace` volume
> (`/workspace/conversations/<id>/` and `/workspace/bash_events/`). If you are
> looking at a repo whose docs reference `/workspace/...`, that is the retired
> location — map it to `~/.openhands/agent-canvas/...`. There is no legacy
> per-repo `project/<repo>/context/` dump in the current layout either.

### 1. Per-conversation dir: `.../conversations/<id>/`

`<id>` is the conversation's hex id (the same value as `meta.json:id`). Each
directory contains:

- `meta.json` — conversation metadata. Populated fields (as of Agent Server
  1.44) include: `id`, `conversation_id` (dashed form), `title`, `autotitle`
  (a bool), `initial_message`, `created_at`/`updated_at`, `tags`, `workspace`
  (a **dict**: `{"working_dir": ..., "kind": "LocalWorkspace"}`), `worktree`
  (bool), `forked_from_conversation_id`/`forked_from_event_id`, and
  **`secrets` / `secrets_encrypted`** — sensitive, see "Secrets" below.
  Note: there is **no** `agent` field (model/base_url are not stored here) and
  **no** `initial_message` as a plain string — `initial_message` is a
  **dict** `{"role", "content", "run"}` where `content` is a list of content
  blocks.
- `base_state.json` — initial environment state snapshot (can be ~100 KB+).
- `owner_lease.json` / `.owner_lease.lock` — runtime lease files; ignore them.
- `events/` — one JSON file per event, named
  `event-NNNNN-<uuid>.json` (e.g. `event-00042-...`). The 5-digit index is
  zero-padded, so **lexicographic filename order == chronological order**.
  Some files can be empty (write in progress) — skip zero-byte files. There is
  also an `events/.eventlog.lock` — ignore it.

> There is **no** `TASKS.json` in the current layout (task-tracker state is not
> persisted as a top-level file here).

Each event file is a single JSON object with `id`, `timestamp`, `source`,
`parent_id`, and `kind`.

- `source` is one of `agent`, `user`, or **`environment`** (the current runtime
  uses `environment` heavily — e.g. `ConversationStateUpdateEvent`). Older
  docs mention `system`; in the current store you will see `environment`.
- `ActionEvent` → `action` dict with a `kind` (`TerminalAction`,
  `FileEditorAction`, ...); a `TerminalAction` holds `command`, `is_input`,
  `reset`.
- `ObservationEvent` → `observation` dict. For terminal traffic the `kind` is
  **`TerminalObservation`** (not `BashObservation`) and it holds `content`,
  `is_error`, `command`, `exit_code`, `timeout`. File edits produce
  `FileEditorObservation`.
- `MessageEvent` → `llm_message` (a dict with `role` and `content`, where
  `content` is a **list of content blocks** like `{"type":"text","text":...}`;
  also `thinking_blocks`), plus `activated_skills` and `extended_content`.
  (Not a top-level `content` string.)
- `SystemPromptEvent`, `ConversationStateUpdateEvent`, and condensation /
  compaction markers also appear.

### 2. Flat dump: `.../bash_events/`

Files are named
`<YYYYMMDDHHMMSSsss>_BashCommand_<command_id>` and the paired
`<timestamp>_BashOutput_<command_id>_<output_id>`:

- `BashCommand`: `command`, `cwd`, `timeout`, `id`, `timestamp`, `kind`.
- `BashOutput`: `command_id`, `order`, `exit_code`, `stdout`, `stderr`, `id`,
  `timestamp`, `kind`.

Join command and output on `id` == `command_id`. This is the fastest way to
reconstruct "every shell command ever run plus its exit code".

## Reading a conversation (reference script)

```python
import json, os

def load_events(conv_dir):
    """Yield events of a .../conversations/<id> dir in chronological order."""
    ev_dir = os.path.join(conv_dir, "events")
    for fn in sorted(os.listdir(ev_dir)):          # zero-padded index => ordered
        p = os.path.join(ev_dir, fn)
        if not os.path.isfile(p) or os.path.getsize(p) == 0:
            continue                                # skip lock + in-flight writes
        with open(p) as fh:
            yield json.load(fh)

def conversation_text(conv_dir):
    """Plain-text transcript: user/agent messages + shell commands."""
    lines = []
    for e in load_events(conv_dir):
        kind = e.get("kind")
        src = e.get("source")
        if kind == "MessageEvent":
            llm = e.get("llm_message") or {}
            content = llm.get("content") or []
            text = "".join(b.get("text", "") for b in content
                           if isinstance(b, dict) and b.get("type") == "text")
            lines.append(f"[{src}] {text}")
        elif kind == "ActionEvent":
            a = e.get("action", {}) or {}
            if a.get("kind") == "TerminalAction":
                lines.append(f"[{src}] $ {a.get('command','')}")
            elif a.get("kind"):
                lines.append(f"[{src}] {a.get('kind')}")
        elif kind == "ObservationEvent":
            o = e.get("observation", {}) or {}
            if o.get("kind") == "TerminalObservation":
                lines.append(f"[result] exit={o.get('exit_code')} "
                             f"{o.get('content') or ''}")
    return "\n".join(lines)
```

## Manually condensing a conversation

Yes — condensation can be forced on demand. The Agent Server exposes a
dedicated endpoint that injects a `CondensationRequest` and runs one agent step
so the condenser summarizes the history:

```
POST /api/conversations/{conversation_id}/condense
```

- **No request body.** Returns `200 {"success": true}` on success, or `404`
  if the conversation id is unknown.
- **Auth:** the session API key — header `X-Session-API-Key` (the key is
  auto-generated and persisted in the state volume at
  `~/.openhands/agent-canvas/api-key.txt`). Verified: 200 with the key,
  401 without.

```bash
KEY=$(tr -d '\n' < ~/.openhands/agent-canvas/api-key.txt)
# conversation id = meta.json:conversation_id (dashed) or the hex dir name
curl -sS -X POST -H "X-Session-API-Key: $KEY" \
  http://localhost:18000/api/conversations/<conversation_id>/condense
```

Notes:

- **Requires a condenser that handles requests.** This only works if the
  conversation's agent uses an `LLMSummarizingCondenser` (the Agent Canvas
  default, which returns `handles_condensation_requests() == True`). If the
  profile was switched to a `NoOpCondenser` or condensation is disabled, the
  call raises `ValueError: Cannot condense conversation ...` (HTTP 500) with a
  hint to configure an `LLMSummarizingCondenser`.
- **It blocks on a running step.** If the agent is mid-turn, `condense()` waits
  for the current step to finish before condensing, so it is safe to call while
  the agent is active.
- **It is a view operation, not a file delete.** The condenser marks older
  events as *forgotten* (`Condensation.forgotten_event_ids`) and inserts a
  `CondensationSummaryEvent`; those events are excluded from the agent's *future*
  LLM view. The on-disk `events/*.json` files are **not** deleted, so
  history-mining (the "Typical uses" below) is unaffected by condensation.
- **SDK equivalent:** on an SDK conversation object, `conversation.condense()`
  does the same thing (see
  `openhands.sdk.conversation.impl.local_conversation.LocalConversation.condense`).

For contrast, the condenser also runs **automatically** — on a
context-window-exceeded error, when the view exceeds `max_size` events
(default 240), or when the total token count exceeds `max_tokens` (which
defaults to the LLM's effective input limit). The manual endpoint just forces
that same path on demand.

## Performance rules (these corpora are large)

- `base_state.json` can be ~100 KB+, and the **`SystemPromptEvent`**
  (usually `event-00000-...`) is by far the largest single event file
  (hundreds of KB, since it embeds the full system prompt + tool schemas).
  Only that one event is heavy; the rest are a few KB each. So a naive full
  `json.load` of a whole conversation is cheap, but a full-corpus pass across
  *many* conversations can still be slow — skip `event-00000-*` when you only
  need tool calls and messages.
- To **search**: `grep -rho <pattern> <one-conv>/events/*.json` per
  conversation is fine; a grep across *all* conversations can exceed the soft
  timeout — loop per conversation, or sample a subset.
- To **mine tool-call errors**: grep the event files for
  `Error validating tool` / `Cannot execute multiple commands` and normalize
  the message — that is how the `terminal-action` skill was produced.
- Write intermediate results to `/tmp`, not into the repo or the state
  volume.

## Secrets — read carefully

`meta.json` contains `secrets` and `secrets_encrypted`, and event files can
contain secrets that were echoed into commands. When processing conversations:

- Select the fields you need (`title`, `initial_message`, event `kind`,
  `action.command`); **do not dump whole `meta.json` or whole event files**
  to logs or into generated artifacts.
- Never write conversation contents into files that get committed.
- Mask anything that looks like a token (`tvly-`, `ghp_`, `hf_`, bearer
  headers) before quoting in PR descriptions, skill files, or reports.

## Typical uses

- **Mine failure patterns** (e.g. tool validation errors) across all
  conversations to write process skills.
- **Rebuild a transcript** of a past session for debugging or a PR description.
- **Answer "what did we try before?"** by grepping event `command` fields for
  a keyword instead of re-running experiments.
