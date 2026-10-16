#!/bin/bash
# Hub/bridge regression tests run entirely inside temporary fixtures.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# part 1 of 4 here, the rest in its part files (bin/selftest_part.py, issue #2694)
SELFTEST_PART=${SELFTEST_PART:-1/4} exec python3 "$BIN/fleet-hub-selftest.py" "$@"
