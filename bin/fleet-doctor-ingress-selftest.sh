#!/bin/bash
# fleet-doctor-ingress-selftest.sh — the `ingress` row of bin/fleet-doctor.sh
# (issue #1196, EPIC #1212): with FLEET_SSH_PUBLIC_HOST/PORT + FLEET_SSH_PROBE_HOST
# set, a probe host on the far side of the internet `ssh-keyscan`s the public
# entry and the doctor compares that ed25519 host key with sshd's on 127.0.0.1.
#
# Pinned:
#   - no row while either key is unset, and no ssh is ever run then;
#   - PASS on a matching key, naming the entry, the probe and "THIS host";
#   - WARN — never FAIL — for each way it can go wrong, each naming the cause:
#     a different key (another machine), an empty scan (entry closed), a probe
#     that cannot be reached (ssh exit 255), no local sshd, a bad port;
#   - every ssh/keyscan is BOUNDED: a probe that hangs ends in a WARN inside the
#     cap, and the doctor still reaches its last check with nothing on stderr;
#   - the verdict is cached (global/ingress.probe): a PASS is reused inside
#     FLEET_INGRESS_TTL without running ssh, a WARN too; TTL=0 or a changed
#     entry/probe re-probes;
#   - the keys resolve from fleet.settings as well as the environment;
#   - FLEET_DOCTOR_INGRESS=0 drops the row; the row renders on Linux too.
#
# Hermetic: fake ssh / ssh-keyscan / uname on PATH, scratch HOME/TMPDIR/conf.
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-doctor.sh fleet-daemon-lib.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-ingress-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf/fleets/tfleet"
for f in fleet-doctor.sh fleet-diskguard.sh fleet-lib.sh fleet-daemon-lib.sh fleet-daemon-loaded.sh; do
  [ -f "$BIN/$f" ] && cp "$BIN/$f" "$WORK/bin/"
done
chmod +x "$WORK/bin/"*.sh
printf 'FLEET_REPO="o/r"\n' > "$WORK/conf/fleets/tfleet/conf"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- line ---\n%s\n' "${2:-(none)}" >&2; exit 1; }
has()  { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) ;; *) fail "$3" "$2";; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) fail "$3" "$2";; esac; }
none() { CHECKS=$((CHECKS + 1)); [ -z "$1" ] || fail "$2" "$1"; }

# --- fake uname: the row is cross-platform; the OS is switchable.
echo Darwin > "$WORK/os"
cat > "$WORK/fakepath/uname" <<SH
#!/bin/sh
[ "\$1" = -s ] && { cat "$WORK/os"; exit 0; }
exec /usr/bin/uname "\$@"
SH
# --- fake ssh: records argv; `out` mode prints the remote fixture and exits with
# the fixture rc (the remote command's, or 255 for ssh's own failure); `hang`
# mode never answers — exec'd, so the doctor's deadline lands on the sleeper.
cat > "$WORK/fakepath/ssh" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/ssh.argv"
case "\$(cat "$WORK/ssh.mode")" in
  hang) exec sleep 60 ;;
  *) cat "$WORK/remote.out"; exit "\$(cat "$WORK/ssh.rc")" ;;
esac
SH
# --- fake ssh-keyscan (the LOCAL scan): records argv, prints the fixture.
cat > "$WORK/fakepath/ssh-keyscan" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/keyscan.argv"
cat "$WORK/local.out"
SH
chmod +x "$WORK/fakepath/uname" "$WORK/fakepath/ssh" "$WORK/fakepath/ssh-keyscan"

KEY_A='AAAAC3NzaC1lZDI1NTE5AAAAIBXhuOVXx5vzpKxnA40jlfLiZs0TpIdZ79oV13q2HqYr'
KEY_B='AAAAC3NzaC1lZDI1NTE5AAAAIOtherMachineOtherMachineOtherMachineOtherMach'
reset() {
  : > "$WORK/ssh.argv"; : > "$WORK/keyscan.argv"; echo out > "$WORK/ssh.mode"; echo 0 > "$WORK/ssh.rc"
  printf '127.0.0.1 ssh-ed25519 %s\n' "$KEY_A" > "$WORK/local.out"
  printf '# pub.example.test:22022 SSH-2.0-OpenSSH_10.3\n[pub.example.test]:22022 ssh-ed25519 %s\n' "$KEY_A" > "$WORK/remote.out"
  rm -f "$WORK/conf/global/ingress.probe" "$WORK/conf/fleet.settings"
}
run_doctor() {   # extra env as args
  : > "$WORK/stderr"
  env PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
    FLEET_CONF_DIR="$WORK/conf" "$@" sh "$WORK/bin/fleet-doctor.sh" 2>"$WORK/stderr"
}
CONF=(FLEET_SSH_PUBLIC_HOST=pub.example.test FLEET_SSH_PUBLIC_PORT=22022 FLEET_SSH_PROBE_HOST=probe.example.test)
row() { printf '%s\n' "$2" | grep -aE "^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+$1([[:space:]]|\$)" | head -1; }
survived() { printf '%s\n' "$1" | grep -qaE '^[[:space:]]+(PASS|WARN)[[:space:]]+perl'; }
quiet() { CHECKS=$((CHECKS + 1)); [ -s "$WORK/stderr" ] && fail "$1" "$(cat "$WORK/stderr")"; return 0; }

