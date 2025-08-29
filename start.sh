#!/usr/bin/env bash
set -euo pipefail

echo "[boot] starting worker…"

# ---------- Paths ----------
APP_DIR="/workspace"
COMFY_DIR="${APP_DIR}/comfywan"
VOLUME_DIR="/runpod-volume"   # RunPod network volume (if mounted)

# ---------- If a network volume is mounted, point caches there ----------
if [[ -d "${VOLUME_DIR}" ]]; then
  echo "[boot] network volume detected at ${VOLUME_DIR}"
  export HF_HOME="${VOLUME_DIR}/hf"
  export TRANSFORMERS_CACHE="${HF_HOME}/transformers"
  export TORCH_HOME="${VOLUME_DIR}/torch"
  export WAN_CACHE="${VOLUME_DIR}/wan"
  export TOKENIZERS_PARALLELISM=false
  export HF_HUB_ENABLE_HF_TRANSFER=1

  mkdir -p "${HF_HOME}/transformers" "${TORCH_HOME}" "${WAN_CACHE}" || true

  # ComfyUI extra model paths -> point at volume so weights persist
  mkdir -p /root/.config/ComfyUI
  cat > /root/.config/ComfyUI/extra_model_paths.yaml <<'YAML'
checkpoints: [/runpod-volume/wan]
vae:         [/runpod-volume/vae]
clip:        [/runpod-volume/clip]
loras:       [/runpod-volume/lora]
YAML
else
  echo "[boot] no network volume; using image-local caches"
  export HF_HOME="${APP_DIR}/.cache/huggingface"
  export TRANSFORMERS_CACHE="${HF_HOME}/transformers"
  export TORCH_HOME="${APP_DIR}/.cache/torch"
  export WAN_CACHE="${APP_DIR}/wan"
  export TOKENIZERS_PARALLELISM=false
  export HF_HUB_ENABLE_HF_TRANSFER=1

  mkdir -p "${HF_HOME}/transformers" "${TORCH_HOME}" "${WAN_CACHE}" || true

  # Fallback extra model paths
  mkdir -p /root/.config/ComfyUI
  cat > /root/.config/ComfyUI/extra_model_paths.yaml <<'YAML'
checkpoints: [/workspace/wan]
vae:         [/workspace/vae]
clip:        [/workspace/clip]
loras:       [/workspace/lora]
YAML
fi

# ---------- Useful diagnostics ----------
python -V || true
echo "[boot] CUDA from base image (if present):"
command -v nvidia-smi >/dev/null && nvidia-smi || echo "(nvidia-smi not present in runtime)"

# ---------- Launch your RunPod handler ----------
echo "[boot] launching handler…"
exec python -u /rp_handler.py
