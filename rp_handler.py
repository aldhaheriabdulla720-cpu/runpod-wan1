#!/usr/bin/env python3
import json, os, time, requests
from typing import Any, Dict
from runpod.serverless import start

COMFY_HOST = os.getenv("COMFY_HOST", "127.0.0.1")
COMFY_PORT = int(os.getenv("COMFY_PORT", "8188"))
COMFY_URL  = f"http://{COMFY_HOST}:{COMFY_PORT}"

WORKFLOWS_DIR = os.getenv("WORKFLOWS_DIR", "/workspace/workflows")
RETURN_MODE   = os.getenv("RETURN_MODE", "base64")

def _wait_for_comfy(timeout=120):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            r = requests.get(f"{COMFY_URL}/system_stats", timeout=5)
            if r.ok:
                return True
        except Exception:
            pass
        time.sleep(1)
    return False

def _load_workflow_obj(spec: Any) -> Dict[str, Any]:
    if isinstance(spec, dict):
        return spec
    if isinstance(spec, str):
        # treat as filename under WORKFLOWS_DIR
        path = spec if spec.startswith("/") else os.path.join(WORKFLOWS_DIR, spec)
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    raise ValueError("workflow must be a dict or filename")

def _post_prompt(workflow_obj):
    r = requests.post(f"{COMFY_URL}/prompt", json={"prompt": workflow_obj}, timeout=30)
    if not r.ok:
        # Bubble up server error so we can see exactly which node/field failed
        return {"http_status": r.status_code, "error_text": r.text}
    j = r.json()
    # Comfy returns {'prompt_id': '...'} (sometimes node_id); accept either
    return j.get("prompt_id") or j.get("node_id")

def handler(event):
    """RunPod /runsync handler"""
    inp = event.get("input", {})
    dry = bool(inp.get("dry_run", False))
    wf  = inp.get("workflow")

    # Health & readiness
    comfy_ready = _wait_for_comfy(60)
    if dry:
        # Also verify the workflow file exists (if a string was given)
        exists = True
        if isinstance(wf, str):
            p = wf if wf.startswith("/") else os.path.join(WORKFLOWS_DIR, wf)
            exists = os.path.exists(p)
        return {"status": "ok", "comfy_ready": comfy_ready, "workflow": wf, "workflow_exists": exists}

    if not comfy_ready:
        return {"status": "error", "msg": "ComfyUI not ready"}

    # Load workflow JSON (file or dict)
    try:
        workflow = _load_workflow_obj(wf)
    except Exception as e:
        return {"status": "error", "msg": f"failed to load workflow: {e}"}

    # Submit prompt
    prompt_id = _post_prompt(workflow)
    if isinstance(prompt_id, dict) and prompt_id.get("http_status"):
        # Return Comfy's exact error body (400/500), super helpful for diagnosing
        return {"status": "error", "from": "/prompt", **prompt_id}

    # Poll history until done
    for _ in range(600):  # ~10 min max
        try:
            r = requests.get(f"{COMFY_URL}/history/{prompt_id}", timeout=10)
            if r.ok:
                hist = r.json()
                if hist:
                    # Return raw history; your client can pick the images/videos or base64
                    return {"status": "ok", "return_mode": RETURN_MODE, "result": hist}
        except Exception:
            pass
        time.sleep(1)

    return {"status": "error", "msg": "timeout waiting for result"}

start({"handler": handler})
