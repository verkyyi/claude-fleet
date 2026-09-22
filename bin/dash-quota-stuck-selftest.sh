#!/bin/bash
# dash-quota-stuck-selftest.sh — a failover request stuck on the same veto is
# `⚠ stuck` on its dash row, not the ordinary `quota:waiting` (issue #872).
#
# bin/.fleet-failover.py stamps @quota_stuck=1 once a request has recorded the
# same reason FLEET_FAILOVER_STUCK_ATTEMPTS times in a row, and unsets it when the
# reason changes or the request ends. The row producer folds that option into the
# @quota_failover field as a `stuck:` prefix; pinned here:
#   • @quota_failover alone        → `quota:waiting`, no `⚠ stuck`
#   • + @quota_stuck=1             → `⚠ stuck`, and the `quota:` tag is gone
#   • @quota_stuck unset again     → back to `quota:waiting`
#   • no @quota_failover at all    → neither tag
#
# Needs a real tmux, on an ISOLATED socket via the PATH shim (never the live
# server — see dash-marker-selftest.sh). tmux absent → SKIP cleanly. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
[ -f "$ROWS" ] || { printf 'selftest: %s not found\n' "$ROWS" >&2; exit 2; }

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — row does not contain [$3]" "$2";; esac; }
not_contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — row unexpectedly contains [$3]" "$2";; esac; }

REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'dash-quota-stuck-selftest: tmux not installed — SKIPPED\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-quota-stuck-selftest.XXXXXX")" || exit 2
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$WORK/conf" "$WORK/bin"
SOCK="$WORK/tmux.sock"
cat > "$WORK/bin/tmux" <<SHIM
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
SHIM
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
export TMPDIR="$WORK"
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# US round-trip probe — some Linux tmux builds octal-escape 0x1f in -F output.
US=$(printf '\037')
tmux new-session -d -s probe -x 80 -y 24 'sleep 300' 2>/dev/null \
  || fail "could not start the isolated tmux server"
probe_out=$(tmux list-windows -t probe -F "a${US}b" 2>/dev/null | od -An -tx1 | tr -d ' \n')
tmux kill-session -t probe 2>/dev/null
case "$probe_out" in
  *611f62*) : ;;
  *) printf 'dash-quota-stuck-selftest: this tmux octal-escapes US in -F — SKIPPED\n'; exit 0 ;;
esac

tmux new-session -d -s fleetQ -x 220 -y 50 -c "$WORK" 'sleep 300' \
  || fail "could not start the 'fleetQ' session"
WID=$(tmux new-window -d -P -F '#{window_id}' -t fleetQ: -n walled -c "$WORK" 'sleep 300')
tmux set-window-option -t "$WID" @issue 900

row() { FLEET_SESSION=fleetQ FZF_COLUMNS=180 bash "$ROWS" 2>/dev/null \
          | LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g' -e $'s/\x1f/ /g' | grep ' walled' | head -1; }

r=$(row); [ -n "$r" ] || fail "the fixture window never rendered a row"
not_contains "no request → no quota tag" "$r" "quota:"
not_contains "no request → no stuck tag" "$r" "stuck"

tmux set-window-option -t "$WID" @quota_failover 'waiting: background/tool processes are still running'
r=$(row)
contains     "pending request → quota:waiting" "$r" "quota:waiting"
not_contains "pending request → not stuck"     "$r" "⚠ stuck"

tmux set-window-option -t "$WID" @quota_stuck 1
r=$(row)
contains     "stuck request → ⚠ stuck"             "$r" "⚠ stuck"
not_contains "stuck request → no plain quota tag"  "$r" "quota:"

tmux set-window-option -t "$WID" -u @quota_stuck
r=$(row)
contains     "unstuck → quota:waiting again" "$r" "quota:waiting"
not_contains "unstuck → no stuck tag"        "$r" "⚠ stuck"

printf 'dash-quota-stuck-selftest: %d checks passed\n' "$CHECKS"
