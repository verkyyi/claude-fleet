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

# --- portability probe: does this tmux round-trip a raw US (0x1f) byte in -F? --
# tmux-dashboard-rows.sh separates its `-F` fields with the US control byte
# (0x1f). macOS tmux emits it raw, but some Linux tmux builds (e.g. 3.4 on GitHub
# ubuntu-latest) OCTAL-ESCAPE control bytes in `-F` output — emitting the literal
# 4-char string `\037` instead — so the producer's `IFS=$'\x1f' read` never splits
# and it renders ZERO rows, for a reason ENTIRELY UNRELATED to the #208 cache-key
# fix under test. Where that's the case we can't faithfully drive the real
# producer, so SKIP cleanly (the cache-key isolation this issue is about is still
# covered portably by fleet-lib-selftest.sh's fleet_summary_key unit tests and
# fleet-history-selftest.sh's two-fleet record-path isolation case).
US=$(printf '\037')
tmux new-session -d -s probe -x 80 -y 24 'sleep 300' 2>/dev/null || fail "could not start isolated tmux server"
probe_out=$(tmux list-windows -t probe -F "a${US}b" 2>/dev/null | od -An -tx1 | tr -d ' \n')
tmux kill-session -t probe 2>/dev/null
case "$probe_out" in
  *611f62*) : ;;   # raw US survived → the producer can parse; run the full test
  *)
    printf 'selftest SKIP: this tmux octal-escapes the US (0x1f) field byte in -F, so tmux-dashboard-rows.sh cannot parse here (unrelated to #208) — cache-key isolation is covered by fleet-lib/fleet-history selftests\n'
    exit 0 ;;
esac

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
