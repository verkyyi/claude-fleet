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
#   STATIC GUARD — the node conf reaches none of it since issue #1714 (⌂ / F9 /
#     ☰ are the client's keys; the chain retires in #1739), and hub-zoom.sh still
#     understands --home / --bar for the legs above.
#
#   DEFAULT (issue #1533) — the full-screen list retired: with no FLEET_DASH_WINDOW
#     ⌂, F9 and prefix g all end on the TASK LIST, focused (the client in the
#     fleet-sidebar key table, the list at the window's {top-left}), from every
#     start: a task with no list yet, with the list, with a name typed on it (kept),
#     zoomed, with the list switched off, from a panel window, and with NO window
#     that can show it (hub-session.sh builds `home`). F9 is three-state: focus, then
#     hide (prefix e's off), then show again. No `plan` window is ever built.
#     Every leg above runs with FLEET_DASH_WINDOW=1 — the way back, unchanged.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail
# The list is drawn on a fleet socket here: on a real node it is the client's
# only (issue #1713), so the drawer's tests take the seam fleet-sidebar.sh offers.
export FLEET_SIDEBAR_NODE=1

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
# Named after the session: fleet-sidebar.sh (the default legs) only acts on a
# server whose socket is the fleet's own label (issue #159).
SOCK="$WORK/t"
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

