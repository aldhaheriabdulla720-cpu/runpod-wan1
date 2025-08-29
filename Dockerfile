FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
# Set at RunPod → Endpoint → Environment Variables
ENV HF_TOKEN=${HF_TOKEN}

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.10 python3.10-venv python3.10-dev python3-pip \
    git curl aria2 wget ca-certificates ffmpeg \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sf /usr/bin/python3.10 /usr/bin/python \
 && ln -sf /usr/bin/python3.10 /usr/bin/python3

WORKDIR /workspace

# --- PyTorch (CUDA 12.1 build) ---
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cu121 \
    torch==2.4.1 torchvision==0.19.1 torchaudio==2.4.1

# --- Clone ComfyUI ---
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /workspace/comfywan
WORKDIR /workspace/comfywan

# Safe pins for dependencies (avoid build failures)
RUN pip install --no-cache-dir \
    numpy==1.26.4 \
    pillow==10.3.0 \
    transformers==4.39.3 \
    tokenizers==0.15.2 \
 && pip install --no-cache-dir -r requirements.txt

# --- Custom Nodes ---
WORKDIR /workspace/comfywan/custom_nodes
RUN git clone --depth=1 https://github.com/city96/ComfyUI-GGUF.git
RUN git clone --depth=1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git
RUN pip install --no-cache-dir imageio-ffmpeg tqdm
RUN git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager.git

# Back to comfy root
WORKDIR /workspace/comfywan

# --- Runtime deps ---
RUN pip install --no-cache-dir runpod==1.7.9 requests websockets safetensors

# --- WAN 2.2 models (requires HF token) ---
# We download the exact filenames shown on the HF pages you shared:
# - models_t5_umt5-xxl-enc-bf16.pth (main checkpoint)
# - Wan2.1_VAE.pth (VAE)
RUN mkdir -p /workspace/models/diffusion_models /workspace/models/vae && \
    aria2c -x 4 -s 4 \
      --header="Authorization: Bearer ${HF_TOKEN}" \
      -d /workspace/models/diffusion_models \
      -o wan2.2-t2v-a14b.pth \
      "https://huggingface.co/Wan-AI/Wan2.2-T2V-A14B/resolve/main/models_t5_umt5-xxl-enc-bf16.pth?download=true" && \
    aria2c -x 4 -s 4 \
      --header="Authorization: Bearer ${HF_TOKEN}" \
      -d /workspace/models/diffusion_models \
      -o wan2.2-i2v-a14b.pth \
      "https://huggingface.co/Wan-AI/Wan2.2-I2V-A14B/resolve/main/models_t5_umt5-xxl-enc-bf16.pth?download=true" && \
    aria2c -x 4 -s 4 \
      --header="Authorization: Bearer ${HF_TOKEN}" \
      -d /workspace/models/vae \
      -o Wan2.1_VAE.pth \
      "https://huggingface.co/Wan-AI/Wan2.2-T2V-A14B/resolve/main/Wan2.1_VAE.pth?download=true"

# --- Optional: public encoders (harmless to keep) ---
RUN mkdir -p /workspace/models/text_encoders && \
    aria2c -x 4 -s 4 -d /workspace/models/text_encoders \
      -o clip_text.pth \
      "https://huggingface.co/openai/clip-vit-large-patch14/resolve/main/pytorch_model.bin?download=true" || true

RUN mkdir -p /workspace/models/clip_vision && \
    aria2c -x 4 -s 4 -d /workspace/models/clip_vision \
      -o clip_vision.pth \
      "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/pytorch_model.bin?download=true" || true

# --- Copy your repo files ---
COPY start.sh /workspace/comfywan/start.sh
COPY rp_handler.py /workspace/comfywan/rp_handler.py
COPY extra_model_paths.yaml /workspace/comfywan/extra_model_paths.yaml
COPY workflows/ /workspace/comfywan/workflows/

RUN chmod +x /workspace/comfywan/start.sh

ENV COMFY_APP=/workspace/comfywan \
    OUTPUT_DIR=/workspace/output \
    RETURN_MODE=base64

WORKDIR /workspace/comfywan
ENTRYPOINT ["bash", "start.sh"]
