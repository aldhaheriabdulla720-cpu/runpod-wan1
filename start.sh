#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +'%F %T')] $*"; }

# -------- Env & paths --------
export COMFY_DIR="${COMFY_DIR:-/workspace/comfywan}"
export MODEL_DIR="${MODEL_DIR:-/workspace/models}"
export DIFFUSION_DIR="${DIFFUSION_DIR:-$MODEL_DIR/diffusion_models}"
export VAE_DIR="${VAE_DIR:-$MODEL_DIR/vae}"
export WORKFLOWS_DIR="${WORKFLOWS_DIR:-/workspace/workflows}"
export COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
export COMFY_PORT="${COMFY_PORT:-8188}"
export COMFY_ARGS="${COMFY_ARGS:---output-directory /workspace/output}"
export RETURN_MODE="${RETURN_MODE:-base64}"

# WAN repos (A14B)
export WAN_T2V_REPO="${WAN_T2V_REPO:-Wan-AI/Wan2.2-T2V-A14B}"
export WAN_I2V_REPO="${WAN_I2V_REPO:-Wan-AI/Wan2.2-I2V-A14B}"
export WAN_VAE_FILE="${WAN_VAE_FILE:-Wan2.1_VAE.pth}"

# Enable both (you have 70 GB)
export WAN_ENABLE_T2V="${WAN_ENABLE_T2V:-true}"
export WAN_ENABLE_I2V="${WAN_ENABLE_I2V:-true}"

# Put HF cache on the network volume to avoid filling root FS
export HF_HOME="${HF_HOME:-$MODEL_DIR/hf_cache}"
export HUGGINGFACE_HUB_CACHE="$HF_HOME"
export TRANSFORMERS_CACHE="$HF_HOME"
mkdir -p "$HF_HOME"

# Ensure directory trees exist
mkdir -p "$MODEL_DIR" "$DIFFUSION_DIR" "$VAE_DIR"
mkdir -p "$COMFY_DIR/models/checkpoints" "$COMFY_DIR/models/vae" \
         "$COMFY_DIR/models/loras" "$COMFY_DIR/models/clip_vision"
mkdir -p /workspace/output

# Link extra_model_paths.yaml into the Comfy root so Comfy reads it
if [[ -f /workspace/extra_model_paths.yaml ]]; then
  ln -sf /workspace/extra_model_paths.yaml "$COMFY_DIR/extra_model_paths.yaml"
  log "[paths] extra_model_paths.yaml -> $COMFY_DIR/extra_model_paths.yaml"
fi

log "[env] COMFY_DIR=$COMFY_DIR  MODEL_DIR=$MODEL_DIR  HF_HOME=$HF_HOME"

# -------- Launch ComfyUI (background) --------
log "[start] Starting ComfyUI…"
pushd "$COMFY_DIR" >/dev/null
python3 -u main.py --listen "$COMFY_HOST" --port "$COMFY_PORT" $COMFY_ARGS \
  > /tmp/comfyui.log 2>&1 &
COMFY_PID=$!
popd >/dev/null

# Wait for API to be ready
log "[wait] Waiting for ComfyUI API…"
for i in {1..120}; do
  if curl -fsS "http://127.0.0.1:${COMFY_PORT}/system_stats" >/dev/null; then
    log "[wait] ComfyUI is ready."
    break
  fi
  sleep 2
  if ! kill -0 $COMFY_PID 2>/dev/null; then
    log "[error] ComfyUI process died. Tail /tmp/comfyui.log"
    exit 1
  fi
  if [[ $i -eq 120 ]]; then
    log "[error] ComfyUI did not become ready."
    exit 1
  fi
done

# -------- Bootstrap: download WAN models & VAE --------
log "[hf] Bootstrapping WAN models… (logs -> /tmp/bootstrap.log)"
python3 - <<'PY' 2>&1 | tee -a /tmp/bootstrap.log
import os, shutil, sys
from huggingface_hub import snapshot_download, hf_hub_download

