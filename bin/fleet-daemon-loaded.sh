#!/bin/sh
# fleet-daemon-loaded.sh <com.claude-fleet.X> — is that optional daemon ACTUALLY
# installed on this machine? Exit 0 = loaded, 1 = missing, 2 = can't tell,
# 3 = installed as a system LaunchDaemon, not verifiably loaded (issue #1495).
#
# Why this exists (issue #492): fleet-doctor's optional-daemon checks read each
# fleet's conf FLAG — which says whether the fleet WANTS the daemon, not whether
# anything is running. A machine can be missing the agent entirely and still
# collect a row of PASSes. That is how a fleet ran for months with
# com.claude-fleet.ledger-watch never installed (11 of the 12 shipped agents were)
# while the doctor printed "every closed session indexed for resume" and every
# hand-closed session went unrecorded. A check that cannot fail is worse than none.
#
# TWO SHAPES on macOS (issue #1495). A console login's daemons are gui
# LaunchAgents — `launchctl list` in gui/<uid> shows them as com.claude-fleet.
# <unit>. A guest login an admin set up (#1192) runs system LaunchDaemons carrying
# UserName, labelled com.claude-fleet.<login>.<unit>, which that listing never
# shows — so this probe read every one of them as «NOT installed» while the
# doctor's `daemons` line, which reads the tick stamps, said all 13 were ticking.
# The gui listing still goes first (a console login is unchanged); on a miss the
# system domain is asked for the login-qualified label — `launchctl print
# system/<label>` answers an unprivileged caller on current macOS, and root's view
# (`sudo -n`, never a prompt) is tried where it does not. Both unanswered: a
# system-shape login whose plist is on disk is INSTALLED and unverified (3), never
# «missing»; everything else is 1. The label, the plist path and the shape come
# from fleet-daemon-lib.sh — the rule fleet-install-apply.sh keeps the login's
# shape by — so the installer and the probe cannot disagree again.
#
# Kept as its own script rather than a function: fleet-doctor.sh is /bin/sh and
# deliberately cannot source the bash-only fleet-lib.sh, and a standalone exit-code
# probe is what makes it unit-testable (bin/fleet-daemon-loaded-selftest.sh shims
# uname/launchctl/sudo/systemctl on PATH to drive every branch on any host).
#
# Shell-options policy: EXECUTED, /bin/sh → set -u only.
set -u  # POSIX sh: pipefail is bash-only (dash has none)

label="${1:-}"
[ -n "$label" ] || exit 2
unit="${label#com.claude-fleet.}"

# The shape rule (gui vs system, label, plist path) is the lib's, not this file's.
# Forkless dir-of-$0: the selftest's no-init-system leg runs with PATH stripped.
case "$0" in */*) _dlib="${0%/*}" ;; *) _dlib=. ;; esac
_dlib="$_dlib/fleet-daemon-lib.sh"
# shellcheck source=/dev/null
[ -f "$_dlib" ] && . "$_dlib"

# A login the machine daemon manages (issue #2332): its tasks run under
# com.claude-fleet.node, so an account unit counts as installed while that
# daemon is (machine units — memguard — are the node row's to judge).
if command -v fleet_node_manages >/dev/null 2>&1 && [ "$unit" != memguard ] && fleet_node_manages; then
  _nsup="${_dlib%/*}/fleet-node-supervisor.py"
  [ -f "$_nsup" ] || exit 1
  python3 -I "$_nsup" status --check >/dev/null 2>&1 && exit 0
  exit 1
fi

# macOS: `launchctl list` prints one line per loaded agent, label in column 3.
if [ "$(uname 2>/dev/null)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
  launchctl list 2>/dev/null | awk -v l="$label" '$3 == l { found = 1 } END { exit(found ? 0 : 1) }' && exit 0
  # system shape (issue #1495): the login-qualified label in the system domain.
  command -v fleet_daemon_label >/dev/null 2>&1 || exit 1   # no lib beside us: gui only, as before
  syslabel=$(fleet_daemon_label "$unit" system)
  launchctl print "system/$syslabel" >/dev/null 2>&1 && exit 0
  if sudo -n true >/dev/null 2>&1; then                     # root's view, where the unprivileged one is refused
    sudo -n launchctl print "system/$syslabel" >/dev/null 2>&1 && exit 0
    exit 1                                                  # verified absent from both domains
  fi
  # No way to ask launchd: a system-shape login's plist on disk is «installed,
  # not verified loaded» (3). A gui-shape login gets no such credit — its system
  # plist, if any, is a leftover, and the gui listing above was the answer.
  [ "$(fleet_daemon_shape)" = system ] && [ -f "$(fleet_daemon_plist "$unit" system)" ] && exit 3
  exit 1
fi

# Linux: the units are timer-driven, so ask systemd about the .timer.
if command -v systemctl >/dev/null 2>&1; then
  unit="claude-fleet-${unit}.timer"
  systemctl --user is-enabled "$unit" >/dev/null 2>&1 && exit 0
  systemctl --user is-active  "$unit" >/dev/null 2>&1 && exit 0
  exit 1
fi

exit 2   # no init system we know → say so rather than inventing a verdict
