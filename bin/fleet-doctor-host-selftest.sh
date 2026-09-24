#!/bin/bash
# fleet-doctor-host-selftest.sh — the `host` section of bin/fleet-doctor.sh
# (EPIC #1074): checks on the machine itself that burn CPU/IO on work no session
# asked for. One case block per doctor row; later members append theirs.
#
# Pinned for every row:
#   - the verdict for each state the fake tool reports (WARN / PASS / INFO);
#   - that a WARN names the command that fixes it AND how to silence the line
#     (EPIC rule 9: an advisory you cannot turn off becomes noise);
#   - that the whole section is ABSENT on Linux (a macOS-only check says nothing
#     there, never an error);
#   - that the run survives to the doctor's last check and prints nothing on
#     stderr (see fleet-doctor-machine-selftest.sh for why both matter).
#
# The network row (issue #1081) is the one row that also runs on Linux: it is
# pinned on both, and the Linux block asserts it renders there while the rest stay
# silent.
#
# Hermetic: fake uname/mdutil/launchctl/pmset/defaults/pgrep/netstat/networksetup/ip
# on PATH, scratch
# HOME/TMPDIR/conf. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-doctor.sh fleet-daemon-lib.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-host-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf/fleets/tfleet"
for f in fleet-doctor.sh fleet-diskguard.sh fleet-lib.sh fleet-daemon-lib.sh fleet-daemon-loaded.sh; do
  [ -f "$BIN/$f" ] && cp "$BIN/$f" "$WORK/bin/"
done
chmod +x "$WORK/bin/"*.sh

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- line ---\n%s\n' "${2:-(none)}" >&2; exit 1; }
has()  { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) ;; *) fail "$3" "$2";; esac; }
none() { CHECKS=$((CHECKS + 1)); [ -z "$1" ] || fail "$2" "$1"; }

