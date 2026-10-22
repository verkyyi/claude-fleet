#!/usr/bin/env python3
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""fleet-cred-proxy-space-selftest.py — a trial's `space` through the proxy (task XA4R).

bin/fleet-cred-proxy.py's /space/ route and bin/mcp-space.py, the stdio bridge a
trial session runs, against ONE fake far end on loopback that plays the hub
(/v1/node/livepage-token, the node token) and 活页's MCP (/mcp, the person's key):

  S  status: a session credential asks /space/status; the proxy asks the hub with
     the node token (GET) and passes on its word — never a key; no or a forged
     session credential is 401 and the hub is not asked
  H  the bridge's handshake (initialize, tools/list) asks nobody: no account is
     opened by starting a session; a public set_visibility is refused before
     anything is sent
  K  the first tool call: the hub is asked (POST) once, 活页 sees the person's
     key in place of the session's credential — never the session credential —
     and the bridge adds the 「刚开好活页账号」 line exactly once; a second call
     reuses the kept key (the hub not asked again)
  R  活页 refuses the kept key (401): the proxy asks the hub again, once, and the
     call goes through
  F  the hub cannot open it (503 failed): a tool error saying the account is not
     ready (show_page account); the trial over (403 ended) says so
  P  a person's pod goes out through the cluster's egress (CONNECT), else direct
  L  the session never holds the key: not in the bridge's output, the proxy's
     log or anything the session can read; only /space/mcp is forwarded
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIN = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("credproxy", os.path.join(BIN, "fleet-cred-proxy.py"))
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

FAILS = []
KEY = "sk-space-trial-secret-1"


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        FAILS.append(what)


class Far(BaseHTTPRequestHandler):
    """The hub and 活页 in one."""
    protocol_version = "HTTP/1.1"
    log_message = lambda *a: None

    def reply(self, code, obj, hdrs=()):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        for k, v in hdrs:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        self.any()

    def do_POST(self):
        self.any()

    def any(self):
        st = self.server
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        auth = self.headers.get("Authorization", "")
        if self.path == "/v1/node/livepage-token":
            st.hub.append(self.command)
            if auth != "Bearer nodetok":
                return self.reply(401, {"error": "node token"})
            if st.hub_mode == "failed":
                return self.reply(503, {"code": "failed", "message": "活页 could not open the account yet", "retry_after": 30})
            if st.hub_mode == "ended":
                return self.reply(403, {"code": "ended", "message": "the trial is over"})
            if self.command == "GET":
                return self.reply(200, {"eligible": True, "ready": bool(st.posts)})
            st.posts += 1
            return self.reply(200, {"eligible": True, "ready": True, "token": st.key, "until": "2099-01-01T00:00:00Z",
                                    "new": st.posts == 1})
        if self.path == "/mcp":
            st.mcp.append((auth, body))
            if auth != "Bearer " + st.key:
                return self.reply(401, {"jsonrpc": "2.0", "error": {"code": -32001, "message": "Authorization required"}, "id": None})
            m = json.loads(body or b"{}")
            if m.get("method") == "initialize":
                return self.reply(200, {"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": "2025-06-18",
                                  "capabilities": {"tools": {}}, "serverInfo": {"name": "space"}}}, [("Mcp-Session-Id", "s1")])
            if "id" not in m:
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            # an event-stream answer, as 活页's streamable HTTP may send
            out = ("event: message\ndata: " + json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": {
                "content": [{"type": "text", "text": "published %s" % m["params"]["name"]}]}}) + "\n\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        self.reply(404, {})


d = tempfile.mkdtemp(prefix="sp")
far = ThreadingHTTPServer(("127.0.0.1", 0), Far)
far.hub, far.mcp, far.posts, far.hub_mode, far.key = [], [], 0, "ok", KEY
threading.Thread(target=far.serve_forever, daemon=True).start()
FAR = "http://127.0.0.1:%d" % far.server_address[1]

ne = os.path.join(d, "node.env")
open(ne, "w").write("CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=nodetok\n" % FAR)
LOG = os.path.join(d, "proxy.log")


class Cfg:
    timeout = 20
    name = "trial1"
    state = d
    node_env = ne
    space_url = FAR
    log = LOG


class Tenant:
    def __init__(self):
        self.cfg = Cfg()
        self.keys = cp.Keys(d)
        self.space = cp.SpaceKey(self.cfg)

    def log(self, **kv):
        cp.log_line(self.cfg, kv)

    def note_quota(self, *a):
        pass


T = Tenant()
cp.Proxy.fixed = T
proxy = ThreadingHTTPServer(("127.0.0.1", 0), cp.Proxy)
threading.Thread(target=proxy.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d" % proxy.server_address[1]
CRED = T.keys.mint("default", "web-1", 3600)


def get(path, tok):
    import urllib.request
    import urllib.error
    req = urllib.request.Request(BASE + path, headers={"Authorization": "Bearer " + tok} if tok else {})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


# S — status
far.hub.clear()
code, a = get("/space/status", CRED)
check(code == 200 and a.get("eligible") is True and "token" not in a and far.hub == ["GET"],
      "S status: the hub asked once with the node token (GET), its word passed on, no key (%s %s)" % (code, a))
code, _ = get("/space/status", "")
code2, _ = get("/space/status", "fcp1.forged.sig")
check(code == 401 and code2 == 401 and far.hub == ["GET"], "S no / a forged session credential: 401, the hub not asked")
code, _ = get("/space/other", CRED)
check(code == 404, "L only /space/mcp is forwarded (/space/other: %s)" % code)


class Bridge:
    def __init__(self):
        env = dict(os.environ, CLAUDE_CODE_OAUTH_TOKEN=CRED)
        self.p = subprocess.Popen([sys.executable, "-I", os.path.join(BIN, "mcp-space.py"), "--base", BASE,
                                   "--cred-env", "CLAUDE_CODE_OAUTH_TOKEN"], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
        self.n, self.seen = 0, ""

    def ask(self, method, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
        self.p.stdin.flush()
        line = self.p.stdout.readline()
        self.seen += line
        return json.loads(line)

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=10)
        self.seen += self.p.stdout.read() + self.p.stderr.read()


# H — the handshake asks nobody
far.hub.clear(); far.mcp.clear()
b = Bridge()
init = b.ask("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t"}})
tools = b.ask("tools/list")
names = {t["name"] for t in tools["result"]["tools"]}
check(init["result"]["serverInfo"]["name"] == "space" and {"publish_file", "push_to_wechat", "set_visibility"} <= names,
      "H initialize + tools/list answered by the bridge (%d tools)" % len(names))
