# Agent Canvas API notes (verified against this deployment, 2026-09)

Verified against a live Agent Canvas dev stack (agent-server on
`localhost:18000`, ingress on `localhost:8020`, frontend on `localhost:3001`)
and against the Canvas launcher code
(`@openhands/agent-canvas/dist/api/agent-server-adapter.js`).

## Session API key resolution order

1. `$SESSION_API_KEY`
2. `$OH_SESSION_API_KEYS_0`
3. `$LOCAL_BACKEND_API_KEY`
4. `~/.openhands/agent-canvas/api-key.txt` (one line, no trailing newline
   issues — read with `.strip()`)

Never print the key. Always pass it via the `X-Session-API-Key` header.

## Base URL resolution order

1. `$AGENT_CANVAS_BACKEND`
2. `$AGENT_SERVER_URL` (set in the agent sandbox, e.g. `http://127.0.0.1:18000`)
3. `$OH_AGENT_SERVER_URL`
4. default `http://localhost:18000`

The UI link for a conversation is
`http://localhost:$AGENT_CANVAS_PORT/conversations/<id>` (default port 8020,
the ingress; it proxies `/conversations/*` to the frontend).

## `GET /api/settings` — the encrypted-secrets header

Default responses **mask** every credential (`llm.api_key` comes back as the
literal string `"**********"`). Forwarding that placeholder makes the new
conversation fail immediately with `LLMAuthenticationError`.

Request with the `X-Expose-Secrets: encrypted` header and the response
carries the real `llm.api_key` as a **Fernet-encrypted token** (starts with
`gAAAAA`). Send the payload with `"secrets_encrypted": true` and the
agent-server decrypts it server-side. The token must never be printed or
persisted anywhere other than the POST body.

The encrypted `agent_settings` contains: `agent`, `agent_context`,
`agent_kind` (`"openhands"`), `condenser`, `enable_sub_agents`,
`enable_switch_llm_tool`, `llm`, `mcp_config`, `schema_version`,
`tool_concurrency_limit`, `tools`, `verification`.

Drop `schema_version` and `mcp_config` before forwarding:
- `schema_version` is a version pin that can reject the payload after
  upgrades.
- `mcp_config` (tavily/github MCP servers in this deployment) can fail to
  connect at conversation-creation time, failing the whole POST.

## Conversation identity from the workspace

A Canvas conversation's workspace is
`<workspace-root>/<conversation-id-without-dashes>` — a 32-char hex string
(the UUID without dashes). Example: conversation
`d8b4e610-77a1-4c2f-9e5a-1f3b5c7d9e0f` lives in
`.../workspace/project/d8b4e61077a14c2f9e5a1f3b5c7d9e0f`.

To find one's own id, search
`GET /api/conversations/search?limit=100` and match
`workspace.working_dir`. The API record also reports
`stats.usage_to_metrics.<profile>.accumulated_token_usage.{prompt_tokens,
context_window, per_turn_token}` — the current context size.

## POST `/api/conversations` payload (Canvas-shaped)

Field-by-field, as built by the Canvas adapter
(`buildCreateConversationPayload` in `agent-server-adapter.js`):

```jsonc
{
  "agent_settings": { /* encrypted settings agent_settings, minus
                        schema_version & mcp_config; agent.agent_context
                        with load_public_skills/load_user_skills/
                        load_project_skills = true */ },
  "secrets_encrypted": true,          // only when using encrypted settings
  "client_tools": ["canvas_ui_control", "launch_child_conversation"],
  "workspace": {"kind": "LocalWorkspace", "working_dir": "<fresh absolute dir>"},
  "confirmation_policy": {"kind": "NeverConfirm"},
  "security_analyzer": {"kind": "LLMSecurityAnalyzer"},  // copied from own record
  "max_iterations": 500,              // copied from own record
  "stuck_detection": true,
  "autotitle": true,
  "worktree": false,
  "initial_message": {
    "role": "user",
    "content": [{"type": "text", "text": "continue conversation <OWN_ID>"}],
    "run": true
  }
}
```

