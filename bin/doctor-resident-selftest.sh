#!/bin/bash
# doctor-resident-selftest.sh — `fleet doctor`'s fleet row names a resident
# daemon still on the code from before the install's version switch (issue #2716).
#
#   A  a resident started BEFORE the install link's switch → WARN fleet naming
#      it (and only it: one started after is current)
#   B  every resident started after the switch → no such WARN
#   C  a checkout install (no link) → no such WARN, whatever the daemons say
#
# The daemons are the seam FLEET_DOCTOR_RESIDENT_CMD (`<unit> <started epoch>`);
# the install is a symlink in a temp dir. Exit 0 = pass.
# Drives: bin/fleet-doctor.sh.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d)" || exit 2
trap 'rm -rf "$W"' EXIT
CHECKS=0; FAILS=0
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) FAILS=$((FAILS + 1)); printf 'FAIL %s\n  got: %s\n  missing: %s\n' "$1" "$2" "$3" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) FAILS=$((FAILS + 1)); printf 'FAIL %s\n  got: %s\n  unwanted: %s\n' "$1" "$2" "$3" ;; esac; }

mkdir -p "$W/home" "$W/conf" "$W/v1" "$W/dir"
ln -s "$W/v1" "$W/fleet"
SW=$(stat -c %Y "$W/fleet" 2>/dev/null || stat -f %m "$W/fleet")
row() { # <install root> <resident rows> → the doctor's fleet rows
  env HOME="$W/home" FLEET_CONF_DIR="$W/conf" FLEET_SKIP_GLOBAL_CONF=1 \
    FLEET_INSTALL_ROOT="$1" FLEET_DOCTOR_RESIDENT_CMD="printf '$2'" \
    sh "$BIN/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+fleet([[:space:]]|$)'
}

out=$(row "$W/fleet" "cred-proxy $((SW - 600))\nmemguard $((SW + 5))\n")
has   "A a resident from before the switch: WARN" "$out" "WARN  fleet    常驻服务还在跑切换前的版本：cred-proxy（"
hasnt "A …naming only it" "$out" "memguard"
has   "A …and how to restart it" "$out" "重启一次"

out=$(row "$W/fleet" "cred-proxy $((SW + 1))\nmemguard $((SW + 5))\n")
hasnt "B all after the switch: no WARN" "$out" "常驻服务"

out=$(row "$W/dir" "cred-proxy $((SW - 600))\n")
hasnt "C a checkout install: no WARN" "$out" "常驻服务"

printf 'doctor-resident selftest: %s checks, %s failed\n' "$CHECKS" "$FAILS"
[ "$FAILS" = 0 ]
