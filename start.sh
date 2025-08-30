#!/usr/bin/env bash
# start.sh — robust ComfyUI + WAN bootstrap + RunPod worker

set -euo pipefail
# set -x  # uncomment for ultra-verbose shell debug

echo "[boot] start.sh invoked (ts=$(date -Is))"

# -------- ENV --------
export COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
export COMFY_PORT="${COMFY_PORT:-8188}"
export OUTPUT_DIR="${OUTPUT_DIR:-/workspace/output}"
export TMP_DIR="${TMP_DIR:-/workspace/tmp}"
export HF_TOKEN="${HF_TOKEN:-}"
export HUGGINGFACE_HUB_TOKEN="${HUGGINGFACE_HUB_TOKEN:-$HF_TOKEN}"

export MODELS_ROOT="/workspace/models"
export DIFF_DIR="${MODELS_ROOT}/diffusion_models"
export VAE_DIR="${MODELS_ROOT}/vae"
mkdir -p "$OUTPUT_DIR" "$TMP_DIR" "$DIFF_DIR" "$VAE_DIR"
: > /tmp/comfyui.log
: > /tmp/bootstrap.log

# -------- GPU sanity with retry --------
GPU_WAIT_SECS="${GPU_WAIT_SECS:-300}"
echo "[gpu] Waiting up to ${GPU_WAIT_SECS}s for CUDA..."
END=$(( $(date +%s) + GPU_WAIT_SECS ))
ok=0
while [ $(date +%s) -lt $END ]; do
  echo "[gpu] nvidia-smi:"; (nvidia-smi || true)
  /usr/bin/python - <<'PY' && ok=1 && break || true
import torch, sys
print("[gpu] torch.__version__:", torch.__version__)
print("[gpu] torch.version.cuda:", torch.version.cuda)
print("[gpu] cuda.is_available():", torch.cuda.is_available())
print("[gpu] device_count:", torch.cuda.device_count())
if torch.cuda.is_available():
    print("[gpu] device 0:", torch.cuda.get_device_name(0))
    sys.exit(0)
sys.exit(1)
PY
  sleep 5
done
if [ $ok -ne 1 ]; then
  echo "[FATAL] CUDA not available after ${GPU_WAIT_SECS}s — exiting."
  exit 1
fi

# -------- Start ComfyUI (background) --------
cd /workspace/comfywan
echo "[start] Launching ComfyUI on ${COMFY_HOST}:${COMFY_PORT} ..."
/usr/bin/python main.py \
  --listen "${COMFY_HOST}" \
  --port "${COMFY_PORT}" \
  --output-directory "${OUTPUT_DIR}" \
  --temp-directory "${TMP_DIR}" \
  2>&1 | tee -a /tmp/comfyui.log &
COMFY_PID=$!

cleanup() { echo "[stop] Stopping…"; kill -TERM "$COMFY_PID" 2>/dev/null || true; wait "$COMFY_PID" 2>/dev/null || true; echo "[stop] Done."; }
trap cleanup TERM INT

# -------- Wait for ComfyUI readiness --------
WAIT_URL="http://127.0.0.1:${COMFY_PORT}/system_stats"; TIMEOUT=300
echo "[wait] Waiting for ComfyUI at ${WAIT_URL} ..."
START_TS=$(date +%s)
until curl -fsS "$WAIT_URL" >/dev/null 2>&1; do
  sleep 1
  if (( $(date +%s) - START_TS > TIMEOUT )); then
    echo "[error] ComfyUI didn't become ready within ${TIMEOUT}s."
    tail -n 200 /tmp/comfyui.log || true
    exit 1
  fi
done
echo "[ok] ComfyUI is READY."

# -------- Background WAN downloads --------
(
/usr/bin/python - <<'PY'
from huggingface_hub import snapshot_download, hf_hub_download
import os, time
tok = os.environ.get("HUGGINGFACE_HUB_TOKEN") or os.environ.get("HF_TOKEN") or None
root  = "/workspace/models"
diff  = os.path.join(root, "diffusion_models")
vae   = os.path.join(root, "vae")
os.makedirs(diff, exist_ok=True); os.makedirs(vae, exist_ok=True)
def grab():
    print("[bootstrap] Downloading Wan2.2 repos ...", flush=True)
    snapshot_download("Wan-AI/Wan2.2-T2V-A14B", local_dir=os.path.join(diff,"wan2.2-t2v"), token=tok)
    snapshot_download("Wan-AI/Wan2.2-I2V-A14B", local_dir=os.path.join(diff,"wan2.2-i2v"), token=tok)
    hf_hub_download("Wan-AI/Wan2.2-T2V-A14B", filename="Wan2.1_VAE.pth", local_dir=vae, token=tok)
    print("[bootstrap] WAN downloads complete.", flush=True)
if tok: 
    for i in range(3):
        try: grab(); break
        except Exception as e: print(f"[bootstrap] retry {i+1}/3 failed: {e}"); time.sleep(10)
else:
    print("[bootstrap] No HF token; skipping downloads.")
PY
) > /tmp/bootstrap.log 2>&1 &

# -------- Alias checkpoints --------
ckpt_dir="/workspace/comfywan/models/checkpoints"; mkdir -p "${ckpt_dir}"
ln -sf /workspace/models/diffusion_models/wan2.2-t2v/*index.json "${ckpt_dir}/wan2.2-t2v.safetensors" 2>/dev/null || true
ln -sf /workspace/models/diffusion_models/wan2.2-i2v/*index.json "${ckpt_dir}/wan2.2-i2v.safetensors" 2>/dev/null || true
[ -f "/workspace/models/vae/Wan2.1_VAE.pth" ] && ln -sf /workspace/models/vae/Wan2.1_VAE.pth /workspace/comfywan/models/vae/Wan2.1_VAE.pth

# -------- Handler preflight --------
/usr/bin/python - <<'PY' || { echo "[FATAL] rp_handler import failed"; exit 1; }
import importlib; importlib.import_module("rp_handler"); print("[ok] rp_handler import succeeded")
PY

# -------- Start worker --------
echo "[start] Starting RunPod worker…"
/usr/bin/python -u -m runpod.serverless.worker rp_handler
