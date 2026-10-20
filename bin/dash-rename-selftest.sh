#!/bin/bash
# dash-rename-selftest.sh — ⌘P's rename road: `dash-rename.sh --wid <id> [name]`
# (issue #898; the old dash's ⌃e fzf rename mode went with the dash, issue
# #4902). Drives the REAL script against an ISOLATED tmux server on its own
# socket — never the user's live server — through a `-S <sock>` PATH shim:
#
#   A. RENAME       a window id + a name renames THAT window and stamps
#                   @name_manual with the name (issue #3317)
#   B. @issue       the window's @issue binding survives the rename
#   C. EMPTY        an empty name renames nothing
#   D. SEAM         no name argument reads @rename_to off the window, then clears it
#   E. NOT AN ID    a `sess:idx` position or a bare name is never a target
#   F. TABS         a tab in the name becomes a space
#   G. NO DASH MODE a call without --wid does nothing and prints nothing
#
# tmux absent → SKIP cleanly (exit 0). Exit 0 = pass. Non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
REN="$BIN/dash-rename.sh"
[ -f "$REN" ] || { printf 'selftest: %s missing\n' "$REN" >&2; exit 2; }
st_real_tmux

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dr-selftest.XXXXXX")" || exit 2
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin"
st_tmux_socket "$WORK/bin" "$SOCK"
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH" TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
unset TMUX TMUX_PANE

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

fail() { printf 'FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '  got: %s\n' "$2" >&2; exit 1; }

tmux -f /dev/null new-session -d -s t -n first 'sleep 600' || fail "could not start the isolated tmux server"
tmux new-window -d -t t: -n second 'sleep 600'
W1=$(tmux list-windows -t t -F '#{window_id} #{window_name}' | awk '$2=="first"{print $1}')
W2=$(tmux list-windows -t t -F '#{window_id} #{window_name}' | awk '$2=="second"{print $1}')
[ -n "$W1" ] && [ -n "$W2" ] || fail "setup: no window ids"
tmux set-option -w -t "$W1" @issue 42
name() { tmux display-message -p -t "$1" '#{window_name}'; }
opt()  { tmux show-options -wqv -t "$1" "$2"; }

# --- A + B --------------------------------------------------------------------
out=$(bash "$REN" --wid "$W1" "修登录 bug")
[ -z "$out" ] || fail "A: prints nothing" "$out"
[ "$(name "$W1")" = "修登录 bug" ] || fail "A: $W1 not renamed" "$(name "$W1")"
[ "$(opt "$W1" @name_manual)" = "修登录 bug" ] || fail "A: @name_manual not stamped" "$(opt "$W1" @name_manual)"
[ "$(name "$W2")" = second ] || fail "A: another window renamed" "$(name "$W2")"
st_ok "A a window id + a name renames that window and stamps @name_manual"
[ "$(opt "$W1" @issue)" = 42 ] || fail "B: @issue lost" "$(opt "$W1" @issue)"
st_ok "B the @issue binding survives"

# --- C ------------------------------------------------------------------------
bash "$REN" --wid "$W2" ""
[ "$(name "$W2")" = second ] || fail "C: an empty name renamed" "$(name "$W2")"
[ -z "$(opt "$W2" @name_manual)" ] || fail "C: an empty name stamped @name_manual"
st_ok "C an empty name renames nothing"

# --- D ------------------------------------------------------------------------
tmux set-option -w -t "$W2" @rename_to "从选项来"
bash "$REN" --wid "$W2"
[ "$(name "$W2")" = "从选项来" ] || fail "D: @rename_to not used" "$(name "$W2")"
[ -z "$(opt "$W2" @rename_to)" ] || fail "D: @rename_to not cleared"
st_ok "D no name reads @rename_to, then clears it"

# --- E ------------------------------------------------------------------------
for t in "t:1" "first" "修登录 bug" ""; do
  bash "$REN" --wid "$t" "nope"
done
case " $(tmux list-windows -t t -F '#{window_name}' | tr '\n' ' ') " in
  *" nope "*) fail "E: a non-id target was renamed" "$(tmux list-windows -t t -F '#{window_name}' | tr '\n' ' ')" ;;
esac
st_ok "E a position or a bare name is never a target"

# --- F ------------------------------------------------------------------------
bash "$REN" --wid "$W2" "$(printf 'a\tb')"
[ "$(name "$W2")" = "a b" ] || fail "F: a tab kept" "$(name "$W2")"
st_ok "F a tab in the name becomes a space"

# --- G ------------------------------------------------------------------------
out=$(bash "$REN" "t:1" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] || fail "G: a call without --wid acted (rc $rc)" "$out"
[ "$(name "$W2")" = "a b" ] || fail "G: renamed without --wid"
st_ok "G no --wid does nothing"

printf 'PASS: dash-rename.sh --wid renames by id only\n'
exit 0
