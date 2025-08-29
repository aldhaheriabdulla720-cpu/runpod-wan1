import os, json, base64, time, glob, requests, runpod

COMFY_HOST = os.getenv("COMFY_HOST", "127.0.0.1")
COMFY_PORT = int(os.getenv("COMFY_PORT", "8188"))
COMFY_URL = f"http://{COMFY_HOST}:{COMFY_PORT}"
OUTPUT_DIR = os.getenv("OUTPUT_DIR", "/workspace/output")
WORKFLOWS_DIR = os.getenv("WORKFLOWS_DIR", "/workspace/comfywan/workflows")
RETURN_MODE = os.getenv("RETURN_MODE", "base64")

CALLBACK_ENDPOINT = os.getenv("CALLBACK_API_ENDPOINT")
CALLBACK_SECRET = os.getenv("CALLBACK_API_SECRET")

def send_callback(payload):
    if not CALLBACK_ENDPOINT:
        return
    headers = {"Content-Type": "application/json"}
    if CALLBACK_SECRET:
        headers["X-Callback-Secret"] = CALLBACK_SECRET
    try:
        requests.post(CALLBACK_ENDPOINT, json=payload, headers=headers, timeout=10)
    except Exception as e:
        print("[callback] Failed:", e)

def load_workflow(workflow):
    # Accept dict, shortname, or filename
    if isinstance(workflow, dict):
        return workflow
    if not isinstance(workflow, str):
        raise ValueError("workflow must be dict or str")
    # Normalize name
    name = workflow.strip()
    if name.endswith(".json"):
        path = os.path.join(WORKFLOWS_DIR, name)
    else:
        path = os.path.join(WORKFLOWS_DIR, f"{name}.json")
    if not os.path.exists(path):
        raise FileNotFoundError(f"Workflow not found: {path}")
    with open(path, "r") as f:
        return json.load(f)

def inject_inputs(workflow, inputs):
    # Replace image node if base64 or URL given
    if "image_b64" in inputs:
        b64 = inputs["image_b64"]
        img_path = os.path.join(OUTPUT_DIR, "input_image.png")
        with open(img_path, "wb") as f:
            f.write(base64.b64decode(b64))
        for node in workflow.values():
            if node.get("class_type", "").lower() in ["loadimage", "load image"]:
                node["inputs"]["image"] = img_path
    if "image_url" in inputs:
        url = inputs["image_url"]
        img_path = os.path.join(OUTPUT_DIR, "input_image.png")
        data = requests.get(url, timeout=30).content
        with open(img_path, "wb") as f:
            f.write(data)
        for node in workflow.values():
            if node.get("class_type", "").lower() in ["loadimage", "load image"]:
                node["inputs"]["image"] = img_path
    return workflow

def run_workflow(workflow, prompt_id="job"):
    payload = {"prompt": workflow}
    r = requests.post(f"{COMFY_URL}/prompt", json=payload)
    r.raise_for_status()
    return r.json()

def handler(event):
    inp = event.get("input", {})
    wf = inp.get("workflow")
    if not wf:
        return {"error": "Missing 'workflow'"}
    # Load + inject
    try:
        workflow = load_workflow(wf)
        workflow = inject_inputs(workflow, inp)
    except Exception as e:
        return {"error": str(e)}

    prompt_id = f"sync-{event['id']}"
    send_callback({"action": "in_queue", "prompt_id": prompt_id})

    try:
        run_workflow(workflow, prompt_id)
    except Exception as e:
        send_callback({"action": "error", "prompt_id": prompt_id, "errors": str(e)})
        return {"error": str(e)}

    # Wait for outputs
    start = time.time()
    result_files = []
    while time.time() - start < int(os.getenv("MAX_EXECUTION_TIME", 1800)):
        files = glob.glob(os.path.join(OUTPUT_DIR, "*.mp4"))
        if files:
            result_files = files
            break
        time.sleep(5)

    if not result_files:
        send_callback({"action": "error", "prompt_id": prompt_id, "errors": "Timeout waiting for outputs"})
        return {"error": "Timeout waiting for outputs"}

    outputs = []
    for fpath in result_files:
        if RETURN_MODE == "base64":
            with open(fpath, "rb") as f:
                b64 = base64.b64encode(f.read()).decode("utf-8")
            outputs.append({"filename": os.path.basename(fpath), "type": "base64", "data": b64})
        else:
            outputs.append({"filename": os.path.basename(fpath), "type": "path", "data": fpath})

    send_callback({"action": "complete", "prompt_id": prompt_id, "result": {"videos": outputs}})
    return {"outputs": outputs}

runpod.serverless.start({"handler": handler})
