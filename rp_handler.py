# rp_handler.py — RunPod serverless handler for ComfyUI (video-ready)
# Additions:
# - Echo path: {"input":{"ping":"pong"}}  → immediate 200
# - Dry-run path: {"input":{"dry_run": true}} → immediate 200
# - Original Comfy workflow execution preserved

import os
import json
import time
import uuid
import base64
import socket
import traceback
from pathlib import Path
from typing import Any, Dict, List, Tuple

import requests
import websocket  # provided by image; no need for asyncio here
import runpod
from runpod.serverless.utils import rp_upload  # works when BUCKET_* env vars are set

# ----------------------------- Config -----------------------------

COMFY_HOST = os.getenv("COMFY_HOST", "127.0.0.1")
COMFY_PORT = int(os.getenv("COMFY_PORT", "3000"))
COMFY_BASE = f"http://{COMFY_HOST}:{COMFY_PORT}"
PROMPT_URL = f"{COMFY_BASE}/prompt"
VIEW_URL = f"{COMFY_BASE}/view"
WS_URL = f"ws://{COMFY_HOST}:{COMFY_PORT}/ws"

# where ComfyUI writes outputs; our start.sh launches Comfy with base at /workspace/comfywan
OUTPUT_ROOT = Path(os.getenv("COMFY_OUTPUT_DIR", "/workspace/comfywan/output")).resolve()

# how long to wait for Comfy API to come up (headless boot)
API_CHECK_MAX_RETRIES = int(os.getenv("COMFY_API_AVAILABLE_MAX_RETRIES", "900"))
API_CHECK_DELAY_MS = int(os.getenv("COMFY_API_CHECK_DELAY_MS", "50"))

# websocket settings for long jobs
WEBSOCKET_RECONNECT_ATTEMPTS = int(os.getenv("WEBSOCKET_RECONNECT_ATTEMPTS", "100"))
WEBSOCKET_RECONNECT_DELAY_S = int(os.getenv("WEBSOCKET_RECONNECT_DELAY_S", "3"))
WEBSOCKET_RECEIVE_TIMEOUT = int(os.getenv("WEBSOCKET_RECEIVE_TIMEOUT", "30"))
MAX_EXECUTION_TIME = int(os.getenv("MAX_EXECUTION_TIME", "1800"))  # 30 minutes

# output mode: "base64" (default) or "url" (requires bucket envs)
RETURN_MODE = os.getenv("RETURN_MODE", "base64").lower()

# cleanup behavior
KEEP_OUTPUTS = os.getenv("KEEP_OUTPUTS", "0") == "1"
VIDEO_EXTS = {".mp4", ".webm", ".gif"}
IMAGE_EXTS = {".png", ".jpg", ".jpeg"}
CLEANABLE_EXTS = VIDEO_EXTS | IMAGE_EXTS

# optional callback webhook if you want (leave empty to disable)
CALLBACK_API_ENDPOINT = os.getenv("CALLBACK_API_ENDPOINT", "")
CALLBACK_API_SECRET = os.getenv("CALLBACK_API_SECRET", "")

# ----------------------------- Helpers -----------------------------

def log(msg: str) -> None:
    print(f"[worker-comfyui] {msg}", flush=True)

def callback_api(payload: Dict[str, Any]) -> None:
    if not CALLBACK_API_ENDPOINT:
        return
    try:
        headers = {"Content-Type": "application/json"}
        if CALLBACK_API_SECRET:
            headers["X-Callback-Secret"] = CALLBACK_API_SECRET
        requests.post(CALLBACK_API_ENDPOINT, headers=headers, json=payload, timeout=5)
    except Exception as e:
        log(f"callback warn: {e}")

def check_server(url: str, retries: int, delay_ms: int) -> bool:
    log(f"checking API at {url} ...")
    for _ in range(retries):
        try:
            r = requests.get(url, timeout=5)
            if r.status_code == 200:
                log("API is reachable")
                return True
        except requests.RequestException:
            pass
        time.sleep(delay_ms / 1000.0)
    return False

