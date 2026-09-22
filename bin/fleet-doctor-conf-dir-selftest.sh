#!/bin/bash
# fleet-doctor-conf-dir-selftest.sh — bin/fleet-doctor.sh must run to its last
# check with FLEET_CONF_DIR UNSET.
#
# Why this needs its own test: the doctor is /bin/sh and cannot source the
# bash-only fleet-lib.sh, so nothing defaults FLEET_CONF_DIR for it — it has to
# default the value itself. #759 added a `$FLEET_CONF_DIR` read (the failover
# screen) above that default, and under `set -u` the doctor died right there:
# `line 254: FLEET_CONF_DIR: unbound variable`, every later check gone. CI never
# saw it because the selftest gate EXPORTS FLEET_CONF_DIR (bin/run-selftests.sh
# points it at an empty shadow dir), and the variable is unset exactly where a
# human runs the doctor: a pane or a login shell — the launcher never exports it.
# Both live machines hit it on 2026-09-18.
#
# So the doctor child here runs with the variable REMOVED from its environment
# (`env -u`) — that is the subject under test, not an isolation preamble; the
# gate's root swap still isolates everything else, and HOME points into the
# sandbox so the default path resolves there. Three things are pinned:
#   1. no "unbound variable" on stderr, and the LAST check (perl) still prints;
#   2. the default path is actually READ: a pending quota request planted under
#      $HOME/.config/claude-fleet surfaces on the failover line;
#   3. an explicit FLEET_CONF_DIR still wins over the default.
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-doctor.sh fleet-daemon-lib.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-conf-dir-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home"
for f in fleet-doctor.sh fleet-daemon-lib.sh; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- stderr ---\n%s\n--- stdout (tail) ---\n%s\n' "$(cat "$WORK/stderr" 2>/dev/null)" "$(tail -5 "$WORK/stdout" 2>/dev/null)" >&2; exit 1; }
ok() { CHECKS=$((CHECKS + 1)); }

# plant_request <conf-dir> <session> <window> — one pending cutover request in
# the shape bin/fleet-doctor.sh's failover screen reads.
plant_request() {
  mkdir -p "$1/handoffs/quota-requests/r1"
  printf '{"state":"waiting","detail":"planted by selftest","source":{"session":"%s","window":"%s"}}\n' \
    "$2" "$3" > "$1/handoffs/quota-requests/r1/request.json"
}

# run_doctor [VAR=value ...] — the doctor with FLEET_CONF_DIR removed from the
# environment unless a caller re-adds it; HOME and TMPDIR inside the sandbox.
run_doctor() {
  env -u FLEET_CONF_DIR HOME="$WORK/home" TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 "$@" \
    sh "$WORK/bin/fleet-doctor.sh" >"$WORK/stdout" 2>"$WORK/stderr"
  return 0
}

# 1. unset → runs to the end, no unbound-variable death
run_doctor
grep -q 'unbound variable' "$WORK/stderr" && fail "doctor died on an unbound variable with FLEET_CONF_DIR unset"
grep -Eq '^[[:space:]]+(PASS|WARN|FAIL)[[:space:]]+perl([[:space:]]|$)' "$WORK/stdout" \
  || fail "the last check (perl) never printed — the doctor stopped early with FLEET_CONF_DIR unset"
ok

# 2. the default path is read: a request under $HOME/.config/claude-fleet shows up
plant_request "$WORK/home/.config/claude-fleet" sess-default @7
run_doctor
grep -q 'unbound variable' "$WORK/stderr" && fail "doctor died on an unbound variable (default path, request planted)"
grep -Eq '^[[:space:]]+WARN[[:space:]]+failover[[:space:]]+sess-default/@7: waiting' "$WORK/stdout" \
  || fail "failover screen did not read the DEFAULT conf dir (\$HOME/.config/claude-fleet)"
ok

# 3. an explicit FLEET_CONF_DIR still wins over the default
plant_request "$WORK/explicit" sess-explicit @8
run_doctor FLEET_CONF_DIR="$WORK/explicit"
grep -q 'unbound variable' "$WORK/stderr" && fail "doctor died on an unbound variable (explicit conf dir)"
grep -Eq '^[[:space:]]+WARN[[:space:]]+failover[[:space:]]+sess-explicit/@8: waiting' "$WORK/stdout" \
  || fail "failover screen ignored an explicit FLEET_CONF_DIR"
grep -q 'sess-default/@7' "$WORK/stdout" && fail "explicit FLEET_CONF_DIR did not override the default (both requests printed)"
ok

# 4. a stuck request (issue #872) is counted on its own line; a merely pending
#    one is not
grep -Eq '^[[:space:]]+PASS[[:space:]]+failover-stuck[[:space:]]+0 stuck' "$WORK/stdout" \
  || fail "a pending, non-stuck request was not reported as 0 stuck"
mkdir -p "$WORK/explicit/handoffs/quota-requests/r2"
printf '{"state":"waiting","detail":"same veto","same_detail_streak":7,"stuck_notified":true,"source":{"session":"sess-explicit","window":"@9"}}\n' \
  > "$WORK/explicit/handoffs/quota-requests/r2/request.json"
run_doctor FLEET_CONF_DIR="$WORK/explicit"
grep -Eq '^[[:space:]]+WARN[[:space:]]+failover-stuck[[:space:]]+1 stuck: sess-explicit/@9 x7' "$WORK/stdout" \
  || fail "a stuck request did not surface on the failover-stuck line"
ok

printf 'fleet-doctor-conf-dir-selftest: %d checks passed\n' "$CHECKS"
