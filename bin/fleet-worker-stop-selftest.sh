#!/bin/bash
# fleet-worker-stop-selftest.sh — pins bin/fleet-worker-stop.sh (issue #834): the
# Fleet Hub's graceful stop addresses a worker by its DURABLE key (issue-N /
# scratch-N), re-resolves the window on the fleet at action time, and refuses
# whenever that resolution is not exactly one awake window.
#
# Real tmux on an ISOLATED socket (`-L fleetS` under a private TMUX_TMPDIR), a
# fake `claude` per pane (a shell loop that exits on `/exit`, widened into
# fleet_pane_claude_pid via FLEET_CLAUDE_COMM), a scratch conf estate and a
# scratch /fleet-history ledger. No live fleet, no gh, no model.
#
#   1. a stop by key exits THAT agent, records a closed-unlanded row, closes only
#      that window — the neighbour keeps its pid; no git command ran (no git here)
#   2. a key nobody holds       → refused:not-found (5), nothing touched
#   3. a key two windows hold   → refused:ambiguous (6), both survive
#   4. a hibernating worker     → refused:hibernating (8), pane untouched
#   5. a window at a bare shell → stopped:shell, window closed, row recorded
#   6. an agent that will not exit → failed:no-exit (7), window + pid survive
#   7. a scratch key resolves through @raw + @worktree, Codex gets its bracketed /exit
#   8. usage: a window NUMBER is not a key (2)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

# Short scratch name on purpose: a unix socket path is capped at ~104 bytes.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wstop.XXXXXX")" || exit 2
export TMUX_TMPDIR="$WORK/tmt"; mkdir -p "$TMUX_TMPDIR"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/fleetS"
mkdir -p "$WORK/main" "$WORK/wt-scratch-7" "$WORK/issue-1" "$WORK/issue-2"
printf 'FLEET_REPO="acme/fleetS"\nFLEET_MAIN="%s"\n' "$WORK/main" > "$FLEET_CONF_DIR/fleets/fleetS/conf"
export FLEET_HISTORY_LEDGER="$WORK/ledger.tsv"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
export CLAUDE_PROJECTS_DIR="$WORK/projects"; mkdir -p "$CLAUDE_PROJECTS_DIR"
export FLEET_CLAUDE_COMM='FLEETFAKECLAUDE'
export FLEET_STOP_EXIT_WAIT=8 FLEET_STOP_CLOSE_WAIT=1
unset TMUX TMUX_PANE