def _safe_is_child(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except Exception:
        return False

def cleanup_outputs(paths: List[str]) -> None:
    if KEEP_OUTPUTS:
        log("KEEP_OUTPUTS=1 → skipping deletion.")
        return
    removed = 0
    for p in paths:
        try:
            p = Path(p)
            if p.suffix.lower() in CLEANABLE_EXTS and _safe_is_child(p, OUTPUT_ROOT):
                if p.exists():
                    p.unlink()
                    removed += 1
                    log(f"deleted: {p}")
        except Exception as e:
            log(f"cleanup warn: {p} → {e}")
    log(f"cleanup done, removed={removed}")

def try_decode_b64uri(data_uri: str) -> bytes:
    # accept data:...;base64,.... or plain base64
    if "," in data_uri and data_uri.strip().lower().startswith("data:"):
        data_uri = data_uri.split(",", 1)[1]
    return base64.b64decode(data_uri)

# ------------------ Input validation & preprocessing ------------------

def validate_and_prepare(job_input: Any) -> Tuple[Dict[str, Any], str]:
    """
    Expect:
    job['input'] = {
        "workflow": { ... ComfyUI workflow object ... },
        // optional: "images": [{ "name": "a.png", "image": "<base64 or datauri>" }, ...]
    }
    """
    if job_input is None:
        return None, "Missing input"
    if isinstance(job_input, str):
        try:
            job_input = json.loads(job_input)
        except json.JSONDecodeError:
            return None, "Invalid JSON in input"

    workflow = job_input.get("workflow")
    if workflow is None:
        return None, "Missing 'workflow' parameter"

    # Must be an object, not a stringified JSON
    if isinstance(workflow, str):
        try:
            workflow = json.loads(workflow)
        except Exception:
            return None, "'workflow' must be a JSON object (not a string)"
    if not isinstance(workflow, dict):
        return None, "'workflow' must be a JSON object"

    images = job_input.get("images")
    if images is not None:
        if not isinstance(images, list) or not all(isinstance(x, dict) and "name" in x and "image" in x for x in images):
            return None, "'images' must be a list of objects with 'name' and 'image'"

    return {"workflow": workflow, "images": images}, None

# ------------------------- Comfy interactions -------------------------

def upload_init_images(images: List[Dict[str, str]]) -> None:
    """Upload init images to ComfyUI via /upload (if your workflow references them)."""
    for img in images:
        name = img["name"]
        b = try_decode_b64uri(img["image"])
        files = {"image": (name, b)}
        data = {"subfolder": "", "type": "input"}
        r = requests.post(f"{COMFY_BASE}/upload/image", files=files, data=data, timeout=60)
        r.raise_for_status()
        log(f"uploaded init image: {name}")

def queue_prompt(workflow: Dict[str, Any], client_id: str) -> str:
    """POST the workflow to /prompt and return the prompt_id."""
    payload = {"prompt": workflow, "client_id": client_id}
    r = requests.post(PROMPT_URL, json=payload, timeout=120)
    if r.status_code != 200:
        raise RuntimeError(f"Error queuing workflow: {r.status_code} {r.text}")
    data = r.json()
    prompt_id = data.get("prompt_id") or data.get("promptId") or data.get("id")
    if not prompt_id:
        raise RuntimeError(f"Missing prompt_id in response: {data}")
    return prompt_id

def ws_listen(client_id: str, prompt_id: str) -> List[Dict[str, Any]]:
    """Connect to websocket and collect 'executed' messages for this prompt_id."""
    outputs = []
    attempts = 0
    start_time = time.time()

    while attempts <= WEBSOCKET_RECONNECT_ATTEMPTS:
        try:
            ws = websocket.create_connection(f"{WS_URL}?clientId={client_id}", timeout=WEBSOCKET_RECEIVE_TIMEOUT)
            ws.settimeout(WEBSOCKET_RECEIVE_TIMEOUT)
            log(f"websocket connected (attempt {attempts+1})")

            while True:
                if time.time() - start_time > MAX_EXECUTION_TIME:
                    raise TimeoutError("Maximum execution time exceeded.")
                try:
                    msg = ws.recv()
                except websocket.WebSocketTimeoutException:
                    # keep alive
                    continue

                if not msg:
                    continue
                try:
                    data = json.loads(msg)
                except Exception:
                    continue

                if data.get("type") == "executed":
                    outputs.append(data)
                elif data.get("type") == "execution_error":
                    raise RuntimeError(f"Comfy execution_error: {data}")

                if data.get("type") == "status":
                    status = data.get("data", {}).get("status")
                    if status in ("finished", "success"):
                        ws.close()
                        return outputs
        except (websocket.WebSocketException, socket.error) as e:
            attempts += 1
            log(f"ws reconnect in {WEBSOCKET_RECONNECT_DELAY_S}s ({attempts}/{WEBSOCKET_RECONNECT_ATTEMPTS}) — {e}")
            time.sleep(WEBSOCKET_RECONNECT_DELAY_S)
        except Exception:
            raise
    raise RuntimeError("Websocket reconnect attempts exhausted.")

def collect_artifacts(outputs_msgs: List[Dict[str, Any]]) -> List[Dict[str, str]]:
    """Parse 'executed' messages and build a list of artifacts descriptors."""
    artifacts: List[Dict[str, str]] = []
    for msg in outputs_msgs:
        d = msg.get("data", {})
        out = d.get("output", {}) or {}
        for key in ("images", "video", "gifs", "output"):
            items = out.get(key)
            if not items:
                continue
            if isinstance(items, list):
                for it in items:
                    fn = it.get("filename")
                    if not fn:
                        continue
                    ext = Path(fn).suffix.lower()
                    kind = "video" if ext in VIDEO_EXTS else "image"
                    artifacts.append({
                        "type": kind,
                        "subfolder": it.get("subfolder", ""),
                        "filename": fn,
                        "format": it.get("format", ext.lstrip(".")) or ext.lstrip(".")
                    })
    return artifacts

def read_file_b64(local_path: str) -> str:
    with open(local_path, "rb") as f:
        return base64.b64encode(f.read()).decode("utf-8")

# ------------------------------ Handler ------------------------------

def handler(job):
    """
    RunPod entrypoint. Supports:
      1) Echo:   {"input":{"ping":"pong"}}
      2) Dry-run {"input":{"dry_run": true}}
      3) Comfy:  {"input":{"workflow": {...}, "images":[...]?}}
    """
    job_id = job.get("id") or str(uuid.uuid4())
    try:
        # --------- Fast paths: echo / dry_run ---------
        raw_input = job.get("input") or {}
        if isinstance(raw_input, str):
            try:
                raw_input = json.loads(raw_input)
            except Exception:
                pass

        if isinstance(raw_input, dict):
            if "ping" in raw_input:
                # Plain echo for health/latency checks
                return {"status": "ok", "echo": raw_input.get("ping")}
            if raw_input.get("dry_run"):
                return {"status": "ok", "message": "dry_run"}

        # --------- Normal Comfy path ---------
        validated, err = validate_and_prepare(raw_input)
        if err:
            return {"error": err}

        workflow = validated["workflow"]
        images = validated.get("images") or []

        # Ensure API up
        if not check_server(f"{COMFY_BASE}/", retries=API_CHECK_MAX_RETRIES, delay_ms=API_CHECK_DELAY_MS):
            return {"error": f"Comfy API not reachable at {COMFY_BASE}"}

        # Upload init images if provided
        if images:
            upload_init_images(images)

        # Queue prompt
        client_id = str(uuid.uuid4())
        prompt_id = queue_prompt(workflow, client_id)
        log(f"queued prompt_id={prompt_id}")

        callback_api({"action": "queued", "job_id": job_id, "prompt_id": prompt_id})

        # Listen for execution
        executed_msgs = ws_listen(client_id, prompt_id)
        artifacts = collect_artifacts(executed_msgs)

        if not artifacts:
            callback_api({"action": "complete", "job_id": job_id, "result": {"status": "success_no_outputs", "artifacts": []}})
            return {"status": "success_no_outputs", "artifacts": []}

        # Build response and cleanup list
        just_produced_files: List[str] = []
        results: List[Dict[str, Any]] = []

        for a in artifacts:
            sub = a.get("subfolder", "")
            fn = a["filename"]
            local_path = str((OUTPUT_ROOT / sub / fn).resolve())
            just_produced_files.append(local_path)

            if RETURN_MODE == "url":
                uploaded = rp_upload.upload_file(local_path)
                results.append({
                    "type": a["type"],
                    "filename": fn,
                    "subfolder": sub,
                    "format": a.get("format"),
                    "url": uploaded.get("url")
                })
            else:
                b64 = read_file_b64(local_path)
                results.append({
                    "type": a["type"],
                    "filename": fn,
                    "subfolder": sub,
                    "format": a.get("format"),
                    "base64": b64
                })

        response = {
            "status": "success",
            "artifacts": results
        }

        cleanup_outputs(just_produced_files)
        callback_api({"action": "complete", "job_id": job_id, "result": {"status": "success", "count": len(results)}})
        return response

    except Exception as e:
        tb = traceback.format_exc()
        log(f"ERROR: {e}\n{tb}")
        callback_api({"action": "error", "job_id": job_id, "error": str(e)})
        return {"error": str(e)}

# ------------------------------ Bootstrap ----------------------------

if __name__ == "__main__":
    log("Starting RunPod serverless handler…")
    runpod.serverless.start({"handler": handler})
