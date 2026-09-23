#!/bin/bash
# fleet-await-selftest.sh — `fleet-await.sh <N>`: spawn-if-needed, then block on
# the worker's outcome off the child-report ledger (issue #812, EPIC #935 R1).
#
# What is load-bearing, and therefore what is pinned:
#   SPAWN     no live worker ⇒ ONE call to the spawn choke point, with --origin =
#             the waiter's key; a live one ⇒ no call; --no-spawn / a cap refusal ⇒
#             NO-WORKER (5), with the reason.
#   OUTCOMES  MERGED 0 · BLOCKED 1 · REAPED 4 · window gone with no report GONE 4 ·
#             `needs` across two reads NEEDS 1 · nothing TIMEOUT 3.
#   NOT-YET   a FAILED report the worker says it is fixing does NOT end the wait,
#             nor does a turn-boundary WAITING.
#   ALREADY   a MERGED report written before the wait began returns at once.
#   ADOPT     a live worker with no parent gets the waiter's @origin.
#
# Runs on a DEDICATED tmux server on its own -L label (never the live server,
# issue #159), from a sandbox bin/ whose dash-issue-session.sh is a stub; reports
# are written by the real fleet-report-parent.sh, so the ledger is the real one.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-await.sh fleet-children.sh fleet-children.py fleet-children-lib.sh fleet-report-parent.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }
done

CHECKS=0
fail() { printf 'fleet-await selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()   { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1" "expected: [$2]"$'\n'"got:      [$3]"; }
has()  { CHECKS=$((CHECKS + 1)); case "$3" in *"$2"*) : ;; *) fail "$1" "$3" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-await.XXXXXX")" || exit 2
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR" "$WORK/.claude-dash/global"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
unset TMUX TMUX_PANE

