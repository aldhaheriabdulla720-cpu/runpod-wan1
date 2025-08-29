#!/usr/bin/env bash
# start.sh — RunPod-safe launcher for ComfyUI + WAN 2.2
# - Starts ComfyUI + handler immediately (so healthchecks pass)
# - Downloads WAN 2.2 (T2V/I2V) + VAE in the background with huggingface_hub
# - Robust HF token handling (no empty "Bearer" header issues)
# - Clean shutdown on SIGTERM/SIGINT

set -u  # (no -e; we handle errors so the pod doesn't crash-loop)

# ---------------------------
# Defaults / ENV
# ---------------------------
export COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
export COMFY_PORT="${COMFY_PORT:-8188}"
export OUTPUT_DIR="${OUTPUT_DIR:-/workspace/output}"
export WORKFLOWS_DIR="${WORKFLOWS_DIR:-/workspace/comfywan/workflows}"
export HF_TOKEN="${HF_TOKEN:-}"                     # may be injected by RunPod secret
export HUGGINGFACE_HUB_TOKEN="${HUGGINGFACE_HUB_TOKEN:-$HF_TOKEN}"

# Models layout
export MODELS_ROOT="/workspace/models"
export DIFF_DIR="${MODELS_ROOT}/diffusion_models"
export VAE_DIR="${MODELS_ROOT}/vae"

mkdir -p "$OUTPUT_DIR" "$DIFF_DIR" "$VAE_DIR"

# Quick visibility (does not print token value)
echo "[debug] HF_TOKEN present? $([ -n "${HF_TOKEN}" ] && echo yes || echo no)"
echo "[debug] HUGGINGFACE_HUB_TOKEN present? $([ -n "${HUGGINGFACE_HUB_TOKEN}" ] && echo yes || echo no)"

# Optional runtime whoami check (non-fatal)
python - <<'PY' >/tmp/hf_whoami.log 2>&1 || true
import os
from huggingface_hub import HfApi
tok = os.environ.get("HUGGINGFACE_HUB_TOKEN") or os.environ.get("HF_TOKEN") or ""
if tok.startswith("hf_"):
    try:
        who = HfApi().whoami(tok)
        print("[debug] HF whoami OK:", who.get("name") or who.get("email") or who)
    except Exception as e:
        print("[WARN] HF whoami failed:", e)
else:
    print("[debug] Skipping whoami; no hf_ token")
PY

# ---------------------------
# Start ComfyUI (background)
# ---------------------------
cd /workspace/comfywan
echo "[start] Launching ComfyUI on ${COMFY_HOST}:${COMFY_PORT} ..."
python main.py \
  --listen "${COMFY_HOST}" \
  --port "${COMFY_PORT}" \
  --output-directory "${OUTPUT_DIR}" \
  > /tmp/comfyui.log 2>&1 &
COMFY_PID=$!
echo "[ok] ComfyUI PID=${COMFY_PID}"

# ---------------------------
# Start RunPod handler (background)
# ---------------------------
echo "[start] Launching rp_handler ..."
python rp_handler.py > /tmp/handler.log 2>&1 &
HANDLER_PID=$!
echo "[ok] Handler PID=${HANDLER_PID}"

# ---------------------------
# Background model bootstrap
# ---------------------------
(
python - <<'PY'
from huggingface_hub import snapshot_download, hf_hub_download
import os, time, sys

token = os.environ.get("HUGGINGFACE_HUB_TOKEN") or os.environ.get("HF_TOKEN") or None
root  = "/workspace/models"
diff  = os.path.join(root, "diffusion_models")
vae   = os.path.join(root, "vae")
os.makedirs(diff, exist_ok=True); os.makedirs(vae, exist_ok=True)

def grab():
    # WAN 2.2 — download full snapshots (sharded safetensors)
    print("[bootstrap] Downloading Wan-AI/Wan2.2-T2V-A14B ...", flush=True)
    snapshot_download("Wan-AI/Wan2.2-T2V-A14B",
                      local_dir=os.path.join(diff,"wan2.2-t2v"),
                      token=token, max_retries=3, resume_download=True)
    print("[bootstrap] Downloading Wan-AI/Wan2.2-I2V-A14B ...", flush=True)
    snapshot_download("Wan-AI/Wan2.2-I2V-A14B",
                      local_dir=os.path.join(diff,"wan2.2-i2v"),
                      token=token, max_retries=3, resume_download=True)
    # VAE file
    print("[bootstrap] Downloading Wan2.1_VAE.pth ...", flush=True)
    hf_hub_download("Wan-AI/Wan2.2-T2V-A14B", filename="Wan2.1_VAE.pth",
                    local_dir=vae, token=token)
    print("[bootstrap] WAN 2.2 downloads complete.", flush=True)

# If token is missing, skip (do NOT crash the pod)
if not token:
    print("[bootstrap] HF token missing; skipping WAN downloads (handler is live).", flush=True)
    sys.exit(0)

# Retry a few times to be resilient to transient issues
for i in range(3):
    try:
        grab(); break
    except Exception as e:
        print(f"[bootstrap] retry {i+1}/3 failed: {e}", flush=True)
        time.sleep(10)
PY
) > /tmp/bootstrap.log 2>&1 &

# ---------------------------
# Shutdown handling
# ---------------------------
cleanup() {
  echo "[stop] Stopping..."
  kill -TERM "$COMFY_PID" "$HANDLER_PID" 2>/dev/null || true
  wait "$COMFY_PID" "$HANDLER_PID" 2>/dev/null || true
  echo "[stop] Done."
}
trap cleanup TERM INT

# Keep container alive
wait