# --- fake uname: the host section is macOS-only, so the OS is switchable.
cat > "$WORK/fakepath/uname" <<SH
#!/bin/sh
[ "\$1" = -s ] && { cat "$WORK/os"; exit 0; }
exec /usr/bin/uname "\$@"
SH
# --- fake mdutil: prints the fixture, records its argv.
cat > "$WORK/fakepath/mdutil" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/mdutil.argv"
cat "$WORK/mdutil.out"
SH
# --- fake launchctl: `limit maxfiles` prints the fixture; anything else goes to
# the real one when there is one (the daemon probe elsewhere in the doctor).
cat > "$WORK/fakepath/launchctl" <<SH
#!/bin/sh
if [ "\$1" = limit ]; then printf '%s\n' "\$*" >> "$WORK/launchctl.argv"; cat "$WORK/maxfiles.out"; exit 0; fi
[ -x /bin/launchctl ] && exec /bin/launchctl "\$@"
exit 1
SH
printf '\tmaxfiles    256            unlimited      \n' > "$WORK/maxfiles.out"
chmod +x "$WORK/fakepath/uname" "$WORK/fakepath/mdutil" "$WORK/fakepath/launchctl"
# --- fake pmset (issue #1076): `-g` prints the fixture (the active power
# profile); every argv is recorded so the test can prove the doctor never ran
# `pmset -a …` (a write).
cat > "$WORK/fakepath/pmset" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/pmset.argv"
cat "$WORK/pmset.out"
SH
# --- fake defaults (issue #1076): answers `read com.apple.assistant.support
# "Assistant Enabled"` from the fixture; an EMPTY fixture is the missing-key case,
# and behaves as macOS does (a "does not exist" line on stderr, exit 1). Argv is
# recorded to prove the doctor only ever `read`s.
cat > "$WORK/fakepath/defaults" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/defaults.argv"
[ -s "$WORK/defaults.out" ] || { echo 'The domain/default pair of (com.apple.assistant.support, Assistant Enabled) does not exist' >&2; exit 1; }
cat "$WORK/defaults.out"
SH
# --- fake pgrep (issue #1076): `-x <name>` is live iff <name> is a line of the
# fixture; anything else falls through to the real pgrep, so a helper the doctor
# sources keeps working.
cat > "$WORK/fakepath/pgrep" <<SH
#!/bin/sh
if [ "\$1" = -x ] && [ \$# -eq 2 ]; then
  printf '%s\n' "\$2" >> "$WORK/pgrep.argv"
  grep -qx -- "\$2" "$WORK/pgrep.live" 2>/dev/null && { echo 4242; exit 0; }
  exit 1
fi
exec /usr/bin/pgrep "\$@"
SH
chmod +x "$WORK/fakepath/uname" "$WORK/fakepath/mdutil" "$WORK/fakepath/pmset" "$WORK/fakepath/defaults" "$WORK/fakepath/pgrep"
# --- fake netstat / networksetup / ip (issue #1081): the routing table and the
# hardware-port list come from fixtures; every argv is recorded so the test can
# prove the doctor only READ them (networksetup -listallhardwareports, never -set…).
cat > "$WORK/fakepath/netstat" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/netstat.argv"
cat "$WORK/netstat.out"
SH
cat > "$WORK/fakepath/networksetup" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/networksetup.argv"
cat "$WORK/networksetup.out"
SH
cat > "$WORK/fakepath/ip" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/ip.argv"
cat "$WORK/ip.out"
SH
chmod +x "$WORK/fakepath/netstat" "$WORK/fakepath/networksetup" "$WORK/fakepath/ip"
# A wired-only host: one default route.
nsone() { printf 'Routing tables\n\nInternet:\nDestination        Gateway            Flags               Netif Expire\ndefault            192.168.1.254      UGScg                 en0       \ndefault            link#26            UCSIg           bridge100      !\n127                127.0.0.1          UCS                   lo0       \n' > "$WORK/netstat.out"; }
nsone
printf 'Hardware Port: Ethernet\nDevice: en0\nEthernet Address: bc:74:ea:ca:e9:95\n\nHardware Port: Wi-Fi\nDevice: en1\nEthernet Address: bc:74:ea:b6:25:1c\n' > "$WORK/networksetup.out"
printf 'default via 10.0.0.1 dev eth0 proto dhcp src 10.0.0.5 metric 100\n' > "$WORK/ip.out"
# Baseline fixtures for the #1076 rows — a tidy headless host — so the spotlight
# cases above them see a complete section; each row's own block overrides these.
printf ' sleep                0 (sleep prevented by powerd)\n autorestart          1\n womp                 1\n' > "$WORK/pmset.out"
: > "$WORK/defaults.out"
: > "$WORK/pgrep.live"

# A fleet whose worktree root carries .noindex — the wtroot row lives in this section too.
printf 'FLEET_REPO="o/r"\nFLEET_WORKTREE_ROOT="%s/wt.noindex"\n' "$WORK" > "$WORK/conf/fleets/tfleet/conf"

run_doctor() {
  : > "$WORK/stderr"
  PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
  FLEET_CONF_DIR="$WORK/conf" \
    sh "$WORK/bin/fleet-doctor.sh" 2>"$WORK/stderr"
}
row() { printf '%s\n' "$2" | grep -aE "^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+$1([[:space:]]|\$)" | head -1; }
survived() { printf '%s\n' "$1" | grep -qaE '^[[:space:]]+(PASS|WARN)[[:space:]]+perl'; }
quiet() { CHECKS=$((CHECKS + 1)); [ -s "$WORK/stderr" ] && fail "$1" "$(cat "$WORK/stderr")"; return 0; }

# ============================================================================
# spotlight (issue #1075)
# ============================================================================
echo Darwin > "$WORK/os"

# 1. Indexing on → WARN naming the fix, the undo, the doc and the silencer.
printf '/System/Volumes/Data:\n\tIndexing enabled. \n' > "$WORK/mdutil.out"
out="$(run_doctor)"; l="$(row spotlight "$out")"
has "WARN" "$l" "1: indexing enabled must WARN"
has "sudo mdutil -a -i off" "$l" "1: the WARN must name the command that turns it off"
has "sudo mdutil -a -i on" "$l" "1: the WARN must say how to undo it"
has "docs/HOST.md#spotlight" "$l" "1: the WARN must point at the host doc"
has "FLEET_DOCTOR_SPOTLIGHT=0" "$l" "1: the WARN must say how to silence it (EPIC rule 9)"
has "-s " "$(cat "$WORK/mdutil.argv" 2>/dev/null)" "1: the doctor must only READ state (mdutil -s), never set it"
case "$(cat "$WORK/mdutil.argv")" in *-i*) fail "1: the doctor ran a state-changing mdutil" "$(cat "$WORK/mdutil.argv")";; esac
survived "$out" || fail "1: the doctor did not reach its last check" "$l"
quiet "1: the spotlight WARN must print nothing on stderr"

