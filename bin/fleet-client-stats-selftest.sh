#!/bin/bash
# fleet-client-stats-selftest.sh — the ruler for the client's three readings
# (issue #4824, EPIC #4823 C1): bin/fleet-client-stats.py on synthetic logs.
#
#   A  drops: `connect … up` whose next lifecycle event is not quit/end, per
#      computer-day; a person's quit / ⌘Q / window close is no drop
#   B  reconnect: a drop's line → the next `drawn`, median / p90 (nearest rank); an `offline`
#      inside the gap keeps it out of the online figures; a drop the client
#      ended before redrawing is `unrecovered`
#   C  open failures: per start (after quit/end, or a second view with no end):
#      the first connect not up (pick rc 1, never up rc 255), or `first` rc 1;
#      never up rc 3 is the first-session road, not a failure by itself
#   D  layouts: a client cache (thin.log + shell/logs), a bundle (logs/), a bare
#      log dir; `.1` read before the live file; --days / --now window
#   E  usage: no dir → 2, an unreadable dir only → 2
set -u
BIN=$(cd "$(dirname "$0")" && pwd)
S="$BIN/fleet-client-stats.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/client-stats.XXXXXX")
trap 'rm -rf "${T:?}"' EXIT
fail=0
ok() { echo "PASS  $1"; }
no() { echo "FAIL  $1"; fail=1; }
tab=$(printf '\t')
# line <time> <event> [home] [route] [pick] [ssh] [first] [rc] [reason]
line() { local IFS="$tab"; printf '%s\n' "$*"; }
# get <json file> <python expr on j>
get() { python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want [$2] got [$3]"; fi; }

# --- computer one: a client cache --------------------------------------------
mkdir -p "$T/a/shell/logs"
{
  # day 1: a start that comes up, drops twice (lan), recovers in 4 s and 10 s, then ⌘Q
  line 2026-10-01T10:00:00Z drawn m1 lan '' 100 200
  line 2026-10-01T11:00:00Z connect m1 lan 50 100 200 255 up
  line 2026-10-01T11:00:04Z drawn m1 lan '' 100 200
  line 2026-10-01T12:00:00Z connect m1 lan 50 100 200 255 up
  line 2026-10-01T12:00:10Z drawn m1 entry '' 100 200
  line 2026-10-01T12:30:00Z say m1 '' '' '' '' '' 'not a lifecycle event'
  line 2026-10-01T12:30:01Z run '' entry '' '' '' '' ls
  line 2026-10-01T13:00:00Z connect m1 entry 50 100 200 0 quit
  line 2026-10-01T13:00:00Z quit m1 '' '' '' '' 0 quit
  # day 2: a start whose first pick fails (rc 1), then up; drops with the own line
  # down (offline inside the gap) — 100 s, kept out of the online figures
  line 2026-10-02T09:00:00Z connect m1 '' 900 '' '' 1 'fleet-connect --argv exit 1'
  line 2026-10-02T09:00:05Z drawn m1 lan '' 100 200
  line 2026-10-02T10:00:00Z connect m1 lan 50 100 200 255 up
  line 2026-10-02T10:00:30Z offline m1 '' '' '' '' '' 'the hub does not answer either'
  line 2026-10-02T10:01:40Z drawn m1 lan '' 100 200
  # the window closed while up: an `end`, no connect line — not a drop
  line 2026-10-02T11:00:00Z end m1 '' '' '' '' 129 'signal 1'
  # a detach (rc 0, up) then quit — the person's, not a drop
  line 2026-10-02T12:00:00Z drawn m1 lan '' 100 200
  line 2026-10-02T12:10:00Z connect m1 lan 50 100 200 0 up
  line 2026-10-02T12:10:00Z quit m1 '' '' '' '' 0 detach
} > "$T/a/thin.log"
{
  line 2026-10-02T09:00:00Z home - - 900 unreachable 'the hub did not answer'
  line 2026-10-02T09:00:01Z pick m1 direct 30 ok 'lan 3/3'
} > "$T/a/shell/logs/connect.log"
{
  line 2026-10-01T10:00:00Z new m1 - 3000 'REMOTE 0' repo=o/r
  line 2026-10-02T10:00:00Z new auto - 3000 'REFUSED 4' 'No machine can take a new session now'
} > "$T/a/shell/logs/place.log"

# --- computer two: a bundle (logs/), its thin.log rotated ---------------------
mkdir -p "$T/b/logs"
echo '{"v":1,"host":"cn-box"}' > "$T/b/manifest.json"
{
  # (in the .1) a start that never comes up and the client is ^C'd
  line 2026-10-01T08:00:00Z connect m2 relay 100 300 '' 255 'never up'
  line 2026-10-01T08:00:05Z quit m2 '' '' '' '' 130 '^C between connections'
} > "$T/b/logs/thin.log.1"
{
  # a start on the first-session road: never up rc 3, the first session opens → not failed
  line 2026-10-01T09:00:00Z connect m2 entry 100 300 '' 3 'never up'
  line 2026-10-01T09:00:01Z first m2 '' '' '' '' '' 'no fleet session is live on m2'
  line 2026-10-01T09:00:20Z first m2 '' '' '' '' 0 'REMOTE m2'
  line 2026-10-01T09:00:25Z drawn m2 entry '' 300 900
  # the process goes with no line (a crash); a new start's view: vanished, new start
  line 2026-10-01T09:30:00Z drawn m2 entry '' 300 900
  # it drops and the client is killed before redrawing: unrecovered
  line 2026-10-01T10:00:00Z connect m2 entry 100 300 900 255 up
  line 2026-10-01T10:00:02Z connect m2 entry 100 300 '' 255 'never up'
  line 2026-10-01T10:00:09Z end m2 '' '' '' '' 129 'signal 1'
  # a start where the first session does not open (first rc 1) → failed
  line 2026-10-01T11:00:00Z connect m2 entry 100 300 '' 3 'never up'
  line 2026-10-01T11:00:30Z first m2 '' '' '' '' 1 'No machine can take a new session now'
  line 2026-10-01T11:00:30Z quit m2 '' '' '' '' 1 'no first session'
  # outside --days 7 from --now: ignored
  line 2026-09-20T11:00:00Z connect m2 entry 100 300 900 255 up
} > "$T/b/logs/thin.log"
line 2026-10-01T11:00:00Z new auto - 3000 'error 1' 'hub answered HTTP 503' > "$T/b/logs/place.log"

# --- computer three: a bare shell log dir, no thin.log ------------------------
mkdir -p "$T/c"
line 2026-10-01T09:00:00Z home - - 900 no_machine_online 'no machine' > "$T/c/connect.log"

J="$T/out.json"
python3 "$S" --json --days 7 --now 2026-10-03T00:00:00Z "$T/a" "$T/b" "$T/c" > "$J" 2>"$T/err"
eq "runs (rc 0)" 0 $?

# A — drops
eq "A computers" 3 "$(get "$J" 'j["computers"]')"
eq "A computer-days: a 2 + b 1 + c 0" 3 "$(get "$J" 'j["computer_days"]')"
eq "A drops: a 3 (lan,lan,lan) + b 1 (entry)" 4 "$(get "$J" 'j["drops"]')"
eq "A drops per computer-day" 1.33 "$(get "$J" 'j["drops_per_computer_day"]')"
eq "A by route" "{'entry': 1, 'lan': 3}" "$(get "$J" 'dict(sorted(j["drops_by_route"].items()))')"
eq "A the bundle names its computer" cn-box "$(get "$J" 'j["per_computer"][1]["computer"]')"

# B — reconnect
eq "B reconnects (4, 10, 100)" 3 "$(get "$J" 'j["reconnects"]')"
eq "B median" 10 "$(get "$J" 'j["reconnect_median_s"]')"
eq "B p90" 100 "$(get "$J" 'j["reconnect_p90_s"]')"
eq "B online (offline gap out)" "2 4 10" "$(get "$J" '"%d %d %d" % (j["reconnects_online"], j["reconnect_online_median_s"], j["reconnect_online_p90_s"])')"
eq "B unrecovered" 1 "$(get "$J" 'j["unrecovered"]')"

# C — open failures
#   a: start 1 ok, start 2 failed (pick rc 1), start 3 (drawn after end) ok → 3 starts, 1 failed
#   b: (.1) never up rc 255 → failed; first-session ok; vanished→new start ok;
#      first rc 1 → failed → 4 starts, 2 failed
eq "C starts" 7 "$(get "$J" 'j["starts"]')"
eq "C open failed" 3 "$(get "$J" 'j["open_failed"]')"
eq "C rate" 0.4286 "$(get "$J" 'j["open_fail_rate"]')"
eq "C by reason" "{'first rc 1': 1, 'fleet-connect --argv exit 1 rc 1': 1, 'never up rc 255': 1}" \
  "$(get "$J" 'dict(sorted(j["open_fail_by"].items()))')"
eq "C vanished" 1 "$(get "$J" 'j["vanished"]')"
eq "C never drawn (b's .1 start, b's first-rc-1 start)" 2 "$(get "$J" 'j["never_drawn"]')"

# D — shell logs, window
eq "D home failures by code" "{'no_machine_online': 1, 'unreachable': 1}" "$(get "$J" 'dict(sorted(j["home_fail"].items()))')"
eq "D place asks / non-zero" "3 2" "$(get "$J" '"%d %d" % (j["place_asks"], j["place_nonzero"])')"
python3 "$S" --json --days 30 --now 2026-10-03T00:00:00Z "$T/b" > "$T/wide.json"
eq "D a wider window reads the September drop" 2 "$(get "$T/wide.json" 'j["drops"]')"
python3 "$S" --days 7 --now 2026-10-03T00:00:00Z "$T/a" "$T/b" > "$T/text"
if grep -q '断线 / 台 / 天' "$T/text" && grep -q '接回 中位 / p90' "$T/text" && grep -q '打开失败' "$T/text"; then
  ok "D text: the three readings"; else no "D text: $(cat "$T/text")"; fi

# E — usage
python3 "$S" >/dev/null 2>&1; eq "E no dir → 2" 2 $?
mkdir -p "$T/empty"; python3 "$S" "$T/empty" >/dev/null 2>&1; eq "E nothing readable → 2" 2 $?

[ "$fail" = 0 ] && echo "fleet-client-stats-selftest: ok" || echo "fleet-client-stats-selftest: FAILED"
exit "$fail"
