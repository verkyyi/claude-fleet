#!/usr/bin/env python3
# selftest-entry
# Reads fleet-node-supervisor.py, fleet-node-update.py (task APVZ). A seated
# daemon's reload of a root machine job stops the core's JOB, not only its own
# stand-in (a shared credential proxy ran a release behind for a day: every
# start was answered «running»); <state>/hub-url follows machine.env, and the
# machine doctor says when it does not.
import importlib.util
import os
import tempfile
import types
import unittest
from unittest import mock

BIN = os.path.dirname(os.path.abspath(__file__))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(BIN, file))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


sup = load("fns_reload", "fleet-node-supervisor.py")
upd = load("fnu_reload", "fleet-node-update.py")


def fake_daemon(seated, children):
    logs = []
    d = types.SimpleNamespace(procs={}, adopted={}, seated=seated, state={"children": {}}, dirty=False,
                              all_children=lambda: children, seat_runs=lambda c: False,
                              core_cmd=lambda c: ["core", "call", "machine"], log=logs.append,
                              seat_stop=lambda name, pid: None)
    return d, logs


class SeatedReload(unittest.TestCase):
    def test_seated_stop_stops_the_cores_job(self):
        d, logs = fake_daemon(True, [{"name": "cred-proxy-shared", "cmd": ["x"]}])
        with mock.patch.object(sup, "core_ask", return_value={"ok": True}) as ask:
            sup.Supervisor.stop_one(d, "cred-proxy-shared", "changed — starting it again")
        ask.assert_called_once_with("machine", {"job": "cred-proxy-shared", "action": "stop"}, 60)
        self.assertIn("stopped", logs[-1])

    def test_account_job_and_unseated_unchanged(self):
        for seated, child in ((True, {"name": "w", "account": "alice"}), (False, {"name": "m", "cmd": ["x"]})):
            d, _ = fake_daemon(seated, [child])
            with mock.patch.object(sup, "core_ask") as ask:
                sup.Supervisor.stop_one(d, child["name"])
            ask.assert_not_called()

    def test_core_refusal_is_said(self):
        d, logs = fake_daemon(True, [{"name": "job", "cmd": ["x"]}])
        with mock.patch.object(sup, "core_ask", return_value={"error": "nope"}):
            sup.Supervisor.stop_one(d, "job")
        self.assertTrue(any("did not stop its job" in l for l in logs), logs)


class HubURL(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.paths = types.SimpleNamespace(state=self.d, machine_env=os.path.join(self.d, "machine.env"))

    def write(self, name, text):
        with open(os.path.join(self.d, name), "w") as f:
            f.write(text)

    def test_copy_follows_machine_env(self):
        self.write("machine.env", "CCQUOTA_HUB_URL=https://hub-new.example.com\nTOKEN=secret\n")
        self.write("hub-url", "https://hub-old.example.com\n")
        self.assertEqual(sup.machine_hub_url(self.paths), "https://hub-new.example.com")
        row = upd.hub_url_row(self.paths)
        self.assertEqual(row[0:2], ("WARN", "hub-url"))
        sup.seat_hub_url(self.paths)
        with open(os.path.join(self.d, "hub-url")) as f:
            self.assertEqual(f.read(), "https://hub-new.example.com\n")
        self.assertEqual(upd.hub_url_row(self.paths)[0], "PASS")

    def test_no_copy_or_no_address(self):
        self.write("machine.env", "CCQUOTA_HUB_URL=https://hub.example.com\n")
        self.assertIsNone(upd.hub_url_row(self.paths))          # no seat copy: no row
        self.write("hub-url", "https://hub.example.com\n")
        self.write("machine.env", "CCQUOTA_HUB_URL=not a url; rm -rf /\n")
        self.assertEqual(sup.machine_hub_url(self.paths), "")
        sup.seat_hub_url(self.paths)                           # a bad address never lands
        with open(os.path.join(self.d, "hub-url")) as f:
            self.assertEqual(f.read(), "https://hub.example.com\n")


if __name__ == "__main__":
    unittest.main()
