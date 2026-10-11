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
#
# `fleet-view-hub-fresh-selftest.sh B` runs one leg (docs/BREAK-IT.md
# view-far-reaped runs B). Drives bin/fleet_view.py through fleet-quickopen.py
# view-rows, the real fleet-hub-sessions.sh and tmux-dashboard-rows.sh; the hub is
# FLEET_HUB_SESSIONS_CMD, tmux a shim with no windows.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'fleet-view-hub-fresh: python3 absent — SKIP'; exit 0; }
LEGS="${1:-ABCD}"
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
echo "PASS fleet-view-hub-fresh-selftest ($LEGS)"
