#!/usr/bin/env python3
# selftest-entry
"""A task's completion notice, both machine halves (task T9AQ).

The worker's half: fleet_task_notify.py (run by set-claude-state.sh on done /
needs) writes ONE `turn` event per reply onto the window's ID ledger — the Stop
hook and the agent's own report saying the same turn are one event, a window
with no @task writes nothing. The dispatcher's half: fleet-hub-node.sh deliver
hands a `task_notice` relay to the dispatching window by its identity (after a
/clear too — same @fleet_id), or, with no live window, puts it in 「✦ 消息」
once and settles it delivered (never held for a window that may not return).

The hub's half (one relay per state, note / pr on the record) is
tokenledger/hub/store/fleet_task_notice_test.go. Isolated tmux socket, sandbox
conf dir, fake Claude inbox (fleet-agent-deliver-selftest.py's Rig); no hub.
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
import uuid

BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("delivery_fixture", BIN / "fleet-agent-deliver-selftest.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


@unittest.skipUnless(fixture.TMUX, "tmux unavailable")
class TaskNotice(unittest.TestCase):
    def setUp(self):
        # every test here shares the Rig's label (agent + pid): the last test's
        # server may still be going down — wait it out, once more if it was not
        import os, time
        label = "fadcl%d" % os.getpid()
        for attempt in range(3):
            for _ in range(50):
                if subprocess.run([fixture.TMUX, "-L", label, "has-session"], capture_output=True).returncode != 0:
                    break
                subprocess.run([fixture.TMUX, "-L", label, "kill-server"], capture_output=True)
                time.sleep(0.1)
            try:
                self.r = fixture.Rig(self, "claude")
                break
            except subprocess.CalledProcessError:
                if attempt == 2:
                    raise
                time.sleep(1)
        self.addCleanup(self.r.close)
        self.r.env.update(FLEET_SKIP_GLOBAL_CONF="1", CCQUOTA_FLEET="1")
        self.fid = str(uuid.uuid4())
        self.r.opt("@fleet_id", self.fid)
        self.r.opt("@norepo", "1")
        self.run_cmd("python3", "-c", "import fleet_control,sys; fleet_control.Control(sys.argv[1]).inventory()", str(self.r.conf))
        p = self.run_cmd("bash", "-c", '. "$1/fleet-lib.sh"; fleet_uuid "$2"', "-", str(BIN), self.r.label)
        self.fleet = p.stdout.strip()
        self.local = self.fleet + "/" + self.fid
        self.task_fid = str(uuid.uuid4())

    def run_cmd(self, *argv, input=None, check=True, env=None):
        p = subprocess.run(argv, input=input, text=True, capture_output=True,
                           env=env or self.r.env, cwd=BIN, timeout=30)
        if check:
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return p

    def deliver(self, relay):
        return self.run_cmd("bash", str(BIN / "fleet-hub-node.sh"), "deliver",
                            input=json.dumps(relay), check=False)

    def notice(self, to, state="done", suffix="m1"):
        frm = self.fleet + "/" + self.task_fid
        text = "[任务通知] N4BN 完成 · 调研\n结论：报告在 ~/.claude/handoff/x-report.md\n全文：fleet-task-record.sh get N4BN"
        return dict(id=frm + "#tn-" + state + "-" + suffix, kind="message", **{"from": frm}, to=to,
                    from_node="mac-b", payload=dict(text=text, task_notice=dict(task="N4BN", fid=self.task_fid,
                                                                                 state=state, title="调研")))

    def notices(self):
        f = self.r.conf / "logs" / "notices.ndjson"
        return [json.loads(l) for l in f.read_text().splitlines() if l.strip()] if f.exists() else []

    # --- the dispatcher's machine ---------------------------------------------------

    def test_live_dispatcher_gets_the_notice_once(self):
        p = self.deliver(self.notice(self.local))
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertTrue(self.r.landed("[任务通知] N4BN 完成"))
        self.assertNotIn("[from ", self.r.inbox.got[-1])   # the notice names itself
        p = self.deliver(self.notice(self.local))           # a late / repeated push
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(len(self.r.inbox.got), 1)

    def test_cleared_dispatcher_same_identity_still_gets_it(self):
        # /clear: a new native conversation in the same window — same @fleet_id
        self.r.opt("@cc_session_id", str(uuid.uuid4()))
        self.r.tm("rename-window", "-t", self.r.win, "after-clear")
        p = self.deliver(self.notice(self.local, suffix="clr"))
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertTrue(self.r.landed("[任务通知] N4BN"))

    def test_gone_dispatcher_goes_to_messages_once(self):
        gone = self.fleet + "/" + str(uuid.uuid4())   # its window was closed
        for _ in range(2):                              # a resend after a lost ack
            p = self.deliver(self.notice(gone, state="waiting", suffix="w1"))
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertIn("kept in ✦ 消息", p.stderr)
        rows = [r for r in self.notices() if r.get("source") == "task-notice"]
        self.assertEqual(len(rows), 1, rows)
        self.assertEqual((rows[0]["kind"], rows[0]["sub"], rows[0]["next"]), ("session", "ask", "fleet-task-record.sh get N4BN"))
        self.assertIn("N4BN", rows[0]["text"])
        self.assertEqual(self.r.inbox.got, [])
        # an ordinary message to a missing window still waits (75), unchanged
        plain = self.notice(gone, suffix="plain")
        plain["payload"].pop("task_notice")
        p = self.deliver(plain)
        self.assertEqual(p.returncode, 75, p.stdout + p.stderr)

    def test_bad_task_notice_is_refused(self):
        bad = self.notice(self.local, suffix="bad")
        bad["payload"]["task_notice"]["state"] = "maybe"
        p = self.deliver(bad)
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertEqual(self.r.inbox.got, [])

    # --- the worker's machine -------------------------------------------------------

    def ledger(self):
        f = self.r.root / "ids" / (self.fid + ".ndjson")
        return [json.loads(l) for l in f.read_text().splitlines()] if f.exists() else []

    def turn(self, state, transcript=""):
        env = dict(self.r.env, TMUX=str(self.r.root) + "/x,1,0")
        sock = self.r.tm("display-message", "-p", "#{socket_path}")
        env["TMUX"] = sock + ",1,0"
        return self.run_cmd("python3", str(BIN / "fleet_task_notify.py"), "turn", "--pane", self.r.pane,
                            "--state", state, "--transcript", transcript, env=env)

    def transcript(self, *replies):
        f = self.r.root / "t.jsonl"
        with open(f, "w") as fh:
            fh.write(json.dumps({"type": "user", "message": {"content": "go"}}) + "\n")
            for uid, text in replies:
                fh.write(json.dumps({"type": "assistant", "uuid": uid,
                                     "message": {"content": [{"type": "text", "text": text}]}}, ensure_ascii=False) + "\n")
        return str(f)

    def test_turn_writes_one_event_per_reply(self):
        # the agent's startup idle (OSC 7501 → done) before any reply: nothing
        self.r.opt("@task", "T1481")
        self.turn("done", self.transcript())
        self.assertEqual(self.ledger(), [], "a done with no reply wrote a turn")
        self.r.tm("set-option", "-w", "-u", "-t", self.r.win, "@task")
        tp = self.transcript(("u1", "做完了。PR https://github.com/o/r/pull/12 · 报告 ~/.claude/handoff/x-report.md"))
        self.turn("done", tp)
        self.assertEqual(self.ledger(), [], "a window with no @task wrote a turn")
        self.r.opt("@task", "T1481")
        self.turn("done", tp)
        self.turn("done", tp)          # the same turn said twice (hook + OSC 7501)
        evs = [e for e in self.ledger() if e.get("ev") == "turn"]
        self.assertEqual(len(evs), 1, evs)
        e = evs[0]
        self.assertEqual((e["state"], e["pr"]), ("done", "o/r#12"))
        self.assertTrue(e["summary"].startswith("做完了"))
        self.assertIn("~/.claude/handoff/x-report.md", e["artifacts"])
        # a question opens: one waiting event; a new reply later: one more done
        self.r.opt("@claude_needs_detail", "要不要合并？")
        self.turn("needs", tp)
        tp = self.transcript(("u1", "做完了"), ("u2", "已合并"))
        self.turn("done", tp)
        evs = [(e["state"], e["summary"][:6]) for e in self.ledger() if e.get("ev") == "turn"]
        self.assertEqual(evs, [("done", "做完了。PR"), ("waiting", "要不要合并？"), ("done", "已合并")])

    def test_stop_hook_writes_the_turn(self):
        # set-claude-state.sh's Stop leg (done) starts the writer in the background
        import time
        self.r.opt("@task", "T1481")
        tp = self.transcript(("u9", "全部完成"))
        sock = self.r.tm("display-message", "-p", "#{socket_path}")
        env = dict(self.r.env, TMUX=sock + ",1,0", TMUX_PANE=self.r.pane, CLAUDE_CODE_ENTRYPOINT="cli", CCQUOTA_FLEET="0")
        p = subprocess.run(["sh", str(BIN / "set-claude-state.sh"), "done"], env=env, cwd=BIN, timeout=60,
                           input=json.dumps({"hook_event_name": "Stop", "transcript_path": tp}),
                           text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        for _ in range(600):
            evs = [e for e in self.ledger() if e.get("ev") == "turn"]
            if evs:
                break
            time.sleep(0.1)
        self.assertEqual([(e["state"], e["summary"]) for e in evs], [("done", "全部完成")],
                         "state=%s err=%s" % (self.r.tm("display-message", "-p", "-t", self.r.pane, "#{@claude_state}"), p.stderr[-500:]))

    def test_reeval_done_writes_the_turn(self):
        # a Stop that wrote `looping` on a stale wait (a background job's last word
        # still settling); the re-ask that turns it `done` writes the turn (fleet-lib.sh)
        import time
        self.r.opt("@task", "T1481")
        self.r.opt("@claude_state", "looping")
        self.r.opt("@claude_wait", "tool")
        home = self.r.root / "home"
        proj = home / ".claude" / "projects" / "x"
        proj.mkdir(parents=True)
        sid = self.r.tm("display-message", "-p", "-t", self.r.win, "#{@cc_session_id}")
        (proj / (sid + ".jsonl")).write_text(json.dumps({"type": "assistant", "uuid": "u7",
            "message": {"content": [{"type": "text", "text": "后台跑完了，全部完成"}]}}, ensure_ascii=False) + "\n")
        env = dict(self.r.env, HOME=str(home))
        p = self.run_cmd("bash", "-c", '. "$1/fleet-lib.sh"; fleet_window_reeval "$2" "$3"', "-", str(BIN),
                         self.r.label, self.r.win, env=env)
        self.assertIn("-> done", p.stdout)
        for _ in range(600):
            evs = [e for e in self.ledger() if e.get("ev") == "turn"]
            if evs:
                break
            time.sleep(0.1)
        self.assertEqual([(e["state"], e["summary"]) for e in evs], [("done", "后台跑完了，全部完成")])

    def test_settle_after_a_stale_looping_stop(self):
        # the Stop wrote `looping` on a wait that clears a moment later: settle
        # re-asks it, the re-ask writes `done`, its hook writes the turn
        import time
        self.r.opt("@task", "T1481")
        self.r.opt("@claude_state", "looping")
        self.r.opt("@claude_wait", "tool")
        home = self.r.root / "home"
        proj = home / ".claude" / "projects" / "y"
        proj.mkdir(parents=True)
        sid = self.r.tm("display-message", "-p", "-t", self.r.win, "#{@cc_session_id}")
        (proj / (sid + ".jsonl")).write_text(json.dumps({"type": "assistant", "uuid": "u8",
            "message": {"content": [{"type": "text", "text": "等的任务跑完了"}]}}, ensure_ascii=False) + "\n")
        sock = self.r.tm("display-message", "-p", "#{socket_path}")
        env = dict(self.r.env, HOME=str(home), TMUX=sock + ",1,0", FLEET_TASK_NOTIFY_SETTLE="30")
        self.run_cmd("python3", str(BIN / "fleet_task_notify.py"), "settle", "--pane", self.r.pane, env=env)
        for _ in range(600):
            evs = [e for e in self.ledger() if e.get("ev") == "turn"]
            if evs:
                break
            time.sleep(0.1)
        self.assertEqual([(e["state"], e["summary"]) for e in evs], [("done", "等的任务跑完了")])


if __name__ == "__main__":
    unittest.main()
