#!/bin/bash
# fleet-wait-webhook-selftest.sh — waiting on a PR is driven by webhook EVENTS, not
# a clock (issue #1272, EPIC #1262 R4).
#
# What is pinned:
#   STAMP     `fleet-webhook.sh --route` leaves an event stamp per PR a delivery
#             names (pull_request, check_run/check_suite pull_requests[]), a repo
#             stamp for one naming none (`status`), and still stamps a delivery the
#             refresh-kick debounce swallows.
#   EVENT     `fleet-pr-verdict.sh --wait` with the repo's forward live: ONE read
#             to start, ZERO gh calls while it waits, and a fake check_run delivered
#             through the real route ends the wait within 2s with ONE confirming
#             read — where the poll would sleep 20s.
#   BACKSTOP  no event at all → one re-read per FLEET_PR_WAIT_BACKSTOP, not per 20s.
#   FALLBACK  no live forward (or FLEET_PR_WAIT_WEBHOOK=0) → the original poll.
#
# Hermetic: a fake `gh` on PATH counts every call; the "live forward" is two pid
# files naming this shell; no network, no daemon, no tmux.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CLI="$BIN/fleet-pr-verdict.sh"; WH="$BIN/fleet-webhook.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: no jq on PATH"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: no python3 on PATH"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/waitwh-selftest.XXXXXX")" || exit 2
BGPID=''
trap '[ -n "$BGPID" ] && kill "$BGPID" 2>/dev/null; rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

export FLEET_WEBHOOK_STATE_DIR="$WORK/wh" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf"
export FLEET_STATE_DIR="$WORK/state" FLEET_GH_LOG="$WORK/gh-limit.log" TMPDIR="$WORK"
export FLEET_PR_REFRESH_CMD=true FLEET_ISSUES_REFRESH_CMD=true FLEET_WEBHOOK_DEBOUNCE=3
unset FLEET_GH_FAKE_LIMIT FLEET_PR_WAIT_WEBHOOK FLEET_PR_WAIT_BACKSTOP
EV="$WORK/wh/events/acme-widgets"
mkdir -p "$WORK/wh/forwards" "$WORK/bin" "$WORK/seq"

route() {  # route <event> <json> — one delivery through the REAL route
  printf '%s' "$2" | bash "$WH" --route --event "$1" 2>>"$WORK/route.log"
}
CHECK_RUN='{"repository":{"full_name":"acme/widgets"},"action":"completed","check_run":{"id":1,"head_sha":"abc","pull_requests":[{"number":77},{"number":78}]}}'

# ===== STAMP ===================================================================
route check_run "$CHECK_RUN"
[ -s "$EV/pr-77" ] && [ -s "$EV/pr-78" ] && [ ! -e "$EV/repo" ] \
  || fail "a check_run stamps every PR in pull_requests[] (and not the repo)" "$(ls -la "$EV" 2>&1; cat "$WORK/route.log")"
s1=$(cat "$EV/pr-77")
route check_run "$CHECK_RUN"   # inside the 3s debounce: the kick is skipped, the stamp is not
grep -q debounced "$WORK/route.log" || fail "the second delivery should have been debounced" "$(cat "$WORK/route.log")"
[ "$(cat "$EV/pr-77")" != "$s1" ] || fail "a debounced delivery must still re-stamp the PR"
route status '{"repository":{"full_name":"acme/widgets"},"sha":"abc","state":"success"}'
[ -s "$EV/repo" ] || fail "a status delivery (no PR in it) stamps the repo"
route pull_request '{"repository":{"full_name":"acme/widgets"},"action":"synchronize","pull_request":{"number":79}}'
[ -s "$EV/pr-79" ] || fail "a pull_request delivery stamps its PR"
route issues '{"repository":{"full_name":"acme/widgets"},"action":"opened","issue":{"number":80}}'
[ ! -e "$EV/pr-80" ] || fail "an issues delivery is not a PR event"
ok "route stamps every PR a delivery names (repo stamp when none), debounce or not"

