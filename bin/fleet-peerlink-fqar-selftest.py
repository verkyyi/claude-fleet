#!/usr/bin/env python3
# selftest-entry
"""fleet-peerlink-fqar-selftest.py — the keeper's link stability (task FQAR):

  A. classify  — an ssh .err / a hub refusal → its short class (426 through the
                 relay's ProxyCommand outranks ssh's «Connection closed»)
  B. ledger    — logs/peerlink.ndjson: one line per transition, the exact schema
                 the hub ingests, gap_s null then the seconds since the last up/down,
                 a probe line with rtt_ms; past FLEET_PEERLINK_LEDGER_MAX it moves to .1
  C. retry     — a refusal (4xx · auth) waits REFUSED_BACKOFF doubling to its max, a
                 network failure the 1 → BACKOFF_MAX doubling; the hub refusing the
                 certificate waits minutes, the hub down is asked again soon; a wake
                 does not hurry a refusal and hurries anything else only to WAKE_MIN
  D. relay     — RELAY_AFTER failures in a row and a hub that can relay: the hub's
                 relay is one more route, dialled through `peer-proxy`; never with
                 FLEET_PEERLINK_RELAY_FALLBACK=0 or no hub
  E. hostkey   — «Host key verification failed»: the certificate asked afresh once
                 (host keys re-pinned), at once; again ⇒ a refusal's backoff
  F. alert     — down ALERT_SECS (a refusal: ALERT_REFUSED_SECS) ⇒ one notice naming
                 the cause; up again ⇒ amended to 已恢复
  G. e2e       — an up link is probed at least every E2E_SECS (also on the quiet beat)
"""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

HERE = Path(__file__).absolute().parent


