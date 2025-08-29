#!/bin/bash
set -euo pipefail

# ---------------------------
# Env / Defaults
# ---------------------------
export COMFY_APP="${COMFY_APP:-/workspace/comfywan}"
export COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
export COMFY_PORT="${COMFY_PORT:-8188}"
export OUTPUT_DIR="${OUTPUT_DIR:-/workspace/output}"
export WORKFLOWS_DIR="${WORKFLOWS_DIR:-$COMFY_APP/workflows}"
export MAX_EXECUTION_TIME="${MAX_EXECUTION_TIME:-1800}"

# Model roots
export MODELS_ROOT="/workspace/models"
export DIFF_DIR="${MODELS_ROOT}/diffusion_models"
export VAE_DIR="${MODELS_ROOT}/vae"

mkdir -p "$OUTPUT_DIR" /workspace/logs "$DIFF_DIR" "$VAE_DIR"

# ---------------------------
# Network Volume (optional) → persist models
# ---------------------------
if [ -d "/runpod-volume" ]; then
  mkdir -p /runpod-volume/models
  if [ ! -L "$MODELS_ROOT" ]; then
    rm -rf "$MODELS_ROOT" 2>/dev/null || true
    ln -s /runpod-volume/models "$MODELS_ROOT"
    mkdir -p "$DIFF_DIR" "$VAE_DIR"
    echo "[start] Linked /runpod-volume/models -> /workspace/models"
  fi
fi

echo "[start] COMFY_APP=$COMFY_APP"
echo "[start] OUTPUT_DIR=$OUTPUT_DIR"
echo "[start] MODELS_ROOT=$MODELS_ROOT"
echo "[start] DIFF_DIR=$DIFF_DIR"
echo "[start] VAE_DIR=$VAE_DIR"

# ---------------------------
# Runtime model downloads (needs HF_TOKEN + accepted licenses)
# ---------------------------
dl_if_missing() {
  local url="$1" out="$2" min_bytes="$3" header=""
  if [[ "$url" == https://huggingface.co/* ]]; then
    if [ -z "${HF_TOKEN:-}" ]; then
      echo "[start] ERROR: HF_TOKEN not set but need to download $(basename "$out")"
      exit 1
    fi
    header="--header=Authorization: Bearer ${HF_TOKEN}"
  fi

  if [ -f "$out" ]; then
    local sz; sz=$(stat -c %s "$out" || echo 0)
    if [ "$sz" -ge "$min_bytes" ]; then
      echo "[start] Found $(basename "$out") ($sz bytes) ✔"
      return 0
    else
      echo "[start] $(basename "$out") exists but too small ($sz < $min_bytes). Re-downloading…"
      rm -f "$out"
    fi
  fi

  echo "[start] Downloading $(basename "$out") ..."
  aria2c -x 4 -s 4 $header -d "$(dirname "$out")" -o "$(basename "$out")" "$url"
  local sz; sz=$(stat -c %s "$out" || echo 0)
  if [ "$sz" -lt "$min_bytes" ]; then
    echo "[start] ERROR: Downloaded $(basename "$out") is too small ($sz bytes)."
    echo "        Check HF_TOKEN and that you've accepted the repo licenses."
    exit 1
  fi
  echo "[start] Download ok: $(basename "$out") ($sz bytes)"
}

# WAN 2.2 (A14B) expected sizes (rough guards)
T2V_OUT="${DIFF_DIR}/wan2.2-t2v-a14b.pth"
I2V_OUT="${DIFF_DIR}/wan2.2-i2v-a14b.pth"
VAE_OUT="${VAE_DIR}/Wan2.1_VAE.pth"

# main pth ~11GB → guard 8GB; VAE ~508MB → guard 200MB
dl_if_missing "https://huggingface.co/Wan-AI/Wan2.2-T2V-A14B/resolve/main/models_t5_umt5-xxl-enc-bf16.pth?download=true" \
              "$T2V_OUT" $((8*1024*1024*1024))
dl_if_missing "https://huggingface.co/Wan-AI/Wan2.2-I2V-A14B/resolve/main/models_t5_umt5-xxl-enc-bf16.pth?download=true" \
              "$I2V_OUT" $((8*1024*1024*1024))
dl_if_missing "https://huggingface.co/Wan-AI/Wan2.2-T2V-A14B/resolve/main/Wan2.1_VAE.pth?download=true" \
              "$VAE_OUT" $((200*1024*1024))

# Compatibility symlinks (absorb legacy ckpt_name values)
(
  cd "$DIFF_DIR"
  ln -sf wan2.2-t2v-a14b.pth wan2.2.safetensors || true
  ln -sf wan2.2-t2v-a14b.pth wan2.2.ckpt        || true
  ln -sf wan2.2-t2v-a14b.pth wan2.2.pth         || true
  ln -sf wan2.2-i2v-a14b.pth wan2.2-i2v.safetensors || true
  ln -sf wan2.2-i2v-a14b.pth wan2.2-i2v.ckpt        || true
  ln -sf wan2.2-i2v-a14b.pth wan2.2-i2v.pth         || true
)

# ---------------------------
# Launch ComfyUI headless
# ---------------------------
cd "$COMFY_APP"
HOST_ARG="--listen $COMFY_HOST"
PORT_ARG="--port $COMFY_PORT"
OUT_ARG="--output-directory $OUTPUT_DIR"

echo "[start] Starting ComfyUI..."
python -u main.py $HOST_ARG $PORT_ARG $OUT_ARG --disable-auto-launch \
  > /workspace/logs/comfyui.log 2>&1 &
COMFY_PID=$!

# Wait for API to be up
echo "[start] Waiting for ComfyUI API on 127.0.0.1:${COMFY_PORT}..."
for i in {1..90}; do
  if curl -sf "http://127.0.0.1:${COMFY_PORT}/system_stats" >/dev/null; then
    echo "[start] ComfyUI is up."
    break
  fi
  sleep 2
done

# ---------------------------
# Launch RunPod handler
# ---------------------------
echo "[start] Launching rp_handler..."
python -u rp_handler.py

trap 'kill -TERM $COMFY_PID 2>/dev/null || true' EXIT
wait $COMFY_PID
