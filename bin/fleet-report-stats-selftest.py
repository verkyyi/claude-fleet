#!/usr/bin/env python3
"""fleet-report-stats selftest (issue #941): fixture transcripts + ledger pin all five
metrics and what must NOT count (a quoted report, a classifier screen, a heredoc)."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
BIN = Path(sys.argv.pop(1))
TOOL = BIN / "fleet-report-stats.py"
spec = importlib.util.spec_from_file_location("stats", TOOL)
stats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stats)

ENV_HEAD = 'Another Claude session sent a message:\n<cross-session-message from-name="fleet" from-mode="bypass">\n'


def report(child, state, branch, summary=""):
    body = "[child-report] %s\nstate: %s · branch %s\n" % (child, state, branch)
    if summary:
        body += "summary: %s\n" % summary
    return ENV_HEAD + body + "no reply needed\n</cross-session-message>"


def user(ts, content):
    return {"type": "user", "timestamp": ts, "message": {"role": "user", "content": content}}


def tool_result(ts, text):
    return user(ts, [{"type": "tool_result", "tool_use_id": "t", "content": text}])


def asst(ts, *cmds, text=None):
    content = [{"type": "tool_use", "id": "t", "name": "Bash", "input": {"command": c}} for c in cmds]
    if text:
        content.append({"type": "text", "text": text})
    return {"type": "assistant", "timestamp": ts, "message": {"role": "assistant", "content": content}}


def write(path, entries):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(e, ensure_ascii=False) + "\n" for e in entries))


def build(root):
    P = root / "projects"
    L = root / "fleets"
    # --- the PARENT (scratch-1 of repo acme/widgets) --------------------------------
    parent = [
        # 1 MERGED for #10 (test_same_parent_merged_then_stopped adds the later REAPED)
        user("2026-09-20T01:00:00Z", report('issue #10 "ten"', "MERGED (PR #110)", "issue-10")),
        asst("2026-09-20T01:00:05Z", text="noted"),
        # 2 STOPPED for #11: child keeps working after → misfire. Parent verifies with 3 tools
        #   (two tool_result round-trips, then the next REAL user message ends the count).
        user("2026-09-20T02:00:00Z", report('issue #11 "eleven"', "STOPPED (no ship report)", "issue-11")),
        asst("2026-09-20T02:00:05Z", "gh pr list --head issue-11", "tmux capture-pane -p -t @3"),
        tool_result("2026-09-20T02:00:06Z", "…"),
        asst("2026-09-20T02:00:07Z", "gh pr view 111"),
        tool_result("2026-09-20T02:00:08Z", "…"),
        user("2026-09-20T02:05:00Z", "operator: carry on"),
        asst("2026-09-20T02:05:01Z", "ls"),                       # NOT counted: after a real user msg
        # 3 STOPPED for #12: child silent after → a TRUE stop; no follow-up tools
        user("2026-09-20T03:00:00Z", report('issue #12 "twelve"', "STOPPED (no ship report)", "issue-12")),
        user("2026-09-20T03:00:30Z", "operator: ok"),
        # 4 STOPPED for #13: the child had already RUN a merged report the parent never got → dup
        user("2026-09-20T04:00:00Z", report('issue #13 "thirteen"', "STOPPED (no ship report)", "issue-13")),
        # 5 STOPPED for a scratch child → unresolved (no issue transcript)
        user("2026-09-20T05:00:00Z", report('scratch ~7 "sc"', "STOPPED (no ship report)", "scratch-7")),
        # 6 FAILED for #14 — delivered AND in the ledger (matched, not double-counted)
        user("2026-09-21T01:00:30Z", report('issue #14 "fourteen"', "FAILED (PR #114)", "issue-14")),
        # 7 a digest: one wake, many ledger events
        user("2026-09-21T02:00:00Z", ENV_HEAD + "[children-digest] 2/3 ✓\n…\n</cross-session-message>"),
        # --- must NOT count ---------------------------------------------------------
        tool_result("2026-09-20T06:00:00Z",
                    "--- envelope ---\n[child-report] issue #99 \"q\"\nstate: STOPPED (no ship report) · branch issue-99\n"),
        user("2026-09-20T06:01:00Z", "You are a status classifier…\n[child-report] issue #98 \"s\"\n"
                                     "state: STOPPED (no ship report) · branch issue-98\n"),
        # 8 a report on 2026-09-23 — outside --until 2026-09-22
        user("2026-09-23T12:00:00Z", report('issue #15 "fifteen"', "MERGED (PR #115)", "issue-15")),
    ]
    write(P / "-home-u-widgets-scratch-1" / "p1.jsonl", parent)
    # the same MERGED entry again in a forked copy → deduped on (ts, child, state)
    write(P / "-home-u-widgets-scratch-1" / "p1-fork.jsonl", parent[:2])
    # a second repo's parent: filtered out by --repo acme/widgets
    write(P / "-home-u-gadgets-scratch-2" / "p2.jsonl",
          [user("2026-09-20T07:00:00Z", report('issue #50 "fifty"', "STOPPED (no ship report)", "issue-50"))])

    # --- the CHILDREN ------------------------------------------------------------------
    write(P / "-home-u-widgets-issue-10" / "c.jsonl", [asst("2026-09-20T00:59:00Z", "true")])
    write(P / "-home-u-widgets-issue-11" / "c.jsonl",
          [asst("2026-09-20T01:59:00Z", "bash tools/await-pr.sh 111"),
           asst("2026-09-20T02:10:00Z", "gh pr merge 111")])          # still working → misfire
    write(P / "-home-u-widgets-issue-12" / "c.jsonl", [asst("2026-09-20T02:59:00Z", "true")])
    write(P / "-home-u-widgets-issue-13" / "c.jsonl",
          [asst("2026-09-20T03:30:00Z",
                "cat > h.md <<'EOF'\n~/.claude/fleet/bin/fleet-report-parent.sh --state merged --pr 1\nEOF"),
           asst("2026-09-20T03:50:00Z",
                "~/.claude/fleet/bin/fleet-report-parent.sh --state merged --pr 113 \\\n  --summary 'landed'"),
           asst("2026-09-20T04:10:00Z", text="done")])                # continues → also a misfire
    # a SAME-NUMBERED issue in another repo must not be picked for acme/widgets #12
    write(P / "-home-u-gadgets-issue-12" / "c.jsonl",
          [asst("2026-09-20T02:59:30Z", "true"), asst("2026-09-20T09:00:00Z", "true")])
    write(P / "-home-u-gadgets-issue-50" / "c.jsonl", [asst("2026-09-20T06:59:00Z", "true")])

    # --- the LEDGER ------------------------------------------------------------------
    led = L / "fleet-widgets" / "children"
    led.mkdir(parents=True)
    events = [
        {"seq": 1, "ts": "2026-09-21T01:00:00Z", "child": "issue-14", "state": "FAILED", "pr": "114"},
        {"seq": 2, "ts": "2026-09-21T01:10:00Z", "child": "issue-16", "state": "WAITING", "pr": ""},
        {"seq": 3, "ts": "2026-09-21T01:20:00Z", "child": "issue-16", "state": "MERGED", "pr": "116"},
        {"seq": 4, "ts": "2026-09-21T01:30:00Z", "child": "issue-17", "state": "MERGED", "pr": "117"},
    ]
    (led / "scratch-1.ndjson").write_text("".join(json.dumps(e) + "\n" for e in events) + "not json\n")
    other = L / "fleet-gadgets" / "children"
    other.mkdir(parents=True)
    (other / "scratch-2.ndjson").write_text(json.dumps(
        {"seq": 1, "ts": "2026-09-21T01:00:00Z", "child": "issue-51", "state": "MERGED"}) + "\n")
    return P, L


class ReportStats(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.P, cls.L = build(Path(cls.tmp.name))

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_cli(self, *args):
        r = subprocess.run([sys.executable, str(TOOL), "--projects", str(self.P), "--ledger-root", str(self.L),
                            *args], capture_output=True, text=True, env=dict(os.environ, TZ="UTC"))
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def stats(self, *args):
        return json.loads(self.run_cli("--json", *args))

    def test_widgets_all_five(self):
        s = self.stats("--repo", "acme/widgets", "--until", "2026-09-22")
        # deliveries: #10 MERGED, #11 #12 #13 scratch~7 STOPPED, #14 FAILED — fork dup,
        # tool_result quote, classifier screen, the 09-23 report and gadgets all excluded
        self.assertEqual(s["reports"], 6, s["states"])
        self.assertEqual(s["states"], {"MERGED": 1, "STOPPED": 4, "FAILED": 1})
        # 1 misfire: #11 and #13 kept working, #12 did not (gadgets #12 ignored), scratch unresolved
        self.assertEqual((s["misfire"]["misfires"], s["misfire"]["resolved"], s["misfire"]["unresolved"]),
                         (2, 3, 1))
        # 2 stopped share
        self.assertEqual((s["stopped_share"]["stopped"], s["stopped_share"]["reports"]), (4, 6))
        # 3 wake: 6 report messages + 1 digest = 7 wakes; events = 4 ledger + 5 unledgered
        #   (#14 FAILED is matched to its ledger event, so it is not counted twice)
        w = s["wake"]
        self.assertEqual((w["wakes"], w["digests"], w["ledger_events"], w["unledgered_reports"], w["events"]),
                         (7, 1, 4, 5, 9))
        # 4 verify: 3 tools after #11, 0 after #12/#13/scratch → 3 / 4
        v = s["verify"]
        self.assertEqual((v["tool_uses"], v["reports"]), (3, 4))
        self.assertEqual(v["commands"], {"gh pr": 2, "capture-pane": 1})
        # 5 dup: only #13 (its own merged call came first); #10's MERGED is never
        #   followed by a STOPPED here — test_same_parent_merged_then_stopped adds one
        self.assertEqual(sorted(c["child"] for c in s["dup_after_merged"]["cases"]), ["issue #13"])

    def test_same_parent_merged_then_stopped(self):
        extra = self.P / "-home-u-widgets-scratch-1" / "p1-late.jsonl"
        write(extra, [user("2026-09-20T09:00:00Z", report('issue #10 "ten"', "REAPED (full)", "issue-10"))])
        try:
            s = self.stats("--repo", "acme/widgets", "--until", "2026-09-22")
            self.assertEqual(sorted(c["child"] for c in s["dup_after_merged"]["cases"]), ["issue #10", "issue #13"])
        finally:
            extra.unlink()

    def test_window_bounds(self):
        self.assertEqual(self.stats("--repo", "acme/widgets", "--until", "2026-09-23")["reports"], 7)
        s = self.stats("--repo", "acme/widgets", "--since", "2026-09-21")
        self.assertEqual(s["states"], {"FAILED": 1, "MERGED": 1})
        self.assertEqual(s["wake"]["ledger_events"], 4)
        self.assertEqual(self.stats("--until", "2026-09-20T02:30:00Z")["reports"], 2)

    def test_all_repos_and_ledger_scope(self):
        s = self.stats("--until", "2026-09-22")
        self.assertEqual(s["states"]["STOPPED"], 5)                    # + gadgets #50
        self.assertEqual(s["wake"]["ledger_events"], 5)                 # + gadgets ledger

    def test_table_is_five_rows(self):
        out = self.run_cli("--repo", "acme/widgets", "--until", "2026-09-22").strip().splitlines()
        self.assertEqual(len(out), 7, out)                               # header + rule + 5
        self.assertIn("66.7%", out[2])
        self.assertIn("2 / 3", out[2])
        self.assertIn("0.78", out[4])
        self.assertIn("0.8 次", out[5])
        self.assertIn("1 例", out[6])

    def test_empty_window(self):
        s = self.stats("--since", "2030-01-01")
        self.assertIsNone(s["misfire"]["value"])
        out = self.run_cli("--since", "2030-01-01")
        self.assertIn("—", out)

    def test_bounds_and_repo_match(self):
        d = stats.parse_bound("2026-09-22", end=True)
        self.assertEqual((d - stats.parse_bound("2026-09-22")).days, 1)
        self.assertTrue(stats.repo_matches("acme/widgets", "-home-u-widgets-issue-3"))
        self.assertFalse(stats.repo_matches("acme/widgets", "-home-u-widgetsx-issue-3"))
        self.assertTrue(stats.repo_matches("acme/widgets", "acme/widgets"))
        with self.assertRaises(SystemExit):
            stats.parse_bound("yesterday")


if __name__ == "__main__":
    unittest.main(verbosity=1)
