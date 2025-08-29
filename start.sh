#!/bin/bash
set -e

# ---------------------------
# Environment defaults
# ---------------------------
export COMFY_APP=${COMFY_APP:-/workspace/comfywan}
export COMFY_HOST=${COMFY_HOST:-0.0.0.0}
export COMFY_PORT=${COMFY_PORT:-8188}
export OUTPUT_DIR=${OUTPUT_DIR:-/workspace/output}
export RETURN_MODE=${RETURN_MODE:-base64}
export WORKFLOWS_DIR=${WORKFLOWS_DIR:-$COMFY_APP/workflows}
export MAX_EXECUTION_TIME=${MAX_EXECUTION_TIME:-1800}

mkdir -p "$OUTPUT_DIR" /workspace/logs

# ---------------------------
# Launch ComfyUI headless
# ---------------------------
cd "$COMFY_APP"

HOST_ARG="--listen $COMFY_HOST"
PORT_ARG="--port $COMFY_PORT"
OUT_ARG="--output-directory $OUTPUT_DIR"
ARGS="--disable-auto-launch"

echo "[start] Starting ComfyUI..."
python main.py $HOST_ARG $PORT_ARG $OUT_ARG $ARGS > /tmp/comfyui.log 2>&1 &
COMFY_PID=$!

# ---------------------------
# Wait for ComfyUI API
# ---------------------------
echo "[start] Waiting for ComfyUI API..."
for i in {1..60}; do
  if curl -s "http://127.0.0.1:$COMFY_PORT" >/dev/null 2>&1; then
    echo "[start] ComfyUI is up on port $COMFY_PORT"
    break
  fi
  sleep 2
done

# ---------------------------
# Launch RunPod handler
# ---------------------------
echo "[start] Launching rp_handler..."
python rp_handler.py

# ---------------------------
# Cleanup
# ---------------------------
trap 'kill -TERM $COMFY_PID 2>/dev/null || true' EXIT
wait $COMFY_PID
