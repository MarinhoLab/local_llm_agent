# Local LLM Agent

Run a Qwen model on a DGX Spark and connect to it from macOS using
[Agent Canvas](https://docs.openhands.dev/openhands/usage/agent-canvas/setup)
(native, no Docker) or [OpenCode](https://opencode.ai) (terminal client, no Docker).

## `dgx_spark_host/`

Host a Qwen model via vLLM on the DGX Spark machine.

### Run

```bash
cd dgx_spark_host
docker compose up --build
```

The API is available at `http://localhost:8000/v1`. For shared networks, bind to `127.0.0.1` in `compose.yml`.

### Environment Variables

| Variable                 | Default                | Description                                                                    |
|--------------------------|------------------------|--------------------------------------------------------------------------------|
| `MODEL_NAME`             | `Qwen/Qwen3.8-27B-FP8` | Hugging Face model to serve                                                    |
| `SERVED_MODEL_NAME`      | `qwen-local`           | Alias exposed by the API                                                       |
| `HOST`                   | `0.0.0.0`              | Bind address                                                                   |
| `PORT`                   | `8000`                 | Listen port                                                                    |
| `API_KEY`                | `local-dgx-key`        | API key for authentication                                                     |
| `MAX_MODEL_LEN`          | `262144`               | Maximum sequence length                                                        |
| `GPU_MEMORY_UTILIZATION` | `0.85`                 | Fraction of GPU memory to use                                                  |
| `MAX_NUM_SEQS`           | `8`                    | Maximum concurrent sequences                                                   |
| `MAX_NUM_BATCHED_TOKENS` | `8192`                 | Max tokens per batch                                                           |
| `SPEC_METHOD`            | `mtp`                  | Speculative decoding method (the checkpoint ships an MTP head)                 |
| `NUM_SPEC_TOKENS`        | `5`                    | Speculative draft tokens; ~2x decode speed at 3-5, tune per workload           |
| `ENABLE_LONG_CONTEXT`    | `0`                    | `1` stretches context to 1M tokens via YaRN (costs ~36 GiB KV; off by default) |
| `HF_CACHE`               | `./hf-cache`           | Volume mount path for Hugging Face cache                                       |
| `HF_TOKEN`               | *(unset)*              | Hugging Face token for gated models                                            |

All vLLM defaults are set in `Dockerfile`; override via `.env` or `compose.yml`.

Tuning notes (DGX Spark, GB10, 128 GB unified memory, LLM-only box):

- **Model**: official `Qwen/Qwen3.8-27B-FP8` (~27 GB, fine-grained FP8 block-128,
  quality nearly identical to the original per the model card). The checkpoint
  ships an MTP head, so MTP speculative decoding needs no separate draft model
  (~2x decode speed on GB10). It is a native vision-language model and image
  inputs stay enabled via `--limit-mm-per-prompt '{"image":4}'`; there is no
  `--language-model-only` flag in this stack.
- **Memory**: `GPU_MEMORY_UTILIZATION` is a fraction of the unified CPU+GPU
  pool. 0.85 is appropriate when the Spark runs nothing but the LLM; lower it
  if you host other workloads on the box.
- **Concurrency**: `MAX_NUM_SEQS` is 8 in this stack. Early measurements
  suggested the per-token bandwidth tax above 4 in-flight decodes outweighed
  continuous-batching gains on GB10; the value was raised to 8 and is kept
  overridable via `.env` — drop it back down if multi-agent latency regresses.
- **Context**: 262144 is the native max. `ENABLE_LONG_CONTEXT=1` enables YaRN
  to 1,048,576 tokens (static, costs KV memory on every request).

## `agent_canvas_native/`

Run [Agent Canvas](https://docs.openhands.dev/openhands/usage/agent-canvas/setup)
natively: UI + agent-server + automation server + ingress run as local
processes via Node.js and uv, with **no Docker**. Agents run as your user on
the local filesystem (there is no container sandbox).

### Run

```bash
./agent_canvas_native/install.sh   # one-time (upgrades on re-run)
./agent_canvas_native/run.sh
```

- Address `http://localhost:8020` (avoids 8000, the vLLM tunnel).
- LLM profile: Settings → LLM, provider **OpenAI-compatible**, base `http://localhost:8000/v1`, key `local-dgx-key`, model `Qwen/Qwen3.8-27B-FP8` (or the `qwen-local` alias).

| Variable             | Default                | Description                                                                 |
|----------------------|------------------------|-----------------------------------------------------------------------------|
| `AGENT_CANVAS_PORT`  | `8020`                 | Ingress (UI + proxied API) port                                              |
| `AGENT_CANVAS_STATE` | `./openhands-state`    | Where agent-server keeps per-conversation runtime state (conversations, workspaces, terminal history, logs). API key + LLM profile live in `~/.openhands`. |
| `VLLM_BASE_URL`      | `http://localhost:8000/v1` | Endpoint `run.sh` checks before launch (the value for the LLM profile)   |
| `VLLM_API_KEY`       | `local-dgx-key`        | API key for the vLLM preflight check                                       |

Needs Node.js ≥ 22.12 and `uv`. Ports, overrides, and troubleshooting are
documented in [`agent_canvas_native/README.md`](agent_canvas_native/README.md).

## `opencode_client/`

Drive the same `qwen-local` model from a plain terminal with
[OpenCode](https://opencode.ai) — no Docker required. Works on macOS (behind
the SSH tunnel) or directly on the DGX Spark (no tunnel, use `OPENCODE_BASE_URL=http://127.0.0.1:8000/v1`).

### Setup (once)

```bash
cd opencode_client
cp example.env .env        # then edit .env if the defaults do not fit
./scripts/install-opencode.sh
```

`install-opencode.sh` installs the OpenCode binary (official installer into
`~/.opencode/bin`, or `npm install -g opencode-ai` with `OPENCODE_INSTALL=npm`)
and generates, from `.env`:

- the provider config at `~/.config/opencode/opencode.json`
  (`OPENCODE_CONFIG_DIR` to relocate it), and
- the API key at OpenCode's auth store (`auth.json` in the XDG data dir;
  `chmod 600`). The key is never written into the tracked config.

### Use

```bash
./scripts/check-vllm.sh                 # endpoint + model + chat smoke test
./scripts/launch-opencode.sh ~/git/my_project
```

`launch-opencode.sh` re-verifies the endpoint (and prints the exact
`ssh -N -L ...` command if the tunnel is down), then runs
`opencode -m dgx-vllm/qwen-local` in the given project directory.
`opencode_client/AGENTS.md` is a template of agent instructions: copy it into
a target project's root for OpenCode to pick up project-specific rules.

### Environment Variables

| Variable                 | Default                     | Description                                                                     |
|--------------------------|-----------------------------|---------------------------------------------------------------------------------|
| `OPENCODE_PROVIDER_ID`   | `dgx-vllm`                  | Provider ID; the key in `opencode.json` and `auth.json` — all three must match   |
| `OPENCODE_PROVIDER_NAME` | `DGX Spark vLLM`            | Display name in the OpenCode model picker (quote it in `.env` — it is sourced)   |
| `OPENCODE_MODEL_ID`      | `qwen-local`                | Model ID exactly as vLLM serves it (from `GET /v1/models`)                       |
| `OPENCODE_MODEL_NAME`    | `Qwen3.8-27B-FP8`           | Model display name in the picker                                                  |
| `OPENCODE_BASE_URL`      | `http://127.0.0.1:8000/v1`  | vLLM API as reachable from THIS machine (tunnel port is derived from it)         |
| `OPENCODE_API_KEY`       | `local-dgx-key`             | Must match the vLLM server's `API_KEY`; written to the git-ignored `auth.json`   |
| `OPENCODE_CONTEXT_LENGTH`| `262144`                    | Model context window in tokens                                                    |
| `OPENCODE_OUTPUT_LENGTH` | `16384`                     | Max output tokens                                                                 |
| `OPENCODE_REQUEST_TIMEOUT` | `120`                     | Per-request curl timeout in seconds for the checks                                |
| `OPENCODE_VERSION`       | *(unset)*                   | Pin an OpenCode release for the installer; unset = latest                         |
| `OPENCODE_INSTALL`       | `official`                  | `official` (default) or `npm`                                                     |
| `OPENCODE_CONFIG_DIR`    | `~/.config/opencode`        | Where the generated `opencode.json` goes (global OpenCode config dir)             |

Generated files (`.env`, `opencode.json`, `auth.json` next to the config) are
git-ignored; only `example.env`, `opencode.example.json`, and
`auth.example.json` are tracked as templates.
