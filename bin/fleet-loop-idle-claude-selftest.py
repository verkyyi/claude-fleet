"""Real Claude Code: the loop's due wakeup through accept_if_idle (#4658).

The #4431 consumer on the Claude half: fleet-loop.py's dispatch → the real
fleet_runtime.accept_if_idle → the real fleet mod (a copy) at the engine's
entry boundary, in a pty with a loopback model and an isolated HOME. The
harness (model fixture, stub runtime that records the mod's turn events) is
fleet-idle-accept-claude-selftest.py's own. Fixtures stand in for the C3
launch authority, the tmux options and the pane gates; the accept, journal and
receipt are the real ones.
"""
import importlib.util
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import patch

BIN = Path(sys.argv[1]); CLAUDE = sys.argv[2]
sys.path.insert(0, str(BIN))
import fleet_runtime as runtime  # noqa: E402

H = runpy.run_path(str(BIN / "fleet-idle-accept-claude-selftest.py"))
Terminal = runpy.run_path(str(BIN / "fleet-native-claude-tui-selftest.py"))["Terminal"]
bodies, last_user, check = H["bodies"], H["last_user"], H["check"]

spec = importlib.util.spec_from_file_location("fleet_loop", BIN / "fleet-loop.py")
loop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(loop)


def main():
    t0 = time.monotonic()
    import http.server
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H["Model"])
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="fleet-loop-idle-claude-", dir="/tmp") as d:
        root = Path(d).resolve()
        home, repo, conf = root / "home", root / "repo", root / "conf"
        for p in (home, repo, conf, root / "stub/bin", root / "fakebin"):
            p.mkdir(parents=True)
        shutil.copytree(BIN.parent / "mod/fleet", root / "stub/mod/fleet",
                        ignore=shutil.ignore_patterns("tests", "types", ".claude-plugin/types"))
        shutil.copytree(BIN.parent / "mod/fleet/types", root / "stub/mod/fleet/types")
        (root / "stub/bin/fleet_runtime.py").write_text(H["STUB_RUNTIME"])
        (root / "fakebin/tmux").write_text("#!/bin/sh\nexit 0\n")
        (root / "fakebin/tmux").chmod(0o755)
        events = root / "events.ndjson"
        events.touch()
        # The C3 launch: what the mod holds (FLEET_LAUNCH_CONTEXT) is what the
        # request carries (launch.IDENTITY of the read's identity).
        c3 = dict(version=1, operation_id="op", task="T1", owner="o", generation=3,
                  worker_id="w", provider="claude", attempt_id="a")
        env = {"HOME": str(home), "CLAUDE_CONFIG_DIR": str(home / ".claude"), "TMPDIR": str(root),
               "PATH": str(root / "fakebin") + ":" + os.environ["PATH"], "TERM": "xterm-256color",
               "ANTHROPIC_API_KEY": "fixture-not-a-credential",
               "ANTHROPIC_BASE_URL": "http://127.0.0.1:%d" % srv.server_port,
               "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1",
               "TMUX": "%s/fixture-sock,1,0" % root, "TMUX_PANE": "%7", "FLEET_CONF_DIR": str(conf),
               "FLEET_MCP_SERVER": "1", "FLEET_LAUNCH_CONTEXT": json.dumps(c3),
               "STUB_EVENTS": str(events)}
        inbox = conf / "global/mod-inbox/fixture-sock/7"
        inbox.mkdir(parents=True)
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
            end = time.monotonic() + timeout
            while time.monotonic() < end:
                ev = native()
                if ev and ev[-1]["state"] == "idle":
                    pump(.3)
                    if native()[-1] == ev[-1]:
                        return ev[-1]["turn_id"]
                pump(.1)
            check(False, "session settles idle")

        def sent(delivery):
            return [i for i, b in enumerate(bodies) if delivery in last_user(json.loads(b))]

        try:
            t.wait("Choose the text style"); t.send("\r")
            t.wait("Do you want to use this API key?"); t.send("\x1b[A"); t.wait("❯ Yes"); time.sleep(.5); t.send("\r")
            t.wait("Security notes:"); t.send("\r")
            t.wait("Yes, I trust this folder"); time.sleep(1.5); t.send("\x1b[B")
            t.wait("❯ Yes, I trust this folder"); time.sleep(.5); t.send("\r")
            t.ready(); pump(2)
            sid = json.loads(next((home / ".claude/sessions").glob("*.json")).read_text())["sessionId"]
            native_id = dict(native_session=sid, pid=t.process.pid, birth="fixture",
                             executable=CLAUDE, native_remote=None)

            def observe(pane, context=None, expected=None, socket=""):
                ev = native()[-1]
                now = time.time()
                return dict(version=1, identity=dict(c3, **native_id, turn_id=ev["turn_id"]),
                            source="claude:native-event", observed_at=now, expires_at=now + runtime.TTL,
                            runtime=dict(state="idle" if ev["state"] == "idle" else ev["state"], reason=""))

            stale = {}

            def read(pane, context=None, expected=None, socket=""):
                # An idle observation taken BEFORE the person's turn (#4524's race).
                return dict(stale["snap"], observed_at=time.time(), expires_at=time.time() + 5) if stale else observe(pane)

            opt = {"socket_path": str(root / "fixture-sock"), "@mod_accept": runtime.CLAUDE_ACCEPT}
            path = root / "loop/state.json"
            path.parent.mkdir()
            loop.save(path, dict(id="loop-claude", status="active", agent="claude", thread_id=sid,
                                 worktree=str(repo), pane_pid=1, manifest="m",
                                 fleet=dict(session="isolated", window_id="@7", pane_id="%7"),
                                 deliveries=0, schedule=dict(prompt="继续原任务", interval_seconds=3600, next_run_at=0)))
            opts = {"#{@claude_state}": "looping", "#{@launch}": json.dumps(c3)}

            def ledger():
                return json.loads(path.read_text())

            def due():
                r = ledger(); r["schedule"]["next_run_at"] = 0; loop.save(path, r)

            def dispatch():
                th = threading.Thread(target=loop.dispatch, args=(path,))
                th.start()
                while th.is_alive():
                    pump(.05)
                return ledger()

            def legacy(*a, **k):
                raise AssertionError("the legacy inbox road ran on a C3 Claude pane")

            with patch.dict(os.environ, FLEET_CONF_DIR=str(conf), FLEET_CC_PROJECTS_DIR=str(home / ".claude/projects")), \
                    patch.object(runtime, "read", read), \
                    patch.object(runtime.launch, "option", lambda p, k, s="": opt.get(k, "")), \
                    patch.object(runtime.launch, "check_receipt", lambda c, r: r), \
                    patch.object(runtime.launch, "inspect", lambda c, p, s="": dict(native_id)), \
                    patch.object(loop, "_runtime", lambda: runtime), \
                    patch.object(loop, "current", lambda r: None), \
                    patch.object(loop, "pane", lambda r, f: opts.get(f, "")), \
                    patch.object(loop, "tm", lambda *a: ""), \
                    patch.object(loop, "wait_reasons", lambda r: []), \
                    patch.object(loop, "deliver_claude", legacy), \
                    patch.object(loop.runpy, "run_path", lambda *a, **k: {"snapshot": lambda *a, **k: {"state": "empty"}}):
                t.send("first\r")
                first = settled()

                # 1. Stop -> looping (its own loop only), native idle, due: accepted once.
                r = dispatch()
                a = r["last_attempt"]
                check(r["deliveries"] == 1 and r["status"] == "active" and a["fence"] == "native_idle"
                      and r["accepted_turn"] and r["accepted_turn"] != first,
                      "idle + due -> accepted at the entry boundary (%s)" % a["reason"])
                d1 = a["delivery_id"]
                turn1 = settled()
                check(turn1 == r["accepted_turn"] and len(sent(d1)) == 1,
                      "the accepted turn ran, the model read the wakeup once")
                check(runtime.claude_receipt(inbox, d1, sid) == (True, turn1), "receipt queryable: names the turn")
                n = len(bodies)
                dispatch(); dispatch()
                check(ledger()["deliveries"] == 1 and len(bodies) == n, "repeated ticks before the next due send nothing")

                # 2. A person's turn running behind an idle read: dropped at entry, still due.
                stale["snap"] = observe("%7")
                t.send("SLOW person busy\r")
                end = time.monotonic() + 10
                while native()[-1]["state"] != "active" and time.monotonic() < end:
                    pump(.05)
                due()
                r = dispatch()
                d2 = r["last_attempt"]["delivery_id"]
                check(r["deferred_reason"].startswith("rejected:") and r["deliveries"] == 1
                      and r["schedule"]["next_run_at"] == 0 and "pending_delivery" not in r,
                      "busy -> rejected (%s), still due, nothing pending" % r["deferred_reason"])
                settled(); pump(2)
                check(sent(d2) == [] and runtime.claude_receipt(inbox, d2, sid) == (False, None),
                      "the refused wakeup never runs after the person's turn, no receipt")

                # 3. Released: exactly once more, as a new delivery.
                stale.clear()
                r = dispatch()
                d3 = r["last_attempt"]["delivery_id"]
                check(r["deliveries"] == 2 and d3 != d2 and r["deferred_reason"] is None,
                      "after the person's turn: one delivery, a new id")
                settled()
                check(len(sent(d3)) == 1, "the new delivery ran once")

                # 4. The answer lost after the mod took it (a disconnect): unknown, settled by
                # its receipt on the next tick, never resent.
                due()
                real = runtime.claude_post_accept

                def lossy(*a):
                    real(*a)
                    raise runtime.Unknown("answer_lost")
                with patch.object(runtime, "claude_post_accept", lossy):
                    r = dispatch()
                d4 = r["pending_delivery"]["delivery_id"] if r.get("pending_delivery") else None
                check(r["status"] == "delivering" and d4 and r["deliveries"] == 2
                      and r["deferred_reason"] == "unknown:answer_lost",
                      "lost answer -> unknown, the delivery kept pending")
                turn4 = settled()
                n = len(bodies)
                r = dispatch()
                check(r["deliveries"] == 3 and r["accepted_turn"] == turn4 and "pending_delivery" not in r
                      and r["last_attempt"]["delivery_id"] == d4,
                      "next tick settles the same id by its receipt (%s)" % r["last_attempt"]["reason"])
                pump(1)
                check(len(sent(d4)) == 1 and len(bodies) == n, "settled without a second send")
        finally:
            t.close()
            srv.shutdown(); srv.server_close()
    print("PASS fleet-loop-idle-claude (claude %s, %.1fs, %s)" % (
        subprocess.check_output([CLAUDE, "--version"], text=True).split()[0],
        time.monotonic() - t0, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))


if __name__ == "__main__":
    main()
