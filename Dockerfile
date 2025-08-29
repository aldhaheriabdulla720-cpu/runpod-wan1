FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.10 python3.10-venv python3.10-dev python3-pip \
    git curl aria2 wget ca-certificates ffmpeg \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sf /usr/bin/python3.10 /usr/bin/python \
 && ln -sf /usr/bin/python3.10 /usr/bin/python3

WORKDIR /workspace

# PyTorch (CUDA 12.1 build)
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cu121 \
    torch==2.4.1 torchvision==0.19.1 torchaudio==2.4.1

# Clone ComfyUI
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /workspace/comfywan
WORKDIR /workspace/comfywan
RUN pip install --no-cache-dir -r requirements.txt

# --- Custom Nodes ---
WORKDIR /workspace/comfywan/custom_nodes
# GGUF loader (fixes UnetLoaderGGUF node)
RUN git clone --depth=1 https://github.com/city96/ComfyUI-GGUF.git
# Video helpers (video combine, writer, etc.)
RUN git clone --depth=1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git
RUN pip install --no-cache-dir imageio-ffmpeg tqdm
# Manager (optional, but useful for troubleshooting)
RUN git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager.git

# Back to comfy root
WORKDIR /workspace/comfywan

# Runtime deps
RUN pip install --no-cache-dir runpod==1.7.9 requests websockets pillow==10.3.0 safetensors

# Copy your files
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
