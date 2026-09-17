#!/usr/bin/env python3
"""Synthetic fixtures pin deduplication, selection, phase/write rules and medians."""

import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
BIN = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location("measure", BIN / "fleet-claim-grounding-measure.py")
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)
FIXTURES = BIN / "fixtures/claim-grounding"


class MeasurementTests(unittest.TestCase):
    def cli(self, *args, code=0):
        result = subprocess.run(["bash", str(BIN / "fleet-claim-grounding-measure.sh"), *map(str, args)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, code, result.stderr+result.stdout)
        return result.stdout

    def test_fixture_request_dedup_and_boundaries(self):
        s, reason = measure.analyze(FIXTURES / "worker.jsonl")
        self.assertIsNone(reason)
        self.assertEqual(s["unique_requests"], 6)
        self.assertEqual(s["preamble"], {"turns": 2, "output_tokens": 30})
        self.assertEqual(s["grounding"], {"turns": 2, "output_tokens": 70})
        self.assertEqual(s["first_write"], {"request_id": "r5", "reason": "Bash: Python file write",
                                          "elapsed_seconds": 59.0, "context_tokens": 91000})
        self.assertEqual(s["malformed_lines"], 1)
        self.assertEqual(s["rows_without_request_id"], 0)

    def test_selection_and_censored_medians(self):
        data = json.loads(self.cli(FIXTURES, "--limit", 0, "--json"))
        self.assertEqual((data["files_scanned"], data["matched_sessions"], data["complete_sessions"]), (4, 3, 2))
        med = data["medians"]
        self.assertEqual(med["preamble.turns"], {"median": 1.5, "samples": 2})
        self.assertEqual(med["preamble.output_tokens"], {"median": 30, "samples": 1})
        self.assertEqual(med["grounding.output_tokens"], {"median": 35.0, "samples": 2})
        self.assertEqual(med["first_write.context_tokens"], {"median": 91000, "samples": 1})
        self.assertEqual(med["first_write.elapsed_seconds"], {"median": 59.0, "samples": 1})
        self.assertEqual(data["skipped"][0]["reason"], "not a claim seed")
        self.assertNotIn("IMPLEMENT", json.dumps(data))
        self.assertNotIn("write_text", json.dumps(data))

    def test_limit_uses_start_time_and_reports_unknown(self):
        data = json.loads(self.cli(FIXTURES, "--limit", 1, "--json"))
        self.assertEqual(data["selected_sessions"], 1)
        self.assertTrue(data["sessions"][0]["path"].endswith("unfinished.jsonl"))
        self.assertTrue(all(m == {"median": None, "samples": 0} for m in data["medians"].values()))

    def test_default_discovery_and_empty_cohort(self):
        with tempfile.TemporaryDirectory(prefix="claim-measure-selftest-") as tmp:
            root = Path(tmp)
            project = root / "-tmp-claude-fleet-issue-461"
            project.mkdir()
            shutil.copy(FIXTURES / "worker.jsonl", project / "worker.jsonl")
            nested = project / "subagents"
            nested.mkdir()
            shutil.copy(FIXTURES / "worker.jsonl", nested / "worker.jsonl")
            data = json.loads(self.cli("--projects-dir", root, "--json"))
            self.assertEqual(data["files_scanned"], 1)
            self.assertEqual(data["matched_sessions"], 1)
            empty = json.loads(self.cli("--projects-dir", root, "--project-glob", "no-match", "--json", code=1))
            self.assertEqual(empty["selected_sessions"], 0)
        self.cli(FIXTURES / "absent.jsonl", code=2)
        self.cli("--limit", -1, code=2)

    def test_repeated_paths_and_table(self):
        data = json.loads(self.cli(FIXTURES / "worker.jsonl", FIXTURES / "worker.jsonl", "--json"))
        self.assertEqual(data["files_scanned"], 1)
        table = self.cli(FIXTURES)
        self.assertIn("preamble.turns", table)
        self.assertIn("grounding.output_tokens", table)
        self.assertIn("first_write.elapsed_seconds", table)
        self.assertIn("heuristic", table)
        self.assertIn("unknown", self.cli(FIXTURES / "unfinished.jsonl"))

    def test_first_write_shapes(self):
        writes = [
            "cat > source.sh <<'EOF'\ncode\nEOF", "echo data >> out", "echo data &> out",
            "cd work\nsed -i.bak 's/a/b/' file", "sed --in-place 's/a/b/' file",
            "perl -pi -e 's/a/b/' file", "apply_patch <<'PATCH'\npatch\nPATCH",
            "echo data | tee file", "python3 -c \"open('a', 'w').write('x')\"",
            "python3 - <<'PY'\nopen('a', mode='a')\nPY", "python3 -c \"p.write_bytes(b'x')\"",
        ]
        reads = [
            "echo '>'", "echo 'sed -i file'", "sed -n '1,20p' file", "echo x >/dev/null",
            "echo x 2>&1", "echo x >&2", "cat <<EOF\ntext\nEOF",
            "python3 - <<'PY'\nprint(open('a').read())\nPY", "cat file | tee /dev/stderr",
            "rg write_text bin", "echo apply_patch", "printf 'x >> y'",
            "cat <<'EOF'\nsed -i fake file\necho x > example\nEOF",
            "cat <<EOF\npython3 -c \"p.write_text('example')\"\nEOF",
        ]
        for command in writes:
            with self.subTest(command=command):
                self.assertIsNotNone(measure.write_reason({"name": "Bash", "input": {"command": command}}))
        for command in reads:
            with self.subTest(command=command):
                self.assertIsNone(measure.write_reason({"name": "Bash", "input": {"command": command}}))
        for name in ("Write", "Edit", "MultiEdit", "NotebookEdit", "apply_patch"):
            self.assertEqual(measure.write_reason({"name": name, "input": {}}), name)

    def test_claim_seed_is_anchored(self):
        for seed in ("/fleet-claim", "/fleet:fleet-claim #12", "<command-name>/fleet-claim</command-name>"):
            self.assertTrue(measure.claim_prompt(seed))
        for seed in ("Summarize: /fleet-claim", "/fleet-claim-other", "screen: <command-name>/fleet-claim</command-name>"):
            self.assertFalse(measure.claim_prompt(seed))

    def test_preamble_commands_and_mixed_requests(self):
        for command in ("source ~/.claude/fleet/bin/fleet-lib.sh\nS=$(fleet_current_session); fleet_load_conf \"$S\"\necho ok",
                        "gh issue view 461 --comments", "bin/fleet-claim-brief.sh", "cat AGENTS.md"):
            self.assertTrue(measure.preamble_tool({"name": "Bash", "input": {"command": command}}), command)
        for command in ("gh issue view 461; rg foo bin", "cat README.md", "source tests/setup.sh", "x=$(cat README.md)"):
            self.assertFalse(measure.preamble_tool({"name": "Bash", "input": {"command": command}}), command)

    def test_missing_ids_and_usage_updates(self):
        rows = [
            {"type": "user", "timestamp": "2026-01-01T00:00:00Z", "message": {"content": "/fleet-claim"}},
            {"type": "assistant", "message": {"id": "m", "content": [], "usage": {"output_tokens": 1}}},
            {"type": "assistant", "requestId": "r", "message": {"id": "m", "content": [], "usage": {"output_tokens": 10}}},
            {"type": "assistant", "message": {"content": [], "usage": {"output_tokens": 5}}},
            {"type": "assistant", "requestId": "write", "message": {"content": [{"type": "tool_use", "name": "Write", "input": {}}]}},
        ]
        with tempfile.TemporaryDirectory(prefix="claim-measure-selftest-") as tmp:
            path = Path(tmp) / "session.jsonl"
            path.write_text("\n".join(json.dumps(r) for r in rows))
            data, _ = measure.analyze(path)
        self.assertEqual(data["unique_requests"], 3)
        self.assertEqual(data["preamble"], {"turns": 2, "output_tokens": 15})
        self.assertEqual(data["rows_without_request_id"], 1)
        self.assertIsNone(data["first_write"]["context_tokens"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