# 2. Indexing off → PASS.
printf '/System/Volumes/Data:\n\tIndexing disabled.\n' > "$WORK/mdutil.out"
out="$(run_doctor)"; l="$(row spotlight "$out")"
has "PASS" "$l" "2: indexing disabled must PASS"
survived "$out" || fail "2: the doctor did not reach its last check" "$l"
quiet "2: the spotlight PASS must print nothing on stderr"
# 2b. The other spelling macOS uses.
printf '/System/Volumes/Data:\n\tIndexing and searching disabled.\n' > "$WORK/mdutil.out"
l="$(row spotlight "$(run_doctor)")"
has "PASS" "$l" "2b: 'Indexing and searching disabled' must PASS"

# 3. An answer the doctor cannot read → INFO (advice, uncounted), never a guess.
printf 'Error: unknown indexing state.\n' > "$WORK/mdutil.out"
out="$(run_doctor)"; l="$(row spotlight "$out")"
has "INFO" "$l" "3: an unreadable state must be INFO, not PASS or WARN"
has "unknown indexing state" "$l" "3: the INFO must quote what mdutil said"
quiet "3: the spotlight INFO must print nothing on stderr"

# 4. Silenced → no row, from the env and from fleet.settings.
printf '/System/Volumes/Data:\n\tIndexing enabled. \n' > "$WORK/mdutil.out"
none "$(row spotlight "$(FLEET_DOCTOR_SPOTLIGHT=0 run_doctor)")" "4: FLEET_DOCTOR_SPOTLIGHT=0 (env) must drop the row"
echo 'FLEET_DOCTOR_SPOTLIGHT=0' > "$WORK/conf/fleet.settings"
none "$(row spotlight "$(run_doctor)")" "4b: FLEET_DOCTOR_SPOTLIGHT=0 in fleet.settings must drop the row"
rm -f "$WORK/conf/fleet.settings"

# 5. wtroot moved into this section (issue #886) and still renders on macOS.
out="$(run_doctor)"; l="$(row wtroot "$out")"
has "PASS" "$l" "5: a .noindex worktree root must still PASS inside the host section"

# ============================================================================
# nofile (issue #1080)
# ============================================================================
# 7. The macOS default (256) → INFO: advice for every OTHER LaunchAgent, since the
#    fleet's own daemons raise their limit in their plists.
printf '\tmaxfiles    256            unlimited      \n' > "$WORK/maxfiles.out"
out="$(run_doctor)"; l="$(row nofile "$out")"
has "INFO" "$l" "7: a 256 system default must be INFO"
has "256" "$l" "7: the INFO must quote the soft limit it read"
has "65536" "$l" "7: the INFO must say the fleet daemons carry their own limit"
has "docs/HOST.md#nofile" "$l" "7: the INFO must point at the host doc"
has "limit maxfiles" "$(cat "$WORK/launchctl.argv" 2>/dev/null)" "7: the doctor must only READ the limit"
quiet "7: the nofile INFO must print nothing on stderr"

# 8. A raised default → PASS.
printf '\tmaxfiles    65536          524288         \n' > "$WORK/maxfiles.out"
l="$(row nofile "$(run_doctor)")"
has "PASS" "$l" "8: a raised system default must PASS"

# 9. Unreadable → no row, never a guess.
printf 'garbage\n' > "$WORK/maxfiles.out"
none "$(row nofile "$(run_doctor)")" "9: an unreadable limit must print no row"
printf '\tmaxfiles    256            unlimited      \n' > "$WORK/maxfiles.out"

