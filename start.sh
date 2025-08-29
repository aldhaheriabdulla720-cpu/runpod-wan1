#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf "[start] %s\n" "$*" >&2; }

# ---------- env sanity ----------
: "${COMFY_APP:?COMFY_APP is required (folder with ComfyUI main.py)}}"
: "${COMFY_HOST:=0.0.0.0}"
: "${COMFY_PORT:=8188}"
: "${COMFY_DATA_DIR:=/workspace}"
: "${COMFY_ARGS:=--disable-auto-launch}"
: "${RUNPOD_HANDLER_PATH:=/workspace/rp_handler.py}"

export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"
export HF_HOME="${HF_HOME:-/workspace/.cache/huggingface}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-$HF_HOME/transformers}"
export TORCH_HOME="${TORCH_HOME:-/workspace/.cache/torch}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/workspace/.cache}"

# Make sure all directories exist, including /workspace/output
mkdir -p "$COMFY_DATA_DIR/output" "$HF_HOME" "$TRANSFORMERS_CACHE" "$TORCH_HOME" "$XDG_CACHE_HOME" /tmp

# ---------- launch ComfyUI in background ----------
log "Starting ComfyUI from $COMFY_APP ..."
cd "$COMFY_APP"

HOST_ARG=(--listen "$COMFY_HOST")
PORT_ARG=(--port "$COMFY_PORT")
OUTPUT_ARG=(--output-directory "$COMFY_DATA_DIR/output")

echo "[start] ComfyUI launching..." > /tmp/comfyui.log
python3 main.py "${HOST_ARG[@]}" "${PORT_ARG[@]}" "${OUTPUT_ARG[@]}" $COMFY_ARGS >> /tmp/comfyui.log 2>&1 &
COMFY_PID=$!
log "ComfyUI PID = $COMFY_PID"

# Clean up gracefully on container stop
cleanup() {
  log "Shutting down (SIGTERM)."
  kill -TERM "$COMFY_PID" 2>/dev/null || true
  wait "$COMFY_PID" 2>/dev/null || true
}
trap cleanup EXIT

# ---------- wait for readiness ----------
log "Waiting for ComfyUI to listen on :$COMFY_PORT ..."
RETRIES=120
until curl -sSf "http://127.0.0.1:${COMFY_PORT}/" >/dev/null 2>&1; do
  ((RETRIES--)) || { 
    log "ComfyUI did not become ready. Dumping last 200 log lines:"
    tail -n 200 /tmp/comfyui.log || true
    exit 1
  }
  sleep 1
done
log "ComfyUI is up on http://127.0.0.1:${COMFY_PORT}"

# Optional: background-tail the Comfy log for easy debugging in RunPod logs
( tail -n +1 -F /tmp/comfyui.log 2>/dev/null | sed -u 's/^/[comfy] /' ) &

# ---------- start RunPod handler in foreground ----------
if [[ -f "$RUNPOD_HANDLER_PATH" ]]; then
  log "Starting RunPod serverless handler: $RUNPOD_HANDLER_PATH"
  exec python3 -m runpod --handler-path "$RUNPOD_HANDLER_PATH"
else
  log "ERROR: RUNPOD_HANDLER_PATH not found at $RUNPOD_HANDLER_PATH"
  exit 2
fi
