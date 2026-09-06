# MEMORIES.md

A persistent, append-friendly record of **what we tried, what worked, and why**
for this repo. It doubles as the plan for the "load LLM + MCP from a file"
work (see [Plan](#plan)). New findings are appended to
[Investigation log](#investigation-log) rather than rewriting history.

The goal, in one line: **make a fresh `docker compose up` on a new machine come
up already-configured** — the local Qwen LLM profile and the DuckDuckGo/Tavily
MCP servers — so nobody has to re-enter them in the OpenHands GUI every install.

---

## Problem statement

On macOS, putting the Tavily key (or the LLM details) in `macos_client/.env` is
**not recognized by OpenHands**. Proof: the key is present in the local `.env`,
yet the agent has no Tavily tools.

Root cause (confirmed, see log entry 2026-09-06):

- The **V1 web app does not read `LLM_*` env vars.** The LLM is resolved from
  the app server's **settings store** (GUI: *Settings → LLM*), persisted in the
  `OPENHANDS_STATE` volume. `LLM_MODEL`/`LLM_BASE_URL`/`LLM_API_KEY` are only
  honored by the V0/CLI path (`LLM.load_from_env` + `--override-with-envs`) and
  are ignored by the web app.
- **MCP servers are registered in the same settings store**, not via env vars.
  There is no `TAVILY_API_KEY` env hook in the web app either — the key only
  exists once it has been saved into the settings store (GUI: *Settings → MCP*,
  or a REST call). `.env` `TAVILY_API_KEY=` is, in the current stack, a
  placeholder that nothing reads.

So: **both the LLM and the MCP servers live in the OpenHands settings store,
not in environment.** To load them "from a file," we must write them *into* the
settings store programmatically on first start.

---

## Design principle

Single source of truth stays in the git-ignored `.env`. A tiny, **idempotent**
bootstrap process reads a few env vars and writes them into the OpenHands
settings store through the **official V1 REST API** — the exact same API the GUI
uses. It runs on every `docker compose up` but **only writes what is missing**,
so:

- it never clobbers settings a user has already customized by hand,
- it is safe to leave running (no-op once configured),
- it self-heals a wiped/`-v` state volume automatically.

We deliberately do **not** hand-edit the `settings.json` file on the state
volume, and we do **not** try to make OpenHands read `.env` directly (that
requires upstream OpenHands changes). Writing through the app server's own API
is version-stable (it's the GUI's path) and keeps all normalization
(base-URL resolution, secret redaction, profile reconciliation) in OpenHands.

---

## Plan

### 1. Bootstrap script — `macos_client/oh_bootstrap.py` (new)

Stdlib-only Python 3 (no `requests`; use `urllib`). Runs as a **sidecar
container** on the same compose network (see step 2). Behavior:

1. **Wait for readiness**: poll `GET {OH_URL}/health` until it returns 200
   (the app server is up). Then poll `GET {OH_URL}/api/v1/settings` until it
   returns 200 *or* 404 (settings store reachable; 404 = fresh install, no
   settings saved yet). Bounded retry (e.g. 120 × 2 s) so a slow start on a
   cold macOS Docker VM does not kill the sidecar.
2. **Load current state**:
   - `GET /api/v1/settings` → current `agent_settings.llm` and
     `agent_settings.mcp_config`.
   - `GET /api/v1/settings/profiles` → existing LLM profile names +
     `api_key_set` flags.
3. **LLM** (env: `LLM_MODEL`, `LLM_BASE_URL`, `LLM_API_KEY`):
   - **Skip** if `agent_settings.llm.model == LLM_MODEL` **and**
     `base_url == LLM_BASE_URL`.
   - Otherwise `POST /api/v1/settings` with
     `{"agent_settings_diff": {"llm": {"model", "base_url", "api_key"}}}`.
     This is the same partial-patch mechanism the GUI uses; it deep-merges and
     preserves unrelated settings, and applies OpenHands' base-URL fixups.
   - **Best-effort named profile**: `POST /api/v1/settings/profiles/{LLM_PROFILE_NAME}`
     with the same LLM, then `POST .../profiles/{LLM_PROFILE_NAME}/activate`,
     so the GUI shows a proper profile. Skip this step if a profile with that
     name already exists and `api_key_set` is true.
4. **MCP servers** (env: `DUCKDUCKGO_MCP_URL`, `TAVILY_API_KEY`,
   `TAVILY_URL`):
   - Build the desired `mcp_config` from the *current* one (read in step 3)
     plus:
     - `duckduckgo` (or reuse the existing entry pointing at the same URL):
       `{"url": DUCKDUCKGO_MCP_URL, "transport": "sse"}`.
     - `tavily`, **only if `TAVILY_API_KEY` is non-empty**:
       `{"url": TAVILY_URL, "transport": "streamable-http",
          "auth": {"strategy": "bearer", "value": TAVILY_API_KEY}}`.
   - **Skip** the write if every desired server is already present (matched by
     URL). Otherwise `POST /api/v1/settings` with
     `{"agent_settings_diff": {"mcp_config": <desired>}}`.
     `mcp_config` is applied **wholesale** by OpenHands, so we must send the
     *full* desired map (current + additions), never a lone entry.
5. **Report** a one-line JSON summary to stdout (what was skipped/written),
   then exit 0. On a hard failure (app server never ready, or a non-2xx on a
   write) exit non-zero; `restart: unless-stopped` gives bounded retries.

Secrets handling: the Tavily key is read from the sidecar's **environment**
(injected from `.env`), never written to disk and never logged (log only the
key's presence, e.g. `"tavily": "configured"`).

Why an *idempotent writer* and not a one-shot: a one-shot that runs once and
exits would need a flag/volume to know it already ran, and would not heal a
re-created state volume. An idempotent writer needs no state of its own.

### 2. Compose wiring — `macos_client/compose.yml` (modified)

Add a sidecar service (no image tag needed — reuse the OpenHands image, which
already has Python + the stdlib, and lives on the same network):

```yaml
  oh-bootstrap:
    image: docker.openhands.dev/openhands/openhands:${OPENHANDS_TAG}
    container_name: oh-bootstrap
    entrypoint: ["python", "/bootstrap/oh_bootstrap.py"]
    volumes:
      - ./oh_bootstrap.py:/bootstrap/oh_bootstrap.py:ro
    environment:
      OH_URL: http://openhands:3000
      LLM_MODEL: ${LLM_MODEL}
      LLM_BASE_URL: ${LLM_BASE_URL}
      LLM_API_KEY: ${LLM_API_KEY}
      LLM_PROFILE_NAME: ${LLM_PROFILE_NAME}
      DUCKDUCKGO_MCP_URL: ${DUCKDUCKGO_MCP_URL}
      TAVILY_API_KEY: ${TAVILY_API_KEY}
      TAVILY_URL: ${TAVILY_URL}
    depends_on:
      - openhands
    restart: unless-stopped
```

Notes:
- The app server binds `0.0.0.0:3000` (verified: `uvicorn ... --host 0.0.0.0`),
  so a sibling container on `macos_client_default` reaches it at
  `http://openhands:3000`. No port re-publication needed.
- `depends_on: openhands` ensures ordering, but the script still health-polls
  (depends_on alone does not wait for the app to answer).
- Reusing the OpenHands image means `pull_policy: always` stays consistent and
  we avoid a second base image in the stack.

### 3. Env template — `macos_client/example.env` (modified)

Reintroduce the LLM vars and make the MCP vars meaningful, with honest comments:

```ini
# ---- LLM (written into OpenHands by oh_bootstrap on first start) ----
# These are NOT read by OpenHands directly; the bootstrap sidecar copies them
# into the OpenHands settings store (the same store the GUI writes to).
LLM_MODEL=openai/qwen-local
LLM_BASE_URL=http://host.docker.internal:8000/v1
LLM_API_KEY=local-dgx-key
LLM_PROFILE_NAME=qwen-local

# ---- MCP servers (same mechanism) ----
# DuckDuckGo is keyless (SSE). URL is the host-published port of the local
# duckduckgo-mcp container.
DUCKDUCKGO_MCP_URL=http://host.docker.internal:8001/sse
# Tavily (remote). Leave TAVILY_API_KEY blank to skip registering Tavily.
# Fill the real key in a local, git-ignored .env only.
TAVILY_URL=https://mcp.tavily.com/mcp
TAVILY_API_KEY=
```

### 4. `.gitignore` (already correct)

`.env` is already ignored — the bootstrap reads it via compose interpolation,
so the real key never needs to be committed. No change needed, but we keep the
"tracked `.env` templates carry empty secrets" convention.

### 5. Docs (keep in sync)

- **README.md** (`macos_client` section): replace "configure once in the GUI"
  with "fill `.env` (`LLM_*`, `TAVILY_API_KEY`) → `docker compose up`; the
  bootstrap configures OpenHands for you. GUI remains the way to *change* them
  later." Update the env-var table.
- **`.agents/skills/mcp-search-servers/SKILL.md`**: note that DuckDuckGo and
  (with a key) Tavily are now auto-registered by the bootstrap; the GUI/REST
  steps remain the manual fallback.
- **`AGENTS.md`** ("Key tuning decisions"): replace the "LLM is GUI-only" note
  with the bootstrap mechanism and the reason (V1 ignores `LLM_*` env vars).

### 6. What we deliberately do NOT do

- **No hand-editing `settings.json`** on the state volume: brittle, bypasses
  OpenHands' normalization/redaction, and races the app server (which also
  writes it).
- **No upstream OpenHands fork** to make it read `.env`: overkill for a local
  stack; the bootstrap achieves the same with zero patching.
- **No new base image / Dockerfile** for the sidecar: reusing the OpenHands
  image keeps the stack simple and version-aligned.

### 7. Verification plan

- **Unit (in-container, pure, no network, no changes):** construct `Settings()`,
  apply the exact payloads, assert the resulting `llm`/`mcp_config`/profiles
  are correct. Proves the *shape* of every write.
- **Integration, no-op (safe against the live app server):** run the sidecar as
  a one-shot container with the env pointing at the **running** OpenHands
  instance but with `TAVILY_API_KEY` **empty** (no real key in this sandbox) and
  the LLM already matching. Expect it to **skip everything** and exit 0, leaving
  `GET /api/v1/settings` byte-identical (except no-op). This proves readiness
  polling, the skip logic, and the network path without mutating the live config.
- **Integration, fresh-install (sandboxed):** run the sidecar against a
  **disposable** OpenHands instance on a throwaway state volume to prove it
  *creates* the LLM profile + MCP from scratch, then tear it down. (Only if a
  spare port/image is available; otherwise covered by the in-container unit test
  of the `Settings()` fresh path, which already passed.)
- **Docker config sanity (no GPU):** `bash -n`, `yaml.safe_load(compose.yml)`.

### 8. Rollback

`docker compose down` (or remove the `oh-bootstrap` service) reverts to the
current GUI-only behavior; the bootstrap is additive and writes nothing when
its env vars are blank.

---

## Investigation log

### 2026-09-06 — Root cause + V1 API surface (verified against a live instance)

**Confirmed the bug.** The V1 web app ignores `LLM_*`/`TAVILY_API_KEY` env vars.
The LLM and MCP servers both live in the app server's **settings store**:

- Storage: `FileSettingsStore` → `settings.json` in the file store, i.e. under
  the `OPENHANDS_STATE` volume (mounted at `/.openhands`).
- The web app reads the LLM from `agent_settings.llm` (+ `llm_profiles`), and
  MCP from `agent_settings.mcp_config`. There is no env-var path.

**Verified the official V1 REST API** (all returned 200 on the live instance):

| Purpose | Endpoint | Verified |
|---|---|---|
| Read full settings (incl. `agent_settings.llm`, `mcp_config`) | `GET /api/v1/settings` | ✅ |
| Partial-patch settings (deep-merge `agent_settings_diff`) | `POST /api/v1/settings` | ✅ (no-op round-trip preserved state) |
| List LLM profiles + active | `GET /api/v1/settings/profiles` | ✅ |
| Save/overwrite a named profile | `POST /api/v1/settings/profiles/{name}` (body `{"llm": {...}}`) | ✅ (create 201) |
| Activate a profile (sets `agent_settings.llm`) | `POST /api/v1/settings/profiles/{name}/activate` | ✅ |
| Delete a profile | `DELETE /api/v1/settings/profiles/{name}` | ✅ |
| Readiness probe | `GET /health` | ✅ 200 |

**Key mechanics learned (from source in the running image, v1.36.0):**

- `POST /api/v1/settings` accepts `{"agent_settings_diff": {...}, "conversation_settings_diff": {...}}`
  plus top-level keys. `agent_settings.llm` is deep-merged; base-URL/provider
  fixups are applied by OpenHands.
- **`mcp_config` inside `agent_settings_diff` is applied *wholesale* (replaced,
  not merged)** — so always send the full desired map. Secret redaction is
  handled: a stored `Authorization` header is normalized to
  `auth: {strategy: bearer, value: ...}` and kept redacted in `GET` responses.
- MCP server entry shape (from `MCPServer` schema):
  `{"url", "transport" (one of stdio|http|sse|streamable-http), "headers", "auth"}`.
  `auth` is a discriminated union on `strategy`
  (`api_key|basic|bearer|header|none|oauth2`).
  - SSE: `{"url": "http://host.docker.internal:8001/sse", "transport": "sse"}`
  - Tavily: `{"url": "https://mcp.tavily.com/mcp", "transport": "streamable-http", "auth": {"strategy": "bearer", "value": "<KEY>"}}`
- Profile names: `^[A-Za-z0-9._-]{1,64}$`.
- A **fresh install** (no `settings.json`) → `GET /api/v1/settings` returns 404;
  `Settings()` defaults build cleanly and accept the same `update()` payload.
  (Verified in-container: a from-scratch `Settings()` + our payload produced the
  expected `llm` and `mcp_config`.)

**Networking (verified):**

- App server runs `uvicorn ... --host 0.0.0.0 --port 3000` → reachable from a
  sibling container as `http://openhands:3000` on `macos_client_default`.
- vLLM is reachable from the sandbox at `http://host.docker.internal:8000/v1`
  (tunnel up), model `qwen-local`, `max_model_len 262144`.
- DuckDuckGo MCP is live (search returned real results) → the SSE server works.

**Rejected alternatives:**
- *Make OpenHands read `.env`* → requires upstream changes; the V1 app server
  only parses `OH_*`-prefixed vars for its own config, not LLM/MCP.
- *Sidecar writes `settings.json` directly* → brittle, races the app server,
  skips redaction/normalization.
- *One-shot init with a done-flag file* → doesn't heal a re-created state
  volume; idempotent writer is simpler and self-healing.

### 2026-09-06 — Current live settings (baseline before changes)

- `agent_settings.llm`: `model=openai/qwen-local`,
  `base_url=http://host.docker.internal:8000/v1`, `api_key_set=true`
  (the `local-dgx-key` placeholder).
- `agent_settings.mcp_config`: single entry
  `{"sse": {"url": "http://host.docker.internal:8001/sse", "transport": "sse"}}`
  (DuckDuckGo, registered by hand in the GUI). **No Tavily** — matches the
  reported symptom.
- `llm_profiles`: one profile `openai_qwen-local` (active).
- This instance has **no** `macos_client/.env` (only `example.env`), so there is
  no real Tavily key available in this sandbox to do a live Tavily round-trip;
  the Tavily write path is validated by shape + the in-container `Settings()`
  test instead.

### 2026-09-06 — Implementation + verification results (all pass)

Implemented `macos_client/oh_bootstrap.py` + `oh-bootstrap` sidecar (compose),
extended `macos_client/example.env` with `LLM_*`/`DUCKDUCKGO_MCP_URL`/
`TAVILY_URL`/`TAVILY_API_KEY`, updated README + AGENTS.md + the mcp-search
skill.

**Refinements made while implementing (beyond the original plan):**

- **LLM: file is the source of truth for model/base URL.** If the live model or
  base URL differs from `.env`, the full LLM (model, base, key) from `.env` is
  written. If only the key is missing, just the key is filled in. A hand-set
  key is otherwise preserved. (A pure "fill missing only" design would let a
  stale GUI value permanently shadow the file.)
- **Profile naming:** the GUI auto-names a profile `openai_<model>` (e.g.
  `openai_qwen-local`); `LLM_PROFILE_NAME` defaults to that in `example.env` to
  avoid ending up with two profiles for one model.
- **Profile snapshot:** when the live LLM is already correct but the named
  profile is missing/keyless, the profile is saved with an *empty body* —
  OpenHands snapshots the current `agent_settings.llm`, so a hand-set key is
  preserved. Saving from env values happens only when the LLM was just written.

**Verification (all executed, all green):**

1. **Unit (pure, no network):** 26 checks over `compute_llm_action` /
   `compute_profile_action` / `compute_mcp_action` — fresh install,
   already-configured no-op, model/base/key drift, trailing-slash tolerance,
   key-only fill, MCP URL dedup, preservation of user-added custom MCP
   servers. All pass.
2. **Fresh-install integration (disposable OpenHands instance, port 3999,
   empty state → `GET /api/v1/settings` = 404):** bootstrap wrote LLM
   (model+base+key), saved+activated profile `openai_qwen-local`, registered
   `duckduckgo` (SSE) + `tavily` (streamable-http, bearer). Verified persisted
   via the API: `llm_api_key_set=true`, both MCP servers present (Tavily auth
   redacted to `auth:{strategy:bearer}` in reads). Exit 0.
3. **Idempotency:** re-ran the identical command → everything skipped,
   exit 0, state unchanged.
4. **File-wins semantics:** simulated a GUI edit (base_url →
   `http://127.0.0.1:9999/v1`), re-ran bootstrap → restored the `.env` base URL
   and re-saved the profile. Exit 0.
5. **Sidecar path (compose-equivalent):** ran the script inside the
   `openhands` container with `OH_URL=http://openhands:3000` (service-name
   resolution on `macos_client_default` works) → clean no-op, exit 0.
   (A direct `docker run` with a `macos_client_default` network + entrypoint
   override was also attempted; the sandbox→Docker file-sharing restriction
   meant the in-container run is the faithful equivalent — same image, same
   network, same entrypoint semantics.)
6. **Live instance untouched:** after all tests, the real `openhands` settings
   were byte-identical (model/base/key, single `sse` MCP entry, profile
   `openai_qwen-local`).
7. **Docker config sanity:** `py_compile` OK, `yaml.safe_load` OK, services
   now `duckduckgo-mcp`, `oh-bootstrap`, `openhands`.

**Known limitation / follow-up:**

- A full `docker compose up` of the *modified* stack was not run in the
  sandbox (it would re-create the live `openhands` container). Every piece it
  composes — image/entrypoint override, network reachability, env
  interpolation, script behavior — was verified individually as above. On a
  real machine, `docker compose up` will pull the (already-present) image,
  create the sidecar, and the sidecar will be a no-op or a one-time
  fill-in.

### 2026-09-06 — Stale REST endpoints discovered (skill fix)

- `GET/POST /api/settings/mcp/<name>` (and `/api/v1/...`) → **SPA HTML
  fallback** (`text/html`), i.e. not a real V1 route. The per-server MCP REST
  API documented in the old skill does not exist in the current app-server.
- `POST /api/mcp/test` → **405**; `GET` → SPA HTML. The agent-server test
  endpoint is gone from the web app path too.
- The only verified MCP write path is `POST /api/v1/settings` with
  `agent_settings_diff.mcp_config` (wholesale replace of the map). The skill's
  "Adding a server" section was rewritten around it.

