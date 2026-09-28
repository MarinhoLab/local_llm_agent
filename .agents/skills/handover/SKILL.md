---
name: handover
description: >-
  Context-window handover for Agent Canvas: when the conversation's full
  context reaches 90% of the model's context window, commit pending work and
  hand the task to a fresh follow-up conversation whose only message is
  "continue conversation <conversation-id>". The follow-up recovers context
  itself from the parent's persisted events and workspace. Includes a
  monitoring loop that verifies the follow-up started executing and a retry
  policy for failed starts.
license: MIT
compatibility: OpenHands agent inside an Agent Canvas local stack (agent-server API at http://localhost:18000, session key in ~/.openhands/agent-canvas/api-key.txt)
triggers:
  - hand over
  - hand off
  - continue in a new conversation
  - carry on in a fresh context
  - context window full
  - context is 90 percent
---

# Context-window handover

When the full context of the current conversation reaches **90%** of the model's
context window, the agent hands the task over to a fresh follow-up conversation
instead of degrading in place. The follow-up agent continues the same task with
a clean context window; the outgoing agent only verifies the handover, then
finishes.

## Hard rules

- **Commit before delegating.** Any uncommitted work in the workspace must be
  committed first, so the follow-up agent always starts from a clean tree.
- **No summarization.** The outgoing agent must not attempt to summarize the
  task, write a status report, or describe progress in the handoff message.
  The follow-up's initial message must be exactly
  `continue conversation <CONVERSATION_ID>`, where `<CONVERSATION_ID>` is the
  **current** conversation's UUID (dashes included).
- **The follow-up recovers context itself.** It reads the parent conversation's
  persisted events and workspace (see *Follow-up side* below). Nothing else is
  passed in the message.
- **Verify the follow-up started.** Monitoring is mandatory: the handover is
  not done until the follow-up conversation has started executing (a real agent
  event is present). Retry the start if it fails.
- **Never print secrets.** The session API key and any LLM key must stay in
  environment variables / command substitution. The scripts in this skill
  handle them without echoing.

## Workflow (outgoing agent)

All steps run from the workspace of the current conversation. Resolve the skill
directory once (the directory that contains this SKILL.md) and refer to it as
`SKILL_DIR`.

### 1. Detect the context threshold

Run:

```bash
python3 "$SKILL_DIR/scripts/context_check.py"
```

- It prints the context usage (prompt tokens vs. context window) and exits `0`
  when usage is **>= 90%**, or `3` when below threshold.
- It resolves the session API key automatically and never prints it.
- Exit `3` means: keep working normally; do nothing else from this skill.
- If the script cannot determine usage (unknown window, API unreachable), it
  exits `2` with a hint. Treat a direct user instruction ("hand over now") as
  the threshold being met; otherwise continue and re-check after the next
  heavy step.

### 2. Commit current progress

If `git status --porcelain` in the workspace is non-empty:

```bash
git add -A
git commit -m "WIP: checkpoint before context handover"
```

- Use the workspace's existing branch. Do not create branches, tags, or push.
- If the repository has **no commits at all**, the same `git add -A && git
  commit ...` creates the first commit — that is fine.
- If committing fails (e.g. not a git repository), proceed: the follow-up can
  still recover state from the workspace and the persisted events.

### 3. Start the follow-up conversation

Run the handover script in **dry-run** first to sanity-check the plan, then
for real:

```bash
python3 "$SKILL_DIR/scripts/handover.py" --dry-run     # prints the plan, touches nothing
python3 "$SKILL_DIR/scripts/handover.py"               # real handover
```

What the script does, in order:

1. Resolves the session API key (never printed).
2. Resolves its own conversation ID from the workspace directory name (the
   workspace path ends with the conversation UUID without dashes; the script
   converts it to the dashed form and cross-checks it against
   `GET /api/conversations`).
3. Builds the follow-up `POST /api/conversations` payload:
   - `agent_settings` copied from `GET /api/settings` with the
     **`X-Expose-Secrets: encrypted`** header, so the LLM key stays Fernet-
     encrypted end-to-end; `schema_version` and `mcp_config` are dropped to
     avoid MCP connection failures at creation time.
   - `secrets_encrypted: true` so the server decrypts the key server-side.
   - `agent_settings.tools` set to the current agent's exec tool set
     (terminal, file_editor, task_tracker, browser_tool_set, ...); the Canvas
     client tools (`canvas_ui_control`, `launch_child_conversation`) are
     delivered as full tool objects via the top-level `client_tools` field.
   - `agent_context.load_public_skills / load_user_skills /
     load_project_skills: true` so the follow-up inherits the user's skills,
     and the skill itself is copied into the fresh workspace at
     `.agents/skills/handover/` so the *Follow-up side* workflow is
     guaranteed to be loaded.
   - `autotitle: true`, `worktree: false`, `max_iterations` matched to the
     current conversation. (No `parent_conversation_id`: the server rejects
     lineage links when the workspaces differ, and the follow-up does not need
     the link — it derives the parent from the message text.)
   - `initial_message` is exactly
     `{"role": "user", "content": [{"type": "text", "text":
     "continue conversation <CONVERSATION_ID>"}], "run": true}`.
   - The follow-up workspace is a fresh sibling directory next to the current
     one.
4. POSTs the payload and records the new conversation ID.
5. **Monitors** the follow-up until verified started (see exit codes), polling
   every 10 s for up to ~10 minutes by default.
6. Prints the follow-up's UI/API links and the final `execution_status`.

### 4. Retry policy

Exit codes from `handover.py`:

| code | meaning                                                       | action |
|------|---------------------------------------------------------------|--------|
| `0`  | follow-up verified running (or idle with an agent event)      | report success, then finish |
| `2`  | configuration problem (key missing, API down, bad conversation) | fix the config, re-run once |
| `3`  | follow-up creation failed (HTTP error from POST)              | wait ~60 s, re-run; retry up to 3 times total |
| `4`  | follow-up created but never produced an agent event in time   | delete the dead follow-up (`scripts/handover.py --cleanup <id>`), re-run; retry up to 3 times total |

Total attempts (initial + retries) must not exceed **3**. After 3 failed
attempts, report the failure to the user with the error details from the
script's output and the UI link to the last created conversation — do not loop
endlessly.

### 5. Report and finish

On success:

- State in one short line that the task was handed to follow-up conversation
  `<id>` and that it is running, with the UI link
  (`http://localhost:8020/conversations/<id>`, or the port from the
  runtime-services block).
- Do **not** include a task summary, recap, or progress report. The only
  content about the task that may be shared is the follow-up conversation ID
  (already inside the handoff message) and its link.
- Finish the turn (e.g. via the `finish` tool) so the current conversation is
  closed cleanly.

## Follow-up side (what the fresh agent does)

The follow-up agent receives only `continue conversation <ID>`. It must be able
to act on that without any other input. Recovery works because the follow-up
shares the host with the parent (same agent-server, same persistence store,
same workspace tree):

1. **Locate the parent record.** The conversation store is
   `$OH_PERSISTENCE_DIR/openhands-state/dev_conversations/` (fall back to
   `~/.openhands/agent-canvas`-style state if `OH_PERSISTENCE_DIR` is unset).
   The directory name is the parent conversation ID **without dashes**:
   `PDIR="$STATE/dev_conversations/<ID-no-dashes>"`. Verify it exists.
   (Cross-check the ID via `GET /api/conversations/<ID>` with the session key
   from `~/.openhands/agent-canvas/api-key.txt` if in doubt.)
2. **Reconstruct the task.** Read, in order, from `PDIR`:
   - `TASKS.json` — the task tracker state (current objective and progress).
   - `meta.json` — the original user request and the parent workspace path.
   - `events/event-*.json` — the full event log. Sort by file name; read the
     **first** user message (the original task), then the **last ~20** events
     (latest progress). Do not dump the whole log into context; scan with
     `grep`/`jq`/python for the parts that matter (last actions, last assistant
     messages, open TODOs, file paths, test results).
3. **Restore the workspace.** The parent's workspace path comes from
   `meta.json` (or is reconstructible as `<workspace-root>/<ID-no-dashes>`).
   `cd` into it and run `git log --oneline -5` and `git status -sb` — the
   outgoing agent committed a "WIP: checkpoint before context handover"
   commit, so the tree should be clean. Continue from the last checkpoint.
4. **Continue the task** exactly as if the context window had simply
   refreshed. Pick up the next step implied by the last events. Do not ask the
   user to re-explain the task; if something is genuinely ambiguous, read more
   of the parent event log before asking.
5. If this follow-up itself later reaches 90% context, it may hand over again
   using the same workflow (its own conversation ID becomes the new parent).

## Scripts

- **`scripts/context_check.py`** — measure context usage of the current
  conversation; exit `0` when >= threshold (default 90%, `--threshold`),
  `3` when below, `2` on config/API errors.
- **`scripts/handover.py`** — commit-aware handover: commit pending work,
  build the payload, POST the follow-up conversation, monitor it until
  verified started, retry per the exit-code table above. Flags: `--dry-run`
  (no POST), `--no-commit` (skip the commit step), `--poll-every` /
  `--timeout` (monitoring), `--cleanup <id>` (delete a previously created
  follow-up conversation via `DELETE /api/conversations/<id>`).

## Additional Resources

- **`references/api-notes.md`** — verified Agent Canvas API specifics for this
  deployment: key resolution order, `X-Expose-Secrets: encrypted` semantics,
  payload fields, `execution_status` values, event-log schema, persistence
  layout, and troubleshooting notes. Read it when a handover fails or when
  adapting the scripts to another backend.
