#!/bin/bash
# fleet-view-hub-fresh-selftest.sh — ⌘P never lists a session reaped on another
# machine because this machine's copy of the hub's list stopped (issue #3079).
#
# ⌘P (bin/fleet_view.py entries → produce → tmux-dashboard-rows.sh) reads the
# other machines' rows from global/remote_<fleet>, which fleet-hub-sessions.sh's
# loop keeps and the collector's tick (re)starts. On 2026-10-10 mini2's node
# supervisor wedged, the collector stopped with it, the file froze, and four
# workers reaped on macmini stayed in mini2's ⌘P.
#
#   A  degenerate — no remote_<fleet> on disk: the list asks the hub nothing
#   B  frozen — the far worker is in the cache, the hub has since dropped it,
#      hub_ok is old and no loop runs: the next open has it gone (one --refresh
#      before the rows) and a loop running after
#   C  fresh — hub_ok within FLEET_VIEW_HUB_FRESH: the open asks the hub nothing
#   D  keepalive — a running loop goes on past its LOOP_SECS while --ensure keeps
#      being called (hubsess.want), and stops LOOP_SECS after the last call
#   E  seen at once (issue #3184) — hub_ok 2 hours old and the hub silent: the
#      popup's red banner names the machine, its rows read 「? 失联 120 分钟」 and
#      are grey end to end, ↵ on one says 进不去 instead of going; hub_ok back to
#      now ⇒ the next read has no banner; a popup left open (a real one, on a pty)
#      shows a row added to the cache within 2-4 s (FLEET_VIEW_REFRESH)
#   F  the first frame never waits on the hub (issue #3311) — hub_ok old, no loop,
#      a hub that takes 6 s: the popup (a real one, on a pty) draws its list from
#      the cache within 1.5 s, and the hub is asked right after, off the screen
#
# `fleet-view-hub-fresh-selftest.sh B` runs one leg (docs/dev/BREAK-IT.md
# view-far-reaped runs B). Drives bin/fleet_view.py through fleet-quickopen.py
# view-rows, the real fleet-hub-sessions.sh and tmux-dashboard-rows.sh; the hub is
# FLEET_HUB_SESSIONS_CMD, tmux a shim with no windows.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'fleet-view-hub-fresh: python3 absent — SKIP'; exit 0; }
LEGS="${1:-ABCDEF}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vhfresh.XXXXXX") || exit 2
cleanup() {
  local p
  for p in $(cat "$WORK/.claude-dash/global/hubsess.lock" "$WORK/.claude-dash/global/hubsess.pid" 2>/dev/null); do
    case "$p" in *[!0-9]*|'') ;; *) kill "$p" 2>/dev/null ;; esac
  done
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$1"; }

unset CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_NODE_ALIASES FLEET_HUB_SESSIONS_USER FLEET_HUB_SESSIONS_STALE \
      TMUX TMUX_PANE FLEET_HUB_URL FLEET_CERT XDG_CONFIG_HOME FLEET_STATUS_G FLEET_VIEW_ROWS_CMD FLEET_VIEW_HUBSESS
S=fl
export TMPDIR="$WORK" HOME="$WORK/home" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh \
       CCQUOTA_FLEET=1 LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
G="$WORK/.claude-dash/global"
mkdir -p "$G" "$HOME" "$WORK/conf/fleets/$S" "$WORK/conf/remote-views" "$WORK/bin" "$WORK/main"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$WORK/conf/fleets/$S/conf"
# 看台 v1, grouped onto fleet fl (the registry row: tty · session · kind · since · pid)
printf '/dev/null\t%s\tthin\t0\t0\n' "$S" > "$WORK/conf/remote-views/v1"
# tmux: a server with no windows; the network tools refuse (the hub is the seam)
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/tmux"
for n in curl wget nc ccquota; do printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/$n"; done
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"

