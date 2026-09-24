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
# Hermetic: fake uname/mdutil/launchctl on PATH, scratch HOME/TMPDIR/conf. Exit 0 = pass.
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
# 6. Linux: the whole section is silent — no spotlight, no wtroot, no error.
# ============================================================================
echo Linux > "$WORK/os"; : > "$WORK/mdutil.argv"
out="$(run_doctor)"
none "$(row spotlight "$out")" "6: Linux must print no spotlight row"
none "$(row wtroot "$out")" "6: Linux must print no wtroot row"
none "$(row nofile "$out")" "6: Linux must print no nofile row"
none "$(cat "$WORK/mdutil.argv")" "6: Linux must not even call mdutil"
survived "$out" || fail "6: the doctor did not reach its last check on Linux" ""
quiet "6: the Linux run must print nothing on stderr"

printf 'fleet-doctor-host-selftest: PASS (%d checks)\n' "$CHECKS"
