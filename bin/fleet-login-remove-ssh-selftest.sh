#!/bin/bash
# fleet-login-remove-ssh-selftest.sh — the local ssh road for deleting a login
# (issue #2994), with PATH shims only: no real account, sshd, directory service
# or authorized_keys is touched. Drives bin/fleet-login-remove-ssh.sh:
#   A  forced: anything but `probe` / `delete <plain login>` is refused, and so
#      is a system account, the admin itself, an admin-group login, a missing one
#   B  forced: an sshd session with no Full Disk Access says so (exit 7), deletes nothing
#   C  forced: a delete takes the record and the login's access-group entries
#   D  setup: one authorized_keys line (from= loopback, restrict, the forced
#      command quoted), the admin's other lines kept, idempotent, a stale line replaced
#   E  run: Remote Login off / the key refused / no key ⇒ exit 5 with the reason;
#      the round trip through `forced` deletes, and passes exit 7 on
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
S="$BIN/fleet-login-remove-ssh.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/login-remove-ssh-selftest.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT INT TERM HUP
FAILS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }
has() { grep -Fq -- "$2" "$1" || { fail "$3"; sed 's/^/    | /' "$1" >&2; }; }
not_has() { ! grep -Fq -- "$2" "$1" || { fail "$3"; sed 's/^/    | /' "$1" >&2; }; }

mkdir -p "$WORK/shim" "$WORK/ds/groups" "$WORK/homes/admin1" "$WORK/hostkeys" "$WORK/tcc"
export PATH="$WORK/shim:$PATH" FLEET_TEST_LOG="$WORK/calls.log" FLEET_TEST_DS="$WORK/ds"
export FLEET_REMOVE_SSH_TEST=1 FLEET_REMOVE_SSH_DIR="$WORK/keydir" FLEET_REMOVE_SSH_HOMES="$WORK/homes" \
  FLEET_REMOVE_SSH_HOSTKEYS="$WORK/hostkeys" FLEET_REMOVE_SSH_FORCED="/Library/Application Support/claude-fleet/current/bin/fleet-login-remove-ssh.sh"
: > "$WORK/tcc/TCC.db"; export FLEET_LOGIN_REMOVE_TCC_DB="$WORK/tcc/TCC.db"
printf 'ssh-ed25519 AAAAHOSTKEY root@host\n' > "$WORK/hostkeys/ssh_host_ed25519_key.pub"

cat > "$WORK/shim/id" <<'EOF'
#!/bin/sh
case "$*" in
  -un) echo admin1 ;;
  '-u admin1') echo 501 ;;
  '-u alice') [ -e "$FLEET_TEST_DS/alice.gone" ] && exit 1; echo 602 ;;
  '-u bob') echo 603 ;;
  '-u daemon') echo 1 ;;
  '-Gn alice') echo staff everyone ;;
  '-Gn bob') echo 'staff admin' ;;
  '-Gn admin1') echo 'staff admin' ;;
  '-Gn daemon') echo daemon ;;
  *) exit 1 ;;
