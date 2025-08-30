#!/usr/bin/env bash
set -euo pipefail

echo "[boot] start.sh invoked (ts=$(date -Is))"

# ---------------------------
# Defaults & paths
# ---------------------------
COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_ARGS="${COMFY_ARGS:---output-directory /workspace/output}"
PYTHON="${PYTHON:-/usr/bin/python}"
COMFY_DIR="/workspace/comfywan"

MODEL_DIR="${MODEL_DIR:-/workspace/models}"
DIFFUSION_DIR="${DIFFUSION_DIR:-/workspace/models/diffusion_models}"
VAE_DIR="${VAE_DIR:-/workspace/models/vae}"
TEXT_ENCODERS_DIR="${TEXT_ENCODERS_DIR:-/workspace/models/text_encoders}"
CLIP_VISION_DIR="${CLIP_VISION_DIR:-/workspace/models/clip_vision}"
LORAS_DIR="${LORAS_DIR:-/workspace/models/loras}"

WAN_T2V_REPO="${WAN_T2V_REPO:-Wan-AI/Wan2.2-T2V-A14B}"
WAN_I2V_REPO="${WAN_I2V_REPO:-Wan-AI/Wan2.2-I2V-A14B}"
WAN_VAE_FILE="${WAN_VAE_FILE:-Wan2.1_VAE.pth}"
HF_TOKEN="${HF_TOKEN:-}"

mkdir -p "$MODEL_DIR" "$DIFFUSION_DIR" "$VAE_DIR" "$TEXT_ENCODERS_DIR" "$CLIP_VISION_DIR" "$LORAS_DIR" /workspace/output
touch /tmp/bootstrap.log /tmp/comfyui.log

echo "[env] RUNPOD_POD_TYPE=${RUNPOD_POD_TYPE:-unset}"
echo "[env] COMFY_HOST=$COMFY_HOST COMFY_PORT=$COMFY_PORT"
echo "[env] MODEL_DIR=$MODEL_DIR"

# ---------------------------
# GPU sanity (skip on CPU)
# ---------------------------
if [ "${RUNPOD_POD_TYPE:-CPU}" = "GPU" ]; then
  echo "[gpu] Checking CUDA…"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi || true
  fi
  $PYTHON - <<'PY' || echo "[gpu] Torch CUDA not available; continuing anyway."
