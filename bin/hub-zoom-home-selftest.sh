#!/bin/bash
# hub-zoom-home-selftest.sh — the ⌂ hub-icon "home" contract (issue #405).
#
# The bug: the ⌂ hub icon and F9 both ran bare `hub-zoom.sh`, which is a
# PROGRESSIVE toggle — from another window it jumps to the dash/hub split, but
# pressed while ALREADY on the hub it toggles the hub pane fullscreen. So a
# single ⌂ tap from the split zoomed you to fullscreen-hub instead of keeping
# the half-dash / half-hub split. The README already frames the ⌂ as a nav tap
# ("not a pane zoom", #368); the code didn't match. The fix adds a `--home` mode
# that ALWAYS lands on the split (never zooms in) and points the ⌂ click at it,
# while F9 keeps the progressive toggle.
#
# This drives the REAL bin/hub-zoom.sh against a REAL, isolated tmux server
# (its own socket, torn down at exit — never the user's live server). A PATH shim
# forces every tmux call onto that socket, including fleet_hub_pane's explicit
# `tmux -L <label> …` (it strips a leading -L/-S so the lookup can't escape).
#
# It also drives via `bash --posix` (see run_zoom below) to reproduce the
# production /bin/sh the conf actually uses — closing the issue #414 fidelity gap
# where the old `bash "$SCRIPT"` harness masked a fleet-lib.sh bashism that broke
# the ⌂ under real sh. The POSIX-parse net itself lives in posix-lib-parse-selftest.sh.
#
#   --home (the ⌂ tap) is CONSISTENT — from another window, from the split, from a
#     dash-zoomed hub, from a hub-zoomed hub: it always ends on the SPLIT
#     (window_zoomed_flag=0) with the hub pane focused. A tap never zooms.
#   default (F9) still PROGRESSIVELY TOGGLES — a cross-window press lands on the
#     split, but a press while already on the split zooms to fullscreen, and a
#     press while zoomed restores the split. (Same start state as the --home split
#     case, opposite result — that contrast is the whole point of the fix.)
#   STATIC GUARD — the shipped conf wires the ⌂ hub range to `--home` and leaves
#     the F9 bind on the plain toggle, and hub-zoom.sh understands --home.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$BIN/hub-zoom.sh"
CONF="$BIN/../conf/tmux-attention.conf"
[ -f "$SCRIPT" ] || { printf 'selftest: %s not found\n' "$SCRIPT" >&2; exit 2; }
[ -f "$CONF" ]   || { printf 'selftest: %s not found\n' "$CONF" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/szh-selftest.XXXXXX")" || exit 2

# Isolate every tmux call onto a private socket so we never touch the user's live
# server. The shim routes the plain `tmux` hub-zoom.sh calls there AND strips a
# leading -L/-S so fleet_hub_pane's `tmux -L <session> …` (fleet-lib.sh) lands
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

# --- build the hub: session 't', a 'plan' window + a plain 'worker' window to
#     jump from. Every pane runs `sleep`, not a login shell: once the task-bar
#     legs attach a real client, an interactive shell's profile could end its pane
#     and take the window the assertions are about with it.
# The hub is DASH-ONLY, so there is no @hub pane to target. The second pane here
# is NOT a hub Claude - it stands in for a pane the OPERATOR split in by hand, and
# carries no marker. It exists so the zoom half of the contract stays testable
# (tmux will not set window_zoomed_flag on a single-pane window), and so the
# assertions below actually prove hub-zoom homes on the DASH rather than on
# "whatever pane happens to be there". -------------------------------------
tmux new-session -d -s t -n plan -x 200 -y 50 'sleep 600' 2>/dev/null || fail "could not start isolated tmux server"
tmux new-window -d -t t: -n worker 'sleep 600'
dashp="$(tmux list-panes -t t:plan -F '#{pane_id}' | head -n1)"
sidep="$(tmux split-window -d -P -F '#{pane_id}' -t "$dashp" 'sleep 600')"
[ -n "$dashp" ] && [ -n "$sidep" ] && [ "$dashp" != "$sidep" ] || fail "could not build the plan window"
tmux set-option -p -t "$dashp" @dash 1

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

# FIDELITY (issue #414): the conf invokes this via `run-shell "sh …/hub-zoom.sh"`,
# and the operator's production /bin/sh is bash in POSIX MODE — where process
# substitution `<(…)` is DISABLED. hub-zoom.sh sources fleet-lib.sh, so a
# `<(…)` in the lib is a syntax error there, sourcing aborts, and fleet_hub_pane
# is left undefined → the ⌂ falls into the hub-rebuild path and never unzooms. The
# old harness ran `bash "$SCRIPT"`, where `<(…)` is valid, so the lib parsed and H4
# passed against the BROKEN lib — a false green. Drive through `bash --posix`, which
# reproduces that production shell on ANY host: it disables `<(…)` (so H4 fails
# against the un-fixed lib, as it must) yet supports hub-zoom.sh's own
# `set -o pipefail` — unlike a literal `sh`, which is dash on CI and has no pipefail.
run_zoom() { bash --posix "$SCRIPT" "$@"; }   # PATH shim pins tmux to the isolated socket

# A run that must end on the plan window, UNZOOMED, with the DASH focused (the
# home invariant). It used to require the hub pane focused; the dash is the hub now.
assert_home_split() {
  local why="$1"
  [ "$(curwin)" = plan ]      || fail "$why: expected to land on the plan hub, got '$(curwin)'"
  [ "$(zflag)" = 0 ]          || fail "$why: expected an UNZOOMED hub, but it is zoomed"
  [ "$(planact)" = "$dashp" ] || fail "$why: expected the dash pane focused, got '$(planact)'"
}

# =====================  --home : ALWAYS the split  ==========================
# H1 — from another window: jump home to the split.
tmux select-window -t t:worker
run_zoom --home
assert_home_split "H1 --home from worker"

# H2 — already on the split (the bug): a home tap must STAY on the split, not zoom.
set_plan "$sidep" no
run_zoom --home
assert_home_split "H2 --home already on the hub (must not zoom)"

# H3 — dash pane zoomed: home unzooms, dash still focused.
set_plan "$dashp" yes
run_zoom --home
assert_home_split "H3 --home with the dash zoomed"

# H4 — another pane zoomed: home unzooms and returns focus to the dash.
set_plan "$sidep" yes
run_zoom --home
assert_home_split "H4 --home with another pane zoomed"

# =====================  default (F9) : PROGRESSIVE toggle  ===================
# F1 — cross-window press still lands on the split (unchanged jump).
tmux select-window -t t:worker
run_zoom
assert_home_split "F1 F9 from worker"

# F2 — already on the hub, a press ZOOMS the dash to fullscreen. SAME start state
# as H2, opposite result — the difference #405 introduced.
set_plan "$sidep" no
run_zoom
[ "$(curwin)" = plan ]      || fail "F2: expected to stay on the plan hub"
[ "$(zflag)" = 1 ]          || fail "F2: F9 on the hub must toggle to fullscreen (progressive zoom)"
[ "$(planact)" = "$dashp" ] || fail "F2: F9 should focus the dash pane"

# F3 — pressed again while zoomed, F9 restores the unzoomed hub.
run_zoom
[ "$(zflag)" = 0 ] || fail "F3: a second F9 press must restore the unzoomed hub"

# =====================  TASK BAR FIRST (issue #899)  =========================
# In a task that shows the task bar, the first ⌂ / F9 puts the keyboard on the bar
# (client key table fleet-sidebar) and stays in the task; the second press — which
# the conf's fleet-sidebar-table binds pass as --nav — goes to the hub. Needs a
# real client for the key table: a pty via `script`, as hub-visits-selftest does.
export FLEET_CONF_DIR="$WORK/conf" FLEET_HUB_VISITS_LOGDIR="$WORK/logs"
VLOG="$WORK/logs/hub-visits-t.log"
attach_bg() {
  if script -q /dev/null true >/dev/null 2>&1; then           # BSD/macOS
    script -q /dev/null tmux -S "$SOCK" attach -t t:worker >/dev/null 2>&1 &
  elif script -q -c true /dev/null >/dev/null 2>&1; then      # GNU/util-linux
    script -q -c "$REAL_TMUX -S '$SOCK' attach -t t:worker" /dev/null >/dev/null 2>&1 &
  else
    return 1
  fi
}
client=''
if attach_bg; then
  for _ in $(seq 1 50); do
    client=$(tmux list-clients -F '#{client_name}' 2>/dev/null | head -n1)
    [ -n "$client" ] && break
    sleep 0.1
  done
fi
if [ -z "$client" ]; then
  printf 'selftest: no pty client (no usable `script`) — task-bar-first legs SKIPPED\n' >&2
else
  ktable()   { tmux list-clients -F '#{client_key_table}' | head -n1; }
  on_worker() { tmux switch-client -c "$client" -T root; tmux select-window -t t:worker; }
  lastcause() { tail -n1 "$VLOG" 2>/dev/null | cut -f3; }
  tmux set-option -w -t t:worker @sidebar_worker 1

  # S1 — ⌂ in a task with a task bar: the bar takes the keyboard, window unchanged,
  #      and the meter records the trip that did not happen.
  on_worker
  run_zoom --home --client "$client"
  [ "$(ktable)" = fleet-sidebar ] || fail "S1 first ⌂: key table is '$(ktable)', want fleet-sidebar"
  [ "$(curwin)" = worker ]        || fail "S1 first ⌂: left the task for '$(curwin)'"
  [ "$(lastcause)" = home-sidebar ] || fail "S1 first ⌂: hub-visit cause '$(lastcause)', want home-sidebar"
  # S2 — ⌂ again, from the bar (the fleet-sidebar bind adds --nav): the hub, unzoomed.
  run_zoom --home --nav --client "$client"
  assert_home_split "S2 second ⌂ from the task bar"

  # S3/S4 — the same two presses for F9.
  on_worker
  run_zoom --client "$client"
  [ "$(ktable)" = fleet-sidebar ] || fail "S3 first F9: key table is '$(ktable)', want fleet-sidebar"
  [ "$(curwin)" = worker ]        || fail "S3 first F9: left the task for '$(curwin)'"
  [ "$(lastcause)" = f9-sidebar ] || fail "S3 first F9: hub-visit cause '$(lastcause)', want f9-sidebar"
  run_zoom --nav --client "$client"
  assert_home_split "S4 second F9 from the task bar"

  # S5 — a zoomed task shows no bar: ⌂ keeps "never stay zoomed" and goes home.
  wside="$(tmux split-window -d -P -F '#{pane_id}' -t t:worker 'sleep 600')"
  on_worker; tmux resize-pane -Z -t t:worker
  run_zoom --home --client "$client"
  assert_home_split "S5 ⌂ from a zoomed task"
  [ "$(ktable)" = root ] || fail "S5: a zoomed task must not enter the task bar"
  tmux kill-pane -t "$wside"

  # S6 — a name half-typed on the bar's input line (@sidebar_input on the view, the
  #      window's {top-left} pane — issue #896): straight home, the text is kept.
  on_worker; tmux set-option -p -t 't:worker.{top-left}' @sidebar_input 1
  run_zoom --home --client "$client"
  assert_home_split "S6 ⌂ while the task bar is typing"
  tmux set-option -up -t 't:worker.{top-left}' @sidebar_input

  # S7 — the knob off: word for word today's behaviour, first press goes home.
  mkdir -p "$FLEET_CONF_DIR/fleets/t"
  printf 'FLEET_HOME_SIDEBAR_FIRST=0\n' > "$FLEET_CONF_DIR/fleets/t/conf"
  on_worker
  run_zoom --home --client "$client"
  assert_home_split "S7 ⌂ with FLEET_HOME_SIDEBAR_FIRST=0"
  [ "$(ktable)" = root ] || fail "S7: knob 0 must not enter the task bar"
  on_worker
  run_zoom --client "$client"
  assert_home_split "S7 F9 with FLEET_HOME_SIDEBAR_FIRST=0"
  rm -f "$FLEET_CONF_DIR/fleets/t/conf"
  tmux set-option -uw -t t:worker @sidebar_worker
fi

# =====================  STATIC GUARD : the shipped wiring  ==================
grep -qF 'hub-zoom.sh --home' "$CONF" \
  || fail "conf: the ⌂ hub click must run 'hub-zoom.sh --home' (issue #405)"
# the ⌂ home wiring sits in the MouseDown1Status hub branch, not on F9.
grep -Eq 'bind -n F9 .*hub-zoom\.sh( |")' "$CONF" \
  || fail "conf: expected an 'bind -n F9 … hub-zoom.sh' bind"
grep -E 'bind -n F9 .*hub-zoom\.sh' "$CONF" | grep -q -- '--home' \
  && fail "conf: F9 must stay the progressive toggle — it must NOT carry --home"
grep -qF -- '--home' "$SCRIPT" \
  || fail "hub-zoom.sh no longer understands --home (issue #405)"
# Task bar first (#899): the SECOND press only reaches hub-zoom.sh as --nav through
# the fleet-sidebar table's own binds, and that table's status click must still
# serve every other status range the root one does (a bound key never falls through).
grep -Eq '^bind -T fleet-sidebar F9 .*hub-zoom\.sh --nav' "$CONF" \
  || fail "conf: the fleet-sidebar table needs an F9 bind running 'hub-zoom.sh --nav' (#899)"
navclick=$(grep -E '^bind -T fleet-sidebar MouseDown1Status ' "$CONF")
printf '%s\n' "$navclick" | grep -qF 'hub-zoom.sh --home --nav' \
  || fail "conf: the fleet-sidebar status click must run 'hub-zoom.sh --home --nav' on the ⌂ (#899)"
for leg in fleet-pick.sh 'next-attention.sh --needs-cycle' usage-modal.sh fleet-xfleet-jump.sh; do
  grep -qF -- "$leg" "$CONF" || continue
  printf '%s\n' "$navclick" | grep -qF -- "$leg" \
    || fail "conf: the fleet-sidebar status click lost the root click's '$leg' range"
done
grep -Eq '^bind -n F9 .*--client' "$CONF" \
  || fail "conf: the root F9 must pass --client so the right client's table switches (#899)"

printf 'selftest PASS: ⌂ --home always lands unzoomed on the DASH; F9 keeps the progressive zoom toggle (#405); both land on the task bar first (#899)\n'
exit 0
