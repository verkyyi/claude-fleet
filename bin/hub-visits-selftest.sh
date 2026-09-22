#!/bin/bash
# hub-visits-selftest.sh — the hub-visit meter (issue #897).
#
# Every arrival on the hub window must append exactly ONE `ts<TAB>from<TAB>cause`
# line to logs/hub-visits-<session>.log, with the cause naming what sent you:
#   f9 / home / g — hub-zoom.sh / hub-zoom.sh --home / dash-zoom.sh (a one-shot
#                   @hub_nav_via stamp the session-window-changed[73] hook reads)
#   closed        — the window you were on was killed and tmux dropped you there
#   attach        — a client attached onto the hub
#   other         — any other switch (prefix n/p, a click)
# and switching BETWEEN non-hub windows must write nothing. The summary
# (`fleet-hub-visits.sh --since 1h`) must group those by cause, count repeat
# arrivals within one second once, and keep `attach` out of the total.
#
# Drives the SHIPPED hook lines from conf/tmux-attention.conf (the [73] ones,
# with ~/.claude/fleet rewritten to this checkout) and the REAL hub-zoom.sh /
# dash-zoom.sh against an ISOLATED tmux server — a PATH shim pins every tmux
# call, including the hook's `tmux -S <socket_path>`, to a private socket.
#
# tmux absent → SKIP (exit 0). The attach leg needs a pty client via `script`;
# where neither BSD nor GNU `script` works it SKIPs that leg only.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CONF="$BIN/../conf/tmux-attention.conf"
HV="$BIN/fleet-hub-visits.sh"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hv-selftest.XXXXXX")" || exit 2
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin" "$WORK/logs"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
case "\$1" in
  -L|-S) shift 2 ;;
esac
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
# The server is started from THIS environment, so the hook's run-shell jobs
# inherit the sandbox log dir.
export FLEET_HUB_VISITS_LOGDIR="$WORK/logs"
LOG="$WORK/logs/hub-visits-t.log"