ME=$(id -un)
F=3f0c2a5e-1111-4a6b-9c1d-0123456789ab   # a fleet on another machine
python3 - "$WORK" "$F" "$ME" <<'PY'
import json, os, sys
w, f, me = sys.argv[1:4]
def s(key, name):
    return dict(worker_id=f + "/" + key, machine_name="farbox", os_user=me, fleet_id=f, fleet_name="fleet",
                availability="online", observed_at="2026-10-10T21:50:00Z",
                worker=dict(key=key, state="working", lifecycle="awake", agent="claude", repo="acme/app",
                            issue=int(key.split("-")[1]), name=name, reap="merged"))
nodes = [dict(machine_name="farbox", availability="online", sessions=2, observed_at="2026-10-10T21:50:00Z", age_sec=1)]
both = [s("issue-3058", "弹窗背后刷中文"), s("issue-3061", "断线重连不回显")]
json.dump({"sessions": both, "nodes": nodes}, open(os.path.join(w, "before.json"), "w"), ensure_ascii=False)
json.dump({"sessions": both[1:], "nodes": nodes}, open(os.path.join(w, "after.json"), "w"), ensure_ascii=False)
PY
# the hub: whichever answer is current, every ask logged
printf '#!/bin/sh\necho ask >> "%s/hub.log"\ncat "%s/hub.json"\n' "$WORK" "$WORK" > "$WORK/hub.sh"
export FLEET_HUB_SESSIONS_CMD="sh '$WORK/hub.sh'"
asks() { [ -f "$WORK/hub.log" ] && wc -l < "$WORK/hub.log" | tr -d ' ' || echo 0; }
rows() { python3 "$BIN/fleet-quickopen.py" view-rows --view v1 2>/dev/null; }
HUBS="$BIN/fleet-hub-sessions.sh"
loop_alive() { bash "$HUBS" --status 2>/dev/null | grep -q '^loop [0-9]'; }
stop_loop() {
  local p
  for p in $(cat "$G/hubsess.lock" "$G/hubsess.pid" 2>/dev/null); do
    case "$p" in *[!0-9]*|'') ;; *) kill "$p" 2>/dev/null ;; esac
  done
  for _ in 1 2 3 4 5 6 7 8 9 10; do loop_alive || break; sleep 0.3; done
  rm -f "$G/hubsess.pid" "$G/hubsess.want"
}
# the state the 2026-10-10 incident left: a cache taken while #3058 was alive,
# hub_ok 16 minutes old, no loop (its collector stopped)
frozen() {
  cp "$WORK/before.json" "$WORK/hub.json"
  bash "$HUBS" --refresh 2>/dev/null || fail "setup: --refresh failed"
  grep -q "$F/issue-3058" "$G/remote_$S" 2>/dev/null || fail "setup: the far worker is not in the cache" "$(cat "$G/remote_$S" 2>/dev/null)"
  echo $(( $(date +%s) - 960 )) > "$G/hub_ok"
  cp "$WORK/after.json" "$WORK/hub.json"   # macmini reaped #3058; the hub knows
  : > "$WORK/hub.log"
}

case "$LEGS" in *A*)
  rm -f "$G/remote_$S" "$G/hub_ok"; : > "$WORK/hub.log"; cp "$WORK/before.json" "$WORK/hub.json"
  rows >/dev/null
  [ "$(asks)" = 0 ] || fail "A: no remote cache, yet the list asked the hub ($(asks)×)"
  [ ! -e "$G/remote_$S" ] || fail "A: no remote cache, yet one was written"
  loop_alive && fail "A: no remote cache, yet a loop was started"
  pass "A: no remote_<fleet> — the list asks the hub nothing, starts nothing"
;; esac

case "$LEGS" in *B*)
  frozen
  r=$(FLEET_VIEW_HUB_FRESH=10 rows)
  printf '%s\n' "$r" | grep -q '断线重连不回显' || fail "B: the live far worker is not listed" "$r"
  printf '%s\n' "$r" | grep -q '弹窗背后刷中文' && fail "B: ⌘P still lists #3058, reaped on macmini (the cache froze with it)" "$r"
  [ "$(asks)" -ge 1 ] || fail "B: the open did not ask the hub"
  for _ in 1 2 3 4 5 6 7 8 9 10; do loop_alive && break; sleep 0.3; done
  loop_alive || fail "B: no loop running after the open"
  stop_loop
  pass "B: a frozen cache (hub_ok 16 min old, no loop) — the next open drops the reaped far worker and starts the loop"
