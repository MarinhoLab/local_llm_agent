# Native Agent Canvas (no Docker)

Agent Canvas is OpenHands' self-hosted UI for running software agents. This
folder runs it **natively** on your machine — the UI, the agent-server, the
automation server, and the ingress proxy all start as local processes via
[Node.js](https://nodejs.org/) and [uv](https://docs.astral.sh/uv/).
There is **no Docker** involved.

This is the npm-based install path documented at
[OpenHands · Running Agent Canvas](https://docs.openhands.dev/openhands/usage/agent-canvas/setup).
It is the equivalent of the [`agent_canvas/`](../agent_canvas/) Docker stack
([OpenHands · Running Agent Canvas with Docker](https://docs.openhands.dev/openhands/usage/agent-canvas/setup#running-agent-canvas-with-docker)),
just without the container boundary.

## What's here

```
agent_canvas_native/
├── install.sh     # one-time setup: check prereqs, install the npm package,
│                  #   make the state dir, seed .env
├── run.sh         # start the stack (UI + agent-server + automation + ingress)
├── example.env    # configuration template (copied to .env by install.sh)
└── openhands-state/   # agent-server state — git-ignored (created at first run)
```

> **Why a separate folder?** `agent_canvas/` runs the same stack as a Docker
> Compose deployment on a port-8010 tunnel. `agent_canvas_native/` runs it as a
> local process. You can run **both** side by side — they only collide if they
> share a port or a state dir.

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
   (e.g. `Qwen/Qwen3.8-27B-FP8`, or the `qwen-local` alias the stack serves).
6. **Save** — it takes effect immediately for new conversations.

`run.sh` does a non-fatal preflight `curl` of the vLLM endpoint before launch.
If it can't reach it you'll see a hint with the SSH tunnel to start first —
the Canvas itself starts fine without the model; you just add the profile
once the tunnel is up. See the [`agent_canvas/` section of the repo
README](../README.md) for the tunnel command and model selection.

## Ports

The internal ports (`18000`/`18001`) are **fixed** defaults and do *not* move
with the ingress port, so pick an ingress port that doesn't collide with the
repo's other stacks (8000 vLLM, 8010 Docker Canvas):

| Service | Port (native default) | Notes |
|---|---|---|
| **Agent Canvas ingress** (UI + proxied API) | `8020` | the only port you normally touch; `run.sh` passes it as `--port` |
| agent-server | `18000` | internal; proxied at `/api`, `/server_info`, etc. |
| automation server | `18001` | internal; proxied at `/api/automation` |
| **vLLM (SSH tunnel)** | `8000` | the model endpoint — a *separate* tunnel, not part of this stack |
| Docker Agent Canvas | `8010` | the *other* stack in `agent_canvas/` — left alone |

Pick a different ingress port with `AGENT_CANVAS_PORT=8030 ./run.sh`. If your
machine is already using the internal ports (a second Canvas stack, or a
sandbox whose own Agent Canvas occupies `18000`/`18001`), override them in
`.env` via `OH_CANVAS_SAFE_BACKEND_PORT` / `OH_CANVAS_SAFE_AUTOMATION_PORT`
(see `example.env`).

## State & where things live

Everything runs as your user, with the same filesystem access your account has
(there is no container boundary). Agent Canvas splits its data into three
places:

**1. The state dir** — per-conversation *runtime* data. Default `./openhands-state`
next to this folder; override with `AGENT_CANVAS_STATE=/some/abs/path`. The
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
restarts and so the Docker and native stacks share the same keys when both use
`~/.openhands`. To rotate a key, delete that file (and restart). Set
`LOCAL_BACKEND_API_KEY` to pin the API key explicitly instead.

**3. `~/.openhands/`** — your saved **LLM profile and agent settings**:
`settings.json`, `secrets.json`, and `profiles/` (e.g. the `qwen-local` profile
you add in Settings → LLM). These live in `$HOME` regardless of the state dir.

So: conversations and workspaces follow `AGENT_CANVAS_STATE`; the API key,
encryption key, and your LLM profile live in `~/.openhands`.

One difference from the Docker stack: there is **no fixed `/projects` mount**.
In Docker mode a host `projects/` dir is bind-mounted to `/projects` and agents
start there by default. Native mode has no such mount — when you create a
conversation you just pick a host path to work in (a checked-out repo, a new
folder, etc.) and the agent edits it in place with your user's permissions.

## Comparison with the Docker stack

| | `agent_canvas/` (Docker) | `agent_canvas_native/` (this) |
|---|---|---|
| Runs on | Docker Desktop | Node.js + uv, local process |
| Port | `8010` (tunnel) | `8020` (local) |
| Requires | Docker + the image built | Node ≥ 22.12 + uv |
| Filesystem | agents are sandboxed in the container | agents run as your user, full local FS |
| State | `~/.openhands/agent-canvas` (volume-mounted) | `./openhands-state` |
| Setup | `docker compose build && up` | `./install.sh` then `./run.sh` |

Use the Docker stack when you want the agent sandboxed; use this native one
when you want zero Docker overhead, or to develop against the local
environment directly.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `npm install -g` fails with `EACCES` | The global npm prefix isn't writable. `install.sh` falls back to a per-user prefix (`~/.npm-global`) automatically; if you hit it manually, run `npm config set prefix ~/.npm-global` and `export PATH="$HOME/.npm-global/bin:$PATH"`. |
| `ERROR: 'agent-canvas' not found` | The binary isn't on `PATH`. Add your npm global bin dir: `echo "$(npm prefix -g)/bin"`. `install.sh` and `run.sh` both add `~/.npm-global/bin` if they find it there. |
| `Cannot start: the following ports are already in use` | The ingress **or** an internal port is taken. Move the ingress (`AGENT_CANVAS_PORT=...`) and/or the internal ports (`OH_CANVAS_SAFE_BACKEND_PORT` / `OH_CANVAS_SAFE_AUTOMATION_PORT`). A second Agent Canvas — including a sandbox's own — occupies the internal ports. |
| `Node.js ... is too old` | Install Node ≥ 22.12. |
| UI loads but the model "doesn't work" | The LLM profile isn't set or the vLLM tunnel is down. Set Settings → LLM and confirm `curl http://localhost:8000/v1/models` works. |
| `uvx` not found when launching | `uv` isn't on `PATH`. Install it and open a new terminal. |

## Uninstall

```bash
npm uninstall -g @openhands/agent-canvas     # removes the npm package
rm -rf ./openhands-state                     # removes the stack's state (optional)
```
