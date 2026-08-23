#!/bin/sh
# fleet-daemon-loaded.sh <com.claude-fleet.X> — is that optional daemon ACTUALLY
# installed on this machine? Exit 0 = loaded, 1 = missing, 2 = can't tell.
#
# Why this exists (issue #492): fleet-doctor's optional-daemon checks read each
# fleet's conf FLAG — which says whether the fleet WANTS the daemon, not whether
# anything is running. A machine can be missing the agent entirely and still
# collect a row of PASSes. That is how a fleet ran for months with
# com.claude-fleet.ledger-watch never installed (11 of the 12 shipped agents were)
# while the doctor printed "every closed session indexed for resume" and every
# hand-closed session went unrecorded. A check that cannot fail is worse than none.
#
# Kept as its own script rather than a function: fleet-doctor.sh is /bin/sh and
# deliberately cannot source the bash-only fleet-lib.sh, and a standalone exit-code
# probe is what makes it unit-testable (bin/fleet-daemon-loaded-selftest.sh shims
# uname/launchctl/systemctl on PATH to drive every branch on any host).
#
# Shell-options policy: EXECUTED, /bin/sh → set -u only.
set -u  # POSIX sh: pipefail is bash-only (dash has none)

label="${1:-}"
[ -n "$label" ] || exit 2

# macOS: `launchctl list` prints one line per loaded agent, label in column 3.
if [ "$(uname 2>/dev/null)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
  launchctl list 2>/dev/null | awk -v l="$label" '$3 == l { found = 1 } END { exit(found ? 0 : 1) }'
  exit $?
fi

# Linux: the units are timer-driven, so ask systemd about the .timer.
if command -v systemctl >/dev/null 2>&1; then
  unit="claude-fleet-${label#com.claude-fleet.}.timer"
  systemctl --user is-enabled "$unit" >/dev/null 2>&1 && exit 0
  systemctl --user is-active  "$unit" >/dev/null 2>&1 && exit 0
  exit 1
fi

exit 2   # no init system we know → say so rather than inventing a verdict
