# ComfyUI + WanVideoWrapper + VideoHelperSuite, ready for RunPod Serverless
FROM nvidia/cuda:12.1.1-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_PREFER_BINARY=1 \
    HF_HOME=/workspace/.cache/huggingface \
    TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9+PTX;9.0"  # A100/H100 families

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /workspace

# — System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.10 python3.10-dev python3.10-venv python3-pip \
    git git-lfs ffmpeg curl ca-certificates \
    build-essential pkg-config libgl1 libglib2.0-0 aria2 wget vim \
  && ln -sf /usr/bin/python3.10 /usr/bin/python \
  && ln -sf /usr/bin/python3.10 /usr/bin/python3 \
  && python -m pip install --upgrade pip \
  && rm -rf /var/lib/apt/lists/*

# — Torch (CUDA 12.1 wheels)
RUN pip install --no-cache-dir \
    torch==2.4.1 torchvision==0.19.1 --index-url https://download.pytorch.org/whl/cu121 && \
    pip install --no-cache-dir xformers==0.0.27.post2 --index-url https://download.pytorch.org/whl/cu121 || true

# — Clone ComfyUI
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /workspace/comfywan
WORKDIR /workspace/comfywan
RUN pip install --no-cache-dir -r requirements.txt

# — Core comfy extras often needed by video nodes
RUN pip install --no-cache-dir \
    safetensors==0.4.3 opencv-python imageio[ffmpeg] decord moviepy einops \
    transformers accelerate huggingface_hub mutagen websocket-client requests

# — Custom nodes
RUN mkdir -p /workspace/comfywan/custom_nodes && \
    git clone --depth 1 https://github.com/kijai/ComfyUI-WanVideoWrapper.git \
      /workspace/comfywan/custom_nodes/ComfyUI-WanVideoWrapper && \
    (test -f /workspace/comfywan/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt && \
      pip install --no-cache-dir -r /workspace/comfywan/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt || true) && \
    git clone --depth 1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git \
      /workspace/comfywan/custom_nodes/ComfyUI-VideoHelperSuite && \
    (test -f /workspace/comfywan/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt && \
      pip install --no-cache-dir -r /workspace/comfywan/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt || true) && \
    git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager.git \
      /workspace/comfywan/custom_nodes/ComfyUI-Manager

# — Models layout helper
COPY extra_model_paths.yaml /workspace/comfywan/extra_model_paths.yaml

# — Handler + launcher
COPY rp_handler.py /rp_handler.py
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 3000
ENTRYPOINT ["/start.sh"]
