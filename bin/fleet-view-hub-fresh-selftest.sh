#!/bin/bash
# fleet-view-hub-fresh-selftest.sh — ⌘P never lists a session reaped on another
# machine because this machine's copy of the hub's list stopped (issue #3079).
#
# ⌘P (bin/fleet_view.py entries → produce → tmux-dashboard-rows.sh) reads the
# other machines' rows from global/remote_<fleet>, which fleet-hub-sessions.sh's
# loop keeps and the collector's tick (re)starts. On 2026-10-10 mac-d's node
# supervisor wedged, the collector stopped with it, the file froze, and four
# workers reaped on mac-c stayed in mac-d's ⌘P.
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
#   G  a viewer keeps the loop — no --ensure for longer than LOOP_SECS while the
#      list is read (global/hubsess.view touched): the same loop lives on and
#      hub_ok keeps advancing; the reads stop ⇒ gone LOOP_SECS later; a view stamp
#      in the future extends nothing (a node at load 27-43: the collector's ticks
#      overran, no --ensure came for 70 s, and the loop ended under a ⌘P read)
#   H  the loop's log (logs/hubsess.log): a start line, one line per round (rc,
#      ms, watched), and an exit line saying why — lifetime · replaced by other
#      code · term · guard gone — with no URL in it
#   I  hub_fresh never kills — an --ensure and a --refresh that take 3 s: the
#      popup waits ≤ FLEET_VIEW_HUB_REFRESH_SECS + _ENSURE_SECS (1 s each) and returns, both run to
#      their end after it; a second ask while that --refresh runs starts no
#      second one
#
# `fleet-view-hub-fresh-selftest.sh B` runs one leg (docs/dev/BREAK-IT.md
# view-far-reaped runs B, hubsess-viewer-keeps-loop runs G). Drives bin/fleet_view.py through fleet-quickopen.py
# view-rows, the real fleet-hub-sessions.sh and tmux-dashboard-rows.sh; the hub is
# FLEET_HUB_SESSIONS_CMD, tmux a shim with no windows.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
command -v python3 >/dev/null 2>&1 || { echo 'fleet-view-hub-fresh: python3 absent — SKIP'; exit 0; }
LEGS="${1:-ABCDEFGHI}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vhfresh.XXXXXX") || exit 2
cleanup() {
  local p
  for p in $(cat "$WORK/.claude-dash/global/hubsess.lock" "$WORK/.claude-dash/global/hubsess.pid" 2>/dev/null); do
    case "$p" in *[!0-9]*|'') ;; *) kill "$p" 2>/dev/null ;; esac
  done
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
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
st_fake_tmux "$WORK/bin"
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
  bash "$HUBS" --refresh 2>/dev/null || st_fail "setup: --refresh failed"
  grep -q "$F/issue-3058" "$G/remote_$S" 2>/dev/null || st_fail "setup: the far worker is not in the cache" "$(cat "$G/remote_$S" 2>/dev/null)"
  echo $(( $(date +%s) - 960 )) > "$G/hub_ok"
  cp "$WORK/after.json" "$WORK/hub.json"   # mac-c reaped #3058; the hub knows
  : > "$WORK/hub.log"
}

case "$LEGS" in *A*)
  rm -f "$G/remote_$S" "$G/hub_ok"; : > "$WORK/hub.log"; cp "$WORK/before.json" "$WORK/hub.json"
  rows >/dev/null
  [ "$(asks)" = 0 ] || st_fail "A: no remote cache, yet the list asked the hub ($(asks)×)"
  [ ! -e "$G/remote_$S" ] || st_fail "A: no remote cache, yet one was written"
  loop_alive && st_fail "A: no remote cache, yet a loop was started"
  pass "A: no remote_<fleet> — the list asks the hub nothing, starts nothing"
;; esac

