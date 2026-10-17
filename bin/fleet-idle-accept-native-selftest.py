"""Real Codex app-server: fleet_runtime's conditional idle acceptance (#4617)."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import uuid

BIN = Path(sys.argv[1]); CODEX = sys.argv[2]
sys.path.insert(0, str(BIN))
import fleet_runtime as runtime  # noqa: E402

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
    with tempfile.TemporaryDirectory(prefix="fleet-idle-accept-") as d:
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

            def connect():
                return runtime.RPC(ep, timeout=30, peer_pid=child.pid)
            client = connect()
            check(runtime.codex_version(client)[:2] >= runtime.CODEX_ACCEPT_MIN,
                  "native version %s" % (runtime.codex_version(client),))
            sid = client.call("thread/start", dict(cwd=str(root), model="gpt-5.4", approvalPolicy="never",
                                                   sandbox="danger-full-access"))["thread"]["id"]

            def idle():
                deadline = time.monotonic() + 20
                while True:
                    try:
                        t = client.call("thread/read", dict(threadId=sid, includeTurns=True))["thread"]
                    except ValueError as e:  # the rollout is not materialized yet
                        if "not supported" not in str(e):
                            raise
                        t = dict(status=dict(type="starting"))
                    rows = t.get("turns") or []
                    if t["status"]["type"] == "idle" and rows and rows[-1]["status"] == "completed":
                        return rows[-1]["id"]
                    if time.monotonic() >= deadline:
                        check(False, "session settles idle")
                    time.sleep(.05)

            def count(delivery):
                n = 0
                for t in client.call("thread/read", dict(threadId=sid, includeTurns=True))["thread"]["turns"]:
                    n += sum(1 for i in t.get("items", []) if i.get("clientId") == delivery)
                return n

            def add(delivery, c=None):
                return (c or client).call("thread/queue/add", dict(threadId=sid, clientUserMessageId=delivery,
                                          input=[dict(type="text", text="loop " + delivery)]))["queuedSubmission"]["id"]

            def user_turn():
                hold.add(len(requests) + 1)
                held.clear(); release.clear()
                t = client.call("turn/start", dict(threadId=sid, input=[dict(type="text", text="user")]))["turn"]
                check(held.wait(10), "user turn running")
                return t["id"]

            client.call("turn/start", dict(threadId=sid, input=[dict(type="text", text="first")]))
            anchor = idle()

            # 1. idle: accepted natively, a receipt read back from a NEW connection.
            d1 = str(uuid.uuid4())
            st, why, tid, prev = runtime.codex_settle(client, sid, add(d1), d1, anchor)
            check(st == "accepted" and prev == anchor, "idle -> accepted (%s), previous turn is the anchor" % why)
            anchor = idle()
            c2 = connect()
            found, tid2, _ = runtime.codex_receipt(c2, sid, d1, prev)
            c2.close()
            check(found and tid2 == tid and count(d1) == 1, "receipt survives a reconnect; delivered once")

            # 2. a user turn after the idle precheck: refused, deleted, never delivered.
            user = user_turn()
            d2 = str(uuid.uuid4())
            st, why, _, _ = runtime.codex_settle(client, sid, add(d2), d2, anchor)
            check((st, why) == ("rejected", "native_not_idle"), "busy -> rejected (native_not_idle)")
            release.set()
            anchor = idle(); time.sleep(1.5); anchor = idle()
            check(anchor == user and count(d2) == 0 and runtime.codex_queued(client, sid, d2) is None,
                  "refused delivery never runs after the user turn ends")

            # 3. disconnect right after the add while busy: the retry settles THE SAME item.
            user = user_turn()
            d3 = str(uuid.uuid4())
            c3 = connect(); add(d3, c3); c3.close()
            qid = runtime.codex_queued(client, sid, d3)
            check(qid is not None, "pending item found by its client message id after the disconnect")
            st, why, _, _ = runtime.codex_settle(client, sid, qid, d3, anchor)
            check(st == "rejected", "retry while busy -> rejected and deleted")
            release.set(); anchor = idle(); time.sleep(1.5)
            check(count(d3) == 0, "still never delivered")

            # 4. disconnect while busy, and the native idle edge takes it first.
            user = user_turn()
            d4 = str(uuid.uuid4())
            c4 = connect(); add(d4, c4); c4.close()
            release.set(); idle(); time.sleep(1.5); idle()
            check(runtime.codex_queued(client, sid, d4) is None, "native queue dispatched it on idle")
            found, tid, prev = runtime.codex_receipt(client, sid, d4, anchor)
            check(found and prev == user and count(d4) == 1,
                  "the retry finds the receipt (intervening user turn reported), no resend")
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
    print("PASS fleet-idle-accept-native (codex %s)" % subprocess.check_output([CODEX, "--version"], text=True).split()[-1])


if __name__ == "__main__":
    main()