# ============================================================================
# sleep (issue #1076)
# ============================================================================
# 10. Idle-sleep set → WARN naming the fix, the undo, the doc and the silencer —
#    and the doctor only ever READ the profile (pmset -g), never set it (-a).
: > "$WORK/pmset.argv"
printf ' sleep                10\n autorestart          1\n womp                 1\n' > "$WORK/pmset.out"
out="$(run_doctor)"; l="$(row sleep "$out")"
has "WARN" "$l" "10: a non-zero sleep must WARN"
has "after 10 min" "$l" "10: the WARN must say the idle minutes it read"
has "sudo pmset -a sleep 0" "$l" "10: the WARN must name the command that turns sleep off"
has "sudo pmset -a sleep 10" "$l" "10: the WARN must say how to undo it (the value it read)"
has "docs/HOST.md#headless" "$l" "10: the WARN must point at the host doc"
has "FLEET_DOCTOR_SLEEP=0" "$l" "10: the WARN must say how to silence it (EPIC rule 9)"
has "-g" "$(cat "$WORK/pmset.argv" 2>/dev/null)" "10: the doctor must READ the profile (pmset -g)"
case "$(cat "$WORK/pmset.argv")" in *-a*|*-b*|*-c*) fail "10: the doctor ran a state-changing pmset" "$(cat "$WORK/pmset.argv")";; esac
survived "$out" || fail "10: the doctor did not reach its last check" "$l"
quiet "10: the sleep WARN must print nothing on stderr"

# 10b. sleep 0 → PASS, with the companions read off the same output; the
#     "(sleep prevented by …)" suffix macOS appends must not confuse the parse.
printf ' sleep                0 (sleep prevented by powerd, caffeinate)\n autorestart          1\n womp                 1\n' > "$WORK/pmset.out"
out="$(run_doctor)"; l="$(row sleep "$out")"
has "PASS" "$l" "10b: sleep 0 must PASS"
has "autorestart=1" "$l" "10b: the PASS must report autorestart"
has "womp=1" "$l" "10b: the PASS must report womp"
quiet "10b: the sleep PASS must print nothing on stderr"

# 10c. sleep 0 but autorestart 0 → still PASS (the verdict is the sleep value),
#     with the companion named so a power cut does not go unmentioned.
printf ' sleep                0\n autorestart          0\n womp                 0\n' > "$WORK/pmset.out"
l="$(row sleep "$(run_doctor)")"
has "PASS" "$l" "10c: autorestart 0 must not change the sleep verdict"
has "sudo pmset -a autorestart 1" "$l" "10c: the PASS must name the autorestart fix"
has "sudo pmset -a womp 1" "$l" "10c: the PASS must name the womp fix"

# 10d. No sleep line at all → INFO quoting what pmset said, never a guess.
printf 'System-wide power settings:\nCurrently in use:\n' > "$WORK/pmset.out"
out="$(run_doctor)"; l="$(row sleep "$out")"
has "INFO" "$l" "10d: an unreadable profile must be INFO, not PASS or WARN"
has "Currently in use" "$l" "10d: the INFO must quote what pmset said"
quiet "10d: the sleep INFO must print nothing on stderr"

# 10e. Silenced → no row, from the env and from fleet.settings.
printf ' sleep                10\n' > "$WORK/pmset.out"
none "$(row sleep "$(FLEET_DOCTOR_SLEEP=0 run_doctor)")" "10e: FLEET_DOCTOR_SLEEP=0 (env) must drop the row"
echo 'FLEET_DOCTOR_SLEEP=0' > "$WORK/conf/fleet.settings"
none "$(row sleep "$(run_doctor)")" "10e-b: FLEET_DOCTOR_SLEEP=0 in fleet.settings must drop the row"
rm -f "$WORK/conf/fleet.settings"
printf ' sleep                0\n autorestart          1\n womp                 1\n' > "$WORK/pmset.out"