;; esac

case "$LEGS" in *C*)
  frozen; date +%s > "$G/hub_ok"
  r=$(rows)
  [ "$(asks)" = 0 ] || fail "C: hub_ok fresh, yet the open asked the hub ($(asks)×)"
  printf '%s\n' "$r" | grep -q '弹窗背后刷中文' || fail "C: a fresh cache's row went missing" "$r"
  loop_alive && fail "C: hub_ok fresh, yet a loop was started"
  pass "C: hub_ok fresh — the open reads the cache as it is, asks nothing"
;; esac

case "$LEGS" in *D*)
  cp "$WORK/after.json" "$WORK/hub.json"
  export FLEET_HUB_SESSIONS_LOOP_SECS=3 FLEET_HUB_SESSIONS_EVERY=1
  bash "$HUBS" --ensure
  for _ in 1 2 3 4 5 6 7 8 9 10; do loop_alive && break; sleep 0.3; done
  loop_alive || fail "D: --ensure started no loop"
  p0=$(bash "$HUBS" --status | awk '{ print $2 }')
  for _ in 1 2 3 4 5 6; do sleep 1; bash "$HUBS" --ensure; done
  p1=$(bash "$HUBS" --status | awk '{ print $2 }')
  [ "$p1" = "$p0" ] || fail "D: the loop ended under a caller still calling --ensure (pid $p0 → ${p1:-none}) — the gap the collector's tick fell into"
  for _ in $(seq 1 20); do loop_alive || break; sleep 0.5; done
  loop_alive && fail "D: the loop outlived its last --ensure by more than LOOP_SECS"
  unset FLEET_HUB_SESSIONS_LOOP_SECS FLEET_HUB_SESSIONS_EVERY
  pass "D: one loop for as long as --ensure is called; gone LOOP_SECS after the last"