esac
EOF
cat > "$WORK/shim/sudo" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$FLEET_TEST_LOG"
[ "$1" = -n ] && shift
exec "$@"
EOF
cat > "$WORK/shim/sysadminctl" <<'EOF'
#!/bin/sh
printf 'sysadminctl %s\n' "$*" >> "$FLEET_TEST_LOG"
[ "${FAKE_RECORD_STAYS:-0}" = 1 ] || : > "$FLEET_TEST_DS/$2.gone"
EOF
cat > "$WORK/shim/dscl" <<'EOF'
#!/bin/sh
DS=$FLEET_TEST_DS
case "$2" in
  -list) ls "$DS/groups" ;;
  -read) case "$3" in
      /Users/alice) [ ! -e "$DS/alice.gone" ] || exit 56; [ "${4:-}" != GeneratedUID ] || echo 'GeneratedUID: GUID-ALICE' ;;
      /Users/*) exit 56 ;;
      /Groups/*) f="$DS/groups/${3#/Groups/}"; [ -f "$f" ] || exit 56; grep "^$4: " "$f" ;;
    esac ;;
  -delete) printf 'dscl %s\n' "$*" >> "$FLEET_TEST_LOG"
    case "$3" in /Users/*) [ "${FAKE_DSCL_DENIED:-0}" = 0 ] || exit 1; : > "$DS/${3#/Users/}.gone"; exit 0 ;; esac
    f="$DS/groups/${3#/Groups/}"
    awk -v a="$4:" -v v="$5" '$1 == a {o = $1; for (i = 2; i <= NF; i++) if ($i != v) o = o " " $i; print o; next} {print}' "$f" > "$f.t" && mv "$f.t" "$f" ;;
esac
exit 0
EOF
# ssh: FAKE_SSH=refused|denied answers as sshd would; else it plays sshd's part
# — the forced command, with what was asked as $SSH_ORIGINAL_COMMAND.
cat > "$WORK/shim/ssh" <<'EOF'
#!/bin/sh
printf 'ssh %s\n' "$*" >> "$FLEET_TEST_LOG"
case "${FAKE_SSH:-}" in
  refused) echo 'ssh: connect to host 127.0.0.1 port 22: Connection refused' >&2; exit 255 ;;
  denied) echo 'admin1@127.0.0.1: Permission denied (publickey,password,keyboard-interactive).' >&2; exit 255 ;;
esac
while [ $# -gt 0 ]; do case "$1" in -i|-o|-F) shift 2 ;; *@*) shift; break ;; *) shift ;; esac; done
SSH_ORIGINAL_COMMAND="$*" exec bash "$FLEET_TEST_SCRIPT" forced
EOF
chmod +x "$WORK/shim/"*
export FLEET_TEST_SCRIPT="$S"
reset_ds() {
  rm -f "$WORK/ds/"*.gone
  printf 'GroupMembership: admin1 alice bob\nGroupMembers: GUID-ADMIN1 GUID-ALICE GUID-BOB\n' > "$WORK/ds/groups/com.apple.access_ssh"
  : > "$FLEET_TEST_LOG"
}
forced() { SSH_ORIGINAL_COMMAND=$1 bash "$S" forced >"$WORK/out" 2>&1; RC=$?; }

# A — forced: the shapes and the logins it refuses
reset_ds
while IFS='|' read -r cmd want; do
  forced "$cmd"
  [ "$RC" = "$want" ] || { fail "forced '$cmd': exit $RC (want $want)"; sed 's/^/    | /' "$WORK/out" >&2; }
done <<'EOF'
|2
rm -rf /|2
bash|2
delete|2
delete alice bob|2
delete Alice|2
delete ../alice|2
delete alice;id|2
delete $(id)|2
delete `id`|2
delete -alice|2
probe alice|2
delete daemon|3
delete admin1|3
delete bob|3
delete nosuch|4
EOF
not_has "$FLEET_TEST_LOG" 'sysadminctl' 'A: a refused command reached sysadminctl'
not_has "$FLEET_TEST_LOG" 'dscl . -delete' 'A: a refused command reached dscl -delete'
forced probe; [ "$RC" = 0 ] || fail "A: probe with Full Disk Access: exit $RC (want 0)"

# B — forced: no Full Disk Access in the ssh session
reset_ds; chmod 000 "$WORK/tcc/TCC.db"
forced 'delete alice'
[ "$RC" = 7 ] || fail "B: delete with no Full Disk Access: exit $RC (want 7)"
has "$WORK/out" '允许远程用户完全磁盘访问' 'B: the Remote Login switch was not named'
not_has "$FLEET_TEST_LOG" 'sysadminctl' 'B: deleted with no Full Disk Access'
forced probe; [ "$RC" = 7 ] || fail "B: probe with no Full Disk Access: exit $RC (want 7)"
chmod 600 "$WORK/tcc/TCC.db"

# C — forced: a delete, the record surviving sysadminctl taken by dscl, the groups cleaned
reset_ds
FAKE_RECORD_STAYS=1 forced 'delete alice'
[ "$RC" = 0 ] || { fail "C: delete: exit $RC (want 0)"; sed 's/^/    | /' "$WORK/out" >&2; }
has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser alice' 'C: sysadminctl was not run'
has "$FLEET_TEST_LOG" 'dscl . -delete /Users/alice' 'C: the record left by sysadminctl was not deleted'
grep -q 'alice\|GUID-ALICE' "$WORK/ds/groups/com.apple.access_ssh" && fail 'C: alice left in com.apple.access_ssh'
grep -q 'GUID-BOB' "$WORK/ds/groups/com.apple.access_ssh" || fail 'C: bob was taken out of com.apple.access_ssh'
reset_ds
FAKE_RECORD_STAYS=1 FAKE_DSCL_DENIED=1 forced 'delete alice'
[ "$RC" = 1 ] || fail "C: a record that survives everything: exit $RC (want 1)"

# D — setup
if command -v ssh-keygen >/dev/null 2>&1; then
  AK="$WORK/homes/admin1/.ssh/authorized_keys"
  mkdir -p "$WORK/homes/admin1/.ssh"
  printf 'ssh-ed25519 AAAAOTHER me@laptop\nssh-ed25519 AAAASTALE fleet-login-remove-ssh\n' > "$AK"
  bash "$S" setup --admin admin1 >"$WORK/out" 2>&1 || { fail "D: setup failed"; sed 's/^/    | /' "$WORK/out" >&2; }
  [ -f "$WORK/keydir/id_ed25519" ] || fail 'D: no key made'
  [ "$(grep -c 'fleet-login-remove-ssh$' "$AK")" = 1 ] || fail 'D: not exactly one road line'
  has "$AK" 'me@laptop' "D: the admin's own key was lost"
  not_has "$AK" 'AAAASTALE' 'D: the stale road line was kept'
  has "$AK" "from=\"127.0.0.1,::1\",restrict,command=\"/bin/bash '/Library/Application Support/claude-fleet/current/bin/fleet-login-remove-ssh.sh' forced\" ssh-ed25519 " 'D: the road line is not loopback + restrict + the quoted forced command'
  has "$WORK/keydir/known_hosts" '127.0.0.1,::1 ssh-ed25519 AAAAHOSTKEY' 'D: known_hosts not from the host key'
  cp "$AK" "$WORK/ak.1"
  bash "$S" setup --admin admin1 >"$WORK/out" 2>&1 || fail 'D: second setup failed'
  cmp -s "$AK" "$WORK/ak.1" || fail 'D: a second setup changed authorized_keys'
  has "$WORK/out" 'ready' 'D: a second setup did not say ready'
  bash "$S" setup --admin 'x;y' >/dev/null 2>&1 && fail 'D: setup took a bad admin name'
else
  printf 'fleet-login-remove-ssh-selftest: SKIP D (no ssh-keygen)\n'
  mkdir -p "$WORK/keydir"; : > "$WORK/keydir/id_ed25519"; : > "$WORK/keydir/known_hosts"
fi

# E — run
reset_ds
FAKE_SSH=refused bash "$S" run alice --admin admin1 >"$WORK/out" 2>&1; RC=$?
[ "$RC" = 5 ] || fail "E: Remote Login off: exit $RC (want 5)"
has "$WORK/out" 'Remote Login is off' 'E: Remote Login off was not said'
FAKE_SSH=denied bash "$S" run alice --admin admin1 >"$WORK/out" 2>&1; RC=$?
[ "$RC" = 5 ] || fail "E: key refused: exit $RC (want 5)"
has "$WORK/out" 'did not take the key' 'E: the refused key was not said'
has "$WORK/out" 'setup --admin admin1' 'E: the refused key did not name the setup line'
bash "$S" run 'alice;id' --admin admin1 >/dev/null 2>&1; [ "$?" = 2 ] || fail 'E: run took a bad login'
chmod 000 "$WORK/tcc/TCC.db"
bash "$S" run alice --admin admin1 >"$WORK/out" 2>&1; RC=$?
chmod 600 "$WORK/tcc/TCC.db"
[ "$RC" = 7 ] || fail "E: round trip, no Full Disk Access: exit $RC (want 7)"
has "$WORK/out" '允许远程用户完全磁盘访问' 'E: the round trip lost the Full Disk Access reason'
bash "$S" run alice --admin admin1 >"$WORK/out" 2>&1; RC=$?
[ "$RC" = 0 ] || { fail "E: round trip: exit $RC (want 0)"; sed 's/^/    | /' "$WORK/out" >&2; }
[ -e "$WORK/ds/alice.gone" ] || fail 'E: the round trip did not delete alice'
has "$FLEET_TEST_LOG" 'IdentitiesOnly=yes' 'E: ssh may offer another key'
has "$FLEET_TEST_LOG" 'StrictHostKeyChecking=yes' 'E: ssh trusts a host key on first use'
has "$FLEET_TEST_LOG" 'admin1@127.0.0.1 delete alice' 'E: ssh did not ask the loopback admin to delete alice'
rm -f "$WORK/keydir/id_ed25519"
bash "$S" run alice --admin admin1 >"$WORK/out" 2>&1; RC=$?
[ "$RC" = 5 ] || fail "E: no key: exit $RC (want 5)"
has "$WORK/out" 'no key' 'E: a missing key was not said'

[ "$FAILS" = 0 ] || { printf 'fleet-login-remove-ssh-selftest: %s failure(s)\n' "$FAILS"; exit 1; }
printf 'fleet-login-remove-ssh-selftest: PASS\n'
