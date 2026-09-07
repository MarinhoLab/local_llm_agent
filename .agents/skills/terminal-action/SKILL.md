---
name: terminal-action
description: >-
  How to call the terminal tool (TerminalAction) correctly in this OpenHands
  environment. Documents the exact allowed parameters, the frequent
  validation errors that waste turns (extra description/usage fields,
  multi-command chains), and how to recover when a command times out or the
  shell is left busy.
license: MIT
compatibility: OpenHands agent with the built-in terminal tool
triggers:
  - terminal
  - terminal action
  - terminalaction
  - run command
  - bash command
  - extra inputs not permitted
  - cannot execute multiple commands
---

The `terminal` tool runs shell commands in a persistent session. It is the most
commonly mis-called tool in this environment: mining ~30 past conversations
shows the single dominant failure is passing an extra `description` field
(~200 occurrences of `Extra inputs are not permitted ... description`). This
skill exists to stop those wasted turns.

## The exact allowed parameters

The tool accepts **only** these keys:

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `command` | string | yes | The shell command(s). Use `&&` or `;` to chain. |
| `summary` | string | no | ~10 words describing the action. This is where your "what am I doing" note goes. |
| `timeout` | number | no | Seconds. Raise for installs/tests; the default soft-timeout pauses after ~10s without new output. |
| `is_input` | boolean | no | `true` to send to a running process's stdin (empty string to poll, or a control token like `C-c`/`C-d`/`C-z`/`TAB`/`UP`). |
| `reset` | boolean | no | `true` to start a fresh shell (clears env, cwd, running procs). |
| `security_risk` | string | no | `UNKNOWN`/`LOW`/`MEDIUM`/`HIGH`. |

**The tool-call payload for `command`/`is_input`/`reset` must contain none of
`description`, `usage`, `command_2`, etc.** If you want to describe the step, put
that text in `summary` (a separate field), not in the command payload.

### The #1 mistake

Do NOT send this (it fails validation and does nothing):

```json
{ "command": "ls -la", "description": "List files" }
```

Send this instead:

```json
{ "command": "ls -la", "summary": "List files in current directory" }
```

The error you see when you get it wrong:

```
Error validating tool 'terminal': 1 validation error for TerminalAction
description
  Extra inputs are not permitted [type=extra_forbidden, ...]
Parameters provided: ['command', 'description']
```

Other observed extra-field variants (all the same class of bug): `usage`,
`syntax_risk`, `structure`, `description_placeholder`, and an accidental second
`command_2`. The rule is simple: **one `command` string, plus at most
`summary`/`timeout`/`is_input`/`reset`/`security_risk`.**

## One command per call

The runtime rejects multiple independent commands in a single call with:

```
Cannot execute multiple commands at once.
Please run each command separately OR chain them into a single command via && or ;
```

Two ways to trigger it:

- Passing `command` as a multi-line block the parser splits into several
  commands.
- Using a heredoc (`cat > f << 'EOF' ... EOF`) that the parser reads as a
  standalone command plus the following line.

Fix:

- **Chain** independent commands with `&&` (stop on first failure) or `;`
  (run regardless): `cd repo && python -m pip install -r requirements.txt`.
- For multi-line input (heredocs, here-docs, pasting a script), prefer writing
  the file with the file editor tool, or base64-encode it and decode in one
  line: `echo '<b64>' | base64 -d > /tmp/run.py && python3 /tmp/run.py`.
- If you truly need separate sequential steps, call the tool once per step.

## Long-running and interactive commands

- The soft timeout pauses after ~10s without new output. For installs, tests,
  or known-fixed durations, set `timeout` accordingly (e.g. `timeout: 600`).
- If a command hits the soft timeout it returns **exit code `-1`** and is still
  running. From then on, use `is_input: true` to:
  - send an **empty `command`** to poll for more logs, or
  - send a control token (`C-c` to interrupt, `C-d` for EOF, `C-z` to
    background, `C-up`/`TAB`/`ENTER`/`HOME`/`END` for navigation).
- For processes that must keep running (servers, watchers), start them in the
  background with a trailing `&` and redirect output:
  `python3 app.py > /tmp/app.log 2>&1 &`.

## State persistence

- The session is **persistent**: `cd`, `export FOO=bar`, `source venv/bin/activate`,
  and package installs carry over to the next call.
- Working directory persists too. Prefer absolute paths, but a `cd` in an earlier
  call remains in effect.
- Use `reset: true` only when the shell becomes unresponsive or you need a clean
  environment. It wipes env vars, cwd, and running background jobs.

## Quick checklist before each call

1. Payload has exactly one `command` string. No `description`/`usage`/extra keys.
2. "What am I doing?" text is in `summary`, not the command.
3. Independent steps are joined with `&&`/`;`, not stacked as separate lines.
4. Long commands set an explicit `timeout`; interactive waits use `is_input`.
