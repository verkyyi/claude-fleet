#!/usr/bin/env python3
# selftest-entry
"""Acceptance statistics never replace missing days or missed wakes with success."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from fleet_park_metrics import daily, integrate_samples, record_sample, sample, sample_history


class CoverageTests(unittest.TestCase):
    def test_collector_records_zero_sessions_and_rotation_keeps_prior_samples(self):
        with patch("fleet_control.Control") as control:
            control.return_value.inventory.return_value = []
            row = sample()
            self.assertEqual(row["idle_count"], 0)
            self.assertEqual(row["fleet_count"], 0)
            control.return_value.workers.assert_not_called()
        from fleet_clientlog import rotate
        with tempfile.TemporaryDirectory() as tmp:
            record_sample(tmp, row)
            path = Path(tmp) / "logs/park-samples.ndjson"
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            # Exercise the actual rotation primitive with a small test limit.
            with patch("fleet_clientlog.rotate", side_effect=lambda p, limit: rotate(p, 1)) as rotation:
                record_sample(tmp, dict(row, ts=row["ts"] + 60))
                rotation.assert_called_once_with(str(path), limit=8 * 1024 * 1024)
            self.assertEqual(len(sample_history(path)), 2)
            self.assertEqual(set(sample_history(path)[0]), {"ts", "scope", "idle_count", "fleet_count"})

    def test_unknown_census_is_persisted_as_unknown(self):
        with patch("fleet_control.Control") as control:
            control.return_value.inventory.return_value = [{"fleet_id": "one"}]
            control.return_value.workers.return_value = {"park_metrics": {"sessions_idle": None}}
            self.assertIsNone(sample()["idle_count"])

    def test_missed_and_failed_opportunities_are_in_denominator(self):
        day, start = "2026-10-21", 1792540800
        rows = [dict(ts=start + 20, fid="a", act="wake", result="ok", secs=2, next=start + 10, started=start + 11),
                dict(ts=start + 21, fid="a", act="wake", result="ok", secs=2, next=start + 10, started=start + 11),
                dict(ts=start + 40, fid="b", act="fail", next=start + 30)]
        manifest = dict(complete=True, coverage_start=start, coverage_end=start + 86400,
                        opportunities=[dict(fid="a", due=start + 10), dict(fid="b", due=start + 30),
                                       dict(fid="never-started", due=start + 50)])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "park.ndjson"
            path.write_text("\n".join(json.dumps(row) for row in rows))
            observed = daily(path, day)
            self.assertEqual(observed["observed_scheduled"], 2)
            self.assertIsNone(observed["scheduled"])
            self.assertIsNone(observed["on_time_rate"])
            complete = daily(path, day, opportunities=manifest)
            self.assertEqual(complete["scheduled"], 3)
            self.assertEqual(complete["on_time_rate"], 1 / 3)
            # Retrying the same due event did not mint another opportunity.
            manifest["opportunities"].append(dict(fid="a", due=start + 10))
            self.assertEqual(daily(path, day, opportunities=manifest)["scheduled"], 3)
            manifest["opportunities"] = manifest["opportunities"][:1]
            self.assertFalse(daily(path, day, opportunities=manifest)["scheduled_complete"])

    def test_partial_day_and_zero_opportunities_never_claim_punctuality(self):
        start = 1792540800
        manifest = dict(complete=True, coverage_start=start, coverage_end=start + 86400, opportunities=[])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "absent"
            partial = daily(path, "2026-10-21", opportunities=manifest, as_of=start + 300)
            self.assertFalse(partial["scheduled_complete"])
            empty = daily(path, "2026-10-21", opportunities=manifest)
            self.assertEqual(empty["scheduled"], 0)
            self.assertIsNone(empty["on_time_rate"])

    def test_samples_cover_only_known_bounded_intervals(self):
        rows = [dict(ts=t, scope="node-a/alice", idle_count=n)
                for t, n in [(0, 2), (60, 2), (120, None), (180, 1), (1000, 1), (1060, 1)]]
        rows.append(dict(ts=120, scope="other/login", idle_count=0))
        result = integrate_samples(rows, 0, 7200, scope="node-a/alice")
        self.assertEqual(result["covered_seconds"], 120)
        self.assertEqual(result["uncovered_seconds"], 7080)
        self.assertAlmostEqual(result["observed_idle_session_hours"], 3 / 60)
        self.assertFalse(result["complete"])
        # A single reading cannot prove any elapsed idle session-hours.
        one = integrate_samples(rows[:1], 0, 259200, scope="node-a/alice")
        self.assertEqual(one["coverage"], 0)
        self.assertIsNone(one["observed_idle_session_hours"])

    def test_conflicting_samples_unknown_counts_and_scope_are_not_zero(self):
        rows = [dict(ts=t, scope="s", idle_count=n) for t, n in [(0, 0), (60, 0), (60, 4), (120, 0)]]
        result = integrate_samples(rows, 0, 120, scope="s")
        self.assertEqual(result["covered_seconds"], 0)
        self.assertIsNone(result["observed_idle_session_hours"])
        self.assertEqual(integrate_samples([], 0, 120, scope="s")["uncovered_seconds"], 120)
        rows = [dict(ts=t, scope="s", idle_count=0) for t in (0, 60, 120)]
        result = integrate_samples(rows, 0, 120, scope="s")
        self.assertTrue(result["complete"])
        self.assertEqual(result["observed_idle_session_hours"], 0)


if __name__ == "__main__":
    unittest.main()
