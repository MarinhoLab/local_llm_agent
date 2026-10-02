#!/usr/bin/env bash
# setup-upstream.sh — ONE-TIME Spark-side preparation for the Qwen3.8 Flash
# DGX UltraFast (v16b) configuration.
#
# This does the heavy lifting the upstream recipe requires, by delegating to
# the upstream (Apache-2.0) build scripts rather than vendoring them here:
#   1. clone https://github.com/dime-online/qwen3.8-Flash-DGX-UltraFast
#   2. install tooling (hf CLI, jq, md5sum/sha256sum)
#   3. download the pinned public checkpoint (~27 GB) + FP8 PLE table
#   4. build the patched vLLM image (iter6c -> iter6d)
#   5. build the T80 dense-MTP drafter directory (~4.8 GB of new shards)
#   6. install the 65,536-id draft vocabulary
#
# Total downloads are ~135 GB; expect tens of minutes to a few hours on the
# Spark. Everything is cached under $MODELS_ROOT and the upstream clone.
#
# Run it from this directory. Use SKIP_* to bypass steps you already did:
#   SKIP_CLONE=1 SKIP_DOWNLOAD=1 ./setup-upstream.sh
#
# After it finishes, serve with:  docker compose -f compose.yml up --build

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-dime-online/qwen3.8-Flash-DGX-UltraFast}"
CLONE_DIR="${CLONE_DIR:-$HOME/qwen3.8-Flash-DGX-UltraFast}"
MODELS_ROOT="${MODELS_ROOT:-$HOME/models}"
VOCAB_CACHE="$HOME/.cache/qwen38-v16b"

BASE_REPO="${MODELS_ROOT%/}/Qwen3.8-Flash-Next-W4A16-AutoRound-hybrid"
TABLE_REPO="${MODELS_ROOT%/}/ple-table-fp8"
BASE_REV="${BASE_REV:-8b82f0b7abe3d1150a7827d298c75e86267636ae}"
TABLE_REV="${TABLE_REV:-50511b0a41aa1d34b8beb7e5d4bb06a0b650dc14}"
IMAGE_TAG="${IMAGE_TAG:-qwen38-flash-dgx:iter6d-20260910}"

log()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1 (install it and re-run)" >&2; exit 2; }; }

# --- 0. tooling -------------------------------------------------------------
need git
need docker
log "Checking tooling"
for t in md5sum sha256sum; do
  command -v "$t" >/dev/null 2>&1 || warn "$t not found (upstream build scripts use it)"
done
if ! docker run --rm alpine true >/dev/null 2>&1; then
  echo "docker cannot run containers — fix the NVIDIA/container setup first" >&2; exit 2
fi

# The downloads use the huggingface_hub CLI. Prefer an existing `hf`;
# otherwise install it into a venv next to the upstream clone.
if command -v hf >/dev/null 2>&1; then
  HF_BIN="hf"
elif command -v python3 >/dev/null 2>&1; then
  mkdir -p "$CLONE_DIR"
  python3 -m venv "$CLONE_DIR/.venv"
  # shellcheck disable=SC1091
  . "$CLONE_DIR/.venv/bin/activate"
  pip install --quiet --upgrade huggingface_hub
  HF_BIN="hf"
else
  echo "python3 is required for the downloads" >&2; exit 2
fi
command -v jq >/dev/null 2>&1 || warn "jq not installed (only needed if you override SPEC_EXTRA)"

# --- 1. clone the upstream repo ---------------------------------------------
log "Cloning upstream recipe"
if [ "${SKIP_CLONE:-0}" = "1" ]; then
  warn "SKIP_CLONE=1 — assuming $CLONE_DIR exists"
else
  [ -d "$CLONE_DIR/.git" ] || git clone "https://github.com/$UPSTREAM_REPO" "$CLONE_DIR"
  git -C "$CLONE_DIR" fetch origin main && git -C "$CLONE_DIR" checkout main
fi
[ -f "$CLONE_DIR/recipe/config/v16b/serve.sh" ] || { echo "upstream layout not found at $CLONE_DIR" >&2; exit 2; }

# --- 2. downloads (~135 GB) --------------------------------------------------
log "Downloading pinned checkpoint + PLE table"
if [ "${SKIP_DOWNLOAD:-0}" = "1" ]; then
  warn "SKIP_DOWNLOAD=1 — assuming checkpoint + PLE table exist under $MODELS_ROOT"
else
  for pair in "$BASE_REPO:$BASE_REPO:$BASE_REV" "$TABLE_REPO:$TABLE_REPO:$TABLE_REV"; do
    local_dir="${pair%%:*}"; rest="${pair#*:}"; repo="${rest%%:*}"; rev="${rest#*:}"
    mkdir -p "$local_dir"
    echo "  downloading $repo @ $rev -> $local_dir"
    "$HF_BIN" download "$repo" --revision "$rev" --local-dir "$local_dir"
  done
fi

# --- 3. build the patched image ----------------------------------------------
log "Building patched vLLM image ($IMAGE_TAG)"
if [ "${SKIP_IMAGE:-0}" = "1" ]; then
  warn "SKIP_IMAGE=1 — assuming $IMAGE_TAG exists"
else
  bash "$CLONE_DIR/recipe/build/image/build.sh" --run
fi

# --- 4. build the T80 dense-MTP drafter directory ----------------------------
log "Building T80 dense-MTP drafter directory"
if [ "${SKIP_MODEL:-0}" = "1" ]; then
  warn "SKIP_MODEL=1 — assuming the mtpdense-g32 directory exists"
else
  env MODELS_ROOT="$MODELS_ROOT" IMAGE="$IMAGE_TAG" \
    bash "$CLONE_DIR/recipe/build/model/build.sh" --run
fi

# --- 5. install the 65,536-id draft vocabulary -------------------------------
log "Installing draft vocabulary"
mkdir -p "$VOCAB_CACHE"
vocab="$VOCAB_CACHE/draft-vocab-ids-K65536.txt"
if [ -r "$vocab" ] && [ "$(wc -l < "$vocab")" -eq 65536 ]; then
  echo "  already installed at $vocab"
else
  tmp="$(mktemp "${vocab}.XXXXXX")"
  gzip -dc "$CLONE_DIR/recipe/config/v16b/draft-vocab-ids-K65536.txt.gz" > "$tmp"
  [ "$(wc -l < "$tmp")" -eq 65536 ] || { rm -f "$tmp"; echo "draft vocab has the wrong length" >&2; exit 1; }
  mv "$tmp" "$vocab"
  echo "  installed $vocab"
fi

# --- 6. verify ---------------------------------------------------------------
log "Verifying prepared assets"
docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 || { echo "image $IMAGE_TAG missing" >&2; exit 1; }
for d in "$BASE_REPO" "$TABLE_REPO"; do
  [ -d "$d" ] || { echo "missing directory: $d" >&2; exit 1; }
done
[ -r "$vocab" ] || { echo "missing draft vocab: $vocab" >&2; exit 1; }

log "Setup complete"
cat <<EOF
The v16b assets are in place:
  image : $IMAGE_TAG
  model : $BASE_REPO
  table : $TABLE_REPO
  vocab : $vocab

Serve it (same port as the other configurations — stop those first):
  cd "$(cd "$(dirname "$0")" && pwd)"
  docker compose -f compose.yml up --build
  curl http://localhost:8000/v1/models
EOF
