# === GPU-friendly base (works on GPU pods; OK on CPU pods too, just larger) ===
FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

# ---- System deps ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.10 python3.10-venv python3.10-dev python3-pip \
    git curl wget ca-certificates ffmpeg \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sf /usr/bin/python3.10 /usr/bin/python \
 && ln -sf /usr/bin/python3.10 /usr/bin/python3

WORKDIR /workspace

# ---- Torch CUDA 12.1 stack ----
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cu121 \
    torch==2.4.1 torchvision==0.19.1 torchaudio==2.4.1

# ---- Core Python deps ----
RUN pip install --no-cache-dir \
    runpod==1.7.9 \
    requests==2.32.3 \
    aiohttp==3.9.5 \
    websockets==12.0 \
    huggingface_hub==0.24.6 \
    tqdm==4.66.4 \
    opencv-python-headless==4.9.0.80 \
    numpy==1.26.4 \
    pillow==10.3.0 \
    transformers==4.39.3 \
    tokenizers==0.15.2

# ---- ComfyUI ----
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /workspace/comfywan
WORKDIR /workspace/comfywan
RUN pip install --no-cache-dir -r requirements.txt || true

# ---- Back to /workspace to copy our app files ----
WORKDIR /workspace

# ENV contract (can be overridden in RunPod endpoint)
ENV RUNPOD_POD_TYPE=GPU \
    COMFY_HOST=0.0.0.0 \
    COMFY_PORT=8188 \
    COMFY_ARGS="--output-directory /workspace/output" \
    RETURN_MODE=base64 \
    MODEL_DIR=/workspace/models \
    DIFFUSION_DIR=/workspace/models/diffusion_models \
    VAE_DIR=/workspace/models/vae \
    TEXT_ENCODERS_DIR=/workspace/models/text_encoders \
    CLIP_VISION_DIR=/workspace/models/clip_vision \
    LORAS_DIR=/workspace/models/loras \
    WAN_T2V_REPO=Wan-AI/Wan2.2-T2V-A14B \
    WAN_I2V_REPO=Wan-AI/Wan2.2-I2V-A14B \
    WAN_VAE_FILE=Wan2.1_VAE.pth

# Copy your workflows folder (make sure it exists in your repo)
# Example: wan2.2-t2v.json, wan2.2-i2v.json, etc.
COPY workflows/ /workspace/workflows/

# Extra model paths for ComfyUI
COPY extra_model_paths.yaml /workspace/extra_model_paths.yaml

# Startup script + handler
COPY start.sh /workspace/start.sh
COPY rp_handler.py /workspace/rp_handler.py

RUN chmod +x /workspace/start.sh

# RunPod looks at the main process; keep handler foregrounded via start.sh
ENTRYPOINT ["bash", "/workspace/start.sh"]
