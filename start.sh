#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

# -------------------------- ENV DEFAULTS --------------------------
export COMFY_DIR="${COMFY_DIR:-/workspace/comfywan}"
export WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
export OUTPUT_DIR="${OUTPUT_DIR:-/workspace/output}"

export MODELS_DIR="${MODELS_DIR:-/workspace/models}"
export DIFFUSION_DIR="${DIFFUSION_DIR:-$MODELS_DIR/diffusion_models}"
export VAE_DIR="${VAE_DIR:-$MODELS_DIR/vae}"
export LORAS_DIR="${LORAS_DIR:-$MODELS_DIR/loras}"
export TEXT_ENCODERS_DIR="${TEXT_ENCODERS_DIR:-$MODELS_DIR/text_encoders}"
export CLIP_VISION_DIR="${CLIP_VISION_DIR:-$MODELS_DIR/clip_vision}"
export HF_HOME="${HF_HOME:-$MODELS_DIR/hf_cache}"   # huggingface cache

export COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
export COMFY_PORT="${COMFY_PORT:-8188}"
export PYTHON="${PYTHON:-python3}"
export RETURN_MODE="${RETURN_MODE:-base64}"
export HF_TOKEN="${HF_TOKEN:-}"

# You can extend with extra args; keep --output-directory (valid) if desired
export COMFY_ARGS="${COMFY_ARGS:---output-directory $OUTPUT_DIR}"

mkdir -p "$OUTPUT_DIR" "$MODELS_DIR" "$DIFFUSION_DIR" "$VAE_DIR" "$LORAS_DIR" \
         "$TEXT_ENCODERS_DIR" "$CLIP_VISION_DIR" "$HF_HOME"

log "[boot] start.sh begin | host=$COMFY_HOST port=$COMFY_PORT return_mode=$RETURN_MODE"

# -------------------------- CPU/GPU INFO (NON-FATAL) --------------------------
if [ "${RUNPOD_POD_TYPE:-CPU}" = "GPU" ]; then
  log "[gpu] GPU pod detected; printing CUDA info (non-fatal if missing)"
  (nvidia-smi || true)
  "$PYTHON" - <<'PY' || true
