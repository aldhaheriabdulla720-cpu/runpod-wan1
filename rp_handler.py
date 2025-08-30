# rp_handler.py — full replacement with health, dry-run, and robust workflow validator
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
# Optional HTTP health route (if using runpod.serverless.flask)
# ------------------------------------------------------------------------------
try:
    from runpod.serverless import flask as rp_flask

    @rp_flask.route("/health", methods=["GET"])
    def __health_route__():
        return {"ok": True}, 200
except Exception:
    # If runpod.serverless.flask isn't available, ignore — job-level health still works.
    pass


# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
def _is_truthy(x: Any) -> bool:
    return str(x).lower() in ("1", "true", "yes", "on")


def _wait_for_comfy(timeout_s: int = COMFY_WAIT_TIMEOUT) -> bool:
    """Try a few times to hit ComfyUI /system_stats. Non-fatal if not up yet."""
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
      - {"workflow":[...]}  # some tools dump like this

    Returns (nodes, links) where nodes is always a list[dict], links is a list.
    """
    if isinstance(obj, list):
        nodes = obj
        links = []
    elif isinstance(obj, dict):
        # Common case
        nodes = obj.get("nodes")
        links = obj.get("links", [])

        # Alt nesting
        if nodes is None and isinstance(obj.get("graph"), dict):
            nodes = obj["graph"].get("nodes")
            links = obj["graph"].get("links", [])

        # Some exotic variants: graph as a list, or workflow key
        if nodes is None and isinstance(obj.get("graph"), list):
            nodes = obj["graph"]
        if nodes is None and isinstance(obj.get("workflow"), list):
            nodes = obj["workflow"]
    else:
        raise ValueError("workflow must be a dict or a list")

    if not isinstance(nodes, list):
        raise ValueError("workflow 'nodes' must be a list")

    if not isinstance(links, list):
        # Be lenient: if links present but malformed, coerce to empty list.
        links = []

    return nodes, links


def _assert_workflow_ok(workflow_spec: Any) -> bool:
    """
    Validate a workflow spec. Accepts either:
      - str path to JSON file, or
      - Python object (dict/list) already loaded.

    Raises ValueError on problems; returns True if valid enough for execution.
    """
    obj = _load_workflow_from_disk(workflow_spec) if isinstance(workflow_spec, str) else workflow_spec
    nodes, _links = _normalize_workflow(obj)

    # Basic per-node checks
    for i, node in enumerate(nodes):
        if not isinstance(node, dict):
            raise ValueError(f"node[{i}] is not a dict")
        if "type" not in node:
            raise ValueError(f"node[{i}] missing 'type'")
        # Some exports omit 'id' — we won't enforce it hard:
        # if "id" not in node:
        #     raise ValueError(f"node[{i}] missing 'id'")

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
      - {"input":{"health":true}}  -> fast OK
      - {"input":{"dry_run":true,"workflow":"wan2.2-t2v.json"}} -> validates JSON shape
      - Normal calls: you can extend run_job(...) to actually run a Comfy workflow.
    """
    inp = (event or {}).get("input", {})

    # 1) Health ping (fast, zero dependencies)
    if _is_truthy(inp.get("health")):
        return {"status": "ok"}

    # 2) Dry-run: verify the workflow JSON exists and is structurally valid
    if _is_truthy(inp.get("dry_run")):
        wf_name = inp.get("workflow")
        if not wf_name:
            return {"error": "Missing 'workflow' parameter"}
        wf_path = _resolve_workflow_path(wf_name)
        if not os.path.isfile(wf_path):
            return {"error": f"workflow not found: {wf_path}"}
        # Validate structure (this fixes: ValueError 'node last_node_id not a dict')
        _assert_workflow_ok(wf_path)
        # Optionally, confirm Comfy is reachable (non-fatal)
        comfy_ready = _wait_for_comfy()
        return {"status": "ok", "workflow": wf_name, "comfy_ready": bool(comfy_ready)}

    # 3) Normal work — validate workflow if provided, then delegate.
    wf_name = inp.get("workflow")
    wf_path = None
    if wf_name:
        wf_path = _resolve_workflow_path(wf_name)
        if not os.path.isfile(wf_path):
            return {"error": f"workflow not found: {wf_path}"}
        _assert_workflow_ok(wf_path)

    # OPTIONAL: Ensure Comfy is up before proceeding with real work
    _wait_for_comfy()

    # Delegate to your actual job logic (edit this function to suit your needs)
    return run_job(inp, wf_path)


# ------------------------------------------------------------------------------
# Your actual job logic — EDIT AS NEEDED
# ------------------------------------------------------------------------------
def run_job(inp: Dict[str, Any], workflow_path: str | None) -> Dict[str, Any]:
    """
    Minimal placeholder. Extend this to:
      - load/patch the workflow graph,
      - POST to ComfyUI's API,
      - poll for results and return outputs.
    Right now we just acknowledge validation success and echo inputs.
    """
    resp = {
        "status": "ok",
        "workflow_path": workflow_path,
        "echo_input_keys": sorted(list(inp.keys())),
    }

    # Example: include some Comfy stats if available (non-fatal)
    try:
        r = requests.get(f"{COMFY_URL}/system_stats", timeout=1.5)
        if r.ok:
            resp["system_stats"] = r.json()
    except Exception:
        pass

    return resp
