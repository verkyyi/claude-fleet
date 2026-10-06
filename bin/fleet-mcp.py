#!/usr/bin/env python3
"""fleet-mcp.py — the fleet's one local tool service (issue #1807, EPIC #1813 C5).

A plain stdio MCP server (newline-delimited JSON-RPC, stdlib only — macOS ships
python 3.9 and nothing here may need a pip install). Every Claude AND every Codex
session the fleet opens mounts it under the server name `fleet`, so both agents
see the same tools (Claude shows them as mcp__fleet__<action>):

  status    read-only: this window's binding + its children + the hosted repos
  children  read-only: bin/fleet-children.sh --json
  repos     read-only: bin/fleet-repo.sh list
  agents    read-only: the live sessions of this fleet, parent/child marked
  spawn     issue [+ repo]          → bin/dash-issue-session.sh
  await     issue [+ repo, timeout] → bin/fleet-await.sh
  send      to + text               → bin/fleet-peer-send.sh

docs/FLEET-MCP.md is the one spec; later EPIC members add tools there and here.

The rule (EPIC #1813 decision 4, same as mod/fleet/hooks/tools.ts): a tool only
CHECKS its arguments — an unknown or missing argument, a wrong type, a repo this
fleet does not host is refused with the reason and NOTHING runs — then runs the
existing script unchanged and hands back its exit code, stdout and stderr as they
came. Caps, claim dedup and guards live in the scripts, once.

  fleet-mcp.py                 serve on stdin/stdout
  fleet-mcp.py --mount codex   print the `-c` value bin/fleet-codex.sh mounts it with
  fleet-mcp.py --legacy-peer   the old fleet-peer server (list_agents/send_message)
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

BIN = Path(__file__).resolve().parent
SERVER = "fleet"
VERSION = "0.1.0"

# fleet-await.sh blocks; the cap and default match the mod's (tools.ts).
AWAIT_MAX_S = 570
AWAIT_DEFAULT_S = 540
AWAIT_SLACK_S = 25
SPAWN_TIMEOUT_S = 120
STATUS_TIMEOUT_S = 30

# Codex hands an MCP server only a short env allowlist (HOME, PATH, USER, …);
# these are what the scripts need to find the pane, the fleet and the install.
CODEX_ENV = ["TMUX", "TMUX_PANE", "FLEET_CONF_DIR", "FLEET_SESSION", "FLEET_MCP_BIN"]
# A blocking await outlives Codex's 60s default per-call timeout.
CODEX_TOOL_TIMEOUT_S = AWAIT_MAX_S + AWAIT_SLACK_S + 5


class ToolFault(Exception):
    def __init__(self, message):
        super().__init__(message)
        self.message = message


class Refused(ToolFault):
    """Arguments that do not fit: said with the reason, nothing ran."""


def run(argv, *, input_text=None, check=True, timeout=None):
    try:
        result = subprocess.run(argv, input=input_text, text=True, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise ToolFault("%s did not answer within %ss" % (Path(argv[0]).name, timeout))
    except OSError as exc:
        raise ToolFault("%s could not start: %s" % (argv[0], exc))
    if check and result.returncode != 0:
        msg = (result.stderr or result.stdout or "command failed").strip().replace("\n", " ")
        raise ToolFault(msg)
    return result


def tmux(*args):
    return run(["tmux", *args], timeout=STATUS_TIMEOUT_S).stdout.rstrip("\n")


def shquote(value):
    return "'" + value.replace("'", "'\\''") + "'"


def lib(script, check=True):
    return run(["bash", "-c", ". " + shquote(str(BIN / "fleet-lib.sh")) + "; " + script],
               check=check, timeout=STATUS_TIMEOUT_S)


def current_session():
    pane = os.environ.get("TMUX_PANE", "")
    if not os.environ.get("TMUX") or not pane:
        raise ToolFault("not running inside a fleet tmux pane")
    sess = tmux("display-message", "-p", "-t", pane, "#{?#{session_group},#{session_group},#{session_name}}")
    if not sess:
        raise ToolFault("could not resolve the current fleet session")
    return sess


def origin_key():
    return lib("fleet_origin_key 2>/dev/null || true").stdout.strip()


def origin_option():
    pane = os.environ.get("TMUX_PANE", "")
    return tmux("display-message", "-p", "-t", pane, "#{@origin}") if pane else ""


def fleet_hosts_many(session):
    return lib("_fleet_hosts_many " + shquote(session), check=False).returncode == 0


# --- agents / send (moved from fleet-peer-mcp.py, issue #1185) ------------------

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
    result = run(["bash", str(BIN / "fleet-children.sh"), "--json"], check=False, timeout=STATUS_TIMEOUT_S)
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
        if len(parts) != 12 or parts[1] != session or parts[2] in ("dash", "plan", "backlog", "home"):
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
    # The ONE resolver (fleet_win_for_key, issue #1537): rc 2 = the key is
    # ambiguous (two windows, or a bare issue key in a 2+ repo fleet) — said on
    # stderr; never a pick. A warm-pool window never answers.
    # By IDENTITY first (issue #1646): fleet_origin_win reads this pane's
    # @origin_fid — the parent may have changed its key since it spawned us —
    # and falls back to the key through the same resolver.
    res = lib("fleet_origin_win " + shquote(session) + " " + shquote(os.environ["TMUX_PANE"])
              if os.environ.get("TMUX_PANE") else
              "fleet_win_for_key " + shquote(parent) + " " + shquote(session), check=False)
    wid = res.stdout.strip()
    if res.returncode == 2:
        why = (res.stderr or "").strip().replace("\n", " ")
        raise ToolFault("parent %s is ambiguous in this fleet — %s" % (parent, why or "several windows answer to it"))
    if res.returncode != 0 or not wid:
        raise ToolFault("parent is not online in this fleet")
    return wid


def send_message(to, text):
    if not isinstance(to, str) or not to.strip():
        raise Refused("to is required")
    if not isinstance(text, str) or not text.strip():
        raise Refused("text is required")
    target = to.strip()
    if target != "parent" and not re.match(
            r"^(issue:[0-9]+|#[0-9]+|issue-[0-9]+|scratch-[0-9]+|[@%][A-Za-z0-9_.:-]+)$", target):
        raise Refused("to must be issue:<N>, scratch-<N> or parent")
    if target == "parent":
        target = parent_window()
    result = run(["bash", str(BIN / "fleet-peer-send.sh"), target, "-"], input_text=text, check=False,
                 timeout=STATUS_TIMEOUT_S)
    # Exit 3 = queued (issue #1647): the peer cannot take it now; it is delivered
    # when it can. Not delivered — and not an error either.
    if result.returncode == 3:
        return {"delivered": False, "queued": True, "receipt": result.stdout.strip(), "to": to}
    # Exit 2 with a stdout line = the peer has ENDED (issue #1649): when and how,
    # nothing sent. Exit 2 with only stderr is a usage refusal, raised below.
    if result.returncode == 2 and result.stdout.strip():
        return {"delivered": False, "ended": True, "receipt": result.stdout.strip(), "to": to}
    if result.returncode != 0:
        raise ToolFault((result.stderr or result.stdout or "command failed").strip().replace("\n", " "))
    return {"delivered": True, "receipt": result.stdout.strip(), "to": to}


# --- the script-backed tools (same contract as mod/fleet/hooks/tools.ts) --------

def script(argv, timeout):
    """Run a script unchanged; its exit code, stdout and stderr come back as they came."""
    r = run(argv, check=False, timeout=timeout)
    return {"command": Path(argv[0]).name, "exit": r.returncode, "stdout": r.stdout, "stderr": r.stderr}


def hosted_repos():
    """The repos `fleet-repo.sh list` prints (two-space-indented rows, repo first)."""
    r = run([str(BIN / "fleet-repo.sh"), "list"], check=False, timeout=STATUS_TIMEOUT_S)
    out = []
    for line in r.stdout.splitlines():
        m = re.match(r"^ {2}(\S+/\S+)\s", line)
        if m:
            out.append(m.group(1))
    return out, r


def check_repo(args):
    repo = args.get("repo")
    if repo is None:
        return []
    repos, _ = hosted_repos()
    if repo not in repos:
        raise Refused('repo "%s" is not hosted by this fleet (hosted: %s)'
                      % (repo, ", ".join(repos) if repos else "none could be read"))
    return ["--repo", repo]


def tool_status(_args):
    pane = os.environ.get("TMUX_PANE", "")
    window = None
    if os.environ.get("TMUX") and pane:
        window = run(["tmux", "display-message", "-p", "-t", pane,
                      "window #{window_name} · issue=#{@issue} repo=#{@repo} state=#{@claude_state} "
                      "lifecycle=#{@worker_lifecycle} origin=#{@origin}"],
                     check=False, timeout=STATUS_TIMEOUT_S).stdout.strip() or None
    kids = script([str(BIN / "fleet-children.sh")], STATUS_TIMEOUT_S)
    repos, listed = hosted_repos()
    return {"window": window, "children": kids, "repos": repos,
            "repo_list": listed.stdout.rstrip("\n")}


def tool_children(_args):
    return script([str(BIN / "fleet-children.sh"), "--json"], STATUS_TIMEOUT_S)


def tool_repos(_args):
    repos, listed = hosted_repos()
    return {"command": "fleet-repo.sh", "exit": listed.returncode, "repos": repos,
            "stdout": listed.stdout, "stderr": listed.stderr}


def tool_spawn(args):
    repo = check_repo(args)
    return script([str(BIN / "dash-issue-session.sh"), str(args["issue"])] + repo, SPAWN_TIMEOUT_S)


def tool_await(args):
    repo = check_repo(args)
    t = args.get("timeout", AWAIT_DEFAULT_S)
    return script([str(BIN / "fleet-await.sh"), str(args["issue"]), "--timeout", str(t)] + repo,
                  t + AWAIT_SLACK_S)


def tool_agents(_args):
    return list_agents()


def tool_send(args):
    return send_message(args.get("to"), args.get("text"))


ISSUE = {"type": "integer", "minimum": 1, "description": 'The GitHub issue number (a positive integer, no "#").'}
REPO = {"type": "string", "pattern": r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$",
        "description": "owner/name of a repo THIS fleet hosts (the repos tool lists them). "
                       "Omit for the fleet's default repo."}
NO_ARGS = {"type": "object", "properties": {}, "additionalProperties": False}

TOOLS = {
    "status": (tool_status, {
        "description": "Read-only. This fleet window's binding (issue, repo, state, origin), every child session "
                       "it spawned (bin/fleet-children.sh) and the repos this fleet hosts. Changes nothing.",
        "inputSchema": NO_ARGS}),
    "children": (tool_children, {
        "description": "Read-only. Every child session this one spawned — ledger outcome, live state, PR — "
                       "as bin/fleet-children.sh --json prints it.",
        "inputSchema": NO_ARGS}),
    "repos": (tool_repos, {
        "description": "Read-only. The GitHub repos this fleet hosts (bin/fleet-repo.sh list).",
        "inputSchema": NO_ARGS}),
    "agents": (tool_agents, {
        "description": "Read-only. The live sessions in this fleet: issue, agent (claude/codex), state, and "
                       "whether each is this session, its parent or its child.",
        "inputSchema": NO_ARGS}),
    "spawn": (tool_spawn, {
        "description": "Start a fleet worker session on a GitHub issue (its own worktree + window; it claims, "
                       "implements and lands the issue itself). Runs bin/dash-issue-session.sh, so the session "
                       "caps and the claim dedup apply. Exit 0 spawned (or the window already exists), 2 at "
                       "capacity, 3 already claimed, 1 infrastructure. Returns at once — await waits for it.",
        "inputSchema": {"type": "object", "properties": {"issue": ISSUE, "repo": REPO},
                        "required": ["issue"], "additionalProperties": False}}),
    "await": (tool_await, {
        "description": "Hand an issue to a worker (spawning one if none is live) and BLOCK until it lands, "
                       "blocks or is reaped; prints the verdict (MERGED / BLOCKED / FAILED / TIMEOUT / REAPED / "
                       "NO-WORKER), PR and summary. Runs bin/fleet-await.sh. TIMEOUT (exit 3) means still "
                       "running — call again to keep waiting (nothing spawns twice).",
        "inputSchema": {"type": "object", "properties": {
            "issue": ISSUE, "repo": REPO,
            "timeout": {"type": "integer", "minimum": 1, "maximum": AWAIT_MAX_S,
                        "description": "Seconds to wait before answering TIMEOUT (default %d, at most %d)."
                                       % (AWAIT_DEFAULT_S, AWAIT_MAX_S)}},
            "required": ["issue"], "additionalProperties": False}}),
    "send": (tool_send, {
        "description": "Send text to a live fleet peer as its next turn (bin/fleet-peer-send.sh). "
                       "to is issue:<N>, scratch-<N> or parent.",
        "inputSchema": {"type": "object", "properties": {"to": {"type": "string"}, "text": {"type": "string"}},
                        "required": ["to", "text"], "additionalProperties": False}}),
}

# The pre-#1807 fleet-peer server, for a config that still mounts it (one version).
LEGACY = {
    "list_agents": (tool_agents, dict(TOOLS["agents"][1])),
    "send_message": (tool_send, dict(TOOLS["send"][1])),
}


def check_args(schema, args):
    """The reason `args` does not fit `schema`, or None when it does."""
    if not isinstance(args, dict):
        return "arguments must be an object"
    props = schema.get("properties", {})
    for key in args:
        if key not in props:
            return 'unknown argument "%s" (takes %s)' % (key, ", ".join(props) if props else "no arguments")
    for key in schema.get("required", []):
        if args.get(key) is None:
            return 'missing required argument "%s"' % key
    for key, p in props.items():
        if key not in args:
            continue
        v = args[key]
        if p["type"] == "integer":
            if not isinstance(v, int) or isinstance(v, bool):
                return '"%s" must be an integer, got %s' % (key, json.dumps(v))
            if "minimum" in p and v < p["minimum"]:
                return '"%s" must be ≥ %d, got %d' % (key, p["minimum"], v)
            if "maximum" in p and v > p["maximum"]:
                return '"%s" must be ≤ %d, got %d' % (key, p["maximum"], v)
        elif p["type"] == "string":
            if not isinstance(v, str) or v == "":
                return '"%s" must be a non-empty string, got %s' % (key, json.dumps(v))
            if "pattern" in p and not re.match(p["pattern"], v):
                return '"%s" must be owner/name, got %s' % (key, json.dumps(v))
    return None


def report(data):
    """A script run, as the model reads it: exit code, stdout, stderr."""
    if not isinstance(data, dict) or "exit" not in data or "command" not in data:
        return json.dumps(data, ensure_ascii=False, sort_keys=True)
    parts = ["exit %s · %s" % (data["exit"], data["command"])]
    if (data.get("stdout") or "").strip():
        parts.append(data["stdout"].rstrip())
    if (data.get("stderr") or "").strip():
        parts.append("[stderr]\n" + data["stderr"].rstrip())
    return "\n".join(parts)


def status_text(data):
    head = "window: " + (data["window"] or "(not in tmux)")
    return "\n\n".join([head, report(data["children"]), data["repo_list"]])


def tool_result(name, data, error=False):
    if error:
        return {"content": [{"type": "text", "text": data}], "isError": True}
    text = status_text(data) if name == "status" else report(data)
    return {"content": [{"type": "text", "text": text}], "structuredContent": data}


def tool_call(table, name, args):
    entry = table.get(name)
    if entry is None:
        return tool_result(name, "%s.%s: unknown tool. Nothing ran." % (SERVER, name), error=True)
    fn, spec = entry
    bad = check_args(spec["inputSchema"], args if args is not None else {})
    if bad is not None:
        return tool_result(name, "%s.%s: %s. Nothing ran." % (SERVER, name, bad), error=True)
    try:
        return tool_result(name, fn(args or {}))
    except Refused as exc:
        return tool_result(name, "%s.%s: %s. Nothing ran." % (SERVER, name, exc.message), error=True)
    except ToolFault as exc:
        return tool_result(name, "%s.%s: %s" % (SERVER, name, exc.message), error=True)


def respond(request, result=None, error=None):
    if "id" not in request:
        return
    msg = {"jsonrpc": "2.0", "id": request["id"]}
    if error:
        msg["error"] = error
    else:
        msg["result"] = result
    print(json.dumps(msg, separators=(",", ":"), ensure_ascii=False), flush=True)


def handle(request, table, name):
    method = request.get("method")
    if method == "initialize":
        asked = (request.get("params") or {}).get("protocolVersion")
        return {"protocolVersion": asked if isinstance(asked, str) and asked else "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": name, "version": VERSION}}
    if method == "tools/list":
        return {"tools": [{"name": n, **spec} for n, (_, spec) in table.items()]}
    if method == "tools/call":
        params = request.get("params") or {}
        return tool_call(table, params.get("name"), params.get("arguments"))
    if method == "ping":
        return {}
    if isinstance(method, str) and method.startswith("notifications/") or method == "$/cancelRequest":
        return None
    raise ToolFault("unsupported MCP method: " + str(method))


def serve(table, name):
    for line in sys.stdin:
        if not line.strip():
            continue
        request = {}
        try:
            request = json.loads(line)
            result = handle(request, table, name)
            if result is not None:
                respond(request, result=result)
        except ToolFault as exc:
            respond(request, error={"code": -32601, "message": exc.message})
        except Exception as exc:
            respond(request, error={"code": -32603, "message": str(exc)})


def toml_str(value):
    return json.dumps(value, ensure_ascii=False)   # a JSON string is a TOML basic string


def mount_codex():
    """The `-c` value that mounts this server in Codex: what conf/mcp-worker.json
    says, plus the env Codex would otherwise withhold and a per-call timeout an
    await fits in."""
    conf = json.loads((BIN.parent / "conf" / "mcp-worker.json").read_text())
    srv = conf["mcpServers"][SERVER]
    fields = ["command=" + toml_str(srv["command"]),
              "args=[" + ",".join(toml_str(a) for a in srv.get("args", [])) + "]",
              "env_vars=[" + ",".join(toml_str(v) for v in CODEX_ENV) + "]",
              "tool_timeout_sec=%d" % CODEX_TOOL_TIMEOUT_S]
    return "mcp_servers.%s={%s}" % (SERVER, ",".join(fields))


def main(argv):
    if argv[:2] == ["--mount", "codex"]:
        print(mount_codex())
        return 0
    if argv[:1] == ["--legacy-peer"]:
        serve(LEGACY, "fleet-peer")
        return 0
    if argv:
        print("usage: fleet-mcp.py [--mount codex | --legacy-peer]", file=sys.stderr)
        return 2
    serve(TOOLS, SERVER)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
