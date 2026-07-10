#!/bin/bash
# dash-summary-crossfleet-selftest.sh — regression for issue #208: the dash
# summary column must render ONLY this fleet's own rows, never another fleet's.
#
# The bug: the machine-wide dash-summary cache (global/summary_<key>) was keyed by
# the BARE numeric window id. Under the old single `default` tmux socket that id
# was globally unique, but after the per-fleet-socket cutover (#159/#168) each
# fleet runs its OWN tmux server numbering windows from @1 — so fleet A's @2 and
# fleet B's @2 both mapped to `summary_2`, and whichever summarizer wrote last won.
# Fleet B's one-liner then bled into fleet A's dash. The fix keys the cache by
# <session>_<window-id> (fleet_summary_key), so each fleet's rows are its own.
#
# This drives the REAL bin/tmux-dashboard-rows.sh against a REAL, isolated tmux
# server (its own socket, torn down at exit — never the user's live server), with
# TWO fleets sharing ONE global cache and both owning a window at the SAME numeric
# id. It asserts fleet A's rendered rows show A's summary and NEVER B's.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
ROWS="$BIN/tmux-dashboard-rows.sh"
[ -f "$LIB" ]  || { printf 'selftest: %s not found\n' "$LIB"  >&2; exit 2; }
[ -f "$ROWS" ] || { printf 'selftest: %s not found\n' "$ROWS" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-sum-selftest.XXXXXX")" || exit 2

# Isolate every tmux call onto a private socket so we never touch the user's live
# server. A PATH shim routes the plain `tmux` that tmux-dashboard-rows.sh calls
# (`tmux list-windows -a`) to it. The dash producer runs in-pane, so this mirrors
# how it inherits its fleet's socket from $TMUX in production.
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"

# Scope the dash cache under WORK so we never read/write the real one.
export TMPDIR="$WORK"
G="$WORK/.claude-dash/global"; mkdir -p "$G"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
# A bare EXIT trap does NOT fire on a signal — turn INT/TERM/HUP into a normal exit
# so cleanup reaps the isolated server instead of leaking it (issue #152).
trap 'exit 130' INT TERM HUP

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# --- two fleets on one isolated server, each with a window at the SAME id ------
# (One server here stands in for two — what matters is the SHARED global cache and
# a COLLIDING numeric window id. We give each fleet its own session and force both
# worker windows to the same numeric id is impossible on one server, so instead we
# read each fleet's OWN window id and seed the cache under BOTH the correct
# <sess>_<id> key AND the legacy bare id — the pre-fix reader would grab the bare
# one and cross the streams.)
# The session's own first window runs a long-lived `sleep` too: a default-shell
# window exits instantly in a headless CI and, if it's the session's only window,
# takes the whole session down before mk_worker can add to it (killed at exit).
tmux new-session -d -s fleetA -x 200 -y 50 'sleep 300' 2>/dev/null || fail "could not start isolated tmux server"
tmux new-session -d -s fleetB -x 200 -y 50 'sleep 300' 2>/dev/null || fail "could not start fleetB session"

# Worker windows (name them like real workers — NOT dash/plan/backlog panels), each
# bound to an @issue and given a Claude state so the row renders. The window runs a
# long-lived `sleep` so it SURVIVES until the render: a new-window with no command
# runs the default shell, which exits instantly in a headless CI (no tty) and tmux
# then destroys the window — locally the shell lingers, but CI would see zero rows.
# The whole server is killed at exit, so the sleep never outlives the test.
mk_worker() { # <session> <issue> → prints the numeric window id
  local s="$1" iss="$2" wid
  wid=$(tmux new-window -d -P -F '#{window_id}' -t "$s:" -n "issue-$iss" 'sleep 300')
  tmux set-window-option -t "$wid" @claude_state working 2>/dev/null
  tmux set-window-option -t "$wid" @issue "$iss" 2>/dev/null
  printf '%s' "${wid//[^0-9]/}"
}
idA=$(mk_worker fleetA 100); [ -n "$idA" ] || fail "no window id for fleetA worker"
idB=$(mk_worker fleetB 200); [ -n "$idB" ] || fail "no window id for fleetB worker"

# Seed the SHARED cache: each fleet's correctly-keyed summary…
printf 'ALPHA doing fleetA work\n' > "$G/summary_fleetA_$idA"
printf 'BRAVO doing fleetB work\n' > "$G/summary_fleetB_$idB"
# …plus the legacy BARE-id files that the pre-#208 reader used. If fleetB's worker
# happens to share fleetA's numeric id, the old reader would surface BRAVO in
# fleetA's dash. Seed fleetA's bare id with BRAVO's text to make that leak visible
# if the fix ever regresses.
printf 'BRAVO doing fleetB work\n' > "$G/summary_$idA"

# --- render fleetA's dash rows and assert isolation --------------------------
# Run in-pane as fleetA (FLEET_SESSION=fleetA); the producer's `tmux list-windows`
# hits the shim socket, and its per-fleet filter keeps only fleetA's windows.
rowsA=$(cd "$WORK" && FLEET_SESSION=fleetA COLUMNS=200 bash "$ROWS" 2>/dev/null)

printf '%s' "$rowsA" | grep -q 'ALPHA doing fleetA work' \
  || fail "fleetA dash should show its OWN summary (ALPHA) — got:\n$rowsA"
printf '%s' "$rowsA" | grep -q 'BRAVO doing fleetB work' \
  && fail "fleetA dash rendered fleetB's summary (BRAVO) — cross-fleet bleed (issue #208)"

# Symmetric check: fleetB's dash shows BRAVO, never ALPHA.
rowsB=$(cd "$WORK" && FLEET_SESSION=fleetB COLUMNS=200 bash "$ROWS" 2>/dev/null)
printf '%s' "$rowsB" | grep -q 'BRAVO doing fleetB work' \
  || fail "fleetB dash should show its OWN summary (BRAVO) — got:\n$rowsB"
printf '%s' "$rowsB" | grep -q 'ALPHA doing fleetA work' \
  && fail "fleetB dash rendered fleetA's summary (ALPHA) — cross-fleet bleed (issue #208)"

printf 'selftest PASS: dash summary column is per-fleet — no cross-fleet row bleed (issue #208)\n'
exit 0
