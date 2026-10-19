#!/usr/bin/env python3
"""--settle (issue #4832): a node closes only its OWN dead local starts with the
existing actions. Fake Hub in memory, real processes for the native proofs;
production hub/nodes are never used."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import fleet_repo_authority as migration

OLD = "2026-10-01T00:00:00.123456789Z"
WORKER = "fleet-uuid/fid"


def native_of(pid):
    p = migration.launch.process(pid)
    return dict(worker_id=WORKER, native_session="sid-%d" % pid, pid=pid, birth=p["birth"], executable=p["executable"])


class FakeHub:
    """RepoLocalStart's transitions for the three settle actions, nothing more."""
    def __init__(self, starts):
        self.starts = {(s["repo"], s["reservation"]): dict(s) for s in starts}
        self.writes = []

    def api(self, method, path, body=None, query=None):
        repo = query["repo"]
        if method == "GET" and path == "/authority/start" and query.get("list") == "1":
            return dict(repo=repo, endpoint_id="node", starts=[
                dict(s) for (r, _), s in sorted(self.starts.items())
                if r == repo and s["endpoint_id"] == "node" and s["phase"] not in ("stopped", "cancelled", "abandoned")])
        assert method == "POST" and path == "/authority/start", (method, path)
        self.writes.append((repo, body["reservation"], body["action"]))
        s = self.starts[(repo, body["reservation"])]
        a = body["action"]
        if a == "cancel" and s["phase"] == "reserved":
            s["phase"] = "cancelled"
        elif a == "unobserved" and s["phase"] == "starting" and body.get("worker_id") == s["worker_id"] and not s.get("native_identity"):
            s["phase"] = "abandoned"
        elif a == "stopped" and s["phase"] == "observed" and body.get("native_identity") == s["native_identity"] and body.get("execution_stopped"):
            s["phase"] = "stopped"
        else:
            raise migration.hubrest.Fail(1, "HTTP 409 fence token=SECRET-X")
        return {k: v for k, v in s.items() if k != "updated"}

    def open(self, repo):
        return sorted(k for (r, k), s in self.starts.items()
                      if r == repo and s["phase"] not in ("stopped", "cancelled", "abandoned"))


def row(key, phase, repo="org/a", endpoint="node", **kw):
    return dict(reservation=key, repo=repo, owner="alice", endpoint_id=endpoint, phase=phase, updated=OLD, **kw)


class SettleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = patch.dict(os.environ, FLEET_CONF_DIR=self.tmp.name, FLEET_HUB_TOKEN="SECRET-X")
        self.env.start()
        self.addCleanup(self.env.stop)
        dead = subprocess.Popen(["sleep", "30"])
        self.dead = native_of(dead.pid)
        dead.kill()
        dead.wait()
        self.live = native_of(os.getpid())

    def run_settle(self, hub, held, apply):
        out = io.StringIO()
        with patch.object(migration.hubrest, "api", side_effect=hub.api), \
                patch.object(migration, "held_text", return_value=held), contextlib.redirect_stdout(out):
            migration.main(["org/a", "--settle"] + (["--apply"] if apply else []))
        return json.loads(out.getvalue())

    def four(self):
        return FakeHub([
            row("live", "observed", worker_id=WORKER, native_identity=self.live),
            row("dead-reserved", "reserved"),
            row("dead-starting", "starting", worker_id=WORKER),
            row("dead-observed", "observed", worker_id=WORKER, native_identity=self.dead),
            row("b-dead", "reserved", repo="org/b"),
            row("other-node", "reserved", endpoint="node-2"),
        ])

    def test_four_starts_only_the_live_one_left(self):
        hub = self.four()
        dry = self.run_settle(hub, "", False)
        self.assertEqual(hub.writes, [], "a dry settle wrote")
        self.assertEqual({r["reservation"]: r["action"] for r in dry["starts"]},
                         {"live": "keep", "dead-reserved": "cancel", "dead-starting": "unobserved", "dead-observed": "stopped"})
        done = self.run_settle(hub, "", True)
        self.assertEqual(hub.open("org/a"), ["live", "other-node"])
        self.assertEqual(done["counts"], {"alive": 1, "cancelled": 1, "abandoned": 1, "stopped": 1})
        self.assertEqual(hub.open("org/b"), ["b-dead"], "another repo changed")
        self.assertTrue(all(r == "org/a" for r, _, _ in hub.writes))
        self.assertNotIn("other-node", [k for _, k, _ in hub.writes], "another node's start touched")
        log = (Path(self.tmp.name) / "logs" / "authority.log").read_text().splitlines()
        self.assertEqual(len(log), 3)
        self.assertTrue(all("settle repo=org/a" in line for line in log))
        self.assertEqual(oct(os.stat(Path(self.tmp.name) / "logs" / "authority.log").st_mode & 0o777), "0o600")

    def test_held_recent_and_blind_are_left_alone(self):
        hub = FakeHub([row("held-r", "reserved"), row("held-s", "starting", worker_id=WORKER),
                       dict(row("young", "reserved"), updated=migration.time.strftime("%Y-%m-%dT%H:%M:%SZ", migration.time.gmtime()))])
        out = self.run_settle(hub, '{"reservation":"held-r"} FLEET_AUTHORITY_CONTEXT={"reservation":"held-s"}', True)
        self.assertEqual(hub.writes, [])
        self.assertEqual(out["counts"], {"held": 2, "recent": 1})
        blind = self.run_settle(FakeHub([row("x", "reserved")]), None, True)
        self.assertEqual(blind["counts"], {"unknown": 1}, "could not look, yet called it unheld")

    def test_refused_write_is_logged_without_credentials(self):
        hub = FakeHub([row("r", "reserved")])
        hub.starts[("org/a", "r")]["phase"] = "reserved"
        real = hub.api
        def refusing(method, path, body=None, query=None):
            if method == "POST":
                raise migration.hubrest.Fail(1, "HTTP 409 fence token=SECRET-X")
            return real(method, path, body, query)
        hub.api = refusing
        out = self.run_settle(hub, "", True)
        self.assertEqual(out["counts"], {"failed": 1})
        log = (Path(self.tmp.name) / "logs" / "authority.log").read_text()
        self.assertIn("result=failed", log)
        self.assertNotIn("SECRET-X", log + json.dumps(out))

    def test_old_hub_says_so(self):
        with patch.object(migration.hubrest, "api", side_effect=migration.hubrest.Fail(1, "HTTP 400 one explicit reservation is required")):
            with self.assertRaisesRegex(ValueError, "issue #4832"):
                migration.main(["org/a", "--settle"])
        with patch.object(migration.hubrest, "api", side_effect=migration.hubrest.Fail(1, "HTTP 503 down")):
            with self.assertRaises(migration.hubrest.Fail):
                migration.main(["org/a", "--settle"])
        with patch.object(migration.hubrest, "api", return_value=dict(phase="reserved")):
            with self.assertRaisesRegex(ValueError, "issue #4832"):
                migration.main(["org/a", "--settle"])


if __name__ == "__main__":
    unittest.main()