# 1. Nothing configured → no row, and ssh is never run. Host alone / probe alone too.
reset
out="$(run_doctor)"
none "$(row ingress "$out")" "1: unconfigured must print no ingress row"
none "$(cat "$WORK/ssh.argv")" "1: unconfigured must not run ssh"
survived "$out" || fail "1: the doctor did not reach its last check" ""
quiet "1: nothing on stderr"
none "$(row ingress "$(run_doctor FLEET_SSH_PUBLIC_HOST=pub.example.test)")" "1b: host without a probe must print no row"
none "$(row ingress "$(run_doctor FLEET_SSH_PROBE_HOST=probe.example.test)")" "1c: probe without a host must print no row"
none "$(cat "$WORK/ssh.argv")" "1b/1c: half-configured must not run ssh"

# 2. Matching key → PASS naming entry, probe, THIS host; bounded, batch-mode ssh
#    that keyscans the entry; the local scan on 127.0.0.1.
reset
out="$(run_doctor "${CONF[@]}")"; l="$(row ingress "$out")"
has "PASS" "$l" "2: a matching host key must PASS"
has "pub.example.test:22022" "$l" "2: the PASS must name the entry"
has "from probe.example.test" "$l" "2: the PASS must name the probe host"
has "THIS host" "$l" "2: the PASS must say the entry lands on this host"
has "ssh -p 22022 <login>@pub.example.test" "$l" "2: the PASS must show what a newcomer types"
a="$(cat "$WORK/ssh.argv")"
has "-o BatchMode=yes" "$a" "2: ssh must run in BatchMode (never a prompt)"
has "-o ConnectTimeout=20" "$a" "2: ssh must carry the default 20s ConnectTimeout"
has "probe.example.test" "$a" "2: ssh must go to the probe host"
has "ssh-keyscan -t ed25519 -T 20 -p 22022 pub.example.test" "$a" "2: the remote command must keyscan the entry on its port"
has "127.0.0.1" "$(cat "$WORK/keyscan.argv")" "2: the local scan must read sshd on 127.0.0.1"
hasnt "cached" "$l" "2: a fresh probe must not claim a cache"
survived "$out" || fail "2: the doctor did not reach its last check" "$l"
quiet "2: the PASS must print nothing on stderr"
[ -f "$WORK/conf/global/ingress.probe" ] || fail "2: the verdict must be cached in global/ingress.probe" ""
has "pub.example.test:22022@probe.example.test pass" "$(sed -n 1p "$WORK/conf/global/ingress.probe")" "2: the cache line carries entry@probe + verdict"

# 3. Cache: a second run inside the TTL reuses the PASS and runs NO ssh; TTL=0
#    re-probes; a changed port is a different entry and re-probes.
: > "$WORK/ssh.argv"; : > "$WORK/keyscan.argv"
out="$(run_doctor "${CONF[@]}")"; l="$(row ingress "$out")"
has "PASS" "$l" "3: the cached verdict must still PASS"
has "cached" "$l" "3: the row must say it is cached"
has "FLEET_INGRESS_TTL=0 re-probes" "$l" "3: the row must say how to re-probe"
none "$(cat "$WORK/ssh.argv")" "3: a cached verdict must not run ssh"
none "$(cat "$WORK/keyscan.argv")" "3: a cached verdict must not run ssh-keyscan"
quiet "3: the cached PASS must print nothing on stderr"
l="$(row ingress "$(run_doctor "${CONF[@]}" FLEET_INGRESS_TTL=0)")"
has "PASS" "$l" "3b: TTL=0 must still PASS"
hasnt "cached" "$l" "3b: TTL=0 must re-probe, not read the cache"
has "probe.example.test" "$(cat "$WORK/ssh.argv")" "3b: TTL=0 must run ssh again"
: > "$WORK/ssh.argv"
printf '# pub.example.test:2200 SSH-2.0-OpenSSH_10.3\n[pub.example.test]:2200 ssh-ed25519 %s\n' "$KEY_A" > "$WORK/remote.out"
l="$(row ingress "$(run_doctor "${CONF[@]}" FLEET_SSH_PUBLIC_PORT=2200)")"
hasnt "cached" "$l" "3c: a different port is a different entry — must re-probe"
has "-p 2200 pub.example.test" "$(cat "$WORK/ssh.argv")" "3c: the re-probe must scan the new port"
has "pub.example.test:2200" "$l" "3c: the row must name the new port"

