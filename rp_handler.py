# /workspace/comfywan/rp_handler.py — full replacement

import os
import json
import time
from typing import Any, Dict, List, Tuple

import requests

# ------------------------------------------------------------------------------
# Config
# ------------------------------------------------------------------------------
COMFY_HOST = os.environ.get("COMFY_HOST", "127.0.0.1")
COMFY_PORT = int(os.environ.get("COMFY_PORT", "8188"))
COMFY_URL = f"http://{COMFY_HOST}:{COMFY_PORT}"
WORKFLOWS_DIR = os.environ.get("WORKFLOWS_DIR", "/workspace/comfywan/workflows")
COMFY_WAIT_TIMEOUT = int(os.environ.get("COMFY_WAIT_TIMEOUT", "10"))  # seconds

# ------------------------------------------------------------------------------
# Optional HTTP health route (if runpod.serverless.flask is present)
# ------------------------------------------------------------------------------
try:
    from runpod.serverless import flask as rp_flask

    @rp_flask.route("/health", methods=["GET"])
    def __health_route__():
        return {"ok": True}, 200
except Exception:
    # If the flask shim isn't available, ignore — job-level health still works.
    pass

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
def _is_truthy(x: Any) -> bool:
    return str(x).lower() in ("1", "true", "yes", "on")


def _wait_for_comfy(timeout_s: int = COMFY_WAIT_TIMEOUT) -> bool:
    """Try a few times to hit ComfyUI /system_stats. Non-fatal."""
    end = time.time() + timeout_s
    url = f"{COMFY_URL}/system_stats"
    while time.time() < end:
        try:
            r = requests.get(url, timeout=1.5)
            if r.ok:
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


def _load_workflow_from_disk(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _normalize_workflow(obj: Any) -> Tuple[List[Dict[str, Any]], List[Any]]:
    """
    Accepts typical ComfyUI exports and older/raw formats:
      - {"nodes":[...], "links":[...], "last_node_id":...}
      - [{"id":..., "type":...}, ...]   # list of node dicts
      - {"graph":{"nodes":[...], "links":[...]}}
      - {"workflow":[...]}              # some tools dump like this
    Returns (nodes, links).
    """
    if isinstance(obj, list):
        nodes = obj
        links = []
    elif isinstance(obj, dict):
        nodes = obj.get("nodes")
        links = obj.get("links", [])

        if nodes is None and isinstance(obj.get("graph"), dict):
            nodes = obj["graph"].get("nodes")
            links = obj["graph"].get("links", [])

        if nodes is None and isinstance(obj.get("graph"), list):
            nodes = obj["graph"]

        if nodes is None and isinstance(obj.get("workflow"), list):
            nodes = obj["workflow"]
    else:
        raise ValueError("workflow must be a dict or a list")

    if not isinstance(nodes, list):
        raise ValueError("workflow 'nodes' must be a list")

    if not isinstance(links, list):
        links = []

    return nodes, links


def _assert_workflow_ok(workflow_spec: Any) -> bool:
    """
    Validate a workflow spec. Accepts either:
      - str path to JSON file, or
      - Python object (dict/list) already loaded.
    Raises ValueError on problems; returns True if valid.
    """
    obj = _load_workflow_from_disk(workflow_spec) if isinstance(workflow_spec, str) else workflow_spec
    nodes, _links = _normalize_workflow(obj)

    for i, node in enumerate(nodes):
        if not isinstance(node, dict):
            raise ValueError(f"node[{i}] is not a dict")
        if "type" not in node:
            raise ValueError(f"node[{i}] missing 'type'")
    return True


def _resolve_workflow_path(name_or_path: str) -> str:
    """Resolve relative workflow filenames against WORKFLOWS_DIR."""
    if os.path.isabs(name_or_path):
        return name_or_path
    return os.path.join(WORKFLOWS_DIR, name_or_path)

# ------------------------------------------------------------------------------
# Core handler
# ------------------------------------------------------------------------------
def rp_handler(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    RunPod entrypoint. Supports:
      - {"input":{"health":true}}
      - {"input":{"dry_run":true,"workflow":"wan2.2-t2v.json"}}
      - Normal invocations (extend run_job(...) for your real logic)
    """
    inp = (event or {}).get("input", {})

    # Health ping (instant)
    if _is_truthy(inp.get("health")):
        return {"status": "ok"}

    # Dry-run: verify workflow exists and is structurally valid
    if _is_truthy(inp.get("dry_run")):
        wf_name = inp.get("workflow")
        if not wf_name:
            return {"error": "Missing 'workflow' parameter"}
        wf_path = _resolve_workflow_path(wf_name)
        if not os.path.isfile(wf_path):
            return {"error": f"workflow not found: {wf_path}"}
        _assert_workflow_ok(wf_path)  # <-- fixes "node last_node_id not a dict"
        comfy_ready = _wait_for_comfy()
        return {"status": "ok", "workflow": wf_name, "comfy_ready": bool(comfy_ready)}

    # Normal flow: validate workflow if provided, then do work
    wf_name = inp.get("workflow")
    wf_path = None
    if wf_name:
        wf_path = _resolve_workflow_path(wf_name)
        if not os.path.isfile(wf_path):
            return {"error": f"workflow not found: {wf_path}"}
        _assert_workflow_ok(wf_path)

    _wait_for_comfy()
    return run_job(inp, wf_path)

# ------------------------------------------------------------------------------
# Your actual job logic — edit as needed
# ------------------------------------------------------------------------------
def run_job(inp: Dict[str, Any], workflow_path: str | None) -> Dict[str, Any]:
    """
    Placeholder. Extend to:
      - load/patch the workflow,
      - POST to ComfyUI's API,
      - poll and return results.
    """
    resp = {"status": "ok", "workflow_path": workflow_path, "echo_input_keys": sorted(inp.keys())}
    try:
        r = requests.get(f"{COMFY_URL}/system_stats", timeout=1.5)
        if r.ok:
            resp["system_stats"] = r.json()
    except Exception:
        pass
    return resp

# ------------------------------------------------------------------------------
# IMPORTANT: RunPod calls `handler(job)` in your trace; expose that alias.
# ------------------------------------------------------------------------------
handler = rp_handler
