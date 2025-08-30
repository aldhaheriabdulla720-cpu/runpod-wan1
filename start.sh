#!/usr/bin/env bash
set -euo pipefail
# set -x   # uncomment for very verbose debug

echo "[boot] start.sh invoked (ts=$(date -Is))"

# ------------------------------------------------------------------------------
# 1. GPU sanity with retry (skip if CPU endpoint)
# ------------------------------------------------------------------------------
if [ "${RUNPOD_POD_TYPE:-CPU}" != "GPU" ]; then
  echo "[gpu] CPU endpoint detected; skipping CUDA check."
else
  GPU_WAIT_SECS="${GPU_WAIT_SECS:-300}"
  echo "[gpu] Waiting up to ${GPU_WAIT_SECS}s for CUDA..."
  END=$(( $(date +%s) + GPU_WAIT_SECS ))
  ok=0
  while [ $(date +%s) -lt $END ]; do
    echo "[gpu] nvidia-smi:"; (nvidia-smi || true)
    /usr/bin/python - <<'PY' && ok=1 && break || true
import torch, sys
print("[gpu] torch.is_available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("[gpu] device:", torch.cuda.get_device_name(0)); sys.exit(0)
sys.exit(1)
PY
    sleep 5
  done
  if [ $ok -ne 1 ]; then
    echo "[FATAL] CUDA not available after ${GPU_WAIT_SECS}s — exiting."
    exit 1
  fi
fi

# ------------------------------------------------------------------------------
# 2. Launch ComfyUI (background)
# ------------------------------------------------------------------------------
COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
COMFY_PORT="${COMFY_PORT:-8188}"
OUTPUT_DIR="${OUTPUT_DIR:-/workspace/output}"
TMP_DIR="${TMP_DIR:-/workspace/tmp}"

mkdir -p "$OUTPUT_DIR" "$TMP_DIR"
: > /tmp/comfyui.log

cd /workspace/comfywan
echo "[start] Launching ComfyUI on ${COMFY_HOST}:${COMFY_PORT} ..."
/usr/bin/python main.py \
  --listen "${COMFY_HOST}" \
  --port "${COMFY_PORT}" \
  --output-directory "${OUTPUT_DIR}" \
  --temp-directory "${TMP_DIR}" \
  2>&1 | tee -a /tmp/comfyui.log &
COMFY_PID=$!

cleanup() { echo "[stop] Stopping ComfyUI…"; kill -TERM "$COMFY_PID" 2>/dev/null || true; }
trap cleanup TERM INT

# ------------------------------------------------------------------------------
# 3. Wait for ComfyUI readiness
# ------------------------------------------------------------------------------
WAIT_URL="http://127.0.0.1:${COMFY_PORT}/system_stats"
TIMEOUT=300
echo "[wait] Waiting for ComfyUI at ${WAIT_URL} (timeout ${TIMEOUT}s)..."
START_TS=$(date +%s)
until curl -fsS "$WAIT_URL" >/dev/null 2>&1; do
  sleep 1
  NOW=$(date +%s)
  if (( NOW - START_TS > TIMEOUT )); then
    echo "[error] ComfyUI didn't start within ${TIMEOUT}s. Last 100 lines:"
    tail -n 100 /tmp/comfyui.log || true
    exit 1
  fi
done
echo "[ok] ComfyUI is READY."

# ------------------------------------------------------------------------------
# 4. Background WAN downloads
# ------------------------------------------------------------------------------
(
/usr/bin/python - <<'PY'
from huggingface_hub import snapshot_download, hf_hub_download
import os, time, sys
tok = os.environ.get("HUGGINGFACE_HUB_TOKEN") or os.environ.get("HF_TOKEN") or None
root  = "/workspace/models"
diff  = os.path.join(root, "diffusion_models")
vae   = os.path.join(root, "vae")
os.makedirs(diff, exist_ok=True); os.makedirs(vae, exist_ok=True)

def grab():
    print("[bootstrap] Downloading Wan-AI/Wan2.2-T2V-A14B ...", flush=True)
    snapshot_download("Wan-AI/Wan2.2-T2V-A14B",
                      local_dir=os.path.join(diff,"wan2.2-t2v"),
                      token=tok, max_retries=3, resume_download=True)
    print("[bootstrap] Downloading Wan-AI/Wan2.2-I2V-A14B ...", flush=True)
    snapshot_download("Wan-AI/Wan2.2-I2V-A14B",
                      local_dir=os.path.join(diff,"wan2.2-i2v"),
                      token=tok, max_retries=3, resume_download=True)
    print("[bootstrap] Downloading Wan2.1_VAE.pth ...", flush=True)
    hf_hub_download("Wan-AI/Wan2.2-T2V-A14B", filename="Wan2.1_VAE.pth",
                    local_dir=os.path.join(root, "vae"), token=tok)
    print("[bootstrap] WAN 2.2 downloads complete.", flush=True)

if not tok:
    print("[bootstrap] HF token missing; skipping WAN downloads.", flush=True); sys.exit(0)

for i in range(3):
    try:
        grab(); break
    except Exception as e:
        print(f"[bootstrap] retry {i+1}/3 failed: {e}", flush=True); time.sleep(10)
PY
) > /tmp/bootstrap.log 2>&1 &

# ------------------------------------------------------------------------------
# 5. Robust aliasing (accepts .index.json OR .safetensors)
# ------------------------------------------------------------------------------
ckpt_dir="/workspace/comfywan/models/checkpoints"; mkdir -p "${ckpt_dir}"

wait_for_any() {
  local base="$1"; shift
  local end=$(( $(date +%s) + 600 ))
  while [ $(date +%s) -lt $end ]; do
    for pat in "$@"; do
      found=$(ls -1 ${base}/${pat} 2>/dev/null | head -n 1 || true)
      if [ -n "$found" ] && [ -f "$found" ]; then
        echo "$found"; return 0
      fi
    done
    sleep 5
  done
  return 1
}

link_alias() {
  local model="$1"; local base="$2"
  local f
  f=$(wait_for_any "$base" \
      "low_noise_model/*.safetensors.index.json" \
      "high_noise_model/*.safetensors.index.json" \
      "low_noise_model/*.safetensors" \
      "high_noise_model/*.safetensors") || true
  if [ -n "$f" ]; then
    ln -sf "$f" "${ckpt_dir}/wan2.2-${model}.safetensors"
    echo "[alias] ${model^^} → ${ckpt_dir}/wan2.2-${model}.safetensors -> ${f}"
  else
    echo "[alias] WARN: No ${model^^} file found under ${base}."
  fi
}

T2V_BASE="/workspace/models/diffusion_models/wan2.2-t2v"
I2V_BASE="/workspace/models/diffusion_models/wan2.2-i2v"

link_alias "t2v" "$T2V_BASE"
link_alias "i2v" "$I2V_BASE"

if [ -f "/workspace/models/vae/Wan2.1_VAE.pth" ]; then
  mkdir -p /workspace/comfywan/models/vae
  ln -sf /workspace/models/vae/Wan2.1_VAE.pth /workspace/comfywan/models/vae/Wan2.1_VAE.pth
  echo "[alias] VAE → /workspace/comfywan/models/vae/Wan2.1_VAE.pth"
fi

# ------------------------------------------------------------------------------
# 6. Start RunPod worker
# ------------------------------------------------------------------------------
echo "[start] Starting RunPod worker…"
/usr/bin/python -u -m runpod.serverless.worker rp_handler