# ===== fake gh + the PR fixtures ===============================================
# call N serves $GH_SEQ/N.json (the last one past the end) through the script's
# real --jq program; every call is counted.
cat > "$WORK/bin/gh" <<'GHFAKE'
#!/bin/bash
prog=''; while [ "$#" -gt 0 ]; do [ "$1" = --jq ] && { shift; prog="$1"; }; shift; done
n=$(( $(cat "$GH_SEQ/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GH_SEQ/calls"
k=$n; while [ "$k" -gt 1 ] && [ ! -f "$GH_SEQ/$k.json" ]; do k=$((k - 1)); done
jq -r "$prog" < "$GH_SEQ/$k.json"
GHFAKE
chmod +x "$WORK/bin/gh"
fx() {  # fx <n> <mss> <checks>
  printf '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"%s","isDraft":false,"statusCheckRollup":[%s],"autoMergeRequest":null}\n' \
    "$2" "$3" > "$WORK/seq/$1.json"
}
C_PASS='{"status":"COMPLETED","conclusion":"SUCCESS"}'
C_RUN='{"status":"IN_PROGRESS","conclusion":null}'
seq_reset() { rm -rf "$WORK/seq"; mkdir -p "$WORK/seq"; fx 1 BLOCKED "$C_RUN"; fx 2 CLEAN "$C_PASS"; }
calls() { cat "$WORK/seq/calls" 2>/dev/null || echo 0; }
live()  { echo $$ > "$WORK/wh/handler.pid"; echo $$ > "$WORK/wh/forwards/acme-widgets.pid"; }
dead()  { echo 999999 > "$WORK/wh/forwards/acme-widgets.pid"; }
bg_wait() {  # bg_wait [env…] — the waiter in the background, real sleep
  env PATH="$WORK/bin:$PATH" GH_SEQ="$WORK/seq" "$@" \
    bash "$CLI" 77 --repo acme/widgets --wait > "$WORK/out" 2> "$WORK/err" & BGPID=$!
}
collect() { wait "$BGPID"; RC=$?; BGPID=''; OUT=$(cat "$WORK/out"); }

# ===== EVENT ===================================================================
seq_reset; live; rm -rf "$EV"
bg_wait
sleep 3
[ "$(calls)" = 1 ] || fail "the event-driven wait must make NO gh call while it waits (3s in)" "calls=$(calls) $(cat "$WORK/err")"
kill -0 "$BGPID" 2>/dev/null || { collect; fail "the waiter returned before any event" "$OUT $(cat "$WORK/err")"; }
grep -q 'waiting on webhook events' "$WORK/err" || fail "the waiter should say it is event-driven" "$(cat "$WORK/err")"
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
route check_run "$CHECK_RUN"
collect
dt=$(( $(perl -MTime::HiRes=time -e 'printf "%d", time*1000') - t0 ))
[ "$OUT" = READY ] && [ "$RC" = 0 ] || fail "a check_run delivery should end the wait READY" "out=$OUT rc=$RC $(cat "$WORK/err")"
[ "$dt" -le 2000 ] || fail "the waiter took ${dt}ms after the event (want ≤2000ms)" "$(cat "$WORK/err")"
[ "$(calls)" = 2 ] || fail "one read to start + ONE confirming read, nothing between" "calls=$(calls)"
ok "fake check_run → the waiter returns in ${dt}ms with zero gh calls while waiting (2 reads total)"

# An event for ANOTHER PR does not wake this one.
seq_reset; live; rm -rf "$EV"
bg_wait
sleep 2
route pull_request '{"repository":{"full_name":"acme/widgets"},"action":"synchronize","pull_request":{"number":12}}'
sleep 2
[ "$(calls)" = 1 ] || fail "a delivery for PR #12 must not re-read #77" "calls=$(calls)"
route status '{"repository":{"full_name":"acme/widgets"},"sha":"abc","state":"success"}'
collect
[ "$OUT" = READY ] && [ "$(calls)" = 2 ] || fail "a repo-wide (status) delivery wakes every waiter on the repo" "out=$OUT calls=$(calls)"
ok "another PR's delivery is ignored; a repo-wide one (status / reconnect) wakes it"

# ===== BACKSTOP ================================================================
seq_reset; live; rm -rf "$EV"
bg_wait FLEET_PR_WAIT_BACKSTOP=2
collect
[ "$OUT" = READY ] && [ "$(calls)" = 2 ] || fail "no event → one re-read at the backstop" "out=$OUT calls=$(calls) $(cat "$WORK/err")"
ok "no delivery at all → the backstop re-reads (a missed event costs freshness, never correctness)"

# ===== FALLBACK ================================================================
# Instant fake sleep, logged: the poll's pacing (20s while CI is young) is visible.
cat > "$WORK/bin/sleep" <<'SLEEPFAKE'
#!/bin/bash
echo "$1" >> "$GH_SEQ/sleeps"
SLEEPFAKE
chmod +x "$WORK/bin/sleep"
for mode in dead off; do
  seq_reset; live
  if [ "$mode" = dead ]; then dead; bg_wait; else bg_wait FLEET_PR_WAIT_WEBHOOK=0; fi
  collect
  [ "$OUT" = READY ] && [ "$(cat "$WORK/seq/sleeps")" = 20 ] \
    || fail "fallback ($mode): the original poll, one 20s sleep" "out=$OUT sleeps=$(cat "$WORK/seq/sleeps" 2>/dev/null) $(cat "$WORK/err")"
  grep -q 'waiting on webhook events' "$WORK/err" && fail "fallback ($mode) must not claim to be event-driven"
done
# The forward dies MID-wait → the rest of the interval is a plain poll.
seq_reset; live
cat > "$WORK/bin/sleep" <<'SLEEPFAKE'
#!/bin/bash
echo "$1" >> "$GH_SEQ/sleeps"
[ "$(grep -c . "$GH_SEQ/sleeps")" -ge 3 ] && echo 999999 > "$FLEET_WEBHOOK_STATE_DIR/forwards/acme-widgets.pid"
exit 0
SLEEPFAKE
bg_wait; collect
[ "$OUT" = READY ] && [ "$(tr '\n' ' ' < "$WORK/seq/sleeps")" = "1 1 1 17 " ] \
  || fail "a forward lost mid-wait → poll out the rest of the interval" "out=$OUT sleeps=$(tr '\n' ' ' < "$WORK/seq/sleeps") $(cat "$WORK/err")"
ok "no live forward / FLEET_PR_WAIT_WEBHOOK=0 / a forward lost mid-wait → the original poll"

printf '\nfleet-wait-webhook-selftest: %d checks passed\n' "$pass"
