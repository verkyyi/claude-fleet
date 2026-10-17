"""Real Codex app-server: the loop's due wakeup through accept_if_idle (#4431)."""
import importlib.util
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import patch

BIN = Path(sys.argv[1]); CODEX = sys.argv[2]
sys.path.insert(0, str(BIN))
import fleet_runtime as runtime  # noqa: E402

spec = importlib.util.spec_from_file_location("fleet_loop", BIN / "fleet-loop.py")
loop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(loop)

requests, hold, held, release = [], set(), threading.Event(), threading.Event()


class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        requests.append(1)
        if len(requests) in hold:
            held.set()
            if not release.wait(30):
                self.send_error(504)
                return
        n = len(requests)
        item = dict(id="msg%d" % n, type="message", role="assistant", status="completed",
                    content=[dict(type="output_text", text="fixture", annotations=[])])
        resp = dict(id="resp%d" % n, object="response", status="completed", output=[item],
                    usage=dict(input_tokens=1, output_tokens=1, total_tokens=2))
        rows = [dict(type="response.created", response=dict(resp, status="in_progress", output=[])),
                dict(type="response.output_item.added", output_index=0, item=item),
                dict(type="response.output_item.done", output_index=0, item=item),
                dict(type="response.completed", response=resp)]
        body = "".join("event: %s\ndata: %s\n\n" % (r["type"], json.dumps(r)) for r in rows).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what, flush=True)
    if not cond:
        raise SystemExit(1)


