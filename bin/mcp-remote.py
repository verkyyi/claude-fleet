#!/usr/bin/env python3
"""mcp-remote.py — the login's remote (http) MCP servers for a Codex session (task S9F7).

Claude Code keeps the login's remote connectors — 活页 `space`, … — in
~/.claude.json (user scope) and their sign-in in its own credential store
(~/.claude/.credentials.json `mcpOAuth`, else the macOS keychain item
«Claude Code-credentials»). Codex reads neither, so a Codex fleet session had
no `space` at all: a scheduled daily brief answered 「当前会话未提供活页 MCP」.

    mcp-remote.py codex-mounts [--codex-home DIR]
        one `-c` value per remote server of the login that Codex's own
        config.toml does not name: `mcp_servers.<name>={command=…, args=[…, "serve",
        "<name>"]}` — the name only, never a URL's credential or a header
    mcp-remote.py serve <name>
        a stdio MCP server that relays every JSON-RPC message to that server's URL
        (MCP streamable HTTP: JSON or an SSE answer, Mcp-Session-Id kept). The
        server's headers and the bearer of Claude's own sign-in for that exact
        URL are read from the login's files at EACH request — never an argument,
        an environment variable, a config line or a log line — so a sign-in Claude
        refreshed is the one used next.

Nothing is written. No sign-in for a server that needs one ⇒ its 401 comes back
as a tool error saying to sign in once from a Claude session (/mcp).
FLEET_CODEX_REMOTE_MCP=0 (read by the launcher) adds none.
"""
import json
import os
import re
import subprocess
import sys
import threading
import urllib.error
import urllib.request

NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
CALL_SECS = int(os.environ.get("FLEET_MCP_REMOTE_SECS", "300") or 300)


def home():
    return os.path.expanduser("~")


def read_json(path):
    try:
        with open(path) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def remote_servers():
    """{name: config} — the login's user-scope remote (http) servers."""
    out = {}
    for name, c in (read_json(os.path.join(home(), ".claude.json")).get("mcpServers") or {}).items():
        url = str((c or {}).get("url", "")) if isinstance(c, dict) else ""
        if NAME_RE.match(str(name)) and isinstance(c, dict) and c.get("type") == "http" and (
                url.startswith("https://") or (os.environ.get("FLEET_MCP_REMOTE_TEST") == "1"
                                               and url.startswith("http://127.0.0.1:"))):
            out[name] = c
    return out


def codex_names(codex_home):
    """Every mcp_servers.<name> the login's Codex config already has (text: no tomllib on 3.9)."""
    names = set()
    try:
        text = open(os.path.join(codex_home, "config.toml")).read()
    except OSError:
        return names
    for m in re.finditer(r'^\s*\[mcp_servers\.(?:"([^"]+)"|([A-Za-z0-9_-]+))', text, re.M):
        names.add(m.group(1) or m.group(2))
    if re.search(r"^\s*mcp_servers\s*=", text, re.M):
        names.add("*")      # an inline table: cannot be extended by -c, hand nothing
    return names


def codex_mounts(codex_home):
    have = codex_names(codex_home)
    if "*" in have:
        return []
    me = os.path.realpath(__file__)
    q = json.dumps
    return ["mcp_servers.%s={command=%s,args=[%s],env_vars=[\"HOME\"],startup_timeout_sec=30}"
            % (n, q(sys.executable or "python3"), ",".join(q(a) for a in ("-I", me, "serve", n)))
            for n in sorted(remote_servers()) if n not in have]


