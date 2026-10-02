# DGX Spark host stacks

One self-contained stack per model — each folder has its own `Dockerfile`,
`entrypoint.sh`, `compose.yml`, and `README.md`, and they share no code or
parameters. All bind port 8000; run only ONE at a time on the Spark.

| Stack | Serves | Run | Served alias |
|---|---|---|---|
| [`qwen38-27b-nvfp4/`](qwen38-27b-nvfp4/) | `nvidia/Qwen3.8-27B-NVFP4` (NVFP4+FP8, ~22 GB) — the current default | `cd qwen38-27b-nvfp4 && docker compose up --build` | `qwen-local` |
| [`qwen38-27b-bf16/`](qwen38-27b-bf16/) | `Qwen/Qwen3.8-27B` (official BF16, ~55 GB) | `cd qwen38-27b-bf16 && docker compose up --build` | `qwen-local` |
| [`flash_ultrafast/`](flash_ultrafast/) | Qwen3.8 Flash DGX UltraFast v16b recipe (patched image, W4A16/FP8 + MTP drafter) | `cd flash_ultrafast && ./setup-upstream.sh && docker compose up --build` | `qwen-local` |

Each stack's README documents its env vars, defaults, and tuning notes.
The macOS-side clients (Agent Canvas / OpenCode) reach the running stack over
the SSH tunnel on port 8000 and use the served alias — `qwen-local`, which
all three stacks serve, so the client configuration never changes.
