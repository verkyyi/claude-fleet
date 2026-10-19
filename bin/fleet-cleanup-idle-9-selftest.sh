#!/bin/bash
# The stuck reaps of issue #4822 (StuckReaps): another repo's pass clearing a
# countdown, a `looping` stamp over the agent's own `done`.
# selftest-part-of: fleet-cleanup-idle-selftest.sh
BIN="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ]; then
  set -- StuckReaps
fi
SELFTEST_PART=4/4 exec bash "$BIN/fleet-cleanup-idle-selftest.sh" "$@"
