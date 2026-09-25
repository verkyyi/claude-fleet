#!/bin/bash
# fleet-login-remove-selftest.sh — offboarding is tested with PATH shims only.
# No real account, tmux server, launchd domain, /Library path or directory
# service is touched. The sysadminctl shim answers `-keepHome` the way this
# macOS does ("'-keepHome' options is not available on this system", #1210 ⑤),
# so the default path must never pass it; the dscl shim is backed by a fixture
# directory so the post-deletion com.apple.access_* cleanup is checked by what
# is left in the group, not only by the argv. tar is real: the archive leg
# inspects a genuine tar.gz. The closed-cwd leg runs --apply from the admin's
# own 0700 home (issue #1216): the sudo shim refuses any `sudo -u` from under
# it, as the login's bash dies on getcwd there — the script must run step 1
# from /.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/login-remove-selftest.XXXXXX") || exit 2
WORK=$(cd "$WORK" && pwd -P)   # one spelling of the path: $PWD is compared against it (#1216)
trap 'rm -rf "${WORK:?}"' EXIT INT TERM HUP
mkdir -p "$WORK/bin" "$WORK/shim" "$WORK/shim-tar-fails" "$WORK/homes" "$WORK/LaunchDaemons" "$WORK/ds/groups"
cp "$BIN/fleet-login-remove.sh" "$BIN/fleet-lib.sh" "$BIN/fleet-down.sh" "$WORK/bin/"
cat > "$WORK/bin/fleet-restore.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$WORK/bin/tmux-dash-collect.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/bin/"*.sh
S="$WORK/bin/fleet-login-remove.sh"
ARCH="$WORK/offboarded"
export FLEET_LOGIN_HOMES="$WORK/homes" FLEET_INSTALL_DAEMON_DIR="$WORK/LaunchDaemons" FLEET_OFFBOARD_ARCHIVE_DIR="$ARCH"
export FLEET_CONF_DIR="$WORK/homes/alice/.config/claude-fleet" FLEET_SKIP_GLOBAL_CONF=1
export FLEET_TEST_LOG="$WORK/calls.log" FLEET_TEST_LIVE="$WORK/live" FLEET_TEST_DS="$WORK/ds"
export HOME="$WORK/admin" PATH="$WORK/shim:$PATH"
export FLEET_TEST_CALLER="$HOME/projects/claude-fleet"   # inside the admin's 0700 home (#1216)
mkdir -p "$HOME" "$FLEET_TEST_CALLER"

# The fixture every --apply leg starts from: alice's home (fleet conf, copied
# pool, GUI agents), her system daemon, a live fleet, and the directory-service
# groups — alice sits in access_ssh by name and GUID, not in access_screensharing,
# access_disabled has no member list at all, and staff is not an access group.
reset_fixture() {
  rm -rf "${WORK:?}/homes/alice" "${WORK:?}/ds/groups"
  mkdir -p "$FLEET_CONF_DIR/fleets/alice-fleet" "$WORK/homes/alice/Library/LaunchAgents" "$FLEET_CONF_DIR/accounts" "$WORK/ds/groups"
  printf 'FLEET_REPO=example/repo\n' > "$FLEET_CONF_DIR/fleets/alice-fleet/conf"
  printf 'alive\n' > "$FLEET_TEST_LIVE"
  printf 'token\n' > "$FLEET_CONF_DIR/accounts/alpha"
  printf 'notes\n' > "$WORK/homes/alice/keep-me.txt"
  for p in "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.alice.spinner.plist" \
           "$WORK/homes/alice/Library/LaunchAgents/com.claude-fleet.collect.plist" \
           "$WORK/homes/alice/Library/LaunchAgents/com.ccquota.agent.plist" \
           "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.bob.spinner.plist"; do
    printf 'plist\n' > "$p"
  done
  printf 'GroupMembership: admin1 alice bob\nGroupMembers: GUID-ADMIN1 GUID-ALICE GUID-BOB\n' > "$WORK/ds/groups/com.apple.access_ssh"
  printf 'GroupMembership: admin1 bob\nGroupMembers: GUID-ADMIN1 GUID-BOB\n' > "$WORK/ds/groups/com.apple.access_screensharing"
  : > "$WORK/ds/groups/com.apple.access_disabled"
  printf 'GroupMembership: alice bob\nGroupMembers: GUID-ALICE GUID-BOB\n' > "$WORK/ds/groups/staff"
}
reset_fixture

