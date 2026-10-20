#!/bin/bash
# fleet-ci-say-selftest.sh — bin/fleet-ci-say.sh, the CI checks' "say, don't file"
# default (issue #4898): the title + body land on the run's summary page, one
# warning on stderr, nothing on stdout, exit 0, every other filer flag ignored.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_sandbox "${TMPDIR:-/tmp}/ci-say.XXXXXX"
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
out=$(GITHUB_STEP_SUMMARY="$WORK/sum" bash "$BIN/fleet-ci-say.sh" --repo o/r --breakage-key flaky-x \
        --fault-sha abc --label flaky --priority p1 --title 'T 时好时坏' --body 'B line one
B line two' 2>"$WORK/err"); rc=$?
[ "$rc" = 0 ] || fail "exit $rc"
[ -z "$out" ] || fail "stdout must stay empty (no issue URL): $out"
grep -q '^### T 时好时坏$' "$WORK/sum" && grep -q '^B line two$' "$WORK/sum" || fail "summary: $(cat "$WORK/sum")"
grep -q '^::warning title=flaky-x::T 时好时坏' "$WORK/err" || fail "warning: $(cat "$WORK/err")"
bash "$BIN/fleet-ci-say.sh" --title t >/dev/null 2>&1 || fail "no summary file must still exit 0"
echo "fleet-ci-say-selftest: ok"