case "$LEGS" in *B*)
  frozen
  r=$(FLEET_VIEW_HUB_FRESH=10 rows)
  printf '%s\n' "$r" | grep -q '断线重连不回显' || st_fail "B: the live far worker is not listed" "$r"
  printf '%s\n' "$r" | grep -q '弹窗背后刷中文' && st_fail "B: ⌘P still lists #3058, reaped on mac-c (the cache froze with it)" "$r"
  [ "$(asks)" -ge 1 ] || st_fail "B: the open did not ask the hub"
  for _ in 1 2 3 4 5 6 7 8 9 10; do loop_alive && break; sleep 0.3; done
  loop_alive || st_fail "B: no loop running after the open"
  stop_loop
  pass "B: a frozen cache (hub_ok 16 min old, no loop) — the next open drops the reaped far worker and starts the loop"
;; esac

case "$LEGS" in *C*)
  frozen; date +%s > "$G/hub_ok"
  r=$(rows)
  [ "$(asks)" = 0 ] || st_fail "C: hub_ok fresh, yet the open asked the hub ($(asks)×)"
  printf '%s\n' "$r" | grep -q '弹窗背后刷中文' || st_fail "C: a fresh cache's row went missing" "$r"
  loop_alive && st_fail "C: hub_ok fresh, yet a loop was started"
  pass "C: hub_ok fresh — the open reads the cache as it is, asks nothing"
;; esac

case "$LEGS" in *D*)
  cp "$WORK/after.json" "$WORK/hub.json"
  export FLEET_HUB_SESSIONS_LOOP_SECS=3 FLEET_HUB_SESSIONS_EVERY=1
  bash "$HUBS" --ensure
  for _ in 1 2 3 4 5 6 7 8 9 10; do loop_alive && break; sleep 0.3; done
  loop_alive || st_fail "D: --ensure started no loop"
  p0=$(bash "$HUBS" --status | awk '{ print $2 }')
  for _ in 1 2 3 4 5 6; do sleep 1; bash "$HUBS" --ensure; done
  p1=$(bash "$HUBS" --status | awk '{ print $2 }')
  [ "$p1" = "$p0" ] || st_fail "D: the loop ended under a caller still calling --ensure (pid $p0 → ${p1:-none}) — the gap the collector's tick fell into"
  for _ in $(seq 1 20); do loop_alive || break; sleep 0.5; done
  loop_alive && st_fail "D: the loop outlived its last --ensure by more than LOOP_SECS"
  unset FLEET_HUB_SESSIONS_LOOP_SECS FLEET_HUB_SESSIONS_EVERY
  pass "D: one loop for as long as --ensure is called; gone LOOP_SECS after the last"
