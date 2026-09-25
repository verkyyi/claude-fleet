#!/usr/bin/env python3
"""Policy tests and a real isolated tmux -> history -> restore round trip."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
BIN = Path(sys.argv.pop(1))
sys.path.insert(0, str(BIN))
from fleet_reap_notice import notice
spec = importlib.util.spec_from_file_location("idle", BIN / "fleet-cleanup-idle.py")
idle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(idle)


class NoticeTests(unittest.TestCase):
    def test_notice_has_visible_tick_and_resets_on_activity_or_stale_tick(self):
        opts = {"@claude_state": "done", "@claude_state_ts": "100"}
        def tm(*args):
            if args[0] == "display-message":
                return opts.get(args[-1][2:-1], "")
            if args[1] == "-wu":
                opts.pop(args[-1], None)
            else:
                opts[args[-2]] = args[-1]
            return ""
        self.assertEqual(notice(tm, "@1", "raw", 1000, 2000), 2060)
        self.assertEqual(notice(tm, "@1", "raw", 1000, 2060), 2060)
        opts["@claude_state_ts"] = "2050"
        self.assertEqual(notice(tm, "@1", "raw", 1000, 2061), 2121)
        self.assertEqual(notice(tm, "@1", "raw", 1000, 3000), 3060)
        before = dict(opts)
        self.assertEqual(notice(tm, "@1", "raw", 1000, 3060, dry=True), 3060)
        self.assertEqual(opts, before)
        opts["@claude_state"] = "working"
        with self.assertRaises(ValueError):
            notice(tm, "@1", "raw", 1000, 3100)
        self.assertNotIn("@reap_due", opts)

    def test_hold_notice_has_no_countdown_and_yields_to_one(self):
        # Issue #1156: a merged PR whose bound issue is still open is HELD, not due.
        opts = {"@claude_state": "done", "@claude_state_ts": "100"}
        def tm(*args):
            if args[0] == "display-message":
                return opts.get(args[-1][2:-1], "")
            if args[1] == "-wu":
                opts.pop(args[-1], None)
            else:
                opts[args[-2]] = args[-1]
            return ""
        self.assertEqual(notice(tm, "@1", "issue-open:9:8", 0, 500, dry=True, hold="x"), "hold")
        self.assertNotIn("@reap_due", opts)
        self.assertEqual(notice(tm, "@1", "issue-open:9:8", 0, 500, hold="PR #9 merged"), "hold")
        self.assertEqual((opts["@reap_due"], opts["@reap_seen"], opts["@reap_state_ts"],
                          opts["@reap_hold"]), ("hold", "500", "100", "PR #9 merged"))
        # the issue closed → an ordinary countdown takes over, with a fresh visible tick
        self.assertEqual(notice(tm, "@1", "merged:9:abc", 0, 560), 620)
        self.assertNotIn("@reap_hold", opts)
        opts["@claude_state"] = "working"
        with self.assertRaises(ValueError):
            notice(tm, "@1", "issue-open:9:8", 0, 600, hold="x")
        self.assertNotIn("@reap_hold", opts)


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class RoundTrip(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="idle-reap-")
        self.root = Path(self.tmp.name).resolve()
        self.main = self.root / "main"
        self.wt = self.root / "repo-scratch-7"
        self.label = "idle-reap-test-" + str(os.getpid())
        self.env = dict(os.environ)
        self.env.pop("TMUX", None)
        self.env.pop("TMUX_PANE", None)
        self.env.update(FLEET_CONF_DIR=str(self.root / "conf"),
                        FLEET_HISTORY_LEDGER=str(self.root / "ledger.tsv"),
                        CLAUDE_PROJECTS_DIR=str(self.root / "projects"),
                        FLEET_REAP_MIN_AGE="0")
        (self.root / "conf").mkdir()
        self.ibin = self.root / "install/bin"
        self.ibin.mkdir(parents=True)
        for p in BIN.iterdir():
            if p.is_file():
                (self.ibin / p.name).symlink_to(p)
        launcher = self.ibin / "fleet-claude.sh"
        launcher.unlink()
        launcher.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" > " + shlex.quote(str(self.root / "resume-args")) + "\nexec sleep 90\n")
        launcher.chmod(0o755)
        fake = self.root / "fake"
        fake.mkdir()
        gh = fake / "gh"
        gh.write_text("#!/bin/sh\ncat " + shlex.quote(str(self.root / "prs.json")) + "\n")
        gh.chmod(0o755)
        self.env["PATH"] = str(fake) + ":" + self.env["PATH"]
        (self.root / "prs.json").write_text("[]")
        self.call("git", "init", "-q", "-b", "master", str(self.main))
        self.call("git", "-C", str(self.main), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                  "commit", "-qm", "base", "--allow-empty")
        self.call("git", "-C", str(self.main), "worktree", "add", "-qb", "scratch-7", str(self.wt))
        head = self.call("git", "-C", str(self.main), "rev-parse", "HEAD").strip()
        self.call("git", "-C", str(self.main), "update-ref", "refs/remotes/origin/master", head)
        (self.root / "conf" / (self.label + ".conf")).write_text(
            f'FLEET_REPO=acme/repo\nFLEET_MAIN={shlex.quote(str(self.main))}\nFLEET_REAP_MIN_AGE=0\n')
        self.tm("-f", "/dev/null", "new-session", "-d", "-s", self.label, "-c", str(self.root), "sleep 90")
        self.win = self.tm("new-window", "-d", "-P", "-F", "#{window_id}", "-t", self.label,
                           "-c", str(self.wt), "sleep 90").strip()
        for key, value in {"@raw": "1", "@worktree": str(self.wt), "@claude_state": "done",
                           "@claude_state_ts": str(int(time.time()) - 4000), "@cc_agent": "claude"}.items():
            self.set(key, value)
        self.tdir = self.root / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(self.wt))
        self.tdir.mkdir(parents=True)
        self.sid = "11111111-1111-4111-8111-111111111111"
        self.transcript = self.tdir / (self.sid + ".jsonl")
        self.transcript.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": "research"}}) + "\n")

    def tearDown(self):
        subprocess.run(["tmux", "-L", self.label, "kill-server"], capture_output=True)
        self.tmp.cleanup()

    def call(self, *args):
        return subprocess.check_output(args, env=self.env, text=True, stderr=subprocess.PIPE, timeout=20)

    def tm(self, *args):
        return self.call("tmux", "-L", self.label, *args)

    def set(self, key, value):
        self.tm("set-option", "-w", "-t", self.win, key, value)

    def clean(self, *args):
        return self.call("bash", str(self.ibin / "fleet-cleanup-idle.sh"), self.label, *args)

    def exists(self):
        return self.win in self.tm("list-windows", "-t", self.label, "-F", "#{window_id}").split()

    def mature_notice(self):
        self.clean()
        self.set("@reap_due", str(int(time.time()) - 1))

    def test_real_close_and_restore(self):
        self.assertEqual(self.clean(), "")
        self.assertTrue(self.exists())
        self.assertGreater(int(self.tm("display-message", "-p", "-t", self.win, "#{@reap_due}")), int(time.time()))
        self.set("@reap_due", str(int(time.time()) - 1))
        self.assertIn("reaped-idle:" + self.win, self.clean())
        self.assertFalse(self.exists())
        self.assertTrue(self.wt.is_dir())
        self.assertTrue(self.transcript.is_file())
        self.assertIn(self.sid, (self.root / "ledger.tsv").read_text())
        self.call("bash", str(self.ibin / "dash-restore-session.sh"), "landed:scratch:scratch-7", self.label)
        until = time.monotonic() + 5
        while not (self.root / "resume-args").exists() and time.monotonic() < until:
            time.sleep(0.05)
        self.assertIn("--resume\n" + self.sid, (self.root / "resume-args").read_text())
        self.assertIn(str(self.wt), self.tm("list-windows", "-t", self.label, "-F", "#{@worktree}"))

    def test_codex_close_and_restore_keeps_exact_identity(self):
        home = self.root / "codex-home"
        transcript = home / "sessions/2026/09/17" / ("rollout-" + self.sid + ".jsonl")
        transcript.parent.mkdir(parents=True)
        transcript.write_text(json.dumps({"type": "session_meta", "payload": {"id": self.sid, "cwd": str(self.wt)}}) + "\n")
        pid = self.tm("display-message", "-p", "-t", self.win, "#{pane_pid}").strip()
        self.set("@cc_agent", "codex")
        self.set("@cc_launcher_pid", pid)
        self.set("@codex_identity", json.dumps({"session_id": self.sid, "owner": pid,
                                               "home": str(home), "transcript": str(transcript), "cwd": str(self.wt)}))
        self.mature_notice()
        self.assertIn("reaped-idle:", self.clean())
        self.call("bash", str(self.ibin / "dash-restore-session.sh"), "landed:scratch:scratch-7", self.label)
        until = time.monotonic() + 5
        while not (self.root / "resume-args").exists() and time.monotonic() < until:
            time.sleep(0.05)
        args = (self.root / "resume-args").read_text()
        self.assertIn("--agent\ncodex\n--codex-home\n" + str(home), args)
        self.assertIn(self.sid, args)
        self.assertTrue(transcript.exists())

    def test_unmerged_pr_requires_strict_ancestor_and_activity_recheck(self):
        self.call("git", "-C", str(self.main), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                  "commit", "--allow-empty", "-qm", "advance base")
        head = self.call("git", "-C", str(self.main), "rev-parse", "HEAD").strip()
        self.call("git", "-C", str(self.main), "update-ref", "refs/remotes/origin/master", head)
        (self.root / "prs.json").write_text('[{"state":"OPEN"}]')
        self.mature_notice()
        # Resume a turn after the real history writer returns; the final snapshot
        # must reject this without dropping the worktree or closing the window.
        script = self.ibin / "fleet-history.sh"
        script.unlink()
        script.write_text('#!/bin/bash\nbash ' + shlex.quote(str(BIN / 'fleet-history.sh')) + ' "$@" || exit $?\n'
                          + 'if [ "$1" = record-closed ]; then tmux -L ' + shlex.quote(self.label)
                          + ' set-option -w -t ' + self.win + ' @claude_state working; fi\n')
        self.clean()
        self.assertTrue(self.exists())
        script.unlink()
        script.symlink_to(BIN / "fleet-history.sh")
        self.set("@claude_state", "done")
        self.assertIn("reaped-idle:", self.clean())

    def test_shared_git_gate_protects_bound_live_worktree(self):
        self.set("@claude_state", "working")
        head = self.call("git", "-C", str(self.wt), "rev-parse", "HEAD").strip()
        args = ("bash", "-c", '. "$1/fleet-lib.sh"; v=$(fleet_reap_ok "$2" "$3" scratch-7 "$4" "$4" scratch-7); r=$?; printf "%s:%s" "$v" "$r"',
                "gate", str(self.ibin), str(self.wt), str(self.main), head)
        self.assertEqual(self.call(*args), "live:1")
        self.set("@claude_state", "done")
        self.assertEqual(self.call(*args), "merged-pr:0")

    def test_dirty_active_loop_recent_unknown_and_unmerged_are_kept(self):
        self.mature_notice()
        for state in ("working", "looping", "busy", "needs", ""):
            self.set("@claude_state", state)
            self.clean()
            self.assertTrue(self.exists(), state)
        self.set("@claude_state", "done")
        (self.wt / "dirty").write_text("keep")
        self.clean()
        self.assertTrue(self.exists())
        (self.wt / "dirty").unlink()
        (self.root / "prs.json").write_text('[{"state":"OPEN"}]')
        self.clean()
        self.assertTrue(self.exists())  # tip==base is not a strict ancestor
        (self.root / "prs.json").write_text("not JSON")
        self.clean()
        self.assertTrue(self.exists())
        (self.root / "prs.json").write_text("[]")
        self.set("@claude_state_ts", str(int(time.time())))
        self.clean()
        self.assertTrue(self.exists())
        manifest = self.root / "handoff/manifest.json"
        (manifest.parent / "loop").mkdir(parents=True)
        (manifest.parent / "loop/state.json").write_text('{"status":"waiting-quota"}')
        self.set("@handoff_manifest", str(manifest))
        self.set("@claude_state_ts", str(int(time.time()) - 4000))
        self.clean()
        self.assertTrue(self.exists())

    def test_missing_transcript_and_failed_ledger_do_not_close(self):
        self.mature_notice()
        self.transcript.unlink()
        self.clean()
        self.assertTrue(self.exists())

        self.transcript.write_text('{"type":"user","message":{"role":"user","content":"back"}}\n')
        self.env["FLEET_HISTORY_LEDGER"] = str(self.root)  # cannot append to a directory
        self.clean()
        self.assertTrue(self.exists())

    def test_dry_cap_off_and_rate_limit(self):
        self.mature_notice()
        before = self.tm("show-options", "-w", "-t", self.win)
        self.assertIn("would-reap-idle:", self.clean("--dry-run"))
        self.assertEqual(before, self.tm("show-options", "-w", "-t", self.win))
        self.assertFalse((self.root / "ledger.tsv").exists())
        self.clean("--limit", "0")
        self.assertTrue(self.exists())
        conf = self.root / "conf" / (self.label + ".conf")
        original = conf.read_text()
        conf.write_text(original + "FLEET_REAP_IDLE_DONE_MIN=0\n")
        self.clean()
        self.assertTrue(self.exists())
        conf.write_text(original)
        gh = self.root / "fake/gh"
        log = self.root / "gh-calls"
        gh.write_text("#!/bin/sh\necho call >> " + shlex.quote(str(log))
                      + "\necho 'API rate limit exceeded' >&2\nexit 1\n")
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.clean()
        self.assertEqual(caught.exception.returncode, 75)
        self.assertEqual(log.read_text().splitlines(), ["call"])
        self.assertTrue(self.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
