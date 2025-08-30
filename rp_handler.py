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
        path = spec if spec.startswith("/") else os.path.join(WORKFLOWS_DIR, spec)
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    raise ValueError("workflow must be a dict or filename")

def _post_prompt(workflow_obj):
    r = requests.post(f"{COMFY_URL}/prompt", json={"prompt": workflow_obj}, timeout=30)
    if not r.ok:
        return {"http_status": r.status_code, "error_text": r.text}
    j = r.json()
    return j.get("prompt_id") or j.get("node_id")

def handler(event):
    """RunPod /runsync handler"""
    inp = event.get("input", {})
    dry = bool(inp.get("dry_run", False))
    wf  = inp.get("workflow")

    comfy_ready = _wait_for_comfy(60)
    if dry:
        exists = True
        if isinstance(wf, str):
            p = wf if wf.startswith("/") else os.path.join(WORKFLOWS_DIR, wf)
            exists = os.path.exists(p)
        return {"status": "ok", "comfy_ready": comfy_ready, "workflow": wf, "workflow_exists": exists}

    if not comfy_ready:
        return {"status": "error", "msg": "ComfyUI not ready"}

    try:
        workflow = _load_workflow_obj(wf)
    except Exception as e:
        return {"status": "error", "msg": f"failed to load workflow: {e}"}

    prompt_id = _post_prompt(workflow)
    if isinstance(prompt_id, dict) and prompt_id.get("http_status"):
        return {"status": "error", "from": "/prompt", **prompt_id}

    for _ in range(600):  # ~10 min
        try:
            r = requests.get(f"{COMFY_URL}/history/{prompt_id}", timeout=10)
            if r.ok:
                hist = r.json()
                if hist:
                    return {"status": "ok", "return_mode": RETURN_MODE, "result": hist}
        except Exception:
            pass
        time.sleep(1)

    return {"status": "error", "msg": "timeout waiting for result"}

start({"handler": handler})
