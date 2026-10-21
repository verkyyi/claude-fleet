#!/usr/bin/env python3
"""fleet_mcp_gateway.py — the MCP servers a session opens when it needs them (T716 F).

A worker session starts with only the fleet's own servers, GitHub and the remote
(http) connectors — every local MCP server is a process, and a dozen of them at
each start is what a busy machine pays for (EPIC 启动提速, T716). The rest stay
one call away: the `fleet` server (bin/fleet-mcp.py) serves three tools from here

    mcp_list            what this machine / login has configured, and what is on
    mcp_enable <name>   start that server NOW and serve its tools in THIS session
                        (`<name>__<tool>`), then tell the client the list changed
                        (notifications/tools/list_changed — Claude Code re-lists
                        at once; no reopen, no lost context)
    mcp_disable <name>  stop it; its tools go

What may be enabled is only what the login already configured — user scope
(~/.claude.json mcpServers), the project's own (~/.claude.json projects[<dir>],
<repo>/.mcp.json), an enabled plugin's .mcp.json and the fleet/team layer the
launcher composed (FLEET_MCP_TEAM_FILE) — never a new source of credentials: each
backend runs its own command with its own environment (minus the session's fleet
credential), exactly as Claude Code would. A local (stdio) server is proxied;
a remote one (http / sse) is left to Claude Code itself (its sign-in lives there)
and the lean start keeps those connected anyway. Each backend is its own process
with its own reader: one that hangs or dies answers its own calls with an error
and leaves the others alone (FLEET_MCP_GATEWAY_CALL_SECS per call, 120).

Every enable / disable is one line in $FLEET_CONF_DIR/logs/mcp-enable.ndjson
({ts, fid, repo, name, action}); `fleet_mcp_gateway.py stats [--days N]` counts
them per repo — what `FLEET_MCP_EXTRA` (a repo's default extras) is tuned from.

    fleet_mcp_gateway.py lean-config <out.json>   the lean start's strict config
                        for a worker launch (fleet-launch-lib.sh fleet_launch_mcp):
                        GitHub + every remote server + FLEET_MCP_EXTRA's names
    fleet_mcp_gateway.py stats [--days N]         enables per repo · server

Codex reads a tool list once (it only logs list_changed): an enable there is
remembered for the window (its @fleet_id's gateway file) and served from the
next launch of the same conversation (↵ on the recovery page, or the fleet's
reopen) — the answer says so.
"""
import json
import os
import re
import subprocess
import sys
import threading
import time

# the fleet's own servers: never proxied (they are this process, or mounted beside it)
OWN = {"fleet", "fleet-orch"}
# kept connected at a worker's start (lean-config), besides every remote one
KEEP_DEFAULT = ("github",)
PROTOCOL = "2024-11-05"
SEP = "__"


def conf_dir():
    return os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet")


def _read_json(path):
    try:
        with open(path) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _repo_root(cwd):
    try:
        out = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], stdin=subprocess.DEVNULL,
                             capture_output=True, text=True, timeout=5)
        return out.stdout.strip() or cwd
    except (OSError, subprocess.SubprocessError):
        return cwd


def configured(cwd=None, home=None):
    """{name: (config, source)} — every MCP server this login could start here, in
    Claude Code's own precedence (local project > project .mcp.json > user >
    plugin > the fleet/team layer): a name met first wins."""
    home = home or os.path.expanduser("~")
    cwd = cwd or os.getcwd()
    root = _repo_root(cwd)
    out = {}

    def add(servers, source):
        if not isinstance(servers, dict):
            return
        for name, cfg in servers.items():
            if isinstance(name, str) and isinstance(cfg, dict) and name not in out and name not in OWN:
                out[name] = (cfg, source)

    cj = _read_json(os.path.join(home, ".claude.json"))
    projects = cj.get("projects") if isinstance(cj.get("projects"), dict) else {}
    for d in (cwd, root):
        p = projects.get(d)
        if isinstance(p, dict):
            add(p.get("mcpServers"), "local")
    add(_read_json(os.path.join(root, ".mcp.json")).get("mcpServers"), "project")
    add(cj.get("mcpServers"), "user")
    settings = _read_json(os.path.join(home, ".claude", "settings.json"))
    enabled = settings.get("enabledPlugins") if isinstance(settings.get("enabledPlugins"), dict) else {}
    plugins = _read_json(os.path.join(home, ".claude", "plugins", "installed_plugins.json")).get("plugins") or {}
    for pid, rows in (plugins.items() if isinstance(plugins, dict) else []):
        if not enabled.get(pid):
            continue
        for row in rows if isinstance(rows, list) else []:
            path = row.get("installPath") if isinstance(row, dict) else None
            if path:
                m = _read_json(os.path.join(path, ".mcp.json"))
                add(m.get("mcpServers", m if "mcpServers" not in m and all(isinstance(v, dict) for v in m.values()) else {}),
                    "plugin " + pid.split("@")[0])
    team = os.environ.get("FLEET_MCP_TEAM_FILE")
    if team:
        add(_read_json(team).get("mcpServers"), "fleet")
    return out