# The fleet's conf. FLEET_DASH_WINDOW=1 for every leg up to the default ones: they
# pin the old hub exactly. Exported BEFORE the server starts, so the list's view
# (spawned by the server) reads this conf dir too, never the operator's.
export FLEET_CONF_DIR="$WORK/conf" FLEET_HUB_VISITS_LOGDIR="$WORK/logs"
mkdir -p "$FLEET_CONF_DIR/fleets/t"
printf 'FLEET_DASH_WINDOW=1\n' > "$FLEET_CONF_DIR/fleets/t/conf"

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
# -f /dev/null: never the operator's ~/.tmux.conf — its fleet hooks would run the
# LIVE install's scripts against this server. The shipped fleet-sidebar table's
# F9 and paste-pin (C-M-S-F12, issue #1105) binds are the one piece of the conf
# the legs need: switch-client -T refuses a table that does not exist, and the
# list's view pins a navigating client by sending it that key.
tmux -f /dev/null new-session -d -s t -n plan -x 200 -y 50 'sleep 600' 2>/dev/null || fail "could not start isolated tmux server"
# A node binds neither since issue #1714 (the person's keys are the client's):
# they are this test's own fixture until the ⌂ chain retires (#1739).
cat > "$WORK/sidebar-binds.conf" <<'BINDS'
bind -T fleet-sidebar C-M-S-F12 if -F -t '{top-left}' '#{==:#{@sidebar},1}' { switch-client -T fleet-sidebar ; refresh-client -f active-pane ; select-pane -t '{top-left}' } { switch-client -T fleet-sidebar ; refresh-client -f '!active-pane' }
bind -T fleet-sidebar F9 run-shell "sh ~/.claude/fleet/bin/hub-zoom.sh --nav --client '#{client_name}'"
BINDS
tmux source-file "$WORK/sidebar-binds.conf" || fail "could not load the fleet-sidebar binds"
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
VLOG="$WORK/logs/hub-visits-t.log"
attach_bg() {
  # 200 columns: the default legs need room for the list beside a worker (111+).
  local a="stty cols 200 rows 50 2>/dev/null; exec '$REAL_TMUX' -S '$SOCK' attach -t t:worker"
  if script -q /dev/null true >/dev/null 2>&1; then           # BSD/macOS
    env -u TMUX script -q /dev/null sh -c "$a" >/dev/null 2>&1 &
  elif script -q -c true /dev/null >/dev/null 2>&1; then      # GNU/util-linux
    env -u TMUX script -q -c "$a" /dev/null >/dev/null 2>&1 &
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
  printf 'FLEET_DASH_WINDOW=1\nFLEET_HOME_SIDEBAR_FIRST=0\n' > "$FLEET_CONF_DIR/fleets/t/conf"
  on_worker
  run_zoom --home --client "$client"
  assert_home_split "S7 ⌂ with FLEET_HOME_SIDEBAR_FIRST=0"
  [ "$(ktable)" = root ] || fail "S7: knob 0 must not enter the task bar"
  on_worker
  run_zoom --client "$client"
  assert_home_split "S7 F9 with FLEET_HOME_SIDEBAR_FIRST=0"
  printf 'FLEET_DASH_WINDOW=1\n' > "$FLEET_CONF_DIR/fleets/t/conf"
  tmux set-option -uw -t t:worker @sidebar_worker

  # ===================  DEFAULT: the list is home (issue #1533)  ==============
  # No FLEET_DASH_WINDOW: the real fleet-sidebar.sh home draws the real list.
  # The worker becomes a task (@issue); `plan` stays as an OLD fleet's leftover.
  printf 'FLEET_SIDEBAR=1\n' > "$FLEET_CONF_DIR/fleets/t/conf"
  tmux set-option -g default-shell /bin/sh
  tmux set-option -w -t t:worker @issue 7
  run_new() { TMUX="$SOCK,1,0" bash --posix "$SCRIPT" "$@"; }
  on_list() {   # $1 = why, $2 = the window it must end in
    [ "$(ktable)" = fleet-sidebar ] || fail "$1: key table '$(ktable)', want fleet-sidebar (the list focused)"
    [ "$(curwin)" = "$2" ] || fail "$1: ended on '$(curwin)', want '$2'"
    [ "$(tmux display-message -p '#{window_zoomed_flag}')" = 0 ] || fail "$1: the window is still zoomed"
    [ "$(tmux display-message -p -t '{top-left}' '#{@sidebar}')" = 1 ] || fail "$1: no list on the window's left"
    [ -n "$(tmux display-message -p '#{@sidebar_worker}')" ] || fail "$1: the window carries no @sidebar_worker"
  }
  sconf() { grep '^FLEET_SIDEBAR=' "$FLEET_CONF_DIR/fleets/t/conf" | tail -n1; }
  view() { tmux display-message -p -t 't:worker.{top-left}' '#{?#{==:#{@sidebar},1},#{pane_id},}'; }
  plans() { tmux list-windows -t t -F '#{window_name}' | grep -c '^plan$'; }

  # D1 — a task with no list drawn yet: ⌂ draws it and focuses it.
  on_worker
  run_new --home --client "$client"
  on_list "D1 ⌂ in a task with no list yet" worker
  [ "$(lastcause)" = home-sidebar ] || fail "D1: hub-visit cause '$(lastcause)', want home-sidebar"
  # D2 — the list on screen: ⌂ focuses it, nothing else moves.
  on_worker
  run_new --home --client "$client"
  on_list "D2 ⌂ with the list on screen" worker
  # D3 — a name half-typed on its input line: focused, and the name is KEPT
  #      (the old hub-zoom.sh left the task for the hub here).
  v=$(view); [ -n "$v" ] || fail "D3: no view to type into"
  tmux send-keys -t "$v" -l ab
  for _ in $(seq 1 50); do [ -n "$(tmux display-message -p -t "$v" '#{@sidebar_input}')" ] && break; sleep 0.1; done
  [ -n "$(tmux display-message -p -t "$v" '#{@sidebar_input}')" ] || fail "D3: the view never marked its input line"
  on_worker
  run_new --home --client "$client"
  on_list "D3 ⌂ with a name typed on the list" worker
  [ -n "$(tmux display-message -p -t "$v" '#{@sidebar_input}')" ] || fail "D3: ⌂ cleared the typed name"
  tmux send-keys -t "$v" Escape
  # D4 — a zoomed task (no list on screen): unzoomed, list drawn, focused.
  wside="$(tmux split-window -d -P -F '#{pane_id}' -t t:worker 'sleep 600')"
  on_worker; tmux resize-pane -Z -t "$wside"
  run_new --home --client "$client"
  on_list "D4 ⌂ from a zoomed task" worker
  tmux kill-pane -t "$wside"
  # D5 — the list switched off (prefix e): ⌂ switches it back on.
  TMUX="$SOCK,1,0" bash "$BIN/fleet-sidebar.sh" hide t
  [ "$(sconf)" = FLEET_SIDEBAR=0 ] || fail "D5 setup: hide did not switch the list off ($(sconf))"
  [ -z "$(view)" ] || fail "D5 setup: the list is still drawn after hide"
  on_worker
  run_new --home --client "$client"
  on_list "D5 ⌂ with the list switched off" worker
  [ "$(sconf)" = FLEET_SIDEBAR=1 ] || fail "D5: ⌂ must switch the list back on ($(sconf))"
  # D6 — from a window that cannot show it (an old fleet's plan): the last task.
  on_worker; tmux select-window -t t:plan
  run_new --home --client "$client"
  on_list "D6 ⌂ from the old plan window" worker
  # D7 — F9 is three-state: focus · hide · show again.
  on_worker
  run_new --client "$client"
  on_list "D7 F9 first press" worker
  [ "$(lastcause)" = f9-sidebar ] || fail "D7: hub-visit cause '$(lastcause)', want f9-sidebar"
  run_new --nav --client "$client"
  [ "$(ktable)" = root ] || fail "D7 F9 second press: key table '$(ktable)', want root"
  [ -z "$(view)" ] || fail "D7 F9 second press: the list must be hidden"
  [ "$(sconf)" = FLEET_SIDEBAR=0 ] || fail "D7 F9 second press: hidden like prefix e ($(sconf))"
  run_new --client "$client"
  on_list "D7 F9 third press" worker
  [ "$(sconf)" = FLEET_SIDEBAR=1 ] || fail "D7 F9 third press: the list must be back on"
  # ⌂ from the list itself (the fleet-sidebar table's own status click: --nav) stays.
  run_new --home --nav --client "$client"
  on_list "D7 ⌂ pressed on the list" worker
  # D8 — prefix g lands in the same place.
  on_worker
  TMUX="$SOCK,1,0" bash --posix "$BIN/dash-zoom.sh"
  on_list "D8 prefix g" worker
  # D9 — no window can show the list (no task, no home): hub-session.sh builds
  #      `home`, the list draws beside its shell, focused. Still no new plan.
  on_worker; tmux set-option -uw -t t:worker @issue; tmux select-window -t t:plan
  run_new --home --client "$client"
  on_list "D9 ⌂ with no window that can show the list" home
  [ "$(tmux list-windows -t t -F '#{window_name}' | grep -c '^home$')" = 1 ] || fail "D9: want exactly one home window"
  [ "$(plans)" = 1 ] || fail "default: a plan window was built ($(plans) now)"
  # D10 — ☰ (--bar, issue #1616) is the list's switch and nothing else: shown →
  #       hidden, hidden → shown; never a focus, never another window.
  tmux set-option -w -t t:worker @issue 7
  TMUX="$SOCK,1,0" bash "$BIN/fleet-sidebar.sh" hide t
  on_worker
  run_new --bar --client "$client"
  [ -n "$(view)" ] || fail "D10 ☰ on a hidden list: the list must be drawn"
  [ "$(sconf)" = FLEET_SIDEBAR=1 ] || fail "D10 ☰ on a hidden list: switched back on ($(sconf))"
  [ "$(ktable)" = root ] || fail "D10 ☰ must not focus the list (key table '$(ktable)')"
  [ "$(curwin)" = worker ] || fail "D10 ☰ left the window for '$(curwin)'"
  [ "$(lastcause)" = bar-sidebar ] || fail "D10: hub-visit cause '$(lastcause)', want bar-sidebar"
  run_new --bar --client "$client"
  [ -z "$(view)" ] || fail "D10 ☰ on a shown list: the list must be hidden"
  [ "$(sconf)" = FLEET_SIDEBAR=0 ] || fail "D10 ☰ on a shown list: hidden like prefix e ($(sconf))"
  [ "$(ktable)" = root ] || fail "D10 ☰ hide: key table '$(ktable)'"
  [ "$(curwin)" = worker ] || fail "D10 ☰ hide left the window for '$(curwin)'"
  run_new --bar --client "$client"
  tmux switch-client -c "$client" -T fleet-sidebar
  run_new --bar --client "$client"
  [ -z "$(view)" ] || fail "D10 ☰ with the keyboard on the list: hidden all the same"
  [ "$(plans)" = 1 ] || fail "D10: ☰ built a plan window ($(plans) now)"
fi

# =====================  STATIC GUARD : the node binds none of it  ===========
# ⌂ / F9 / ☰ / prefix g left the node with the person's keys (issue #1714, EPIC
# #1710 C4): nothing in the node conf reaches hub-zoom.sh any more — the script
# and the legs above stay until the chain retires (#1739).
grep -v '^[[:space:]]*#' "$CONF" | grep -qE 'hub-zoom\.sh|dash-zoom\.sh|mouse_status_range' \
  && fail "conf: the node conf reaches the ⌂ chain again (#1714)"
grep -qF -- '--bar' "$SCRIPT" \
  || fail "hub-zoom.sh no longer understands --bar (issue #1616)"
grep -qF -- '--home' "$SCRIPT" \
  || fail "hub-zoom.sh no longer understands --home (issue #405)"

printf 'selftest PASS: by default ⌂ / F9 / prefix g always end on the task list, focused, and no plan window is built (#1533); ☰ only shows / hides it (#1616); with FLEET_DASH_WINDOW=1 ⌂ --home lands unzoomed on the DASH, F9 keeps the zoom toggle (#405), both land on the task bar first (#899)\n'
exit 0