def load(tmp):
    os.environ["FLEET_CONF_DIR"] = tmp
    os.environ["FLEET_PEERLINK_LEDGER"] = os.path.join(tmp, "logs", "peerlink.ndjson")
    spec = importlib.util.spec_from_file_location("peerlink_fqar", HERE / "fleet-peerlink.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class Base(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.tmp = self.td.name
        self.env = patch.dict(os.environ, {"FLEET_REMOTE_SSH": "", "FLEET_PEERLINK_NOTICE_CMD": "true"})
        self.env.start()
        self.pl = load(self.tmp)
        os.makedirs(self.pl.D, exist_ok=True)
        self.notes = []
        self.np = patch.object(self.pl, "notice", side_effect=lambda a: self.notes.append(a))
        self.np.start()
        self.k = self.pl.Keeper()

    def tearDown(self):
        self.np.stop()
        self.env.stop()
        self.td.cleanup()

    def rows(self):
        p = os.path.join(self.tmp, "logs", "peerlink.ndjson")
        try:
            return [json.loads(x) for x in open(p).read().splitlines()]
        except OSError:
            return []

    def link(self, routes=None):
        l = self.pl.Link("mac-a", "bob")
        l.routes = routes or []
        return l


class A_Classify(Base):
    def test_classes(self):
        c = self.pl.classify
        relay426 = ("fleet connect: hub refused the connection: 426 Upgrade Required\n"
                    "kex_exchange_identification: Connection closed by remote host")
        self.assertEqual(c(relay426), "http4xx")
        self.assertEqual(c("Host key verification failed."), "hostkey")
        self.assertEqual(c("@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @"), "hostkey")
        self.assertEqual(c("bob@mac-a: Permission denied (publickey)."), "auth")
        self.assertEqual(c("fleet-peer-cert: 入口不认这台机器的节点令牌（401）"), "auth")
        self.assertEqual(c("入口拒绝了到 mac-a 的访问（HTTP 403）：nope"), "http4xx")
        self.assertEqual(c("入口拒绝了到 mac-a 的访问（HTTP 503）"), "http5xx")
        self.assertEqual(c("ssh: Could not resolve hostname fleet-x: nodename nor servname provided"), "dns")
        self.assertEqual(c("ssh: connect to host 203.0.113.4 port 22: Connection refused"), "network")
        self.assertEqual(c("ssh: connect to host 203.0.113.4 port 22: Operation timed out"), "timeout")
        self.assertEqual(c("入口不在或拒绝：the hub could not be reached（curl exit 7；不退回长期互信）"), "network")
        self.assertEqual(c("ssh -O check 不通（连续 3 次）"), "check")
        self.assertEqual(c(""), "unknown")
        self.assertEqual(c("something odd"), "unknown")

    def test_last_err_names_the_cause_line(self):
        l = self.link()
        os.makedirs(self.pl.D, exist_ok=True)
        with open(l.sock[:-5] + ".err", "w") as f:
            f.write("fleet connect: hub refused the connection: 426 Upgrade Required\n"
                    "Connection closed by UNKNOWN port 65535\n")
        self.assertIn("426", self.k.last_err(l))


class B_Ledger(Base):
    KEYS = ["ts", "machine", "login", "route", "event", "cause", "detail", "gap_s", "rtt_ms"]

    def test_schema_and_gap(self):
        l = self.link()
        self.k.fail(l, "ssh: connect to host mac-a port 22: Connection refused", 1000.0)
        self.k.fail(l, "ssh: connect to host mac-a port 22: Connection refused", 1002.0)
        l.phase, l.verify, l.kind = "verifying", None, "tailnet"

        class P:
            returncode = 0
            stdout = type("o", (), {"read": staticmethod(lambda: b"bob\n")})()

            def poll(self):
                return 0
        l.verify = (P(), 1003.0)
        self.k.step(l, 1010.0)
        r = self.rows()
        self.assertEqual([x["event"] for x in r], ["down", "retry", "up"])
        for x in r:
            self.assertEqual(list(x), self.KEYS)
            self.assertIn(x["route"], ("tailnet", "lan", "entry", "peer-relay", "hub-relay"))
            self.assertIn(x["cause"], self.pl.CAUSES)
        self.assertIsNone(r[0]["gap_s"])
        self.assertEqual(r[0]["cause"], "network")
        self.assertEqual(r[2]["cause"], "ok")
        self.assertEqual(r[2]["gap_s"], 10.0)
        self.assertEqual(l.streak, 0)

    def test_probe_line(self):
        l = self.link()
        l.kind, l.check_ms, l.ledger_probe = "lan", 7, 0.0
        self.k.probe_good(l, 42)
        self.k.probe_good(l, 43)    # within E2E_SECS: one line only
        r = self.rows()
        self.assertEqual(len(r), 1)
        self.assertEqual((r[0]["event"], r[0]["rtt_ms"], r[0]["route"]), ("probe", 42, "lan"))
        self.assertIn("check 7ms", r[0]["detail"])

    def test_rotation(self):
        with patch.object(self.pl, "LEDGER_MAX", 200):
            for i in range(10):
                self.pl.ledger_write({"ts": i, "detail": "x" * 50})
        p = os.path.join(self.tmp, "logs", "peerlink.ndjson")
        self.assertTrue(os.path.exists(p + ".1"))
        self.assertLess(os.path.getsize(p), 400)

    def test_detail_redacted_single_line(self):
        l = self.link()
        self.k.fail(l, "Connection refused\nAuthorization: Bearer sk-ant-api03-" + "a" * 40, 5.0)
        d = self.rows()[0]["detail"]
        self.assertNotIn("\n", d)
        self.assertNotIn("a" * 40, d)


class C_Retry(Base):
    def test_refusal_waits_minutes(self):
        l = self.link()
        why = "fleet connect: hub refused the connection: 426 Upgrade Required"
        self.k.fail(l, why, 100.0)
        self.assertEqual(l.next_try, 100.0 + self.pl.REFUSED_BACKOFF)
        self.k.fail(l, why, 200.0)
        self.assertEqual(l.next_try, 200.0 + 2 * self.pl.REFUSED_BACKOFF)
        for t in range(20):
            self.k.fail(l, why, 1000.0 + t)
        self.assertEqual(l.next_try - 1019.0, self.pl.REFUSED_BACKOFF_MAX)

    def test_network_backs_off_capped(self):
        l = self.link()
        why = "ssh: connect to host mac-a port 22: Connection refused"
        waits = []
        for t in range(10):
            self.k.fail(l, why, float(t * 100))
            waits.append(l.next_try - t * 100)
        self.assertEqual(waits[:5], [1.0, 2.0, 4.0, 8.0, 16.0])
        self.assertEqual(max(waits), self.pl.BACKOFF_MAX)

    def test_next_route_at_once(self):
        l = self.link([{"name": "a", "host": "203.0.113.4", "port": 22022},
                       {"name": "b", "host": "203.0.113.5", "port": 22022}])
        self.k.fail(l, "fleet connect: hub refused the connection: 426 Upgrade Required", 50.0)
        self.assertEqual((l.route_i, l.next_try), (1, 50.0))

    def test_hub_cert(self):
        l = self.link()
        with patch.object(self.pl, "peer_opts", return_value=(None, "入口不在或拒绝：入口不认这台机器的节点令牌（401）")), \
                patch.object(self.pl, "master_check", return_value=(False, 0)):
            self.k.start(l, 10.0)
        self.assertEqual(l.cause, "auth")
        self.assertEqual(l.next_try, 10.0 + self.pl.REFUSED_BACKOFF)
        l2 = self.link()
        with patch.object(self.pl, "peer_opts", return_value=(None, "入口不在：curl exit 7")), \
                patch.object(self.pl, "master_check", return_value=(False, 0)):
            self.k.start(l2, 10.0)
            self.assertEqual(l2.next_try, 10.0 + self.pl.TICK)
            self.k.start(l2, 20.0)
            self.assertEqual(l2.next_try, 20.0 + 2 * self.pl.TICK)

    def test_wake(self):
        refused, net = self.link(), self.pl.Link("mac-b", "bob")
        refused.last_try = net.last_try = 100.0
        self.k.fail(refused, "fleet connect: hub refused the connection: 426 Upgrade Required", 100.0)
        for _ in range(6):
            self.k.fail(net, "Connection refused", 100.0)
        self.k.links = {("mac-a", "bob"): refused, ("mac-b", "bob"): net}
        self.k.on_wake(101.0)
        self.assertEqual(refused.next_try, 100.0 + self.pl.REFUSED_BACKOFF)
        self.assertEqual(net.next_try, 100.0 + self.pl.WAKE_MIN)
        net.next_try = 500.0
        self.k.on_wake(200.0)
        self.assertEqual(net.next_try, 200.0)


class D_Relay(Base):
    def test_fallback_after_n(self):
        l = self.link([{"name": "pub", "host": "203.0.113.4", "port": 22}])
        l.hub_relay = True
        self.assertEqual([c[3] for c in self.k.cands(l)], ["entry"])
        for t in range(self.pl.RELAY_AFTER):
            self.k.fail(l, "Connection refused", float(t))
        self.assertEqual([c[3] for c in self.k.cands(l)], ["entry", "hub-relay"])
        l.route_i = 1
        with patch.object(self.pl, "master_check", return_value=(False, 0)), \
                patch.object(self.pl, "peer_opts", return_value=(["-o", "HostKeyAlias=fleet-mac-a"], "")), \
                patch.object(self.pl.subprocess, "Popen") as popen:
            self.k.start(l, 10.0)
        argv = popen.call_args.args[0]
        self.assertEqual(l.kind, "hub-relay")
        self.assertIn(" peer-proxy mac-a", next(a for a in argv if a.startswith("ProxyCommand=")))
        self.assertEqual(argv[-1], "mac-a")

    def test_no_fallback(self):
        l = self.link()
        for t in range(5):
            self.k.fail(l, "Connection refused", float(t))
        self.assertEqual([c[3] for c in self.k.cands(l)], ["tailnet"])     # no hub here
        l.hub_relay = True
        with patch.dict(os.environ, {"FLEET_PEERLINK_RELAY_FALLBACK": "0"}):
            self.assertEqual([c[3] for c in self.k.cands(l)], ["tailnet"])
        jump = [{"name": "entry", "host": "203.0.113.9", "port": 22022, "jump": "door"}]
        l.routes = jump
        self.assertEqual([c[3] for c in self.k.cands(l)], ["peer-relay"])   # already the relay


class E_Hostkey(Base):
    def test_repin_once(self):
        l = self.link()
        self.k.fail(l, "Host key verification failed.", 100.0)
        self.assertTrue(l.fresh_cert)
        self.assertEqual(l.next_try, 100.0)
        seen = []
        with patch.object(self.pl, "master_check", return_value=(False, 0)), \
                patch.object(self.pl, "peer_opts", side_effect=lambda m, fresh=False: (seen.append(fresh), ([], ""))[1]), \
                patch.object(self.pl.subprocess, "Popen"):
            self.k.start(l, 100.0)
            self.k.start(l, 101.0)
        self.assertEqual(seen, [True, False])
        self.k.fail(l, "Host key verification failed.", 102.0)
        self.assertEqual(l.next_try, 102.0 + self.pl.REFUSED_BACKOFF)

    def test_peer_cert_fresh_skips_cache(self):
        src = open(HERE / "fleet-peer-cert.sh").read()
        self.assertIn('"${FLEET_PEER_CERT_FRESH:-0}" != 1 ] && [ -s "$CERT" ]', src)


class F_Alert(Base):
    def test_alert_and_recover(self):
        l = self.link()
        self.k.fail(l, "Connection refused", 1000.0)
        self.k.alert(l, 1000.0 + self.pl.ALERT_SECS - 1)
        self.assertEqual(self.notes, [])
        self.k.alert(l, 1000.0 + self.pl.ALERT_SECS)
        self.k.alert(l, 1000.0 + self.pl.ALERT_SECS + 5)
        self.assertEqual(len(self.notes), 1)
        n = self.notes[0]
        self.assertEqual(n[:2], ["notify", "warn"])
        self.assertIn("网络不通", n[2])
        self.assertIn("--tag", n)
        tag = n[n.index("--tag") + 1]
        l.phase = "up"
        self.k.alert(l, 2000.0)
        self.assertEqual(self.notes[1][:3], ["amend", tag, "info"])

    def test_refusal_alerts_sooner(self):
        l = self.link()
        self.k.fail(l, "fleet connect: hub refused the connection: 426 Upgrade Required", 1000.0)
        self.k.alert(l, 1000.0 + self.pl.ALERT_REFUSED_SECS)
        self.assertEqual(self.notes[0][:2], ["notify", "error"])
        self.assertIn("4xx", self.notes[0][2])


class G_E2E(Base):
    def test_probe_cadence(self):
        self.assertLessEqual(min(self.pl.PROBE, self.pl.E2E_SECS), 60)
        src = open(HERE / "fleet-peerlink.py").read()
        self.assertIn("time.time() - l.last_probe >= E2E_SECS", src)


if __name__ == "__main__":
    unittest.main()
