"""Real Claude Code: a handoff's pickup through the mod inbox after /clear (#4865).

fleet-handoff-cycle.sh posts `/clear` and then `/fleet-handoff pickup` to the
pane's command inbox (fleet_session_command); the mod runs each with
`$.command.run`. A prompt-type command (a markdown command / skill) expands
into a `prompt.submit` that carries the mod's own origin (`plugin:fleet`), and
accept.ts once dropped every such prompt that matched no idle-accept slot —
«Prompt dropped by a hook: fleet idle-accept: no live request» — so the pickup
never reached the fresh session.

The real engine in a pty, the REAL mod/fleet (a copy, plus one markdown command
`/probe` standing in for /fleet-handoff), a stub bin/fleet_runtime.py, a
loopback model fixture, an isolated HOME. Posted exactly the way bash posts it.
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
        title = "Write the title" in last_user(body)
        if body.get("stream") and not title:
            bodies.append(raw.decode("utf-8", "replace"))
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
        if SCREEN:
            print("screen: " + SCREEN[0]()[-1500:], flush=True)
        raise SystemExit(1)


SCREEN = []

STUB_RUNTIME = """import json, os, sys
with open(os.environ["STUB_EVENTS"], "a") as f:
    f.write(json.dumps(dict(argv=sys.argv[1:], stdin=json.load(sys.stdin))) + "\\n")
"""

PROBE = """---
description: stands in for /fleet-handoff (a prompt-type plugin command)
---
PICKUP-PROBE resume with argument: $ARGUMENTS
"""


def main():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="fleet-handoff-pickup-claude-", dir="/tmp") as d:
        root = Path(d).resolve()
        home, repo, conf = root / "home", root / "repo", root / "conf"
        for p in (home, repo, conf, root / "stub/bin", root / "fakebin"):
            p.mkdir(parents=True)
        mod = root / "stub/mod/fleet"
        shutil.copytree(BIN.parent / "mod/fleet", mod,
                        ignore=shutil.ignore_patterns("tests", "types", ".claude-plugin/types"))
        shutil.copytree(BIN.parent / "mod/fleet/types", mod / "types")
        (mod / "commands").mkdir()
        (mod / "commands/probe.md").write_text(PROBE)
        (root / "stub/bin/fleet_runtime.py").write_text(STUB_RUNTIME)
        (root / "fakebin/tmux").write_text("#!/bin/sh\nexit 0\n")
        (root / "fakebin/tmux").chmod(0o755)
        events = root / "events.ndjson"
        events.touch()
        env = {"HOME": str(home), "CLAUDE_CONFIG_DIR": str(home / ".claude"), "TMPDIR": str(root),
               "PATH": str(root / "fakebin") + ":" + os.environ["PATH"], "TERM": "xterm-256color",
               "ANTHROPIC_API_KEY": "fixture-not-a-credential",
               "ANTHROPIC_BASE_URL": "http://127.0.0.1:%d" % srv.server_port,
               "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1",
               "TMUX": "%s/fixture-sock,1,0" % root, "TMUX_PANE": "%7", "FLEET_CONF_DIR": str(conf),
               "FLEET_MCP_SERVER": "1",
               "FLEET_LAUNCH_CONTEXT": json.dumps(dict(version=1, provider="claude", task="T1")),
               "STUB_EVENTS": str(events)}
        inbox = conf / "global/mod-inbox/fixture-sock/7"
        inbox.mkdir(parents=True)
        t = Terminal([CLAUDE, "--setting-sources", "", "--strict-mcp-config", "--tools", "",
                      "--model", "claude-sonnet-4-6", "--plugin-dir", str(mod)], str(repo), env)

        SCREEN.append(t.text)

        def pump(secs):
            end = time.monotonic() + secs
            while time.monotonic() < end:
                t.read(0.05)

        def post(line, wait=20):
            """fleet_session_command's own protocol: <seq>.json, then the mod's .done."""
            cmd, _, args = line.partition(" ")
            seq = "%d-%s" % (time.time(), uuid.uuid4().hex[:8])
            tmp = inbox / (".%s.tmp" % seq)
            tmp.write_text(json.dumps(dict(cmd=cmd, args=args, **{"from": "handoff-cycle"})) + "\n")
            tmp.replace(inbox / (seq + ".json"))
            done = inbox / (seq + ".done")
            end = time.monotonic() + wait
            while time.monotonic() < end and not done.exists():
                pump(.1)
            return json.loads(done.read_text()) if done.exists() else None

        def reached(marker, timeout=15):
            end = time.monotonic() + timeout
            while time.monotonic() < end:
                if any(marker in last_user(json.loads(b)) for b in bodies):
                    return True
                pump(.1)
            return False

        try:
            t.wait("Choose the text style"); t.send("\r")
            t.wait("Do you want to use this API key?"); t.send("\x1b[A"); t.wait("❯ Yes"); time.sleep(.5); t.send("\r")
            t.wait("Security notes:"); t.send("\r")
            t.wait("Yes, I trust this folder"); time.sleep(1.5); t.send("\x1b[B")
            t.wait("❯ Yes, I trust this folder"); time.sleep(.5); t.send("\r")
            t.ready(); pump(2)
            t.send("first\r")
            check(reached("first"), "the person's first turn ran")
            pump(2)

            # 1. a prompt-type command posted to the inbox runs as a turn.
            r = post("/fleet:probe one")
            check(r is not None and r.get("ok") is True, "inbox command taken and finished (%s)" % r)
            check(reached("PICKUP-PROBE resume with argument: one"),
                  "the posted prompt command reached the model")
            check("no live request" not in t.text(), "no idle-accept drop")
            pump(2)

            # 2. the handoff cycle: /clear, then the pickup, both through the inbox —
            #    comment storage (argument-free pickup), then file storage (the doc path).
            for store, args in (("comment", "pickup"), ("file", "pickup /tmp/handoff-doc.md")):
                pump(2)
                r = post("/clear")
                check(r is not None and r.get("ok") is True, "%s: inbox /clear taken and finished (%s)" % (store, r))
                pump(1.5)
                r = post("/fleet:probe " + args)
                check(r is not None and r.get("ok") is True, "%s: inbox pickup taken and finished (%s)" % (store, r))
                check(reached("PICKUP-PROBE resume with argument: " + args),
                      "%s: the pickup reached the fresh session's model" % store)
                check("no live request" not in t.text(), "%s: no idle-accept drop after /clear" % store)
        finally:
            t.close()
            srv.shutdown(); srv.server_close()
    import subprocess
    print("PASS fleet-handoff-pickup-claude (claude %s)" %
          subprocess.check_output([CLAUDE, "--version"], text=True).split()[0])


if __name__ == "__main__":
    main()
