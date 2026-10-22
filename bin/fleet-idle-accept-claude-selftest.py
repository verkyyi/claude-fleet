"""Real Claude Code: the fleet mod's conditional idle acceptance (#4618), the
session gate's idle.v2 road (task HHV0).

The real engine in a pty, the REAL mod/fleet (a copy: the engine writes types
into a --plugin-dir) beside a stub bin/ whose fleet_runtime.py records the
mod's native turn events (it still names them for a session with a launch
context — observation only, idle.v2 reads none), a loopback model fixture, an
isolated HOME. The python half is fleet_session_gate.py's own claude_post /
claude_receipt.
"""
import http.server
import json
import os
from pathlib import Path
import runpy
import shutil
import sys
import tempfile
import threading
import time
import uuid

BIN = Path(sys.argv[1]); CLAUDE = sys.argv[2]
gate = runpy.run_path(str(BIN / "fleet_session_gate.py"))

Terminal = runpy.run_path(str(BIN / "fleet-native-claude-tui-selftest.py"))["Terminal"]
bodies = []


def last_user(body):
    for m in reversed(body.get("messages", [])):
        if m.get("role") == "user":
            c = m["content"]
            return c if isinstance(c, str) else " ".join(
                b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    return ""


class Model(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def reply(self, ctype, body):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}"
        body = json.loads(raw)
        if "count_tokens" in self.path:
            return self.reply("application/json", b'{"input_tokens":10}')
        user = last_user(body)
        title = "Write the title" in user
        if body.get("stream") and not title:
            bodies.append(raw.decode("utf-8", "replace"))
        if "SLOW" in user and not title:
            time.sleep(6)
        text = "fixture reply"
        if not body.get("stream"):
            return self.reply("application/json", json.dumps(dict(
                id="msg_1", type="message", role="assistant", model=body.get("model"),
                content=[dict(type="text", text=text)], stop_reason="end_turn", stop_sequence=None,
                usage=dict(input_tokens=1, output_tokens=1))).encode())
        ev = [dict(type="message_start", message=dict(id="msg_" + uuid.uuid4().hex[:8], type="message",
                   role="assistant", model=body.get("model"), content=[], stop_reason=None,
                   stop_sequence=None, usage=dict(input_tokens=1, output_tokens=1))),
              dict(type="content_block_start", index=0, content_block=dict(type="text", text="")),
              dict(type="content_block_delta", index=0, delta=dict(type="text_delta", text=text)),
              dict(type="content_block_stop", index=0),
              dict(type="message_delta", delta=dict(stop_reason="end_turn", stop_sequence=None),
                   usage=dict(output_tokens=1)),
              dict(type="message_stop")]
        self.reply("text/event-stream", "".join(
            "event: %s\ndata: %s\n\n" % (e["type"], json.dumps(e)) for e in ev).encode())


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what, flush=True)
    if not cond:
        raise SystemExit(1)


STUB_RUNTIME = """import json, os, sys
with open(os.environ["STUB_EVENTS"], "a") as f:
    f.write(json.dumps(dict(argv=sys.argv[1:], stdin=json.load(sys.stdin))) + "\\n")
"""