def kind(cfg):
    t = cfg.get("type") or ("http" if cfg.get("url") else "stdio")
    return "remote" if t in ("http", "sse", "streamable-http", "ws") else "stdio"


_VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")


def expand(value, env):
    """Claude Code's ${VAR} / ${VAR:-default} in a server's command, args and env."""
    if isinstance(value, str):
        return _VAR.sub(lambda m: env.get(m.group(1), m.group(2) if m.group(2) is not None else ""), value)
    if isinstance(value, list):
        return [expand(v, env) for v in value]
    if isinstance(value, dict):
        return {k: expand(v, env) for k, v in value.items()}
    return value


def tool_name(server, tool):
    return re.sub(r"[^A-Za-z0-9_-]", "_", server) + SEP + tool


class Backend:
    """One stdio MCP server, started for this session: its own process and reader."""

    def __init__(self, name, cfg):
        self.name, self.cfg = name, cfg
        self.proc = None
        self.lock = threading.Lock()
        self.pending = {}
        self.next_id = 0
        self.tools = []
        self.error = ""

    def start(self, timeout):
        env = dict(os.environ)
        for k in ("FLEET_WORKER_CRED", "FLEET_WORKER_ASSERT", "FLEET_MCP_EXEC"):
            env.pop(k, None)
        cfg = expand(self.cfg, env)
        env.update({k: str(v) for k, v in (cfg.get("env") or {}).items()})
        cmd = [cfg.get("command")] + [str(a) for a in (cfg.get("args") or [])]
        if not cmd[0]:
            raise RuntimeError("%s: no command configured" % self.name)
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, env=env, cwd=cfg.get("cwd") or None,
                                     start_new_session=True)
        threading.Thread(target=self._read, daemon=True).start()
        self.request("initialize", {"protocolVersion": PROTOCOL, "capabilities": {},
                                    "clientInfo": {"name": "fleet-gateway", "version": "1"}}, timeout)
        self.notify("notifications/initialized")
        res = self.request("tools/list", {}, timeout)
        self.tools = [t for t in (res.get("tools") or []) if isinstance(t, dict) and t.get("name")]

    def _read(self):
        for line in self.proc.stdout:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if not isinstance(msg, dict) or "id" not in msg:
                continue
            with self.lock:
                slot = self.pending.get(msg["id"])
            if slot is not None:
                slot["msg"] = msg
                slot["ev"].set()
        self.error = self.error or "%s exited" % self.name
        with self.lock:
            for slot in self.pending.values():
                slot["ev"].set()

    def _send(self, msg):
        data = (json.dumps(msg, separators=(",", ":")) + "\n").encode()
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def notify(self, method, params=None):
        try:
            self._send({"jsonrpc": "2.0", "method": method, **({"params": params} if params else {})})
        except (OSError, ValueError):
            pass

    def request(self, method, params, timeout):
        if self.proc is None or self.proc.poll() is not None:
            raise RuntimeError(self.error or "%s is not running" % self.name)
        with self.lock:
            self.next_id += 1
            rid = self.next_id
            slot = self.pending[rid] = {"ev": threading.Event(), "msg": None}
        try:
            self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
            if not slot["ev"].wait(timeout):
                raise RuntimeError("%s did not answer %s within %ds" % (self.name, method, timeout))
        except (OSError, ValueError) as exc:
            raise RuntimeError("%s: %s" % (self.name, exc))
        finally:
            with self.lock:
                self.pending.pop(rid, None)
        msg = slot["msg"]
        if msg is None:
            raise RuntimeError(self.error or "%s went away" % self.name)
        if "error" in msg:
            raise RuntimeError("%s: %s" % (self.name, (msg["error"] or {}).get("message", "error")))
        return msg.get("result") or {}

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.stdin.close()
                self.proc.terminate()
                self.proc.wait(timeout=3)
            except (OSError, subprocess.SubprocessError):
                try:
                    self.proc.kill()
                except OSError:
                    pass


