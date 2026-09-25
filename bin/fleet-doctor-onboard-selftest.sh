#!/bin/bash
# Isolated readiness matrix: each missing enrollment step must be named in the
# single WARN row, while an old login must not acquire the row at all.
set -uo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/doctor-onboard-selftest.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/launchd" "$WORK/shim" "$WORK/core" "$WORK/home/.ssh" "$WORK/conf/global" "$WORK/conf/fleets/fleet" "$WORK/accounts"
cp "$BIN/fleet-doctor-onboard.sh" "$BIN/fleet-lib.sh" "$WORK/bin/"
touch "$WORK/launchd/com.claude-fleet.collect.plist.tmpl" "$WORK/launchd/com.claude-fleet.spinner.plist.tmpl"
for cmd in awk find id dirname; do ln -s "$(command -v "$cmd")" "$WORK/core/$cmd"; done

cat > "$WORK/shim/gh" <<'EOF'
#!/bin/sh
[ "${TEST_GH:-good}" = good ]
EOF
cat > "$WORK/shim/ccquota" <<'EOF'
#!/bin/sh
[ "$1 $2" = 'codex list' ] || exit 1
[ "${TEST_CODEX:-valid}" = error ] && exit 1
printf 'PROFILE DEFAULT EMAIL PLAN LOGIN DIRECTORY\n'
printf 'personal * user@example.com pro %s /home/test\n' "${TEST_CODEX:-valid}"
EOF
cat > "$WORK/shim/launchctl" <<'EOF'
#!/bin/sh
[ "$1" = print ] || exit 1
case "${TEST_DAEMON:-both}" in
  both) case "$2" in *collect|*spinner) exit 0;; esac ;;
  system) case "$2" in system/*collect|system/*spinner) exit 0;; esac ;;
  gui) case "$2" in gui/*collect|gui/*spinner) exit 0;; esac ;;
  missing) case "$2" in *collect) exit 0;; esac ;;
esac
exit 1
EOF
cat > "$WORK/shim/tmux" <<'EOF'
#!/bin/sh
[ "${TEST_GUIDE:-dead}" = live ] && printf 'guide|1|claude|123\n'
exit 0
EOF
cat > "$WORK/shim/claude" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/shim/"*
printf 'token\n' > "$WORK/accounts/one"; chmod 600 "$WORK/accounts/one"
printf 'ssh-ed25519 AAAA normal-key\n' > "$WORK/home/.ssh/authorized_keys"
printf 'FLEET_REPO=x/y\n' > "$WORK/conf/fleets/fleet/conf"
touch "$WORK/conf/global/onboarded"

fail() { printf 'selftest FAIL: %s (got: %s)\n' "$1" "${out:-}" >&2; exit 1; }
checks=0
probe() {
  out=$(HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_ACCOUNTS_DIR="$WORK/accounts" \
    PATH="$WORK/shim:$WORK/core" /usr/bin/env "$@" /bin/bash "$WORK/bin/fleet-doctor-onboard.sh" 2>"$WORK/err")
  rc=$?
  [ ! -s "$WORK/err" ] || fail "unexpected stderr: $(cat "$WORK/err")"
}
ready() { probe "$@"; [ "$rc" = 0 ] && [[ "$out" = ready:* ]] || fail 'expected ready'; checks=$((checks+1)); }
needs() { local needle=$1; shift; probe "$@"; [ "$rc" = 1 ] && [[ "$out" == *"$needle"* ]] || fail "missing $needle"; checks=$((checks+1)); }

ready
mv "$WORK/shim/claude" "$WORK/claude"; needs 'Claude CLI'; mv "$WORK/claude" "$WORK/shim/claude"
needs 'GitHub login' TEST_GH=missing
needs 'Codex LOGIN valid' TEST_CODEX=invalid
needs 'Codex LOGIN valid' TEST_CODEX=error
needs 'daemon spinner' TEST_DAEMON=missing
ready TEST_DAEMON=system
ready TEST_DAEMON=gui
chmod 644 "$WORK/accounts/one"; needs 'Claude accounts'; chmod 600 "$WORK/accounts/one"
: > "$WORK/accounts/one"; needs 'Claude accounts'; printf 'token\n' > "$WORK/accounts/one"
mv "$WORK/accounts/one" "$WORK/token"; needs 'Claude accounts'; mv "$WORK/token" "$WORK/accounts/one"
mv "$WORK/home/.ssh/authorized_keys" "$WORK/key"; needs 'SSH authorized_keys'; mv "$WORK/key" "$WORK/home/.ssh/authorized_keys"
printf 'ssh-ed25519 AAAA temporary-key\n' > "$WORK/home/.ssh/authorized_keys"
needs 'replace temporary SSH key'
printf 'ssh-ed25519 AAAA normal-key\n' > "$WORK/home/.ssh/authorized_keys"
rm "$WORK/conf/global/onboarded"
needs 'onboarding guide'
# A running guide that never spoke (no guide.spoke — `Unknown command`, #1215)
# is not a guide; one that spoke and is still running is; one that spoke and
# then died is not (only onboarded survives the guide closing).
needs 'onboarding guide' TEST_GUIDE=live
touch "$WORK/conf/global/guide.spoke"
ready TEST_GUIDE=live
needs 'onboarding guide'
rm "$WORK/conf/global/guide.spoke"
touch "$WORK/conf/global/onboarded"

# Exercise the real doctor dispatch as well as the helper: enrollment controls
# whether the row exists, and a missing step adds WARN without adding FAIL.
cp "$BIN/fleet-doctor.sh" "$BIN/fleet-daemon-lib.sh" "$WORK/bin/"
touch "$WORK/conf/global/bootstrapped"
doctor() {
  HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_ACCOUNTS_DIR="$WORK/accounts" \
    FLEET_SKIP_GLOBAL_CONF=1 PATH="$WORK/shim:$PATH" \
    /bin/sh "$WORK/bin/fleet-doctor.sh" > "$WORK/doctor.out" 2> "$WORK/doctor.err"
  doctor_rc=$?
}
doctor
grep -Eq '^[[:space:]]+PASS[[:space:]]+onboard[[:space:]]+ready:' "$WORK/doctor.out" || fail 'doctor did not print ready row'
ready_rc=$doctor_rc
checks=$((checks+1))
TEST_GH=missing doctor
grep -Eq '^[[:space:]]+WARN[[:space:]]+onboard[[:space:]]+needs:.*GitHub login' "$WORK/doctor.out" || fail 'doctor did not print named WARN'
[ "$doctor_rc" = "$ready_rc" ] || fail 'onboard WARN changed doctor FAIL exit code'
checks=$((checks+1))
rm "$WORK/conf/global/bootstrapped"
doctor
! grep -Eq '^[[:space:]]+(PASS|WARN|FAIL)[[:space:]]+onboard[[:space:]]' "$WORK/doctor.out" || fail 'old login acquired onboard row'
checks=$((checks+1))
printf 'fleet-doctor-onboard-selftest: %d checks passed\n' "$checks"
