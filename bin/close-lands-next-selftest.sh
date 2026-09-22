#!/bin/bash
# close-lands-next-selftest.sh — closing a task lands on its neighbour (issue #900).
#
# Closing the window you are on used to leave the client wherever tmux chose —
# usually the hub. Now fleet-sidebar.py publishes, for the task on screen, the
# ordered landing candidates (`@sidebar_next`, pinned to that window by
# `@sidebar_next_of`), and the hub-arrival hook (session-window-changed[73] →
# fleet-hub-visits.sh record) moves a `closed` arrival on to the first candidate
# that is alive, awake and not a panel, logging `closed-next`. Asserts:
#   • landing(): rows below first, then above nearest-first; not in list ⇒ none
#   • 3 tasks + hub, close the middle one → lands on the third, `closed-next`
#   • close the last one → lands on the one before it
#   • only the hub left → stays on the hub, `closed`
#   • a sleeping neighbour is skipped (never woken), a dead one too
#   • F9 onto the hub is never rewritten
#   • candidates published for ANOTHER window are ignored
#   • FLEET_CLOSE_LANDS_NEXT=0 → today's behaviour exactly (hub, `closed`)
#
# Drives the SHIPPED [73] hook lines (~/.claude/fleet rewritten to this checkout)
# on an ISOLATED tmux server — a PATH shim pins every tmux call, including the
# hook's `tmux -S <socket_path>`, to a private socket. tmux absent → SKIP.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CONF="$BIN/../conf/tmux-attention.conf"
REAL_TMUX="$(command -v tmux 2>/dev/null)"

fail() {
  printf 'selftest FAIL: %s\n' "$1" >&2
  [ -f "${LOG:-}" ] && { printf -- '--- %s ---\n' "$LOG" >&2; cat "$LOG" >&2; }
  exit 1
}

# --- landing(): the pure ordering rule ----------------------------------------
got="$(python3 - "$BIN/fleet-sidebar.py" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sb", sys.argv[1])
sb = importlib.util.module_from_spec(spec); spec.loader.exec_module(sb)
ids = ["@1", "@2", "@3", "@4"]
for w in ("@2", "@4", "@1", "@9"):
    print(w + "=" + ",".join(sb.landing(ids, w)))
print("cap", len(sb.landing([f"@{i}" for i in range(20)], "@0")))
EOF
)" || fail "landing(): python import failed"
want='@2=@3,@4,@1
@4=@3,@2,@1
@1=@2,@3,@4
@9=
cap 8'
[ "$got" = "$want" ] || fail "landing() ordering: got
$got"

[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — tmux legs SKIPPED\n' >&2; printf 'close-lands-next-selftest: PASS\n'; exit 0; }

grep -q '@sidebar_next' "$BIN/fleet-sidebar.py" || fail "static: fleet-sidebar.py does not publish @sidebar_next"
grep -q '^#FLEET_CLOSE_LANDS_NEXT=1$' "$BIN/../fleet.conf.example" || fail "static: FLEET_CLOSE_LANDS_NEXT missing from fleet.conf.example"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cln-selftest.XXXXXX")" || exit 2
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin" "$WORK/logs" "$WORK/conf/fleets/t"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
case "\$1" in
  -L|-S) shift 2 ;;
esac
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
# The server starts from THIS environment, so the hook's run-shell jobs inherit
# the sandbox log + conf dirs (the knob is read through fleet-hook-conf.sh).
export FLEET_HUB_VISITS_LOGDIR="$WORK/logs" FLEET_CONF_DIR="$WORK/conf"
: > "$WORK/conf/fleets/t/conf"
LOG="$WORK/logs/hub-visits-t.log"

# shellcheck disable=SC2329  # invoked via the EXIT trap below
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

lines() { if [ -f "$LOG" ]; then wc -l < "$LOG" | tr -d ' '; else echo 0; fi; }
N=0
# One hub arrival → one log line (async, from run-shell -b); then let any
# redirect's select-window settle.
arrived() {
  N=$((N + 1))
  local i=0
  while [ "$i" -lt 50 ] && [ "$(lines)" -lt "$N" ]; do sleep 0.1; i=$((i + 1)); done
  sleep 0.3
  [ "$(lines)" = "$N" ] || fail "$1: expected $N log line(s), got $(lines)"
}
cause() { tail -n 1 "$LOG" | cut -f3; }
here()  { tmux display-message -p -t t '#{window_name}'; }
wid()   { tmux display-message -p -t "t:$1" '#{window_id}'; }
# What the sidebar publishes while $1 is on screen, given the list order $2…
publish() {
  local on="$1"; shift
  local ids=() n
  for n in "$@"; do ids+=("$(wid "$n")"); done
  nxt="$(python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("sb",sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
print(" ".join(m.landing(sys.argv[3:],sys.argv[2])))' "$BIN/fleet-sidebar.py" "$(wid "$on")" ${ids[@]+"${ids[@]}"})"
  tmux set-option -t t: @sidebar_next "$nxt" \; set-option -t t: @sidebar_next_of "$(wid "$on")"
}
# Open task window $1 (dies with the pane's sleep).
task() { tmux new-window -d -t t: -n "$1" 'sleep 600'; }