CLIENT_PID=
cleanup() {
  [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null
  tmux kill-server 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

fail() {
  printf 'selftest FAIL: %s\n' "$1" >&2
  [ -f "$LOG" ] && { printf -- '--- %s ---\n' "$LOG" >&2; cat "$LOG" >&2; }
  exit 1
}
lines() { if [ -f "$LOG" ]; then wc -l < "$LOG" | tr -d ' '; else echo 0; fi; }
# The hook writes from `run-shell -b`, i.e. asynchronously: wait for line N.
wait_lines() {
  local want="$1" i=0
  while [ "$i" -lt 40 ]; do
    [ "$(lines)" -ge "$want" ] && break
    sleep 0.1; i=$((i + 1))
  done
  sleep 0.2   # and give a wrongly-extra line the chance to show up
  [ "$(lines)" = "$want" ] || fail "$2: expected $want log line(s), got $(lines)"
}
last_cause() { tail -n 1 "$LOG" | cut -f3; }
last_from()  { tail -n 1 "$LOG" | cut -f2; }

# --- static: the shipped wiring --------------------------------------------
grep -q '^set-hook -g session-window-changed\[73\] .*fleet-hub-visits.sh record' "$CONF" \
  || fail "static: conf lacks the session-window-changed[73] hub-visit hook"
grep -q '^set-hook -g client-attached\[73\] .*fleet-hub-visits.sh record.* attach ' "$CONF" \
  || fail "static: conf lacks the client-attached[73] attach hook"
grep -q '@hub_nav_via home' "$BIN/hub-zoom.sh" && grep -q '@hub_nav_via f9' "$BIN/hub-zoom.sh" \
  || fail "static: hub-zoom.sh does not stamp @hub_nav_via home/f9"
grep -q '@hub_nav_via g' "$BIN/dash-zoom.sh" || fail "static: dash-zoom.sh does not stamp @hub_nav_via g"

# --- the isolated fleet: plan (the @dash hub) + two workers ----------------
# Panes run `sleep`, not a login shell: a shell's rc files are the operator's,
# and one that exits on attach would take the @dash pane with it.
tmux -f /dev/null new-session -d -s t -n plan -x 160 -y 40 'sleep 600' 2>/dev/null || fail "could not start isolated tmux server"
tmux set-option -p -t t:plan @dash 1
tmux new-window -d -t t: -n w1 'sleep 600'
tmux new-window -d -t t: -n w2 'sleep 600'
tmux set-option -w -t t:w1 @wid a1
w2id="$(tmux display-message -p -t t:w2 '#{window_id}')"
grep '\[73\]' "$CONF" | grep '^set-hook' | sed "s#~/.claude/fleet#$BIN/..#g" > "$WORK/hooks.conf"
tmux source-file "$WORK/hooks.conf" || fail "the shipped [73] hook lines do not parse"

# 1. switches between non-hub windows write nothing.
tmux select-window -t t:w1
tmux select-window -t t:w2
tmux select-window -t t:w1
wait_lines 0 "non-hub switches"

# 2. F9 (hub-zoom.sh, as the conf runs it: POSIX sh) from w1 → f9, from a1.
bash --posix "$BIN/hub-zoom.sh"
wait_lines 1 "F9"
[ "$(last_cause)" = f9 ] || fail "F9: cause is '$(last_cause)', want f9"
[ "$(last_from)" = a1 ]  || fail "F9: from is '$(last_from)', want the @wid handle a1"

# The summary counts repeat arrivals within one second ONCE (EPIC #894's reading
# rule), so each counted arrival below starts on a fresh second.
tick() { sleep 1.05; }

# 3. the ⌂ tap (hub-zoom.sh --home) from w2 → home, from the window id (no @wid).
tmux select-window -t t:w2
tick
bash --posix "$BIN/hub-zoom.sh" --home
wait_lines 2 "home"
[ "$(last_cause)" = home ]   || fail "home: cause is '$(last_cause)', want home"
[ "$(last_from)" = "$w2id" ] || fail "home: from is '$(last_from)', want $w2id"

# 3b. F9 / ⌂ pressed while ALREADY on the hub changes no window: nothing logged,
#     and no stamp is left behind to mislabel a later trip.
bash --posix "$BIN/hub-zoom.sh"
bash --posix "$BIN/hub-zoom.sh" --home
wait_lines 2 "F9/home on the hub"
[ -z "$(tmux show-option -qv -t t @hub_nav_via)" ] || fail "a hub-on-hub press left @hub_nav_via stamped"

# 4. closing the task you are on drops you on the hub → closed.
tmux select-window -t t:w2
tick
tmux kill-window -t t:w2
wait_lines 3 "close"
[ "$(tmux display-message -p -t t '#{window_name}')" = plan ] || fail "close: tmux did not land on the hub (test premise)"
[ "$(last_cause)" = closed ] || fail "close: cause is '$(last_cause)', want closed"
[ "$(last_from)" = "$w2id" ] || fail "close: from is '$(last_from)', want $w2id"

# 5. a client attaching onto the hub → attach.
attach_bg() {
  if script -q /dev/null true >/dev/null 2>&1; then           # BSD/macOS
    script -q /dev/null tmux -S "$SOCK" attach -t t >/dev/null 2>&1 &
  elif script -q -c true /dev/null >/dev/null 2>&1; then      # GNU/util-linux
    script -q -c "$REAL_TMUX -S '$SOCK' attach -t t" /dev/null >/dev/null 2>&1 &
  else
    return 1
  fi
  CLIENT_PID=$!
  local i=0
  while [ "$i" -lt 60 ]; do
    [ -n "$(tmux list-clients -t t 2>/dev/null)" ] && return 0
    sleep 0.25; i=$((i + 1))
  done
  return 1
}
want=3
if attach_bg; then
  want=4
  wait_lines 4 "attach"
  [ "$(last_cause)" = attach ] || fail "attach: cause is '$(last_cause)', want attach"
  [ "$(last_from)" = - ]       || fail "attach: from is '$(last_from)', want -"
  kill "$CLIENT_PID" 2>/dev/null; CLIENT_PID=
  i=0; while [ -n "$(tmux list-clients -t t 2>/dev/null)" ] && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
else
  printf 'selftest: no usable `script` for a pty client — attach leg SKIPPED\n' >&2
fi

# 6. prefix g (dash-zoom.sh) → g; a plain select-window onto the hub → other.
tmux select-window -t t:w1
tick
bash --posix "$BIN/dash-zoom.sh"
want=$((want + 1)); wait_lines "$want" "prefix g"
[ "$(last_cause)" = g ] || fail "prefix g: cause is '$(last_cause)', want g"
tmux select-window -t t:w1
tick
tmux select-window -t t:plan
want=$((want + 1)); wait_lines "$want" "plain switch"
[ "$(last_cause)" = other ] || fail "plain switch: cause is '$(last_cause)', want other"

# --- the summary ---------------------------------------------------------------
out="$(bash "$HV" --since 1h --session t)" || fail "summary exited non-zero"
printf '%s\n' "$out" | grep -q "^hub visits · t · last 1h: 5" || fail "summary total (attach excluded) is not 5: $out"
for c in f9 home closed g other; do
  printf '%s\n' "$out" | grep -Eq "^  $c +1\$" || fail "summary lacks '$c 1': $out"
done
if [ "$want" = 6 ]; then
  printf '%s\n' "$out" | grep -Eq '^  attach +1  \(not counted\)$' || fail "summary lacks the uncounted attach row: $out"
fi
brief="$(bash "$HV" --brief --all --since 1h)"
[ "$(printf '%s\n' "$brief" | cut -f1,2)" = "$(printf 't\t5')" ] || fail "--brief: got '$brief'"

# Reading rules on a hand-made log: same-second repeats count once; old lines
# fall outside --since; an unknown future cause token is still grouped.
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{ printf '2020-01-01T00:00:00Z\ta1\tf9\n'
  printf '%s\ta1\tf9\n%s\ta1\tf9\n%s\t-\tattach\n' "$now" "$now" "$now"
  printf '%s\tb2\tclosed-next\n' "2999-01-01T00:00:00Z"; } > "$WORK/fixed.log"
fx="$(bash "$HV" --since 24h --log "$WORK/fixed.log")"
printf '%s\n' "$fx" | grep -q ': 2 (+1 attach, not counted)$' || fail "same-second dedup / --since cut: $fx"
printf '%s\n' "$fx" | grep -Eq '^  f9 +1$' || fail "same-second repeats not counted once: $fx"

# A task-bar landing (issue #899) is a trip that did NOT happen: listed on its
# own, kept out of the total and out of --brief's count, even in a second shared
# with a real trip.
{ printf '%s\ta1\tf9\n%s\ta1\thome-sidebar\n%s\ta1\thome-sidebar\n' "$now" "$now" "$now"
  printf '%s\tb2\tf9-sidebar\n' "$now"; } > "$WORK/side.log"
sx="$(bash "$HV" --since 24h --log "$WORK/side.log")"
printf '%s\n' "$sx" | grep -q ': 1 (+2 kept on the task bar, not counted)$' || fail "sidebar landings counted as trips: $sx"
printf '%s\n' "$sx" | grep -Eq '^  home-sidebar +1  \(stayed on the task bar, not counted\)$' || fail "home-sidebar row missing: $sx"
printf '%s\n' "$sx" | grep -Eq '^  f9-sidebar +1  \(stayed' || fail "f9-sidebar row missing: $sx"

# No log at all, and a bad --since.
empty="$(FLEET_HUB_VISITS_LOGDIR="$WORK/none" bash "$HV" --brief --all)"
[ -z "$empty" ] || fail "--brief with no logs should print nothing, got '$empty'"
bash "$HV" --since 5x --session t >/dev/null 2>&1 && fail "--since 5x should be refused"

# Trimming: past MAX + 10% the log is cut back to its last MAX lines.
: > "$WORK/logs/hub-visits-trim.log"
i=0; while [ "$i" -lt 12 ]; do
  FLEET_HUB_VISITS_MAX=10 bash "$HV" record "$SOCK" trim other a1 ''; i=$((i + 1))
done
n="$(wc -l < "$WORK/logs/hub-visits-trim.log" | tr -d ' ')"
[ "$n" -le 11 ] || fail "trim: log has $n lines, want ≤ 11 at FLEET_HUB_VISITS_MAX=10"

printf 'hub-visits-selftest: PASS\n'
exit 0