;; esac
case "$LEGS" in *E*)
  cp "$WORK/before.json" "$WORK/hub.json"
  bash "$HUBS" --refresh 2>/dev/null || st_fail "E setup: --refresh failed"
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
  [ "$out" = ok ] || st_fail "E: a frozen list (hub_ok 2 h old, the hub silent) is not seen at once" "$out"
  stop_loop
  date +%s > "$G/hub_ok"
  b=$(FLEET_UI_LANG=zh python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fv", sys.argv[1] + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
print(repr(fv.banner(fv.entries("v1"))))' "$BIN")
  [ "$b" = "''" ] || st_fail "E: hub_ok back to now, yet the banner stays" "$b"
  # no other machine's row to name (issue #4902): the line still says how long the
  # hub — what a row's PR is read off — has not answered, and goes when it does
  echo $(( $(date +%s) - 7200 )) > "$G/hub_ok"
  b=$(FLEET_UI_LANG=zh python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fv", sys.argv[1] + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
print(fv.banner([]))' "$BIN")
  [ "$b" = "入口 120 分钟没响应 · 正在重连" ] || st_fail "E: a silent hub with no far row says nothing" "$b"
  date +%s > "$G/hub_ok"
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
  [ "$r" = ok ] || st_fail "E: a popup left open did not show the new row in time" "$r"
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
  [ "$r" = ok ] || st_fail "F: the popup's first frame waited on a slow hub (or never asked it)" "$r"
  stop_loop
  pass "F: hub_ok old, a 6 s hub — the popup draws the cache at once, the hub is asked behind it"
;; esac
case "$LEGS" in *G*)
  stop_loop
  printf '#!/bin/sh\necho ask >> "%s/hub.log"\ncat "%s/hub.json"\n' "$WORK" "$WORK" > "$WORK/hub.sh"
  cp "$WORK/after.json" "$WORK/hub.json"
  export FLEET_HUB_SESSIONS_LOOP_SECS=3 FLEET_HUB_SESSIONS_EVERY=1
  okv() { cut -d' ' -f1 "$G/hub_ok" 2>/dev/null || echo 0; }
  bash "$HUBS" --ensure; touch "$G/hubsess.view"
  for _ in 1 2 3 4 5 6 7 8 9 10; do loop_alive && break; sleep 0.3; done
  loop_alive || st_fail "G: --ensure started no loop"
  p0=$(bash "$HUBS" --status | awk '{ print $2 }'); touch "$G/hubsess.view"
  ok0=$(okv)
  # 8 s of reads and no --ensure: more than twice LOOP_SECS past the last stamp
  # (a read every half second: a loaded box must not make the drill's own gap)
  for _ in $(seq 1 16); do sleep 0.5; touch "$G/hubsess.view"; done
  p1=$(bash "$HUBS" --status | awk '{ print $2 }')
  [ "$p1" = "$p0" ] || st_fail "G: the loop ended under a viewer still reading the list (pid $p0 → ${p1:-none}, no --ensure for 8 s, LOOP_SECS 3)" "$(tail -5 "$WORK/conf/logs/hubsess.log" 2>/dev/null)"
  ok1=$(okv)
  [ "$ok1" -gt "$ok0" ] && [ "$ok1" -ge $(( $(date +%s) - 2 )) ] \
    || st_fail "G: hub_ok did not keep advancing while the list was read ($ok0 → $ok1, now $(date +%s))"
  for _ in $(seq 1 20); do loop_alive || break; sleep 0.5; done
  loop_alive && st_fail "G: the reads stopped, yet the loop outlived the stale view stamp by more than LOOP_SECS"
  # a stamp in the future would keep it for ever: it extends nothing
  python3 -c 'import os, sys, time; t = time.time() + 3600; os.utime(sys.argv[1], (t, t))' "$G/hubsess.view"
  bash "$HUBS" --ensure
  for _ in 1 2 3 4 5 6 7 8 9 10; do loop_alive && break; sleep 0.3; done
  for _ in $(seq 1 20); do loop_alive || break; sleep 0.5; done
  loop_alive && st_fail "G: a view stamp an hour in the future kept the loop past LOOP_SECS"
  touch "$G/hubsess.view"
  unset FLEET_HUB_SESSIONS_LOOP_SECS FLEET_HUB_SESSIONS_EVERY
  pass "G: a viewer reading the list keeps the loop (no --ensure for 8 s, LOOP_SECS 3) and hub_ok advancing; stale or future stamps extend nothing"
;; esac
case "$LEGS" in *H*)
  stop_loop
  printf '#!/bin/sh\necho ask >> "%s/hub.log"\ncat "%s/hub.json"\n' "$WORK" "$WORK" > "$WORK/hub.sh"
  cp "$WORK/after.json" "$WORK/hub.json"
  LOG="$WORK/conf/logs/hubsess.log"; rm -f "$LOG"
  export FLEET_HUB_SESSIONS_LOOP_SECS=2 FLEET_HUB_SESSIONS_EVERY=1
  lp() { bash "$HUBS" --status | awk '{ print $2 }'; }
  start_loop() { bash "$HUBS" --ensure; for _ in 1 2 3 4 5 6 7 8 9 10; do loop_alive && break; sleep 0.3; done; }
  gone() { for _ in $(seq 1 30); do loop_alive || return 0; sleep 0.3; done; return 1; }
  start_loop; gone || st_fail "H: a 2 s loop did not end"
  # replaced by other code: the running loop's stamp says other code, an --ensure comes
  export FLEET_HUB_SESSIONS_LOOP_SECS=30
  start_loop; sleep 0.5; echo other-code > "$G/hubsess.loopcode"; bash "$HUBS" --ensure; sleep 1
  # term: a plain TERM to the loop
  p=$(lp); kill "$p" 2>/dev/null; gone || st_fail "H: TERM did not end the loop"
  # guard gone: the lock's parent SIGKILLed, the loop notices at its next round
  start_loop; p=$(lp); pp=$(ps -o ppid= -p "$p" | tr -d ' ')
  kill -9 "$pp" 2>/dev/null
  for _ in $(seq 1 30); do kill -0 "$p" 2>/dev/null || break; sleep 0.3; done
  kill -0 "$p" 2>/dev/null && st_fail "H: the loop outlived its lock parent"
  unset FLEET_HUB_SESSIONS_LOOP_SECS FLEET_HUB_SESSIONS_EVERY
  [ -s "$LOG" ] || st_fail "H: no logs/hubsess.log"
  for w in 'start life=2s code=' 'round rc=200 ms=' 'watched=no' 'exit reason=lifetime up=' \
           'ensure: no loop — starting one' 'exit reason=replaced by other code' 'exit reason=term' \
           'exit reason=guard gone' 'want_age=' 'view_age='; do
    grep -qF -- "$w" "$LOG" || st_fail "H: the log has no «${w}» line" "$(cat "$LOG")"
  done
  grep -qiE 'https?:|bearer|token' "$LOG" && st_fail "H: the log carries a URL or a credential word" "$(cat "$LOG")"
  pass "H: logs/hubsess.log — start, every round (rc · ms · watched), exit with its reason (lifetime · replaced · term · guard gone), no URL"