import torch
print("[gpu] torch.cuda.is_available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("[gpu] device:", torch.cuda.get_device_name(0))
PY
else
  log "[gpu] CPU endpoint detected; skipping CUDA checks."
fi

# -------------------------- COMFYUI LAUNCH --------------------------
if [ ! -d "$COMFY_DIR" ]; then
  log "[comfy] FATAL: COMFY_DIR not found at $COMFY_DIR"
  exit 1
fi

cd "$COMFY_DIR"
log "[comfy] launching ComfyUI..."
# Valid flags: --listen, --port. Avoid deprecated/unsupported --data-dir.
$PYTHON -u main.py --listen "$COMFY_HOST" --port "$COMFY_PORT" $COMFY_ARGS > /tmp/comfyui.log 2>&1 &
COMFY_PID=$!
log "[comfy] PID=$COMFY_PID | logs -> /tmp/comfyui.log"

trap 'log "[trap] TERM/INT -> stopping Comfy (PID '"$COMFY_PID"')"; kill '"$COMFY_PID"' 2>/dev/null || true; exit 0' TERM INT

# -------------------------- COMFYUI READINESS WAIT (WARN & CONTINUE) --------------------------
READY=0
log "[wait] waiting for ComfyUI /system_stats ..."
for i in {1..300}; do  # up to ~300s
  if curl -fsS "http://127.0.0.1:${COMFY_PORT}/system_stats" >/dev/null; then
    log "[wait] ComfyUI is ready."
    READY=1
    break
  fi
  sleep 1
  # If Comfy died during wait, warn and continue (handler will report not-ready)
  if ! kill -0 "$COMFY_PID" 2>/dev/null; then
    log "[warn] ComfyUI process terminated while waiting; continuing."
    break
  fi
done
if [ "$READY" -ne 1 ]; then
  log "[warn] ComfyUI not ready within time budget; handler will still start."
fi

# -------------------------- EXTRA MODEL PATHS --------------------------
# If you ship /workspace/extra_model_paths.yaml, link it so Comfy sees it.
if [ -f "$WORKSPACE_DIR/extra_model_paths.yaml" ]; then
  ln -sf "$WORKSPACE_DIR/extra_model_paths.yaml" "$COMFY_DIR/extra_model_paths.yaml"
  log "[paths] linked extra_model_paths.yaml into ComfyUI root"
fi

# -------------------------- BACKGROUND WAN DOWNLOADS (NON-BLOCKING) --------------------------
# This block runs in the background so we don't blow cold-start budgets.
if [ -n "$HF_TOKEN" ]; then
  log "[hf] starting background WAN downloads (see /tmp/bootstrap.log)"
  (
    "$PYTHON" - <<'PY'
import os, sys, traceback
from huggingface_hub import snapshot_download, hf_hub_download

tok = os.getenv("HF_TOKEN")
def safe_snapshot(repo_id, dest):
    try:
        print(f"[hf] snapshot {repo_id} -> {dest}", flush=True)
        snapshot_download(
            repo_id=repo_id,
            local_dir=dest,
            local_dir_use_symlinks=False,
            resume_download=True,
            token=tok
        )
    except Exception as e:
        print(f"[hf][warn] {repo_id} download failed: {e}", flush=True)

# Example WAN repos (uncomment if you want auto-downloads here):
# safe_snapshot("Wan-AI/Wan2.2-T2V-A14B", "/workspace/models/diffusion_models/wan2.2-t2v")
# safe_snapshot("Wan-AI/Wan2.2-I2V-A14B", "/workspace/models/diffusion_models/wan2.2-i2v")
# Optionally download a VAE if your workflow requires it:
# try:
#     p = hf_hub_download("KBlueLeaf/Wan2.1_VAE", "Wan2.1_VAE.safetensors", token=tok, local_dir="/workspace/models/vae")
#     print(f"[hf] VAE at {p}", flush=True)
# except Exception as e:
#     print(f"[hf][warn] VAE download failed: {e}", flush=True)

print("[hf] bootstrap complete", flush=True)
PY
  ) >> /tmp/bootstrap.log 2>&1 &
  disown || true
else
  log "[hf] HF_TOKEN not set; skipping WAN downloads."
fi

# -------------------------- WAN CHECKPOINT ALIASES --------------------------
# Prefer linking the *.safetensors.index.json (sharded) to Comfy's checkpoints dir.
mkdir -p "$COMFY_DIR/models/checkpoints"

link_wan_aliases_once() {
  local t2v_idx i2v_idx t2v_one i2v_one
  t2v_idx="$(find "$DIFFUSION_DIR/wan2.2-t2v" -type f -name '*.safetensors.index.json' 2>/dev/null | head -n1 || true)"
  i2v_idx="$(find "$DIFFUSION_DIR/wan2.2-i2v" -type f -name '*.safetensors.index.json' 2>/dev/null | head -n1 || true)"

  if [ -n "$t2v_idx" ]; then
    ln -sf "$t2v_idx" "$COMFY_DIR/models/checkpoints/wan2.2-t2v.safetensors.index.json"
    log "[paths] T2V index alias -> $COMFY_DIR/models/checkpoints/wan2.2-t2v.safetensors.index.json"
  else
    # fallback: any single large .safetensors (if a monolith exists)
    t2v_one="$(find "$DIFFUSION_DIR/wan2.2-t2v" -type f -name '*.safetensors' ! -name '*.index.safetensors' 2>/dev/null | head -n1 || true)"
    if [ -n "$t2v_one" ]; then
      ln -sf "$t2v_one" "$COMFY_DIR/models/checkpoints/wan2.2-t2v.safetensors"
      log "[paths] T2V single-file alias -> $COMFY_DIR/models/checkpoints/wan2.2-t2v.safetensors"
    fi
  fi

  if [ -n "$i2v_idx" ]; then
    ln -sf "$i2v_idx" "$COMFY_DIR/models/checkpoints/wan2.2-i2v.safetensors.index.json"
    log "[paths] I2V index alias -> $COMFY_DIR/models/checkpoints/wan2.2-i2v.safetensors.index.json"
  else
    i2v_one="$(find "$DIFFUSION_DIR/wan2.2-i2v" -type f -name '*.safetensors' ! -name '*.index.safetensors' 2>/dev/null | head -n1 || true)"
    if [ -n "$i2v_one" ]; then
      ln -sf "$i2v_one" "$COMFY_DIR/models/checkpoints/wan2.2-i2v.safetensors"
      log "[paths] I2V single-file alias -> $COMFY_DIR/models/checkpoints/wan2.2-i2v.safetensors"
    fi
  fi
}

# Run once now…
link_wan_aliases_once

# …and briefly watch in background for late-arriving shards (e.g., during first pull)
(
  for _ in {1..120}; do  # ~10 minutes max
    link_wan_aliases_once
    sleep 5
  done
) >> /tmp/alias-watch.log 2>&1 & disown || true
log "[paths] alias watcher running (logs -> /tmp/alias-watch.log)"

# -------------------------- START HANDLER (PID1) --------------------------
cd "$WORKSPACE_DIR"
log "[handler] launching rp_handler.py as PID1 (RETURN_MODE=$RETURN_MODE)"
exec $PYTHON -u "$WORKSPACE_DIR/rp_handler.py"