import torch, sys
print("[gpu] torch.is_available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("[gpu] device:", torch.cuda.get_device_name(0))
PY
else
  echo "[gpu] CPU endpoint detected; skipping CUDA check."
fi

# ---------------------------
# Launch ComfyUI (background)
# ---------------------------
cd "$COMFY_DIR"
HOST_ARG="--listen $COMFY_HOST"
PORT_ARG="--port $COMFY_PORT"

echo "[start] Starting ComfyUI…"
set +e
$PYTHON main.py $HOST_ARG $PORT_ARG $COMFY_ARGS > /tmp/comfyui.log 2>&1 &
COMFY_PID=$!
set -e
echo "[start] ComfyUI PID=$COMFY_PID"

# ---------------------------
# Wait for ComfyUI API
# ---------------------------
echo "[wait] Waiting for ComfyUI to be ready at http://127.0.0.1:${COMFY_PORT}/system_stats"
READY=0
for i in {1..180}; do
  if curl -fsS "http://127.0.0.1:${COMFY_PORT}/system_stats" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 1
done
if [ "$READY" -ne 1 ]; then
  echo "[wait] ComfyUI did not become ready in time. Tail of log:"
  tail -n 200 /tmp/comfyui.log || true
  exit 1
fi
echo "[wait] ComfyUI is ready."

# ---------------------------
# Background model bootstrap (WAN 2.2 + VAE)
# Using huggingface_hub to avoid fragile shell header quoting.
# ---------------------------
(
  set -e
  echo "[dl] Model bootstrap started…" | tee -a /tmp/bootstrap.log
  $PYTHON - <<PY 2>&1 | tee -a /tmp/bootstrap.log
import os, shutil
from huggingface_hub import snapshot_download, hf_hub_download

tok = os.getenv("HF_TOKEN", None)
diff_dir = os.getenv("DIFFUSION_DIR", "/workspace/models/diffusion_models")
vae_dir  = os.getenv("VAE_DIR", "/workspace/models/vae")
t2v_repo = os.getenv("WAN_T2V_REPO", "Wan-AI/Wan2.2-T2V-A14B")
i2v_repo = os.getenv("WAN_I2V_REPO", "Wan-AI/Wan2.2-I2V-A14B")
vae_file = os.getenv("WAN_VAE_FILE", "Wan2.1_VAE.pth")

os.makedirs(diff_dir, exist_ok=True)
os.makedirs(vae_dir, exist_ok=True)

def safe_snapshot(repo_id, local_dir):
    try:
        print(f"[hf] snapshot_download: {repo_id} -> {local_dir}")
        snapshot_download(repo_id=repo_id, local_dir=local_dir,
                          local_dir_use_symlinks=False, token=tok, resume_download=True)
    except Exception as e:
        print(f"[hf] WARN: snapshot failed for {repo_id}: {e}")

# WAN shards (directories include high_noise_model/low_noise_model)
safe_snapshot(t2v_repo, os.path.join(diff_dir, "wan2.2-t2v"))
safe_snapshot(i2v_repo, os.path.join(diff_dir, "wan2.2-i2v"))

# VAE from dedicated repo (don't fetch from T2V/I2V repo)
try:
    vae_path = hf_hub_download(repo_id="Wan-AI/Wan2.2-VAE", filename=vae_file, token=tok)
    dst = os.path.join(vae_dir, os.path.basename(vae_path))
    if not os.path.exists(dst):
        shutil.copy2(vae_path, dst)
    print(f"[hf] VAE ready at {dst}")
except Exception as e:
    print(f"[hf] WARN: VAE download skipped/failed: {e}")

print("[hf] Bootstrap done.")
PY
) &

# ---------------------------
# Non-blocking aliasing (avoid cold-start delays)
# ---------------------------
ckpt_dir="/workspace/comfywan/models/checkpoints"; mkdir -p "${ckpt_dir}"

try_link() {  # $1=model tag; $2=base path
  local model="$1"; local base="$2"; local f=""
  for pat in \
    "low_noise_model/*.safetensors.index.json" \
    "high_noise_model/*.safetensors.index.json" \
    "low_noise_model/*.safetensors" \
    "high_noise_model/*.safetensors"
  do
    f=$(ls -1 ${base}/${pat} 2>/dev/null | head -n 1 || true)
    [ -n "$f" ] && break
  done
  if [ -n "$f" ]; then
    ln -sf "$f" "${ckpt_dir}/wan2.2-${model}.safetensors"
    echo "[alias] ${model^^} -> ${ckpt_dir}/wan2.2-${model}.safetensors"
  else
    echo "[alias] ${model^^} not present yet; skipping."
  fi
}

T2V_BASE="${DIFFUSION_DIR}/wan2.2-t2v"
I2V_BASE="${DIFFUSION_DIR}/wan2.2-i2v"
try_link "t2v" "$T2V_BASE"
try_link "i2v" "$I2V_BASE"

# Watcher to re-link when shards finish
(
  for i in {1..180}; do
    try_link "t2v" "$T2V_BASE"
    try_link "i2v" "$I2V_BASE"
    sleep 2
  done
) >/tmp/alias-watch.log 2>&1 &

# ---------------------------
# Start handler in foreground (so health checks pass)
# ---------------------------
echo "[handler] Starting rp_handler.py…"
trap 'echo "[shutdown] SIGTERM"; kill -TERM ${COMFY_PID} 2>/dev/null || true; wait ${COMFY_PID} 2>/dev/null || true' TERM INT
exec $PYTHON -u /workspace/rp_handler.py