def main():
    t0 = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="fleet-loop-idle-") as d:
        root = Path(d).resolve()
        home = root / "home"
        native_home = home / ".codex"
        native_home.mkdir(parents=True)
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
        srv.daemon_threads = True
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        (native_home / "config.toml").write_text(
            'model="gpt-5.4"\nmodel_provider="fixture"\n[model_providers.fixture]\nname="Fixture"\n'
            'base_url="http://127.0.0.1:%d/v1"\nwire_api="responses"\nrequires_openai_auth=false\n' % srv.server_port)
        env = {k: os.environ[k] for k in ("PATH", "LANG", "TERM", "TMPDIR") if k in os.environ}
        env.update(HOME=str(home), CODEX_HOME=str(native_home))
        ep = "unix://" + str(root / "w.sock")
        child = client = None
        try:
            with open(root / "native.log", "w") as log:
                child = subprocess.Popen([CODEX, "app-server", "--listen", ep], env=env, cwd=root,
                                         stdout=log, stderr=log, start_new_session=True)
            deadline = time.monotonic() + 20
            while not Path(ep[7:]).exists():
                if child.poll() is not None or time.monotonic() >= deadline:
                    check(False, "app-server listening")
                time.sleep(.05)
            client = runtime.RPC(ep, timeout=30, peer_pid=child.pid)
            version = runtime.codex_version(client)
            sid = client.call("thread/start", dict(cwd=str(root), model="gpt-5.4", approvalPolicy="never",
                                                   sandbox="danger-full-access"))["thread"]["id"]

            def turns():
                try:
                    return client.call("thread/read", dict(threadId=sid, includeTurns=True))["thread"]
                except ValueError as e:  # the rollout is not materialized yet
                    if "not supported" not in str(e):
                        raise
                    return dict(status=dict(type="starting"), turns=[])

            def idle():
                deadline = time.monotonic() + 20
                while True:
                    t = turns()
                    rows = t.get("turns") or []
                    if t["status"]["type"] == "idle" and rows and rows[-1]["status"] == "completed":
                        return rows[-1]["id"]
                    if time.monotonic() >= deadline:
                        check(False, "session settles idle")
                    time.sleep(.05)

            def count(delivery):
                return sum(1 for t in turns().get("turns") or [] for i in t.get("items", [])
                           if i.get("clientId") == delivery)

            # C3 authority is a fixture; the native identity is this real server's.
            native = dict(native_session=sid, pid=child.pid, birth="fixture", executable=CODEX,
                          native_remote=ep)
            c3 = dict(version=1, operation_id="op", task="T1", owner="o", generation=3,
                      worker_id="w", provider="codex", attempt_id="a")

            def observe(pane, context=None, expected=None, socket=""):
                t = turns()
                rows = t.get("turns") or []
                st = t["status"]["type"]
                state = "active" if st == "active" else "idle" if rows and rows[-1]["status"] == "completed" else "unknown"
                now = time.time()
                return dict(version=1, identity=dict(c3, **native, turn_id=rows[-1]["id"] if rows else None),
                            source="codex:rpc", observed_at=now, expires_at=now + runtime.TTL,
                            runtime=dict(state=state, reason=""))

            stale = {}

            def read(pane, context=None, expected=None, socket=""):
                # An idle observation taken BEFORE a user turn (the race #4524 names).
                return dict(stale["snap"], observed_at=time.time(), expires_at=time.time() + 5) if stale else observe(pane)

            path = root / "loop/state.json"
            path.parent.mkdir()
            loop.save(path, dict(id="loop-native", status="active", thread_id=sid,
                                 socket=ep[7:], worktree=str(root), pane_pid=1, manifest="m",
                                 fleet=dict(session="isolated", window_id="@2", pane_id="%2"),
                                 deliveries=0, schedule=dict(prompt="继续原任务", interval_seconds=3600, next_run_at=0)))
            opts = {"#{@claude_state}": "looping", "#{@launch}": json.dumps(c3)}
            with patch.dict(os.environ, FLEET_CONF_DIR=str(root / "conf")), \
                    patch.object(runtime, "read", read), \
                    patch.object(runtime.launch, "check_receipt", lambda c, r: r), \
                    patch.object(runtime.launch, "inspect", lambda c, p, s="": dict(native)), \
                    patch.dict(runtime.CODEX, identity=lambda p, s="": dict(session_id=sid, remote=ep)), \
                    patch.object(loop, "_runtime", lambda: runtime), \
                    patch.object(loop, "current", lambda r: None), \
                    patch.object(loop, "pane", lambda r, f: opts.get(f, "")), \
                    patch.object(loop, "tm", lambda *a: ""), \
                    patch.object(loop, "wait_reasons", lambda r: []):
                client.call("turn/start", dict(threadId=sid, input=[dict(type="text", text="first")]))
                first = idle()

                # 1. Stop -> looping (its own loop only), native idle, due: accepted once.
                loop.dispatch(path)
                r = json.loads(path.read_text())
                a = r["last_attempt"]
                check(r["deliveries"] == 1 and r["status"] == "active" and a["fence"] == "native_idle",
                      "looping + native idle + due -> accepted (%s)" % a["reason"])
                check(count(a["delivery_id"]) == 1 and r["accepted_turn"] != first,
                      "the accepted turn carries the delivery id once (turn %s)" % r["accepted_turn"])
                idle()
                n = len(requests)
                loop.dispatch(path); loop.dispatch(path)
                check(json.loads(path.read_text())["deliveries"] == 1 and len(requests) == n,
                      "repeated ticks before the next due send nothing")

                # 2. A user turn starts after the idle check: native refusal, still due.
                stale["snap"] = observe("%2")
                hold.add(len(requests) + 1); held.clear(); release.clear()
                user = client.call("turn/start", dict(threadId=sid, input=[dict(type="text", text="user")]))["turn"]["id"]
                check(held.wait(10), "user turn running")
                r = json.loads(path.read_text()); r["schedule"]["next_run_at"] = 0; loop.save(path, r)
                loop.dispatch(path)
                r = json.loads(path.read_text())
                d2 = r["last_attempt"]["delivery_id"]
                check(r["deferred_reason"] == "rejected:native_not_idle" and r["deliveries"] == 1
                      and r["schedule"]["next_run_at"] == 0 and "pending_delivery" not in r,
                      "check-then-new-turn -> rejected natively, still due, nothing pending")
                release.set(); idle(); time.sleep(1.5)
                check(idle() == user and count(d2) == 0, "the refused wakeup never runs after the user turn")

                # 3. Released: exactly once more, as a new delivery.
                stale.clear()
                loop.dispatch(path)
                r = json.loads(path.read_text())
                d3 = r["last_attempt"]["delivery_id"]
                check(r["deliveries"] == 2 and d3 != d2 and count(d3) == 1 and r["deferred_reason"] is None,
                      "after the blocker clears: one delivery, a new id, no deferral left")
                idle(); n = len(requests)
                loop.dispatch(path)
                check(len(requests) == n, "late tick: nothing resent")
        finally:
            release.set()
            if client:
                client.close()
            if child and child.poll() is None:
                child.terminate()
                try:
                    child.wait(10)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait(5)
            srv.shutdown(); srv.server_close()
    print("PASS fleet-loop-idle-native (codex %s, session %s, %.1fs, %s)" % (
        ".".join(map(str, version)) if version else "?", sid,
        time.monotonic() - t0, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))


if __name__ == "__main__":
    main()
