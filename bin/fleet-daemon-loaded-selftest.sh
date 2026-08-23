#!/bin/bash
# fleet-daemon-loaded-selftest.sh — hermetic tests for bin/fleet-daemon-loaded.sh,
# the probe that decides whether an optional fleet daemon is really installed.
#
# This probe exists because the doctor's old check could not fail (issue #492), so
# the one thing these tests must prove is that the NEW check can: a missing agent
# has to come back 1, not 0 and not 2.
#
# Every branch is driven on ANY host by shimming `uname`, `launchctl` and
# `systemctl` onto PATH — otherwise the launchd branch would be untested on Linux
# CI and the systemd branch untested on the macOS machines that run this fleet.
#
# Exit 0 = pass. Hermetic: no real launchctl/systemctl, no network.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
P="$BIN/fleet-daemon-loaded.sh"
[ -f "$P" ] || { printf 'selftest: %s not found\n' "$P" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-daemon-loaded-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
SHIM="$WORK/shim"; mkdir -p "$SHIM"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
rc_is() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected rc $2, got rc $3"; }
probe() { PATH="$SHIM:$PATH" sh "$P" "$@"; printf '%s' $?; }

mkshim() { printf '#!/bin/sh\n%s\n' "$2" > "$SHIM/$1"; chmod +x "$SHIM/$1"; }

# ---- launchd branch (macOS) -------------------------------------------------
mkshim uname 'echo Darwin'
# `launchctl list` output shape: PID<TAB>status<TAB>label. Only col 3 may match —
# a label appearing in another column (or as a substring) must NOT count.
mkshim launchctl 'printf "40985\t0\tcom.claude-fleet.ledger-watch\n-\t0\tcom.claude-fleet.cleanup\n"'
rc_is "launchd: loaded agent → 0"  0 "$(probe com.claude-fleet.ledger-watch)"
rc_is "launchd: agent listed with '-' pid is still loaded" 0 "$(probe com.claude-fleet.cleanup)"
rc_is "launchd: absent agent → 1" 1 "$(probe com.claude-fleet.base-sync)"
rc_is "launchd: substring of a loaded label is not a match" 1 "$(probe com.claude-fleet.ledger)"
mkshim launchctl 'exit 0'      # nothing loaded at all
rc_is "launchd: empty list → 1" 1 "$(probe com.claude-fleet.ledger-watch)"

# ---- systemd branch (Linux) -------------------------------------------------
mkshim uname 'echo Linux'
rm -f "$SHIM/launchctl"
# is-enabled succeeds only for the ledger-watch TIMER; everything else fails.
mkshim systemctl '
case "$*" in
  *"is-enabled"*"claude-fleet-ledger-watch.timer"*) exit 0 ;;
  *"is-active"*"claude-fleet-cleanup.timer"*)       exit 0 ;;
  *) exit 1 ;;
esac'
rc_is "systemd: enabled timer → 0"          0 "$(probe com.claude-fleet.ledger-watch)"
rc_is "systemd: active-but-not-enabled → 0" 0 "$(probe com.claude-fleet.cleanup)"
rc_is "systemd: neither → 1"                1 "$(probe com.claude-fleet.base-sync)"

# ---- neither init system → "can't tell", never a fabricated verdict ---------
mkshim uname 'echo Plan9'
rm -f "$SHIM/systemctl"
# PATH must be the shim dir ALONE here: on a Linux runner the real systemctl is on
# the normal PATH, so merely deleting the shim models nothing (that is how this
# case passed on macOS and failed in CI). /bin/sh is invoked by absolute path so
# the stripped PATH can't break the run itself.
rc_is "no init system → 2 (unknown, not a guess)" 2 \
      "$(PATH="$SHIM" /bin/sh "$P" com.claude-fleet.ledger-watch; printf '%s' $?)"

# ---- argument guard ---------------------------------------------------------
mkshim uname 'echo Darwin'
rc_is "no label → 2" 2 "$(probe)"

printf 'selftest OK: fleet-daemon-loaded (%s assertions — launchd/systemd/unknown branches, all shimmed)\n' "$CHECKS"
