FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
# Do NOT bake secrets in the image; HF_TOKEN will be provided at runtime by env
# ENV HF_TOKEN=${HF_TOKEN}    # <-- intentionally not setting here

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

# Safe pins + ComfyUI deps
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
RUN git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager.git
RUN pip install --no-cache-dir imageio-ffmpeg tqdm

# Back to comfy root
WORKDIR /workspace/comfywan

# --- Runtime deps (handler etc.) ---
RUN pip install --no-cache-dir runpod==1.7.9 requests websockets safetensors

# --- WAN models ---
# ⛔ Removed from Docker build. Download now happens at runtime in start.sh using HF_TOKEN.

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
