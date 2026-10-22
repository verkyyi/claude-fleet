#!/usr/bin/env python3
# selftest-entry
"""fleet-session-gate-selftest.py — bin/fleet_session_gate.py (task HHV0, 会话合一 ①).

The gate against a fake tmux (one JSON file of window options and clients), a
fake mod (FLEET_GATE_ACCEPT_CMD: the inbox answer a scripted engine gives) and a
fake Codex app-server (FLEET_GATE_CODEX). What the real engines do at the same
steps is bin/fleet-idle-accept-claude-selftest.py's (needs claude 2.1.295 on PATH).

  A  say into an idle Claude session: one post, sent, its turn named
  B  answering: queued (busy), the next tick sends it; two sentences = two turns, in order
  C  a draft in the box refuses at entry: queued (draft), sent once it is gone
  D  an unanswered post is settled by its receipt — never posted twice; the same delivery id again is the same answer
  E  an older mod (no idle.v2) is read-only: refused old_version, nothing posted
  F  a /clear (another conversation id) returns what waited: session_changed; queued too long: expired
  G  park-while-watched: a person looking at the window ⇒ never parked; idle and unwatched ⇒ @parked, the /exit asked
  H  wake-timeout: a parked session that does not come up in time ⇒ returned wake_timeout, its seed taken back (never a late turn)
  I  a parked session woken by a sentence: the seed claimed ⇒ sent, the words are the start's first turn
  J  Codex: idle ⇒ started (sent); answering ⇒ in its own queue (queued), the receipt scan sends it; never added twice
  K  stop: Claude working ⇒ one Escape; idle ⇒ no key; Codex ⇒ turn/interrupt
  L  status: can_talk + the queue (what waits, why) for the page's state line
  M  what it asks: an AskUserQuestion's card (fp · questions · options) answered by
     {question: label} through fleet-dialog-answer.sh; a permission's card answered
     allow / deny through fleet-permission.sh --by; a changed fp is refused

Run one case: fleet-session-gate-selftest.py G
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

BIN = Path(__file__).absolute().parent
GATE = BIN / "fleet_session_gate.py"
FID = "11111111-2222-4333-8444-555555555555"
SID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

FAKE_TMUX = r'''#!/usr/bin/env python3
import json, os, re, sys
st_path = os.environ["FAKE_TMUX_STATE"]
st = json.load(open(st_path))
a = sys.argv[1:]
if a[:1] == ["-L"]:
    a = a[2:]
def save():
    with open(st_path + ".tmp", "w") as f:
        json.dump(st, f)
    os.replace(st_path + ".tmp", st_path)
def opts(t):
    return st["windows"].setdefault(t if t in st["windows"] else "@1", {})
cmd = a[0]
if cmd == "display-message":
    t = a[a.index("-t") + 1]; fmt = a[-1]; w = opts(t)
    def sub(m):
        k = m.group(1)
        return str(w.get(k, ""))
    print(re.sub(r"#\{([^}]+)\}", sub, fmt))
elif cmd == "set-option":
    t = a[a.index("-t") + 1]; w = opts(t)
    rest = [x for x in a[1:] if not x.startswith("-") and x != t]
    if "-wu" in a or "-u" in a:
        w.pop(rest[0], None)
    else:
        w[rest[0]] = rest[1] if len(rest) > 1 else ""
    save()
elif cmd == "list-clients":
    for c in st.get("clients", []):
        print("%s\t%s" % (c.get("control", "0"), c["window"]))
elif cmd == "send-keys":
    st.setdefault("keys", []).append(a[a.index("-t") + 2:])
    save()
'''

# the engine: answers each idle.v2 request from a script of outcomes (FAKE_ACCEPT_PLAN)
FAKE_ACCEPT = r'''#!/usr/bin/env python3
import json, os, sys
req = json.load(sys.stdin)
plan_path = os.environ["FAKE_ACCEPT_PLAN"]
plan = json.load(open(plan_path))
step = plan.pop(0) if plan else {"state": "accepted"}
json.dump(plan, open(plan_path, "w"))
with open(os.environ["FAKE_ACCEPT_LOG"], "a") as f:
    f.write(json.dumps({"delivery": req["delivery_id"], "text": req["text"], "accept": req["accept"]}) + "\n")
if step.get("receipt"):
    # the mod wrote its receipt but the answer was lost (a disconnect)
    open(os.path.join(os.environ["FAKE_INBOX"], "idle-accept-%s.receipt" % req["delivery_id"]), "w").write(
        json.dumps({"state": "accepted", "delivery_id": req["delivery_id"], "turn_id": "t-r"}))
out = {"ok": True, "state": step["state"], "reason": step.get("reason", "native_entry"),
       "nonce": req["nonce"], "delivery_id": req["delivery_id"]}
if step["state"] == "accepted":
    out["turn_id"] = "t-%d" % (len(open(os.environ["FAKE_ACCEPT_LOG"]).read().splitlines()))
print(json.dumps(out))
'''

FAKE_CODEX = r'''
import json, os
STATE = os.environ["FAKE_CODEX_STATE"]
def _load():
    return json.load(open(STATE))
def _save(s):
    json.dump(s, open(STATE, "w"))
def identity(pane, socket=""):
    return {"session_id": "th-1", "remote": "unix:///tmp/x.sock", "home": "/h", "owner": "1"}
class C:
    initialized = {"userAgent": "codex_cli_rs/0.162.1 (Mac OS)"}
    def call(self, method, params):
        s = _load(); s.setdefault("calls", []).append(method)
        try:
            if method == "thread/queue/add":
                q = {"id": "q%d" % len(s.setdefault("queue", [])), "clientUserMessageId": params["clientUserMessageId"],
                     "text": params["input"][0]["text"]}
                s["queue"].append(q)
                return {"queuedSubmission": q}
            if method == "thread/queue/start":
                if s.get("busy"):
                    raise ValueError("thread already has an active or pending turn")
                q = next(x for x in s["queue"] if x["id"] == params["queuedSubmissionId"])
                s["queue"].remove(q)
                s.setdefault("turns", []).insert(0, {"id": "turn-%d" % len(s["turns"]), "status": "inProgress",
                                                    "items": [{"type": "userMessage", "clientId": q["clientUserMessageId"]}]})
                return {"turn": {"id": s["turns"][0]["id"]}}
            if method == "thread/queue/list":
                return {"data": list(s.get("queue", []))}
            if method == "thread/turns/list":
                return {"data": list(s.get("turns", []))[: params.get("limit", 50)]}
            if method == "turn/interrupt":
                s["interrupted"] = params["turnId"]
                return {}
            raise ValueError("unknown " + method)
        finally:
            _save(s)
    def close(self):
        pass
def client(remote):
    return C()
'''


class Gate(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp(prefix="gate-"))
        (self.d / "conf/logs").mkdir(parents=True)
        self.inbox = self.d / "conf/global/mod-inbox/fleet-a/7"
        self.inbox.mkdir(parents=True)
        for name, body in (("tmux", FAKE_TMUX), ("accept", FAKE_ACCEPT)):
            p = self.d / name
            p.write_text(body)
            p.chmod(0o755)
        (self.d / "codex.py").write_text(FAKE_CODEX)
        (self.d / "win").write_text("#!/bin/sh\nprintf 'fleet-a\\t@1\\n'\n")
        (self.d / "win").chmod(0o755)
        proof = self.d / "park-proof"
        proof.write_text('#!/bin/sh\necho \'{"ok":true}\'\n')
        proof.chmod(0o755)
        self.window({})
        self.plan([])
        (self.d / "accept.log").write_text("")
        json.dump({}, open(self.d / "codex.json", "w"))
        self.addCleanup(shutil.rmtree, self.d, True)

    def window(self, extra, clients=()):
        w = {"pane_id": "%7", "@cc_agent": "claude", "@mod_accept": "idle.v2", "@claude_state": "done",
             "@cc_session_id": SID, "@park_wrap_ver": "1", "socket_path": "/private/tmp/tmux-501/fleet-a"}
        w.update(extra)
        st = {"windows": {"@1": w}, "clients": list(clients)}
        json.dump(st, open(self.d / "tmux.json", "w"))

    def opt(self, name):
        return json.load(open(self.d / "tmux.json"))["windows"]["@1"].get(name)

    def setopt(self, **kv):
        st = json.load(open(self.d / "tmux.json"))
        for k, v in kv.items():
            if v is None:
                st["windows"]["@1"].pop(k, None)
            else:
                st["windows"]["@1"][k] = v
        json.dump(st, open(self.d / "tmux.json", "w"))

    def plan(self, steps):
        json.dump(steps, open(self.d / "plan.json", "w"))

    def posts(self):
        return [json.loads(x) for x in (self.d / "accept.log").read_text().splitlines()]

    def gate(self, *args, text=None, env=None):
        e = dict(os.environ, FLEET_CONF_DIR=str(self.d / "conf"), FLEET_GATE_TMUX=str(self.d / "tmux"),
                 FAKE_TMUX_STATE=str(self.d / "tmux.json"), FLEET_GATE_WIN_CMD=str(self.d / "win"),
                 FLEET_GATE_ACCEPT_CMD=str(self.d / "accept"), FAKE_ACCEPT_PLAN=str(self.d / "plan.json"),
                 FAKE_ACCEPT_LOG=str(self.d / "accept.log"), FAKE_INBOX=str(self.inbox),
                 FLEET_GATE_CODEX=str(self.d / "codex.py"), FAKE_CODEX_STATE=str(self.d / "codex.json"),
                 FLEET_CC_PROJECTS_DIR=str(self.d / "projects"), FLEET_GATE_WAKE_WAIT="0.3",
                 FLEET_GATE_PARK_SECS="2", FLEET_GATE_EXIT_CMD="false",
                 FLEET_GATE_BG_CMD="false", FLEET_GATE_PARK_PROBE_CMD=str(self.d / "park-proof"))
        e.update(env or {})
        p = subprocess.run([sys.executable, str(GATE), *args], input=text or "", capture_output=True, text=True,
                           env=e, timeout=60)
        try:
            return json.loads(p.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            self.fail("gate %s: rc %d out %r err %r" % (args, p.returncode, p.stdout, p.stderr[-800:]))

    def say(self, text, **kw):
        return self.gate("say", "--fid", FID, text=text, **kw)

    def test_A_idle_claude(self):
        r = self.say("hello")
        self.assertEqual(r["state"], "sent")
        self.assertEqual([p["text"] for p in self.posts()], ["hello"])
        self.assertEqual(self.posts()[0]["accept"], "idle.v2")

    def test_B_busy_queues_then_in_order(self):
        self.setopt(**{"@claude_state": "working"})
        a, b = self.say("one"), self.say("two")
        self.assertEqual([a["state"], b["state"]], ["queued", "queued"])
        self.assertEqual(a["reason"], "busy")
        self.assertEqual(self.posts(), [])
        self.setopt(**{"@claude_state": "done"})
        self.gate("tick", "--fid", FID)
        self.gate("tick", "--fid", FID)
        self.assertEqual([p["text"] for p in self.posts()], ["one", "two"])

    def test_C_draft_refuses(self):
        self.plan([{"state": "rejected", "reason": "draft_present"}])
        r = self.say("later")
        self.assertEqual([r["state"], r["reason"]], ["queued", "typing"])
        self.gate("tick", "--fid", FID)
        self.assertEqual([p["text"] for p in self.posts()], ["later", "later"])
        st = self.gate("status", "--fid", FID)
        self.assertEqual(st["queue"], [])

    def test_D_unanswered_settled_by_receipt(self):
        self.plan([{"state": "unknown", "reason": "entry_unanswered", "receipt": True}])
        r = self.say("once")
        self.assertEqual(r["state"], "queued")
        st = self.gate("status", "--fid", FID, env={"FLEET_GATE_NOW": str(time.time() + 60)})
        self.assertEqual(st["queue"], [])
        self.assertEqual(len(self.posts()), 1, "never posted twice")
        d = r["delivery"]
        again = self.gate("say", "--fid", FID, "--delivery", d, text="once")
        self.assertEqual(again["state"], "sent")
        self.assertEqual(len(self.posts()), 1)

    def test_E_old_mod_read_only(self):
        self.setopt(**{"@mod_accept": "idle.v1"})
        r = self.say("x")
        self.assertEqual([r["state"], r["reason"]], ["refused", "old_version"])
        self.assertEqual(self.posts(), [])
        self.assertFalse(self.gate("status", "--fid", FID)["can_talk"])

    def test_F_session_changed_and_expired(self):
        self.setopt(**{"@claude_state": "working"})
        r = self.say("for the old one")
        self.setopt(**{"@cc_session_id": "ffffffff-bbbb-4ccc-8ddd-eeeeeeeeeeee", "@claude_state": "done"})
        st = self.gate("status", "--fid", FID)
        self.assertEqual([(q["delivery"], q["why"]) for q in st["queue"]], [(r["delivery"], "session_changed")])
        self.setopt(**{"@claude_state": "working"})
        r2 = self.say("too long")
        st = self.gate("status", "--fid", FID, env={"FLEET_GATE_NOW": str(time.time() + 1900)})
        self.assertIn((r2["delivery"], "expired"), [(q["delivery"], q["why"]) for q in st["queue"]])
        self.assertEqual(self.posts(), [])

    def test_G_park_while_watched(self):
        self.window({}, clients=[{"window": "@1"}])
        r = self.gate("park", "--fid", FID)
        self.assertEqual([r["ok"], r["why"]], [False, "watched"])
        self.assertIsNone(self.opt("@parked"))
        # a control-mode client (the hub's own) is nobody looking
        self.window({}, clients=[{"window": "@1", "control": "1"}])
        # the wrapper says it holds it: simulate by stamping @park_held as /exit lands
        env = {"FLEET_GATE_PARK_SECS": "1", "FLEET_GATE_EXIT_CMD": "true"}
        self.setopt(**{"@park_held": "1"})
        r = self.gate("park", "--fid", FID, env=env)
        self.assertTrue(r["ok"], r)
        self.assertTrue(self.opt("@parked"))
        # answering or asking: never parked
        self.window({"@claude_state": "needs"})
        self.assertEqual(self.gate("park", "--fid", FID)["why"], "asking")

    def test_N_old_wrapper_never_receives_exit(self):
        # C1 drives fleet_session_gate.py: an old wrapper has no holding page.
        self.setopt(**{"@park_wrap_ver": None})
        r = self.gate("park", "--fid", FID)
        self.assertEqual(r.get("why"), "old_wrapper", r)
        self.assertIsNone(self.opt("@parked"))
        self.assertFalse(json.load(open(self.d / "tmux.json")).get("keys"))

    def test_H_wake_timeout(self):
        self.window({"@parked": "1", "@claude_state": "done"})
        r = self.say("are you there", env={"FLEET_GATE_WAKE_SECS": "1"})
        self.assertEqual(r["state"], "queued")
        seed = self.d / "conf/session-gate" / FID / ("wake-%s.txt" % r["delivery"])
        self.assertTrue(seed.exists())
        self.assertIsNone(self.opt("@park_state"))
        time.sleep(1.2)
        st = self.gate("status", "--fid", FID, env={"FLEET_GATE_WAKE_SECS": "1"})
        self.assertEqual([(q["delivery"], q["why"]) for q in st["queue"]], [(r["delivery"], "wake_timeout")])
        self.assertFalse(seed.exists(), "the seed is taken back: a late start never carries it")
        self.assertIsNone(self.opt("@park_wake"))
        self.assertIsNone(self.opt("@park_state"))
        self.assertTrue(self.opt("@parked"))

    def test_I_wake_carries_first_turn(self):
        self.window({"@parked": "1"})
        # the wrapper: claims the seed as soon as @park_wake names it
        claimer = subprocess.Popen([sys.executable, "-c", r'''
import json, os, sys, time
p = sys.argv[1]
end = time.time() + 10
while time.time() < end:
    w = json.load(open(p))["windows"]["@1"].get("@park_wake")
    if w and os.path.exists(w):
        os.rename(w, w + ".taken"); open(w + ".launched", "w").write(open(w + ".taken").read()); break
    time.sleep(.05)
''', str(self.d / "tmux.json")])
        r = self.say("first words", env={"FLEET_GATE_WAKE_WAIT": "5"})
        claimer.wait(timeout=15)
        self.assertEqual(r["state"], "sent")
        launched = list((self.d / "conf/session-gate" / FID).glob("wake-*.launched"))
        self.assertEqual([p.read_text() for p in launched], ["first words"])
        self.assertEqual(self.posts(), [], "a wake is not an inbox round")

    def test_J_codex(self):
        self.window({"@cc_agent": "codex", "@codex_session_id": "th-1"})
        r = self.say("go")
        self.assertEqual(r["state"], "sent")
        s = json.load(open(self.d / "codex.json"))
        s["busy"] = True
        json.dump(s, open(self.d / "codex.json", "w"))
        self.setopt(**{"@claude_state": "working"})
        r2 = self.say("next")
        self.assertEqual([r2["state"], r2["reason"]], ["queued", "busy"])
        s = json.load(open(self.d / "codex.json"))
        self.assertEqual(len(s["queue"]), 1, "waits in Codex's own queue")
        # Codex dispatched it itself when the turn ended
        q = s["queue"].pop()
        s["turns"].insert(0, {"id": "turn-x", "status": "completed",
                              "items": [{"type": "userMessage", "clientId": q["clientUserMessageId"]}]})
        s["busy"] = False
        json.dump(s, open(self.d / "codex.json", "w"))
        self.gate("tick", "--fid", FID)
        st = self.gate("status", "--fid", FID)
        self.assertEqual(st["queue"], [])
        adds = [c for c in json.load(open(self.d / "codex.json"))["calls"] if c == "thread/queue/add"]
        self.assertEqual(len(adds), 2, "never added twice")

    def missing_codex_submission(self):
        self.window({"@cc_agent": "codex", "@codex_session_id": "th-1"})
        (self.d / "codex.json").write_text(json.dumps({"busy": True}))
        delivery = self.say("native client starts this once")["delivery"]
        state = json.loads((self.d / "codex.json").read_text())
        queued = state["queue"].pop()
        state["busy"] = False
        (self.d / "codex.json").write_text(json.dumps(state))
        return delivery, queued

    def test_O_codex_delayed_receipt_never_returns_or_readds(self):
        delivery, _ = self.missing_codex_submission()
        clock = time.time() + 1
        for seconds in (0, 8):
            status = self.gate("status", "--fid", FID, env={"FLEET_GATE_NOW": str(clock + seconds)})
            self.assertEqual([(q["delivery"], q["state"]) for q in status["queue"]], [(delivery, "native")])
        state = json.loads((self.d / "codex.json").read_text())
        state["turns"] = [{"id": "native-turn", "status": "completed",
                           "items": [{"type": "userMessage", "clientId": delivery}]}]
        (self.d / "codex.json").write_text(json.dumps(state))
        status = self.gate("status", "--fid", FID, env={"FLEET_GATE_NOW": str(clock + 9)})
        self.assertEqual(status["queue"], [])
        again = self.gate("say", "--fid", FID, "--delivery", delivery, text="native client starts this once")
        self.assertEqual(again["state"], "sent")
        calls = json.loads((self.d / "codex.json").read_text())["calls"]
        self.assertEqual(calls.count("thread/queue/add"), 1, "uncertain delivery is never re-added")

    def test_P_codex_missing_receipt_is_bounded_and_queue_resets_grace(self):
        delivery, queued = self.missing_codex_submission()
        clock = time.time() + 1
        status = self.gate("status", "--fid", FID, env={"FLEET_GATE_NOW": str(clock)})
        self.assertEqual(status["queue"][0]["state"], "native")
        state = json.loads((self.d / "codex.json").read_text())
        state.update(queue=[queued], busy=True)
        (self.d / "codex.json").write_text(json.dumps(state))
        self.gate("status", "--fid", FID, env={"FLEET_GATE_NOW": str(clock + 10)})
        state = json.loads((self.d / "codex.json").read_text())
        state.update(queue=[], busy=False)
        (self.d / "codex.json").write_text(json.dumps(state))
        status = self.gate("status", "--fid", FID, env={"FLEET_GATE_NOW": str(clock + 30)})
        self.assertEqual(status["queue"][0]["state"], "native", "a visible queue resets the absence clock")
        status = self.gate("status", "--fid", FID, env={"FLEET_GATE_NOW": str(clock + 51)})
        self.assertEqual([(q["delivery"], q["why"]) for q in status["queue"]], [(delivery, "dropped")])
        calls = json.loads((self.d / "codex.json").read_text())["calls"]
        self.assertEqual(calls.count("thread/queue/add"), 1)

    def test_K_stop(self):
        self.window({"@claude_state": "working", "@agent_status": '{"state":"working"}'})
        self.assertEqual(self.gate("stop", "--fid", FID)["how"], "escape")
        self.assertEqual(json.load(open(self.d / "tmux.json")).get("keys"), [["Escape"]])
        self.window({"@claude_state": "done"})
        self.assertEqual(self.gate("stop", "--fid", FID)["how"], "idle")
        self.assertIsNone(json.load(open(self.d / "tmux.json")).get("keys"))
        self.window({"@cc_agent": "codex", "@claude_state": "working"})
        json.dump({"turns": [{"id": "turn-9", "status": "inProgress"}]}, open(self.d / "codex.json", "w"))
        self.assertEqual(self.gate("stop", "--fid", FID)["how"], "turn/interrupt")
        self.assertEqual(json.load(open(self.d / "codex.json"))["interrupted"], "turn-9")

    def test_L_status(self):
        self.setopt(**{"@claude_state": "working"})
        r = self.say("waiting")
        st = self.gate("status", "--fid", FID)
        self.assertTrue(st["can_talk"])
        self.assertEqual([(q["delivery"], q["text"], q["why"]) for q in st["queue"]], [(r["delivery"], "waiting", "busy")])

    def test_M_ask_cards(self):
        proj = self.d / "projects/p"
        proj.mkdir(parents=True)
        q = {"question": "猫还是狗？", "header": "宠物", "multiSelect": False,
             "options": [{"label": "猫", "description": ""}, {"label": "狗", "description": ""}]}
        (proj / (SID + ".jsonl")).write_text(json.dumps({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": "tu1", "name": "AskUserQuestion", "input": {"questions": [q]}}]}}) + "\n")
        self.window({"@claude_state": "needs", "@claude_needs": "ask"})
        st = self.gate("status", "--fid", FID)
        card = st["ask"]
        self.assertEqual([card["kind"], card["questions"][0]["question"], [o["label"] for o in card["questions"][0]["options"]]],
                         ["question", "猫还是狗？", ["猫", "狗"]])
        log = self.d / "dialog.log"
        stub = self.d / "dialog"
        stub.write_text("#!/bin/sh\necho \"$@\" >> %s\n" % log)
        stub.chmod(0o755)
        env = {"FLEET_GATE_DIALOG_CMD": str(stub)}
        r = self.gate("answer", "--fid", FID, "--fp", card["fp"], "--answers-json", json.dumps({"猫还是狗？": "狗"}), env=env)
        self.assertTrue(r["ok"], r)
        self.assertIn("--fp %s --by person --basis 网页上点选 --pick 狗" % card["fp"], log.read_text())
        self.assertEqual(self.gate("answer", "--fid", FID, "--fp", "0" * 16, "--pick", "狗", env=env)["why"], "changed")
        # a permission prompt: its card off fleet-permission.sh --show --json, allow / deny --by
        perm = self.d / "perm"
        plog = self.d / "perm.log"
        perm.write_text("#!/bin/sh\necho \"$@\" >> %s\ncase \"$*\" in *--show*) echo '{\"tool\":\"Bash\",\"command\":\"rm -rf build\"}' ;; esac\n" % plog)
        perm.chmod(0o755)
        self.window({"@claude_state": "needs", "@claude_needs": "perm"})
        env = {"FLEET_GATE_PERMISSION_CMD": str(perm)}
        card = self.gate("status", "--fid", FID, env=env)["ask"]
        self.assertEqual([card["kind"], card["tool"], card["summary"]], ["permission", "Bash", "rm -rf build"])
        r = self.gate("answer", "--fid", FID, "--fp", card["fp"], "--allow", "1", env=env)
        self.assertTrue(r["ok"], r)
        self.assertIn("--by 网页 --allow @1", plog.read_text())


if __name__ == "__main__":
    only = [a for a in sys.argv[1:] if len(a) == 1 and a.isalpha()]
    if only:
        names = [n for n in unittest.TestLoader().getTestCaseNames(Gate) if n.split("_")[1] in only]
        suite = unittest.TestSuite(Gate(n) for n in names)
    else:
        suite = unittest.TestLoader().loadTestsFromTestCase(Gate)
    sys.exit(0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1)
