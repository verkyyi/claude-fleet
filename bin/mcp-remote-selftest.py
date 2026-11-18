#!/usr/bin/env python3
# selftest-entry
"""bin/mcp-remote.py — a Codex session reaches the login's remote MCP servers (task S9F7).

A: codex-mounts names each remote server Codex's config.toml lacks — the name only,
   no URL credential, no header, no token; an inline mcp_servers table ⇒ none.
B: serve relays JSON and SSE answers, keeps Mcp-Session-Id, and puts Claude's own
   sign-in for exactly that URL on the request — read from the login's file.
C: a 401 comes back as a tool error that says how to sign in.
"""
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "mcp-remote.py")
TOKEN = "tok-" + "s9f7" * 4


class Fake(http.server.BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        Fake.seen.append((dict(self.headers), body))
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            self.send_response(401); self.end_headers(); return
        if "id" not in body:
            self.send_response(202); self.end_headers(); return
        if body["method"] == "initialize":
            out = {"jsonrpc": "2.0", "id": body["id"], "result": {"protocolVersion": "2025-06-18",
                                                                   "serverInfo": {"name": "fake"}}}
            raw = json.dumps(out).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Mcp-Session-Id", "sess-1"); self.send_header("Content-Length", str(len(raw)))
            self.end_headers(); self.wfile.write(raw); return
        out = {"jsonrpc": "2.0", "id": body["id"], "result": {"tools": [{"name": "get_page"}]}}
        raw = ("event: message\ndata: %s\n\n" % json.dumps(out)).encode()
        self.send_response(200); self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)


class Bridge(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = self.tmp.name
        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.shutdown)
        self.url = "http://127.0.0.1:%d/mcp" % self.srv.server_address[1]
        cfg = {"mcpServers": {"space": {"type": "http", "url": self.url},
                              "stdio-one": {"type": "stdio", "command": "x"},
                              "plain": {"type": "http", "url": "http://example.com/mcp"}}}
        json.dump(cfg, open(os.path.join(self.home, ".claude.json"), "w"))
        os.makedirs(os.path.join(self.home, ".claude"))
        os.makedirs(os.path.join(self.home, ".codex"))
        self.env = dict(os.environ, HOME=self.home, FLEET_MCP_REMOTE_TEST="1")
        self.env.pop("CODEX_HOME", None)
        Fake.seen = []

    def signin(self, url):
        json.dump({"mcpOAuth": {"space|x": {"serverName": "space", "serverUrl": url, "accessToken": TOKEN}}},
                  open(os.path.join(self.home, ".claude", ".credentials.json"), "w"))

    def mounts(self):
        p = subprocess.run([sys.executable, BRIDGE, "codex-mounts"], env=self.env, capture_output=True, text=True)
        return p.stdout.splitlines()

    def serve(self, lines):
        p = subprocess.run([sys.executable, BRIDGE, "serve", "space"], env=self.env, capture_output=True, text=True,
                           input="".join(json.dumps(m) + "\n" for m in lines), timeout=30)
        return [json.loads(l) for l in p.stdout.splitlines()], p.stderr

    def test_a_mounts(self):
        self.signin(self.url)
        m = self.mounts()
        self.assertEqual(len(m), 1, m)
        self.assertTrue(m[0].startswith('mcp_servers.space={command='), m[0])
        self.assertIn('"serve","space"', m[0])
        for secret in (TOKEN, self.url):
            self.assertNotIn(secret, m[0])
        open(os.path.join(self.home, ".codex", "config.toml"), "w").write('[mcp_servers.space]\nurl = "x"\n')
        self.assertEqual(self.mounts(), [])
        open(os.path.join(self.home, ".codex", "config.toml"), "w").write('mcp_servers = { a = { command = "b" } }\n')
        self.assertEqual(self.mounts(), [])

    def test_b_relay_with_signin(self):
        self.signin(self.url)
        init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
        out, err = self.serve([init, {"jsonrpc": "2.0", "method": "notifications/initialized"},
                               {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}])
        by = {m["id"]: m for m in out}
        self.assertEqual(by[1]["result"]["serverInfo"]["name"], "fake")
        self.assertEqual(by[2]["result"]["tools"][0]["name"], "get_page")
        hdrs = [h for h, b in Fake.seen if b.get("method") == "tools/list"][0]
        self.assertEqual(hdrs.get("Mcp-Session-Id"), "sess-1")
        self.assertEqual(hdrs.get("Mcp-Protocol-Version") or hdrs.get("MCP-Protocol-Version"), "2025-06-18")
        self.assertNotIn(TOKEN, err)

    def test_c_unsigned_is_said(self):
        self.signin(self.url + "/other")      # a sign-in for another URL is never borrowed
        out, err = self.serve([{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}])
        self.assertIn("sign in to space once from a Claude session", out[0]["error"]["message"])
        self.assertNotIn("Authorization", Fake.seen[0][0])


if __name__ == "__main__":
    unittest.main()
