FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

# Ensure Python 3.10
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.10 python3.10-venv python3.10-dev python3-pip git curl aria2 wget \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3.10 /usr/bin/python \
    && ln -sf /usr/bin/python3.10 /usr/bin/python3

WORKDIR /workspace

# Torch 2.4.1 CUDA 12.1
RUN pip install --no-cache-dir torch==2.4.1 torchvision==0.19.1 torchaudio==2.4.1 --index-url https://download.pytorch.org/whl/cu121

# Clone ComfyUI
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git comfywan
WORKDIR /workspace/comfywan

# Install core deps
RUN pip install --no-cache-dir -r requirements.txt

# Custom nodes
RUN git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes/ComfyUI-Manager && pip install -r custom_nodes/ComfyUI-Manager/requirements.txt
RUN git clone https://github.com/kijai/ComfyUI-KJNodes.git custom_nodes/ComfyUI-KJNodes && pip install -r custom_nodes/ComfyUI-KJNodes/requirements.txt
RUN git clone https://github.com/welltop-cn/ComfyUI-TeaCache.git custom_nodes/ComfyUI-TeaCache && pip install -r custom_nodes/ComfyUI-TeaCache/requirements.txt

# RunPod + extras
RUN pip install --no-cache-dir runpod==1.7.9 websocket-client onnxruntime-gpu triton mutagen requests

# Copy repo files
COPY start.sh /workspace/comfywan/start.sh
COPY rp_handler.py /workspace/comfywan/rp_handler.py
COPY workflows/ /workspace/comfywan/workflows/
COPY extra_model_paths.yaml /workspace/comfywan/extra_model_paths.yaml

WORKDIR /workspace/comfywan
RUN chmod +x start.sh

ENTRYPOINT ["bash", "start.sh"]
