#!/usr/bin/env bash
set -euo pipefail

echo "[boot] starting worker…"

APP_DIR="/workspace"
COMFY_DIR="${APP_DIR}/comfywan"
VOLUME_DIR="/runpod-volume"

# -------- Cache dirs (same as before) --------
if [[ -d "${VOLUME_DIR}" ]]; then
  echo "[boot] network volume detected at ${VOLUME_DIR}"
  export HF_HOME="${VOLUME_DIR}/hf"
  export TRANSFORMERS_CACHE="${HF_HOME}/transformers"
  export TORCH_HOME="${VOLUME_DIR}/torch"
  export WAN_CACHE="${VOLUME_DIR}/wan"
else
  echo "[boot] no network volume; using image-local caches"
  export HF_HOME="${APP_DIR}/.cache/huggingface"
  export TRANSFORMERS_CACHE="${HF_HOME}/transformers"
  export TORCH_HOME="${APP_DIR}/.cache/torch"
  export WAN_CACHE="${APP_DIR}/wan"
fi
export TOKENIZERS_PARALLELISM=false
export HF_HUB_ENABLE_HF_TRANSFER=1
mkdir -p "${TRANSFORMERS_CACHE}" "${TORCH_HOME}" "${WAN_CACHE}" || true

# ComfyUI extra model paths (same mapping you had)
mkdir -p /root/.config/ComfyUI
cat > /root/.config/ComfyUI/extra_model_paths.yaml <<'YAML'
checkpoints: [/runpod-volume/wan, /workspace/wan]
vae:         [/runpod-volume/vae, /workspace/vae]
clip:        [/runpod-volume/clip, /workspace/clip]
loras:       [/runpod-volume/lora, /workspace/lora]
YAML

python -V || true
command -v nvidia-smi >/dev/null && nvidia-smi || echo "(nvidia-smi not present in runtime)"

# -------- Launch ComfyUI headless --------
echo "[boot] starting ComfyUI headless…"
python "${COMFY_DIR}/main.py" --disable-auto-launch --listen 127.0.0.1 --port 3000 &

# Wait for API to come up quickly
echo "[boot] waiting for ComfyUI API…"
for i in {1..120}; do
  if curl -sf "http://127.0.0.1:3000/" >/dev/null; then
    echo "[boot] ComfyUI API is up."
    break
  fi
  sleep 0.5
done

# -------- Launch RunPod handler --------
echo "[boot] launching handler…"
exec python -u /rp_handler.py
