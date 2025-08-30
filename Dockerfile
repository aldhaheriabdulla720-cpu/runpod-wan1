# ===== Base: CUDA runtime for GPU pods =====
FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-lc"]

# ---- OS deps ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-venv python3-pip git curl wget ca-certificates ffmpeg \
    libglib2.0-0 libsm6 libxext6 libxrender1 \
    && rm -rf /var/lib/apt/lists/*

# ---- Python env ----
RUN python3 -m pip install --upgrade pip

# ---- Torch (CUDA 12.1) ----
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cu121 \
    torch==2.4.1 torchvision==0.19.1 torchaudio==2.4.1

# ---- Core libs pinned for Comfy stability ----
RUN pip install --no-cache-dir \
    numpy==1.26.4 pillow==10.3.0 \
    transformers==4.39.3 tokenizers==0.15.2 \
    tqdm==4.66.4 requests==2.32.3 \
    huggingface_hub==0.24.6 \
    aiohttp==3.9.5 websockets==12.0 \
    opencv-python-headless==4.9.0.80 \
    pyyaml==6.0.1

# ---- ComfyUI checkout ----
ENV COMFY_DIR=/workspace/comfywan
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
WORKDIR $COMFY_DIR
# Comfy requirements (after pins)
RUN pip install --no-cache-dir -r requirements.txt || true

# ---- Custom nodes needed by your graphs ----
RUN mkdir -p "$COMFY_DIR/custom_nodes" && cd "$COMFY_DIR/custom_nodes" && \
    git clone --depth=1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git && \
    git clone --depth=1 https://github.com/kijai/ComfyUI-KJNodes.git

# Optional: install custom-node requirements if present
RUN if [ -f "$COMFY_DIR/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt" ]; then \
      pip install --no-cache-dir -r "$COMFY_DIR/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt"; \
    fi || true
RUN if [ -f "$COMFY_DIR/custom_nodes/ComfyUI-KJNodes/requirements.txt" ]; then \
      pip install --no-cache-dir -r "$COMFY_DIR/custom_nodes/ComfyUI-KJNodes/requirements.txt"; \
    fi || true

# ---- RunPod serverless worker lib ----
RUN pip install --no-cache-dir runpod==1.7.9

# ---- App layout ----
WORKDIR /workspace
COPY workflows/ /workspace/workflows/
COPY extra_model_paths.yaml /workspace/extra_model_paths.yaml
COPY start.sh /workspace/start.sh
COPY rp_handler.py /workspace/rp_handler.py
RUN chmod +x /workspace/start.sh

ENV COMFY_HOST=0.0.0.0 \
    COMFY_PORT=8188 \
    COMFY_ARGS="--output-directory /workspace/output" \
    WORKFLOWS_DIR=/workspace/workflows \
    MODEL_DIR=/workspace/models \
    DIFFUSION_DIR=/workspace/models/diffusion_models \
    VAE_DIR=/workspace/models/vae \
    RETURN_MODE=base64

EXPOSE 8188
ENTRYPOINT ["bash", "/workspace/start.sh"]
