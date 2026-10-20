#!/bin/bash
# fleet-doctor-conf-dir-selftest.sh — bin/fleet-doctor.sh must run to its last
# check with FLEET_CONF_DIR UNSET.
#
# Why this needs its own test: the doctor is /bin/sh and cannot source the
# bash-only fleet-lib.sh, so nothing defaults FLEET_CONF_DIR for it — it has to
# default the value itself. #759 added a `$FLEET_CONF_DIR` read (the failover
# screen, retired with the planner in T546) above that default, and under `set -u` the doctor died right there:
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
#   2. the default path is actually READ: a socket-heal.log line planted under
#      $HOME/.config/claude-fleet surfaces on the socket line;
#   3. an explicit FLEET_CONF_DIR still wins over the default.
# (Also: retired rows stay gone; a pool account on a login not separated WARNs.)
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

# plant_heal <conf-dir> <fleet> — one fresh socket-heal.log line in the shape
# bin/fleet-doctor.sh's socket check reads (`<epoch>\t<fleet>`).
plant_heal() {
  mkdir -p "$1"
  printf '%s\t%s\n' "$(date +%s)" "$2" > "$1/socket-heal.log"
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

# 2. the default path is read: a heal under $HOME/.config/claude-fleet shows up
plant_heal "$WORK/home/.config/claude-fleet" sess-default
run_doctor
grep -q 'unbound variable' "$WORK/stderr" && fail "doctor died on an unbound variable (default path, heal planted)"
grep -Eq '^[[:space:]]+WARN[[:space:]]+socket[[:space:]].*for fleet sess-default' "$WORK/stdout" \
  || fail "socket check did not read the DEFAULT conf dir (\$HOME/.config/claude-fleet)"
ok

# 3. an explicit FLEET_CONF_DIR still wins over the default
plant_heal "$WORK/explicit" sess-explicit
run_doctor FLEET_CONF_DIR="$WORK/explicit"
grep -q 'unbound variable' "$WORK/stderr" && fail "doctor died on an unbound variable (explicit conf dir)"
grep -Eq '^[[:space:]]+WARN[[:space:]]+socket[[:space:]].*for fleet sess-explicit' "$WORK/stdout" \
  || fail "socket check ignored an explicit FLEET_CONF_DIR"
grep -q 'sess-default' "$WORK/stdout" && fail "explicit FLEET_CONF_DIR did not override the default (both heals printed)"
ok

# 4. the retired quota failover rows (T546) never print, whatever is on disk
mkdir -p "$WORK/explicit/handoffs/quota-requests/r2"
printf '{"state":"waiting","detail":"same veto","same_detail_streak":7,"stuck_notified":true,"source":{"session":"sess-explicit","window":"@9"}}\n' \
  > "$WORK/explicit/handoffs/quota-requests/r2/request.json"
run_doctor FLEET_CONF_DIR="$WORK/explicit"
grep -Eq '^[[:space:]]+(PASS|WARN|FAIL)[[:space:]]+(failover|failover-stuck|account-pick)([[:space:]]|$)' "$WORK/stdout" \
  && fail "a retired failover / failover-stuck / account-pick row still printed"
ok

# 5. a login holding pool accounts but not separated is told so (T550): the
#    launcher picks none of them, its sessions run on its own login
mkdir -p "$WORK/acc"; printf 'hub:p1\n' > "$WORK/acc/p1"; chmod 600 "$WORK/acc/p1"
run_doctor FLEET_CONF_DIR="$WORK/explicit" FLEET_ACCOUNTS_DIR="$WORK/acc"
grep -Eq '^[[:space:]]+WARN[[:space:]]+account-pool[[:space:]].*还没交给池子' "$WORK/stdout" \
  || fail "a not-separated login with a pool account must WARN account-pool"
: > "$WORK/explicit/credsep.json"
run_doctor FLEET_CONF_DIR="$WORK/explicit" FLEET_ACCOUNTS_DIR="$WORK/acc"
grep -Eq '[[:space:]]account-pool[[:space:]]' "$WORK/stdout" && fail "a separated login must not WARN account-pool"
rm -f "$WORK/explicit/credsep.json"
ok

printf 'fleet-doctor-conf-dir-selftest: %d checks passed\n' "$CHECKS"