cat > "$WORK/shim/id" <<'EOF'
#!/bin/sh
case "$*" in
  -u) echo 501 ;;
  '-u alice') echo 602 ;;
  '-u me') echo 501 ;;
  '-u bob') echo 603 ;;
  '-Gn alice') echo staff everyone ;;
  '-Gn bob') echo 'staff admin' ;;
  '-Gn me') echo staff ;;
  *) exit 1 ;;
esac
EOF
cat > "$WORK/shim/sudo" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$FLEET_TEST_LOG"
if [ "$1" = -u ]; then
  # the login cannot stand in the admin's home (#1216): from under it, die as bash does
  case "$PWD/" in "$FLEET_TEST_CALLER/"*) echo "shell-init: error retrieving current directory: getcwd: cannot access parent directories: Permission denied" >&2; exit 1 ;; esac
  shift 2; [ "$1" = -H ] && shift
fi
exec "$@"
EOF
cat > "$WORK/shim/tmux" <<'EOF'
#!/bin/sh
printf 'tmux %s\n' "$*" >> "$FLEET_TEST_LOG"
case "$*" in
  *has-session*) [ -f "$FLEET_TEST_LIVE" ] ;;
  *kill-session*) rm -f "$FLEET_TEST_LIVE" ;;
  *) exit 0 ;;
esac
EOF
cat > "$WORK/shim/launchctl" <<'EOF'
#!/bin/sh
printf 'launchctl %s\n' "$*" >> "$FLEET_TEST_LOG"
case "$1" in
  bootout) [ "${FAKE_BOOTOUT_FAIL:-0}" = 1 ] && exit 1 ;;
  print) [ "${FAKE_LOADED:-0}" = 1 ] && exit 0; exit 1 ;;