tok = os.getenv("HF_TOKEN")
diff_dir  = os.getenv("DIFFUSION_DIR", "/workspace/models/diffusion_models")
vae_dir   = os.getenv("VAE_DIR", "/workspace/models/vae")
t2v_repo  = os.getenv("WAN_T2V_REPO", "Wan-AI/Wan2.2-T2V-A14B")
i2v_repo  = os.getenv("WAN_I2V_REPO", "Wan-AI/Wan2.2-I2V-A14B")
vae_file  = os.getenv("WAN_VAE_FILE", "Wan2.1_VAE.pth")
enable_t2v = os.getenv("WAN_ENABLE_T2V", "true").lower() == "true"
enable_i2v = os.getenv("WAN_ENABLE_I2V", "true").lower() == "true"
cache_dir  = os.getenv("HF_HOME", "/workspace/models/hf_cache")

os.makedirs(diff_dir, exist_ok=True)
os.makedirs(vae_dir, exist_ok=True)

def snap(repo_id, local_dir):
    print(f"[hf] snapshot_download {repo_id} -> {local_dir}")
    try:
        snapshot_download(repo_id=repo_id,
                          local_dir=local_dir,
                          local_dir_use_symlinks=False,
                          token=tok, resume_download=True,
                          cache_dir=cache_dir)
        print(f"[hf] done {repo_id}")
    except Exception as e:
        print(f"[hf] WARN {repo_id}: {e}", file=sys.stderr)

if enable_t2v: snap(t2v_repo, os.path.join(diff_dir, "wan2.2-t2v"))
else: print("[hf] T2V disabled")

if enable_i2v: snap(i2v_repo, os.path.join(diff_dir, "wan2.2-i2v"))
else: print("[hf] I2V disabled")

# VAE exists inside WAN repos; prefer an enabled repo
vae_repo = i2v_repo if enable_i2v else t2v_repo
try:
    print(f"[hf] downloading VAE {vae_file} from {vae_repo}")
    vae_path = hf_hub_download(repo_id=vae_repo, filename=vae_file,
                               token=tok, cache_dir=cache_dir)
    dst = os.path.join(vae_dir, os.path.basename(vae_path))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if not os.path.exists(dst):
        shutil.copy2(vae_path, dst)
    print(f"[hf] VAE ready at {dst}")
except Exception as e:
    print(f"[hf] WARN VAE download: {e}", file=sys.stderr)

print("[hf] bootstrap complete")
PY

# -------- Link models into Comfy tree (was missing before) --------
# VAE
if [[ -f "$VAE_DIR/$WAN_VAE_FILE" ]]; then
  ln -sf "$VAE_DIR/$WAN_VAE_FILE" "$COMFY_DIR/models/vae/$WAN_VAE_FILE"
  log "[paths] VAE -> $COMFY_DIR/models/vae/$WAN_VAE_FILE"
fi

# Create/refresh friendly checkpoint aliases in Comfy checkpoints folder
(
  set -e
  T2V_SRC=$(find "$DIFFUSION_DIR/wan2.2-t2v" -type f -name '*.safetensors' -size +500M | head -n1 || true)
  I2V_SRC=$(find "$DIFFUSION_DIR/wan2.2-i2v" -type f -name '*.safetensors' -size +500M | head -n1 || true)
  if [[ -n "$T2V_SRC" ]]; then
    ln -sf "$T2V_SRC" "$COMFY_DIR/models/checkpoints/wan2.2-t2v.safetensors"
    log "[paths] T2V alias -> $COMFY_DIR/models/checkpoints/wan2.2-t2v.safetensors"
  else
    log "[paths] T2V shard not found yet; alias skipped"
  fi
  if [[ -n "$I2V_SRC" ]]; then
    ln -sf "$I2V_SRC" "$COMFY_DIR/models/checkpoints/wan2.2-i2v.safetensors"
    log "[paths] I2V alias -> $COMFY_DIR/models/checkpoints/wan2.2-i2v.safetensors"
  else
    log "[paths] I2V shard not found yet; alias skipped"
  fi
) 2>&1 | tee -a /tmp/alias-watch.log

# -------- RunPod handler (foreground) --------
log "[handler] starting worker…"
exec python3 -u /workspace/rp_handler.py