def _secs(name, default):
    try:
        return float(os.environ.get(name) or default)
    except ValueError:
        return default


class Gateway:
    """The session's opened servers. `notify` prints a JSON-RPC notification to
    the client (fleet-mcp.py's stdout)."""

    def __init__(self, notify=None, codex=None):
        self.backends = {}
        self.notify = notify or (lambda method: None)
        self.codex = (os.environ.get("FLEET_AGENT") == "codex") if codex is None else codex

    # --- the three tools ---------------------------------------------------------
    SPECS = {
        "mcp_list": {
            "description": "List the MCP servers this machine / login has configured for this session, and which "
                           "are on. Tools of a server you enable appear in THIS session as <server>__<tool>.",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
        "mcp_enable": {
            "description": "Start one configured MCP server now (a name from mcp_list) and serve its tools in this "
                           "session — no reopen, no lost context. Only servers the login already configured.",
            "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"],
                            "additionalProperties": False}},
        "mcp_disable": {
            "description": "Stop an MCP server mcp_enable started; its tools go from this session.",
            "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"],
                            "additionalProperties": False}},
    }

    def tools(self):
        out = [{"name": n, **spec} for n, spec in self.SPECS.items()]
        for b in list(self.backends.values()):   # a reopen may be adding one (a thread)
            for t in b.tools:
                out.append(dict(t, name=tool_name(b.name, t["name"]),
                                description=("[%s] " % b.name) + (t.get("description") or "")))
        return out

    def owns(self, name):
        return name in self.SPECS or any(name.startswith(tool_name(b.name, "")) for b in list(self.backends.values()))

    def call(self, name, args):
        if name == "mcp_list":
            return self.text(self.list_text())
        if name == "mcp_enable":
            return self.text(self.enable((args or {}).get("name", "")))
        if name == "mcp_disable":
            return self.text(self.disable((args or {}).get("name", "")))
        for b in list(self.backends.values()):
            prefix = tool_name(b.name, "")
            if name.startswith(prefix):
                try:
                    return b.request("tools/call", {"name": name[len(prefix):], "arguments": args or {}},
                                     _secs("FLEET_MCP_GATEWAY_CALL_SECS", 120))
                except RuntimeError as exc:
                    return {"content": [{"type": "text", "text": str(exc)}], "isError": True}
        return {"content": [{"type": "text", "text": "no such tool: %s" % name}], "isError": True}

    @staticmethod
    def text(s, error=False):
        return {"content": [{"type": "text", "text": s}], **({"isError": True} if error else {})}

    def list_text(self):
        rows = []
        for name, (cfg, src) in sorted(configured().items()):
            k = kind(cfg)
            on = name in self.backends
            if k == "remote":
                state = "远程服务（由 Agent 自己连接，启动时已连）"
            elif on:
                state = "已打开 · %d 个工具" % len(self.backends[name].tools)
            else:
                state = "未打开 — mcp_enable %s" % name
            rows.append("%-18s %-8s %-12s %s" % (name, k, src, state))
        return "\n".join(rows) if rows else "这个登录没有配置别的 MCP 服务。"

    def enable(self, name):
        servers = configured()
        if name not in servers:
            return "没有名为「%s」的已配置服务（mcp_list 列出可用的）。" % name
        cfg, src = servers[name]
        if kind(cfg) == "remote":
            return "「%s」是远程服务，由 Agent 自己连接（登录在它那里）；工作会话启动时已连上。" % name
        if name in self.backends and self.backends[name].proc.poll() is None:
            return "「%s」已经打开（%d 个工具）。" % (name, len(self.backends[name].tools))
        b = Backend(name, cfg)
        try:
            b.start(_secs("FLEET_MCP_GATEWAY_START_SECS", 60))
        except (OSError, RuntimeError) as exc:
            b.stop()
            return "「%s」没打开：%s" % (name, exc)
        self.backends[name] = b
        record(name, "enable")
        remember(name, True)
        self.notify("notifications/tools/list_changed")
        names = ", ".join(tool_name(name, t["name"]) for t in b.tools[:12])
        more = "" if len(b.tools) <= 12 else " …"
        if self.codex:
            return ("「%s」已打开（%d 个工具：%s%s）。Codex 只在启动时读工具列表：同一对话重开后可用"
                    "（恢复页 ↵，或让 fleet 重开），之后每次启动自动打开。" % (name, len(b.tools), names, more))
        return "「%s」已打开，%d 个工具已在本会话可用：%s%s" % (name, len(b.tools), names, more)

    def disable(self, name):
        b = self.backends.pop(name, None)
        if b is None:
            return "「%s」没有打开。" % name
        b.stop()
        record(name, "disable")
        remember(name, False)
        self.notify("notifications/tools/list_changed")
        return "「%s」已关闭，它的工具已从本会话移除。" % name

    def reopen(self, names):
        """The names a reload-exec or a relaunch of the same conversation carried."""
        servers = configured()
        for name in names or []:
            if name in servers and kind(servers[name][0]) == "stdio" and name not in self.backends:
                b = Backend(name, servers[name][0])
                try:
                    b.start(_secs("FLEET_MCP_GATEWAY_START_SECS", 60))
                    self.backends[name] = b
                except (OSError, RuntimeError):
                    b.stop()
        if self.backends:
            self.notify("notifications/tools/list_changed")

    def names(self):
        return sorted(self.backends)

    def close(self):
        for b in self.backends.values():
            b.stop()
        self.backends = {}