esac
exit 0
EOF
# What this macOS does (#1210 ⑤): -keepHome is refused; a plain -deleteUser
# removes the login and its home (FAKE_HOME_STAYS=1: a macOS that leaves it).
cat > "$WORK/shim/sysadminctl" <<'EOF'
#!/bin/sh
printf 'sysadminctl %s\n' "$*" >> "$FLEET_TEST_LOG"
case " $* " in *' -keepHome '*) echo "'-keepHome' options is not available on this system" >&2; exit 1 ;; esac
if [ "$1" = -deleteUser ] && [ "${FAKE_HOME_STAYS:-0}" = 0 ]; then rm -rf "${FLEET_LOGIN_HOMES:?}/${2:?}"; fi
exit 0
EOF
# dscl over a fixture: `. -list /Groups`, `. -read <path> [attr]` (an absent
# attr answers "No such key" at exit 0, as dscl does), `. -delete <group> <attr>
# <value>` removes that one value — refused when it is not there, as dscl does.
# Reads are not mutations, so only -delete is logged.
cat > "$WORK/shim/dscl" <<'EOF'
#!/bin/sh
DS=$FLEET_TEST_DS
case "$2" in
  -list) ls "$DS/groups" ;;
  -read)
    f="$DS/groups/${3#/Groups/}"
    case "$3" in
      /Users/alice) [ "${4:-}" != GeneratedUID ] || echo 'GeneratedUID: GUID-ALICE' ;;
      /Groups/*) [ -f "$f" ] || { echo '<dscl_cmd> DS Error: -14136 (eDSRecordNotFound)' >&2; exit 56; }
                 if [ -n "${4:-}" ]; then grep "^$4: " "$f" || echo "No such key: $4"; else cat "$f"; fi ;;
      *) exit 56 ;;
    esac ;;
  -delete)
    printf 'dscl %s\n' "$*" >> "$FLEET_TEST_LOG"
    [ "${FAKE_DSCL_FAIL:-0}" = 0 ] || { echo '<dscl_cmd> DS Error: -14120 (eDSPermissionError)' >&2; exit 1; }
    f="$DS/groups/${3#/Groups/}"
    grep "^$4: " "$f" | tr ' ' '\n' | grep -Fxq -- "$5" || { echo '<dscl_cmd> DS Error: -14009 (eDSUnknownAttribute)' >&2; exit 1; }
    awk -v a="$4:" -v v="$5" '$1 == a {o = $1; for (i = 2; i <= NF; i++) if ($i != v) o = o " " $i; print o; next} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
esac
exit 0
EOF
cat > "$WORK/shim/install" <<'EOF'
#!/bin/sh
printf 'install %s\n' "$*" >> "$FLEET_TEST_LOG"
for last; do :; done
mkdir -p "$last"
EOF
cat > "$WORK/shim/chown" <<'EOF'
#!/bin/sh
printf 'chown %s\n' "$*" >> "$FLEET_TEST_LOG"
exit 0
EOF
cat > "$WORK/shim/pkill" <<'EOF'
#!/bin/sh
printf 'pkill %s\n' "$*" >> "$FLEET_TEST_LOG"
exit 1
EOF
cat > "$WORK/shim/pgrep" <<'EOF'
#!/bin/sh
printf 'pgrep %s\n' "$*" >> "$FLEET_TEST_LOG"
exit 1
EOF
cat > "$WORK/shim-tar-fails/tar" <<'EOF'
#!/bin/sh
printf 'tar %s\n' "$*" >> "$FLEET_TEST_LOG"
echo 'tar: disk full' >&2
exit 1
EOF
chmod +x "$WORK/shim/"* "$WORK/shim-tar-fails/"*

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
has() { grep -Fq -- "$2" "$1" || fail "$3"; }
not_has() { grep -Fq -- "$2" "$1" && fail "$3"; :; }
run() { : > "$FLEET_TEST_LOG"; bash "$S" "$@" > "$WORK/out" 2>&1; RC=$?; }
archives() { set -- "$ARCH"/alice-*.tar.gz; if [ -e "$1" ]; then echo $#; else echo 0; fi; }
ssh_group() { cat "$WORK/ds/groups/com.apple.access_ssh"; }

# Preview shows both daemon shapes, the archive, the deletion and the group
# cleanup — never -keepHome — but executes none of it.
run alice
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail 'dry run failed'; }
has "$WORK/out" 'DRY RUN' 'dry-run banner'
has "$WORK/out" "bootout system $FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.alice.spinner.plist" 'system shape missing'
has "$WORK/out" 'bootout gui/602' 'GUI shape missing'
has "$WORK/out" 'com.ccquota.agent.plist' 'ccquota missing'
has "$WORK/out" "home-policy=archive → $ARCH/alice-" 'default policy is not archive'
has "$WORK/out" "sudo install -d -m 700 -o 501 $ARCH" 'archive dir not prepared for the admin'
has "$WORK/out" "sudo tar -czf $ARCH/alice-" 'archive command missing'
has "$WORK/out" "tar.gz -C $WORK/homes alice" 'archive is not the home, relative to the homes dir'
has "$WORK/out" 'sudo chmod 600' 'archive is not 600'
has "$WORK/out" 'sysadminctl -deleteUser alice' 'default deleteUser missing'
not_has "$WORK/out" 'keepHome' 'default path still passes -keepHome (#1210 ⑤: not available on this macOS)'
has "$WORK/out" 'sudo dscl . -delete /Groups/com.apple.access_ssh GroupMembership alice' 'ssh group name cleanup missing'
has "$WORK/out" 'sudo dscl . -delete /Groups/com.apple.access_ssh GroupMembers GUID-ALICE' 'ssh group GUID cleanup missing'
not_has "$WORK/out" 'access_screensharing' 'a group alice is not in was touched'
not_has "$WORK/out" 'access_disabled' 'a group with no member list was touched'
not_has "$WORK/out" '/Groups/staff' 'a non-access group was touched'
has "$WORK/out" "archive=$ARCH/alice-" 'archive path not printed last'
[ ! -s "$FLEET_TEST_LOG" ] || fail 'preview executed a mutating command'
[ -f "$FLEET_TEST_LIVE" ] && [ -f "$FLEET_CONF_DIR/accounts/alpha" ] || fail 'preview mutated fixture'
[ ! -e "$ARCH" ] || fail 'preview created the archive dir'
[ "$(ssh_group)" = "$(printf 'GroupMembership: admin1 alice bob\nGroupMembers: GUID-ADMIN1 GUID-ALICE GUID-BOB')" ] || fail 'preview mutated the ssh group'

# Refuse self, admins, and an archive dir inside the home, before sudo, in either mode.
run me --apply; [ "$RC" = 3 ] || fail 'self-delete was not refused'
run bob --apply; [ "$RC" = 3 ] || fail 'admin delete was not refused'
run alice --archive-dir "$WORK/homes/alice/backup" --apply; [ "$RC" = 3 ] || fail 'archive into the home itself was not refused'
has "$WORK/out" 'into itself' 'archive-into-itself refusal not explained'
[ ! -s "$FLEET_TEST_LOG" ] || fail 'refusal ran a command'

# Default apply: pool out, home archived (a real tar.gz, 600, without the
# pool), login deleted with a plain -deleteUser, then the group cleanup.
run alice --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail 'apply failed'; }
has "$FLEET_TEST_LOG" 'tmux -L alice-fleet kill-session -t alice-fleet' 'fleet was not stopped'
has "$FLEET_TEST_LOG" "launchctl bootout system $FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.alice.spinner.plist" 'system daemon not booted out'
has "$FLEET_TEST_LOG" 'launchctl bootout gui/602' 'GUI daemon not booted out'
has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser alice' 'account was not deleted'
not_has "$FLEET_TEST_LOG" 'keepHome' 'apply passed -keepHome'
has "$FLEET_TEST_LOG" 'pkill -TERM -U 602' 'remaining processes were not stopped'
has "$FLEET_TEST_LOG" "install -d -m 700 -o 501 $ARCH" 'archive dir not prepared'
has "$FLEET_TEST_LOG" "sudo tar -czf $ARCH/alice-" 'home was not archived'
has "$FLEET_TEST_LOG" "chown 501 $ARCH/alice-" 'archive not handed to the admin'
[ "$(archives)" = 1 ] || fail "expected one archive, found $(archives)"
A=$(echo "$ARCH"/alice-*.tar.gz)
m=$(stat -f %Lp "$A" 2>/dev/null || stat -c %a "$A" 2>/dev/null); [ "$m" = 600 ] || fail "archive mode is $m, not 600"
tar -tzf "$A" > "$WORK/tar.lst" || fail 'archive is not a readable tar.gz'
has "$WORK/tar.lst" 'alice/keep-me.txt' "the person's files are not in the archive"
has "$WORK/tar.lst" 'alice/.config/claude-fleet/fleets/alice-fleet/conf' 'the fleet conf is not in the archive'
not_has "$WORK/tar.lst" 'accounts/alpha' 'the copied account pool is inside the archive'
has "$WORK/out" "archive=$A" 'archive path not printed at the end'
has "$WORK/out" 'fleet-login-remove: done' 'done line missing'
not_has "$WORK/out" 'WARN home still present' 'home was reported present after deleteUser removed it'
[ ! -e "$WORK/homes/alice" ] || fail 'home remains after deleteUser'
[ ! -e "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.alice.spinner.plist" ] || fail 'system plist was not removed'
[ -f "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.bob.spinner.plist" ] || fail 'another login plist was removed'
has "$FLEET_TEST_LOG" 'dscl . -delete /Groups/com.apple.access_ssh GroupMembership alice' 'ssh group name not cleaned'
has "$FLEET_TEST_LOG" 'dscl . -delete /Groups/com.apple.access_ssh GroupMembers GUID-ALICE' 'ssh group GUID not cleaned'
not_has "$FLEET_TEST_LOG" 'access_screensharing' 'a group alice is not in was touched'
not_has "$FLEET_TEST_LOG" 'access_disabled' 'a group with no member list was touched'
not_has "$FLEET_TEST_LOG" '/Groups/staff' 'a non-access group was touched'
[ "$(ssh_group)" = "$(printf 'GroupMembership: admin1 bob\nGroupMembers: GUID-ADMIN1 GUID-BOB')" ] || { ssh_group >&2; fail 'ssh group still lists alice, or lost someone else'; }
[ "$(cat "$WORK/ds/groups/staff")" = "$(printf 'GroupMembership: alice bob\nGroupMembers: GUID-ALICE GUID-BOB')" ] || fail 'staff group was edited'
python3 - "$FLEET_TEST_LOG" <<'PY' || fail 'wrong step order'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
def at(s): return next(i for i, line in enumerate(lines) if s in line)
assert at('kill-session') < at('launchctl bootout system') < at('rm -rf') < at('pkill -TERM') < at('sudo tar') < at('sysadminctl -deleteUser') < at('dscl . -delete')
PY

# --delete-home: no archive at all; the deletion and the group cleanup are the same.
reset_fixture
run alice --delete-home --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail 'delete-home apply failed'; }
has "$WORK/out" 'home-policy=delete' 'delete-home policy line'
has "$WORK/out" '(skipped: --delete-home)' 'delete-home did not say the archive is skipped'
not_has "$FLEET_TEST_LOG" 'tar' 'delete-home archived the home'
not_has "$FLEET_TEST_LOG" 'install -d' 'delete-home prepared an archive dir'
[ "$(archives)" = 1 ] || fail 'delete-home wrote an archive'
has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser alice' 'delete-home did not delete the account'
not_has "$FLEET_TEST_LOG" 'keepHome' 'delete-home passed -keepHome'
not_has "$WORK/out" 'archive=' 'delete-home printed an archive path'
[ ! -e "$WORK/homes/alice" ] || fail 'delete-home: home remains'
has "$FLEET_TEST_LOG" 'dscl . -delete /Groups/com.apple.access_ssh GroupMembership alice' 'delete-home skipped the group cleanup'
[ "$(ssh_group)" = "$(printf 'GroupMembership: admin1 bob\nGroupMembers: GUID-ADMIN1 GUID-BOB')" ] || fail 'delete-home: ssh group still lists alice'

# A macOS that leaves the home behind: say so, loudly, after the deletion.
reset_fixture
FAKE_HOME_STAYS=1 run alice --delete-home --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail 'home-stays apply failed'; }
has "$WORK/out" "WARN home still present after deleteUser: $WORK/homes/alice" 'a leftover home was not reported'

# --archive-dir picks the archive location; a login in no access group says so.
reset_fixture
printf 'GroupMembership: admin1 bob\nGroupMembers: GUID-ADMIN1 GUID-BOB\n' > "$WORK/ds/groups/com.apple.access_ssh"
run alice --archive-dir "$WORK/elsewhere" --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail 'archive-dir apply failed'; }
[ -f "$(echo "$WORK/elsewhere"/alice-*.tar.gz)" ] || fail '--archive-dir was not honoured'
has "$WORK/out" '(no com.apple.access_* group lists alice)' 'no-group case not explained'
not_has "$FLEET_TEST_LOG" 'dscl . -delete' 'dscl -delete ran for a login in no access group'

# The archive failing stops BEFORE the login is deleted; the home and its groups are untouched.
reset_fixture
: > "$FLEET_TEST_LOG"; PATH="$WORK/shim-tar-fails:$PATH" bash "$S" alice --apply > "$WORK/out" 2>&1; RC=$?
[ "$RC" = 1 ] || { cat "$WORK/out" >&2; fail 'a failed archive did not stop the run'; }
has "$FLEET_TEST_LOG" 'sudo tar -czf' 'failing tar was not attempted'
has "$WORK/out" 'stopped before deleting the login' 'failed archive not explained'
not_has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser' 'login deleted although the archive failed'
not_has "$FLEET_TEST_LOG" 'dscl . -delete' 'groups edited although the archive failed'
[ -f "$WORK/homes/alice/keep-me.txt" ] || fail 'failed archive: home was lost'
[ "$(ssh_group)" = "$(printf 'GroupMembership: admin1 alice bob\nGroupMembers: GUID-ADMIN1 GUID-ALICE GUID-BOB')" ] || fail 'failed archive: ssh group edited'

# A group edit failing AFTER the deletion cannot undo it: finish the rest, say
# what is left to do by hand, exit 1.
reset_fixture
FAKE_DSCL_FAIL=1 run alice --apply
[ "$RC" = 1 ] || { cat "$WORK/out" >&2; fail 'a failed group edit did not exit 1'; }
has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser alice' 'group-edit failure leg: login not deleted'
has "$WORK/out" 'failed after the login was deleted; finish by hand' 'leftover group edit not explained'
has "$WORK/out" 'GroupMembers GUID-ALICE' 'the second group edit was not attempted after the first failed'
has "$WORK/out" 'deleted, but a step after it failed' 'partial outcome not summarised'
has "$WORK/out" 'archive=' 'archive path not printed on the partial outcome'

# If a service remains registered, stop before touching its plist, the home or the account.
reset_fixture
FAKE_BOOTOUT_FAIL=1 FAKE_LOADED=1 run alice --apply
[ "$RC" = 1 ] || fail 'loaded service did not stop removal'
has "$WORK/out" 'remains loaded; stopped' 'loaded-service failure not explained'
[ -f "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.alice.spinner.plist" ] || fail 'loaded plist was removed'
not_has "$FLEET_TEST_LOG" 'sudo tar' 'home archived with a loaded service'
not_has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser' 'account deleted with a loaded service'
# From the admin's own 0700 home (issue #1216) — where the admin actually types
# it — step 1 runs as the login, which cannot stand there: bash died on getcwd
# and the offboarding stopped at once. The script runs it from /.
reset_fixture
( cd "$FLEET_TEST_CALLER" && "$WORK/shim/sudo" -u alice -H true 2>/dev/null ) && fail 'the shim does not refuse a -u run from the closed cwd'
( cd "$FLEET_TEST_CALLER" && "$WORK/shim/sudo" true 2>/dev/null ) || fail 'the shim refuses a root (no -u) run from the closed cwd'
: > "$FLEET_TEST_LOG"; ( cd "$FLEET_TEST_CALLER" && bash "$S" alice --apply ) > "$WORK/out" 2>&1; RC=$?
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail 'apply from the closed cwd failed'; }
not_has "$WORK/out" 'Permission denied' 'closed cwd: a getcwd death leaked into the run'
has "$FLEET_TEST_LOG" 'tmux -L alice-fleet kill-session -t alice-fleet' 'closed cwd: fleet was not stopped'
has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser alice' 'closed cwd: account was not deleted'
has "$FLEET_TEST_LOG" "sudo tar -czf $ARCH/alice-" 'closed cwd: home was not archived'
[ ! -e "$WORK/homes/alice" ] || fail 'closed cwd: home remains'
printf 'fleet-login-remove-selftest: PASS\n'
