#!/usr/bin/env python3
"""Isolated migration fixtures; production hub/nodes and GitHub are never used."""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import fleet_repo_authority as migration
import fleet_task_control as control


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
        for mode in ("frozen", "hub"):
            with patch.object(migration.ticket, "api", return_value=dict(mode=mode)), patch.dict(os.environ, {"FLEET_LAUNCH": ""}):
                with self.assertRaises(ValueError):
                    migration.gate("org/a", True)
        with patch.object(migration.ticket, "api", side_effect=migration.ticket.Fail(4, "unavailable")):
            with self.assertRaises(migration.ticket.Fail):
                migration.gate("org/a", False)

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
