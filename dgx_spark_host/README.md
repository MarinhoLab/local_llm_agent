# DGX Spark host stacks

One self-contained stack per model — each folder holds its own `Dockerfile`,
`entrypoint.sh`, `compose.yml`, and `README.md`, and stacks share no code or
parameters. All bind port 8000, so run only ONE at a time on the Spark.

## The stack

| Stack | Serves | Run | Served alias |
|---|---|---|---|
| [`qwen38-flash-next-fp4/`](qwen38-flash-next-fp4/) | `nvidia/Qwen3.8-Flash-Next-FP4-Local` (QAD NVFP4/MXFP8 of the 125B MoE `Qwen3.8-Flash-Next`, ~96 GiB) on the B12X image | `cd qwen38-flash-next-fp4 && docker compose up --build` | `qwen-local` |

The stack's README documents its env vars, defaults, and tuning notes. The
macOS-side clients (the retired client or OpenCode — see `../retired-stack/`
and `../opencode_native/`) reach the running stack over the SSH tunnel on port
8000 and use the served alias — `qwen-local`, so the client configuration
never changes.

## Adding another model

Copy an existing stack folder and adjust its `MODEL_NAME`,
`GPU_MEMORY_UTILIZATION` and README: the layout is deliberately duplicated
rather than shared, so a new checkpoint never perturbs the tuned values of
another one. Stop the running stack first — every stack binds port 8000.