def main():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="fleet-idle-accept-claude-", dir="/tmp") as d:
        root = Path(d).resolve()
        home, repo, conf = root / "home", root / "repo", root / "conf"
        for p in (home, repo, conf, root / "stub/bin", root / "fakebin"):
            p.mkdir(parents=True)
        shutil.copytree(BIN.parent / "mod/fleet", root / "stub/mod/fleet",
                        ignore=shutil.ignore_patterns("tests", "types", ".claude-plugin/types"))
        shutil.copytree(BIN.parent / "mod/fleet/types", root / "stub/mod/fleet/types")
        (root / "stub/bin/fleet_runtime.py").write_text(STUB_RUNTIME)
        (root / "fakebin/tmux").write_text("#!/bin/sh\nexit 0\n")
        (root / "fakebin/tmux").chmod(0o755)
        events = root / "events.ndjson"
        events.touch()
        launch = dict(version=1, provider="claude", task="T1")
        env = {"HOME": str(home), "CLAUDE_CONFIG_DIR": str(home / ".claude"), "TMPDIR": str(root),
               "PATH": str(root / "fakebin") + ":" + os.environ["PATH"], "TERM": "xterm-256color",
               "ANTHROPIC_API_KEY": "fixture-not-a-credential",
               "ANTHROPIC_BASE_URL": "http://127.0.0.1:%d" % srv.server_port,
               "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1",
               "TMUX": "%s/fixture-sock,1,0" % root, "TMUX_PANE": "%7", "FLEET_CONF_DIR": str(conf),
               "FLEET_MCP_SERVER": "1", "FLEET_LAUNCH_CONTEXT": json.dumps(launch),
               "STUB_EVENTS": str(events)}
        inbox = conf / "global/mod-inbox/fixture-sock/7"
        inbox.mkdir(parents=True)
        os.environ["FLEET_CC_PROJECTS_DIR"] = str(home / ".claude/projects")
        t = Terminal([CLAUDE, "--setting-sources", "", "--strict-mcp-config", "--tools", "",
                      "--model", "claude-sonnet-4-6", "--plugin-dir", str(root / "stub/mod/fleet")],
                     str(repo), env)

        def pump(secs):
            end = time.monotonic() + secs
            while time.monotonic() < end:
                t.read(0.05)

        def native():
            return [json.loads(x)["stdin"] for x in events.read_text().splitlines()]

        def settled(timeout=20):
            """The last root turn, once the mod says it finished idle."""
            end = time.monotonic() + timeout
            while time.monotonic() < end:
                ev = native()
                if ev and ev[-1]["state"] in ("idle", "interrupted"):
                    pump(.3)
                    if native()[-1] == ev[-1]:
                        return ev[-1]["turn_id"]
                pump(.1)
            check(False, "session settles idle")

        def accept(expected, delivery, text, during=None):
            # idle.v2: no launch, no turn to name — the conversation it is taken in is the fence
            req = dict(accept="idle.v2", nonce=uuid.uuid4().hex, delivery_id=delivery,
                       text=text, deadline=time.time() + gate["ACCEPT_WINDOW"])
            out = {}
            th = threading.Thread(target=lambda: out.update(r=_post(req)))
            th.start()
            if during:
                during()
            while th.is_alive():
                pump(.05)
            return out["r"]

        def _post(req):
            return gate["claude_post"](inbox, req, gate["ACCEPT_WINDOW"] + gate["ACCEPT_GRACE"] + gate["ACCEPT_POLL"])

        receipt = gate["claude_receipt"]
        PREFIX = gate["RECEIPT_PREFIX"]

        def sent(delivery):
            """Requests whose NEWEST user message carries it (later ones hold it as history)."""
            return [i for i, b in enumerate(bodies) if delivery in last_user(json.loads(b))]

        try:
            t.wait("Choose the text style"); t.send("\r")
            t.wait("Do you want to use this API key?"); t.send("\x1b[A"); t.wait("❯ Yes"); time.sleep(.5); t.send("\r")
            t.wait("Security notes:"); t.send("\r")
            t.wait("Yes, I trust this folder"); time.sleep(1.5); t.send("\x1b[B")
            t.wait("❯ Yes, I trust this folder"); time.sleep(.5); t.send("\r")
            t.ready(); pump(2)
            sid = json.loads(next((home / ".claude/sessions").glob("*.json")).read_text())["sessionId"]
            t.send("first\r")
            anchor = settled()

            # 1. idle: one turn of its own, its receipt durable and in the transcript.
            d1 = str(uuid.uuid4())
            r = accept(anchor, d1, "loop wakeup one")
            check(r.get("state") == "accepted" and r.get("previous_turn_id") == anchor and r.get("turn_id"),
                  "idle -> accepted at the entry boundary (%s)" % r.get("reason"))
            turn1 = settled()
            check(turn1 == r["turn_id"], "the accepted turn is the one that ran")
            check(len(sent(d1)) == 1 and PREFIX + d1 in last_user(json.loads(bodies[sent(d1)[0]])),
                  "the model read it once, its receipt in the hidden context")
            rf = json.loads((inbox / ("idle-accept-%s.receipt" % d1)).read_text())
            check(receipt(inbox, d1, sid) is True and rf.get("turn_id") == turn1, "durable receipt names the turn")
            (inbox / ("idle-accept-%s.receipt" % d1)).unlink()
            check(receipt(inbox, d1, sid) is True, "without the file the transcript still names the delivery")

            # 2. a person's turn running: refused before anything is submitted.
            t.send("SLOW person busy\r")
            end = time.monotonic() + 10
            while native()[-1]["state"] != "active" and time.monotonic() < end:
                pump(.05)
            d2 = str(uuid.uuid4())
            r = accept(turn1, d2, "loop wakeup two")
            check((r.get("state"), r.get("reason")) == ("rejected", "precheck_not_idle"), "busy -> rejected (precheck)")
            anchor = settled()
            pump(2)
            check(sent(d2) == [], "the refused delivery never runs after the person's turn")
            # the gate's queue: the refused sentence is posted again once idle — one turn, after the person's
            r = accept(anchor, d2, "loop wakeup two")
            check(r.get("state") == "accepted", "queued -> accepted on the retry once idle (%s)" % r.get("reason"))
            end = time.monotonic() + 20
            while settled() != r["turn_id"] and time.monotonic() < end:
                pump(.2)
            anchor = settled()
            check(len(sent(d2)) == 1, "the queued sentence ran exactly once")

            # 3. a draft in the box: dropped at entry, the draft kept, never re-queued.
            t.send("half typed draft")
            pump(1)
            d3 = str(uuid.uuid4())
            r = accept(anchor, d3, "loop wakeup three")
            check((r.get("state"), r.get("reason")) == ("rejected", "draft_present"), "draft -> dropped at entry")
            check("half typed draft" in t.text(), "the person's draft is untouched")
            t.send("\r")
            anchor = settled()
            pump(3)
            check(sent(d3) == [] and receipt(inbox, d3, sid) is False,
                  "dropped -> never delivered, no receipt, after the next idle")

            # 4. a person's Enter racing the request: never folded into one turn.
            for i, lag in enumerate((0, .4, .8, 1.2)):
                anchor = settled()
                d = str(uuid.uuid4())
                n = len(bodies)
                r = accept(anchor, d, "loop wakeup race %d" % i,
                           during=lambda lag=lag, i=i: (pump(lag), t.send("person racer %d\r" % i)))
                settled()
                pump(1)
                people = [j for j in range(n, len(bodies)) if "person racer %d" % i in last_user(json.loads(bodies[j]))]
                if r.get("state") == "accepted":
                    # idle.v2: first come first in — either order, but each its own turn
                    mine = sent(d)
                    check(len(mine) == 1 and people and mine[0] not in people
                          and "person racer" not in last_user(json.loads(bodies[mine[0]])),
                          "race %d: accepted -> one turn of its own beside the person's" % i)
                else:
                    check(r.get("state") == "rejected" and sent(d) == [] and people,
                          "race %d: %s -> never delivered, the person's ran" % (i, r.get("reason")))

            # 5. Esc stops a running turn (the gate's stop): within a second, idle again.
            anchor = settled()
            t.send("SLOW stop me\r")
            end = time.monotonic() + 10
            while native()[-1]["state"] != "active" and time.monotonic() < end:
                pump(.05)
            t0 = time.monotonic()
            t.send("\x1b")
            end = time.monotonic() + 5
            while native()[-1]["state"] == "active" and time.monotonic() < end:
                pump(.02)
            check(native()[-1]["state"] in ("interrupted", "idle") and time.monotonic() - t0 < 1.5,
                  "Esc stops the running turn in %.2f s" % (time.monotonic() - t0))
            pump(1)
            check("SLOW stop me" in t.text(), "a person's stopped prompt comes back to the box (the engine's rule)")
            t.send("\x15")                              # the person clears it
            pump(.5)

            # 5b. the gate's OWN words stopped: back in the box they are no draft — emptied,
            # so the next sentence is not refused as typing
            anchor = settled()
            d6 = str(uuid.uuid4())
            r = accept(anchor, d6, "SLOW gate words")
            check(r.get("state") == "accepted", "a slow gate sentence entered (%s)" % r.get("reason"))
            t.send("\x1b")
            end = time.monotonic() + 5
            while native()[-1]["state"] == "active" and time.monotonic() < end:
                pump(.02)
            pump(1.5)
            d7 = str(uuid.uuid4())
            r = accept(settled(), d7, "after the stop")
            check(r.get("state") == "accepted", "after the gate's turn was stopped the next sentence enters (%s)" % r.get("reason"))
            settled()

            # 6. after a /clear: a sentence taken now enters the NEW conversation
            # (idle.v2's fence is the conversation it is taken in; the gate returns what
            # was queued for the old one — fleet-session-gate-selftest.py F).
            t.send("/clear\r")
            pump(3)
            d5 = str(uuid.uuid4())
            r = accept("", d5, "loop wakeup five")
            check(r.get("state") == "accepted" and len(sent(d5)) <= 1, "after /clear -> into the new conversation (%s)" % r.get("reason"))
            settled()

            # 7. a request nobody takes (no mod poll): withdrawn, never submitted.
            r = gate["claude_post"](root, dict(accept="idle.v2", nonce=uuid.uuid4().hex,
                                               delivery_id=str(uuid.uuid4())), .5)
            check((r.get("state"), r.get("reason")) == ("rejected", "not_taken"), "untaken request -> withdrawn")
        finally:
            t.close()
            srv.shutdown(); srv.server_close()
    import subprocess
    print("PASS fleet-idle-accept-claude (claude %s)" %
          subprocess.check_output([CLAUDE, "--version"], text=True).split()[0])


if __name__ == "__main__":
    main()
