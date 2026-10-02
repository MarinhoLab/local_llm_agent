# MEMORIES.md

> **Note (2026-09): the `macos_client/` stack — and with it the `oh-bootstrap`
> sidecar, the `duckduckgo-mcp` service, and `example.env` — has been removed
> from this repository.** Most of the plan and log below describes that now-
> removed work and is kept only as history. The one piece that remains
> directly useful is the **verified OpenHands V1 REST API surface** (settings
> store, profiles, MCP registration) under
> [Investigation log](#investigation-log) — that API is still how the Agent
> Canvas stack configures its LLM profile and MCP servers.
>
> **Note (2026-09): the Docker-based `agent_canvas/` stack has also been
> removed**, in favor of `agent_canvas_native/` (no Docker). The 2026-09-08
> entry about sharing the host Docker socket with `agent_canvas/compose.yml`
> now describes a retired stack and is kept only as history.

A persistent, append-friendly record of **what we tried, what worked, and why**
for this repo. New findings are appended to
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

### 2026-09-08 — Agent Docker: nested daemon → shared host socket

**Symptom:** running Docker inside the Canvas/agent sandbox (the nested
`sudo dockerd` that `AGENT_CANVAS_PRIVILEGED=true` existed to enable) fails in a
nested environment. Reproduced here: the sandbox's root `/` is itself `overlayfs`
(we are a container), so a second `dockerd` inside it dies at
`POST /containers/create` with
`failed to mount ... fstype: overlay ... err: invalid argument` — i.e. it cannot
do **overlay-on-overlay**. Even where it doesn't hard-fail, the nested daemon is
heavy and fragile (needs `CAP_SYS_ADMIN`, spins up a duplicate Docker network
stack, and its image state is ephemeral in the container's `/var/lib/docker`).

**Decision:** share the **host** Docker socket with the agent instead of nesting
a daemon. `agent_canvas/compose.yml` now bind-mounts
`AGENT_CANVAS_DOCKER_SOCKET` (default `/var/run/docker.sock`) into the container
at `/var/run/docker.sock` and sets `DOCKER_HOST=unix:///var/run/docker.sock`, so
the in-container `docker` client drives the host daemon directly.

**Consequences / trade-offs:**

- The agent no longer runs `dockerd` and no longer needs `CAP_SYS_ADMIN`, so
  `AGENT_CANVAS_PRIVILEGED` now **defaults to `false`** — the "container is the
  sandbox boundary" posture is restored by default. The flag is kept as the
  documented **nested-daemon fallback** (host has no daemon, or you want the
  agent's containers isolated from the host daemon).
- Security trade-off (accepted for this single-user, small-agent-count box): with
  the socket shared, an agent that escapes its process sandbox can run arbitrary
  containers on the **host** daemon. The old nested-daemon setup kept the agent's
  containers on a throwaway daemon, but the nested daemon was unreliable in nested
  environments (this very bug). The README documents this and the escape hatch
  (remove the socket line + `AGENT_CANVAS_PRIVILEGED=true`).
- The default socket path works on Linux and Docker Desktop (macOS/Windows);
  override `AGENT_CANVAS_DOCKER_SOCKET` for non-standard paths (e.g.
  `//./pipe/dockerDesktopLinuxContainers` on Windows).

**Verification:** `sudo docker compose -f agent_canvas/compose.yml config`
renders cleanly with `DOCKER_HOST` set, the `/var/run/docker.sock` bind, and no
`privileged` key (unprivileged default). Docs kept in sync: README env-var table
+ prose, AGENTS.md stack description, and the `docker-usage` skill (now leads
with the shared socket; nested daemon demoted to a clearly-labelled fallback).

### 2026-09 — Checkpoint swap: official FP8 → NVIDIA NVFP4, vLLM → nightly

The `dgx_spark_host/` stack moved away from the official FP8 checkpoint to
NVIDIA's repack, and the pinned vLLM image to a nightly build. This entry
records the current state so the README/AGENTS tuning notes do not read as if
the old FP8 setup were still live.

**What changed in `dgx_spark_host/`:**

- `Dockerfile`: `MODEL_NAME` is now `nvidia/Qwen3.8-27B-NVFP4` (was
  `Qwen/Qwen3.8-27B-FP8`); `FROM` is now `vllm/vllm-openai:nightly` (was pinned
  `vllm/vllm-openai:v0.28.0-ubuntu2404`); `GPU_MEMORY_UTILIZATION` is now `0.80`
  (was `0.85`). `MAX_NUM_SEQS` is `8`, `NUM_SPEC_TOKENS` is `5`, `SPEC_METHOD`
  is `mtp`.
- `entrypoint.sh`: `--kv-cache-dtype fp8_e4m3` (was `fp8`); `--seed 0` added;
  speculative decoding is back on via
  `--speculative-config '{"method":"mtp","num_speculative_tokens":5}'`.
  Removed from an earlier revision and **not re-added**: `--dtype auto`,
  `--async-scheduling`, `--load-format fastsafetensors`, and the
  `ENABLE_LONG_CONTEXT`/YaRN 1M-token switch.

**Why (per the commit messages):** the NVFP4 checkpoint was tried to merge the
server settings toward the values in the model card; the pinned v0.28.0 image
was swapped to `nightly` because the `qwen3_5` hybrid-attention architecture and
Qwen MTP / fused-decode kernels track the nightly line rather than a stable
tag.

**Verified checkpoint facts** (`nvidia/Qwen3.8-27B-NVFP4`, cross-checked against
the Hugging Face `config.json` / index / `hf_quant_config.json`):

- It is an **NVIDIA Model Optimizer** quantization (`quant_method: modelopt`,
  `quant_algo: MIXED_PRECISION`) of the official `Qwen/Qwen3.8-27B` base:
  linear-attention + full-attention projections are **FP8** (FP8 weight +
  dynamic FP8 input activation), the MLP and `lm_head` are **NVFP4**
  (`group_size: 16`). Total weight download is **~22 GB** (was ~27 GB for the
  FP8 repack).
- `model_type` is **`qwen3_5`**, `architectures` is
  `Qwen3_5ForConditionalGeneration`, with a `vision_config` and
  `language_model_only: false` — a native VLM (image + video), which is why the
  entrypoint keeps `--limit-mm-per-prompt '{"image":4}'` and there is no
  `--language-model-only` flag.
- It ships a **1-layer MTP head**: `text_config.mtp_num_hidden_layers: 1`, with
  `mtp.layers.0.*` tensors in `model.safetensors.index.json`. So MTP
  speculative decoding needs no separate draft model.
- `text_config.max_position_embeddings` is **262144** (the native context the
  stack serves; `--max-model-len` is fixed at `MAX_MODEL_LEN`).
- `hf_quant_config.json` sets `kv_cache_quant_algo` to **`None`** for this
  NVFP4 repack — the checkpoint does **not** itself request FP8 KV, so the
  entrypoint sets `--kv-cache-dtype fp8_e4m3` explicitly. (The FP8 model card's
  `kv_cache_quant_algo: FP8` note applied to the previous `Qwen/Qwen3.8-27B-FP8`
  checkpoint, not this one.)

**Docs brought back in sync (this change):** the `dgx_spark_host` env-var table
and tuning notes in `README.md`, the project overview + Key-tuning-decisions in
`AGENTS.md` (model, vLLM image, image-inputs, `--kv-cache-dtype`, context), the
opencode display name (`Qwen3.8-27B-NVFP4`) in `opencode_client/example.env`,
`opencode.example.json`, and `scripts/lib_vllm.sh`, the LLM-profile example in
`agent_canvas_native/README.md`, and the `docker-usage` skill (model + ~22 GB
download size). No code changed — `entrypoint.sh`, `Dockerfile`, `compose.yml`,
and the client scripts were already on the NVFP4/nightly path; only the prose
was stale.

**Caveats / things to re-verify on the real Spark:** the `nightly` base image
is unpinned, so a rebuild can drift — record the working nightly tag if
reproducible builds are needed. The "~2x decode" figure for MTP at
`NUM_SPEC_TOKENS=5` was carried over from the earlier FP8 measurements; re-measure
if the NVFP4 repack changes decode behaviour.

### 2026-09-30 — Third DGX option: Qwen3.8 Flash DGX UltraFast (`flash_ultrafast`)

Added a **third DGX-side configuration**, `dgx_spark_host/flash_ultrafast/`,
running the [dime-online/qwen3.8-Flash-DGX-UltraFast](https://github.com/dime-online/qwen3.8-Flash-DGX-UltraFast)
**v16b** recipe. It joins the two `MODEL_CONFIG` checkpoint presets (`nvfp4` /
`b16`) already added to the standard `dgx_spark_host/` stack.

**Why a separate substack, not a third `MODEL_CONFIG` value:** `nvfp4` and `b16`
are plain Hugging Face checkpoints served by the same standard
`vllm/vllm-openai:nightly` image via the shared `entrypoint.sh` `vllm serve` —
so they fit a `MODEL_NAME`-style switch. The UltraFast recipe is fundamentally
different and would be misleading to fold into that mechanism:

- a **patched vLLM image** (`qwen38-flash-dgx:iter6d-20260910`), built from the
  upstream's staged Dockerfiles (`iter6c` → `iter6d`) on top of
  `vllm/vllm-openai:qwen38-flash-next@sha256:fc120e…` — CUDA 13.0, custom
  low-latency SM12x GEMM, Mamba/PLE/MTP kernels, piecewise CUDA graphs with
  twelve `--cc.splitting_ops`;
- **two pinned downloads** (~135 GB total): `Saren/Qwen3.8-Flash-Next-W4A16-AutoRound-hybrid`
  (revision `8b82f0b7…`) + `Saren/Qwen3.8-Flash-Next-ple-table-fp8`
  (revision `50511b0a…`);
- a **T80 dense-MTP drafter directory** that must be *built*
  (`recipe/build/model/build.sh --run`), plus a 65,536-id draft vocabulary
  (`draft-vocab-ids-K65536.txt.gz`);
- a heavily pinned serve command (`VLLM_PLE_MMAP*`, `VLLM_DRAFTER_EXPERTS_FP8`,
  `QWEN38NEXT_LOW_LATENCY_GEMM`, `VLLM_VERIFY_TOPK_TRITON`, `KEEP_DRAFT_BLOCKS`,
  `--kv-cache-memory-bytes 16g`, `--gpu-memory-utilization 0.01`, MTP depth 3,
  block rejection + probabilistic draft sampling, `qwen3_xml` tool parser).

The W4A16 target keeps an FP8 PLE table **memory-mapped from storage**
(`VLLM_PLE_MMAP=1`), so it stays ~71 GiB resident with a 16 GB KV pool at the
262,144-token context. Speed comes from the MTP drafter (block rejection), not
lower-bit target weights — output distribution is preserved (upstream: 93% on a
492-item suite; teacher-forced agreement within the noise band).

**What was added (this repo):**
- `flash_ultrafast/entrypoint.sh` — thin wrapper that assembles the pinned
  v16b `vllm serve` command from env vars and preflights the three mounted
  assets (checkpoint, PLE table, draft vocab). Defaults = promoted v16b values;
  every value overridable via `.env`.
- `flash_ultrafast/compose.yml` — runs the **fixed** upstream image (not
  rebuilt here), mounts the assets read-only, sets the ~30 pinned PLE/MTP/tuning
  env vars, exposes port 8000, `shm_size: 16g`, `ipc: host`.
- `flash_ultrafast/setup-upstream.sh` — the one-time Spark-side prep: clones the
  upstream repo, installs the `hf` CLI, downloads the pinned checkpoint + PLE
  table, builds the patched image, builds the T80 drafter, installs the draft
  vocab, then verifies. Delegates the heavy build/download work to the upstream
  Apache-2.0 scripts rather than vendoring them (no image patches/weights are
  committed to this repo).
- `flash_ultrafast/README.md` — provenance, upstream claims, setup/run/switch,
  override table.
- Docs: top-level `README.md` (three-option table + `### flash_ultrafast`
  subsection), `AGENTS.md` (overview, stack list, Key-tuning-decisions,
  conventions, Common commands).

**Serving identity:** alias **`qwen`** (not `qwen-local`) on port 8000 — the
three DGX options share port 8000, so run only ONE at a time. The
`nvfp4`/`b16` and `flash_ultrafast` stacks are distinct compose projects and do
**not** auto-stop each other; stop the other first (`docker compose -f
../compose.yml down`). Clients (Agent Canvas / OpenCode) point at model `qwen`
when this option is active.

**Verification done here:** `bash -n` on the new entrypoint and setup script;
`docker compose config` renders the pinned image + env for the substack. The
entrypoint preflight path (assets present / missing) and arg-list assembly were
checked by reading against the upstream `serve.sh`/`env` (SPLITS, PLE, MTP,
prefix-cache, pinned-prompt branches). NOT run on a GPU: the patched image, the
~135 GB downloads, the drafter build, and the actual 74/212 tok/s numbers all
require the Spark. Re-verify the upstream's measurements on real hardware.

**Caveats / re-verify on the Spark:** the promoted v16b image tag
`qwen38-flash-dgx:iter6d-20260910` is a moving target only if the upstream
re-releases it — `setup-upstream.sh` builds it from pinned parent
`sha256:fc120e…`, so it is reproducible from upstream source. Changing ANY
pinned value (KV bytes, seqs, MTP depth, batched tokens, `GPU_MEM`) creates a
new variant whose speed/quality must be measured separately per upstream docs —
keep the promoted values for the published throughput. The 65,536-id draft
vocab is English/code-weighted: non-English (notably CJK) output gets lower
draft *acceptance* (slower) but unchanged *quality*. Upstream is a **fork**;
the model weights carry their own terms — check them before serving.

### 2026-10-02 — Restructure: one self-contained stack folder per model

Requested: fully isolate the three DGX-side stacks — the two Qwen3.8-27B
models must not share parameters or code. The `MODEL_CONFIG` switch (which
shared one `Dockerfile`/`entrypoint.sh`/`compose.yml` between `nvfp4` and
`b16`) was removed and replaced with one self-contained folder per stack:

- `dgx_spark_host/qwen38-27b-nvfp4/` — `Dockerfile` (defaults: `MODEL_NAME=
  nvidia/Qwen3.8-27B-NVFP4`, `GPU_MEMORY_UTILIZATION=0.80`), `entrypoint.sh`,
  `compose.yml` (container `dgx-qwen-nvfp4-vllm`), `README.md` with its own
  env table and tuning notes. Served alias `qwen-local`.
- `dgx_spark_host/qwen38-27b-b16/` — independent copy with `MODEL_NAME=
  Qwen/Qwen3.8-27B` and `GPU_MEMORY_UTILIZATION=0.70` (larger BF16 weights).
  Container `dgx-qwen-b16-vllm`. Served alias `qwen-local`.
- `dgx_spark_host/flash_ultrafast/` — unchanged in behavior; its docs
  updated to refer to the sibling stack folders.

The old shared `dgx_spark_host/Dockerfile`, `entrypoint.sh`, and
`compose.yml` were deleted; `MODEL_CONFIG` no longer exists anywhere. A thin
`dgx_spark_host/README.md` index now lists the three stacks (all port 8000,
run one at a time). Docs updated: top-level `README.md` (stack table, run
commands, per-stack pointers), `AGENTS.md` (overview, stack list, constraints,
Key tuning decisions, Common commands, sanity checks, conventions),
`agent_canvas_native/README.md` (LLM-profile note), the `docker-usage` skill
(server row + bring-up + tunnel bullets).

**Consequence for existing Spark deployments:** the compose project name and
container name change (`dgx-qwen-vllm` → `dgx-qwen-nvfp4-vllm` /
`dgx-qwen-b16-vllm`), and each stack's `.env` (e.g. `HF_TOKEN`) now lives in
the stack's own folder — move it when redeploying.

**Verification:** `bash -n` on all entrypoints; stub-`vllm` dry-runs of the
nvfp4 and b16 entrypoints (correct model/memory flags per stack); `docker
compose config` renders for all three stacks.

### 2026-10-02 — flash_ultrafast now serves the alias `qwen-local`

Requested: the flash stack should expose the same model alias as the 27B
stacks so the macOS clients (Agent Canvas LLM profile, OpenCode
`OPENCODE_MODEL_ID`) never change when switching stacks. Changed the default
`SERVED_NAME` from `qwen` to `qwen-local` in
`flash_ultrafast/entrypoint.sh` + `compose.yml` (still overridable via `.env`),
and removed the client-side special-case notes (`OPENCODE_MODEL_ID=qwen` etc.)
from the READMEs, `AGENTS.md`, and `agent_canvas_native/README.md`. All three
stacks now serve `qwen-local` on port 8000; only the underlying checkpoint
differs. (Earlier MEMORIES entries describing the `qwen` alias are history.)

**Verification:** `bash -n`; `docker compose config` shows
`SERVED_NAME: qwen-local`; stub dry-run emits `--served-model-name
qwen-local`.

### 2026-10-02 — Fact-check fixes for the per-stack restructure

Checked against the upstream UltraFast repo (`recipe/config/v16b`,
`docs/BUILD.md`, README), the Hugging Face API, and the model cards:

- `setup-upstream.sh` passed the *local directory* to `hf download` as the repo
  id; it now downloads `Saren/Qwen3.8-Flash-Next-W4A16-AutoRound-hybrid` and
  `Saren/Qwen3.8-Flash-Next-ple-table-fp8` at the pinned revisions. The
  checkpoint is ~75 GB (not ~27 GB) and the PLE table ~52 GB (~130 GB total,
  as upstream says). Re-runs skip the drafter build once its output exists
  (upstream refuses to overwrite), and the verify step checks the
  `-mtpdense-g32` directory that `compose.yml` mounts.
- `.env` overrides never reached the containers: compose only used `.env` for
  `${...}` interpolation, so `GPU_MEMORY_UTILIZATION`, `MAX_NUM_SEQS`,
  `HF_TOKEN`, `SPEC_EXTRA`, `PIN_PROMPT`, ... were silently ignored (this
  predates the restructure). Each stack's compose now has an optional
  `env_file: .env`.
- `flash_ultrafast/entrypoint.sh`: `PREFIX_CACHE=0` now passes
  `--no-enable-prefix-caching` (vLLM enables it by default), as upstream does.
- The BF16 README said 0.70 is lower *because* the weights are larger; the
  fraction caps weights + KV together, so larger weights shrink KV at a given
  fraction. 0.70 still leaves ~25 GiB of fp8 KV (~32 KiB/token, ~3 full
  262144-token sequences); the rationale was corrected, the value kept.
- Upstream's ~71 GiB residency is the base recipe's, not v16b's; reworded.
- Stale references to the removed shared `dgx_spark_host/compose.yml`,
  `dgx-qwen-vllm`, and `MODEL_CONFIG` in the docker-usage skill and
  `opencode_client/example.env` were updated.

**Verification:** `bash -n` + `shellcheck -S warning` on all scripts;
`docker compose config` for all three stacks with and without a `.env` (the
`.env` values now appear in the container environment, 0 of them before);
stub `vllm` run of the flash entrypoint with `PREFIX_CACHE=1/0`; stub `hf`
run of the setup download step. Not run on a GPU.

### 2026-10-02 — `qwen38-27b-b16` renamed to `qwen38-27b-bf16`

The folder serves the BF16 checkpoint, so "b16" was a misnomer. Renamed the
folder to `dgx_spark_host/qwen38-27b-bf16/`, the compose service to
`qwen-bf16-vllm`, and the container to `dgx-qwen-bf16-vllm`, and updated every
reference (READMEs, `AGENTS.md`, the docker-usage skill,
`opencode_client/example.env`). Earlier MEMORIES entries that say `b16` are
history. Migration: `docker compose down` the old stack from the old folder
before switching (a running `dgx-qwen-b16-vllm` would still hold port 8000),
and move any `.env` / `hf-cache` from the old folder into the new one.

**Verification:** `bash -n` on the entrypoint; `docker compose config` renders
with service `qwen-bf16-vllm` / container `dgx-qwen-bf16-vllm`; no `b16`
references remain outside this history file.

### 2026-10-02 — BF16 stack `GPU_MEMORY_UTILIZATION` standardized to 0.80

Requested: use the same `GPU_MEMORY_UTILIZATION` as the NVFP4 stack. The
`qwen38-27b-bf16` default is now 0.80 (was 0.70). Since the fraction caps
weights + KV together, this grows the BF16 KV pool from ~25 GiB to ~38 GiB
(~four full 262144-token sequences at ~32 KiB/token fp8 KV). Updated the
stack's `Dockerfile` and README and `AGENTS.md`.

**Verification:** `docker compose config` + stub-`vllm` dry-run of the BF16
entrypoint emits `--gpu-memory-utilization 0.80`. Not run on a GPU.

### 2026-10-02 — BF16 stack `MAX_NUM_SEQS` limited to 4

Requested: since the BF16 KV pool (~38 GiB at `GPU_MEMORY_UTILIZATION=0.80`)
holds only about four full 262144-token sequences, cap concurrency there at
4. `qwen38-27b-bf16` now defaults to `MAX_NUM_SEQS=4` (was 8); the NVFP4
stack stays at 8. Updated the stack's `Dockerfile` and README and
`AGENTS.md`. Sequences share the KV pool, so with short contexts it can be
raised again via `.env`.

**Verification:** stub-`vllm` dry-run of the BF16 entrypoint emits
`--max-num-seqs 4`. Not run on a GPU.

### 2026-10-02 — `setup-upstream.sh`: hf venv moved out of the clone dir

First run on the Spark failed at step 1: `fatal: destination path
'~/qwen3.8-Flash-DGX-UltraFast' already exists and is not an empty directory`.
Cause: when `hf` was not installed, the tooling step created its venv at
`$CLONE_DIR/.venv` *before* cloning, so `git clone` found a non-empty target.
The venv now lives at `$VENV_DIR` (default `~/.cache/qwen38-v16b/hf-venv`,
reused on re-runs, `hf` called by path). Step 1 removes a clone dir that holds
only the stale `.venv` from the old script, and stops with a clear message
for any other non-git directory.

**Verification:** `bash -n` + `shellcheck -S warning`; stub run (fake git,
docker, python3) of: the Spark state (dir with only `.venv`, no `hf`) →
recovers, clones, downloads; re-run reuses venv + clone; non-git dir with
other files → clear error; clean first run.

### 2026-10-02 — Drafter build: upstream test writes into a read-only /work

On the Spark, step 4 (`recipe/build/model/build.sh --run`) died in upstream's
own unit test: `OSError: [Errno 30] Read-only file system:
'_iter4_st_test.safetensors.partial'`. Upstream bug (still on its main,
0c391a3): `test_safetensors_roundtrip(tmp="_iter4_st_test.safetensors")`
writes into the working dir, and `build.sh` runs the tests with
`-v "$here:/work:ro" -w /work`. The other tests use `tempfile`. Before the
drafter build, `setup-upstream.sh` now rewrites that one default to
`/tmp/_iter4_st_test.safetensors` in the local upstream clone (idempotent,
warns when it patches). The image (step 3) had built and passed its checks.

**Verification:** reproduced locally by running upstream's test from a
read-only copy of `recipe/build/model` (fails writing the `.partial` file);
with the patched default, 289/289 checks pass and the scratch file is
removed. The `sed` edit checked on Linux (alpine): patches once, no-op on
re-run. `bash -n` + `shellcheck -S warning`.

### 2026-10-02 — flash_ultrafast: `PROMPT_TOKENS_DETAILS` switch, default off

Server-side fix for the Agent Canvas crash `'PromptTokensDetailsWrapper'
object has no attribute 'cache_creation_tokens'`. Upstream v16b passes
`--enable-prompt-tokens-details`, which adds `usage.prompt_tokens_details`
(cached-token counts) to API responses; openhands-sdk < 1.50.0 (every Agent
Canvas release up to 1.24.0) crashes on that block. The flag is now behind
`PROMPT_TOKENS_DETAILS` (entrypoint + compose), default `0`; `1` restores the
upstream value. It is reporting-only: no effect on speed or output. The 27B
stacks never passed it, which is why they were unaffected. The client-side
fix is an Agent Canvas release pinning sdk >= 1.50.0 (see `install.sh`).

**Verification:** `bash -n` + `shellcheck -S warning`; stub-`vllm` run: unset
and `0` emit no `--enable-prompt-tokens-details`, `1` adds exactly that
argument; `docker compose config` renders `0` by default and `1` from `.env`.
Earlier repro: openhands-sdk 1.49.x works when the usage carries no
`prompt_tokens_details`.