def claude_signins():
    """Claude Code's mcpOAuth table: the credentials file, else the macOS keychain."""
    d = read_json(os.path.join(home(), ".claude", ".credentials.json")).get("mcpOAuth")
    if isinstance(d, dict) and d:
        return d
    if sys.platform == "darwin":
        try:
            p = subprocess.run(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
            d = json.loads(p.stdout or "{}").get("mcpOAuth") if p.returncode == 0 else None
            if isinstance(d, dict):
                return d
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    return {}


def bearer(name, url):
    """Claude's access token for exactly this server and URL, or ''."""
    for k, v in claude_signins().items():
        if isinstance(v, dict) and v.get("serverName") == name and v.get("serverUrl") == url \
                and isinstance(v.get("accessToken"), str):
            return v["accessToken"]
    return ""


class Bridge(object):
    def __init__(self, name):
        self.name = name
        self.sid = None
        self.proto = None
        self.out = threading.Lock()

    def say(self, msg):
        with self.out:
            sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
            sys.stdout.flush()

    def error(self, mid, text):
        if mid is not None:
            self.say({"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": text}})

    def post(self, msg):
        c = remote_servers().get(self.name)
        mid = msg.get("id") if isinstance(msg, dict) and "method" in msg else None
        if not c:
            return self.error(mid, "%s: no longer configured for this login (~/.claude.json)" % self.name)
        h = {str(k): str(v) for k, v in (c.get("headers") or {}).items()}
        tok = bearer(self.name, c["url"])
        if tok and not any(k.lower() == "authorization" for k in h):
            h["Authorization"] = "Bearer " + tok
        h.update({"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
        if self.sid:
            h["Mcp-Session-Id"] = self.sid
        if self.proto:
            h["MCP-Protocol-Version"] = self.proto
        req = urllib.request.Request(c["url"], data=json.dumps(msg).encode(), method="POST", headers=h)
        try:
            r = urllib.request.urlopen(req, timeout=CALL_SECS)
        except urllib.error.HTTPError as e:
            if e.code == 401:
                why = ("not signed in here — sign in to %s once from a Claude session (/mcp); "
                       "Codex uses that sign-in" % self.name)
            elif e.code == 404 and self.sid:
                self.sid = None
                why = "the server ended this MCP session — reopen the conversation"
            else:
                why = "HTTP %s" % e.code
            return self.error(mid, "%s: %s" % (self.name, why))
        except (OSError, ValueError) as e:
            return self.error(mid, "%s: unreachable (%s)" % (self.name, e.__class__.__name__))
        with r:
            sid = r.headers.get("Mcp-Session-Id")
            if sid:
                self.sid = sid
            if r.status == 202:
                return
            ctype = (r.headers.get("Content-Type") or "").lower()
            if "text/event-stream" in ctype:
                data = []
                for raw in r:
                    line = raw.decode("utf-8", "replace").rstrip("\r\n")
                    if line.startswith("data:"):
                        data.append(line[5:].lstrip())
                    elif not line and data:
                        self.relay("\n".join(data))
                        data = []
                if data:
                    self.relay("\n".join(data))
            else:
                body = r.read().decode("utf-8", "replace").strip()
                if body:
                    self.relay(body)

    def relay(self, text):
        try:
            d = json.loads(text)
        except ValueError:
            return
        for m in (d if isinstance(d, list) else [d]):
            if isinstance(m, dict):
                res = m.get("result")
                if isinstance(res, dict) and isinstance(res.get("protocolVersion"), str):
                    self.proto = res["protocolVersion"]
                self.say(m)

    def run(self):
        live = []
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if not isinstance(msg, dict):
                continue
            if msg.get("method") == "initialize" or "id" not in msg or "method" not in msg:
                # the handshake and every notification in order; requests in parallel
                self.post(msg)
            else:
                t = threading.Thread(target=self.post, args=(msg,), daemon=True)
                t.start()
                live.append(t)
                live[:] = [x for x in live if x.is_alive()]
        for t in live:      # stdin closed: answer what is in flight before going
            t.join(CALL_SECS)


def main(argv):
    if argv[:1] == ["codex-mounts"]:
        ch = argv[2] if argv[1:2] == ["--codex-home"] and len(argv) > 2 else \
            os.environ.get("CODEX_HOME") or os.path.join(home(), ".codex")
        for v in codex_mounts(ch):
            print(v)
        return 0
    if argv[:1] == ["serve"] and len(argv) == 2 and NAME_RE.match(argv[1]):
        Bridge(argv[1]).run()
        return 0
    sys.stderr.write("usage: mcp-remote.py codex-mounts [--codex-home DIR] | serve <name>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