# 4. A DIFFERENT key → WARN: the entry lands on another machine. Names the
#    cause, the fix's doc anchor and the silencer; counted as a warn; cached as a
#    warn (reused on the next run, without ssh).
reset
printf '[pub.example.test]:22022 ssh-ed25519 %s\n' "$KEY_B" > "$WORK/remote.out"
out="$(run_doctor "${CONF[@]}")"; l="$(row ingress "$out")"
has "WARN" "$l" "4: a different host key must WARN"
has "DIFFERENT host key" "$l" "4: the WARN must say the key differs"
has "ANOTHER machine" "$l" "4: the WARN must say the entry lands elsewhere"
has "docs/HOST.md#ingress" "$l" "4: the WARN must point at the host doc"
has "FLEET_DOCTOR_INGRESS=0" "$l" "4: the WARN must say how to silence it"
hasnt "FAIL" "$l" "4: never a FAIL — a network condition, not a broken install"
survived "$out" || fail "4: the doctor did not reach its last check" "$l"
quiet "4: the WARN must print nothing on stderr"
has "pub.example.test:22022@probe.example.test warn" "$(sed -n 1p "$WORK/conf/global/ingress.probe")" "4: a WARN is cached too"
: > "$WORK/ssh.argv"
l="$(row ingress "$(run_doctor "${CONF[@]}")")"
has "WARN" "$l" "4b: the cached WARN is reused"
has "cached" "$l" "4b: and says so"
none "$(cat "$WORK/ssh.argv")" "4b: without running ssh"

# 5. Entry closed: the remote keyscan prints nothing and exits 1 → WARN naming
#    the entry as NOT reachable, with what a newcomer would type.
reset
: > "$WORK/remote.out"; echo 1 > "$WORK/ssh.rc"
out="$(run_doctor "${CONF[@]}")"; l="$(row ingress "$out")"
has "WARN" "$l" "5: an empty scan must WARN"
has "NOT reachable from probe.example.test" "$l" "5: the WARN must say the entry is not reachable from the probe"
has "ssh -p 22022 <login>@pub.example.test" "$l" "5: the WARN must show what will not connect"
has "port 22022" "$l" "5: the WARN must name the port to check on the router"
quiet "5: the WARN must print nothing on stderr"
# 5b. keyscan's own reason (stderr merged on the remote) is quoted.
printf 'connect to host pub.example.test port 22022: Connection refused\n' > "$WORK/remote.out"
l="$(row ingress "$(run_doctor "${CONF[@]}" FLEET_INGRESS_TTL=0)")"
has "Connection refused" "$l" "5b: the WARN must quote keyscan's reason"

# 6. The PROBE itself cannot be reached (ssh exit 255) → WARN that names the
#    probe and the reason, and says nothing about the entry either way.
reset
printf 'ssh: connect to host probe.example.test port 22: Connection refused\n' > "$WORK/remote.out"; echo 255 > "$WORK/ssh.rc"
out="$(run_doctor "${CONF[@]}")"; l="$(row ingress "$out")"
has "WARN" "$l" "6: an unreachable probe must WARN"
has "probe host probe.example.test unreachable" "$l" "6: the WARN must name the probe as the problem"
has "Connection refused" "$l" "6: the WARN must quote ssh's reason"
has "FLEET_SSH_PROBE_HOST" "$l" "6: the WARN must name the key that picks the probe"
hasnt "NOT reachable" "$l" "6: an unreachable probe must not be reported as a closed entry"
quiet "6: the WARN must print nothing on stderr"
# 6b. Host key verification failed (BatchMode refuses an unknown probe key).
printf 'Host key verification failed.\n' > "$WORK/remote.out"
l="$(row ingress "$(run_doctor "${CONF[@]}" FLEET_INGRESS_TTL=0)")"
has "Host key verification failed" "$l" "6b: the WARN must quote the host-key refusal"

