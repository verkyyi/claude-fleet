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


class Rig(unittest.TestCase):
    """An isolated tmux server + repo + scratch worktree (no tests of its own)."""
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


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class RoundTrip(Rig):

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


class PolicyGrammar(unittest.TestCase):
    """bin/fleet_reap_policy.py — the one parser (issue #1902)."""
    def test_norm_default_label(self):
        import fleet_reap_policy as rp
        self.assertEqual(rp.norm("merged"), "merged")
        self.assertEqual(rp.norm("merged:48h"), "merged:48h")
        self.assertEqual(rp.norm("done"), "done:2h")
        self.assertEqual(rp.norm("done:30m"), "done:30m")
        self.assertEqual(rp.norm("loop-end"), "loop-end")
        self.assertEqual(rp.norm("keep"), "keep")
        self.assertEqual(rp.norm("at:2026-10-06T18:00Z"), "at:2026-10-06T18:00:00Z")
        self.assertEqual(rp.norm("at:1791320000"), "at:" + rp.iso(1791320000))
        self.assertRegex(rp.norm("at:18:00"), r"^at:\d{4}-\d\d-\d\dT\d\d:\d\d:00Z$")
        for bad in ("", "never", "merged:", "done:0", "done:-1h", "keep:1", "at:soon", "at:25:00",
                    "merged:1y", "loop-end:1h", "done:9999999d"):
            self.assertIsNone(rp.norm(bad), bad)
        self.assertEqual((rp.default("issue"), rp.default("scratch"), rp.default("loop")),
                         ("merged", "done:2h", "loop-end"))
        self.assertEqual(rp.parse("done:2h"), ("done", 7200))
        self.assertEqual([rp.label(p) for p in ("merged", "done:2h", "loop-end", "keep")],
                         ["合并后回收", "做完就回收", "循环停了回收", "常驻"])
        self.assertEqual(rp.label("merged:48h"), "合并后留 2 天")
        self.assertEqual([rp.merged_grace(p) for p in ("", "merged", "merged:48h", "keep", "done:2h", "junk")],
                         ["", "", "172800", "keep", "other", ""])
        r = subprocess.run(["python3", str(BIN / "fleet_reap_policy.py"), "norm", "nope"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)

    def test_restore_map_carries_policy_by_identity(self):
        fid = "12345678-1234-4123-8123-123456789abc"
        line = "keep|" + fid + "||acme/app|w|/nonexistent|7|done|-|-||-|claude|\n"
        out = subprocess.run(["python3", str(BIN / ".fleet-restore-resolve.py"), "", "--lead", "--sid", "--fid", "--reap"],
                             input=line, capture_output=True, text=True).stdout.splitlines()
        self.assertEqual(out[0], "REAP\t" + fid + "\tkeep")
        self.assertEqual(out[1], "FID\t" + fid)
        self.assertTrue(out[2].startswith("WIN\tw\t"))
        with tempfile.NamedTemporaryFile("w", suffix=".map", delete=False) as f:
            f.write("\n".join(out) + "\n")
        wins = subprocess.run(["bash", "-c", '. "$1/fleet-lib.sh"; fleet_restore_wins "$2"', "x", str(BIN), f.name],
                              capture_output=True, text=True).stdout
        os.unlink(f.name)
        self.assertTrue(wins.startswith("WIN:" + fid + "\tw\t"), wins)
        # no policy: no REAP row, the rows exactly as before
        out = subprocess.run(["python3", str(BIN / ".fleet-restore-resolve.py"), "", "--lead", "--sid", "--fid", "--reap"],
                             input="|" + line.split("|", 1)[1], capture_output=True, text=True).stdout.splitlines()
        self.assertEqual(out[0], "FID\t" + fid)


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class ReapPolicy(Rig):
    """Each reap policy (issue #1902): reaped once due, kept before it, kept while
    working, and its unpushed work stays on disk."""
    def due(self):
        self.clean()
        if self.tm("display-message", "-p", "-t", self.win, "#{@reap_due}").strip().isdigit():
            self.set("@reap_due", str(int(time.time()) - 1))
        return self.clean()

    def policy(self, p):
        out = self.call("bash", str(self.ibin / "fleet-reap-policy.sh"), "set", p, "--win", self.win,
                        "--session", self.label)
        self.assertIn("reap_policy=", out)

    def test_done_waits_its_own_idle_then_reaps_keeping_unpushed_work(self):
        self.policy("done:2h")
        self.assertEqual(self.call("bash", str(self.ibin / "fleet-reap-policy.sh"), "get", "--win", self.win,
                                   "--session", self.label).strip(), "done:2h")
        self.due()                                   # idle 4000 s < 2 h: not yet
        self.assertTrue(self.exists())
        self.assertGreater(int(self.tm("display-message", "-p", "-t", self.win, "#{@reap_due}")), int(time.time()) + 3000)
        self.set("@claude_state", "working")
        self.set("@claude_state_ts", str(int(time.time()) - 9000))
        self.due()
        self.assertTrue(self.exists())               # working: never
        self.set("@claude_state", "done")
        self.call("git", "-C", str(self.wt), "-c", "user.name=T", "-c", "user.email=t@example.invalid",
                  "commit", "-qm", "unpushed", "--allow-empty")
        out = self.due()
        self.assertIn("reaped-idle:" + self.win + " policy=done:2h", out)
        self.assertFalse(self.exists())
        self.assertTrue(self.wt.is_dir())            # the worktree and its branch stay
        self.assertIn("unpushed", self.call("git", "-C", str(self.main), "log", "-1", "--format=%s", "scratch-7"))
        self.assertIn("reap policy done:2h", (self.root / "ledger.tsv").read_text())

    def test_keep_and_merged_are_never_this_pass(self):
        for p in ("keep", "merged", "merged:48h"):
            self.policy(p)
            self.set("@claude_state_ts", str(int(time.time()) - 900000))
            self.due()
            self.assertTrue(self.exists(), p)

    def test_at_only_once_the_time_has_come_and_never_while_working(self):
        self.policy("at:" + str(int(time.time()) + 3600))
        self.due()
        self.assertTrue(self.exists())
        self.policy("at:" + str(int(time.time()) - 60))
        self.set("@claude_state", "working")
        self.due()
        self.assertTrue(self.exists())
        self.set("@claude_state", "done")
        self.assertIn("reaped-idle:", self.due())
        self.assertFalse(self.exists())

    def test_loop_end_waits_for_the_loop(self):
        self.policy("loop-end")
        self.set("@loop", "kind=wakeup next=%d ttl=600" % (int(time.time()) + 600))
        self.due()
        self.assertTrue(self.exists())               # a round still pending
        self.set("@loop", "kind=wakeup next=%d ttl=600" % (int(time.time()) - 4000))
        self.assertIn("reaped-idle:", self.due())

    def test_sleep_on_considers_only_windows_with_a_policy(self):
        conf = self.root / "conf" / (self.label + ".conf")
        conf.write_text(conf.read_text() + "FLEET_SLEEP=on\n")
        self.set("@claude_state_ts", str(int(time.time()) - 9000))
        self.due()
        self.assertTrue(self.exists())               # no policy, sleep on: the old rule, not closed
        self.policy("done:2h")
        self.assertIn("reaped-idle:", self.due())


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class TestIdentity(Rig):
    """A no-repo session the TEST identity placed (issue #2505, @test_identity):
    its own policy closes it — done:10m counted from its last turn, or its birth
    when it never took one — while any other no-repo session stays (#791)."""
    def norepo(self, test, **opts):
        win = self.tm("new-window", "-d", "-P", "-F", "#{window_id}", "-t", self.label,
                      "-c", str(self.root), "sleep 90").strip()
        fid = "%08x-0000-4000-8000-000000000000" % int(win[1:])
        for key, value in dict({"@norepo": "1", "@fleet_id": fid, "@reap_policy": "done:10m",
                                "@born": str(int(time.time()) - 1200)}, **opts).items():
            self.tm("set-option", "-w", "-t", win, key, value)
        if test:
            self.tm("set-option", "-w", "-t", win, "@test_identity", "1")
        return win

    def alive(self, win):
        return win in self.tm("list-windows", "-t", self.label, "-F", "#{window_id}").split()

    def test_closes_a_test_session_past_its_policy_and_nothing_else(self):
        old = self.norepo(True)                                   # never took a turn, born 20 min ago
        young = self.norepo(True, **{"@born": str(int(time.time()) - 60)})
        busy = self.norepo(True, **{"@claude_state": "working",
                                    "@claude_state_ts": str(int(time.time()) - 4000)})
        mine = self.norepo(False)                                 # the person's own no-repo session
        out = self.clean()
        self.assertIn("reaped-test:" + old + " policy=done:10m", out)
        self.assertFalse(self.alive(old))
        self.assertTrue(self.alive(young))                        # its 10 minutes are not up
        self.assertTrue(self.alive(busy))                         # working: never
        self.assertTrue(self.alive(mine))                         # not a test's: #791 holds
        self.tm("set-option", "-w", "-t", busy, "@claude_state", "done")
        self.assertIn("reaped-test:" + busy, self.clean())        # done 4000 s ago
        self.assertFalse(self.alive(busy))


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class HomeReap(ReapPolicy):
    """A no-repo (home) session (issue #2565): `done:2h` closes it two hours after
    its agent EXITED — never on a finished turn (#2564 resumes that one), never
    without a policy (#791), never pinned."""
    def setUp(self):
        super().setUp()
        for key in ("@raw", "@worktree"):
            self.tm("set-option", "-wu", "-t", self.win, key)
        self.set("@norepo", "1")
        self.set("@fleet_id", "%08x-0000-4000-8000-000000000000" % int(self.win[1:]))

    def test_exited_two_hours_closes_an_idle_turn_never(self):
        self.policy("done:2h")
        self.set("@claude_state_ts", str(int(time.time()) - 9000))
        self.due()
        self.assertTrue(self.exists())               # done for hours: still the current session
        self.set("@claude_state", "exited")
        self.set("@claude_state_ts", str(int(time.time()) - 4000))
        self.due()
        self.assertTrue(self.exists())               # exited 4000 s < 2 h: not yet
        self.set("@claude_state_ts", str(int(time.time()) - 9000))
        out = self.due()
        self.assertIn("reaped-idle:" + self.win + " policy=done:2h norepo", out)
        self.assertFalse(self.exists())

    def test_no_policy_or_pinned_or_keep_is_never_closed(self):
        self.set("@claude_state", "exited")
        self.set("@claude_state_ts", str(int(time.time()) - 900000))
        self.due()
        self.assertTrue(self.exists())               # no policy: #791, as before
        self.policy("keep")
        self.due()
        self.assertTrue(self.exists())
        self.policy("done:2h")
        self.set("@pin", "1")
        self.due()
        self.assertTrue(self.exists())

    # the inherited worktree-session cases do not apply to a home session
    test_done_waits_its_own_idle_then_reaps_keeping_unpushed_work = None
    test_keep_and_merged_are_never_this_pass = None
    test_at_only_once_the_time_has_come_and_never_while_working = None
    test_loop_end_waits_for_the_loop = None
    test_sleep_on_considers_only_windows_with_a_policy = None


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class DoneNoPr(Rig):
    """A finished session no PR will ever close (issue #1832): closed two hours
    after its last turn, its worktree dropped only when clean with nothing of its
    own, and every refusal said as a token."""
    def setUp(self):
        super().setUp()
        self.set("@raw", "")                         # a spawned scratch, no policy
        (self.root / "issue.json").write_text('{"state":"CLOSED"}')
        (self.root / "fake/gh").write_text(
            '#!/bin/sh\nif [ "$1" = issue ]; then cat ' + shlex.quote(str(self.root / "issue.json"))
            + '; else cat ' + shlex.quote(str(self.root / "prs.json")) + '; fi\n')

    def ago(self, secs):
        self.set("@claude_state_ts", str(int(time.time()) - secs))

    def due(self):
        out = self.clean()
        if self.tm("display-message", "-p", "-t", self.win, "#{@reap_due}").strip().isdigit():
            self.set("@reap_due", str(int(time.time()) - 1))
            out += self.clean()
        return out

    def listed(self):
        return str(self.wt) in self.call("git", "-C", str(self.main), "worktree", "list")

    def test_recent_is_kept_and_said_once(self):
        self.ago(3600)
        out = self.clean()
        self.assertIn("skip:done-recent " + self.win + " scratch-7", out)
        self.assertEqual(self.clean(), "")           # the same skip is not repeated
        self.assertTrue(self.exists())

    def test_two_hours_clean_closes_and_drops_the_worktree(self):
        self.ago(7300)
        self.assertIn("would-clean:done-no-pr " + self.win, self.clean("--dry-run"))
        self.assertTrue(self.exists())
        out = self.due()
        self.assertIn("cleaned:done-no-pr " + self.win + " scratch-7 worktree=trashed", out)
        self.assertFalse(self.exists())
        self.assertFalse(self.listed())
        self.assertIn("scratch-7", self.call("git", "-C", str(self.main), "branch", "--list", "scratch-7"))
        self.assertIn(self.sid, (self.root / "ledger.tsv").read_text())   # recorded first

    def test_dirty_or_unpushed_only_closes_the_window(self):
        self.ago(7300)
        (self.wt / "dirty").write_text("keep")
        self.assertIn("worktree=kept:dirty", self.due())
        self.assertFalse(self.exists())
        self.assertTrue((self.wt / "dirty").is_file())
        self.assertTrue(self.listed())

    def test_unpushed_commit_keeps_the_worktree(self):
        self.ago(7300)
        self.call("git", "-C", str(self.wt), "-c", "user.name=T", "-c", "user.email=t@example.invalid",
                  "commit", "-qm", "unpushed", "--allow-empty")
        self.assertIn("worktree=kept:unpushed", self.due())
        self.assertFalse(self.exists())
        self.assertTrue(self.listed())

    def test_working_pr_open_issue_and_keep_are_kept(self):
        self.ago(9000)
        self.set("@claude_state", "working")
        self.assertEqual(self.due(), "")
        self.assertTrue(self.exists())
        self.set("@claude_state", "done")
        (self.root / "prs.json").write_text('[{"state":"OPEN"}]')
        self.assertIn("skip:has-pr " + self.win, self.due())
        self.assertTrue(self.exists())
        (self.root / "prs.json").write_text("[]")
        self.set("@issue", "12")
        (self.root / "issue.json").write_text('{"state":"OPEN"}')
        self.assertIn("skip:issue-open " + self.win + " scratch-7 #12", self.due())
        self.assertTrue(self.exists())
        for p in ("keep", "merged"):
            self.set("@issue", "" if p == "merged" else "12")
            self.set("@reap_policy", p)
            self.due()
            self.assertTrue(self.exists(), p)        # keep never; merged on a scratch is a PR's

    def test_closed_issue_with_merged_policy_and_no_worktree(self):
        # #2446: an issue session, policy merged, its issue closed with no PR — and
        # here its worktree already gone (#2417 on this machine): the window closes.
        self.ago(9000)
        self.set("@issue", "12")
        self.set("@reap_policy", "merged")
        self.call("git", "-C", str(self.main), "worktree", "remove", "--force", str(self.wt))
        out = self.due()
        self.assertIn("cleaned:done-no-pr " + self.win + " scratch-7 worktree=gone", out)
        self.assertFalse(self.exists())
        self.assertIn("finished with no PR", (self.root / "ledger.tsv").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
