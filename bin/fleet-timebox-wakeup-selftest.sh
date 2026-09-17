#!/bin/bash
# The #701 fast path must never call sleep, even when the job spans several
# liveness checks. A PATH shim records polling, so this assertion does not depend
# on a loaded runner finishing a "fast" command within a narrow wall-clock window.
# The existing wallclock/kill tests cover deadlines, process groups and residue.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/timebox-wakeup-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath" "$WORK/tmp"
REAL_SLEEP="$(command -v sleep)"
export TIMEBOX_SLEEP_LOG="$WORK/sleeps" TIMEBOX_REAL_SLEEP="$REAL_SLEEP"
cat > "$WORK/fakepath/sleep" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TIMEBOX_SLEEP_LOG"
exec "$TIMEBOX_REAL_SLEEP" "$@"
SH
chmod +x "$WORK/fakepath/sleep"
PATH="$WORK/fakepath:$PATH"; export PATH
TMPDIR="$WORK/tmp"; export TMPDIR
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf '  ok — %s\n' "$1"; }
quick() { printf 'payload\nsecond line'; printf 'diagnostic\n' >&2; return 7; }

for ((i=0; i<12; i++)); do
  out=$(fleet_timebox 30 quick 2> "$WORK/stderr"); rc=$?
  [ "$rc" = 7 ] || fail "job status lost (got $rc)"
  [ "$out" = $'payload\nsecond line' ] || fail 'completion channel corrupted stdout'
  [ "$(cat "$WORK/stderr")" = diagnostic ] || fail 'completion channel corrupted stderr'
done
[ ! -s "$TIMEBOX_SLEEP_LOG" ] || fail 'a completed job paid for an external sleep'
ok 'repeated fast failures preserve stdout/stderr/status without a sleep floor'

# This job spans two read timeouts. Only its explicit, absolute sleep is allowed;
# poll-time forks would go through the PATH shim and leave an observable record.
fleet_timebox 30 "$REAL_SLEEP" 2.1 || fail 'a longer job should finish normally'
[ ! -s "$TIMEBOX_SLEEP_LOG" ] || fail 'waiting for a running job forked sleep'
ok 'waiting across multiple liveness checks makes no sleep calls'

no_input() { local line=''; if IFS= read -r line; then
  printf 'unexpected stdin: %s\n' "$line" >&2; return 1
fi; return 0; }
fleet_timebox 30 no_input <<< 'caller input' || fail 'job stdin must still be /dev/null'
ok 'the job sees EOF on stdin'

# Redirections, traps and job-control flags belong to the caller. An occupied
# fd 9 must remain available to both the caller and its bounded child.
exec 9> "$WORK/caller-fd"
trap ':' USR1
before=$(trap -p USR1)
set +m
write_fd() { printf 'child\n' >&9; }
fleet_timebox 30 write_fd || fail 'bounded child lost caller fd 9'
case "$-" in *m*) fail 'enabled job control in caller';; esac
[ "$(trap -p USR1)" = "$before" ] || fail 'changed caller signal trap'
printf 'still open\n' >&9
[ "$(cat "$WORK/caller-fd")" = $'child\nstill open' ] || fail 'clobbered caller fd 9'
set -m
fleet_timebox 30 true || fail 'bounded command with job control failed'
case "$-" in *m*) :;; *) fail 'disabled caller job control';; esac
set +m
exec 9>&-
trap - USR1
nested() { fleet_timebox 20 quick; }
out=$(fleet_timebox 30 nested 2> "$WORK/stderr"); rc=$?
[ "$rc" = 7 ] && [ "$out" = $'payload\nsecond line' ] || fail 'nested call lost output/status'
ok 'caller fd/traps/job control and nested timeboxes survive'

exits() { exit 42; }
execs() { exec true; }
fleet_timebox 30 exits 2> "$WORK/stderr"; rc=$?
[ "$rc" = 42 ] && [ ! -s "$WORK/stderr" ] || fail 'explicit exit lost status or wrote notification errors'
fleet_timebox 30 execs 2> "$WORK/stderr"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$WORK/stderr" ] || fail 'exec replacement lost status or wrote notification errors'
ok 'explicit exit and exec remain observable when no notification is sent'

changed=no
mutate() { changed=yes; return 7; }
fleet_timebox 0 mutate; rc=$?
[ "$rc" = 7 ] && [ "$changed" = yes ] || fail 'budget 0 must execute in caller'
changed=no
fleet_timebox invalid mutate; rc=$?
[ "$rc" = 7 ] && [ "$changed" = yes ] || fail 'invalid budget must execute in caller'
ok 'unbudgeted calls retain in-process side effects and exit status'

# A missing/unusable FIFO facility must keep the previous bounded implementation.
cat > "$WORK/fakepath/mkfifo" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$WORK/fakepath/mkfifo"
out=$(fleet_timebox 30 quick 2> "$WORK/stderr"); rc=$?
[ "$rc" = 7 ] && [ "$out" = $'payload\nsecond line' ] || fail 'FIFO setup failure lost the job'
for leftover in "$TMPDIR"/fleet-timebox.*; do
  [ ! -e "$leftover" ] || fail 'left a FIFO or directory behind'
done
ok 'failed FIFO setup falls back without leaving temporary files'

printf 'selftest PASS: timebox completion wakeup (#701)\n'