# ============================================================================
# siri (issue #1076)
# ============================================================================
# 11. Siri on → INFO (uncounted: memory, not CPU) naming where to turn it off, the
#    doc and the silencer — and the doctor only ever `read`, never `write`.
: > "$WORK/defaults.argv"
echo 1 > "$WORK/defaults.out"
out="$(run_doctor)"; l="$(row siri "$out")"
has "INFO" "$l" "11: Siri on must be INFO"
has "Siri off" "$l" "11: the INFO must say where to turn Siri off"
has "docs/HOST.md#headless" "$l" "11: the INFO must point at the host doc"
has "FLEET_DOCTOR_SIRI=0" "$l" "11: the INFO must say how to silence it (EPIC rule 9)"
has "read com.apple.assistant.support Assistant Enabled" "$(cat "$WORK/defaults.argv" 2>/dev/null)" "11: the doctor must READ the Siri key"
case "$(cat "$WORK/defaults.argv")" in *write*|*delete*) fail "11: the doctor ran a state-changing defaults" "$(cat "$WORK/defaults.argv")";; esac
survived "$out" || fail "11: the doctor did not reach its last check" "$l"
quiet "11: the siri INFO must print nothing on stderr"

# 11b. Siri off → PASS.
echo 0 > "$WORK/defaults.out"
out="$(run_doctor)"; l="$(row siri "$out")"
has "PASS" "$l" "11b: Siri off must PASS"
quiet "11b: the siri PASS must print nothing on stderr"

# 11c. Key absent (never enabled — defaults exits 1 with a stderr line) → PASS,
#     and that stderr line must not leak through the doctor.
: > "$WORK/defaults.out"
out="$(run_doctor)"; l="$(row siri "$out")"
has "PASS" "$l" "11c: a missing Assistant Enabled key must PASS (never enabled)"
has "never enabled" "$l" "11c: the PASS must say the key is absent, not claim it read 0"
quiet "11c: the missing-key run must print nothing on stderr"

# 11d. Silenced → no row, from the env and from fleet.settings.
echo 1 > "$WORK/defaults.out"
none "$(row siri "$(FLEET_DOCTOR_SIRI=0 run_doctor)")" "11d: FLEET_DOCTOR_SIRI=0 (env) must drop the row"
echo 'FLEET_DOCTOR_SIRI=0' > "$WORK/conf/fleet.settings"
none "$(row siri "$(run_doctor)")" "11d-b: FLEET_DOCTOR_SIRI=0 in fleet.settings must drop the row"
rm -f "$WORK/conf/fleet.settings"
: > "$WORK/defaults.out"

# ============================================================================
# icloud (issue #1076)
# ============================================================================
# 12. Sync daemons alive → INFO naming WHICH ones (a partial sign-out reads as
#    progress), where to sign out, the doc and the silencer.
: > "$WORK/pgrep.argv"
printf 'bird\nfileproviderd\n' > "$WORK/pgrep.live"
out="$(run_doctor)"; l="$(row icloud "$out")"
has "INFO" "$l" "12: a live iCloud daemon must be INFO"
has " bird" "$l" "12: the INFO must name bird"
has " fileproviderd" "$l" "12: the INFO must name fileproviderd"
case "$l" in *cloudd*) fail "12: the INFO must not name a daemon that is not running (cloudd)" "$l";; esac
has "iCloud" "$l" "12: the INFO must say where to sign out"
has "docs/HOST.md#headless" "$l" "12: the INFO must point at the host doc"
has "FLEET_DOCTOR_ICLOUD=0" "$l" "12: the INFO must say how to silence it (EPIC rule 9)"
for d in bird cloudd fileproviderd; do
  has "$d" "$(cat "$WORK/pgrep.argv" 2>/dev/null)" "12: the doctor must probe $d"
done
survived "$out" || fail "12: the doctor did not reach its last check" "$l"
quiet "12: the icloud INFO must print nothing on stderr"

# 12b. None alive → PASS.
: > "$WORK/pgrep.live"
out="$(run_doctor)"; l="$(row icloud "$out")"
has "PASS" "$l" "12b: no iCloud daemon must PASS"
quiet "12b: the icloud PASS must print nothing on stderr"

