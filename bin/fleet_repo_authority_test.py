#!/usr/bin/env python3
"""Isolated migration fixtures; production hub/nodes and GitHub are never used."""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import fleet_repo_authority as migration
import fleet_task_control as control


@unittest.skipUnless(shutil.which("tmux"), "tmux is required")
class PoolAuthorityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fleet-authority-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.socket = self.root / "fixture"
        self.conf = self.root / "conf"
        self.identities = {
            "fixture": "11111111-1111-4111-8111-111111111111",
            "fixture-pool": "22222222-2222-4222-8222-222222222222",
            "separate-pool": "33333333-3333-4333-8333-333333333333",
        }
        self.fid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        self.native_program = shutil.which("true")
        self.assertIsNotNone(self.native_program)
        self.panes = {}
        self.addCleanup(lambda: subprocess.run(["tmux", "-S", str(self.socket), "kill-server"],
                                              capture_output=True))
        for session, identity in self.identities.items():
            directory = self.conf / "fleets" / session
            directory.mkdir(parents=True)
            (directory / "identity").write_text(identity + "\n")
            if session != "fixture-pool":
                (directory / "conf").write_text('FLEET_REPO="org/a"\n')
            pane = self.tm("-f", "/dev/null", "new-session", "-d", "-P", "-F", "#{pane_id}",
                           "-s", session, "-c", str(self.root), "sleep 60")
            self.panes[session] = pane
            self.tm("set-option", "-w", "-t", pane, "@fleet_id", self.fid)
            self.tm("set-option", "-w", "-t", pane, "@repo", "org/a")

    def tm(self, *arguments):
        return subprocess.check_output(["tmux", "-S", str(self.socket), *arguments],
                                       text=True, stderr=subprocess.PIPE).strip()

    def supervise(self, session, expected, hint=None, refuse=False):
        worker = self.identities[expected] + "/" + self.fid
        pane = self.panes[session]
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("FLEET_") and key not in ("TMUX", "TMUX_PANE")}
        environment.update(HOME=str(self.root), FLEET_CONF_DIR=str(self.conf),
                           FLEET_SKIP_GLOBAL_CONF="1", CCQUOTA_FLEET="1", TMUX_PANE=pane,
                           TMUX=str(self.socket) + "," + self.tm("display-message", "-p", "#{pid}") + ",0")
        if hint is not None:
            environment["FLEET_LAUNCH_SESSION"] = hint
        native = dict(worker_id=worker, native_session="native", pid=456,
                      birth="birth", executable=self.native_program)
        receipt = dict(repo="org/a", worker_id=worker, reservation="", supervisor=os.getpid(),
                       native_identity=native)
        writes = []

        def start(repo, key, action, **fields):
            self.assertEqual(repo, "org/a")
            writes.append(action)
            if action == "reserve":
                receipt["reservation"] = key
            elif action == "begin":
                self.assertEqual(fields["worker_id"], worker)
                if refuse:
                    raise migration.ticket.Fail(4, "worker belongs to another node")
            elif action == "stopped":
                self.assertEqual(fields["native_identity"], native)
                self.assertTrue(fields["execution_stopped"])

        with patch.dict(os.environ, environment, clear=True), \
                patch.object(migration, "start_call", side_effect=start), \
                patch.object(migration.signal, "signal"), \
                patch.object(migration.launch, "option", side_effect=lambda *args: json.dumps(receipt)), \
                patch.object(migration, "prove_stopped", return_value=native):
            if refuse:
                with self.assertRaisesRegex(migration.ticket.Fail, "another node"):
                    migration.supervise([self.native_program])
            else:
                self.assertEqual(migration.supervise([self.native_program]), 0)
        self.assertEqual(writes, ["reserve", "begin", "cancel" if refuse else "stopped"])
        self.assertFalse((self.conf / "fleets/fixture-pool/conf").exists())

    def test_warm_pool_uses_owning_fleet_with_launch_hint(self):
        self.supervise("fixture-pool", "fixture", "fixture")

    def test_warm_pool_uses_socket_without_launch_hint(self):
        self.supervise("fixture-pool", "fixture")

    def test_unrelated_launch_hint_cannot_rebind_pool(self):
        self.supervise("fixture-pool", "fixture", "separate")

    def test_normal_fleet_ignores_unrelated_launch_hint(self):
        self.supervise("fixture", "fixture", "separate")

    def test_genuine_fleet_ending_in_pool_keeps_identity(self):
        self.supervise("separate-pool", "separate-pool", "fixture")

    def test_claimed_window_keeps_its_owning_fleet_identity(self):
        self.supervise("fixture-pool", "fixture", "fixture")
        self.tm("move-window", "-s", "fixture-pool:", "-t", "fixture:")
        self.supervise("fixture-pool", "fixture", "fixture")

    def test_hub_refusal_remains_fatal_after_pool_resolution(self):
        self.supervise("fixture-pool", "fixture", "fixture", refuse=True)


