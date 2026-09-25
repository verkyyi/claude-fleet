#!/usr/bin/env python3
"""Tiny stdio MCP server for live peer discovery and delivery inside one fleet."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

BIN = Path(__file__).resolve().parent


class ToolFault(Exception):
    def __init__(self, message):
        super().__init__(message)
        self.message = message


def run(argv, *, input_text=None, check=True):
    result = subprocess.run(argv, input=input_text, text=True, capture_output=True)
    if check and result.returncode != 0:
        msg = (result.stderr or result.stdout or "command failed").strip().replace("\n", " ")
        raise ToolFault(msg)
    return result


def tmux(*args):
    return run(["tmux", *args]).stdout.rstrip("\n")


def current_session():
    pane = os.environ.get("TMUX_PANE", "")
    if not os.environ.get("TMUX") or not pane:
        raise ToolFault("not running inside a fleet tmux pane")
    sess = tmux("display-message", "-p", "-t", pane, "#{session_name}")
    if not sess:
        raise ToolFault("could not resolve the current fleet session")
    return sess


def shell_func(script):
    return run(["bash", "-lc", ". " + shquote(str(BIN / "fleet-lib.sh")) + "; " + script]).stdout.strip()


def shquote(value):
    return "'" + value.replace("'", "'\\''") + "'"


def origin_key():
    return shell_func("fleet_origin_key 2>/dev/null || true")


def origin_option():
    pane = os.environ.get("TMUX_PANE", "")
    return tmux("display-message", "-p", "-t", pane, "#{@origin}") if pane else ""


def fleet_hosts_many(session):
    result = run(["bash", "-lc", ". " + shquote(str(BIN / "fleet-lib.sh")) +
                  "; _fleet_hosts_many " + shquote(session)], check=False)
    return result.returncode == 0


def slug(repo):
    return re.sub(r"[^A-Za-z0-9._-]", "", repo.replace("/", "-"))


def scratch_key(path):
    name = path.rstrip("/").rsplit("/", 1)[-1]
    if name.startswith("scratch-"):
        value = name[8:]
    elif "-scratch-" in name:
        value = name.rsplit("-scratch-", 1)[1]
    else:
        return ""
    return "scratch-" + value if value.isdigit() else ""


def window_key(row, multi):
    if row["issue"].isdigit():
        key = "issue-" + row["issue"]
    else:
        key = scratch_key(row["worktree"]) or scratch_key(row["path"])
        if not key:
            return ""
    if multi:
        repo = row["repo"]
        if not repo or row["norepo"] == "1":
            return ""
        key = slug(repo) + ":" + key
    return key


def child_keys():
    result = run(["bash", str(BIN / "fleet-children.sh"), "--json"], check=False)
    if result.returncode != 0:
        return set()
    try:
        data = json.loads(result.stdout)
    except ValueError:
        return set()
    keys = set()
    for child in data.get("children", []):
        if not isinstance(child, dict):
            continue
        for field in ("child", "key"):
            value = child.get(field)
            if isinstance(value, str) and value:
                keys.add(value)
    return keys


def list_agents():
    session = current_session()
    me = origin_key()
    parent = origin_option()
    kids = child_keys()
    multi = fleet_hosts_many(session)
    fmt = "#{window_id}\t#{session_name}\t#{window_name}\t#{@issue}\t#{@cc_agent}\t" \
          "#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}\t#{@claude_needs}\t" \
          "#{@origin}\t#{@repo}\t#{@norepo}\t#{@worktree}\t#{pane_current_path}"
    out = tmux("list-windows", "-a", "-F", fmt)
    agents = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 12 or parts[1] != session or parts[2] in ("dash", "plan", "backlog"):
            continue
        row = dict(zip(("window_id", "session", "window_name", "issue", "agent", "state", "needs",
                        "origin", "repo", "norepo", "worktree", "path"), parts))
        key = window_key(row, multi)
        state = row["needs"] or row["state"] or "unknown"
        agent = "codex" if row["agent"] == "codex" else "claude"
        agents.append({
            "window_id": row["window_id"],
            "window_name": row["window_name"],
            "issue": int(row["issue"]) if row["issue"].isdigit() else None,
            "agent": agent,
            "state": state,
            "key": key,
            "repo": row["repo"] or None,
            "is_self": bool(me and key == me),
            "is_parent": bool(parent and key == parent),
            "is_child": bool((me and row["origin"] == me) or (key and key in kids)),
        })
    return {"session": session, "self": me or None, "parent": parent or None, "agents": agents}


def parent_window():
    parent = origin_option()
    if not re.match(r"^([A-Za-z0-9._-]+:)?(issue|scratch)-[0-9]+$", parent or ""):
        raise ToolFault("this session has no live-addressable parent")
    session = current_session()
    script = ". " + shquote(str(BIN / "fleet-lib.sh")) + "; fleet_win_for_key " + shquote(parent) + " " + shquote(session)
    wid = run(["bash", "-lc", script], check=False).stdout.strip()
    if not wid:
        raise ToolFault("parent is not online in this fleet")
    return wid


def send_message(to, text):
    if not isinstance(to, str) or not to.strip():
        raise ToolFault("to is required")
    if not isinstance(text, str) or not text.strip():
        raise ToolFault("text is required")
    target = to.strip()
    if target == "parent":
        target = parent_window()
    elif not re.match(r"^(issue:[0-9]+|#[0-9]+|issue-[0-9]+|scratch-[0-9]+|[@%][A-Za-z0-9_.:-]+)$", target):
        raise ToolFault("to must be issue:<N>, scratch-<N> or parent")
    result = run(["bash", str(BIN / "fleet-peer-send.sh"), target, "-"], input_text=text)
    return {"delivered": True, "receipt": result.stdout.strip(), "to": to}


TOOLS = {
    "list_agents": {
        "description": "List live sessions in this fleet, including issue, agent type, state and parent/child relation to this session.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    "send_message": {
        "description": "Send text to a live fleet peer as its next turn. Target is issue:<N>, scratch-<N> or parent.",
        "inputSchema": {
            "type": "object",
            "properties": {"to": {"type": "string"}, "text": {"type": "string"}},
            "required": ["to", "text"],
            "additionalProperties": False,
        },
    },
}


def tool_call(name, args):
    args = args or {}
    if name == "list_agents":
        return list_agents()
    if name == "send_message":
        return send_message(args.get("to"), args.get("text"))
    raise ToolFault("unknown tool: " + str(name))


def respond(request, result=None, error=None):
    if "id" not in request:
        return
    msg = {"jsonrpc": "2.0", "id": request["id"]}
    if error:
        msg["error"] = error
    else:
        msg["result"] = result
    print(json.dumps(msg, separators=(",", ":")), flush=True)


def tool_result(data):
    text = json.dumps(data, ensure_ascii=False, sort_keys=True)
    return {"content": [{"type": "text", "text": text}], "structuredContent": data}


def handle(request):
    method = request.get("method")
    if method == "initialize":
        return {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                "serverInfo": {"name": "fleet-peer", "version": "0.1.0"}}
    if method == "tools/list":
        return {"tools": [{"name": name, **spec} for name, spec in TOOLS.items()]}
    if method == "tools/call":
        params = request.get("params") or {}
        return tool_result(tool_call(params.get("name"), params.get("arguments") or {}))
    if method in ("notifications/initialized", "$/cancelRequest"):
        return None
    raise ToolFault("unsupported MCP method: " + str(method))


def main():
    for line in sys.stdin:
        if not line.strip():
            continue
        request = {}
        try:
            request = json.loads(line)
            result = handle(request)
            if result is not None:
                respond(request, result=result)
        except ToolFault as exc:
            respond(request, error={"code": -32000, "message": exc.message})
        except Exception as exc:
            respond(request, error={"code": -32603, "message": str(exc)})


if __name__ == "__main__":
    main()
