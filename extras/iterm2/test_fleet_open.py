"""Unit tests for fleet_open.py's pure logic — no iTerm2, no ssh, no network.

Run: python3 -m unittest discover -s extras/iterm2 -p 'test_*.py'
(bin/fleet-open-laptop-selftest.sh does, as part of the selftest gate.)
"""
import base64
import json
import os
import random
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fleet_open as fo  # noqa: E402


def b64(obj, urlsafe=False, strip=False):
    raw = json.dumps(obj).encode()
    s = (base64.urlsafe_b64encode(raw) if urlsafe else base64.b64encode(raw)).decode()
    return s.rstrip("=") if strip else s


class ParsePayload(unittest.TestCase):
    def test_forward_defaults(self):
        r = fo.parse_payload(b64({"v": 1, "kind": "forward", "rport": 8123}))
        self.assertEqual(r, {"kind": "forward", "rport": 8123, "path": "/", "scheme": "http", "host": ""})

    def test_forward_full(self):
        r = fo.parse_payload(b64({"v": 1, "kind": "forward", "rport": "8123", "path": "/d/ab/",
                                  "scheme": "https", "host": "macmini", "ts": 1000}), now=1100)
        self.assertEqual((r["rport"], r["path"], r["scheme"], r["host"]), (8123, "/d/ab/", "https", "macmini"))

    def test_url(self):
        r = fo.parse_payload(b64({"v": 1, "kind": "url", "url": "https://github.com/x/y/pull/1"}))
        self.assertEqual(r["url"], "https://github.com/x/y/pull/1")

    def test_urlsafe_and_unpadded(self):
        r = fo.parse_payload(b64({"v": 1, "kind": "url", "url": "https://claude.ai/?a=1&b=~~"}, urlsafe=True, strip=True))
        self.assertEqual(r["kind"], "url")

    def test_rejects(self):
        bad = [
            "!!notbase64!!",
            base64.b64encode(b"not json").decode(),
            b64([1, 2]),
            b64({"v": 2, "kind": "url", "url": "https://github.com"}),
            b64({"v": 1, "kind": "exec", "cmd": "rm -rf /"}),
            b64({"v": 1, "kind": "forward", "rport": 0}),
            b64({"v": 1, "kind": "forward", "rport": 70000}),
            b64({"v": 1, "kind": "forward", "rport": "x"}),
            b64({"v": 1, "kind": "forward", "rport": 80, "path": "no-slash"}),
            b64({"v": 1, "kind": "forward", "rport": 80, "path": "/a b"}),
            b64({"v": 1, "kind": "forward", "rport": 80, "scheme": "file"}),
            b64({"v": 1, "kind": "forward", "rport": 80, "host": "-oProxyCommand=evil"}),
            b64({"v": 1, "kind": "forward", "rport": 80, "host": "a b"}),
            b64({"v": 1, "kind": "url", "url": "file:///etc/passwd"}),
            b64({"v": 1, "kind": "url", "url": "javascript:alert(1)"}),
            b64({"v": 1, "kind": "url", "url": "https://x.com/a\nb"}),
            b64({"v": 1, "kind": "url", "url": 5}),
        ]
        for s in bad:
            with self.subTest(s=s):
                self.assertRaises(fo.Reject, fo.parse_payload, s)

    def test_host_cannot_be_an_option(self):
        # host goes straight into an ssh argv: a leading '-' would be read as a flag
        self.assertRaises(fo.Reject, fo.parse_payload, b64({"v": 1, "kind": "url", "url": "https://github.com", "host": "-x"}))

    def test_stale(self):
        p = b64({"v": 1, "kind": "url", "url": "https://github.com", "ts": 1000})
        self.assertRaises(fo.Reject, fo.parse_payload, p, now=1000 + fo.STALE_SECS + 1)
        fo.parse_payload(p, now=1000 + fo.STALE_SECS - 1)
        fo.parse_payload(p)  # no clock given: no staleness check


class Allow(unittest.TestCase):
    def test_default(self):
        self.assertEqual(fo.load_allow(None), ["github.com", "claude.ai"])

    def test_file(self):
        self.assertEqual(fo.load_allow("# mine\nExample.org\n\n.docs.rs  # trailing\n"), ["example.org", "docs.rs"])
        self.assertEqual(fo.load_allow(""), [])

    def test_match(self):
        allow = fo.load_allow(None)
        self.assertTrue(fo.host_allowed("github.com", allow))
        self.assertTrue(fo.host_allowed("gist.GitHub.com", allow))
        self.assertTrue(fo.host_allowed("claude.ai.", allow))
        self.assertFalse(fo.host_allowed("evilgithub.com", allow))
        self.assertFalse(fo.host_allowed("github.com.evil.io", allow))

    def test_check_url(self):
        self.assertEqual(fo.check_url("https://User@GitHub.com:443/x"), "github.com")
        self.assertRaises(fo.Reject, fo.check_url, "https:///nohost")
        self.assertRaises(fo.Reject, fo.check_url, "ftp://github.com/")


