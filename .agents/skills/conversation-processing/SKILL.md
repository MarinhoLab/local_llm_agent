---
name: conversation-processing
description: >-
  Where OpenHands conversations are stored on this machine, their on-disk
  layout (current per-conversation dirs, the flat bash_events dump, and the
  legacy per-event context dumps), how to read them, and safe, fast patterns
  for mining/processing them without leaking secrets or melting the machine.
license: MIT
compatibility: Linux/macOS sandbox with the /workspace volume populated
triggers:
  - conversations
  - conversation history
  - process conversations
  - mine conversations
  - read conversation events
  - where are conversations
---

OpenHands conversation data lives on the shared `/workspace` volume. There are
**three on-disk formats** to be aware of.

## Where things are

| Location | Format | What it is |
|---|---|---|
| `/workspace/conversations/<conversation_id>/` | Current format, one directory per conversation | The canonical store. ~31 conversations as of 2026-09. |
| `/workspace/bash_events/` | Flat directory, one JSON file per bash command/output | A global, timestamp-prefixed dump of all terminal traffic across conversations. |
| `/workspace/project/<repo>/context/` | Legacy flat directory, one JSON file per event | Old OpenHands format (one huge `context/` per repo, e.g. ~29k files in `msc_allocation`). Git-ignored; never commit. |

### 1. Current format: `/workspace/conversations/<id>/`

Each conversation directory contains:

- `meta.json` — conversation metadata: `id`, `conversation_id` (dashed form),
  `title`, `autotitle`, `initial_message`, `agent` (LLM model/base_url),
  `created_at`/`updated_at`, `tags`, `workspace`, `worktree`, fork pointers
  (`forked_from_conversation_id` / `forked_from_event_id`), and
  **`secrets` / `secrets_encrypted`** — sensitive, see "Secrets" below.
- `base_state.json` — initial environment state snapshot.
- `TASKS.json` — the task-tracker list for the conversation.
- `owner_lease.json` / `.owner_lease.lock` — runtime lease files; ignore them.
- `events/` — one JSON file per event, named
  `event-NNNNN-<uuid>.json` (e.g. `event-00042-...`). The 5-digit index is
  zero-padded, so **lexicographic filename order == chronological order**.
  Some files can be empty (write in progress) — skip zero-byte files.

Each event file is a single JSON object:

- `id`, `timestamp`, `source` (`agent` | `user` | `system`), `kind`
- `ActionEvent` → `action` dict with `kind` (`TerminalAction`,
  `FileEditorAction`, `TaskTrackerAction`, ...); a `TerminalAction` holds
  `command`, `is_input`, `reset`.
- `ObservationEvent` → `observation` dict: for terminal traffic that is
  `output`, `exit_code`, `error`, `content`.
- `MessageEvent` → `llm_message` (a dict with `role` and `content`, where
  `content` is a **list of content blocks** like `{"type":"text","text":...}`;
  also `thinking_blocks`), plus `activated_skills` and `extended_content`.
  (Not a top-level `content` string.)
- `ConversationStateUpdateEvent`, `SystemPromptEvent`, `AgentErrorEvent`,
  `Condensation` (context-compaction markers) also appear.

### 2. Flat dump: `/workspace/bash_events/`

Files are named
`<YYYYMMDDHHMMSSsss>_BashCommand_<command_id>` and the paired
`<timestamp>_BashOutput_<command_id>_<output_id>`:

- `BashCommand`: `command`, `cwd`, `timeout`, `id`, `timestamp`, `kind`.
- `BashOutput`: `command_id`, `order`, `exit_code`, `stdout`, `stderr`, `kind`.

Join command and output on `id` == `command_id`. This is the fastest way to
reconstruct "every shell command ever run plus its exit code".

### 3. Legacy format: `/workspace/project/<repo>/context/`

One file per event, named `<16-hex>.json` (no index prefix), with fields
`id`, `kind`, `source`, `timestamp`, `parent_id`, `content`,
`reasoning_content`. Kinds include `StreamingDeltaEvent`, `ActionEvent`,
`ObservationEvent`, `MessageEvent`. Sort by `timestamp` to get order. These
directories can be **tens of thousands of files** — `ls context/` can fail with
"Argument list too long"; use Python's `os.listdir` instead.

## Reading a conversation (reference script)

```python
import json, os

def load_events(conv_dir):
    """Yield events of a /workspace/conversations/<id> dir in order."""
    ev_dir = os.path.join(conv_dir, "events")
    for fn in sorted(os.listdir(ev_dir)):          # zero-padded index => ordered
        p = os.path.join(ev_dir, fn)
        if os.path.getsize(p) == 0:                # skip in-flight writes
            continue
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
            a = e.get("action", {})
            if a.get("kind") == "TerminalAction":
                lines.append(f"[{src}] $ {a.get('command','')}")
            else:
                lines.append(f"[{src}] {a.get('kind')}")
        elif kind == "ObservationEvent":
            o = e.get("observation", {})
            if o.get("kind") == "BashObservation":
                lines.append(f"[result] exit={o.get('exit_code')} "
                             f"{o.get('content') or o.get('output') or ''}")
    return "\n".join(lines)
```

## Performance rules (these corpora are large)

- `meta.json` and `base_state.json` are hundreds of KB; every event file
  re-embeds the full system prompt, so a naive full-corpus `json.load` of all
  ~17k events takes minutes.
- To **search**: `grep -rho <pattern> <one-conv>/events/*.json` per
  conversation is fine; a grep across *all* conversations can exceed the 30s
  soft timeout — loop per conversation with a `timeout` raised, or sample a
  subset of conversations.
- To **count/list** files in legacy `context/` dirs, never use shell globbing
  (argument-list-too-long); use Python `os.listdir`.
- To **mine tool-call errors**: grep the event files for
  `Error validating tool` / `Cannot execute multiple commands` and normalize
  the message — that is how the `terminal-action` skill was produced.
- Write intermediate results to `/tmp`, not into the repo's git-ignored
  `context/` directory, unless the repo convention for that repo says otherwise.

## Secrets — read carefully

`meta.json` contains `secrets` and `secrets_encrypted`, and event files can
contain secrets that were echoed into commands. When processing conversations:

- Select the fields you need (`title`, `initial_message`, event `kind`,
  `action.command`); **do not dump whole `meta.json` or whole event files**
  to logs or into generated artifacts.
- Never write conversation contents (or `context/` exports) into files that
  get committed — `context/` is git-ignored for a reason.
- Mask anything that looks like a token (`tvly-`, `ghp_`, `hf_`, bearer
  headers) before quoting in PR descriptions, skill files, or reports.

## Typical uses

- **Mine failure patterns** (e.g. tool validation errors) across all
  conversations to write process skills.
- **Rebuild a transcript** of a past session for debugging or PR description.
- **Answer "what did we try before?"** by grepping event `command` fields for
  a keyword instead of re-running experiments.
