#!/bin/bash
# doctor-resident-selftest.sh — `fleet doctor`'s fleet row names a resident
# daemon still on the code from before the install's version switch (issue #2716).
#
#   A  a resident started BEFORE the install link's switch → WARN fleet naming
#      it (and only it: one started after is current)
#   B  every resident started after the switch → no such WARN
#   C  a checkout install (no link) → no such WARN, whatever the daemons say
#   D  (macOS) the `daemons` row: a system-shape login whose installed plists
#      still name a log file → ONE WARN naming fleet-login-new.sh <login>
#      --daemons-only --apply; /dev/null keys → no row
#
# The daemons are the seam FLEET_DOCTOR_RESIDENT_CMD (`<unit> <started epoch>`);
# the install is a symlink in a temp dir. Exit 0 = pass.
# Drives: bin/fleet-doctor.sh.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
W="$(mktemp -d)" || exit 2
trap 'rm -rf "$W"' EXIT
st_tally count miss

mkdir -p "$W/home" "$W/conf" "$W/v1" "$W/dir"
ln -s "$W/v1" "$W/fleet"
SW=$(stat -c %Y "$W/fleet" 2>/dev/null || stat -f %m "$W/fleet")
row() { # <install root> <resident rows> → the doctor's fleet rows
  env HOME="$W/home" FLEET_CONF_DIR="$W/conf" FLEET_SKIP_GLOBAL_CONF=1 \
    FLEET_INSTALL_ROOT="$1" FLEET_DOCTOR_RESIDENT_CMD="printf '$2'" \
    sh "$BIN/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+fleet([[:space:]]|$)'
}

out=$(row "$W/fleet" "cred-proxy $((SW - 600))\nmemguard $((SW + 5))\n")
st_has   "A a resident from before the switch: WARN" "$out" "WARN  fleet    常驻服务还在跑切换前的版本：cred-proxy（"
st_hasnt "A …naming only it" "$out" "memguard"
st_has   "A …and how to restart it" "$out" "重启一次"

out=$(row "$W/fleet" "cred-proxy $((SW + 1))\nmemguard $((SW + 5))\n")
st_hasnt "B all after the switch: no WARN" "$out" "常驻服务"

out=$(row "$W/dir" "cred-proxy $((SW - 600))\n")
st_hasnt "C a checkout install: no WARN" "$out" "常驻服务"

# D  the daemons row (macOS): a system-shape login whose installed plists still
#    name a log file (StandardOutPath / StandardErrorPath not /dev/null) → ONE
#    WARN for all of them naming the operator's command; /dev/null keys → none
if [ "$(uname)" = Darwin ]; then
  mkdir -p "$W/agents" "$W/daemons" "$W/node"
  mk() { python3 -c 'import plistlib,sys; plistlib.dump({"Label":sys.argv[2],"UserName":"alice","ProgramArguments":["/bin/sh","-c","true"],"StandardOutPath":"/dev/null","StandardErrorPath":sys.argv[3]}, open(sys.argv[1],"wb"))' "$W/daemons/$1.plist" "$1" "$2"; }
  drow() {
    env HOME="$W/home" FLEET_CONF_DIR="$W/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_INSTALL_ROOT="$W/dir" \
      FLEET_LAUNCHD_AGENTS_DIR="$W/agents" FLEET_INSTALL_DAEMON_DIR="$W/daemons" FLEET_INSTALL_LOGIN=alice \
      FLEET_NODE_STATE="$W/node" sh "$BIN/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+daemons([[:space:]]|$)'
  }
  mk com.claude-fleet.alice.collect "$W/home/.config/claude-fleet/logs/collect.launchd.log"
  mk com.claude-fleet.alice.cleanup "$W/home/.config/claude-fleet/logs/cleanup.launchd.log"
  mk com.claude-fleet.alice.spinner /dev/null
  out=$(drow)
  st_has "D older plists: one WARN for both" "$out" "WARN  daemons  2 of alice's background services (system LaunchDaemons) still have launchd open their log in the home"
  st_has "D …naming the operator's command" "$out" "/fleet-login-new.sh alice --daemons-only --apply"
  [ "$(printf '%s\n' "$out" | grep -c 'still have launchd open their log')" = 1 ] || st_miss "D more than one such row: $out"
  mk com.claude-fleet.alice.collect /dev/null; mk com.claude-fleet.alice.cleanup /dev/null
  out=$(drow)
  st_hasnt "D /dev/null keys: no such WARN" "$out" "still have launchd open their log"
fi

printf 'doctor-resident selftest: %s checks, %s failed\n' "$CHECKS" "$FAIL"
st_done
