# Native OpenCode (no Docker)

[OpenCode](https://opencode.ai) is a terminal coding agent (TUI + web UI +
HTTP API). This folder runs it **natively** as the alternative macOS-side
client to [`../agent_canvas_native/`](../agent_canvas_native/): same DGX
Spark vLLM endpoint, same SSH tunnel, same ntfy notifications — a different
front end. There is **no Docker** involved and **no Node.js required**
(opencode ships as a single self-contained binary).

Agents run as **your user on the local filesystem** — same caveat as the
Canvas stack: there is no sandbox, so the edit/shell approval prompt is the
safety net (kept on by default, see [Permissions](#permissions)).

## Why this exists next to Agent Canvas

| | `agent_canvas_native/` | `opencode_native/` |
|---|---|---|
| Front end | Web UI (browser) + REST API | TUI (terminal), plus web UI + REST API in server mode |
| Runtime | Node.js ≥ 22.12 + uv + Python 3.14 | one binary (`~/.opencode/bin/opencode`) |
| Model config | Settings → LLM in the UI | generated `opencode.json` (no provider UI exists) |
| State | `openhands-state/` + `~/.openhands` | fully inside `opencode-state/` (XDG-isolated) |
| Notifications | `ntfy_notifier.py` (agent-server API) | `ntfy_notifier.py` (opencode server API) |

Both point at `http://localhost:8000/v1` serving `qwen-local`, so you can run
either without touching the DGX side.

## What's here

```
opencode_native/
├── install.sh             # one-time setup: install/upgrade the binary, create
│                          #   the isolated state tree, generate the config and
│                          #   .env (random server password + NTFY_TOPIC)
├── run.sh                 # start the stack (TUI | server | attach | run)
├── lib_stack.sh           # shared env/path/preflight helpers (sourced)
├── ntfy_notifier.py       # optional push-notification daemon (started by run.sh)
├── opencode.example.jsonc # config template → opencode-state/config/opencode.json
├── example.env            # configuration template (copied to .env by install.sh)
└── opencode-state/        # config copy, sessions, DB, logs — git-ignored
```

## Prerequisites

| Dependency | Minimum | Check | Notes |
|---|---|---|---|
| macOS / Linux | — | `uname -a` | bash 3.2 (macOS stock) is enough |
| curl, git | — | `curl --version` | git is used for opencode's snapshots |
| [opencode](https://opencode.ai) | validated on 1.18.30 | `opencode --version` | `install.sh` installs it if missing |
| Python 3 | any recent 3 | `python3 --version` | only for the optional ntfy notifier |
| Docker | — | `docker ps` | only for the local ntfy server in `../ntfy/` |

**Node.js is not required.** The binary bundles its own JS runtime. Node/npm
become relevant only if you install OpenCode *plugins*, which opencode
materialises into `opencode-state/xdg-config/opencode/node_modules` with
`npm` (a ~60 MB install) — for plain agent use there are none. The one thing
that does need a real terminal is the TUI: WezTerm, Alacritty, Ghostty, Kitty
or iTerm2 (`run.sh server` works anywhere).

## Quick start

```bash
# 0. tunnel to the DGX (same one the Canvas uses)
ssh -N -L 8000:localhost:8000 USER@DGX_SPARK_IP

# 1. one-time setup (safe to re-run — it upgrades the binary)
./opencode_native/install.sh

# 2. code
./opencode_native/run.sh                 # TUI in the current directory
./opencode_native/run.sh /path/to/repo   # TUI on a project
```

There is no login screen: `run.sh` wires everything through
`.env` + the generated config. If `install.sh` could not reach the tunnel it
says so and continues — the TUI starts fine, turns just fail until the
tunnel is up.

## Pointing it at your vLLM

Unlike the Canvas, OpenCode has **no UI for adding a provider** — the profile
lives in a config file, which `install.sh` generates from
`opencode.example.jsonc`:

- provider `dgx-vllm` → `@ai-sdk/openai-compatible` against
  `{env:OPENCODE_DGX_BASE_URL}` / `{env:OPENCODE_DGX_API_KEY}`, which `run.sh`
  exports from `VLLM_BASE_URL` / `VLLM_API_KEY` in `.env` — the same two knobs
  `agent_canvas_native/example.env` uses;
- model `dgx-vllm/qwen-local` (also used as `small_model`, since the DGX
  serves one model), declared `reasoning` + `tool_call` with
  `limit.context: 262144` to match the checkpoint (see `../AGENTS.md`);
- request `timeout`/`headerTimeout`/`chunkTimeout` disabled — long local
  agent turns must not be aborted mid-thought;
- `permission.edit`/`shell` = `ask`.

**No secret lives in the file** — the key is substituted from the environment
at launch, which is also why you always launch through `run.sh`. To customise
(temperature, extra providers, agents): edit
`opencode-state/config/opencode.json`, or set `OPENCODE_CONFIG` in `.env` to
your own file. `install.sh` never overwrites an edited copy.

## Modes

```bash
./run.sh [dir]         # TUI (default) — mirrors `opencode [project]`
./run.sh server        # headless HTTP API + web UI on OPENCODE_SERVER_PORT
./run.sh web [dir]     # server + published on the tailnet (tailscale serve)
./run.sh web-off       # undo the tailnet publishing
./run.sh attach [dir]  # TUI connected to that server
./run.sh run "prompt"  # non-interactive one-shot (model from the profile)
./run.sh upgrade       # re-run install.sh
```

`server` prints the URLs:

```
web UI      : http://localhost:4096/
API         : http://localhost:4096/doc  (basic auth: opencode)
```

- **Web UI** — the same single-page app the desktop app wraps. On a first
  visit it asks you to **Add server**: *Server address*
  `http://localhost:4096`, *Username* `opencode`
  (`OPENCODE_SERVER_USERNAME`), *Password* = `OPENCODE_SERVER_PASSWORD`
  from `.env`. It remembers the server per browser afterwards.
- **`attach`** reuses that server from a second terminal, so the phone-friendly
  web UI and a terminal TUI can watch the same sessions. Note `attach` has no
  `--auto` flag; the permission posture comes from `OPENCODE_PERMISSION`
  (see [Permissions](#permissions)).
- **Re-running `run.sh server` while a server is up** attaches the TUI to the
  existing server instead of failing on the port.

### Remote access

Two supported ways to reach the web UI from another machine or your phone.
Both keep the server on `127.0.0.1` — with `OPENCODE_AUTO=yes` it runs shell
as you, so treat a wider bind as handing out a shell credential.

1. **`./run.sh web`** — publishes the loopback server on your **tailnet** via
   `tailscale serve` (Tailscale proxies to `localhost` from inside its own
   signed process). Any device on your tailnet opens
   `http://<pc>.<tailnet>.ts.net:4096/` and authenticates with
   `opencode` / `OPENCODE_SERVER_PASSWORD`. Undo with `./run.sh web-off`.
   Requires Tailscale installed and **Serve enabled** for the node — if it is
   not, `run.sh web` says so and still starts the local server, printing the
   enable URL.
   Why not just `OPENCODE_BIND_HOST=<tailscale-ip>`? macOS's application
   firewall silently drops inbound connections to the *ad-hoc-signed* opencode
   binary on every non-loopback interface, so the bind succeeds but nothing
   can connect (a signed relay binary reaches it fine, which is how this was
   diagnosed). Tailscale's process is firewall-allowed, so the proxy path
   works without touching the firewall. If you'd rather allow-list opencode
   itself, that's an admin decision:
   `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add ~/.opencode/bin/opencode`
   followed by `--unblockapp` on the same path, then bind `0.0.0.0`.
2. **SSH tunnel** (no Tailscale needed) — `ssh -L 4096:localhost:4096 host`,
   then browse `http://localhost:4096` as if local. Same pattern as the vLLM
   tunnel.

In both cases the web UI's **Add server** dialog wants the URL exactly as the
browser reaches it (`http://localhost:4096` over a tunnel,
`http://<pc>.<tailnet>.ts.net:4096` on the tailnet), and phone deep links need
`NTFY_DEEP_LINK_BASE` set to that same URL (see [Deep links](#deep-links)).

## Permissions

Agents edit files and run shell **as you**, so approvals are on by default
(`ask` before `edit`/`shell`, mirroring the Canvas's confirmation flow).
`OPENCODE_AUTO=yes` in `.env` switches to auto-approve — `run.sh` then passes
`--auto` to the TUI/`run`, and exports `OPENCODE_PERMISSION` (the JSON
`serve`/`attach` have no `--auto` flag, so the env override is what makes
server mode unattended). Use it only where the prompt is pure friction, e.g.
a throwaway checkout.

An approval is two steps for paths outside the project: first `external_directory`
(“may this project touch /tmp/x at all?”), then `edit` with the diff. Both are
pending requests on the server, so the notifier's 🚦 notification and the web
UI's prompt screen are the intended way to unblock a headless session.

## State & where things live

Everything is inside `opencode-state/` (git-ignored) — nothing is written to
`~/.config/opencode` or `~/.local/share/opencode`, so this stack, its
notifier, and any personal OpenCode install stay fully separated. `run.sh`
achieves it by exporting `XDG_CONFIG_HOME` / `XDG_DATA_HOME` / `XDG_CACHE_HOME`
plus `OPENCODE_CONFIG` / `OPENCODE_CONFIG_DIR` before exec'ing the binary.

```
opencode-state/
├── config/opencode.json      # generated config copy (mode 600)
├── config/opencode-dir/      # OPENCODE_CONFIG_DIR: your agents/, commands/,
│                             #   skills/, plugins/, opencode.json for this stack
├── data/opencode/            # XDG_DATA_HOME: opencode.db (sessions), snapshot/,
│                             #   repos/, log/
├── xdg-config/opencode/      # XDG_CONFIG_HOME: plugin node_modules (only if
│                             #   you install plugins)
├── cache/opencode/           # XDG_CACHE_HOME: models.json cache, LSP binaries
├── logs/ntfy.log             # notifier log
└── ntfy_notifier_state.json  # notifier's last-seen statuses
```

Per-project overrides go in the project's own `opencode.json`;
stack-wide custom agents/commands/skills go in `config/opencode-dir/`.
Uninstall: `rm -rf ./opencode-state` plus `rm ~/.opencode/bin/opencode`
(or `npm uninstall -g opencode-ai`).

## Notifications (ntfy)

Same design as [`../agent_canvas_native/`](../agent_canvas_native/README.md):
one stdlib-only daemon per PC, publishing to the local ntfy server from
[`../ntfy/`](../ntfy/). It polls the **opencode server** every
`NTFY_POLL_SECONDS` and publishes on status transitions. Run it in
**server mode** — the TUI spawns a private server on a random port, which the
notifier cannot watch.

### What triggers a notification

| Session status | Notification | Priority |
|---|---|---|
| `finished` | finished a turn — needs your input 👀 | 3 (default) |
| `waiting_for_input` | waiting for your approval (permission / question) 🚦 | 4 (high) |
| `error` | hit an error 🚨 | 5 (max) |
| `retrying` | the endpoint is failing, opencode is backing off 🔁 | 2 (low; add to `NTFY_EVENTS`) |
| `running` / `idle` | started running / went idle 🚀💤 | 2 (opt-in) |

`finished`, `error` and `waiting_for_input` are on by default. OpenCode
reports only “busy” per session, so the rest is derived from its primitives:
pending `/permission` + `/question` entries, the `/session/status` retry
entries, and the error/text of the last assistant message. Only transitions
notify, with a per-session cooldown (`NTFY_COOLDOWN_SECONDS`, default 120 s).

### Setup (per PC)

1. **ntfy server** — one-time, per PC ([`../ntfy/README.md`](../ntfy/README.md)):
   ```bash
   cd ntfy && cp example.env .env
   # edit .env: NTFY_BASE_URL=http://<this-pc>.tail:2020
   docker compose up -d
   ```
2. **Notifier config** — in `opencode_native/.env` (`install.sh` already put a
   random topic in):
   ```bash
   NTFY_ENABLED=true
   NTFY_SERVER=http://127.0.0.1:2020         # this PC's local ntfy
   NTFY_TOPIC=opencode-<unguessable>          # generated by install.sh
   NTFY_HOSTNAME=mac                          # your Tailscale name
   NTFY_DEEP_LINK_BASE=http://mac.tail:4096   # tap-to-open base (see below)
   # NTFY_AUTH_TOKEN=tk_...                   # only if you enabled account auth
   ```
3. **Phone** — subscribe to `http://<this-pc>.tail:2020/<NTFY_TOPIC>`; open the
   web UI once at `http://<this-pc>.tail:4096/` and enter
   `http://<this-pc>.tail:4096` as the server address, so taps land on a server
   the browser knows.
4. **Run** — `./opencode_native/run.sh server` starts the notifier (and the
   local ntfy server, if Docker is available). Log:
   `opencode-state/logs/ntfy.log`.

### Deep links

Taps open the session page in the web UI. Its route is
`/server/<serverKey>/session/<id>`, where `serverKey` is the **base64url of the
exact server URL the browser saved** — so the notifier derives it from
`NTFY_DEEP_LINK_BASE` (default `http://localhost:4096`) rather than having you
hand-encode it. If taps open a “server not found” screen, your browser saved
the server under a different host string: set `NTFY_DEEP_LINK_BASE` to that
string (and open the UI through it once). `NTFY_DEEP_LINK_PREFIX` is the
escape hatch — a literal prefix with the session id appended, used instead of
`BASE` when set.

### Notes

- The notifier reads the basic-auth password from the environment
  (`OPENCODE_SERVER_PASSWORD`, which `run.sh` exports) and uses it only for its
  own calls — it is **never** written into ntfy messages, and publish failures
  log only the status code (the body could echo the header back).
- Test the pipeline without a real state change: run the notifier once with
  `NTFY_DRY_RUN=true` (publishes nothing, writes no state), or send it
  `SIGUSR1` to force-publish current statuses.
- Stop it: `pkill -f 'opencode_native/ntfy_notifier.py'` (the server is
  unaffected).
- Using public **ntfy.sh** instead? `NTFY_SERVER=https://ntfy.sh`, empty
  `NTFY_AUTH_TOKEN`, long unguessable `NTFY_TOPIC`. Deep links still need a
  URL your phone can reach.
- Push reliability (Android instant delivery / iOS relay) is documented in
  [`../ntfy/README.md`](../ntfy/README.md).

## Working with your files

Like the Canvas, this stack has **no container sandbox**: the agent edits the
checkout you launch it in, as you. Use it on a git repository (opencode
snapshots changes with git and can undo a turn), and keep the default `ask`
permissions unless the tree is disposable. `OPENCODE_DISABLE_AUTO_SHARE=true`
(`run.sh` default) keeps sessions from being published to any share service.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ERROR: 'opencode' not found` | Not installed or not on `PATH`. Its installer uses `~/.opencode/bin` — `run.sh` adds it for its own use; for your shell: `export PATH="$HOME/.opencode/bin:$PATH"`, or re-run `install.sh`. |
| `ERROR: no config at .../config/opencode.json` | You ran `run.sh` before `install.sh`, or deleted the state dir. `./opencode_native/install.sh`. |
| Turns fail instantly, `Cannot connect to API` | The vLLM tunnel is down — the notifier shows this as 🔁 *retrying* if enabled. Start it: `ssh -N -L 8000:localhost:8000 USER@DGX_SPARK_IP`, then confirm `curl http://localhost:8000/v1/models` answers. |
| `... does not serve 'qwen-local'` | Wrong stack or wrong alias. Check `curl -H 'Authorization: Bearer local-dgx-key' http://localhost:8000/v1/models` and fix `VLLM_MODEL_ID` in `.env`. |
| TUI looks broken / no colours | `TERM=dumb` (e.g. from a script or tmux misconfig). Use a modern terminal emulator; `run.sh server` + web UI works regardless. |
| `server mode needs a real OPENCODE_SERVER_PASSWORD` | `run.sh` refuses to bind a shell-capable port unauthenticated. Re-run `install.sh` on a fresh `.env`, or: `python3 -c 'import secrets;print("OPENCODE_SERVER_PASSWORD="+secrets.token_urlsafe(24))' >> opencode_native/.env` |
| `port 4096 is already in use by something else` | Not this stack's server (that case attaches). Move it: `OPENCODE_SERVER_PORT=5000 ./opencode_native/run.sh server`. Taken: 8000 (vLLM), 8020 (Canvas), 18000/18001 (Canvas internals), 2020 (ntfy). |
| Web UI asks for a server address / “Could not connect to server” | Expected on first use: enter `http://localhost:4096`, then the basic-auth password. If it fails, the server isn't running or the port differs. |
| `attach` says no server answering | Start one in another terminal: `./opencode_native/run.sh server`. `attach` needs the server on `OPENCODE_SERVER_PORT`, with `--password` matching `.env` (both are handled for you when you go through `run.sh`). |
| Notifications never arrive | The notifier only watches **server mode**. Check `opencode-state/logs/ntfy.log`: `waiting for the opencode server` → server down; `publish failed HTTP 401/403` → `NTFY_AUTH_TOKEN` wrong (only with account auth); nothing logged → `NTFY_ENABLED` isn't `true`. |
| Taps open “server not found” | `NTFY_DEEP_LINK_BASE` doesn't match the host string the browser saved — see [Deep links](#deep-links). |
| Phone gets nothing | ntfy container unhealthy (`docker compose ps` in `ntfy/`), topic mismatch, or (Android) instant delivery off. |
| Sessions from a previous run are gone | You pointed `OPENCODE_STATE_DIR` somewhere else, or deleted the state dir. Sessions live in `opencode-state/data/opencode/opencode.db`. |
| Two OpenCode stacks fight | They don't, by design: each keeps its own `opencode-state/`. Only ports can collide — give one another `OPENCODE_SERVER_PORT`. |
