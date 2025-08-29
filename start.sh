#!/usr/bin/env bash
set -euo pipefail

# Prefer a Network Volume if present (keeps models between cold starts)
if [ -d "/runpod-volume" ]; then
  echo "[boot] Using RunPod network volume at /runpod-volume"
  rm -rf /workspace && ln -s /runpod-volume /workspace
  mkdir -p /workspace/comfywan
else
  echo "[boot] No network volume; using image filesystem at /workspace"
  mkdir -p /workspace/comfywan
fi

# Nicer logs & HF cache
export PYTHONUNBUFFERED=1
export HF_HOME="/workspace/.cache/huggingface"

# Make sure extra_model_paths.yaml exists in the Comfy root (where we cloned it)
if [ ! -f /workspace/comfywan/extra_model_paths.yaml ] && [ -f /extra_model_paths.yaml ]; then
  cp /extra_model_paths.yaml /workspace/comfywan/extra_model_paths.yaml || true
fi

# Force ComfyUI-Manager offline to avoid git during serverless boots
export COMFYUI_MANAGER_CONFIG=/workspace/comfywan/user/default/ComfyUI-Manager/config.ini
mkdir -p "$(dirname "$COMFYUI_MANAGER_CONFIG")"
grep -q '^network_mode' "$COMFYUI_MANAGER_CONFIG" 2>/dev/null \
  && sed -i 's/^network_mode *=.*/network_mode = offline/' "$COMFYUI_MANAGER_CONFIG" \
  || printf "[default]\nnetwork_mode = offline\n" > "$COMFYUI_MANAGER_CONFIG"

# Start ComfyUI headless
echo "[boot] Starting ComfyUI on 127.0.0.1:3000"
python -u /workspace/comfywan/main.py \
  --port 3000 \
  --disable-auto-launch \
  --disable-metadata \
  --base-directory /workspace/comfywan \
  --verbose INFO \
  --log-stdout \
  >/workspace/comfyui.log 2>&1 &

# Start the RunPod handler (talks to ComfyUI over 127.0.0.1:3000)
python -u /rp_handler.py