;; esac
case "$LEGS" in *I*)
  stop_loop
  echo $(( $(date +%s) - 600 )) > "$G/hub_ok"
  printf '#!/bin/sh\necho "$1 start" >> "%s/slow.log"\nsleep 3\necho "$1 end" >> "%s/slow.log"\n' "$WORK" "$WORK" > "$WORK/slowhs.sh"
  : > "$WORK/slow.log"; rm -f "$G/hubsess.refresh.pid"
  out=$(FLEET_VIEW_HUBSESS="$WORK/slowhs.sh" FLEET_VIEW_HUB_REFRESH_SECS=1 FLEET_VIEW_HUB_ENSURE_SECS=1 python3 - "$BIN" "$S" <<'PY2'
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("fv", sys.argv[1] + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
t = time.monotonic(); fv.hub_fresh(sys.argv[2]); a = time.monotonic() - t
t = time.monotonic(); fv.hub_fresh(sys.argv[2]); b = time.monotonic() - t
print("%.1f %.1f" % (a, b))
PY2
)
  set -- $out
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 3 and float(sys.argv[2]) < 3 else 1)' "${1:-9}" "${2:-9}" \
    || st_fail "I: hub_fresh waited past FLEET_VIEW_HUB_REFRESH_SECS + _ENSURE_SECS on a slow --refresh / --ensure ($out)"
  sleep 5
  st=$(sort "$WORK/slow.log" | uniq -c | awk '{ print $2 "×" $1 "/" $3 }' | sort | tr '\n' ' ')
  [ "$(grep -c -- '--refresh start' "$WORK/slow.log")" = 1 ] || st_fail "I: a second ask stacked a second --refresh" "$st"
  [ "$(grep -c -- '--refresh end' "$WORK/slow.log")" = 1 ] || st_fail "I: the --refresh was killed at the popup's wait" "$st"
  [ "$(grep -c -- '--ensure end' "$WORK/slow.log")" = 2 ] || st_fail "I: an --ensure was killed at the popup's wait" "$st"
  pass "I: hub_fresh waits ≤1 s each on a 3 s --refresh / --ensure and kills neither; a second ask waits on the running --refresh"
;; esac
echo "PASS fleet-view-hub-fresh-selftest ($LEGS)"
