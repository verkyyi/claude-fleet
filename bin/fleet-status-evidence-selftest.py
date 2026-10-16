#!/usr/bin/env python3
"""Shared proof -> display, isolated fixtures; never live/provider acceptance."""
import copy
from pathlib import Path
import runpy
import json
import tempfile
import unittest
from unittest.mock import patch

import fleet_status_evidence as display
import fleet_reap_shadow as shadow
import fleet_view as view

fixture = runpy.run_path(str(Path(__file__).with_name("fleet-reap-shadow-selftest.py")))["fixture"]


class Display(unittest.TestCase):
    def rows(self, bundle=None, now=101, **kw):
        p = shadow.project(bundle or fixture(), now=101)
        with patch.object(shadow, "read", side_effect=AssertionError("display probed")):
            return {r["name"]: r for r in display.project(p, now=now, expected=kw.pop("expected", p["identity"]), **kw)["rows"]}

    def test_separate_native_task_delivery_and_reap(self):
        for native in ("active", "idle", "ask", "approval", "interrupted"):
            b = fixture()
            b["runtime"]["runtime"]["state"] = native
            b["layers"]["task"]["value"].update(state="running", outcome="")
            r = self.rows(b)
            self.assertEqual(r["runtime"]["state"], native)
            self.assertEqual(r["task"]["state"], "running")
            self.assertEqual(r["delivery"]["state"], "unknown")
            self.assertFalse(r["reap"]["actionable"])
        b = fixture()
        b["layers"]["processes"]["value"]["pending"] = [42]
        r = self.rows(b)
        self.assertEqual(r["task"]["state"], "succeeded")
        self.assertIn("processes", r["reap"]["last_known"])

    def test_expiry_lost_identity_and_no_timestamp_renewal(self):
        b = fixture(); original = copy.deepcopy(b)
        for kw in (dict(now=106), dict(lost=True), dict(expected_worker="another/worker")):
            r = self.rows(b, **kw)
            self.assertEqual(r["runtime"]["state"], "unknown")
            self.assertEqual(r["runtime"]["observed_at"], 100)
            self.assertEqual(r["runtime"]["last_known"]["state"], "idle")
        self.assertEqual(b, original)
        b["runtime"]["identity"] = {}
        self.assertEqual(self.rows(b)["runtime"]["state"], "unknown")

    def test_same_fid_new_generation_and_missing_current_binding(self):
        p = shadow.project(fixture(), now=101)
        expected = dict(p["identity"], generation=2, attempt_id="task:T1:g2")
        for binding in (None, expected, dict(p["identity"], turn_id="next")):
            rows = display.project(p, now=102, expected=binding)["rows"]
            self.assertTrue(all(r["state"] == "unknown" for r in rows))
            self.assertEqual(rows[0]["observed_at"], 100)

    def test_real_evidence_read_rereads_owner_after_same_fid_collection(self):
        p = shadow.project(fixture(), now=101)
        fid = p["identity"]["worker_id"].split("/")[1]
        row = dict(target="@1", fid=fid)
        for change in ({}, dict(turn_id="next"), dict(generation=2, attempt_id="task:T1:g2")):
            current = copy.deepcopy(p["runtime"])
            current["identity"].update(change)
            with tempfile.TemporaryDirectory() as directory, \
                    patch.object(view, "facts", return_value=dict(fid=fid, pane="%1")), \
                    patch.object(view, "dash_global", return_value=Path(directory)), \
                    patch.object(view, "evidence_command", side_effect=[p, current]) as command:
                observation = view.evidence_read("test", row)
                self.assertEqual(command.call_count, 2)
                self.assertIn("fleet_runtime.py", command.call_args.args[1][1])
                self.assertEqual(json.loads(command.call_args.args[2])["expected"], p["runtime"])
                binding = display.delivery_identity(observation, now=102)
                self.assertEqual(binding is None, bool(change))
                cache = json.loads(next(Path(directory).glob("status-proof-*")).read_text())
                self.assertEqual(cache, p)
                self.assertTrue(all(r["state"] == "unknown" for r in display.project(cache, now=102)["rows"]))

    def test_blockers_never_clear_attention(self):
        b = fixture(); t = b["layers"]["task"]["value"]
        scope = dict(task="T1", owner="alice", repo="", ticket_ref="", generation=1,
                     worker_id=b["runtime"]["identity"]["worker_id"])
        t["task_blockers"]["items"] = [dict(scope=scope, blocker_id=x, state="active") for x in ("a", "b")]
        t["task_blockers"]["items"][0]["state"] = "resolved"
        b["runtime"]["runtime"]["state"] = "approval"
        r = self.rows(b)
        self.assertEqual(r["blockers"]["projection"]["active_ids"], ["b"])
        self.assertEqual(r["runtime"]["state"], "approval")
        t["task_blockers"]["generation"] = 2
        self.assertEqual(self.rows(b)["blockers"]["state"], "unknown")

    def test_controller_and_startup_use_published_facts(self):
        b = fixture()
        b["runtime"]["runtime"].update(state="unknown", reason="first_thread_timeout",
                                        socket_ready=True, thread_ready=False, first_thread_deadline=90)
        for state in ("scheduled", "deferred", "overdue"):
            b["layers"]["loop"]["value"] = [dict(state=state)]
            r = self.rows(b)
            self.assertEqual(r["loop"]["last_known"], [dict(state=state)])
            self.assertEqual(r["delivery"]["reason"], "controller_acceptance_unavailable")
            self.assertEqual(r["runtime"]["first_thread_deadline"], 90)

    def test_lines_carry_retention_sources_without_native_identity(self):
        p = shadow.project(fixture(), now=101)
        text = "\n".join(display.lines(p, now=102, expected=p["identity"]))
        self.assertIn("codex:rpc", text)
        self.assertIn("not-actionable:no-atomic-boundary", text)
        self.assertNotIn("/private/socket", text)
        self.assertNotIn("execution_owner", text)


if __name__ == "__main__":
    unittest.main()
