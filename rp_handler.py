import os, json, time, base64, glob, requests, runpod
from typing import Any, Dict, List

# Always call loopback (127.0.0.1). Bind may be 0.0.0.0, that's fine.
COMFY_PORT = int(os.getenv("COMFY_PORT", "8188"))
COMFY_URL = f"http://127.0.0.1:{COMFY_PORT}"
OUTPUT_DIR = os.getenv("OUTPUT_DIR", "/workspace/output")
WORKFLOWS_DIR = os.getenv("WORKFLOWS_DIR", "/workspace/comfywan/workflows")
RETURN_MODE = os.getenv("RETURN_MODE", "base64")  # base64 | path

CALLBACK_ENDPOINT = os.getenv("CALLBACK_API_ENDPOINT")
CALLBACK_SECRET   = os.getenv("CALLBACK_API_SECRET")

def _cb(payload: Dict[str, Any]):
    if not CALLBACK_ENDPOINT:
        return
    headers = {"Content-Type": "application/json"}
    if CALLBACK_SECRET:
        headers["X-Callback-Secret"] = CALLBACK_SECRET
    try:
        requests.post(CALLBACK_ENDPOINT, json=payload, headers=headers, timeout=10)
    except Exception as e:
        print("[callback] failed:", e)

def _load_workflow(ref: Any) -> Dict[str, Any]:
    """
    Accepts:
      - dict: returned as-is
      - short name: 'ping' or 'wan2.2-t2v' -> loads WORKFLOWS_DIR/<name>.json
      - filename:  'wan2.2-t2v.json'
    """
    if isinstance(ref, dict):
        return ref
    if not isinstance(ref, str):
        raise ValueError("workflow must be dict or string")

    candidates: List[str] = []
    if ref.endswith(".json"):
        candidates.append(os.path.join(WORKFLOWS_DIR, ref))
    else:
        candidates.append(os.path.join(WORKFLOWS_DIR, f"{ref}.json"))

    for path in candidates:
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)

    raise FileNotFoundError(f"workflow '{ref}' not found in {WORKFLOWS_DIR}")

def _validate_workflow(wf: Dict[str, Any]):
    if not isinstance(wf, dict) or not wf:
        raise ValueError("workflow is empty or not a dict")
    # Each key is a node id; each node must have class_type and inputs
    for node_id, node in wf.items():
        if not isinstance(node, dict):
            raise ValueError(f"node {node_id} is not an object")
        if "class_type" not in node:
            raise ValueError(f"node {node_id} missing class_type")
        if "inputs" not in node:
            raise ValueError(f"node {node_id} missing inputs")

def _post_prompt(prompt: Dict[str, Any]) -> str:
    r = requests.post(f"{COMFY_URL}/prompt", json=prompt, timeout=30)
    if r.status_code != 200:
        raise RuntimeError(f"ComfyUI /prompt bad status {r.status_code}: {r.text}")
    data = r.json()
    return data.get("prompt_id") or data.get("number") or ""

def _poll(prompt_id: str, timeout_s: int = 1800) -> Dict[str, Any]:
    t0 = time.time()
    while True:
        if time.time() - t0 > timeout_s:
            raise TimeoutError("execution timed out")
        r = requests.get(f"{COMFY_URL}/history/{prompt_id}", timeout=15)
        if r.status_code == 200:
            data = r.json()
            if data and prompt_id in data:
                return data[prompt_id]
        time.sleep(1.5)

def _collect_outputs(limit: int = 8) -> List[str]:
    exts = ("*.mp4", "*.webm", "*.png", "*.gif", "*.jpg", "*.jpeg")
    files: List[str] = []
    for pattern in exts:
        files += glob.glob(os.path.join(OUTPUT_DIR, pattern))
    files.sort(key=os.path.getmtime, reverse=True)
    return files[:limit]

def _serialize(file_path: str) -> Dict[str, str]:
    if RETURN_MODE == "base64":
        with open(file_path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode("utf-8")
        return {"filename": os.path.basename(file_path), "type": "base64", "data": b64}
    else:
        return {"filename": os.path.basename(file_path), "type": "path", "data": file_path}

def handler(event):
    """
    Input:
    {
      "workflow": dict | "ping" | "wan2.2-t2v" | "wan2.2-t2v.json",
      "inputs":   {...},       # reserved for future prompt/img injection
      "client_id":"abc",       # optional
      "dry_run":  false        # optional - validate only
    }
    """
    payload = event.get("input") or {}
    workflow_ref = payload.get("workflow", "ping")
    inputs = payload.get("inputs", {})  # not used yet
    client_id = payload.get("client_id", "serverless")
    dry_run = bool(payload.get("dry_run", False))

    # Load + validate
    wf = _load_workflow(workflow_ref)
    _validate_workflow(wf)

    if dry_run:
        return {"ok": True, "validated": True, "workflow_nodes": len(wf)}

    # ComfyUI expects {"prompt": <graph>, "client_id": "..."}
    prompt = {"prompt": wf, "client_id": client_id}

    # Submit
    prompt_id = _post_prompt(prompt)
    _cb({"action": "in_queue", "prompt_id": prompt_id})

    # Poll for completion
    result = _poll(prompt_id, timeout_s=int(os.getenv("MAX_EXECUTION_TIME", "1800")))

    # Gather outputs
    files = _collect_outputs()
    outputs = [_serialize(p) for p in files]

    _cb({"action": "complete", "prompt_id": prompt_id, "result": {"outputs": outputs}})
    return {"outputs": outputs, "history": result}

runpod.serverless.start({"handler": handler})
