# ---- Base: CUDA 12.1 (matches torch/cu121) ----
FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

# ---- System deps ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.10 python3.10-venv python3.10-dev python3-pip \
    git curl aria2 wget ca-certificates ffmpeg \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sf /usr/bin/python3.10 /usr/bin/python \
 && ln -sf /usr/bin/pip3 /usr/bin/pip

WORKDIR /workspace

# ---- PyTorch CUDA 12.1 build ----
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cu121 \
    torch==2.4.1 torchvision==0.19.1 torchaudio==2.4.1

# ---- Core Python deps (SDK + client libs) ----
RUN pip install --no-cache-dir \
    runpod==1.7.9 \
    huggingface_hub==0.24.6 \
    requests==2.32.3 \
    aiohttp==3.9.5 \
    websockets==12.0 \
    tqdm==4.66.4 \
    pillow==10.3.0 \
    numpy==1.26.4 \
    opencv-python-headless==4.9.0.80

# ---- Clone ComfyUI (to /workspace/comfywan) ----
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /workspace/comfywan

# ✅ New (safe) line: install ComfyUI requirements so nodes don't miss deps
RUN pip install --no-cache-dir -r /workspace/comfywan/requirements.txt

# (Optional) Example custom nodes (comment out if you don’t want them)
# RUN git clone --depth=1 https://github.com/cubiq/ComfyUI_essentials.git /workspace/comfywan/custom_nodes/ComfyUI_essentials
# RUN git clone --depth=1 https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git /workspace/comfywan/custom_nodes/ComfyUI-Custom-Scripts

# ---- Copy your repo files into the image ----
# (Assumes these files/folders exist in your repo root)
COPY rp_handler.py /workspace/comfywan/rp_handler.py
COPY workflows /workspace/comfywan/workflows
# If you have this file in your repo (you said you do). If not, remove this line.
COPY extra_model_paths.yaml /workspace/comfywan/extra_model_paths.yaml

# ---- Launcher ----
COPY start.sh /workspace/start.sh
RUN chmod +x /workspace/start.sh

# Useful defaults (can be overridden by endpoint envs)
ENV COMFY_HOST=0.0.0.0 \
    COMFY_PORT=8188 \
    OUTPUT_DIR=/workspace/output \
    WORKFLOWS_DIR=/workspace/comfywan/workflows

WORKDIR /workspace/comfywan

# ---- Start the stack ----
ENTRYPOINT ["bash", "/workspace/start.sh"]

