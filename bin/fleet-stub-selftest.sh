#!/bin/bash
# fleet-stub-selftest.sh — a new session's stub (T992, bin/fleet_stub.py +
# bin/fleet-stub.sh) on an isolated tmux server: its window is on the screen
# within the budget, it takes keys at once, and every word typed in it reaches
# the agent once the agent keeps a paste — queued lines submitted, the unsent
# line left unsent. A failure stays on it; a stub the person closed takes the
# 看台 nowhere; another machine's session keeps the words as a notice.
#   A  the first frame: p50 ≤ FLEET_STUB_SELFTEST_MS (100), p90 ≤ 3× it (of 10)
#   B  keys before the agent: CJK, ⌫, ⌃U, a paste with lines, ↵ queues
#   C  the handoff: in band (no key lost), waits for 7501 idle, pastes, submits
#   D  failure: `✗ …` stays on the stub; the road gone with no word is said
#   E  closed by the person (esc esc): handoff → False, nothing pasted
#   F  another machine (far): frozen, words carried; `fleet_stub.py deliver` there
#      pastes them; words that never land are kept as a notice
#   G  fleet_view: go() runs the handoff once, closes the stub, FLEET_STUB=0 = the old road
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/stub-selftest.XXXXXX") || exit 2
export FLEET_CONF_DIR="$WORK/conf" TMUX_TMPDIR="$WORK/tmt" LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
mkdir -p "$FLEET_CONF_DIR" "$TMUX_TMPDIR"
unset TMUX TMUX_PANE FLEET_STUB
SOCK=stubtest
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
command -v tmux >/dev/null || { echo "skip: no tmux"; exit 0; }
tmux -L "$SOCK" new-session -d -s fleet -n home -x 120 -y 40 'sleep 3600' || { echo "FAIL could not start tmux"; exit 1; }
tmux -L "$SOCK" new-session -d -t fleet -s 'fleet@view-v1' || { echo "FAIL could not group a 看台"; exit 1; }
# a fake agent: its prompt `❯ ` (cursor after it, as Claude's), the 7501 relay's
# word on its window after READY_AFTER seconds, every line it gets written down
cat >"$WORK/agent.sh" <<'EOF'
#!/usr/bin/env python3
# raw input with bracketed paste on, as an agent's TUI: every byte written down
import os, subprocess, sys, termios, time, tty
time.sleep(float(os.environ.get("READY_AFTER") or 1))
tty.setraw(0)
os.write(1, b"\033[?2004h\033[H\033[2J\xe2\x9d\xaf ")
subprocess.run(["tmux", "-L", os.environ["SOCK"], "set-option", "-w", "-t", os.environ["TMUX_PANE"],
                "@agent_status", '{"state":"idle","app":"claude-code"}'])
with open(os.environ["GOT"], "ab", buffering=0) as got:
    while True:
        b = os.read(0, 4096)
        if not b:
            break
        got.write(b)
        # echoed as a TUI's input does (a paste that shows is not re-pasted);
        # ↵ outside a paste submits: the input is empty again
        shown = b.replace(b"\033[200~", b"").replace(b"\033[201~", b"")
        if shown == b"\r":
            os.write(1, b"\033[H\033[2J\xe2\x9d\xaf ")
        else:
            os.write(1, shown.replace(b"\r", b"\xe2\x8f\x8e"))
EOF
chmod +x "$WORK/agent.sh"
PYTHONDONTWRITEBYTECODE=1 SOCK="$SOCK" WORK="$WORK" python3 - "$BIN" <<'PY'
import json, os, subprocess, sys, time
from pathlib import Path
BIN, SOCK, WORK = sys.argv[1], os.environ["SOCK"], os.environ["WORK"]
sys.path.insert(0, BIN)
import fleet_stub
fails = []
def ok(cond, what):
    print(("ok   " if cond else "FAIL ") + what, flush=True)
    if not cond:
        fails.append(what)
def tm(*args, timeout=5):
    p = subprocess.run(["tmux", "-L", SOCK] + list(args), capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout.rstrip("\n")
def cap(w):
    return tm("capture-pane", "-p", "-t", w)[1]
def until(pred, secs=5.0):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.01)
    return False
def keys(w, *k, lit=True):
    tm("send-keys", "-t", w, *(["-l"] if lit else []), *k)
    time.sleep(0.05)
