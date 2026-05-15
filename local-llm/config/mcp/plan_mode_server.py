#!/usr/bin/env python3
"""Plan mode MCP server — toggles plan/act mode via a file-based flag.

Exposes three tools: plan_mode_enable, plan_mode_disable, plan_mode_status.
The toggle file at ~/.config/crush/plan-mode controls the mode state.
A PreToolUse hook in crush.json checks for this file and blocks write tools.
"""

import json
import sys
from pathlib import Path

TOGGLE_FILE = Path.home() / ".config" / "crush" / "plan-mode"
TOGGLE_FILE.parent.mkdir(parents=True, exist_ok=True)

SERVER_INFO = {"name": "plan-mode", "version": "1.0.0"}

TOOLS = [
    {
        "name": "plan_mode_enable",
        "description": "Enable plan mode. Blocks all write tools (bash, edit, write). The agent should analyze and suggest without modifying files.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "plan_mode_disable",
        "description": "Disable plan mode (enter act mode). Unblocks all write tools. The agent can now execute changes.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "plan_mode_status",
        "description": "Check whether plan mode is currently enabled or disabled.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
]


def handle_request(req: dict) -> dict | None:
    method = req.get("method", "")

    if method == "initialize":
        return {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": SERVER_INFO,
        }

    if method == "notifications/initialized":
        return None

    if method == "tools/list":
        return {"tools": TOOLS}

    if method == "tools/call":
        tool = (req.get("params") or {}).get("name", "")

        if tool == "plan_mode_enable":
            TOGGLE_FILE.touch()
            return {"content": [{"type": "text", "text": "🔒 Plan mode enabled. Write tools are now blocked. Analyze and suggest without making changes."}]}

        if tool == "plan_mode_disable":
            TOGGLE_FILE.unlink(missing_ok=True)
            return {"content": [{"type": "text", "text": "🔓 Act mode enabled. Write tools are now unblocked. You may proceed with implementation."}]}

        if tool == "plan_mode_status":
            if TOGGLE_FILE.exists():
                return {"content": [{"type": "text", "text": "🔒 Plan mode is ACTIVE. Write tools are blocked."}]}
            return {"content": [{"type": "text", "text": "🔓 Act mode is ACTIVE. Write tools are allowed."}]}

        return {"content": [{"type": "text", "text": f"Unknown tool: {tool}"}], "isError": True}

    return {"error": {"code": -32601, "message": f"Method not found: {method}"}}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            result = handle_request(req)
            if result is None:
                continue
            response = {"jsonrpc": "2.0", "id": req.get("id"), "result": result}
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()
        except Exception as e:
            response = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": str(e)}}
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
