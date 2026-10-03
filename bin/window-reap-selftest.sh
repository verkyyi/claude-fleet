#!/bin/bash
# window-reap-selftest.sh — a closed window takes its process trees with it
# (issue #1298): fleet_orphan_trees / fleet_reap_orphan_trees and the tmux hooks
# that run bin/fleet-window-reap.sh on every close.
#
# The gap this guards: a tree a window started and abandoned (a disowned job, a
# Bash-tool `&`, an MCP server's headless browser) outlived the window as a PPID=1
# orphan until a scan found it — on 2026-10-03 three browsers held ~50 GB for five
# days. Now the close sweeps.
#
# Asserts:
#   • CONF       conf/tmux-attention.conf hooks window-unlinked, pane-exited and
#                after-kill-pane to `fleet-window-reap.sh --hook`.
#   • CLOSE      a window on a PRIVATE socket runs `sh -c 'sleep & wait' & disown`
#                in its worktree; kill-window → the hook fires, and the orphan
#                AND its child are gone within seconds.
#   • NEIGHBOR   the window beside it, in another worktree, keeps its pane and its
#                own disowned job — a live pane in the anchor spares every orphan.
#   • SCRATCHPAD a window's orphan whose cwd is its SESSION scratchpad (the
#                mangled-cwd dir under the claude root) dies with the window.
#   • SCOPE      an orphan in a plain dir, and an exempt one (doc-preview's
#                server.py), survive a sweep.
#   • LEASE      an orphan in a worktree under a rotation lease (#550) survives.
#   • OFF        FLEET_WINDOW_REAP=0 makes --hook a no-op.
#
# Hermetic: the claude root is a temp dir (FLEET_CLAUDE_TMP_ROOT) and every sweep
# is narrowed to the test's WORK dir (FLEET_WINDOW_REAP_ROOT), so a real orphan on
# the machine is never touched. tmux is driven on a PRIVATE -S socket only.
# No lsof → SKIP. Exit 0 = pass; non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s missing\n' "$LIB" >&2; exit 2; }
command -v lsof >/dev/null 2>&1 || { printf 'selftest: no lsof — SKIP\n' >&2; exit 0; }
command -v tmux >/dev/null 2>&1 || { printf 'selftest: no tmux — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/winreap.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
# A unix socket path is capped at ~104 bytes; $TMPDIR on macOS is already long.
SOCK="$(mktemp -u /tmp/winreap-sock.XXXXXX)"

PIDS=""
cleanup() {
  # shellcheck disable=SC2086
  [ -n "$PIDS" ] && kill $PIDS 2>/dev/null
  # ISOLATED socket only (issue #159's rail): this is never a fleet's server.
  tmux -S "$SOCK" kill-server 2>/dev/null
  rm -f "$SOCK"
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
alive() { kill -0 "$1" 2>/dev/null; }
# wait_gone <secs> <pid>… → 0 once every pid is gone
wait_gone() {
  local n="$1" p any; shift
  while [ "$n" -gt 0 ]; do
    any=0; for p in "$@"; do alive "$p" && any=1; done
    [ "$any" = 0 ] && return 0
    sleep 1; n=$((n - 1))
  done
  return 1
}

export FLEET_CONF_DIR="$WORK/conf"
export FLEET_CLAUDE_TMP_ROOT="$WORK/claude-root"
export FLEET_WINDOW_REAP_ROOT="$WORK"
export FLEET_WINDOW_REAP_PASSES="1 3 6"
mkdir -p "$FLEET_CONF_DIR" "$FLEET_CLAUDE_TMP_ROOT"
# shellcheck source=/dev/null
. "$LIB"

WT1="$WORK/wt/repo-issue-901"; WT2="$WORK/wt/repo-issue-902"; WT3="$WORK/wt/repo-issue-903"
PLAIN="$WORK/plain"; HUBCWD="$WORK/hub"
mkdir -p "$WT1" "$WT2" "$WT3" "$PLAIN" "$HUBCWD"
SCR="$FLEET_CLAUDE_TMP_ROOT/$(fleet_mangle_path "$HUBCWD")/sid-1/scratchpad"
mkdir -p "$SCR"

# orphan <cwd> [argv-tail…] → ORPHAN = the pid of a double-forked sh (PPID=1)
# running `sleep` as a child, so the tree has two levels.
ORPHAN=""
orphan() {
  local d="$1" f="$WORK/o.$$.$RANDOM"; shift
  ( cd "$d" && exec nohup sh -c 'sleep 120 & echo $$ > "$0"; wait' "$f" "$@" >/dev/null 2>&1 & )
  local i=0; while [ ! -s "$f" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  ORPHAN="$(cat "$f" 2>/dev/null)"; rm -f "$f"
  [ -n "$ORPHAN" ] || fail "could not start an orphan in $d"
  PIDS="$PIDS $ORPHAN $(pgrep -P "$ORPHAN" 2>/dev/null | tr '\n' ' ')"
}

# ── CONF ────────────────────────────────────────────────────────────────────────
CONF="$BIN/../conf/tmux-attention.conf"
for h in window-unlinked pane-exited after-kill-pane; do
  grep -Eq "^set-hook -g $h\[[0-9]+\] .*fleet-window-reap\.sh --hook" "$CONF" \
    || fail "CONF: $h is not hooked to fleet-window-reap.sh --hook"
done
ok "CONF: window-unlinked / pane-exited / after-kill-pane run the sweeper"

# ── SCOPE / LEASE (direct sweeps, no tmux) ──────────────────────────────────────
orphan "$PLAIN"; P_PLAIN="$ORPHAN"
orphan "$WT3" /x/skills/doc-preview/server.py; P_EXEMPT="$ORPHAN"
mkdir -p "$WORK/wt/repo-issue-904"; orphan "$WORK/wt/repo-issue-904"; P_LEASE="$ORPHAN"
fleet_rotate_lease_take "$WORK/wt/repo-issue-904" selftest 600 || fail "LEASE: could not take a lease"
dry="$(fleet_reap_orphan_trees dry)"
printf '%s\n' "$dry" | grep -q "would reap $P_PLAIN " && fail "SCOPE: an orphan in a plain dir is a candidate" "$dry"
printf '%s\n' "$dry" | grep -q "would reap $P_EXEMPT " && fail "SCOPE: doc-preview's server is a candidate" "$dry"
printf '%s\n' "$dry" | grep -q "would reap $P_LEASE " && fail "LEASE: an orphan under a rotation lease is a candidate" "$dry"
bash "$BIN/fleet-window-reap.sh" --once >/dev/null
alive "$P_PLAIN" && alive "$P_EXEMPT" && alive "$P_LEASE" || fail "SCOPE/LEASE: a spared orphan was killed"
ok "SCOPE: an unanchored and an exempt orphan survive a sweep"
ok "LEASE: an orphan in a worktree mid-rotation survives"
fleet_rotate_lease_drop "$WORK/wt/repo-issue-904"
kill_tree() { local p; for p in "$@"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; }
kill_tree "$P_LEASE" "$P_EXEMPT"

# ── OFF ─────────────────────────────────────────────────────────────────────────
orphan "$WT3"; P_OFF="$ORPHAN"
FLEET_WINDOW_REAP=0 FLEET_WINDOW_REAP_FG=1 bash "$BIN/fleet-window-reap.sh" --hook
alive "$P_OFF" || fail "OFF: FLEET_WINDOW_REAP=0 still reaped"
ok "OFF: FLEET_WINDOW_REAP=0 makes the hook a no-op"
kill_tree "$P_OFF"

# ── CLOSE / NEIGHBOR / SCRATCHPAD (a private tmux server, the real hooks) ───────
T() { tmux -S "$SOCK" -f /dev/null "$@"; }
T new-session -d -s wr -n base -c "$PLAIN" || fail "could not start a private tmux server"
T set-environment -g FLEET_CONF_DIR "$FLEET_CONF_DIR"
T set-environment -g FLEET_CLAUDE_TMP_ROOT "$FLEET_CLAUDE_TMP_ROOT"
T set-environment -g FLEET_WINDOW_REAP_ROOT "$FLEET_WINDOW_REAP_ROOT"
T set-environment -g FLEET_WINDOW_REAP_PASSES "$FLEET_WINDOW_REAP_PASSES"
# The live conf's hooks, pointed at THIS checkout's sweeper (the conf names the
# installed ~/.claude/fleet path).
grep -E '^set-hook -g [a-z-]+\[[0-9]+\] .*fleet-window-reap\.sh' "$CONF" \
  | sed "s#~/.claude/fleet/bin/fleet-window-reap.sh#$BIN/fleet-window-reap.sh#" > "$WORK/hooks.conf"
T source-file "$WORK/hooks.conf" || fail "the hook lines do not parse"

T new-window -d -n w1 -c "$WT1" sh
T new-window -d -n w2 -c "$WT2" sh
T new-window -d -n w3 -c "$HUBCWD" sh
start_job() {   # <window> <cwd> <pidfile> — a disowned two-level job from the pane
  T send-keys -t "wr:$1" "cd '$2'; nohup sh -c 'sleep 120 & wait' >/dev/null 2>&1 & echo \$! > '$3'" Enter
  local i=0; while [ ! -s "$3" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$3" ] || fail "window $1 did not start its job"
}
start_job w1 "$WT1" "$WORK/j1"; J1="$(cat "$WORK/j1")"
start_job w2 "$WT2" "$WORK/j2"; J2="$(cat "$WORK/j2")"
# w3's job runs in its session scratchpad while the pane stays in $HUBCWD
start_job w3 "$SCR" "$WORK/j3"; J3="$(cat "$WORK/j3")"
T send-keys -t wr:w3 "cd '$HUBCWD'" Enter
sleep 0.5
J1C="$(pgrep -P "$J1" 2>/dev/null | head -1)"; J3C="$(pgrep -P "$J3" 2>/dev/null | head -1)"
PIDS="$PIDS $J1 $J2 $J3 $J1C $J3C $(pgrep -P "$J2" 2>/dev/null | tr '\n' ' ')"
[ -n "$J1C" ] || fail "CLOSE: w1's job has no child"
W2PANE="$(T display-message -p -t wr:w2 '#{pane_pid}')"

# While every window is open, nothing is a candidate (a pane in each anchor).
dry="$(fleet_reap_orphan_trees dry)"
printf '%s\n' "$dry" | grep -Eq "would reap ($J1|$J2|$J3) " && fail "a job is a candidate while its window is open" "$dry"

T kill-window -t wr:w1
wait_gone 15 "$J1" "$J1C" || fail "CLOSE: w1's orphan survived its window" \
  "$(ps -o pid,ppid,command -p "$J1,${J1C:-0}" 2>&1; cat "$FLEET_CONF_DIR/diskguard/window-reap.log" 2>/dev/null)"
ok "CLOSE: kill-window → the disowned job and its child are gone"
grep -Eq "reaped $J1 worktree cwd=$WT1 " "$FLEET_CONF_DIR/diskguard/window-reap.log" 2>/dev/null \
  || fail "CLOSE: the reap was not logged" "$(cat "$FLEET_CONF_DIR/diskguard/window-reap.log" 2>/dev/null)"
ok "CLOSE: the reap is logged in diskguard/window-reap.log"

sleep 7   # let the whole schedule run out
alive "$J2" && alive "$W2PANE" || fail "NEIGHBOR: the window beside the closed one lost a process"
ok "NEIGHBOR: the open window's pane and its own disowned job survive"

alive "$J3" || fail "SCRATCHPAD: w3's job died while w3 was open"
T kill-window -t wr:w3
wait_gone 15 "$J3" "${J3C:-$J3}" || fail "SCRATCHPAD: w3's scratchpad orphan survived its window"
ok "SCRATCHPAD: an orphan in the closed window's session scratchpad is reaped"
alive "$P_PLAIN" || fail "SCOPE: the plain-dir orphan died in a hook sweep"

printf 'PASS: window-reap selftest (%d checks)\n' "$pass"
