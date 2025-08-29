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

# Make sure extra_model_paths.yaml exists in the Comfy root
if [ ! -f /workspace/comfywan/extra_model_paths.yaml ] && [ -f /extra_model_paths.yaml ]; then
  cp /extra_model_paths.yaml /workspace/comfywan/extra_model_paths.yaml || true
fi

# -------------------------
# WAN 2.2 auto-download step
# -------------------------
echo "[boot] Ensuring WAN model dirs exist"
mkdir -p /runpod-volume/{wan,vae,clip,lora}

if [ "${WAN_BOOT_FETCH:-0}" = "1" ]; then
  echo "[boot] Checking WAN models..."

  # WAN T2V
  [ -f /runpod-volume/wan/wan2.2.pth ] || aria2c -x16 -s16 -k1M -d /runpod-volume/wan \
    -o wan2.2.pth "${WAN22_MODEL_URL:-}"

  # VAE
  [ -f /runpod-volume/vae/wan_vae_b.pth ] || aria2c -x16 -s16 -k1M -d /runpod-volume/vae \
    -o wan_vae_b.pth "${VAE_URL:-}"

  # CLIP shards
  for i in 1 2 3 4 5 6; do
    url_var="CLIP_URL_${i}"
    fname="clip_part_${i}.safetensors"
    if [ -n "${!url_var:-}" ]; then
      [ -f /runpod-volume/clip/$fname ] || aria2c -x16 -s16 -k1M -d /runpod-volume/clip \
        -o $fname "${!url_var}"
    fi
  done

  # LoRA (optional)
  if [ -n "${LORA1_URL:-}" ]; then
    [ -f /runpod-volume/lora/cinematic_vibes.safetensors ] || aria2c -x16 -s16 -k1M -d /runpod-volume/lora \
      -o cinematic_vibes.safetensors "$LORA1_URL"
  fi
fi

echo "[boot] WAN models present:"
ls -lh /runpod-volume/* || true

# Write ComfyUI extra_model_paths.yaml pointing to /runpod-volume
mkdir -p /root/.config/ComfyUI
cat >/root/.config/ComfyUI/extra_model_paths.yaml <<'YAML'
checkpoints: [/runpod-volume/wan]
vae:         [/runpod-volume/vae]
clip:        [/runpod-volume/clip]
loras:       [/runpod-volume/lora]
YAML

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