pub = b.ask("tools/call", {"name": "set_visibility", "arguments": {"proposal_id": "p1", "visibility": "public"}})
check(pub["result"].get("isError") and "公开" in pub["result"]["content"][0]["text"], "H a public page is refused by the bridge")
check(not far.hub and not far.mcp, "H nothing was asked of the hub or 活页 (no account opened at start)")

# K — the first call opens the account, once
r1 = b.ask("tools/call", {"name": "publish_file", "arguments": {"title": "清单", "filename": "a.html", "content": "<p>x</p>"}})
txt = "".join(c.get("text", "") for c in r1["result"]["content"])
check(not r1["result"].get("isError") and "published publish_file" in txt and "刚用他的微信为他开好了活页账号" in txt,
      "K the first call went through and says the account was just opened")
check(far.hub.count("POST") == 1, "K the hub was asked for the key once (%s)" % far.hub)
check(far.mcp and all(au == "Bearer " + KEY for au, _ in far.mcp) and not any(CRED in au for au, _ in far.mcp),
      "K 活页 saw the person's key, never the session credential")
r2 = b.ask("tools/call", {"name": "push_to_wechat", "arguments": {"proposal_id": "p1", "to": "self"}})
txt2 = "".join(c.get("text", "") for c in r2["result"]["content"])
check("published push_to_wechat" in txt2 and "开好了活页账号" not in txt2 and far.hub.count("POST") == 1,
      "K a second call: the kept key, no 「开好」 line, the hub not asked again")

# R — 活页 refuses the kept key: once more from the hub
far.key = "sk-space-trial-secret-2"
r3 = b.ask("tools/call", {"name": "get_version", "arguments": {"version_id": "v1"}})
check("published get_version" in "".join(c.get("text", "") for c in r3["result"]["content"]) and far.hub.count("POST") == 2,
      "R a refused key is asked again once and the call goes through")
b.close()

# F — the hub cannot open it / the trial is over
T.space = cp.SpaceKey(T.cfg)
far.hub_mode = "failed"
b = Bridge()
b.ask("initialize", {})
f1 = b.ask("tools/call", {"name": "publish_file", "arguments": {"title": "x", "filename": "a.html", "content": "x"}})
check(f1["result"].get("isError") and "status account" in f1["result"]["content"][0]["text"],
      "F the account not open yet: a tool error that says show_page account")
b.close()
T.space = cp.SpaceKey(T.cfg)
far.hub_mode = "ended"
b = Bridge()
b.ask("initialize", {})
f2 = b.ask("tools/call", {"name": "publish_file", "arguments": {"title": "x", "filename": "a.html", "content": "x"}})
check(f2["result"].get("isError") and "试用已结束" in f2["result"]["content"][0]["text"], "F the trial over: said so")
b.close()

# L — the key is nowhere the session can read
logtxt = open(LOG).read() if os.path.exists(LOG) else ""
check(KEY not in b.seen and "sk-space-trial" not in logtxt and CRED not in logtxt,
      "L the key in neither the bridge's output nor the proxy's log")
check(any('"space"' in l or "space" in l for l in logtxt.splitlines()), "L the proxy logged its space requests")

# P — a person's pod reaches 活页 through the cluster's egress (CONNECT), else direct
saved = {k: os.environ.pop(k, None) for k in ("FLEET_CRED_SPACE_PROXY", "HTTPS_PROXY", "https_proxy", "FLEET_DEVNET_ENV")}
dv = os.path.join(d, "fleet-devnet.env")
open(dv, "w").write("NO_PROXY=x\nHTTPS_PROXY=http://fleet-egress.fleet-workers.svc.cluster.local:3128\n")
os.environ["FLEET_DEVNET_ENV"] = os.path.join(d, "none")
direct = cp.space_tunnel()
os.environ["FLEET_DEVNET_ENV"] = dv
pod = cp.space_tunnel()
os.environ["FLEET_CRED_SPACE_PROXY"] = "http://egress.example:8080"
named = cp.space_tunnel()
check(direct is None and pod == ("fleet-egress.fleet-workers.svc.cluster.local", 3128) and named == ("egress.example", 8080),
      "P the egress: none ⇒ direct, the pod's devnet file, FLEET_CRED_SPACE_PROXY first (%r %r %r)" % (direct, pod, named))
for k, v in saved.items():
    os.environ.pop(k, None)
    if v is not None:
        os.environ[k] = v

far.shutdown(); proxy.shutdown()
shutil.rmtree(d, ignore_errors=True)
print("PASS" if not FAILS else "FAIL %d" % len(FAILS))
sys.exit(1 if FAILS else 0)
