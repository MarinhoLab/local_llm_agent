---
name: opencode-subagents
description: >-
  Spawn "subagents" on the local Qwen model by driving the opencode_native
  server's HTTP API: one opencode session per task, scoped to a directory,
  run in parallel and read back as text. Covers bringing the server up with
  the right auth and auto-approve settings, the bundled oc.sh driver, and the
  pitfalls (hidden .env, 401s, per-directory session listing, and
  external_directory prompts that stall unattended runs even with
  OPENCODE_AUTO=yes and look like hung shell calls).
license: MIT
compatibility: opencode_native stack (opencode serve on http://127.0.0.1:4096, provider dgx-vllm/qwen-local via the vLLM tunnel on :8000)
triggers:
  - opencode subagent
  - spawn opencode
  - delegate to opencode
  - local llm subagent
  - qwen subagent
  - opencode server api
---

# opencode subagents

An agent outside opencode (Claude Code, a script, another orchestrator) can
hand work to the local model by talking to `opencode serve`. Each task becomes
an opencode **session**: it gets its own context, runs opencode's full tool
set (read, edit, shell…) in a chosen directory, and returns its final message.
Several sessions run concurrently on the one server.

Resolve the skill directory once (the directory containing this SKILL.md) and
refer to it as `SKILL_DIR`. All commands below assume the repository root as
the working directory.

## Hard rules

- **Never print the server password.** It lives in `opencode_native/.env`
  (mode 600). `scripts/oc.sh` reads it itself; do not `cat` the file, echo the
  variable, or read it out of the running server's `/proc/<pid>/environ` —
  that last one is credential exploration and agent guardrails rightly block
  it. If the password is unavailable, stop and ask the user.
- **Start the server only through `run.sh`.** Calling `opencode serve`
  directly skips the password, the generated config and the XDG isolation.
- **Unattended sessions need `OPENCODE_AUTO=yes`.** With `no` (the default)
  every edit/shell call waits for an approval in the web UI, and `oc.sh run`
  blocks until someone answers it. `yes` means the model runs shell **as the
  user with no sandbox** — only enable it when the user agrees, and scope
  every session to the narrowest directory that does the job.
- **`OPENCODE_AUTO=yes` does not cover files outside the session's
  directory.** Any tool call that reads, writes or `cd`s outside `<dir>`
  (`/tmp`, a helper script elsewhere, another checkout) raises an
  `external_directory` prompt and the session waits on it indefinitely. Keep
  everything a session needs inside `<dir>`, and tell it so in the brief
  (e.g. "write scratch files under `<dir>`, never `/tmp`").
- **Leave prompts to the user.** Answering a pending prompt widens what
  the model may do; that is the user's decision (web UI), not the calling
  agent's. Report the prompt and its patterns, and ask.

## 1. Bring the server up

```bash
./opencode_native/install.sh            # idempotent; creates .env + password if missing
grep -E '^OPENCODE_(AUTO|SERVER_PORT)=' opencode_native/.env
```

- `.env` is a dotfile — plain `ls` will not show it; use `ls -a`.
- `install.sh` never overwrites an existing `.env`. If
  `OPENCODE_SERVER_PASSWORD` is still `REPLACE_ME`, `run.sh server` refuses to
  start; generate one as its error message says.
- For unattended runs: `sed -i 's/^OPENCODE_AUTO=.*/OPENCODE_AUTO=yes/' opencode_native/.env`.
  The setting is read at startup, so **restart** the server after changing it.

Check whether a server is already running, and stop it if it must be
restarted (only with the user's OK — it may be serving their own sessions):

```bash
pgrep -af 'opencode serve'
kill <pid>
```

Start it in the background (it runs in the foreground otherwise) and wait for
it to answer:

```bash
./opencode_native/run.sh server &      # or your harness's background-run option
for i in $(seq 60); do [ "$("$SKILL_DIR/scripts/oc.sh" ping)" = 200 ] && break; sleep 1; done
"$SKILL_DIR/scripts/oc.sh" ping        # 200 = up and authenticated; 401 = wrong/missing password
```

The server dies with the shell that started it. For something long-lived,
have the user run `./opencode_native/run.sh server` in their own terminal.

## 2. Run subagents

```bash
"$SKILL_DIR/scripts/oc.sh" run <dir> "<title>" "<prompt>"
```

- Prints `session: <id>` on stderr, then the session's final text on stdout.
- `<dir>` scopes the session: tools resolve relative paths there and the
  session is filed under that project in the web UI.
- The call blocks until the turn ends (default timeout 3600 s, `OC_TIMEOUT`
  to change). Model defaults to `dgx-vllm/qwen-local`; override with
  `OC_PROVIDER` / `OC_MODEL`.

Parallel fan-out — background each run, capture output per task, then `wait`:

```bash
out=$(mktemp -d)
"$SKILL_DIR/scripts/oc.sh" run ~/git/proj "task A" "…" >"$out/a.txt" 2>&1 &
"$SKILL_DIR/scripts/oc.sh" run ~/git/proj "task B" "…" >"$out/b.txt" 2>&1 &
wait
for f in "$out"/*.txt; do echo "== $f"; cat "$f"; done
```

Write prompts as complete, self-contained briefs: the session has none of the
caller's context. Name the files, the expected result, and the reply format
(e.g. "reply with only the number"). Treat each reply as a report, not proof —
check the diff or files it claims to have changed.

Avoid two sessions editing the same files at once; nothing locks them. For
parallel work on one repository, give each session its own `git worktree`.

If a build or test needs software the host lacks, say so in the brief and
give the session a ready command (e.g. a Docker image plus a script **inside
`<dir>`**) rather than letting it hunt for it; a local model will otherwise
search the filesystem and the network at length.

## 3. A session that seems hung

A tool call shown as `running` for a long time with **no child process**
under `opencode serve` is almost always a permission prompt, not a hang:

```bash
"$SKILL_DIR/scripts/oc.sh" pending <dir>   # session | permission | patterns
grep 'message=asking' opencode_native/opencode-state/data/opencode/log/opencode.log | tail
pstree -p "$(pgrep -f 'opencode serve' | head -1)"   # threads only = no command running
```

- `external_directory` with a path pattern: the session touched a path
  outside its directory. Ask the user to approve it in the web UI, or abort
  and re-brief so the path is inside `<dir>`.
- `abort` stops the turn but **does not clear** its pending prompts; they
  stay listed until answered.

## 4. Housekeeping

```bash
"$SKILL_DIR/scripts/oc.sh" list <dir>      # id | title | directory
"$SKILL_DIR/scripts/oc.sh" abort <id>      # stop a runaway turn
"$SKILL_DIR/scripts/oc.sh" delete <id>     # remove test/finished sessions
```

Sessions (and prompts) are filed per directory: `list` and `pending` without
`<dir>` only show the server's own directory, so pass the directory you gave
`run`.

The user can watch and steer any session live in the web UI at
`http://localhost:4096` (same basic auth).

## API notes

The driver uses only these endpoints (basic auth `opencode:<password>`):

| Call | Purpose |
|---|---|
| `GET /config` | auth/health probe |
| `GET /config/providers` | providers/models the server knows |
| `POST /session?directory=<dir>` body `{"title":…}` | create session → `id` |
| `POST /session/<id>/message?directory=<dir>` body `{"model":{"providerID","modelID"},"parts":[{"type":"text","text":…}]}` | run one turn; returns the assistant message with `parts` |
| `GET /session?directory=<dir>` | list a directory's sessions |
| `GET /session/status?directory=<dir>` | which of them are `busy` |
| `GET /permission?directory=<dir>` | pending permission prompts |
| `POST /session/<id>/abort` | abort the running turn |
| `DELETE /session/<id>` | delete a session |

Verified against opencode 1.19.4 (2026-10-23): two concurrent sessions, one
using the shell tool and one reading a file, both completed without prompts
under `OPENCODE_AUTO=yes`. In a real two-worktree run the same day, one
session finished on its own, while the other stalled twice on
`external_directory` prompts (a `curl` into `/tmp`, then reading a helper
script under `/tmp`) that looked like hung shell calls.