tmux -f /dev/null new-session -d -s t -n plan -x 160 -y 40 'sleep 600' 2>/dev/null || fail "could not start isolated tmux server"
tmux set-option -p -t t:plan @dash 1
task w1; task w2; task w3
grep '\[73\]' "$CONF" | grep '^set-hook' | sed "s#~/.claude/fleet#$BIN/..#g" > "$WORK/hooks.conf"
tmux source-file "$WORK/hooks.conf" || fail "the shipped [73] hook lines do not parse"
# tmux lands a close on the LAST window; make that the hub, as it is in life.
# (Passing through the hub may log an `other` arrival; resync the count after.)
land_on_hub_premise() {
  tmux select-window -t t:plan; sleep 0.5; N=$(lines)
  tmux select-window -t "t:$1"
}

# 1. close the middle task → the third.
land_on_hub_premise w2
publish w2 w1 w2 w3
tmux kill-window -t t:w2
arrived "close middle"
[ "$(cause)" = closed-next ] || fail "close middle: cause '$(cause)', want closed-next"
[ "$(here)" = w3 ] || fail "close middle: landed on '$(here)', want w3"

# 2. close the last task → the one before it.
land_on_hub_premise w3
publish w3 w1 w3
tmux kill-window -t t:w3
arrived "close last"
[ "$(cause)" = closed-next ] || fail "close last: cause '$(cause)', want closed-next"
[ "$(here)" = w1 ] || fail "close last: landed on '$(here)', want w1"

# 3. only the hub left → the hub, `closed`.
land_on_hub_premise w1
publish w1 w1
tmux kill-window -t t:w1
arrived "close only"
[ "$(cause)" = closed ] || fail "close only: cause '$(cause)', want closed"
[ "$(here)" = plan ] || fail "close only: landed on '$(here)', want the hub"

# 4. a sleeping neighbour is skipped (and stays asleep); a closed one too.
task a; task b; task c; task d
tmux set-option -w -t t:b @worker_lifecycle sleeping
land_on_hub_premise a
publish a a b c d
tmux kill-window -t t:c
tmux kill-window -t t:a
arrived "skip sleeping"
[ "$(cause)" = closed-next ] || fail "skip: cause '$(cause)', want closed-next"
[ "$(here)" = d ] || fail "skip: landed on '$(here)', want d (b sleeps, c is gone)"
[ "$(tmux show-option -wqv -t t:b @worker_lifecycle)" = sleeping ] || fail "skip: the sleeping neighbour was touched"

# 5. F9 onto the hub is never rewritten.
publish d b d
bash --posix "$BIN/hub-zoom.sh"
arrived "F9"
[ "$(cause)" = f9 ] || fail "F9: cause '$(cause)', want f9"
[ "$(here)" = plan ] || fail "F9: landed on '$(here)', want the hub"

# 6. candidates published for another window are ignored.
task e
tmux select-window -t t:d
publish e b d e
land_on_hub_premise e
tmux set-option -t t: @sidebar_next_of "$(wid d)"
tmux kill-window -t t:e
arrived "stale candidates"
[ "$(cause)" = closed ] || fail "stale: cause '$(cause)', want closed"
[ "$(here)" = plan ] || fail "stale: landed on '$(here)', want the hub"

# 7. the knob off → today's behaviour exactly.
printf 'FLEET_CLOSE_LANDS_NEXT=0\n' > "$WORK/conf/fleets/t/conf"
task f
land_on_hub_premise f
publish f d f
tmux kill-window -t t:f
arrived "knob off"
[ "$(cause)" = closed ] || fail "knob off: cause '$(cause)', want closed"
[ "$(here)" = plan ] || fail "knob off: landed on '$(here)', want the hub"

printf 'close-lands-next-selftest: PASS\n'
exit 0