def _session():
    pane = os.environ.get("TMUX_PANE", "")
    if not pane or not os.environ.get("TMUX"):
        return "", ""
    try:
        out = subprocess.run(["tmux", "display-message", "-p", "-t", pane, "#{@fleet_id}\t#{@repo}"],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return "", ""
    fid, _, repo = out.strip("\n").partition("\t")
    return fid, repo


def record(name, action):
    """One line of the book the doctor and `stats` count (never raises)."""
    fid, repo = _session()
    try:
        d = os.path.join(conf_dir(), "logs")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "mcp-enable.ndjson"), "a") as f:
            f.write(json.dumps({"ts": int(time.time()), "fid": fid, "repo": repo, "name": name,
                                "action": action}, ensure_ascii=False) + "\n")
    except OSError:
        pass


def _remembered_path(fid):
    return os.path.join(conf_dir(), "mcp-gateway", re.sub(r"[^A-Za-z0-9_.-]", "_", fid) + ".json")


def remember(name, on):
    """The window's opened servers, kept for the next launch of the same session."""
    fid, _ = _session()
    if not fid:
        return
    path = _remembered_path(fid)
    names = set(remembered(fid))
    (names.add if on else names.discard)(name)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(sorted(names), f)
        os.replace(tmp, path)
    except OSError:
        pass


def remembered(fid=None):
    fid = fid if fid is not None else _session()[0]
    if not fid:
        return []
    try:
        with open(_remembered_path(fid)) as f:
            v = json.load(f)
        return [n for n in v if isinstance(n, str)] if isinstance(v, list) else []
    except (OSError, ValueError):
        return []


def lean_config(out_path, cwd=None):
    """The strict config of a worker's lean start: KEEP + FLEET_MCP_EXTRA's names
    + every remote server. Written 0600 (a config may carry a header the login
    wrote); the path printed."""
    keep = set(KEEP_DEFAULT) | set((os.environ.get("FLEET_MCP_EXTRA") or "").replace(",", " ").split())
    servers = {}
    for name, (cfg, _src) in configured(cwd).items():
        if name in keep or kind(cfg) == "remote":
            servers[name] = cfg
    fd = os.open(out_path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"mcpServers": servers}, f, ensure_ascii=False)
    os.replace(out_path + ".tmp", out_path)
    print(out_path)
    return 0


def stats(days=30.0):
    since = time.time() - days * 86400
    count = {}
    try:
        with open(os.path.join(conf_dir(), "logs", "mcp-enable.ndjson")) as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("action") == "enable" and r.get("ts", 0) >= since:
                    k = (r.get("repo") or "-", r.get("name") or "?")
                    count[k] = count.get(k, 0) + 1
    except OSError:
        pass
    for (repo, name), n in sorted(count.items(), key=lambda kv: (-kv[1], kv[0])):
        print("%s\t%s\t%d" % (repo, name, n))
    return 0


def main(argv):
    if argv[:1] == ["lean-config"] and len(argv) == 2:
        return lean_config(argv[1])
    if argv[:1] == ["stats"]:
        days = 30.0
        if argv[1:2] == ["--days"] and len(argv) == 3:
            days = float(argv[2])
        return stats(days)
    sys.stderr.write(__doc__.split("\n\n")[0] + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
