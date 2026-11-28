#!/usr/bin/env python3
# selftest-entry
"""bin/fleet-cred-proxy.py Budget.quota_entries / flush + rl_reading: the pool
accounts' readings ride the usage report (POST /v1/node/usage `quota`) to the
hub, each reading once; a central-route reading, a login's own account and an
unread account are never sent; a Codex reading keeps its windows' minutes.
The hub's half: go test ./tokenledger/hub/api -run TestNodePoolQuotaFromUsageReport.
"""
import importlib.util
import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('proxy', BIN / 'fleet-cred-proxy.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class Hub(BaseHTTPRequestHandler):
    bodies = []

    def do_POST(self):
        Hub.bodies.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        b = b'{"principal": "gh:1", "over": false}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a):
        pass


class QuotaReport(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        st = self.tmp.name
        with open(os.path.join(st, "pool.json"), "w") as f:
            json.dump({"claude:gmail": "k1", "claude:24helpful": "k2", "codex:default": "k3"}, f)
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), Hub)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.shutdown)
        ne = os.path.join(st, "node.env")
        with open(ne, "w") as f:
            f.write("CCQUOTA_HUB_URL=http://127.0.0.1:%d\nCCQUOTA_TOKEN=tok\n" % self.srv.server_address[1])
        self.cfg = SimpleNamespace(state=st, store=True, node_env=ne)
        self.saved = dict(p.Proxy.reads)
        self.addCleanup(lambda: (p.Proxy.reads.clear(), p.Proxy.reads.update(self.saved)))
        p.Proxy.reads.clear()
        Hub.bodies = []

    def test_rides_the_usage_report_once(self):
        p.Proxy.reads[("claude", "24helpful")] = {"rl5h": "-", "rl7d": "68", "rl_reset5": "-", "rl_reset7": "1795932000",
                                                  "route": "direct", "ts": 1795863615}
        p.Proxy.reads[("claude", "own")] = {"rl5h": "1", "rl7d": "2", "rl_reset5": "-", "rl_reset7": "-", "route": "direct", "ts": 1}
        p.Proxy.reads[("codex", "default")] = {"rl5h": "0", "rl7d": "21", "rl_reset5": "1", "rl_reset7": "2", "win5": "300",
                                               "win7": "10080", "route": "central", "ts": 5}
        b = p.Budget(self.cfg)
        b.add("claude", 10, worker="w", acct="24helpful")
        self.assertIsNotNone(b.flush())
        q = Hub.bodies[-1].get("quota")
        # gmail unread, `own` not a pool account, codex:default's reading central
        self.assertEqual(q, [{"provider": "claude", "account": "24helpful", "at": 1795863615, "rl5h": "-", "rl7d": "68",
                              "rl_reset5": "-", "rl_reset7": "1795932000"}])
        b.ts = 0
        b.flush()
        self.assertNotIn("quota", Hub.bodies[-1], "a reading already sent went again")
        p.Proxy.reads[("claude", "24helpful")] = dict(p.Proxy.reads[("claude", "24helpful")], rl7d="70", ts=1795863700)
        b.ts = 0
        b.flush()
        self.assertEqual([e["rl7d"] for e in Hub.bodies[-1]["quota"]], ["70"])

    def test_not_separated_sends_none(self):
        p.Proxy.reads[("claude", "gmail")] = {"rl5h": "1", "rl7d": "2", "rl_reset5": "-", "rl_reset7": "-", "route": "direct", "ts": 9}
        self.assertEqual(p.Budget(SimpleNamespace(state=self.cfg.state, store=False)).quota_entries(), [])

    def test_codex_minutes(self):
        h = [("x-codex-primary-used-percent", "12"), ("x-codex-primary-window-minutes", "10080"), ("x-codex-primary-reset-at", "9"),
             ("x-codex-secondary-used-percent", "3"), ("x-codex-secondary-window-minutes", "300"), ("x-codex-secondary-reset-at", "8")]
        rd = p.rl_reading("codex", h, now=1)
        self.assertEqual((rd["rl5h"], rd["win5"], rd["rl7d"], rd["win7"]), ("3", "300", "12", "10080"))
        self.assertNotIn("win5", p.rl_reading("claude", [("anthropic-ratelimit-unified-5h-utilization", "0.1"),
                                                          ("anthropic-ratelimit-unified-7d-utilization", "0.2")], now=1))


if __name__ == "__main__":
    unittest.main()