G = "fleet@view-v1"
def agent(ready_after=1):
    got = os.path.join(WORK, "got.%d" % time.time_ns())
    rc, w = tm("new-window", "-d", "-t", "=fleet:", "-P", "-F", "#{window_id}", "-e", "SOCK=" + SOCK,
               "-e", "GOT=" + got, "-e", "READY_AFTER=%s" % ready_after, os.path.join(WORK, "agent.sh"))
    pane = tm("display-message", "-p", "-t", w, "#{pane_id}")[1]
    return w, pane, got

# A — the first frame
budget = float(os.environ.get("FLEET_STUB_SELFTEST_MS") or 100)
times = []
for _ in range(10):
    t0 = time.time()
    w, d = fleet_stub.start(tm, G, "repo · Claude", t0)
    ms = fleet_stub.shown(tm, d, t0)
    times.append(ms if ms is not None else 1e9)
    if _ < 9:
        fleet_stub.close(tm, d)
times.sort()
# the median against the promise, the 九成 against three times it: a shared CI
# box stalls a run now and then (the production promise — the 九成五 of real ↵s —
# is fleet_timing.py check's `shown`, the doctor's timing row)
ok(times[4] <= budget and times[8] <= 3 * budget,
   "A first frame p50 %.0f ms ≤ %.0f, p90 %.0f ≤ %.0f (all: %s)" % (times[4], budget, times[8], 3 * budget,
                                                                [round(t) for t in times]))
cur = tm("display-message", "-p", "-t", "=%s:" % G, "#{window_id}")[1]
ok(cur == w, "A the stub is the 看台's window (%s == %s)" % (cur, w))
ok(tm("display-message", "-p", "-t", w, "#{@fleet_role}")[1] == "panel", "A the stub is a panel, never a session")
ok(tm("display-message", "-p", "-t", "=fleet:", "#{window_name}")[1] != "new", "A the fleet's own session stays where it was")
rows = [json.loads(l) for l in open(os.path.join(os.environ["FLEET_CONF_DIR"], "timing", "session.ndjson"))]
ok(sum(1 for r in rows if r["seg"] == "shown") == 10, "A `shown` clocked under the ↵'s run, once each")

# B — keys before the agent
keys(w, "你好 world"); keys(w, "Enter", lit=False)
keys(w, "junk"); keys(w, "C-u", lit=False)
keys(w, "second lineX"); keys(w, "BSpace", lit=False)
tm("set-buffer", "-b", "st", "p1\np2"); tm("paste-buffer", "-p", "-b", "st", "-t", w)
ok(until(lambda: "second linep1⏎p2" in cap(w)), "B the line: CJK, ⌫, ⌃U, a paste's lines kept")
ok("1" in cap(w) and ("已排队" in cap(w) or "queued" in cap(w)), "B ↵ queues the line")

# C — the handoff
aw, pane, got = agent(ready_after=1)
fleet_stub.note_road(d, os.getpid())
t = time.monotonic()
keys(w, " tail")       # typed right before the freeze: still taken (in band)
res = fleet_stub.handoff(tm, d, pane, secs=20)
ok(res is True, "C handoff → True")
ok(time.monotonic() - t >= 0.9, "C it waited for the agent's 7501 idle")
raw = lambda: open(got, "rb").read().decode("utf-8", "replace") if os.path.exists(got) else ""
ok(until(lambda: raw().startswith("\x1b[200~你好 world\x1b[201~\r")), "C the queued line reached the agent, pasted once + submitted: %r" % raw())
ok(until(lambda: raw().endswith("\r\x1b[200~second linep1\rp2 tail\x1b[201~")),
   "C the unsent line is in its input, its line kept, not submitted: %r" % raw()[-60:])
fleet_stub.close(tm, d)
ok(tm("display-message", "-p", "-t", w, "#{window_id}")[0] != 0 or tm("display-message", "-p", "-t", w, "#{window_id}")[1] != w,
   "C close: the stub's window is gone")
ok(not os.path.exists(d), "C close: its dir is gone")

# D — failure
w, d = fleet_stub.start(tm, G, "repo · Claude", time.time())
fleet_stub.note_road(d, os.getpid())
fleet_stub.status(tm, d, "✗ 新会话没有开出来：hub 不可达")
ok(until(lambda: "hub 不可达" in cap(w)), "D the failure is on the stub")
time.sleep(1.2)
ok(fleet_stub.alive(tm, d), "D it stays (esc ×2 closes it)")
fleet_stub.close(tm, d)
dead = subprocess.Popen(["true"]); dead.wait()
w, d = fleet_stub.start(tm, G, "repo · Claude", time.time())
fleet_stub.note_road(d, dead.pid)
ok(until(lambda: "启动进程已退出" in cap(w) or "ended without" in cap(w), 6), "D the road gone with no word: said")
fleet_stub.close(tm, d)