class RepoAuthorityTests(unittest.TestCase):
    def test_final_gate_reserves_before_window_creation(self):
        calls = []
        def api(method, path, body=None, query=None):
            calls.append((method, path, body))
            if method == "GET":
                return dict(mode="legacy", revision=0)
            return dict(reservation="fixture-start", mode="legacy")
        with patch.object(migration.ticket, "api", side_effect=api), contextlib.redirect_stdout(io.StringIO()):
            migration.gate("org/a", True)
        self.assertTrue(any(method == "POST" and body.get("action") == "reserve"
                            for method, _, body in calls), "last gate must leave a durable reservation before any window exists")

    def test_unbound_and_wrong_native_receipt_refused(self):
        proof = dict(worker_id="fleet/session", native_session="old", pid=123, birth="old-birth", executable="/bin/codex")
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "receipt.json"
            f.write_text(json.dumps(proof))
            with patch.object(migration.os, "kill", side_effect=ProcessLookupError()):
                for saved in (None, dict(proof, native_session="replacement", pid=456)):
                    authority = dict(legacy_owners=[dict(worker_id=proof["worker_id"], native_identity=saved)])
                    with self.assertRaises(ValueError):
                        migration.stopped_receipt(f, authority)

    def test_accepted_ticket_reference_survives_work_completion(self):
        c = dict(task="T9", owner="alice", generation=1, worker_id="fleet/session")
        task = dict(owner="alice", generation=1, execution_owner="fleet/session",
                    ticket_ref="hub:org/a#8", outcome="succeeded")
        with patch.object(migration.launch, "validate_context", return_value=c), \
                patch.object(migration.launch, "task_call", return_value=task):
            with patch.object(migration.sys, "stdin", io.StringIO("{}")), contextlib.redirect_stdout(io.StringIO()) as out:
                migration.ticket_ref("org/a", "8")
            self.assertEqual(out.getvalue().strip(), "hub:org/a#8")
            for repo, number in (("org/b", "8"), ("org/a", "7")):
                with patch.object(migration.sys, "stdin", io.StringIO("{}")), self.assertRaises(ValueError):
                    migration.ticket_ref(repo, number)
            task["generation"] = 2
            with patch.object(migration.sys, "stdin", io.StringIO("{}")), self.assertRaises(ValueError):
                migration.ticket_ref("org/a", "8")

    def test_manifest_apply_repeat_rollback_and_repo_b(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            conf = root / "conf"
            repos = conf / "fleets/fixture/repos"
            repos.mkdir(parents=True)
            (conf / "fleets/fixture/conf").write_text('FLEET_SESSION="fixture"\n')
            a = repos / "org-a.conf"
            b = repos / "org-b.conf"
            original = 'FLEET_REPO="org/a"\nFLEET_TICKETS="github"\nFLEET_FORGE="github"\nFLEET_LAND="github"\n'
            a.write_text(original)
            b.write_text(original.replace("org/a", "org/b"))
            old_b = b.read_bytes()
            authority = dict(repo="org/a", mode="legacy", revision=0)
            history, calls = {}, []

            def api(method, path, body=None, query=None):
                nonlocal authority
                self.assertEqual(query["repo"], "org/a")
                calls.append((method, path))
                if method == "GET":
                    if query.get("gate"):
                        return copy.deepcopy(authority)
                    return dict(authority=copy.deepcopy(authority), nodes=[], legacy_owners=[],
                                tickets=[], blockers=[], dry_run=True, live_acceptance="unverified")
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
                    migration.main(["org/a", "--session", "fixture", *args])
                return json.loads(out.getvalue())

            env = dict(os.environ, FLEET_CONF_DIR=str(conf), FLEET_SKIP_GLOBAL_CONF="1")
            for key in ("TMUX", "TMUX_PANE", "FLEET_SESSION", "FLEET_REPO", "FLEET_TASK_AUTHORITY"):
                env.pop(key, None)
            with patch.dict(os.environ, env, clear=True), patch.object(migration.ticket, "api", side_effect=api):
                baseline = {str(p): p.read_bytes() for p in conf.rglob("*") if p.is_file()}
                doc = run("--dry-run")
                self.assertEqual(baseline, {str(p): p.read_bytes() for p in conf.rglob("*") if p.is_file()})
                manifest = root / "manifest.json"
                for stage in ("freeze", "apply", "freeze", "rollback"):
                    manifest.write_text(json.dumps(run("--dry-run")))
                    first = run("--" + stage, "--manifest", str(manifest))
                    bytes_after = a.read_bytes()
                    repeated = run("--" + stage, "--manifest", str(manifest))
                    self.assertEqual(first, repeated)
                    self.assertEqual(bytes_after, a.read_bytes())
                    self.assertEqual(old_b, b.read_bytes())
                self.assertIn(original, a.read_text())
                self.assertEqual(authority["mode"], "legacy")
                self.assertTrue(all(path == "/authority" for _, path in calls))
                self.assertEqual(doc["local"]["settings"]["FLEET_FORGE"], "github")
            print("fixture manifest: dry-run writes=0, repeat apply identical, repo B unchanged, forge/land/ticket home retained")

    def test_forge_none_manifest_and_unknown_gate(self):
        with patch.object(migration, "local_settings", return_value=(dict(settings=dict(FLEET_FORGE="none", FLEET_LAND="fleet", FLEET_TICKETS="hub")), Path("fixture"))), \
                patch.object(migration.ticket, "api", return_value=dict(authority=dict(mode="legacy", revision=0))):
            self.assertEqual(migration.manifest("fixture", "org/a")["local"]["settings"]["FLEET_FORGE"], "none")
        for mode in ("frozen", "hub", "unknown"):
            with patch.object(migration.ticket, "api", return_value=dict(mode=mode)), patch.dict(os.environ, {"FLEET_LAUNCH": ""}):
                with self.assertRaises(ValueError):
                    migration.gate("org/a", True)
        with patch.object(migration.ticket, "api", side_effect=migration.ticket.Fail(4, "unavailable")):
            with self.assertRaises(migration.ticket.Fail):
                migration.gate("org/a", False)

    def test_native_hook_cannot_bind_a_nested_or_wrong_process(self):
        c = dict(repo="org/a", worker_id="fleet/session", reservation="start", supervisor=123)
        native = dict(pid=456, birth="birth", executable="/bin/codex")
        with patch.dict(os.environ, {"FLEET_AUTHORITY_CONTEXT": json.dumps(c), "TMUX_PANE": "%1"}), \
                patch.object(migration.launch, "native_parent", return_value=native), \
                patch.object(migration.launch, "root_native", return_value=False), \
                patch.object(migration, "start_call") as write:
            with self.assertRaises(ValueError):
                migration.observe_native(dict(hook_event_name="SessionStart", session_id="11111111-1111-4111-8111-111111111111"))
            write.assert_not_called()

    def test_supervisor_confirms_only_its_own_observed_native_stop(self):
        c = dict(repo="org/a", worker_id="fleet/session", reservation="start", supervisor=os.getpid())
        native = dict(worker_id="fleet/session", pid=456, birth="birth", executable="/bin/codex", native_session="native")
        for replaced in (False, True):
            receipt = dict(c, native_identity=native)
            if replaced:
                receipt["reservation"] = "replacement"
            writes = []
            with patch.dict(os.environ, {"FLEET_AUTHORITY_START": "start", "TMUX_PANE": "%1"}), \
                    patch.object(migration.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "org/a\tfleet/session", "")), \
                    patch.object(migration.subprocess, "Popen") as child, \
                    patch.object(migration.signal, "signal"), \
                    patch.object(migration.launch, "option", return_value=json.dumps(receipt)), \
                    patch.object(migration.os, "kill", side_effect=ProcessLookupError()), \
                    patch.object(migration, "start_call", side_effect=lambda r, k, a, **kw: writes.append(a)), \
                    contextlib.redirect_stderr(io.StringIO()):
                child.return_value.wait.return_value = 0
                self.assertEqual(migration.supervise(["fixture-native"]), 0)
            self.assertEqual(writes, ["begin"] if replaced else ["begin", "stopped"])

    def test_stop_receipt_requires_positive_proof(self):
        proof = dict(worker_id="fleet/session", native_session="native", pid=123, birth="birth", executable="/bin/codex")
        authority = dict(legacy_owners=[dict(worker_id=proof["worker_id"], native_identity=proof)])
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "receipt.json"
            f.write_text(json.dumps(proof))
            with patch.object(migration.os, "kill", return_value=None), patch.object(migration.launch, "process", return_value=proof):
                with self.assertRaisesRegex(ValueError, "still alive"):
                    migration.stopped_receipt(f, authority)
            with patch.object(migration.os, "kill", side_effect=PermissionError("unknown")):
                with self.assertRaises(PermissionError):
                    migration.stopped_receipt(f, authority)
            with patch.object(migration.os, "kill", side_effect=ProcessLookupError()):
                self.assertTrue(migration.stopped_receipt(f, authority)["execution_stopped"])

    def test_blocked_github_keeps_work_and_pr_separate(self):
        c = dict(task="T9", owner="alice", generation=1, worker_id="fleet/session")
        t = dict(owner="alice", generation=1, execution_owner="fleet/session", ticket_ref="gh:org/a#7")
        receipt = dict(native_session="native", actual_provider="codex")
        saved = []
        with patch.object(control, "context", return_value=c), patch.object(control, "call", return_value=dict(task=t)), \
                patch.object(control.launch, "option", return_value="{}"), patch.object(control.launch, "check_receipt", return_value=receipt), \
                patch.object(control, "publish_report", side_effect=lambda r: saved.append(r) or 0), \
                patch.object(control.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "UNKNOWN", "GitHub blocked")) as gh:
            control.report("%1", "waiting", "work complete; PR pending", "10", False, outcome="succeeded")
            gh.assert_not_called()
            self.assertEqual(saved[0]["outcome"], "succeeded")
            self.assertEqual(json.loads(saved[0]["evidence"])["pr_state"], "waiting")
            with self.assertRaisesRegex(ValueError, "unconfirmed"):
                control.report("%1", "merged", "merge claimed", "10", False)
            self.assertEqual(len(saved), 1)
        print("fixture GitHub blocked: explicit work result committed without GitHub; merged refused; PR remains waiting")


if __name__ == "__main__":
    unittest.main()
