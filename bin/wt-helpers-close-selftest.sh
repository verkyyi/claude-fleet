#!/bin/bash
# wt-helpers-close-selftest.sh — fleet_wt_helpers_close (bin/fleet-lib.sh, issue
# #3352): a reaped session's HELPER windows go with it — a shell someone opened
# in its worktree — and nothing else does.
#
# Asserts, on a PRIVATE tmux server (-L <unique label>, never a fleet's):
#   • HELPER     a plain shell window whose every pane sits in the worktree is
#                closed, retired first (its @fleet_id in the retired book, so a
#                restore never pulls it back), and printed `helper:<id>`.
#   • SESSIONS   a window bound to ANOTHER issue, a raw scratch, a window with a
#                pane outside the worktree, one elsewhere and the reaped window
#                itself (the caller kills that one) are left alone.
#   • HOME       a home / panel window in the worktree is never a helper.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null 2>&1 || { printf 'selftest: no tmux — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wthelp.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SESS="wthelp$$"
export FLEET_CONF_DIR="$WORK/conf" FLEET_REAP_MIN_AGE=0
mkdir -p "$FLEET_CONF_DIR" "$WORK/app-issue-12/sub" "$WORK/elsewhere"
unset TMUX TMUX_PANE
T() { tmux -L "$SESS" "$@"; }
cleanup() { tmux -L "$SESS" kill-server >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; T list-windows -F '#{window_id} #{window_name}' >&2; exit 1; }

# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
[ "$(fleet_socket "$SESS")" = "$SESS" ] || fail "fleet_socket must map $SESS to its own label"

WT="$WORK/app-issue-12"
T -f /dev/null new-session -d -s "$SESS" -n home -c "$WT" 'exec sleep 120' || fail "cannot start the private server"
T set-option -w -t "$SESS:home" @fleet_role home
reaped=$(T new-window -d -P -F '#{window_id}' -t "$SESS" -c "$WT" 'exec sleep 120')
T set-option -w -t "$reaped" @issue 12; T set-option -w -t "$reaped" @worktree "$WT"
helper=$(T new-window -d -P -F '#{window_id}' -t "$SESS" -c "$WT/sub" 'exec sleep 120')
T set-option -w -t "$helper" @fleet_id 11111111-2222-4333-8444-555555555555
other=$(T new-window -d -P -F '#{window_id}' -t "$SESS" -c "$WT" 'exec sleep 120')
T set-option -w -t "$other" @issue 13
raw=$(T new-window -d -P -F '#{window_id}' -t "$SESS" -c "$WT" 'exec sleep 120')
T set-option -w -t "$raw" @raw 1
split=$(T new-window -d -P -F '#{window_id}' -t "$SESS" -c "$WT" 'exec sleep 120')
T split-window -d -t "$split" -c "$WORK/elsewhere" 'exec sleep 120'
away=$(T new-window -d -P -F '#{window_id}' -t "$SESS" -c "$WORK/elsewhere" 'exec sleep 120')

out=$(fleet_wt_helpers_close "$SESS" "$WT" "$reaped")
left=$(T list-windows -t "$SESS" -F '#{window_id}')

[ "$out" = "helper:$helper" ] || fail "HELPER: expected 'helper:$helper', got '$out'"
printf '%s\n' "$left" | grep -qxF "$helper" && fail "HELPER: the helper shell is still open"
[ -e "$(fleet_retired_dir)/11111111-2222-4333-8444-555555555555" ] \
  || fail "HELPER: closed without being retired first (a restore would pull it back)"
for w in "$reaped" "$other" "$raw" "$split" "$away"; do
  printf '%s\n' "$left" | grep -qxF "$w" || fail "SESSIONS: $w was closed"
done
T list-windows -t "$SESS" -F '#{window_name}' | grep -qx home || fail "HOME: the home window was closed"

printf 'selftest PASS: helper shell closed + retired · other sessions, raw, split, elsewhere, home and the reaped window kept\n'
exit 0
