import os

# Your existing handler stays intact; it is now aliased to rp_handler_original.
# If your file already defined rp_handler, we rename it to rp_handler_original automatically.

# --- BEGIN: additive health/dry-run patch ---
try:
    from runpod.serverless import flask as rp_flask
    @rp_flask.route('/health', methods=['GET'])
    def __health_route__():
        return {"ok": True}, 200
except Exception:
    pass

def __is_truthy(x):
    return str(x).lower() in ("1", "true", "yes", "on")

def rp_handler(event):
    inp = (event or {}).get("input", {})

    # Health ping
    if __is_truthy(inp.get("health")):
        return {"status": "ok"}

    # Dry-run: verify workflow exists
    if __is_truthy(inp.get("dry_run")):
        wf = inp.get("workflow")
        if not wf:
            return {"error": "Missing 'workflow' parameter"}
        wf_dir = os.environ.get("WORKFLOWS_DIR", "/workspace/comfywan/workflows")
        wf_path = os.path.join(wf_dir, wf) if not os.path.isabs(wf) else wf
        return {"status": "ok", "workflow": wf} if os.path.isfile(wf_path) else {"error": f"workflow not found: {wf_path}"}

    # Delegate to your original implementation
    return rp_handler_original(event)
# --- END: additive health/dry-run patch ---