Notes:
- `client_tools` must be exactly the Canvas client tool list for the
  openhands agent kind; the server wires `canvas_ui_control` and
  `launch_child_conversation` into the follow-up agent (they show up in
  `agent.tools` with full spec blobs; no `tool_module_qualnames` entry is
  needed in this deployment).
- `parent_conversation_id` is accepted by the server **only when the follow-up
  workspace equals the parent workspace**. A cross-workspace handover must
  omit it, or the POST fails with 422 "Parent conversation ... belongs to a
  different workspace". The handover skill therefore omits it.
- `tool_module_qualnames` is only needed for non-standard tools; the Canvas
  client tools are built in, so omit it.
- The response JSON contains the new `id`, `title`, `execution_status`,
  `workspace`.

## Monitoring endpoints

- `GET /api/conversations/<id>` — record with `execution_status`,
  `agent.tools`, `stats`, `workspace`.
- `GET /api/conversations/<id>/events/search?limit=50` — returns
  `{items: [event, ...]}` (oldest first). Event shape: `id` (UUID),
  `timestamp`, `source` (`user` | `agent` | `environment` | `assistant`),
  `kind` (`MessageEvent`, `ActionEvent`, `ObservationEvent`,
  `ConversationStateUpdateEvent`, `ConversationErrorEvent`, ...).
  An `ActionEvent` with `source == "agent"` proves the agent actually began
  working.
- `DELETE /api/conversations/<id>` — deletes a conversation (HTTP 200 on
  success; 422/404 for unknown ids).
- `GET /server_info` — backend liveness check.

### `execution_status` values

`running`, `idle`, `finished`, `error`, `stuck`, `stopped`. A healthy
freshly-created conversation goes `running` → (agent event) → `idle`/
`running` as it works.

### "Verified started" definition

The handover is verified when the follow-up record has at least one
`ActionEvent` with `source == "agent"` **and** its `execution_status` is one
of `running`, `idle`, `finished`. `idle` with assistant activity also counts.
Error indicators (any `ConversationErrorEvent`/`ErrorEvent`, or an
`ObservationEvent` with `observation.is_error` and no agent activity yet)
mean the follow-up failed — report and retry.

## Conversation persistence on disk (what the follow-up reads)

Store root: `$OH_PERSISTENCE_DIR/openhands-state/dev_conversations/`
(`$OH_PERSISTENCE_DIR` unset → fall back to
`~/.openhands/agent-canvas`-style state under `$HOME`). Per conversation, the
directory name is the **dashed-less** conversation id:

```
dev_conversations/<id-no-dashes>/
├── meta.json        # original initial_message, workspace, client_tools,
│                    # secrets_encrypted, worktree, parent_conversation_id
├── base_state.json  # full agent state incl. llm (encrypted key), agent_context
├── TASKS.json       # task tracker state
└── events/
    └── event-NNNNN-<uuid>.json   # one event per file, sorted by NN prefix
```

The follow-up agent (running in the same host environment) reads these
directly with its terminal tool — no API key needed for this step. Scan the
event log with `grep`/`python3`; do not cat large logs into context.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Unauthorized` on any API call | wrong/missing session key | re-resolve key (order above) |
| `LLMAuthenticationError` in follow-up | masked key (`**********`) forwarded | use `X-Expose-Secrets: encrypted` + `secrets_encrypted: true` |
| POST fails with MCP connection error | `mcp_config` forwarded | drop `mcp_config` from `agent_settings` |
| POST `422` validation error | schema drift | drop `schema_version`, trim unknown keys, re-check adapter payload |
| follow-up created but stays `idle` with zero events for >5 min | agent start hung | `DELETE` the conversation, re-run handover |
| `context_window: 0` in stats | model provider doesn't report window | use the heuristic in `context_check.py` |
| workspace path not a 32-hex dir | not a Canvas conversation workspace | handover is only defined for Canvas conversations; abort |
