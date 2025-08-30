#!/usr/bin/env python3
import os, json, time, traceback
import requests
import runpod

COMFY_PORT = os.getenv("COMFY_PORT", "8188")
COMFY_URL  = f"http://127.0.0.1:{COMFY_PORT}"
WORKFLOWS_DIR = "/workspace/workflows"
RETURN_MODE = os.getenv("RETURN_MODE", "base64")

def wait_for_comfy(timeout=180):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            r = requests.get(f"{COMFY_URL}/system_stats", timeout=2)
            if r.ok:
                return True
        except Exception:
            time.sleep(1)
    return False

def _load_workflow(spec):
    if isinstance(spec, dict):
        return spec
    if isinstance(spec, str):
        path = os.path.join(WORKFLOWS_DIR, spec)
        if not os.path.exists(path):
            raise FileNotFoundError(f"workflow file not found: {path}")
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    raise ValueError("Invalid 'workflow' type; must be dict or filename string.")

def _post_prompt(workflow_obj):
    r = requests.post(f"{COMFY_URL}/prompt", json={"prompt": workflow_obj}, timeout=30)
    r.raise_for_status()
    j = r.json()
    return j.get("prompt_id") or j.get("node_id")

def _poll_history(prompt_id, timeout=600):
    t0 = time.time()
    while time.time() - t0 < timeout:
        r = requests.get(f"{COMFY_URL}/history/{prompt_id}", timeout=15)
        if r.ok:
            j = r.json()
            if isinstance(j, dict) and prompt_id in j:
                return j[prompt_id]
            return j
        time.sleep(1.0)
    raise TimeoutError("Timed out waiting for Comfy result")

def handler(event):
    try:
        inp = (event or {}).get("input", {}) or {}

        if inp.get("dry_run"):
            ready = wait_for_comfy()
            wf = inp.get("workflow")
            wf_exists = True
            if isinstance(wf, str):
                wf_exists = os.path.exists(os.path.join(WORKFLOWS_DIR, wf))
            return {"status": "ok", "comfy_ready": bool(ready), "workflow": wf, "workflow_exists": bool(wf_exists)}

        wf_spec = inp.get("workflow")
        if wf_spec is None:
            return {"error": "Missing 'workflow' parameter"}

        if not wait_for_comfy():
            return {"error": "ComfyUI not ready"}

        workflow = _load_workflow(wf_spec)

        # (Optional) edit workflow using inp["params"] here

        prompt_id = _post_prompt(workflow)
        result = _poll_history(prompt_id)

        return {"status": "ok", "prompt_id": prompt_id, "result": result}

    except Exception as e:
        return {"status": "error", "error": str(e), "trace": traceback.format_exc()}

runpod.serverless.start({"handler": handler})
