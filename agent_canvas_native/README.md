# Native Agent Canvas (no Docker)

Agent Canvas is OpenHands' self-hosted UI for running software agents. This
folder runs it **natively** on your machine — the UI, the agent-server, the
automation server, and the ingress proxy all start as local processes via
[Node.js](https://nodejs.org/) and [uv](https://docs.astral.sh/uv/).
There is **no Docker** involved.

This is the npm-based install path documented at
[OpenHands · Running Agent Canvas](https://docs.openhands.dev/openhands/usage/agent-canvas/setup).

## What's here

```
agent_canvas_native/
├── install.sh     # one-time setup: check prereqs, install the npm package,
│                  #   make the state dir, seed .env (with a random NTFY_TOPIC)
├── run.sh         # start the stack (UI + agent-server + automation + ingress)
├── bind_guard.py  # default path: publishes the UI on local addresses only
│                  #   only, keeping the launcher itself on loopback
├── ntfy_notifier.py  # optional push-notification daemon (started by run.sh)
├── example.env    # configuration template (copied to .env by install.sh)
└── openhands-state/   # agent-server state — git-ignored (created at first run)
```

## Prerequisites

| Dependency | Minimum | Check |
|---|---|---|
| [Node.js](https://nodejs.org/en/download) | 22.12 | `node --version` |
| npm | — | `npm --version` (ships with Node) |
| [uv](https://docs.astral.sh/uv/) | — | `uv --version` (the agent-server and automation backend run via `uvx`) |
| macOS / Linux | — | `uname -a` |

```bash
node --version   # needs v22.12 or newer
uv --version     # e.g. uv 0.12.x
```

`uv` is what the launcher uses to run the Python agent-server and automation
backend (the npm package bundles the UI + ingress only).

## Quick start

```bash
# 1. one-time setup (safe to re-run — it upgrades the npm package)
./agent_canvas_native/install.sh

# 2. start the stack
./agent_canvas_native/run.sh
```

`install.sh` always installs `@openhands/agent-canvas@latest` and then checks
that the `agent-canvas` first on `PATH` is that version — it exits with an
error listing every copy if an older one (e.g. under a different npm prefix)
shadows it. Re-run it to upgrade: each Agent Canvas release pins its own
agent-server / `openhands-sdk` version, so upgrading Agent Canvas is also how
the SDK gets upgraded.

When it's up, the launcher prints a summary. Open:

- **Agent Canvas**: <http://localhost:8020> — the chat UI.

There is no login: on first start the agent-server auto-generates an API key
and injects it into the UI (local mode). The key is persisted at
`~/.openhands/agent-canvas/api-key.txt` (see [State & where things
live](#state--where-things-live)), so it stays stable across restarts.

## Pointing it at your vLLM

The LLM is configured in the UI, not by environment variables:

1. Open **Settings** (top-right) → **LLM**.
2. Provider: **OpenAI-compatible** (the profile type for a local OpenAI-shaped
   endpoint).
3. **Base URL**: `http://localhost:8000/v1`
4. **API key**: the same one `run.sh` uses for its preflight check
   (`VLLM_API_KEY` in `.env`; `local-dgx-key` by default for a local tunnel).
5. **Model ID**: the model name vLLM is serving
   (e.g. `qwen-local`, the alias all three DGX stacks serve —
   `qwen38-27b-nvfp4`, `qwen38-27b-bf16`, and `flash_ultrafast`; see
   `dgx_spark_host/README.md`).
6. **Save** — it takes effect immediately for new conversations.

`run.sh` does a non-fatal preflight `curl` of the vLLM endpoint before launch.
If it can't reach it you'll see a hint with the SSH tunnel to start first —
the Canvas itself starts fine without the model; you just add the profile
once the tunnel is up. Start the tunnel with
`ssh -L 8000:localhost:8000 USER@DGX_SPARK_IP`.

## Ports

The internal ports (`18000`/`18001`) are **fixed** defaults and do *not* move
with the ingress port, so pick an ingress port that doesn't collide with the
repo's other stack (8000 vLLM):

| Service | Port (native default) | Notes |
|---|---|---|
| **Agent Canvas ingress** (UI + proxied API) | `8020` | the port you normally touch; by default this is the `bind_guard.py` front door, with `LAN_BIND=off` it is `--port` |
| launcher ingress, `LAN_BIND=on` (the default) | `8021` | `AGENT_CANVAS_PORT + 1`; the Agent Canvas launcher stays on `127.0.0.1` here — use `8020` |
| agent-server | `18000` | internal; proxied at `/api`, `/server_info`, etc. |
| automation server | `18001` | internal; proxied at `/api/automation` |
| **ntfy push server** (optional) | `2020` | only when `NTFY_ENABLED=true` + local ntfy (`../ntfy/compose.yml`); `NTFY_PORT` |
| **vLLM (SSH tunnel)** | `8000` | the model endpoint — a *separate* tunnel, not part of this stack |

Pick a different ingress port with `AGENT_CANVAS_PORT=8030 ./run.sh` (`run.sh`
checks both `PORT` and `PORT+1` first, since `LAN_BIND` is on by default). If
your machine is already using the internal ports (a second Canvas stack, or a
sandbox whose own Agent Canvas occupies `18000`/`18001`), override them in
`.env` via `OH_CANVAS_SAFE_BACKEND_PORT` / `OH_CANVAS_SAFE_AUTOMATION_PORT`
(see `example.env`).

## Reaching the UI from another machine

Out of the box (`LAN_BIND=on`) the stack answers on this machine's **local**
addresses, not just `localhost`. `run.sh` runs `bind_guard.py`, which keeps the
Agent Canvas launcher on loopback at `AGENT_CANVAS_PORT+1` and listens itself on
`AGENT_CANVAS_PORT` across loopback plus every interface address inside
`BIND_ALLOW_CIDRS` — by default loopback, `192.168/16` (home LAN) and
`100.64/10`, the range Tailscale hands out. Anywhere else binds nothing and
stays silent.

To go back to a loopback-only stack, set `LAN_BIND=off` in `.env` — `run.sh`
then `exec`s `agent-canvas` directly, with nothing listening off-loopback.

| What | Why it works out this way |
|---|---|
| `http://localhost:8020/` | as before, no login |
| `http://192.168.1.91:8020/`, `http://100.68.103.68:8020/` | the page still comes from the loopback launcher, so the session key is injected as usual — **no key to paste** |
| a public interface, another VLAN, a guest network | never bound; nothing answers |
| a page on the internet aiming at this machine | the `Host` check answers 403, so it cannot reach the API through a browser (DNS rebinding) |

Because it is a plain TCP pump, HTTP, SSE and WebSockets all pass through, and
`NTFY_DEEP_LINK_PREFIX=http://<this-pc>.tail:8020/conversations/` becomes
tappable from a phone on the tailnet.

**First run on a Mac with the application firewall on:** macOS asks whether to
let `python3` accept incoming connections — click **Allow** (see the firewall
gotcha below).

`--host 0.0.0.0` is *not* a shortcut to the same place: it publishes every
interface and, since the key is then withheld from the HTML, forces the API-key
screen even on the machine itself.

Two practical gotchas:

- **macOS application firewall.** It keys on the *path* of the binary and
  silently drops inbound connections for one it has not been told about — the
  bind succeeds and `localhost` keeps working, so the only symptom is a timeout
  from every other machine. macOS prompts on the first LAN bind; click **Allow**.
  A Homebrew or `uv` upgrade that changes the Python path can re-block you.
  `run.sh` warns when the firewall is on and its own `python3` is missing from
  the allow list; fix it with the two `socketfilterfw --add/--unblockapp`
  commands it prints.
- The guard forwards the browser's own `Host` header to the launcher. Canvas
  uses same-origin requests and the ingress sends the SPA for any path, so
  deep links like `/conversations/<id>` work; a bare IP `Host` needs no
  `BIND_ALLOW_HOSTS` entry, and a MagicDNS name does.

## State & where things live

Everything runs as your user, with the same filesystem access your account has
(there is no container boundary). Agent Canvas splits its data into three
places:

**1. The state dir** — per-conversation *runtime* data. Default
`./openhands-state`, resolved to inside this folder wherever you run `run.sh`
from; override with `AGENT_CANVAS_STATE=/some/abs/path`. The
launcher creates the subdirectories on first run:

```
openhands-state/
├── dev_conversations/ # conversation history
├── workspaces/        # per-conversation agent workspaces
├── bash_events/       # terminal command history
├── storage/           # blob storage (uploads, artifacts)
└── logs/              # server logs
```

`openhands-state/` is git-ignored. (A `tmux/` socket dir is added here too when
agents open terminals.)

**2. `~/.openhands/agent-canvas/`** — the credentials. The launcher auto-generates
and pins the **session API key** (`api-key.txt`, used as `X-Session-API-Key`)
and the **encryption secret key** (`secret-key.txt`) here. They live in `$HOME`
deliberately, *independent of the state dir*, so they stay stable across
restarts. To rotate a key, delete that file (and restart). Set
`LOCAL_BACKEND_API_KEY` to pin the API key explicitly instead.

**3. `~/.openhands/`** — your saved **LLM profile and agent settings**:
`settings.json`, `secrets.json`, and `profiles/` (e.g. the `qwen-local` profile
you add in Settings → LLM). These live in `$HOME` regardless of the state dir.

So: conversations and workspaces follow `AGENT_CANVAS_STATE`; the API key,
encryption key, and your LLM profile live in `~/.openhands`.

## Working with your files

There is **no fixed `/projects` mount**: agents run as your user with the same
filesystem access your account has (there is no container boundary). When you
create a conversation you just pick a host path to work in (a checked-out
repo, a new folder, etc.) and the agent edits it in place with your
permissions.

## Notifications (ntfy)

Get a push notification on your phone when your agent finishes a turn, is
waiting for your input, hits an error, or gets stuck. Implemented by a small
stdlib-only daemon, `ntfy_notifier.py`, that polls the local agent-server and
publishes to [ntfy](https://ntfy.sh) on status transitions — no SDK, no venv.

This stack is designed for **multiple PCs, each on Tailscale, each running its
own ntfy server** (see [`../ntfy/`](../ntfy/)). One notifier per PC; each
notifier only ever talks to its local ntfy server and its local agent-server.

### What triggers a notification

| Conversation status | Notification | Priority |
|---|---|---|
| `idle` | finished a turn — needs your input 👀 | 3 (default) |
| `finished` | conversation completed ✅ | 3 |
| `waiting_for_confirmation` | waiting for your confirmation 🚦 | 4 (high) |
| `stuck` | stuck detection fired 🐌 | 4 |
| `error` | hit an error 🚨 | 5 (max) |

Only transitions notify (not every poll), with a per-conversation cooldown
(default 120 s) so a conversation flapping between statuses can't spam you.
Each notification carries a **tap-to-open deep link** to the conversation:
`http://<this-pc>.tail:8020/conversations/<id>`.

### Setup (per PC)

1. **ntfy server** — one-time, per PC (see [`../ntfy/README.md`](../ntfy/README.md)):
   ```bash
   cd ntfy && cp example.env .env
   # edit .env: NTFY_BASE_URL=http://<this-pc>.tail:2020
   docker compose up -d
   ```
   No account auth needed by default — the unguessable topic name is the
   credential (Tailscale reachability + random topic = your protection).
2. **Notifier config** — in `agent_canvas_native/.env`:
   ```bash
   NTFY_ENABLED=true
   NTFY_SERVER=http://127.0.0.1:2020        # this PC's local ntfy
   NTFY_TOPIC=agent-canvas-<unguessable>     # e.g. agent-canvas-3f9a1c7e
   NTFY_HOSTNAME=mac                          # your Tailscale name
   NTFY_DEEP_LINK_PREFIX=http://mac.tail:8020/conversations/
   # NTFY_AUTH_TOKEN=tk_...                   # only if you enabled account auth
   ```
3. **Phone** — in the ntfy app, subscribe to
   `http://<this-pc>.tail:2020/<NTFY_TOPIC>` (repeat for each PC).
4. **Run** — `./agent_canvas_native/run.sh` starts the notifier automatically
   (and the local ntfy server, if Docker is available). Its log lives at
   `openhands-state/logs/ntfy.log`.

Using the public **ntfy.sh** instead of a local server? Set
`NTFY_SERVER=https://ntfy.sh`, leave `NTFY_AUTH_TOKEN` empty, and use a long
unguessable `NTFY_TOPIC` (the topic name is the password). The deep-link
prefix still needs a reachable URL for tap-to-open.

### Notes

- The notifier reads the session API key from the launcher (env or
  `~/.openhands/agent-canvas/api-key.txt`) and uses it only for its own
  agent-server calls — it is **never** written into ntfy messages.
- To send a test notification without a state change, run the notifier once
  with `NTFY_DRY_RUN=true` to see exactly what it would publish, or trigger
  `NTFY_EVENTS=idle,finished,error,stuck,waiting_for_confirmation,paused` and
  toggle a conversation's status in the UI.
- To stop the notifier: `pkill -f ntfy_notifier.py` (the agent-server is
  unaffected).
- Push reliability: Android gets instant delivery out of the box (foreground
  service); iOS uses the ntfy.sh relay configured in `../ntfy/compose.yml`.
  Details and the Firebase/custom-APK caveat are in [`../ntfy/README.md`](../ntfy/README.md).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `npm install -g` fails with `EACCES` | The global npm prefix isn't writable. `install.sh` falls back to a per-user prefix (`~/.npm-global`) automatically; if you hit it manually, run `npm config set prefix ~/.npm-global` and `export PATH="$HOME/.npm-global/bin:$PATH"`. |
| `ERROR: 'agent-canvas' not found` | The binary isn't on `PATH`. Add your npm global bin dir: `echo "$(npm prefix -g)/bin"`. `install.sh` and `run.sh` both add `~/.npm-global/bin` if they find it there. |
| `port ... is already in use` | The ingress **or** an internal port is taken. Move the ingress (`AGENT_CANVAS_PORT=...`) and/or the internal ports (`OH_CANVAS_SAFE_BACKEND_PORT` / `OH_CANVAS_SAFE_AUTOMATION_PORT`). A second Agent Canvas — including a sandbox's own — occupies the internal ports. With the default `LAN_BIND=on`, both `AGENT_CANVAS_PORT` and `+1` must be free. |
| localhost works, every other machine times out | Usually the macOS application firewall dropping inbound connections for `python3` (run.sh prints the `socketfilterfw` commands when it detects this). Otherwise check the guard's log (`openhands-state/logs/bind_guard.log`) for which addresses it bound — an address outside `BIND_ALLOW_CIDRS` is deliberately not listening. |
| The browser shows the API-key screen | The request reached the launcher directly on `AGENT_CANVAS_PORT+1`, bypassing the guard. Use the published port. |
| `Node.js ... is too old` | Install Node ≥ 22.12. |
| UI loads but the model "doesn't work" | The LLM profile isn't set or the vLLM tunnel is down. Set Settings → LLM and confirm `curl http://localhost:8000/v1/models` works. |
| `uvx` not found when launching | `uv` isn't on `PATH`. Install it and open a new terminal. |
| Notifier: `waiting for agent-server session API key...` loops | The Canvas hasn't started yet or the key file was removed. Wait for the stack to come up, or set `LOCAL_BACKEND_API_KEY` in `.env`. Log: `openhands-state/logs/ntfy.log`. |
| Notifier: `WARN: ntfy publish failed HTTP 401/403` | Only when you enabled account auth (`NTFY_AUTH_FILE`): `NTFY_AUTH_TOKEN` missing/wrong, or the token lacks write access. Re-create it (`../ntfy/README.md` → *Authentication*). |
| ntfy container exits and logs show the CLI help | The `serve` subcommand is missing. `compose.yml` sets `command: serve`; if you ran the image directly, add `serve` after the image name. |
| Phone gets no notifications | Check the ntfy server is healthy (`docker compose ps`), the topic matches exactly, and (Android) instant delivery is on. Deep links need the phone on Tailscale and port `8020` reachable. |

## Uninstall

```bash
npm uninstall -g @openhands/agent-canvas     # removes the npm package
rm -rf ./openhands-state                     # removes the stack's state (optional)
```