# 12c. Silenced → no row, from the env and from fleet.settings.
printf 'cloudd\n' > "$WORK/pgrep.live"
none "$(row icloud "$(FLEET_DOCTOR_ICLOUD=0 run_doctor)")" "12c: FLEET_DOCTOR_ICLOUD=0 (env) must drop the row"
echo 'FLEET_DOCTOR_ICLOUD=0' > "$WORK/conf/fleet.settings"
none "$(row icloud "$(run_doctor)")" "12c-b: FLEET_DOCTOR_ICLOUD=0 in fleet.settings must drop the row"
rm -f "$WORK/conf/fleet.settings"

# ============================================================================
# network (issue #1081)
# ============================================================================
# 13. Wired + Wi-Fi on one subnet: two default routes to one gateway → WARN naming
#    the gateway, both interfaces, the Wi-Fi switch-off (its device read off
#    networksetup), the undo, the doc and the silencer. Read-only tool use.
: > "$WORK/netstat.argv"; : > "$WORK/networksetup.argv"
printf 'Internet:\nDestination        Gateway            Flags               Netif Expire\ndefault            192.168.1.254      UGScg                 en0       \ndefault            192.168.1.254      UGScIg                en1       \ndefault            link#26            UCSIg           bridge100      !\n' > "$WORK/netstat.out"
out="$(run_doctor)"; l="$(row network "$out")"
has "WARN" "$l" "13: one gateway through two interfaces must WARN"
has "192.168.1.254" "$l" "13: the WARN must name the gateway"
has "en0 + en1" "$l" "13: the WARN must name both interfaces"
has "networksetup -setairportpower en1 off" "$l" "13: the WARN must name the Wi-Fi switch-off, on the Wi-Fi device"
has "networksetup -setairportpower en1 on" "$l" "13: the WARN must say how to undo it"
has "docs/HOST.md#network" "$l" "13: the WARN must point at the host doc"
has "FLEET_DOCTOR_NETWORK=0" "$l" "13: the WARN must say how to silence it (EPIC rule 9)"
case "$l" in *bridge100*|*link#*) fail "13: an interface-only (link#) default must not be counted" "$l";; esac
has "-rn -f inet" "$(cat "$WORK/netstat.argv" 2>/dev/null)" "13: the doctor must READ the routing table"
case "$(cat "$WORK/networksetup.argv")" in *-set*) fail "13: the doctor ran a state-changing networksetup" "$(cat "$WORK/networksetup.argv")";; esac
survived "$out" || fail "13: the doctor did not reach its last check" "$l"
quiet "13: the network WARN must print nothing on stderr"

# 13b. One default route (plus a link# bridge) → PASS naming it.
nsone
out="$(run_doctor)"; l="$(row network "$out")"
has "PASS" "$l" "13b: one default route must PASS"
has "192.168.1.254 via en0" "$l" "13b: the PASS must name the route"
case "$l" in *bridge100*) fail "13b: the link# bridge must not be listed" "$l";; esac
quiet "13b: the network PASS must print nothing on stderr"

# 13c. Two defaults to DIFFERENT gateways (two networks, deliberate failover) → PASS:
#     the signature is one gateway through two links, not two routes.
printf 'Internet:\nDestination        Gateway            Flags               Netif Expire\ndefault            192.168.1.254      UGScg                 en0       \ndefault            10.0.0.1           UGScIg                en1       \n' > "$WORK/netstat.out"
l="$(row network "$(run_doctor)")"
has "PASS" "$l" "13c: two defaults to different gateways must PASS"

# 13d. Same gateway through two wired links, no Wi-Fi among them → WARN without a
#     Wi-Fi command (never name a switch-off for an interface that is not Wi-Fi).
printf 'Internet:\nDestination        Gateway            Flags               Netif Expire\ndefault            192.168.1.254      UGScg                 en0       \ndefault            192.168.1.254      UGScIg                en4       \n' > "$WORK/netstat.out"
l="$(row network "$(run_doctor)")"
has "WARN" "$l" "13d: two wired links to one gateway must WARN"
has "keep only one of them" "$l" "13d: with no Wi-Fi among them the WARN must give the generic fix"
case "$l" in *setairportpower*) fail "13d: must not name a Wi-Fi switch-off for wired links" "$l";; esac

