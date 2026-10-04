#!/bin/bash
# fleet-daemon-loaded-selftest.sh — hermetic tests for bin/fleet-daemon-loaded.sh,
# the probe that decides whether an optional fleet daemon is really installed, and
# for the launchd-shape rule in bin/fleet-daemon-lib.sh it reads by (issue #1495:
# fleet_daemon_shape / fleet_daemon_label / fleet_daemon_plist / fleet_daemon_domain
# — the same functions fleet-install-apply.sh keeps a login's shape by).
#
# This probe exists because the doctor's old check could not fail (issue #492), so
# the one thing these tests must prove is that the NEW check can: a missing agent
# has to come back 1, not 0 and not 2. #1495 adds the other half: a loaded unit
# of the OTHER shape (a system LaunchDaemon, com.claude-fleet.<login>.<unit>)
# must come back 0, and one that only a root could see must never read «missing».
#
# Every branch is driven on ANY host by shimming `uname`, `launchctl`, `sudo` and
# `systemctl` onto PATH — otherwise the launchd branch would be untested on Linux
# CI and the systemd branch untested on the macOS machines that run this fleet.
# The plist dirs and the login are the lib's env knobs, pointed at this sandbox.
#
# Exit 0 = pass. Hermetic: no real launchctl/sudo/systemctl, no network.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
P="$BIN/fleet-daemon-loaded.sh"
L="$BIN/fleet-daemon-lib.sh"
[ -f "$P" ] || { printf 'selftest: %s not found\n' "$P" >&2; exit 2; }
[ -f "$L" ] || { printf 'selftest: %s not found\n' "$L" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-daemon-loaded-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
SHIM="$WORK/shim"; AG="$WORK/LaunchAgents"; LD="$WORK/LaunchDaemons"
mkdir -p "$SHIM" "$AG" "$LD"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
rc_is() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected rc $2, got rc $3"; }
eq()    { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected '$2', got '$3'"; }
# the probe, in a sandbox: this login is `guest`, its plist dirs are ours
probe() { PATH="$SHIM:$PATH" FLEET_INSTALL_LOGIN=guest FLEET_LAUNCHD_AGENTS_DIR="$AG" FLEET_INSTALL_DAEMON_DIR="$LD" \
          sh "$P" "$@"; printf '%s' $?; }

mkshim() { printf '#!/bin/sh\n%s\n' "$2" > "$SHIM/$1"; chmod +x "$SHIM/$1"; }

# ---- the lib's shape rule (issue #1495) — what the probe and the installer share ----
lib() { ( export FLEET_INSTALL_LOGIN=guest FLEET_LAUNCHD_AGENTS_DIR="$AG" FLEET_INSTALL_DAEMON_DIR="$LD"
          . "$L" && "$@" ); }
eq "lib: neither dir has a plist → gui"   gui    "$(lib fleet_daemon_shape)"
: > "$LD/com.claude-fleet.guest.cleanup.plist"
eq "lib: only a system plist for this login → system" system "$(lib fleet_daemon_shape)"
eq "lib: another login's system plist is not ours"    gui    "$(lib fleet_daemon_shape other)"
: > "$AG/com.claude-fleet.collect.plist"
eq "lib: a gui agent outranks a system plist → gui"  gui    "$(lib fleet_daemon_shape)"
rm -f "$AG/com.claude-fleet.collect.plist"
eq "lib: label, gui"        com.claude-fleet.cleanup        "$(lib fleet_daemon_label cleanup gui)"
eq "lib: label, system"     com.claude-fleet.guest.cleanup  "$(lib fleet_daemon_label cleanup system)"
eq "lib: label, this shape (system)" com.claude-fleet.guest.cleanup "$(lib fleet_daemon_label cleanup)"
eq "lib: label, explicit login"      com.claude-fleet.other.cleanup "$(lib fleet_daemon_label cleanup system other)"
eq "lib: plist, gui"        "$AG/com.claude-fleet.cleanup.plist"        "$(lib fleet_daemon_plist cleanup gui)"
eq "lib: plist, system"     "$LD/com.claude-fleet.guest.cleanup.plist"  "$(lib fleet_daemon_plist cleanup system)"
eq "lib: domain, system"    system          "$(lib fleet_daemon_domain system)"
eq "lib: domain, gui"       "gui/$(id -u)"  "$(lib fleet_daemon_domain gui)"
rm -f "$LD"/*.plist

# ---- launchd branch (macOS), gui shape ---------------------------------------
mkshim uname 'echo Darwin'
mkshim sudo 'exit 1'            # no passwordless sudo on this login
# `launchctl list` output shape: PID<TAB>status<TAB>label. Only col 3 may match —
# a label appearing in another column (or as a substring) must NOT count.
# `launchctl print system/<label>` (the system-shape probe) finds nothing here.
mkshim launchctl '
case "$1" in
  list)  printf "40985\t0\tcom.claude-fleet.ledger-watch\n-\t0\tcom.claude-fleet.cleanup\n" ;;
  print) exit 113 ;;
  *)     exit 1 ;;
esac'
rc_is "launchd: loaded agent → 0"  0 "$(probe com.claude-fleet.ledger-watch)"
rc_is "launchd: agent listed with '-' pid is still loaded" 0 "$(probe com.claude-fleet.cleanup)"
rc_is "launchd: absent agent → 1" 1 "$(probe com.claude-fleet.base-sync)"
rc_is "launchd: substring of a loaded label is not a match" 1 "$(probe com.claude-fleet.ledger)"
mkshim launchctl 'case "$1" in print) exit 113 ;; *) exit 0 ;; esac'   # nothing loaded at all
rc_is "launchd: empty list → 1" 1 "$(probe com.claude-fleet.ledger-watch)"

# ---- launchd branch, system shape (issue #1495) ------------------------------
# The gui listing is empty (a guest login has no LaunchAgents); the unit is a
# system LaunchDaemon labelled com.claude-fleet.guest.<unit>.
# (a) `launchctl print system/<label>` answers the unprivileged caller → 0.
mkshim launchctl '
case "$1 $2" in
  "print system/com.claude-fleet.guest.cleanup") exit 0 ;;
  "print "*) exit 113 ;;
  *) exit 0 ;;
esac'
rc_is "system: loaded LaunchDaemon, seen unprivileged → 0" 0 "$(probe com.claude-fleet.cleanup)"
rc_is "system: the gui label of that unit is not what is asked for" 1 "$(probe com.claude-fleet.guest.cleanup)"
rc_is "system: another unit → 1" 1 "$(probe com.claude-fleet.base-sync)"
# (b) unprivileged print is refused; root's view (sudo -n, no prompt) sees it → 0.
mkshim launchctl 'case "$1" in print) [ "${AS_ROOT:-}" = 1 ] && [ "$2" = system/com.claude-fleet.guest.ledger-watch ] && exit 0; exit 113 ;; *) exit 0 ;; esac'
mkshim sudo 'case "$*" in "-n true") exit 0 ;; "-n launchctl print "*) shift; AS_ROOT=1 exec "$@" ;; *) exit 1 ;; esac'
rc_is "system: loaded, seen only by root (sudo -n) → 0" 0 "$(probe com.claude-fleet.ledger-watch)"
# (c) sudo works and root sees nothing either: verified absent — a plist on disk
# does NOT make it «installed» (the #492 property: the check can still fail).
: > "$LD/com.claude-fleet.guest.base-sync.plist"
rc_is "system: verified absent by root, plist on disk → 1" 1 "$(probe com.claude-fleet.base-sync)"
# (d) no sudo, launchd unanswerable: a system-shape login's plist on disk is
# «installed, not verified loaded» (3) — never «NOT installed».
mkshim sudo 'exit 1'
rc_is "system: no sudo, plist on disk, system shape → 3" 3 "$(probe com.claude-fleet.base-sync)"
rc_is "system: no sudo, no plist → 1" 1 "$(probe com.claude-fleet.dispatch)"
# (e) the same plist under a GUI-shape login (an agent is installed) earns no
# credit: the gui listing was the answer, the system plist is a leftover.
: > "$AG/com.claude-fleet.collect.plist"
rc_is "system: no sudo, plist on disk, but gui shape → 1" 1 "$(probe com.claude-fleet.base-sync)"
rm -f "$AG"/*.plist "$LD"/*.plist
# (f) sudo must never be reached for while the gui listing answers.
mkshim sudo 'echo "sudo called" >> "'"$WORK"'/sudo.log"; exit 1'
mkshim launchctl 'case "$1" in list) printf "1\t0\tcom.claude-fleet.cleanup\n" ;; *) exit 113 ;; esac'
rc_is "system: gui hit short-circuits" 0 "$(probe com.claude-fleet.cleanup)"
CHECKS=$((CHECKS + 1)); [ ! -f "$WORK/sudo.log" ] || fail "sudo was called although the gui listing answered"

# ---- systemd branch (Linux) -------------------------------------------------
mkshim uname 'echo Linux'
rm -f "$SHIM/launchctl" "$SHIM/sudo"
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

printf 'selftest OK: fleet-daemon-loaded (%s assertions — lib shape rule, launchd gui + system shapes, systemd, unknown; all shimmed)\n' "$CHECKS"