# E — closed by the person
w, d = fleet_stub.start(tm, G, "repo · Claude", time.time())
keys(w, "never sent")
tm("send-keys", "-t", w, "Escape"); tm("send-keys", "-t", w, "Escape")
ok(until(lambda: not fleet_stub.alive(tm, d), 4), "E esc esc closes the stub")
aw, pane, got = agent(ready_after=0)
ok(fleet_stub.handoff(tm, d, pane, secs=5) is False, "E handoff → False: the 看台 stays put")
time.sleep(0.5)
ok("never sent" not in (open(got, "rb").read().decode() if os.path.exists(got) else ""), "E nothing pasted")
fleet_stub.close(tm, d)

# F — another machine
w, d = fleet_stub.start(tm, G, "repo · Claude", time.time())
keys(w, "for far")
sys.path.insert(0, BIN)
import fleet_view
fleet_view._SOCK[0] = SOCK
went, far_words = fleet_view.stub_handoff(d, "", True)
ok(went is True and far_words == ([], "for far"), "F far: the switch goes on, the words carried: %r" % (far_words,))
# the far half, as fleet-remote-view.sh deliver runs it on the session's machine
aw, pane, got = agent(ready_after=1)
p = subprocess.run([sys.executable, os.path.join(BIN, "fleet_stub.py"), "deliver", "--socket", SOCK, "--pane", pane],
                   input=json.dumps({"queued": ["far one"], "unsent": "far two"}), text=True, timeout=60)
raw = lambda: open(got, "rb").read().decode("utf-8", "replace") if os.path.exists(got) else ""
ok(p.returncode == 0 and until(lambda: raw() == "\x1b[200~far one\x1b[201~\r\x1b[200~far two\x1b[201~"),
   "F far: deliver there submits the queued line, leaves the unsent one: %r" % raw())
fleet_stub.keep(d, far_words)
notes = Path(os.environ["FLEET_CONF_DIR"]).rglob("*.ndjson")
ok(any("for far" in p.read_text(encoding="utf-8", errors="replace") for p in notes), "F far: words that never landed kept as a notice")
fleet_stub.close(tm, d)

# G — go() hands off once and closes the stub; FLEET_STUB=0 is the old road
w, d = fleet_stub.start(tm, G, "repo · Claude", time.time())
keys(w, "via go"); keys(w, "Enter", lit=False)
aw, pane, got = agent(ready_after=0)
fleet_view.view_row = lambda vid, *a: {}
fleet_view.view_fleet = lambda vid, *a: "fleet"
fleet_view.resolve = lambda vid, target, row, fleet: (target, False)
fleet_view.webterm_switch = lambda vid, w: None
fleet_view.hist_save = lambda *a: None
fleet_view.hist_load = lambda *a: {}
fleet_view.log_switch = lambda rec: None
class QO:
    @staticmethod
    def visit(h, k): return h
os.environ["FLEET_STUB_DIR"] = d
rc = fleet_view.go(QO, "v1", aw, "new")
ok(rc == 0, "G go() → 0")
ok("FLEET_STUB_DIR" not in os.environ, "G the stub is handed off once")
ok(until(lambda: "via go\x1b[201~\r" in (open(got, "rb").read().decode() if os.path.exists(got) else "")),
   "G go(): the queued line reached the agent")
ok(tm("display-message", "-p", "-t", "=%s:" % G, "#{window_id}")[1] == aw, "G go(): the 看台 is on the session")
ok(not os.path.exists(d), "G go(): the stub is closed")
os.environ["FLEET_STUB"] = "0"
ok(fleet_view.bolt_stub("v1", "", ["x", "--t0", str(time.time())], "w") is False, "G FLEET_STUB=0: no stub")
os.environ.pop("FLEET_STUB")
ok(fleet_view.bolt_stub("wt-1", "", ["x"], "w") is False, "G a browser 看台: no stub")
sys.exit(1 if fails else 0)
PY
rc=$?
[ $rc -eq 0 ] && echo "PASS fleet-stub-selftest" || echo "FAIL fleet-stub-selftest"
exit $rc
