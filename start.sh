#!/bin/bash
set -euo pipefail

# ---------------------------
# Environment
# ---------------------------
export COMFY_APP="${COMFY_APP:-/workspace/comfywan}"
export COMFY_HOST="${COMFY_HOST:-0.0.0.0}"   # bind externally
export COMFY_PORT="${COMFY_PORT:-8188}"
export OUTPUT_DIR="${OUTPUT_DIR:-/workspace/output}"
export WORKFLOWS_DIR="${WORKFLOWS_DIR:-$COMFY_APP/workflows}"
export MAX_EXECUTION_TIME="${MAX_EXECUTION_TIME:-1800}"

mkdir -p "$OUTPUT_DIR" /workspace/logs

echo "[start] COMFY_APP=$COMFY_APP"
echo "[start] OUTPUT_DIR=$OUTPUT_DIR"

# ---------------------------
# Launch ComfyUI headless
# ---------------------------
cd "$COMFY_APP"

HOST_ARG="--listen $COMFY_HOST"
PORT_ARG="--port $COMFY_PORT"
OUT_ARG="--output-directory $OUTPUT_DIR"

echo "[start] Starting ComfyUI..."
python -u main.py $HOST_ARG $PORT_ARG $OUT_ARG > /workspace/logs/comfyui.log 2>&1 &
COMFY_PID=$!

# ---------------------------
# Wait for API to be ready
# ---------------------------
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

# ---------------------------
# Cleanup
# ---------------------------
trap 'kill -TERM $COMFY_PID 2>/dev/null || true' EXIT
wait $COMFY_PID