# Sandbox bin/: every real script, with the spawn choke point swapped for a stub
# that records its argv and opens the window the real one would.
SB="$WORK/bin"; mkdir -p "$SB"
for f in "$BIN"/*; do ln -s "$f" "$SB/${f##*/}"; done
rm -f "$SB/dash-issue-session.sh"
cat > "$SB/dash-issue-session.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
rc=$(cat "$STUB_RC" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || { printf 'dash-issue-session: at capacity (stub)\n' >&2; exit "$rc"; }
num=$1 sess=$2 origin=''
while [ "$#" -gt 0 ]; do [ "$1" = --origin ] && origin=$2; shift; done
w=$(tmux -L "$sess" new-window -d -P -F '#{window_id}' -t "$sess" -n "issue-$num" "sleep 600")
tmux -L "$sess" set-window-option -t "$w" @issue "$num"
tmux -L "$sess" set-window-option -t "$w" @origin "$origin"
tmux -L "$sess" set-window-option -t "$w" @claude_state working
STUB
chmod +x "$SB/dash-issue-session.sh"
export STUB_LOG="$WORK/spawns" STUB_RC="$WORK/spawn-rc"; : > "$STUB_LOG"
AW="$SB/fleet-await.sh"

# --- 1. usage (no server) --------------------------------------------------------
bash "$AW" >/dev/null 2>&1;            eq "no issue number exits 2" 2 "$?"
bash "$AW" 12 --timeout x >/dev/null 2>&1; eq "a bad --timeout exits 2" 2 "$?"
out=$(bash "$AW" 12 -L nosuch-$$ 2>&1); eq "no parent key exits 2" 2 "$?"
has "…and says why" 'no parent key' "$out"

command -v tmux >/dev/null 2>&1 || { printf 'fleet-await selftest: tmux absent — usage only (%d checks)\n' "$CHECKS"; rm -rf "$WORK"; exit 0; }

# --- 2. end to end on a dedicated server -----------------------------------------
LBL="fawait-selftest-$$"
trap 'tmux -L "$LBL" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT
TM() { tmux -L "$LBL" "$@"; }
TM new-session -d -s "$LBL" -n dash -c "$WORK" "sleep 600" 2>/dev/null || fail "could not start the selftest tmux server"
mkdir -p "$WORK/repo-scratch-7"
P=$(TM new-window -d -P -F '#{window_id}' -n parent -c "$WORK" "sleep 600")
TM set-window-option -t "$P" @raw 1; TM set-window-option -t "$P" @worktree "$WORK/repo-scratch-7"

win_of() { TM list-windows -F '#{@issue} #{window_id}' | awk -v n="$1" '$1==n{print $2; exit}'; }
report() { bash "$SB/fleet-report-parent.sh" -L "$LBL" "$@" >/dev/null 2>&1; }
# await <N> [args…] — run it in the background; AWAIT_PID to `collect` later.
await() { bash "$AW" "$@" -L "$LBL" --parent scratch-7 --interval 1 > "$WORK/out" 2> "$WORK/err" & AWAIT_PID=$!; }
collect() { wait "$AWAIT_PID"; RC=$?; OUT=$(cat "$WORK/out"); }
# Wait (bounded) until the awaited window exists — the spawn is synchronous in the
# waiter, but the waiter itself is in the background.
until_win() { local i=0; while [ -z "$(win_of "$1")" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; win_of "$1"; }

# SPAWN → MERGED
await 101 --timeout 30
W=$(until_win 101); [ -n "$W" ] || fail "no window spawned for #101" "$(cat "$WORK/err")"
sleep 1.5
report --win "$W" --state merged --pr 501 --summary 'landed the thing'
collect
eq "MERGED exits 0" 0 "$RC"
eq "…first line is the verdict" MERGED "$(printf '%s\n' "$OUT" | head -1)"
has "…with the PR" 'pr: #501' "$OUT"
has "…and the worker's summary" 'summary: landed the thing' "$OUT"
eq "one spawn, parented on the waiter" "101 $LBL --origin scratch-7" "$(cat "$STUB_LOG")"

# ALREADY: the merge is in the ledger; a second wait returns without sleeping or spawning.
TM kill-window -t "$W"
await 101 --timeout 30; collect
eq "an already-MERGED child returns 0 at once" 0 "$RC"
has "…saying so" 'already reported' "$OUT"
eq "…and spawns nothing" 1 "$(wc -l < "$STUB_LOG" | tr -d ' ')"

# LIVE → BLOCKED, with a not-yet FAILED (fixing) and WAITING first.
await 102 --timeout 30
W=$(until_win 102); sleep 1.5
report --win "$W" --state failed --pr 502 --summary 'RED: CI failure or merge conflict; fixing it'
report --win "$W" --state waiting --pr 502
sleep 2.5
kill -0 "$AWAIT_PID" 2>/dev/null || { collect; fail "a fixing FAILED / WAITING must not end the wait" "$OUT"; }
CHECKS=$((CHECKS + 1))
report --win "$W" --state blocked --pr 502 --summary 'needs a token I do not have'
collect
eq "BLOCKED exits 1" 1 "$RC"
eq "…verdict line" BLOCKED "$(printf '%s\n' "$OUT" | head -1)"
has "…with the blocker" 'needs a token' "$OUT"

# A live worker is waited on, not re-spawned: --no-spawn finds it; REAPED ends it.
n=$(wc -l < "$STUB_LOG" | tr -d ' ')
TM set-window-option -t "$W" @claude_state working
await 102 --timeout 30 --no-spawn; sleep 1.5
report --win "$W" --state reaped --verdict unmerged --summary 'worktree reaped with commits'
TM kill-window -t "$W"
collect
eq "REAPED (unmerged) exits 4" 4 "$RC"
eq "…verdict line" REAPED "$(printf '%s\n' "$OUT" | head -1)"
eq "…and a live worker is never re-spawned" "$n" "$(wc -l < "$STUB_LOG" | tr -d ' ')"

# GONE: the window closes with no report at all.
await 103 --timeout 30
W=$(until_win 103); sleep 1.5; TM kill-window -t "$W"
collect
eq "a window gone without a report is GONE, exit 4" "4 GONE" "$RC $(printf '%s\n' "$OUT" | head -1)"

# NEEDS: sitting in `needs` across two reads.
await 104 --timeout 30
W=$(until_win 104); TM set-window-option -t "$W" @claude_state needs; TM set-window-option -t "$W" @claude_needs permission
collect
eq "a window stuck in needs is NEEDS, exit 1" "1 NEEDS" "$RC $(printf '%s\n' "$OUT" | head -1)"
has "…naming the need" 'permission' "$OUT"

# TIMEOUT: nothing happens.
await 104 --timeout 2
TM set-window-option -t "$(win_of 104)" @claude_state working
SECONDS=0; collect
eq "TIMEOUT exits 3" "3 TIMEOUT" "$RC $(printf '%s\n' "$OUT" | head -1)"
[ "$SECONDS" -le 5 ] || fail "--timeout 2 took ${SECONDS}s"
CHECKS=$((CHECKS + 1))

# ADOPT: a hub-spawned (parentless) worker is re-parented onto the waiter.
A=$(TM new-window -d -P -F '#{window_id}' -n issue-105 "sleep 600")
TM set-window-option -t "$A" @issue 105; TM set-window-option -t "$A" @claude_state working
await 105 --timeout 30 --no-spawn; sleep 1.5
eq "a parentless worker is adopted" scratch-7 "$(TM display-message -p -t "$A" '#{@origin}')"
report --win "$A" --state merged --pr 505
collect
eq "…and its report reaches the waiter" "0 MERGED" "$RC $(printf '%s\n' "$OUT" | head -1)"

# NO-WORKER: --no-spawn with nothing live; a cap refusal from the choke point.
bash "$AW" 106 -L "$LBL" --parent scratch-7 --interval 1 --timeout 5 --no-spawn > "$WORK/out" 2>&1
eq "--no-spawn with no worker exits 5" 5 "$?"
has "…NO-WORKER" 'NO-WORKER' "$(cat "$WORK/out")"
echo 2 > "$STUB_RC"
bash "$AW" 106 -L "$LBL" --parent scratch-7 --interval 1 --timeout 5 > "$WORK/out" 2>&1
eq "a cap refusal exits 5" 5 "$?"
has "…and says capacity" 'at capacity' "$(cat "$WORK/out")"

printf 'fleet-await selftest: OK (%d checks)\n' "$CHECKS"
