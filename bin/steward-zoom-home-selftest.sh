#!/bin/bash
# steward-zoom-home-selftest.sh — the ⌂ hub-icon "home" contract (issue #405).
#
# The bug: the ⌂ hub icon and F9 both ran bare `steward-zoom.sh`, which is a
# PROGRESSIVE toggle — from another window it jumps to the dash/steward split, but
# pressed while ALREADY on the hub it toggles the steward pane fullscreen. So a
# single ⌂ tap from the split zoomed you to fullscreen-steward instead of keeping
# the half-dash / half-steward split. The README already frames the ⌂ as a nav tap
# ("not a pane zoom", #368); the code didn't match. The fix adds a `--home` mode
# that ALWAYS lands on the split (never zooms in) and points the ⌂ click at it,
# while F9 keeps the progressive toggle.
#
# This drives the REAL bin/steward-zoom.sh against a REAL, isolated tmux server
# (its own socket, torn down at exit — never the user's live server). A PATH shim
# forces every tmux call onto that socket, including fleet_steward_pane's explicit
# `tmux -L <label> …` (it strips a leading -L/-S so the lookup can't escape).
#
#   --home (the ⌂ tap) is CONSISTENT — from another window, from the split, from a
#     dash-zoomed hub, from a steward-zoomed hub: it always ends on the SPLIT
#     (window_zoomed_flag=0) with the steward pane focused. A tap never zooms.
#   default (F9) still PROGRESSIVELY TOGGLES — a cross-window press lands on the
#     split, but a press while already on the split zooms to fullscreen, and a
#     press while zoomed restores the split. (Same start state as the --home split
#     case, opposite result — that contrast is the whole point of the fix.)
#   STATIC GUARD — the shipped conf wires the ⌂ hub range to `--home` and leaves
#     the F9 bind on the plain toggle, and steward-zoom.sh understands --home.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$BIN/steward-zoom.sh"
CONF="$BIN/../conf/tmux-attention.conf"
[ -f "$SCRIPT" ] || { printf 'selftest: %s not found\n' "$SCRIPT" >&2; exit 2; }
[ -f "$CONF" ]   || { printf 'selftest: %s not found\n' "$CONF" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/szh-selftest.XXXXXX")" || exit 2

# Isolate every tmux call onto a private socket so we never touch the user's live
# server. The shim routes the plain `tmux` steward-zoom.sh calls there AND strips a
# leading -L/-S so fleet_steward_pane's `tmux -L <session> …` (fleet-lib.sh) lands
# on the same isolated socket instead of escaping to a `-L <session>` server.
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
case "\$1" in
  -L|-S) shift 2 ;;
esac
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
# A bare EXIT trap does NOT fire on a signal — turn INT/TERM/HUP (Ctrl-C, a CI
# timeout) into a normal exit so cleanup still reaps the isolated server instead of
# leaking it (issue #152). fleet-selftest-reap.sh backstops a SIGKILL.
trap 'exit 130' INT TERM HUP

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# --- build the hub: session 't', a 'plan' window (dash pane top / steward pane
#     bottom) + a plain 'worker' window to jump from --------------------------
tmux new-session -d -s t -n plan -x 200 -y 50 2>/dev/null || fail "could not start isolated tmux server"
tmux new-window -d -t t: -n worker
dashp="$(tmux list-panes -t t:plan -F '#{pane_id}' | head -n1)"
stewp="$(tmux split-window -d -P -F '#{pane_id}' -t "$dashp")"
[ -n "$dashp" ] && [ -n "$stewp" ] && [ "$dashp" != "$stewp" ] || fail "could not build the dash/steward split"
tmux set-option -p -t "$dashp" @dash 1
tmux set-option -p -t "$stewp" @steward 1

# --- helpers ----------------------------------------------------------------
zflag()   { tmux display-message -p -t t:plan '#{window_zoomed_flag}'; }
curwin()  { tmux display-message -p '#{window_name}'; }
planact() { tmux display-message -p -t t:plan '#{pane_id}'; }

# Force plan into a start state: $1 = active pane id, $2 = zoom (yes|no).
set_plan() {
  tmux select-window -t t:plan
  tmux select-pane -t "$1"
  [ "$(zflag)" = 1 ] && tmux resize-pane -Z -t t:plan   # normalize to unzoomed
  [ "$2" = yes ] && tmux resize-pane -Z -t "$1"         # then zoom the named pane
  return 0
}

run_zoom() { bash "$SCRIPT" "$@"; }   # the shim on PATH pins tmux to the isolated socket

# A run that must end on the SPLIT with the steward focused (the home invariant).
assert_home_split() {
  local why="$1"
  [ "$(curwin)" = plan ]     || fail "$why: expected to land on the plan hub, got '$(curwin)'"
  [ "$(zflag)" = 0 ]         || fail "$why: expected the half-dash/half-steward SPLIT, but it's zoomed"
  [ "$(planact)" = "$stewp" ] || fail "$why: expected the steward pane focused, got '$(planact)'"
}

# =====================  --home : ALWAYS the split  ==========================
# H1 — from another window: jump home to the split.
tmux select-window -t t:worker
run_zoom --home
assert_home_split "H1 --home from worker"

# H2 — already on the split (the bug): a home tap must STAY on the split, not zoom.
set_plan "$stewp" no
run_zoom --home
assert_home_split "H2 --home on the split (must not zoom)"

# H3 — dash pane zoomed: home unzooms and focuses steward.
set_plan "$dashp" yes
run_zoom --home
assert_home_split "H3 --home with the dash zoomed"

# H4 — steward pane zoomed: home unzooms back to the split.
set_plan "$stewp" yes
run_zoom --home
assert_home_split "H4 --home with the steward zoomed"

# =====================  default (F9) : PROGRESSIVE toggle  ===================
# F1 — cross-window press still lands on the split (unchanged jump).
tmux select-window -t t:worker
run_zoom
assert_home_split "F1 F9 from worker"

# F2 — on the split, a press ZOOMS to fullscreen-steward. SAME start state as H2,
# opposite result — the difference the fix introduces.
set_plan "$stewp" no
run_zoom
[ "$(curwin)" = plan ]      || fail "F2: expected to stay on the plan hub"
[ "$(zflag)" = 1 ]          || fail "F2: F9 on the split must toggle to fullscreen (progressive zoom)"
[ "$(planact)" = "$stewp" ] || fail "F2: F9 should focus the steward pane"

# F3 — pressed again while zoomed, F9 restores the split.
run_zoom
[ "$(zflag)" = 0 ] || fail "F3: a second F9 press must restore the split"

# =====================  STATIC GUARD : the shipped wiring  ==================
grep -qF 'steward-zoom.sh --home' "$CONF" \
  || fail "conf: the ⌂ hub click must run 'steward-zoom.sh --home' (issue #405)"
# the ⌂ home wiring sits in the MouseDown1Status hub branch, not on F9.
grep -Eq 'bind -n F9 .*steward-zoom\.sh( |")' "$CONF" \
  || fail "conf: expected an 'bind -n F9 … steward-zoom.sh' bind"
grep -E 'bind -n F9 .*steward-zoom\.sh' "$CONF" | grep -q -- '--home' \
  && fail "conf: F9 must stay the progressive toggle — it must NOT carry --home"
grep -qF -- '--home' "$SCRIPT" \
  || fail "steward-zoom.sh no longer understands --home (issue #405)"

printf 'selftest PASS: ⌂ --home always lands on the split; F9 keeps the progressive zoom toggle (#405)\n'
exit 0