class Host(unittest.TestCase):
    def test_payload_wins(self):
        self.assertEqual(fo.resolve_host({"host": "mini"}, "other\n"), "mini")

    def test_file(self):
        self.assertEqual(fo.resolve_host({"host": ""}, "# alias\n  macmini \n"), "macmini")

    def test_none(self):
        self.assertRaises(fo.Reject, fo.resolve_host, {"host": ""}, None)
        self.assertRaises(fo.Reject, fo.resolve_host, {"host": ""}, "# only a comment\n")


class PickPort(unittest.TestCase):
    def pick(self, rport, remembered=None, busy=(), ours=()):
        return fo.pick_lport(rport, remembered, lambda p: p not in busy and p not in ours,
                             lambda p: p in ours, rng=random.Random(7))

    def test_same_port(self):
        self.assertEqual(self.pick(8123), (8123, False))

    def test_remembered_ours_is_reused(self):
        self.assertEqual(self.pick(8123, remembered=21000, ours={21000}), (21000, True))

    def test_remembered_free(self):
        self.assertEqual(self.pick(8123, remembered=21000), (21000, False))

    def test_remembered_taken_by_someone_else(self):
        self.assertEqual(self.pick(8123, remembered=21000, busy={21000}), (8123, False))

    def test_busy_picks_range(self):
        p, reuse = self.pick(8123, busy={8123})
        self.assertFalse(reuse)
        self.assertTrue(fo.PORT_LO <= p <= fo.PORT_HI)

    def test_rport_held_by_unrelated_ssh_is_not_reused(self):
        # only the REMEMBERED port may be adopted; an ssh on rport may forward elsewhere
        p, reuse = self.pick(8123, ours={8123})
        self.assertFalse(reuse)
        self.assertNotEqual(p, 8123)

    def test_exhausted(self):
        self.assertRaises(fo.Reject, fo.pick_lport, 8123, None, lambda p: False, lambda p: False, random.Random(1))


class Commands(unittest.TestCase):
    def test_mux(self):
        self.assertEqual(fo.mux_forward_cmd("macmini", 21000, 8123),
                         ["ssh", "-O", "forward", "-L", "21000:127.0.0.1:8123", "macmini"])

    def test_fallback(self):
        c = fo.fallback_forward_cmd("macmini", 8123, 8123)
        self.assertEqual(c[:2], ["ssh", "-N"])
        self.assertIn("ExitOnForwardFailure=yes", c)
        self.assertIn("BatchMode=yes", c)
        self.assertEqual(c[-3:], ["-L", "8123:127.0.0.1:8123", "macmini"])

    def test_local_url(self):
        self.assertEqual(fo.local_url("http", 21000, "/d/ab/?x=1"), "http://localhost:21000/d/ab/?x=1")

    def test_confirm_quotes(self):
        c = fo.confirm_cmd('https://x.io/"; do shell script "rm"')
        self.assertEqual(c[:2], ["osascript", "-e"])
        self.assertIn('\\"; do shell script \\"rm\\"', c[2])

    def test_log_line(self):
        self.assertEqual(fo.log_line(0, "url", "a\tb\nc", "opened"),
                         "1970-01-01T00:00:00Z\turl\ta b c\topened\n")

    def test_version_is_a_plain_literal(self):
        # fleet-doctor greps this line over ssh; keep its shape
        src = open(fo.__file__).read()
        self.assertRegex(src, r'(?m)^FLEET_OPEN_VERSION = "[0-9]+"')


class Reaper(unittest.TestCase):
    def test_idle_forward_closed(self):
        class P:
            def __init__(self):
                self.done = None

            def poll(self):
                return self.done

            def terminate(self):
                self.done = -15

        old = fo.CONF_DIR
        tmp = tempfile.TemporaryDirectory()
        fo.CONF_DIR = tmp.name
        try:
            idle, fresh = P(), P()
            fo._fallbacks.clear()
            fo._fallbacks[1] = [idle, 0]
            fo._fallbacks[2] = [fresh, fo.IDLE_SECS]
            fo.reap_idle(now=fo.IDLE_SECS + 1)
            self.assertEqual(idle.done, -15)
            self.assertIsNone(fresh.done)
            self.assertEqual(list(fo._fallbacks), [2])
        finally:
            fo._fallbacks.clear()
            fo.CONF_DIR = old
            tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
