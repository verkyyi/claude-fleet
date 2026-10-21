#!/usr/bin/env python3
"""Isolated migration fixtures; production hub/nodes and GitHub are never used."""
import contextlib
import copy
import io
import json
import re
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import fleet_repo_authority as migration


class RepoAuthorityTests(unittest.TestCase):
    def test_gate_asks_the_persons_mode_and_reserves_nothing(self):
        # EPIC T497 C8: a start is admitted by its window's ID — no reservation,
        # no claim; frozen and unknown still refuse, an outage is never a fallback.
        for mode in ("legacy", "hub"):
            calls = []
            def api(method, path, body=None, query=None):
                calls.append((method, path))
                return dict(mode=mode, revision=0)
            with patch.object(migration.hubrest, "api", side_effect=api), \
                    contextlib.redirect_stdout(io.StringIO()) as out:
                migration.gate("org/a", True)
            self.assertEqual(json.loads(out.getvalue()), dict(mode=mode, ticket_ref=""))
            self.assertEqual(calls, [("GET", "/authority")])

    def test_supervise_execs_the_launcher_without_a_retired_environment(self):
        # A session started under the launch proof or a start reservation reopens
        # as itself: nothing is asked of the hub, their environment is not handed on.
        env = dict(os.environ, FLEET_LAUNCH_CONTEXT="{}", FLEET_LAUNCH_SUPERVISOR="1",
                   FLEET_AUTHORITY_CONTEXT="{}", FLEET_ID_DISPATCH="{}", FLEET_KEPT="yes")
        env.pop("TMUX_PANE", None)
        out = subprocess.run([sys.executable, str(Path(migration.__file__)), "--supervise", "--", "env"],
                             env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(out.returncode, 0, out.stderr)
        names = {line.split("=", 1)[0] for line in out.stdout.splitlines()}
        self.assertIn("FLEET_KEPT", names)
        self.assertFalse(names & set(migration.RETIRED_ENV))

    def test_the_wrapper_drops_the_same_retired_environment(self):
        # fleet-session-wrap.sh execs the launcher with `env -u` (T716) instead of
        # the --supervise hop: its list is RETIRED_ENV, name for name.
        wrap = (Path(migration.__file__).parent / "fleet-session-wrap.sh").read_text()
        block = wrap[wrap.index('env -u FLEET_LAUNCH '):wrap.index('"$LAUNCH" ${cmd[@]+')]
        self.assertEqual(set(re.findall(r"-u (FLEET_[A-Z_]+)", block)), set(migration.RETIRED_ENV))
    def test_manifest_apply_repeat_rollback_and_repo_b(self):
        # The cutover is the person's (issue #4901): it writes this login's
        # fleet.conf [node] line and no repo overlay, A's or B's.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            conf = root / "conf"
            repos = conf / "fleets/fixture/repos"
            repos.mkdir(parents=True)
            (conf / "fleets/fixture/conf").write_text('FLEET_SESSION="fixture"\n')
            login = conf / "fleet.conf"
            login.write_text('FLEET_HOST=1\n')
            a = repos / "org-a.conf"
            b = repos / "org-b.conf"
            original = 'FLEET_REPO="org/a"\nFLEET_TICKETS="github"\nFLEET_FORGE="github"\nFLEET_LAND="github"\n'
            a.write_text(original)
            b.write_text(original.replace("org/a", "org/b"))
            old_a, old_b = a.read_bytes(), b.read_bytes()
            authority = dict(owner="alice", mode="legacy", revision=0)
            history, calls = {}, []

            def api(method, path, body=None, query=None):
                nonlocal authority
                calls.append((method, path, dict(query or {})))
                if method == "GET":
                    if query.get("gate"):
                        return copy.deepcopy(authority)
                    return dict(authority=copy.deepcopy(authority), nodes=[], legacy_owners=[],
                                blockers=[], dry_run=True, live_acceptance="unverified")
                key = body["idempotency_key"]
                if key in history:
                    return copy.deepcopy(history[key])
                self.assertEqual(authority["revision"], body["expected_revision"])
                authority = dict(authority, mode={"freeze": "frozen", "apply": "hub", "rollback": "legacy"}[body["action"]],
                                 revision=authority["revision"] + 1)
                history[key] = copy.deepcopy(authority)
                return copy.deepcopy(authority)

            def run(*args):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    migration.main(list(args))
                return json.loads(out.getvalue())

            env = dict(os.environ, FLEET_CONF_DIR=str(conf), FLEET_SKIP_GLOBAL_CONF="1")
            for key in ("TMUX", "TMUX_PANE", "FLEET_SESSION", "FLEET_REPO", "FLEET_TASK_AUTHORITY"):
                env.pop(key, None)
            with patch.dict(os.environ, env, clear=True), patch.object(migration.hubrest, "api", side_effect=api):
                baseline = {str(p): p.read_bytes() for p in conf.rglob("*") if p.is_file()}
                doc = run("--dry-run")
                self.assertEqual(baseline, {str(p): p.read_bytes() for p in conf.rglob("*") if p.is_file()})
                self.assertEqual((doc["version"], doc["scope"], doc["owner"]), (2, "owner", "alice"))
                manifest = root / "manifest.json"
                for stage, mode in (("freeze", "frozen"), ("apply", "hub"), ("freeze", "frozen"), ("rollback", "legacy")):
                    manifest.write_text(json.dumps(run("org/a", "--dry-run")))
                    first = run("--" + stage, "--manifest", str(manifest))
                    bytes_after = login.read_bytes()
                    repeated = run("org/b", "--" + stage, "--manifest", str(manifest))
                    self.assertEqual(first, repeated)
                    self.assertEqual(bytes_after, login.read_bytes())
                    self.assertIn('FLEET_TASK_AUTHORITY="%s"' % mode, login.read_text())
                    self.assertEqual((old_a, old_b), (a.read_bytes(), b.read_bytes()))
                self.assertTrue(login.read_text().startswith('FLEET_HOST=1\n'))
                self.assertEqual(authority["mode"], "legacy")
                self.assertTrue(all(path == "/authority" for _, path, _ in calls))
                self.assertFalse([q for m, _, q in calls if m == "POST" and q.get("repo")])
            print("fixture manifest: dry-run writes=0, repeat apply identical, fleet.conf [node] only, repo A/B overlays unchanged")

    def test_second_host_follows_apply_and_rollback(self):
        # Issues #4730, #4901: a host of the same person follows the cutover; a
        # login of ANOTHER person on the same machine and repo does not move.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = 'FLEET_REPO="org/a"\nFLEET_TICKETS="github"\nFLEET_FORGE="github"\nFLEET_LAND="github"\n'
            owner_of = {"node-a": "alice", "node-b": "alice", "login-c": "bob"}
            overlays = {}
            for host in owner_of:
                repos = root / host / "fleets/fixture/repos"
                repos.mkdir(parents=True)
                (root / host / "fleets/fixture/conf").write_text('FLEET_SESSION="fixture"\n')
                overlays[host] = repos / "org-a.conf"
                overlays[host].write_text(original)
            rows = {o: dict(owner=o, mode="legacy", revision=0) for o in ("alice", "bob")}

            def who():
                return owner_of[Path(os.environ["FLEET_CONF_DIR"]).name]

            def api(method, path, body=None, query=None):
                a = rows[who()]
                if method == "GET":
                    if query.get("gate"):
                        return copy.deepcopy(a)
                    return dict(authority=copy.deepcopy(a), nodes=[], legacy_owners=[],
                                blockers=[], dry_run=True, live_acceptance="unverified")
                a.update(mode={"freeze": "frozen", "apply": "hub", "rollback": "legacy"}[body["action"]],
                         revision=a["revision"] + 1)
                return copy.deepcopy(a)

            def run(host, *args):
                out = io.StringIO()
                env = dict(os.environ, FLEET_CONF_DIR=str(root / host), FLEET_SKIP_GLOBAL_CONF="1")
                for key in ("TMUX", "TMUX_PANE", "FLEET_SESSION", "FLEET_REPO", "FLEET_TASK_AUTHORITY"):
                    env.pop(key, None)
                with patch.dict(os.environ, env, clear=True), contextlib.redirect_stdout(out):
                    migration.main(list(args))
                return json.loads(out.getvalue())

            def effective(host):
                return run(host, "--dry-run")["local"]["settings"]["FLEET_TASK_AUTHORITY"]

            with patch.object(migration.hubrest, "api", side_effect=api):
                untouched = run("node-b", "org/a", "--sync")
                self.assertEqual(untouched["changed"], [])
                self.assertFalse((root / "node-b/fleet.conf").exists())
                manifest = root / "manifest.json"
                for stage, mode in (("freeze", "frozen"), ("apply", "hub"), ("rollback", "legacy")):
                    manifest.write_text(json.dumps(run("node-a", "--dry-run")))
                    run("node-a", "--" + stage, "--manifest", str(manifest))
                    self.assertEqual(effective("node-a"), mode)
                    self.assertEqual(run("node-b", "org/a", "--sync")["changed"], ["fleet.conf"])
                    self.assertEqual(effective("node-b"), mode)
                    self.assertEqual(run("node-b", "--sync")["changed"], [])
                    self.assertEqual(run("login-c", "org/a", "--sync")["changed"], [])
                    self.assertEqual(effective("login-c"), "")
                for host in owner_of:
                    self.assertEqual(overlays[host].read_text(), original)
                self.assertFalse((root / "login-c/fleet.conf").exists())
                self.assertEqual(rows["bob"], dict(owner="bob", mode="legacy", revision=0))
            with patch.object(migration.hubrest, "api", return_value=dict(mode="unknown")):
                before = (root / "node-b/fleet.conf").read_bytes()
                with self.assertRaises(ValueError):
                    run("node-b", "--sync")
                self.assertEqual(before, (root / "node-b/fleet.conf").read_bytes())
            print("two hosts of alice follow frozen/hub/legacy; bob's login on the same repo stays legacy; overlays and unknown untouched")

    def test_forge_none_manifest_and_unknown_gate(self):
        with patch.object(migration, "login_settings", return_value=(dict(settings=dict(FLEET_TASK_AUTHORITY="")), Path("fleet.conf"))), \
                patch.object(migration.hubrest, "api", return_value=dict(authority=dict(owner="alice", mode="legacy", revision=0))) as api:
            doc = migration.manifest("Org/A")
            self.assertEqual((doc["owner"], doc["repo"]), ("alice", "org/a"))
            api.assert_called_once_with("GET", "/authority", query={"rollback": "1", "repo": "org/a"})
        for mode in ("frozen", "unknown"):
            with patch.object(migration.hubrest, "api", return_value=dict(mode=mode)):
                with self.assertRaises(ValueError):
                    migration.gate("org/a", True)
        with patch.object(migration.hubrest, "api", side_effect=migration.hubrest.Fail(4, "unavailable")):
            with self.assertRaises(migration.hubrest.Fail):
                migration.gate("org/a", False)

if __name__ == "__main__":
    unittest.main()
