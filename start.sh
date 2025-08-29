#!/usr/bin/env bash
set -euo pipefail

echo "[boot] workspace stays on image; models live on /runpod-volume if mounted"

# Create app + models dirs
mkdir -p /workspace/comfywan
mkdir -p /runpod-volume/{wan,vae,clip,lora} || true

# Logs & HF cache
export PYTHONUNBUFFERED=1
export HF_HOME="/workspace/.cache/huggingface"

# Ensure extra_model_paths points at /runpod-volume
mkdir -p /root/.config/ComfyUI
cat >/root/.config/ComfyUI/extra_model_paths.yaml <<'YAML'
checkpoints: [/runpod-volume/wan]
vae:         [/runpod-volume/vae]
clip:        [/runpod-volume/clip]
loras:       [/runpod-volume/lora]
YAML

# Optional: copy a repo-provided extra_model_paths if you keep one in repo
if [ -f /extra_model_paths.yaml ]; then
  cp -f /extra_model_paths.yaml /workspace/comfywan/extra_model_paths.yaml || true
fi

# -------------------------
# WAN 2.2 auto-download
# -------------------------
if [ "${WAN_BOOT_FETCH:-0}" = "1" ]; then
  echo "[boot] Fetching WAN models (first boot only if missing)..."

  # WAN T2V
  if [ -n "${WAN22_MODEL_URL:-}" ] && [ ! -f /runpod-volume/wan/wan2.2.pth ]; then
    aria2c -x16 -s16 -k1M -d /runpod-volume/wan -o wan2.2.pth "$WAN22_MODEL_URL"
  fi

  # VAE
  if [ -n "${VAE_URL:-}" ] && [ ! -f /runpod-volume/vae/wan_vae_b.pth ]; then
    aria2c -x16 -s16 -k1M -d /runpod-volume/vae -o wan_vae_b.pth "$VAE_URL"
  fi

  # CLIP shards (1..6)
  for i in 1 2 3 4 5 6; do
    url_var="CLIP_URL_${i}"
    fname="clip_part_${i}.safetensors"
    if [ -n "${!url_var:-}" ] && [ ! -f "/runpod-volume/clip/${fname}" ]; then
      aria2c -x16 -s16 -k1M -d /runpod-volume/clip -o "${fname}" "${!url_var}"
    fi
  done

  # Optional LoRA
  if [ -n "${LORA1_URL:-}" ] && [ ! -f /runpod-volume/lora/cinematic_vibes.safetensors ]; then
    aria2c -x16 -s16 -k1M -d /runpod-volume/lora -o cinematic_vibes.safetensors "$LORA1_URL"
  fi
fi

echo "[boot] WAN models present (if any):"
ls -lh /runpod-volume/wan /runpod-volume/vae /runpod-volume/clip /runpod-volume/lora 2>/dev/null || true

# Force ComfyUI-Manager offline to avoid git on boot
export COMFYUI_MANAGER_CONFIG=/workspace/comfywan/user/default/ComfyUI-Manager/config.ini
mkdir -p "$(dirname "$COMFYUI_MANAGER_CONFIG")"
if [ -f "$COMFYUI_MANAGER_CONFIG" ]; then
  sed -i 's/^network_mode *=.*/network_mode = offline/' "$COMFYUI_MANAGER_CONFIG" || true
else
  printf "[default]\nnetwork_mode = offline\n" > "$COMFYUI_MANAGER_CONFIG"
fi

# Start ComfyUI headless (code lives in image at /workspace/comfywan)
echo "[boot] Starting ComfyUI on 127.0.0.1:3000"
python -u /workspace/comfywan/main.py \
  --port 3000 \
  --disable-auto-launch \
  --disable-metadata \
  --base-directory /workspace/comfywan \
  --verbose INFO \
  --log-stdout \
  >/workspace/comfyui.log 2>&1 &

# RunPod handler (talks to 127.0.0.1:3000)
python -u /rp_handler.py
