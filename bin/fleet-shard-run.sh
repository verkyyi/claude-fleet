#!/bin/bash
# fleet-shard-run.sh --budget <secs> [--log <file>] [--retries <n>] [--resume-opt <opt>] -- <command …>
#   — run one release-train shard under a deadline, and rerun it once when the
#   deadline cut it short (issue #3241, EPIC #3139 C9).
#
# A shard that hits the step's timeout-minutes is killed by GitHub with nothing
# but "The action … has timed out": the tests that ran passed, the one in flight
# was cut off, and the train went red on a forecast, not on a test (run
# 38131987956: Linux shards 9 and 12). So the deadline lives HERE, inside the step,
# where its outcome can be told apart:
#   * the command finishes ⇒ its exit code is the shard's, whatever it is;
#   * the deadline fires ⇒ the command's whole process group is stopped
#     (TERM, 5 s, KILL) — "cut short". Its log has a FAIL / TIMEOUT line ⇒ a test
#     really failed: red, no rerun (a rerun must never turn a red green). None ⇒ run
#     the SAME command again, once (--retries) — the same commit, the same
#     selection; nothing is loosened. Cut short again ⇒ red, said so.
# --resume-opt <opt> (issue #4914): the rerun does not repeat what already passed.
# Every test whose own `=== <test> ===` block ended in a `PASS  <test>` line on a cut
# attempt is written to <log>.passed, and the rerun gets `<opt> <log>.passed` right
# after the command's run-selftests.sh word (else at its end) — run-selftests.sh
# --passed, which leaves those out of the same slice. Only PASS: the one in flight,
# the ones never started, and a FLAKY / QUARANTINE one run again as before.
# The first attempt's log is kept as <log>.cut-<n>; <log> is always the last
# attempt's, so the caller's summary step reads what it always read. One line per
# attempt (predicted · budget · actual) goes to stdout and $GITHUB_STEP_SUMMARY.
#
# Exit: the command's code · 124 cut short and not rerun (a FAIL line, or the
# reruns spent) · 2 usage. The step's own timeout-minutes stays the backstop
# (bin/fleet-train-plan.sh sizes it for two attempts).
set -uo pipefail

budget='' log=selftests.log retries=1 resume_opt=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --budget) budget=${2:-}; shift 2 ;;
    --log) log=${2:-}; shift 2 ;;
    --retries) retries=${2:-}; shift 2 ;;
    --resume-opt) resume_opt=${2:-}; shift 2 ;;
    --) shift; break ;;
    *) echo "fleet-shard-run: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
case "$budget" in ''|*[!0-9]*|0) echo "fleet-shard-run: --budget wants seconds" >&2; exit 2 ;; esac
case "$retries" in ''|*[!0-9]*) echo "fleet-shard-run: --retries wants a count" >&2; exit 2 ;; esac
[ "$#" -gt 0 ] || { echo "fleet-shard-run: no command after --" >&2; exit 2; }

# The deadline: the command in its own process group, the group stopped at
# <budget>; exits 124 and leaves <log>.cut-mark when it fired.
# shellcheck disable=SC2016  # a perl program: its $vars are perl's
DEADLINE='
use strict; use POSIX ();
my ($limit, $mark, @cmd) = @ARGV; my $grace = 5;
my $pid = fork(); defined $pid or die "fleet-shard-run: fork: $!\n";
if ($pid == 0) { setpgrp(0, 0); exec { $cmd[0] } @cmd or POSIX::_exit(127) }
setpgrp($pid, $pid);
sub alive { waitpid($pid, POSIX::WNOHANG()); kill(0, -$pid) }
sub stop { kill("TERM", -$pid); for (1 .. $grace * 10) { last unless alive(); select(undef, undef, undef, 0.1) } kill("KILL", -$pid) if alive() }
for my $s (qw(INT TERM HUP)) { $SIG{$s} = sub { stop(); exit 128 + ($s eq "INT" ? 2 : $s eq "TERM" ? 15 : 1) } }
my $r = eval { local $SIG{ALRM} = sub { die "deadline\n" }; alarm($limit); my $w = waitpid($pid, 0); alarm(0); $w };
if (defined $r) { exit($? & 127 ? 128 + ($? & 127) : $? >> 8) }
open(my $fh, ">", $mark); close($fh);
print "\nfleet-shard-run: CUT SHORT after ${limit}s — stopping the shard\n";
stop(); waitpid($pid, 0);
exit 124;
'

note() {
  printf '%s\n' "$1"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n\n' "$1" >> "$GITHUB_STEP_SUMMARY"
}

# The rerun's command: the first one, plus `<resume_opt> <log>.passed` after the
# run-selftests.sh word (its options parse off the front, a name ends them).
resume_cmd() {
  local a put=0 pf=$log.passed
  case "$pf" in /*) ;; *) pf=$PWD/$pf ;; esac
  cmd=()
  for a in "$@"; do
    cmd+=("$a")
    case "$a" in *run-selftests.sh) [ "$put" = 1 ] || { cmd+=("$resume_opt" "$pf"); put=1; } ;; esac
  done
  [ "$put" = 1 ] || cmd+=("$resume_opt" "$pf")
}

cmd=("$@")
attempt=0
while :; do
  attempt=$((attempt + 1))
  rm -f "$log.cut-mark"
  t0=$(date +%s)
  perl -e "$DEADLINE" "$budget" "$log.cut-mark" ${cmd[@]+"${cmd[@]}"} 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  took=$(( $(date +%s) - t0 ))
  pred=$(sed -n 's/.*predicted ~\([0-9]*\)s.*/\1/p' "$log" | head -1)
  if [ ! -f "$log.cut-mark" ]; then
    note "shard-run: attempt $attempt — predicted ~${pred:-?}s · budget ${budget}s · took ${took}s · exit $rc"
    exit "$rc"
  fi
  rm -f "$log.cut-mark"
  mv "$log" "$log.cut-$attempt"
  cp "$log.cut-$attempt" "$log"
  if grep -Eq '^(FAIL  |TIMEOUT )' "$log"; then
    note "shard-run: attempt $attempt CUT SHORT at ${budget}s (predicted ~${pred:-?}s) with a test already red — no rerun"
    echo "::error::this shard was cut short at ${budget}s and a test in it had already failed — red, not rerun"
    exit 124
  fi
  if [ "$attempt" -gt "$retries" ]; then
    note "shard-run: attempt $attempt CUT SHORT at ${budget}s again (predicted ~${pred:-?}s) — red"
    echo "::error::this shard was cut short at ${budget}s on every attempt ($attempt) — the forecast is wrong or a test hangs; see the log for the test in flight"
    exit 124
  fi
  if [ -n "$resume_opt" ]; then
    # a test passed when its own block's PASS line came (a drill's inner PASS is not it)
    cat "$log".cut-* | awk '/^=== /{h=$2} /^PASS  / && $2 == h {print h; h=""}' | sort -u > "$log.passed"
    resume_cmd "$@"
    note "shard-run: attempt $attempt CUT SHORT at ${budget}s (predicted ~${pred:-?}s), no test red — rerunning the rest of the shard once ($(wc -l < "$log.passed" | tr -d ' ') test(s) already passed, not run again)"
  else
    note "shard-run: attempt $attempt CUT SHORT at ${budget}s (predicted ~${pred:-?}s), no test red — rerunning the same shard once"
  fi
  echo "::warning::shard cut short at ${budget}s with no test red — rerunning it once (same commit, same selection)"
done
