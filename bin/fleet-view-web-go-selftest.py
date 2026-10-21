#!/usr/bin/env python3
# fleet-view-web-go-selftest.py — a browser 看台's ⌘P onto another machine's
# session (task C8X3): bin/fleet_view.py's go() on a `wt-` view writes
# `ESC ] 7502 ; web-go ; w=<worker id> BEL` to its client's own tty (the page,
# extras/web-console terminal.tsx, opens /terminal?worker=<id>) and says rc 0 —
# never 「<machine> is not connected yet」; a bad id writes nothing and says the
# browser line. A real pty stands in for the browser's terminal; tmux is faked.
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
import importlib.util
import os
import pty
import select
import sys
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fleet_view", BIN / "fleet_view.py")
fv = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(BIN))
spec.loader.exec_module(fv)

WID = "33333333-3333-4333-8333-333333333333/44444444-4444-4444-8444-444444444444"


class WebGo(unittest.TestCase):
    def setUp(self):
        self.master, slave = pty.openpty()
        self.tty = os.ttyname(slave)
        self.slave = slave
        self.toasts, self.logs = [], []
        self.patch = {
            "tm": lambda *a: (0, self.tty) if "#{client_tty}" in a else (0, ""),
            "view_row": lambda vid: {"node": "mac-a"},
            "view_fleet": lambda vid, row: "fleet",
            "current": lambda vid, fleet: "@1",
            "resolve": lambda vid, target, row, fleet: ("", True),
            "order_load": lambda vid: None,
            "toast": lambda client, text, *a, **k: self.toasts.append(text),
            "log_switch": lambda rec: self.logs.append(rec),
            "tell_cur": lambda g: None,
            "hist_save": lambda *a: None,
            "hist_load": lambda *a: [],
        }
        self.saved = {k: getattr(fv, k) for k in self.patch}
        for k, v in self.patch.items():
            setattr(fv, k, v)

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(fv, k, v)
        os.close(self.master)
        os.close(self.slave)

    def read(self):
        out = b""
        while select.select([self.master], [], [], 0.2)[0]:
            out += os.read(self.master, 4096)
        return out

    class QO:
        def visit(self, h, t):
            return h

    def test_far_session_goes_through_the_page(self):
        rc = fv.go(self.QO(), "wt-web-abc", WID, "popup", "/dev/ttys999", {"machine": "mac-b", "far": True})
        self.assertEqual(rc, 0)
        self.assertIn(("\x1b]7502;web-go;w=%s\x07" % WID).encode(), self.read())
        self.assertEqual(self.toasts, [])
        self.assertEqual(self.logs[-1]["method"], "web-go")

    def test_bad_id_writes_nothing(self):
        rc = fv.go(self.QO(), "wt-web-abc", "../../etc;x", "popup", "/dev/ttys999", {"machine": "mac-b"})
        self.assertEqual(rc, 3)
        self.assertEqual(self.read(), b"")
        self.assertEqual(fv.far_miss("wt-web-abc", {"far": True, "machine": "mac-b"}, rc), fv.say("view_web_far"))
        self.assertNotIn("mac-b", fv.far_miss("wt-web-abc", {"far": True, "machine": "mac-b"}, rc))


if __name__ == "__main__":
    unittest.main()