FAIL=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
tf() { "$REAL_TMUX" -L fleetS "$@"; }
cleanup() { "$REAL_TMUX" -L fleetS kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# A fake agent: reads lines off its tty and exits on one ending in `/exit`
# (the Escape byte the stop sends first lands on the same line). The stubborn
# one ignores everything, like an agent wedged in a modal. Each is a SEPARATE
# process under the pane's `sh -c` — the token fleet_pane_claude_pid matches
# (FLEET_CLAUDE_COMM) sits in the CHILD's argv only, so the probe resolves the
# agent, not the pane shell, exactly as it resolves a real `claude` under the
# launcher's runner.
cat > "$WORK/fc" <<'EOF'
#!/bin/bash
exec bash -c ': FLEETFAKECLAUDE; while IFS= read -r l; do case "$l" in *"/exit"*) exit 0;; esac; done'
EOF
cat > "$WORK/fs" <<'EOF'
#!/bin/bash
exec bash -c ': FLEETFAKECLAUDE; while :; do sleep 300; done'
EOF
chmod +x "$WORK/fc" "$WORK/fs"
# The real launcher ends `…; exec $SHELL`, so after /exit the pane sits at a
# shell and only the SessionEnd hook (absent here) would close the window —
# SHELLED models that; BARE lets the pane die with the agent.
BARE="$WORK/fc"
SHELLED="$WORK/fc; while :; do sleep 300; done"
STUBBORN="$WORK/fs; while :; do sleep 300; done"
tf -f /dev/null new-session -d -s fleetS -n plan 'while :; do sleep 300; done' 2>/dev/null \
  || { printf 'selftest: cannot start an isolated tmux server — SKIP\n' >&2; exit 0; }

# mkwin <name> <cmd> <issue|-> [raw-worktree] [lifecycle] [agent] → prints window id
mkwin() {
  local name="$1" cmd="$2" iss="$3" wt="${4:-}" lc="${5:-}" agent="${6:-}" wid
  wid=$(tf new-window -d -P -F '#{window_id}' -n "$name" -c "${wt:-$WORK}" "$cmd")
  [ "$iss" != - ] && tf set-window-option -t "$wid" @issue "$iss"
  [ -n "$wt" ] && { tf set-window-option -t "$wid" @raw 1; tf set-window-option -t "$wid" @worktree "$wt"; }
  [ -n "$lc" ] && tf set-window-option -t "$wid" @worker_lifecycle "$lc"
  [ -n "$agent" ] && tf set-window-option -t "$wid" @cc_agent "$agent"
  printf '%s' "$wid"
}
pid_of() { (. "$BIN/fleet-lib.sh"; fleet_pane_claude_pid "$1" fleetS 2>/dev/null); }
# display-message -t <gone window> answers with an empty line and exit 0, so
# existence is a list-windows membership test, never a display-message probe.
has_win() { tf list-windows -t fleetS -F '#{window_id}' 2>/dev/null | grep -qx -- "$1"; }
run_stop() { out=$(bash "$BIN/fleet-worker-stop.sh" "$@" 2>"$WORK/err"); rc=$?; }
ledger_has() { [ -f "$FLEET_HISTORY_LEDGER" ] && awk -F'\t' -v k="$1" '$2==k{f=1} END{exit !f}' "$FLEET_HISTORY_LEDGER"; }

# --- 1. stop by key: exits that agent, closes that window, neighbour untouched --
w1=$(mkwin one "$SHELLED" 1); w2=$(mkwin two "$SHELLED" 2)
sleep 0.5
p1=$(pid_of "$w1"); p2=$(pid_of "$w2")
[ -n "$p1" ] && [ -n "$p2" ] || fail "fixture: fake agents not resolved under $w1/$w2" "p1=$p1 p2=$p2"
run_stop fleetS issue-1
[ "$rc" = 0 ] && [ "$out" = stopped:closed ] || fail "1: expected stopped:closed/0" "rc=$rc out=$out err=$(cat "$WORK/err")"
has_win "$w1" && fail "1: window $w1 still exists after the stop"
has_win "$w2" || fail "1: neighbour window $w2 was closed"
kill -0 "$p1" 2>/dev/null && fail "1: agent pid $p1 still alive after /exit"
kill -0 "$p2" 2>/dev/null || fail "1: neighbour agent pid $p2 died"
ledger_has 1 || fail "1: no closed-unlanded ledger row keyed 1" "$(cat "$FLEET_HISTORY_LEDGER" 2>/dev/null)"
ledger_has 2 && fail "1: a row was recorded for the neighbour"

# --- 2. a key nobody holds -------------------------------------------------------
run_stop fleetS issue-9
[ "$rc" = 5 ] && [ "$out" = refused:not-found ] || fail "2: expected refused:not-found/5" "rc=$rc out=$out"
has_win "$w2" || fail "2: a not-found stop closed a window"

# --- 3. a key two windows hold ---------------------------------------------------
w3a=$(mkwin three-a "$SHELLED" 3); w3b=$(mkwin three-b "$SHELLED" 3); sleep 0.3
run_stop fleetS issue-3
[ "$rc" = 6 ] && [ "$out" = refused:ambiguous ] || fail "3: expected refused:ambiguous/6" "rc=$rc out=$out"
has_win "$w3a" && has_win "$w3b" || fail "3: an ambiguous stop closed a window"

# --- 4. a hibernating worker (sleep controller owns the pane) --------------------
w4=$(mkwin four "$SHELLED" 4 "" sleeping); sleep 0.3
run_stop fleetS issue-4
[ "$rc" = 8 ] && [ "$out" = refused:hibernating ] || fail "4: expected refused:hibernating/8" "rc=$rc out=$out"
has_win "$w4" || fail "4: a hibernating worker's window was closed"
p4=$(pid_of "$w4"); kill -0 "${p4:-0}" 2>/dev/null || fail "4: hibernating pane's process was typed at / killed"

# --- 5. a window at a bare shell (no agent under the pane) -----------------------
w5=$(mkwin five 'while :; do sleep 300; done' 5); sleep 0.3
run_stop fleetS issue-5
[ "$rc" = 0 ] && [ "$out" = stopped:shell ] || fail "5: expected stopped:shell/0" "rc=$rc out=$out"
has_win "$w5" && fail "5: shell-only window $w5 survived the stop"
ledger_has 5 || fail "5: no ledger row for the shell-only stop"

# --- 6. an agent that will not exit ----------------------------------------------
w6=$(mkwin six "$STUBBORN" 6); sleep 0.3
p6=$(pid_of "$w6")
FLEET_STOP_EXIT_WAIT=2 run_stop fleetS issue-6
[ "$rc" = 7 ] && [ "$out" = failed:no-exit ] || fail "6: expected failed:no-exit/7" "rc=$rc out=$out"
has_win "$w6" || fail "6: window of a still-running agent was closed"
kill -0 "${p6:-0}" 2>/dev/null || fail "6: a stop that reported no-exit killed the agent"

# --- 7. scratch key via @raw + @worktree (pane dies with the agent, as when a
#        hook closed it: stopped:exit — or stopped:closed where tmux never noticed
#        the pane die (tmux 3.4 on Linux loses SIGCHLD, #781) — row recorded either
#        way); Codex bracketed /exit --------------------------------------------
w7=$(mkwin scratch-7 "$BARE" - "$WORK/wt-scratch-7"); sleep 0.3
run_stop fleetS scratch-7
case "$rc:$out" in 0:stopped:exit|0:stopped:closed) ;; *) fail "7: scratch key expected stopped:exit|closed/0" "rc=$rc out=$out err=$(cat "$WORK/err")" ;; esac
has_win "$w7" && fail "7: scratch window survived"
ledger_has scratch-7 || fail "7: no ledger row keyed scratch-7" "$(cat "$FLEET_HISTORY_LEDGER" 2>/dev/null)"
w8=$(mkwin eight "$SHELLED" 8 "" "" codex); sleep 0.3
run_stop fleetS issue-8
[ "$rc" = 0 ] && [ "$out" = stopped:closed ] || fail "7: codex expected stopped:closed/0" "rc=$rc out=$out"
has_win "$w8" && fail "7: codex window survived"

# --- 8. usage: a window number / index is not a key ------------------------------
for bad in "@12" "12" "issue-" "issue-x" "scratch-0"; do
  run_stop fleetS "$bad"
  [ "$rc" = 2 ] || fail "8: '$bad' should be a usage refusal (2)" "rc=$rc out=$out"
done
has_win "$w2" || fail "8: a usage refusal closed a window"

if [ "$FAIL" = 0 ]; then echo "fleet-worker-stop-selftest: OK"; exit 0; fi
echo "fleet-worker-stop-selftest: $FAIL failure(s)"; exit 1