# 7. No sshd answering on 127.0.0.1 (local scan empty) while the entry answers →
#    WARN: cannot tell whether it is this host; names Remote Login.
reset
: > "$WORK/local.out"
out="$(run_doctor "${CONF[@]}")"; l="$(row ingress "$out")"
has "WARN" "$l" "7: no local sshd must WARN"
has "no sshd answers on 127.0.0.1" "$l" "7: the WARN must name the local side"
has "Remote Login" "$l" "7: the WARN must name Remote Login"
has "-p 22022 127.0.0.1" "$(cat "$WORK/keyscan.argv")" "7: with 22 silent, the local scan must also try the public port"
quiet "7: the WARN must print nothing on stderr"

# 8. A probe that HANGS: bounded. FLEET_INGRESS_TIMEOUT=1 caps the whole probe at
#    2×1+10 = 12s; the fake ssh would sleep 60. The run must end well inside that,
#    WARN "timed out", reach the last check, and print nothing on stderr (a
#    signalled child would make bash say "Alarm clock").
reset
echo hang > "$WORK/ssh.mode"
t0=$(date +%s); out="$(run_doctor "${CONF[@]}" FLEET_INGRESS_TIMEOUT=1)"; t1=$(date +%s); l="$(row ingress "$out")"
has "WARN" "$l" "8: a hung probe must WARN"
has "timed out after 12s" "$l" "8: the WARN must say it timed out, and after how long"
[ $((t1 - t0)) -lt 45 ] || fail "8: the doctor must not wait for a hung probe (took $((t1 - t0))s)" "$l"
survived "$out" || fail "8: the doctor did not reach its last check after a timeout" "$l"
quiet "8: a timeout must print nothing on stderr"

# 9. Silenced → no row, no ssh — from the env and from fleet.settings.
reset
out="$(run_doctor "${CONF[@]}" FLEET_DOCTOR_INGRESS=0)"
none "$(row ingress "$out")" "9: FLEET_DOCTOR_INGRESS=0 must print no row"
none "$(cat "$WORK/ssh.argv")" "9: silenced must not run ssh"
printf 'FLEET_DOCTOR_INGRESS=0\n' > "$WORK/conf/fleet.settings"
none "$(row ingress "$(run_doctor "${CONF[@]}")")" "9b: FLEET_DOCTOR_INGRESS=0 in fleet.settings must print no row"

# 10. The three keys from fleet.settings (no env) → the row renders and probes
#     that entry; a bad port there is named, never scanned.
reset
printf 'FLEET_SSH_PUBLIC_HOST=mini.example.test\nFLEET_SSH_PUBLIC_PORT="22022"\nFLEET_SSH_PROBE_HOST=hk\n' > "$WORK/conf/fleet.settings"
printf '[mini.example.test]:22022 ssh-ed25519 %s\n' "$KEY_A" > "$WORK/remote.out"
out="$(run_doctor)"; l="$(row ingress "$out")"
has "PASS" "$l" "10: keys from fleet.settings must render the row"
has "mini.example.test:22022" "$l" "10: the row must name the settings' entry"
has "from hk" "$l" "10: the row must name the settings' probe"
has " hk " "$(cat "$WORK/ssh.argv")" "10: ssh must go to the settings' probe"
: > "$WORK/ssh.argv"
l="$(row ingress "$(run_doctor "${CONF[@]}" FLEET_SSH_PUBLIC_PORT=abc)")"
has "WARN" "$l" "10b: a non-numeric port must WARN"
has "not a port number: 'abc'" "$l" "10b: the WARN must name the bad value"
none "$(cat "$WORK/ssh.argv")" "10b: a bad port must not be scanned"

# 11. Linux: the row is cross-platform, and stray ssh chatter around the key
#     line ("Warning: Permanently added …") does not spoil a match.
reset
echo Linux > "$WORK/os"
printf 'Warning: Permanently added probe.example.test (ED25519) to the list of known hosts.\n# pub.example.test:22022 SSH-2.0-OpenSSH_9.6\n[pub.example.test]:22022 ssh-ed25519 %s\n' "$KEY_A" > "$WORK/remote.out"
out="$(run_doctor "${CONF[@]}")"; l="$(row ingress "$out")"
has "PASS" "$l" "11: the row must render on Linux, and a matching key beside ssh chatter must PASS"
survived "$out" || fail "11: the doctor did not reach its last check on Linux" "$l"
quiet "11: the Linux PASS must print nothing on stderr"

printf 'fleet-doctor-ingress-selftest: PASS (%d checks)\n' "$CHECKS"
