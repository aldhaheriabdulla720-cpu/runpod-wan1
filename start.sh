#!/usr/bin/env bash
# Ensure this script is executable even if repo clone dropped permissions
if [ ! -x "$0" ]; then
  chmod +x "$0" || true
fi

set -euo pipefail

# ---------------------------
# Defaults (overridable via RunPod env panel)
# ---------------------------
: "${COMFY_HOST:=0.0.0.0}"
: "${COMFY_PORT:=8188}"
: "${COMFY_DATA_DIR:=/workspace}"         # data-dir for ComfyUI (outputs -> $COMFY_DATA_DIR/output)
: "${COMFY_ARGS:=--disable-auto-launch}"
: "${PYTHON:=python3}"
: "${HEALTH_RETRIES:=90}"                 # 90 * 2s = 3 minutes
: "${HEALTH_SLEEP:=2}"
: "${RP_HANDLER_TIMEOUT:=1800}"

export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"

echo "[start] COMFY_HOST=$COMFY_HOST COMFY_PORT=$COMFY_PORT DATA=$COMFY_DATA_DIR"

# ---------------------------
# Ensure base folders
# ---------------------------
mkdir -p "$COMFY_DATA_DIR" "$COMFY_DATA_DIR/output"

# Preferred network volume model layout
for d in /runpod-volume/wan /runpod-volume/vae /runpod-volume/clip /runpod-volume/unet /runpod-volume/lora; do
  mkdir -p "$d" || true
done
# Local fallbacks
mkdir -p /workspace/wan /workspace/vae /workspace/clip /workspace/unet /workspace/lora /workspace/comfywan/models/unet || true

# ---------------------------
# Configure extra model paths (includes UNET)
# ---------------------------
mkdir -p /root/.config/ComfyUI
cat > /root/.config/ComfyUI/extra_model_paths.yaml <<'YAML'
checkpoints: [/runpod-volume/wan, /workspace/wan]
vae:         [/runpod-volume/vae, /workspace/vae]
clip:        [/runpod-volume/clip, /workspace/clip]
unet:        [/runpod-volume/unet, /workspace/comfywan/models/unet, /workspace/unet]
loras:       [/runpod-volume/lora, /workspace/lora]
YAML

# ---------------------------
# Ensure ComfyUI exists at /workspace/comfywan (image clones it here)
# If missing (custom image), clone it now.
# ---------------------------
if [ ! -f "/workspace/comfywan/main.py" ]; then
  echo "[start] ComfyUI not found at /workspace/comfywan — cloning…"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /workspace/comfywan
fi

# ---------------------------
# Activate venv if exists
# ---------------------------
if [ -d "/venv" ]; then
  # shellcheck disable=SC1091
  source /venv/bin/activate
fi

# ---------------------------
# Launch ComfyUI headless
# ---------------------------
cd /workspace/comfywan

HOST_ARG="--listen $COMFY_HOST"
PORT_ARG="--port $COMFY_PORT"
DATA_ARG="--data-dir $COMFY_DATA_DIR"

echo "[start] Starting ComfyUI..."
$PYTHON main.py $HOST_ARG $PORT_ARG $DATA_ARG $COMFY_ARGS > /tmp/comfyui.log 2>&1 &
COMFY_PID=$!

# Clean up on exit
trap 'kill -TERM $COMFY_PID 2>/dev/null || true' EXIT

# ---------------------------
# Health check
# ---------------------------
HEALTH_URL="http://127.0.0.1:$COMFY_PORT/system_stats"
tries=0
until curl -sf "$HEALTH_URL" >/dev/null 2>&1; do
  tries=$((tries+1))
  if [ "$tries" -ge "$HEALTH_RETRIES" ]; then
    echo "[start][FATAL] ComfyUI failed to become healthy. Last 200 lines:"
    tail -n 200 /tmp/comfyui.log || true
    exit 1
  fi
  echo "[start] Waiting for ComfyUI ($tries/$HEALTH_RETRIES)…"
  sleep "$HEALTH_SLEEP"
done
echo "[start] ComfyUI is healthy."

# ---------------------------
# Launch RunPod handler (handler lives at /rp_handler.py)
# ---------------------------
export RP_HANDLER_TIMEOUT
echo "[start] Launching rp_handler.py"
exec $PYTHON /rp_handler.py