# 13e. No gateway route at all (offline, or only link#) → no row, never a guess.
printf 'Internet:\nDestination        Gateway            Flags               Netif Expire\ndefault            link#26            UCSIg           bridge100      !\n' > "$WORK/netstat.out"
none "$(row network "$(run_doctor)")" "13e: no gateway route must print no network row"

# 13f. Silenced → no row, from the env and from fleet.settings.
printf 'Internet:\ndefault            192.168.1.254      UGScg                 en0       \ndefault            192.168.1.254      UGScIg                en1       \n' > "$WORK/netstat.out"
none "$(row network "$(FLEET_DOCTOR_NETWORK=0 run_doctor)")" "13f: FLEET_DOCTOR_NETWORK=0 (env) must drop the row"
echo 'FLEET_DOCTOR_NETWORK=0' > "$WORK/conf/fleet.settings"
none "$(row network "$(run_doctor)")" "13f-b: FLEET_DOCTOR_NETWORK=0 in fleet.settings must drop the row"
rm -f "$WORK/conf/fleet.settings"
nsone

# ============================================================================
# 6. Linux: the whole section is silent — no spotlight, no wtroot, no nofile, no sleep, no
#    siri, no icloud, no error — and none of the macOS tools is even called.
# ============================================================================
echo Linux > "$WORK/os"; : > "$WORK/mdutil.argv"; : > "$WORK/pmset.argv"; : > "$WORK/defaults.argv"; : > "$WORK/pgrep.argv"
printf '/System/Volumes/Data:\n\tIndexing enabled. \n' > "$WORK/mdutil.out"
printf ' sleep                10\n' > "$WORK/pmset.out"; echo 1 > "$WORK/defaults.out"; printf 'bird\n' > "$WORK/pgrep.live"
out="$(run_doctor)"
none "$(row spotlight "$out")" "6: Linux must print no spotlight row"
none "$(row wtroot "$out")" "6: Linux must print no wtroot row"
none "$(row nofile "$out")" "6: Linux must print no nofile row"
none "$(row sleep "$out")" "6: Linux must print no sleep row"
none "$(row siri "$out")" "6: Linux must print no siri row"
none "$(row icloud "$out")" "6: Linux must print no icloud row"
none "$(cat "$WORK/mdutil.argv")" "6: Linux must not even call mdutil"
none "$(cat "$WORK/pmset.argv")" "6: Linux must not even call pmset"
none "$(cat "$WORK/defaults.argv")" "6: Linux must not even call defaults"
none "$(cat "$WORK/pgrep.argv")" "6: Linux must not probe the iCloud daemons"
survived "$out" || fail "6: the doctor did not reach its last check on Linux" ""
quiet "6: the Linux run must print nothing on stderr"

# 14. network on Linux (issue #1081): the one host row that renders there, off
#     `ip -4 route show default` — never netstat.
: > "$WORK/netstat.argv"; : > "$WORK/ip.argv"
printf 'default via 192.168.1.1 dev eth0 proto dhcp metric 100\ndefault via 192.168.1.1 dev wlan0 proto dhcp metric 600\n' > "$WORK/ip.out"
out="$(run_doctor)"; l="$(row network "$out")"
has "WARN" "$l" "14: Linux wired + Wi-Fi to one gateway must WARN"
has "eth0 + wlan0" "$l" "14: the WARN must name both interfaces"
has "nmcli radio wifi off" "$l" "14: the Linux WARN must name the nmcli switch-off"
has "route show default" "$(cat "$WORK/ip.argv" 2>/dev/null)" "14: Linux must read ip route"
none "$(cat "$WORK/netstat.argv")" "14: Linux must not call netstat"
quiet "14: the Linux network WARN must print nothing on stderr"
printf 'default via 10.0.0.1 dev eth0 proto dhcp src 10.0.0.5 metric 100\n' > "$WORK/ip.out"
l="$(row network "$(run_doctor)")"
has "PASS" "$l" "14b: one Linux default route must PASS"
has "10.0.0.1 via eth0" "$l" "14b: the PASS must name the route"

printf 'fleet-doctor-host-selftest: PASS (%d checks)\n' "$CHECKS"
