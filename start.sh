#!/usr/bin/env bash
echo "[boot] start.sh invoked (ts=$(date -Is))"

        # --- GPU sanity with retry (prevents instant unhealthy) ---
        GPU_WAIT_SECS="${GPU_WAIT_SECS:-300}"
        echo "[gpu] Waiting up to ${GPU_WAIT_SECS}s for CUDA..."
        END=$(( $(date +%s) + GPU_WAIT_SECS ))
        ok=0
        while [ $(date +%s) -lt $END ]; do
          echo "[gpu] nvidia-smi:"; (nvidia-smi || true)
          /usr/bin/python - <<'PY' && ok=1 && break || true
import torch, sys
print("[gpu] torch.__version__:", torch.__version__)
print("[gpu] torch.version.cuda:", torch.version.cuda)
print("[gpu] cuda.is_available():", torch.cuda.is_available())
print("[gpu] device_count:", torch.cuda.device_count())
if torch.cuda.is_available():
    print("[gpu] device 0:", torch.cuda.get_device_name(0)); sys.exit(0)
sys.exit(1)
PY
          sleep 5
        done
        if [ $ok -ne 1 ]; then
          echo "[FATAL] CUDA not available after ${GPU_WAIT_SECS}s — exiting so scheduler can respawn elsewhere."
          exit 1
        fi

# --- Background WAN 2.2 downloads (non-blocking) ---
(
/usr/bin/python - <<'PY'
from huggingface_hub import snapshot_download, hf_hub_download
import os, time, sys
tok = os.environ.get("HUGGINGFACE_HUB_TOKEN") or os.environ.get("HF_TOKEN") or None
root  = "/workspace/models"
diff  = os.path.join(root, "diffusion_models")
vae   = os.path.join(root, "vae")
os.makedirs(diff, exist_ok=True); os.makedirs(vae, exist_ok=True)
def grab():
    print("[bootstrap] Downloading Wan-AI/Wan2.2-T2V-A14B ...", flush=True)
    snapshot_download("Wan-AI/Wan2.2-T2V-A14B",
                      local_dir=os.path.join(diff,"wan2.2-t2v"),
                      token=tok, max_retries=3, resume_download=True)
    print("[bootstrap] Downloading Wan-AI/Wan2.2-I2V-A14B ...", flush=True)
    snapshot_download("Wan-AI/Wan2.2-I2V-A14B",
                      local_dir=os.path.join(diff,"wan2.2-i2v"),
                      token=tok, max_retries=3, resume_download=True)
    print("[bootstrap] Downloading Wan2.1_VAE.pth ...", flush=True)
    hf_hub_download("Wan-AI/Wan2.2-T2V-A14B", filename="Wan2.1_VAE.pth",
                    local_dir=os.path.join(root, "vae"), token=tok)
    print("[bootstrap] WAN 2.2 downloads complete.", flush=True)
if not tok:
    print("[bootstrap] HF token missing; skipping WAN downloads (handler is live).", flush=True); sys.exit(0)
for i in range(3):
    try:
        grab(); break
    except Exception as e:
        print(f"[bootstrap] retry {i+1}/3 failed: {e}", flush=True); time.sleep(10)
PY
) > /tmp/bootstrap.log 2>&1 &

# --- Create WAN aliases for CheckpointLoaderSimple ---
ckpt_dir="/workspace/comfywan/models/checkpoints"; mkdir -p "${ckpt_dir}"
pick_first() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }

# T2V
T2V_BASE="/workspace/models/diffusion_models/wan2.2-t2v"
T2V_INDEX="$(pick_first \
  "${T2V_BASE}/low_noise_model/model.safetensors.index.json" \
  "${T2V_BASE}/high_noise_model/model.safetensors.index.json" \
  "${T2V_BASE}/low_noise_model/diffusion_pytorch_model.safetensors.index.json" \
  "${T2V_BASE}/high_noise_model/diffusion_pytorch_model.safetensors.index.json")"
if [ -n "${T2V_INDEX:-}" ]; then
  ln -sf "${T2V_INDEX}" "${ckpt_dir}/wan2.2-t2v.safetensors"
  echo "[alias] T2V → ${ckpt_dir}/wan2.2-t2v.safetensors -> ${T2V_INDEX}"
else
  echo "[alias] WARN: No T2V index found under ${T2V_BASE}"
fi

# I2V
I2V_BASE="/workspace/models/diffusion_models/wan2.2-i2v"
I2V_INDEX="$(pick_first \
  "${I2V_BASE}/low_noise_model/model.safetensors.index.json" \
  "${I2V_BASE}/high_noise_model/model.safetensors.index.json" \
  "${I2V_BASE}/low_noise_model/diffusion_pytorch_model.safetensors.index.json" \
  "${I2V_BASE}/high_noise_model/diffusion_pytorch_model.safetensors.index.json")"
if [ -n "${I2V_INDEX:-}" ]; then
  ln -sf "${I2V_INDEX}" "${ckpt_dir}/wan2.2-i2v.safetensors"
  echo "[alias] I2V → ${ckpt_dir}/wan2.2-i2v.safetensors -> ${I2V_INDEX}"
else
  echo "[alias] WARN: No I2V index found under ${I2V_BASE}"
fi

# VAE convenience link
if [ -f "/workspace/models/vae/Wan2.1_VAE.pth" ]; then
  mkdir -p /workspace/comfywan/models/vae
  ln -sf /workspace/models/vae/Wan2.1_VAE.pth /workspace/comfywan/models/vae/Wan2.1_VAE.pth
fi

# -------- Start RunPod worker --------
echo "[start] Starting RunPod worker…"
/usr/bin/python -u -m runpod.serverless.worker rp_handler