;; esac
case "$LEGS" in *E*)
  cp "$WORK/before.json" "$WORK/hub.json"
  bash "$HUBS" --refresh 2>/dev/null || fail "E setup: --refresh failed"
  printf '#!/bin/sh\necho ask >> "%s/hub.log"\nexit 1\n' "$WORK" > "$WORK/hub.sh"   # the hub goes silent
  echo $(( $(date +%s) - 7200 )) > "$G/hub_ok"
  out=$(FLEET_UI_LANG=zh FLEET_VIEW_HUB_REFRESH_SECS=2 python3 - "$BIN" <<'PY2'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fv", sys.argv[1] + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
bad = []
def chk(what, got, want):
    if got != want:
        bad.append("%s: %r, want %r" % (what, got, want))
items = fv.entries("v1")
far = [e for e in items if e["kind"] == "sess" and e.get("far")]
chk("far rows listed", len(far) >= 1, True)
ban = fv.banner(items)
chk("banner names the machine and the minutes", ("farbox" in ban, "120 分钟没更新" in ban, "正在重连" in ban), (True, True, True))
for e in far:
    chk("lost", e.get("lost"), True)
    chk("tag 「? 失联 120 分钟」", "? 失联 120 分钟" in e["tags"], True)
    chk("↵ says 进不去", "进不去" in (fv.lost_msg(e) or ""), True)
    for lit in (False, True):
        segs = fv.paint([e], 0 if lit else -1, 100, len, lambda t, n: t[:n])[0]
        if not lit:
            chk("grey end to end", all("dim" in st for _, st in segs), True)
        chk("no colour on a lost glyph (lit=%s)" % lit, any(k.startswith("c") for k in segs[1][1]), False)
print("\n".join(bad) or "ok")
PY2
)
  [ "$out" = ok ] || fail "E: a frozen list (hub_ok 2 h old, the hub silent) is not seen at once" "$out"
  stop_loop
  date +%s > "$G/hub_ok"
  b=$(FLEET_UI_LANG=zh python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fv", sys.argv[1] + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
print(repr(fv.banner(fv.entries("v1"))))' "$BIN")
  [ "$b" = "''" ] || fail "E: hub_ok back to now, yet the banner stays" "$b"
  # a popup left open, on a real pty: a row added to the cache appears within 2-4 s
  r=$(FLEET_UI_LANG=zh FLEET_VIEW_REFRESH=2 TERM=xterm-256color python3 - "$BIN" "$G/remote_$S" <<'PY2'
import os, pty, select, sys, time
binp, cache = sys.argv[1:3]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("python3", ["python3", binp + "/fleet-quickopen.py", "--view", "v1"])
def read_until(word, secs):
    buf, end = b"", time.monotonic() + secs
    while time.monotonic() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                buf += os.read(fd, 65536)
            except OSError:
                break
            if word in buf:
                return True
    return False
try:
    if not read_until("断线重连不回显".encode(), 10):
        print("the popup never drew its list"); sys.exit(0)
    time.sleep(0.3)
    lines = open(cache, encoding="utf-8").read().splitlines()
    src = next(l for l in lines if "issue-3061" in l)
    open(cache, "a", encoding="utf-8").write(src.replace("issue-3061", "issue-3099").replace("3061", "3099")
                                             .replace("断线重连不回显", "zz-new-row") + "\n")
    t0 = time.monotonic()
    seen = read_until(b"zz-new-row", 6)
    dt = time.monotonic() - t0
    print("ok" if seen and dt <= 4.5 else "seen=%s after %.1fs" % (seen, dt))
finally:
    os.write(fd, b"\x1b")
    time.sleep(0.3)
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    os.close(fd)   # macOS: an exiting child waits on its pty's unread output
    os.waitpid(pid, 0)
PY2
)
  [ "$r" = ok ] || fail "E: a popup left open did not show the new row in time" "$r"
  pass "E: hub_ok 2 h old — banner, grey 「? 失联 120 分钟」 rows, ↵ 进不去; back to now — no banner; an open popup shows a new row within 2-4 s"
;; esac
case "$LEGS" in *F*)
  printf '#!/bin/sh\necho ask >> "%s/hub.log"\ncat "%s/hub.json"\n' "$WORK" "$WORK" > "$WORK/hub.sh"   # E left it silent
  frozen; cp "$WORK/before.json" "$WORK/hub.json"
  printf '#!/bin/sh\necho ask >> "%s/hub.log"\nsleep 6\ncat "%s/hub.json"\n' "$WORK" "$WORK" > "$WORK/hub.sh"   # a slow hub
  r=$(FLEET_UI_LANG=zh FLEET_VIEW_REFRESH=2 TERM=xterm-256color python3 - "$BIN" "$WORK/hub.log" <<'PY2'
import os, pty, select, sys, time
binp, log = sys.argv[1:3]
t0 = time.monotonic()
pid, fd = pty.fork()
if pid == 0:
    os.execvp("python3", ["python3", binp + "/fleet-quickopen.py", "--view", "v1"])
def read_until(word, secs):
    buf, end = b"", time.monotonic() + secs
    while time.monotonic() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                buf += os.read(fd, 65536)
            except OSError:
                break
            if word in buf:
                return True
    return False
def asked():
    try:
        return sum(1 for _ in open(log))
    except OSError:
        return 0
try:
    seen = read_until("弹窗背后刷中文".encode(), 10)
    dt = time.monotonic() - t0
    end = time.monotonic() + 4
    while asked() < 1 and time.monotonic() < end:
        time.sleep(0.1)
    print("ok" if seen and dt <= 1.5 and asked() >= 1 else "drawn=%s after %.1fs, hub asked %d×" % (seen, dt, asked()))
finally:
    os.write(fd, b"\x1b")
    time.sleep(0.3)
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    os.close(fd)
    os.waitpid(pid, 0)
PY2
)
  [ "$r" = ok ] || fail "F: the popup's first frame waited on a slow hub (or never asked it)" "$r"
  stop_loop
  pass "F: hub_ok old, a 6 s hub — the popup draws the cache at once, the hub is asked behind it"
;; esac
echo "PASS fleet-view-hub-fresh-selftest ($LEGS)"
