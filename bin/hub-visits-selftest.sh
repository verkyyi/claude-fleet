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
# The arrival HOOKS are gone (issue #1714: a node binds none of a person's keys
# and runs none of their hooks), so this pins the reader — summary, dedup,
# trimming, the `record` verb hub-zoom.sh still calls — on hand-made logs, and
# that the node conf drops the [73] hooks from a live server.
#
# tmux absent → SKIP (exit 0).
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
# The meter counts trips to the full-screen hub, which only FLEET_DASH_WINDOW=1
# still builds (issue #1533) — this fleet keeps it.
export FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$FLEET_CONF_DIR/fleets/t"
# The meter is the thing under test, so every key goes STRAIGHT to the hub
# (FLEET_HOME_SIDEBAR_FIRST=0): with the task-bar-first branch on, a ⌂ / F9 from
# a bar-less window tries the picker popup first, and since issue #1611 that
# parent pre-reads the row producer BEFORE the popup opens — whose @wid backfill
# hands every window a handle, and leg 3's "from the window id, no @wid" would
# read a handle instead. The branch itself is hub-zoom-home-selftest.sh's and
# task-pick-selftest.sh's to cover.
printf 'FLEET_DASH_WINDOW=1\nFLEET_HOME_SIDEBAR_FIRST=0\n' > "$FLEET_CONF_DIR/fleets/t/conf"
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

# --- static: the node carries no hub-visit hook (issue #1714) ---------------
# The [73] hooks that wrote one line per hub arrival left the node with the
# person's keys (EPIC #1710 C4): a client looks through a view session and the
# full-screen hub is FLEET_DASH_WINDOW=1's alone. What stays is the reader and
# the `record` verb hub-zoom.sh still calls — the legs below.
grep -Eq '^set-hook -g [a-z-]+\[73\] ' "$CONF" && fail "static: the node conf still sets a [73] hook"
grep -Eq '^set-hook -gu session-window-changed\[73\]$' "$CONF" \
  || fail "static: the node conf must drop a live server's session-window-changed[73] hook"

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

# The task picker (issue #902): ⌂ / F9 in a task with NO bar open the popup —
# also a trip that did not happen, counted apart from the bar's.
{ printf '%s\ta1\tf9\n%s\ta1\tf9-pick\n' "$now" "$now"; printf '%s\ta1\thome-pick\n' "$now"; } > "$WORK/pick.log"
px="$(bash "$HV" --since 24h --log "$WORK/pick.log")"
printf '%s\n' "$px" | grep -q ': 1 (+2 via the task picker, not counted)$' || fail "picker openings counted as trips: $px"
printf '%s\n' "$px" | grep -Eq '^  f9-pick +1  \(task picker instead of the hub, not counted\)$' || fail "f9-pick row missing: $px"
bx="$(bash "$HV" --brief --since 24h --log "$WORK/pick.log")"
printf '%s\n' "$bx" | cut -f2 | grep -qx 1 || fail "--brief counted a picker opening: $bx"

# The ⌂ trace (issue #1611): `record`'s optional 6th argument is a 4th column —
# one line, no tab (a tab-bearing extra is dropped, never a 5th column) — and
# the readers key on the first three columns as before.
: > "$WORK/logs/hub-visits-x.log"
bash "$HV" record '' x home-pick a1 '' 'ms=238 conf:21 fzf:238 done:240'
bash "$HV" record '' x home-pick a1 '' "$(printf 'ms=1\tevil')"
bash "$HV" record '' x f9 a1 ''
xl="$(cat "$WORK/logs/hub-visits-x.log")"
[ "$(printf '%s\n' "$xl" | sed -n 1p | cut -f4)" = 'ms=238 conf:21 fzf:238 done:240' ] || fail "record extra → 4th column: $xl"
[ "$(printf '%s\n' "$xl" | sed -n 2p | awk -F'\t' '{print NF}')" = 3 ] || fail "a tab in the extra must drop it, not add a column: $xl"
[ "$(printf '%s\n' "$xl" | sed -n 3p | awk -F'\t' '{print NF}')" = 3 ] || fail "no extra → three columns as before: $xl"
xt="$(bash "$HV" --since 24h --log "$WORK/logs/hub-visits-x.log")"
printf '%s\n' "$xt" | grep -q ': 1 (+1 via the task picker, not counted)$' || fail "the 4th column changed the table: $xt"

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
