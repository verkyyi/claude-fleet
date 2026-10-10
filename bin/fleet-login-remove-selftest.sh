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
REAL_TAR=$(command -v tar) || exit 2
mkdir -p "$WORK/bin" "$WORK/shim" "$WORK/shim-tar-fails" "$WORK/shim-tar-warns" "$WORK/homes" "$WORK/LaunchDaemons" "$WORK/ds/groups"
cp "$BIN/fleet-login-remove.sh" "$BIN/fleet-lib.sh" "$BIN/fleet-down.sh" "$BIN/fleet-node-leave.sh" "$BIN/fleet-credsep.py" "$WORK/bin/"
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
export FLEET_TEST_LOG="$WORK/calls.log" FLEET_TEST_LIVE="$WORK/live" FLEET_TEST_DS="$WORK/ds" FLEET_TEST_PROCS="$WORK/procs"
export FLEET_LOGIN_REMOVE_SETTLE=0   # no settle watch but in the respawn leg (#2866)
mkdir -p "$WORK/tcc-ok"; : > "$WORK/tcc-ok/TCC.db"
export FLEET_LOGIN_REMOVE_TCC_DB="$WORK/tcc-ok/TCC.db"   # this run holds Full Disk Access but in the #2973 leg
export HOME="$WORK/admin" PATH="$WORK/shim:$PATH"
# the machine daemon's register (issue #2528): absent unless a leg writes one
export FLEET_NODE_STATE="$WORK/node" FLEET_NODE_SUPERVISOR="$WORK/rt/fleet-node-supervisor.py"
export FLEET_TEST_CALLER="$HOME/projects/claude-fleet"   # inside the admin's 0700 home (#1216)
mkdir -p "$HOME" "$FLEET_TEST_CALLER"
# credsep's root paths (issue #2418), all under the work dir; no launchctl/systemctl
CS="$WORK/credsep" ME=$(id -un)
export FLEET_CREDSEP_ROOT_BASE="$CS/db" FLEET_CREDSEP_RUN_BASE="$CS/run" FLEET_CREDSEP_LOG_BASE="$CS/log" \
  FLEET_CREDSEP_LIB="$CS/lib" FLEET_CREDSEP_DAEMON_DIR="$CS/daemons" FLEET_CREDSEP_ROLE="$ME" \
  FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1
if [ "$(uname)" = Darwin ]; then PX=com.claude-fleet.credsep.; PXS=.plist; else PX=claude-fleet-credsep-; PXS=.service; fi
# cs_fixture <mode> — alice and bob separated: own proxies (mode own), or both
# tenants of the shared proxy (mode shared)
cs_fixture() {
  rm -rf "${CS:?}"
  mkdir -p "$CS/daemons" "$CS/lib" "$CS/log/alice" "$CS/log/bob"
  for l in alice bob; do
    mkdir -p "$CS/db/$l/accounts" "$CS/run/$l"
    printf 'tok-POOL-%s\n' "$l" > "$CS/db/$l/accounts/p1"
    printf 'K=v\n' > "$CS/lib/$l.conf"; : > "$CS/log/$l.log"; : > "$CS/log/$l/agent.log"
    if [ "$1" = shared ]; then
      printf '{"login": "%s", "mode": "shared", "conf_dir": "%s"}\n' "$l" "$CS/conf-$l" > "$CS/db/$l/meta.json"
    else
      printf '{"login": "%s"}\n' "$l" > "$CS/db/$l/meta.json"; printf 'plist\n' > "$CS/daemons/$PX$l$PXS"
    fi
  done
  mkdir -p "$CS/db/alice.rolledback-20261008T000000Z"
  if [ "$1" = shared ]; then
    printf '{"shared": true, "logins": ["alice", "bob"]}\n' > "$CS/db/.shared.json"
    if [ "$(uname)" = Darwin ]; then printf 'plist\n' > "$CS/daemons/com.claude-fleet.cred-proxy-shared.plist"
    else printf 'unit\n' > "$CS/daemons/claude-fleet-cred-proxy-shared.service"; fi
  fi
}
cs_fixture own

# The fixture every --apply leg starts from: alice's home (fleet conf, copied
# pool, GUI agents), her system daemon, a live fleet, and the directory-service
# groups — alice sits in access_ssh by name and GUID, not in access_screensharing,
# access_disabled has no member list at all, and staff is not an access group.
reset_fixture() {
  rm -rf "${WORK:?}/homes/alice" "${WORK:?}/ds/groups" "${WORK:?}/ds/alice.gone" "${WORK:?}"/procs*
  # an archive is named to the second: two quick legs must not meet the last one's
  rm -rf "${ARCH:?}"/alice-*.tar.gz "${ARCH:?}"/alice-*.left
  mkdir -p "$FLEET_CONF_DIR/fleets/alice-fleet" "$WORK/homes/alice/Library/LaunchAgents" "$FLEET_CONF_DIR/accounts" "$WORK/ds/groups"
  printf 'FLEET_REPO=example/repo\n' > "$FLEET_CONF_DIR/fleets/alice-fleet/conf"
  printf 'alive\n' > "$FLEET_TEST_LIVE"
  printf 'token\n' > "$FLEET_CONF_DIR/accounts/alpha"
  printf 'notes\n' > "$WORK/homes/alice/keep-me.txt"
  mkdir -p "$WORK/homes/alice/Library/Caches/com.example"
  printf 'cache\n' > "$WORK/homes/alice/Library/Caches/com.example/blob"
  for p in "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.alice.spinner.plist" \
           "$WORK/homes/alice/Library/LaunchAgents/com.claude-fleet.collect.plist" \
           "$WORK/homes/alice/Library/LaunchAgents/com.ccquota.agent.plist" \
           "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.bob.spinner.plist" \
           "$FLEET_INSTALL_DAEMON_DIR/com.ccquota.agent.alice.plist" \
           "$FLEET_INSTALL_DAEMON_DIR/com.ccquota.agent.alice.plist.bak-1453" \
           "$FLEET_INSTALL_DAEMON_DIR/com.ccquota.agent.alice.plist.pre-move" \
           "$FLEET_INSTALL_DAEMON_DIR/com.ccquota.agent.bob.plist"; do
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
  -un) echo admin1 ;;
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
# The login's per-user domains (#2866): `bootout user/602` / `gui/602` leave a
# mark in $FLEET_TEST_PROCS, so the respawning distnoted below stays dead;
# `print gui/602` answers only with FAKE_GUI=1 (a logged-in console session).
cat > "$WORK/shim/launchctl" <<'EOF'
#!/bin/sh
printf 'launchctl %s\n' "$*" >> "$FLEET_TEST_LOG"
case "$#:$1 $2" in
  '2:bootout user/602'|'2:bootout gui/602') : > "$FLEET_TEST_PROCS.booted"; exit 0 ;;
  '2:print gui/602') [ "${FAKE_GUI:-0}" = 1 ]; exit ;;
esac
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
# FAKE_TCC=1: run from the node program, which has no Full Disk Access (#2953):
# the home goes but for ~/Desktop, the record stays, and it exits 1.
if [ "$1" = -deleteUser ] && [ "${FAKE_TCC:-0}" = 1 ]; then
  find "${FLEET_LOGIN_HOMES:?}/${2:?}" -mindepth 1 -maxdepth 1 ! -name Desktop -exec rm -rf {} +
  echo "sysadminctl: Operation not permitted: ${FLEET_LOGIN_HOMES}/$2/Desktop" >&2; exit 1
fi
if [ "$1" = -deleteUser ] && [ "${FAKE_HOME_STAYS:-0}" = 0 ]; then rm -rf "${FLEET_LOGIN_HOMES:?}/${2:?}"; fi
# A process of the login still alive (the respawned distnoted, #2866), or
# FAKE_DELETE_HANGS=1: deleteUser hangs — a real one retried for minutes.
if [ "$1" = -deleteUser ] && { [ -e "$FLEET_TEST_PROCS" ] || [ "${FAKE_DELETE_HANGS:-0}" = 1 ]; }; then
  echo 'sysadminctl: hanging on a live process' >&2; exec sleep 30
fi
# FAKE_RECORD_STAYS=1: the home goes, the record does not — exit 0 anyway (#2728)
if [ "$1" = -deleteUser ] && [ "${FAKE_RECORD_STAYS:-0}" = 0 ]; then : > "$FLEET_TEST_DS/${2:?}.gone"; fi
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
      /Users/alice) [ ! -e "$DS/alice.gone" ] || exit 56
                    [ "${4:-}" != GeneratedUID ] || echo 'GeneratedUID: GUID-ALICE' ;;
      /Groups/*) [ -f "$f" ] || { echo '<dscl_cmd> DS Error: -14136 (eDSRecordNotFound)' >&2; exit 56; }
                 if [ -n "${4:-}" ]; then grep "^$4: " "$f" || echo "No such key: $4"; else cat "$f"; fi ;;
      *) exit 56 ;;
    esac ;;
  -delete)
    printf 'dscl %s\n' "$*" >> "$FLEET_TEST_LOG"
    [ "${FAKE_DSCL_FAIL:-0}" = 0 ] || { echo '<dscl_cmd> DS Error: -14120 (eDSPermissionError)' >&2; exit 1; }
    case "$3" in /Users/*)
      [ "${FAKE_USER_DELETE_FAILS:-0}" = 0 ] || { echo '<dscl_cmd> DS Error: -14120 (eDSPermissionError)' >&2; exit 1; }
      : > "$DS/${3#/Users/}.gone"; exit 0 ;;
    esac
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
# The login's processes: none, unless a leg writes $FLEET_TEST_PROCS (a live
# distnoted). pkill takes it; with FAKE_RESPAWN=1 launchd brings it back on the
# next look unless the login's domain was booted out first (#2866).
cat > "$WORK/shim/pkill" <<'EOF'
#!/bin/sh
printf 'pkill %s\n' "$*" >> "$FLEET_TEST_LOG"
[ -e "$FLEET_TEST_PROCS" ] || exit 1
rm -f "$FLEET_TEST_PROCS"; : > "$FLEET_TEST_PROCS.killed"
EOF
cat > "$WORK/shim/pgrep" <<'EOF'
#!/bin/sh
printf 'pgrep %s\n' "$*" >> "$FLEET_TEST_LOG"
if [ ! -e "$FLEET_TEST_PROCS" ] && [ "${FAKE_RESPAWN:-0}" = 1 ] && [ -e "$FLEET_TEST_PROCS.killed" ] && [ ! -e "$FLEET_TEST_PROCS.booted" ]; then
  if [ -e "$FLEET_TEST_PROCS.looked" ]; then echo 'respawned /usr/sbin/distnoted agent' > "$FLEET_TEST_PROCS"; else : > "$FLEET_TEST_PROCS.looked"; fi
fi
[ -e "$FLEET_TEST_PROCS" ]
EOF
cat > "$WORK/shim-tar-fails/tar" <<'EOF'
#!/bin/sh
printf 'tar %s\n' "$*" >> "$FLEET_TEST_LOG"
echo 'tar: disk full' >&2
exit 1
EOF
# tar that writes the archive but cannot read two files, as on 2026-10-05
# (a socket, a SIP-protected .bnnsir): bsdtar says so and exits 1 (issue #1700).
cat > "$WORK/shim-tar-warns/tar" <<EOF
#!/bin/sh
case "\$1" in -t*) exec "$REAL_TAR" "\$@" ;; esac
printf 'tar %s\n' "\$*" >> "\$FLEET_TEST_LOG"
"$REAL_TAR" "\$@" || exit 2
echo 'tar: alice/Library/Biome/x.bnnsir: Couldn'"'"'t open: Operation not permitted' >&2
echo 'tar: alice/Library/Group Containers/s.sock: tar format cannot archive socket' >&2
exit 1
EOF
chmod +x "$WORK/shim/"* "$WORK/shim-tar-fails/"* "$WORK/shim-tar-warns/"*

fail() {
  printf 'selftest FAIL: %s\n' "$1" >&2
  [ ! -s "$WORK/out" ] || { printf -- '--- last run (exit %s), its tail:\n' "${RC:-?}" >&2; tail -12 "$WORK/out" >&2; }
  exit 1
}
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
has "$WORK/out" "sudo tar --exclude=alice/Library/Caches -czf $ARCH/alice-" 'archive command missing (or Library/Caches not excluded)'
has "$WORK/out" "bootout system $FLEET_INSTALL_DAEMON_DIR/com.ccquota.agent.alice.plist" 'node agent LaunchDaemon not shown (#1700)'
has "$WORK/out" "rm -f $FLEET_INSTALL_DAEMON_DIR/com.ccquota.agent.alice.plist.bak-1453" 'node agent .bak-* copy not shown'
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
has "$WORK/out" "sudo python3 -I $WORK/bin/fleet-credsep.py purge --login alice" 'credsep purge step not shown (#2418)'
has "$WORK/out" "would remove: $CS/db/alice" 'the dry run does not list the store it would remove'
[ -d "$CS/db/alice" ] && [ -f "$CS/daemons/${PX}alice$PXS" ] || fail 'preview removed credsep files'
[ ! -s "$FLEET_TEST_LOG" ] || fail 'preview executed a mutating command'
[ -f "$FLEET_TEST_LIVE" ] && [ -f "$FLEET_CONF_DIR/accounts/alpha" ] || fail 'preview mutated fixture'
[ ! -e "$ARCH" ] || fail 'preview created the archive dir'
[ "$(ssh_group)" = "$(printf 'GroupMembership: admin1 alice bob\nGroupMembers: GUID-ADMIN1 GUID-ALICE GUID-BOB')" ] || fail 'preview mutated the ssh group'

# Refuse self, admins, and an archive dir inside the home, before sudo, in either mode.
run me --apply; [ "$RC" = 3 ] || fail 'self-delete was not refused'
run bob --apply; [ "$RC" = 3 ] || fail 'admin delete was not refused'
# No such login (#2696): its own exit 4, nothing run — the hub reads it as removed.
run ghost --apply; [ "$RC" = 4 ] || fail "a login that is not there: exit $RC (want 4)"
has "$WORK/out" 'nothing to remove' 'the missing login is not explained'
[ ! -s "$FLEET_TEST_LOG" ] || fail 'a missing login ran a command'
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
has "$FLEET_TEST_LOG" "sudo tar --exclude=alice/Library/Caches -czf $ARCH/alice-" 'home was not archived'
has "$FLEET_TEST_LOG" "launchctl bootout system $FLEET_INSTALL_DAEMON_DIR/com.ccquota.agent.alice.plist" 'node agent LaunchDaemon not booted out (#1700)'
for f in com.ccquota.agent.alice.plist com.ccquota.agent.alice.plist.bak-1453 com.ccquota.agent.alice.plist.pre-move; do
  [ ! -e "$FLEET_INSTALL_DAEMON_DIR/$f" ] || fail "$f was left behind (#1700)"
done
[ -f "$FLEET_INSTALL_DAEMON_DIR/com.ccquota.agent.bob.plist" ] || fail "another login's node agent was removed"
not_has "$FLEET_TEST_LOG" 'bootout system '"$FLEET_INSTALL_DAEMON_DIR"'/com.ccquota.agent.alice.plist.' 'a never-loaded copy was booted out'
has "$FLEET_TEST_LOG" "chown 501 $ARCH/alice-" 'archive not handed to the admin'
[ "$(archives)" = 1 ] || fail "expected one archive, found $(archives)"
A=$(echo "$ARCH"/alice-*.tar.gz)
m=$(ls -ld "$A" | cut -c1-10); [ "$m" = '-rw-------' ] || fail "archive mode is $m, not -rw------- (600)"
tar -tzf "$A" > "$WORK/tar.lst" || fail 'archive is not a readable tar.gz'
has "$WORK/tar.lst" 'alice/keep-me.txt' "the person's files are not in the archive"
has "$WORK/tar.lst" 'alice/.config/claude-fleet/fleets/alice-fleet/conf' 'the fleet conf is not in the archive'
not_has "$WORK/tar.lst" 'accounts/alpha' 'the copied account pool is inside the archive'
not_has "$WORK/tar.lst" 'Library/Caches' 'Library/Caches is inside the archive (#1700)'
not_has "$WORK/out" 'WARN' 'a clean archive warned'
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
assert at('kill-session') < at('launchctl bootout system') < at('fleet-credsep.py purge') < at('rm -rf') < at('pkill -TERM') < at('sudo tar') < at('sysadminctl -deleteUser') < at('dscl . -delete')
PY
# credsep (issue #2418): alice's proxy, store (+ .rolledback-), run dir, root conf
# and logs are gone; bob's are all there
left=$(cd "$CS" && ls -d daemons/*alice* db/alice* run/alice lib/alice.conf log/alice* 2>/dev/null | tr '\n' ' ')
[ -z "$left" ] || fail "credsep left behind for a deleted login: $left"
for f in "daemons/${PX}bob$PXS" db/bob/accounts/p1 run/bob lib/bob.conf log/bob.log log/bob/agent.log; do
  [ -e "$CS/$f" ] || fail "another login's credsep $f was removed"
done
has "$WORK/out" "purge: alice — removed: proxy ${PX}alice" 'purge did not say what it removed'

# --delete-home: no archive at all; the deletion and the group cleanup are the same.
reset_fixture
run alice --delete-home --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail 'delete-home apply failed'; }
has "$WORK/out" 'home-policy=delete' 'delete-home policy line'
has "$WORK/out" '(skipped: --delete-home)' 'delete-home did not say the archive is skipped'
not_has "$FLEET_TEST_LOG" 'tar' 'delete-home archived the home'
not_has "$FLEET_TEST_LOG" 'install -d' 'delete-home prepared an archive dir'
[ "$(archives)" = 0 ] || fail 'delete-home wrote an archive'
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

# deleteUser takes the home and leaves the record, exit 0 (drill10092046,
# #2728): the record is deleted with dscl, and the run still ends done.
reset_fixture
FAKE_RECORD_STAYS=1 run alice --delete-home --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail "record-left apply: exit $RC (want 0 once dscl took it)"; }
has "$WORK/out" 'record still there after deleteUser' 'a surviving record was not reported'
has "$FLEET_TEST_LOG" 'dscl . -delete /Users/alice' 'a surviving record was not deleted with dscl'
[ -e "$WORK/ds/alice.gone" ] || fail 'the record is still there'
# … and when even dscl cannot: never done — exit 1, the hub asks again.
reset_fixture
FAKE_RECORD_STAYS=1 FAKE_USER_DELETE_FAILS=1 run alice --delete-home --apply
[ "$RC" = 1 ] || { cat "$WORK/out" >&2; fail "record that survives dscl: exit $RC (want 1)"; }
has "$WORK/out" 'is still on this machine' 'a login left on the machine was not said'
not_has "$WORK/out" 'fleet-login-remove: done' 'a login left on the machine read done'
# a process that can read the TCC database has Full Disk Access: no FDA line
not_has "$WORK/out" 'no Full Disk Access' 'an FDA-holding run was told it has none'
# … and from a process with no Full Disk Access (the node program, #2973): its
# last words say so and name the way out — they are what the hub shows
reset_fixture
mkdir -p "$WORK/tcc"; : > "$WORK/tcc/TCC.db"; chmod 000 "$WORK/tcc/TCC.db"
FLEET_LOGIN_REMOVE_TCC_DB="$WORK/tcc/TCC.db" FAKE_RECORD_STAYS=1 FAKE_USER_DELETE_FAILS=1 run alice --delete-home --apply
chmod 600 "$WORK/tcc/TCC.db"
[ "$RC" = 1 ] || { cat "$WORK/out" >&2; fail "record kept by TCC: exit $RC (want 1)"; }
has "$WORK/out" 'this process has no Full Disk Access' 'a dscl refused by TCC did not say Full Disk Access'
has "$WORK/out" 'alice --delete-home --apply' 'the FDA line does not name the admin-ssh way out'

# deleteUser fails outright — the node program has no Full Disk Access, so TCC
# keeps ~/Desktop from it, every time (33 of 33 hub-sent removes on mini2,
# #2953): no longer the end — the record goes with dscl, the home that is left
# is moved aside out of /Users, and the run ends done.
reset_fixture
mkdir -p "$WORK/homes/alice/Desktop"
FAKE_TCC=1 run alice --delete-home --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail "deleteUser failing on TCC: exit $RC (want 0 once dscl took the record)"; }
has "$WORK/out" 'sysadminctl -deleteUser alice failed (exit 1)' 'a failed deleteUser was not said'
has "$FLEET_TEST_LOG" 'dscl . -delete /Users/alice' 'after a failed deleteUser the record was not deleted with dscl'
[ -e "$WORK/ds/alice.gone" ] || fail 'TCC leg: the record is still there'
[ ! -e "$WORK/homes/alice" ] || fail 'TCC leg: the leftover home still stands in the homes dir'
has "$WORK/out" "moved to $ARCH/alice-" 'TCC leg: where the leftover home went was not said'
ls -d "$ARCH"/alice-*.left/Desktop >/dev/null 2>&1 || fail 'TCC leg: the leftover home was not moved aside whole'
has "$WORK/out" 'fleet-login-remove: done' 'TCC leg: the run did not end done'
rm -rf "$ARCH"/alice-*.left
# … and with the record surviving dscl too: still never done.
reset_fixture
FAKE_TCC=1 FAKE_USER_DELETE_FAILS=1 run alice --delete-home --apply
[ "$RC" = 1 ] || { cat "$WORK/out" >&2; fail "TCC + record surviving dscl: exit $RC (want 1)"; }
rm -rf "$ARCH"/alice-*.left

# launchd's per-user domain brings distnoted back after the pkill (drill10100326
# on macmini, #2866): user/<uid> (and gui/<uid> when there is one) is booted
# out BEFORE the kill — at step 4 and again before deleteUser — nothing comes
# back, and deleteUser does not hang.
reset_fixture
echo '/usr/sbin/distnoted agent' > "$WORK/procs"
t0=$(date +%s)
FAKE_GUI=1 FAKE_RESPAWN=1 FLEET_LOGIN_REMOVE_SETTLE=1 FLEET_LOGIN_REMOVE_DELETE_SECS=20 run alice --delete-home --apply
el=$(( $(date +%s) - t0 ))
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail "respawn apply: exit $RC (want 0)"; }
has "$FLEET_TEST_LOG" 'launchctl bootout user/602' "the login's user domain was not booted out"
grep -qx 'launchctl bootout gui/602' "$FLEET_TEST_LOG" || fail "the login's gui domain was not booted out"
[ ! -e "$WORK/procs" ] || fail 'distnoted came back and is still running'
not_has "$WORK/out" 'timed out' 'deleteUser hung on a respawned process'
[ "$el" -lt 15 ] || fail "respawn apply took ${el}s"
python3 - "$FLEET_TEST_LOG" <<'PY2' || fail 'bootout user/<uid> is not before every kill and before deleteUser'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
boots = [i for i, l in enumerate(lines) if 'launchctl bootout user/602' in l]
kills = [i for i, l in enumerate(lines) if l.startswith('pkill ')]
dele = next(i for i, l in enumerate(lines) if 'sysadminctl -deleteUser' in l)
assert boots and kills and boots[0] < kills[0], (boots, kills)
assert len(boots) >= 2 and kills[0] < boots[-1] < dele, (boots, kills, dele)
PY2
# no gui domain (nobody at the console): only user/<uid>
reset_fixture
run alice --delete-home --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail "no-gui apply: exit $RC"; }
has "$FLEET_TEST_LOG" 'launchctl bootout user/602' 'user domain not booted out without a gui one'
grep -qx 'launchctl bootout gui/602' "$FLEET_TEST_LOG" && fail 'an absent gui domain was booted out'
# deleteUser hangs anyway: it is killed at its time limit, said loudly, and the
# record check of step 6 decides (here dscl takes the record: done).
reset_fixture
t0=$(date +%s)
FAKE_DELETE_HANGS=1 FAKE_RECORD_STAYS=1 FLEET_LOGIN_REMOVE_DELETE_SECS=1 run alice --delete-home --apply
el=$(( $(date +%s) - t0 ))
[ "$el" -lt 15 ] || fail "a hanging deleteUser was not cut off at its limit (${el}s)"
has "$WORK/out" 'sysadminctl -deleteUser alice timed out after 1s' 'the deleteUser time limit was not said'
has "$FLEET_TEST_LOG" 'dscl . -delete /Users/alice' 'after a timed-out deleteUser the record was not deleted with dscl'
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail "timed-out deleteUser, record then deleted: exit $RC (want 0)"; }

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
has "$FLEET_TEST_LOG" 'sudo tar --exclude=alice/Library/Caches -czf' 'failing tar was not attempted'
has "$WORK/out" 'stopped before deleting the login' 'failed archive not explained'
not_has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser' 'login deleted although the archive failed'
not_has "$FLEET_TEST_LOG" 'dscl . -delete' 'groups edited although the archive failed'
[ -f "$WORK/homes/alice/keep-me.txt" ] || fail 'failed archive: home was lost'
[ "$(ssh_group)" = "$(printf 'GroupMembership: admin1 alice bob\nGroupMembers: GUID-ADMIN1 GUID-ALICE GUID-BOB')" ] || fail 'failed archive: ssh group edited'

# tar cannot read some files (a socket, a SIP file) but the archive is whole:
# a WARN naming them, and the offboarding goes on (issue #1700).
reset_fixture
: > "$FLEET_TEST_LOG"; PATH="$WORK/shim-tar-warns:$PATH" bash "$S" alice --apply > "$WORK/out" 2>&1; RC=$?
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail 'an unreadable file stopped the archive (#1700)'; }
has "$WORK/out" 'WARN 2 line(s) from tar' 'unreadable files not reported as a WARN'
has "$WORK/out" 'x.bnnsir' 'the unreadable file is not named'
has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser alice' 'login not deleted after an archive with warnings'
A=$(echo "$ARCH"/alice-*.tar.gz | tr ' ' '\n' | tail -n 1)
tar -tzf "$A" | grep -Fq 'alice/keep-me.txt' || fail 'archive with warnings lost the readable files'
rm -f "$ARCH"/alice-*.tar.gz

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
has "$FLEET_TEST_LOG" "sudo tar --exclude=alice/Library/Caches -czf $ARCH/alice-" 'closed cwd: home was not archived'
[ ! -e "$WORK/homes/alice" ] || fail 'closed cwd: home remains'
# A login that is a node is taken off the hub first, as itself, with its own
# token (issue #1928): the hub is asked, node.env goes, and it happens before the
# services are booted out. The dry run only shows it.
reset_fixture
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=tok-alice\n' > "$FLEET_CONF_DIR/node.env"
cat > "$WORK/shim/fakecurl" <<'EOF2'
#!/bin/sh
printf 'curl %s\n' "$*" >> "$FLEET_TEST_LOG"
cat >> "$FLEET_TEST_LOG.stdin"
printf '{"endpoint_id":"ep_7","already":false,"removed":true}\n200'
EOF2
chmod +x "$WORK/shim/fakecurl"
export FLEET_HUB_CURL="$WORK/shim/fakecurl"
run alice
has "$WORK/out" 'fleet-node-leave.XXXXXX --hub-only --reason' 'dry run does not show the hub leave'
[ -f "$FLEET_CONF_DIR/node.env" ] || fail 'dry run removed node.env'
not_has "$FLEET_TEST_LOG" 'curl' 'dry run asked the hub'
: > "$FLEET_TEST_LOG.stdin"
run alice --delete-home --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail 'node leg apply failed'; }
has "$FLEET_TEST_LOG" 'curl -sS --max-time 15' 'the hub was not asked to retire the node'
has "$FLEET_TEST_LOG" 'https://hub.test/v1/node/leave' 'the leave went to the wrong route'
not_has "$FLEET_TEST_LOG" 'tok-alice' 'the node token reached an argv'
has "$FLEET_TEST_LOG.stdin" 'Authorization: Bearer tok-alice' 'the node token was not handed over on stdin'
has "$WORK/out" 'ep_7' 'the retire verdict was not printed'
has "$FLEET_TEST_LOG" 'sudo -u alice' 'the leave did not run as the login'
python3 - "$FLEET_TEST_LOG" <<'PY' || fail 'the hub leave must come before the services are booted out'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
def at(s): return next(i for i, line in enumerate(lines) if s in line)
assert at('kill-session') < at('/v1/node/leave') < at('launchctl bootout')
PY
# The hub down: a WARN naming the other way, and the login still goes.
reset_fixture
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=tok-alice\n' > "$FLEET_CONF_DIR/node.env"
printf '#!/bin/sh\nexit 7\n' > "$WORK/shim/fakecurl"
run alice --delete-home --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail 'a hub that cannot be asked stopped the offboarding'; }
has "$WORK/out" 'was not taken off the hub' 'hub-down WARN missing'
has "$WORK/out" '「移除」' 'hub-down WARN does not name the machines page'
has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser alice' 'hub down: the login was not deleted'
unset FLEET_HUB_CURL

# A tenant of the machine's shared proxy (issue #2418): dropped from its record,
# the shared proxy restarted so its tenants.json and pool follow; bob stays on.
reset_fixture; cs_fixture shared
run alice --delete-home --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail 'shared-tenant apply failed'; }
[ ! -e "$CS/db/alice" ] && [ ! -e "$CS/lib/alice.conf" ] || fail 'shared tenant: store / root conf left behind'
[ -f "$CS/db/bob/accounts/p1" ] || fail "shared tenant: another tenant's store was removed"
python3 -c 'import json, sys; l = json.load(open(sys.argv[1]))["logins"]; sys.exit(l != ["bob"])' "$CS/db/.shared.json" \
  || fail "shared tenant: .shared.json still lists alice: $(cat "$CS/db/.shared.json")"
has "$WORK/out" 'tenant of ' 'shared tenant: purge did not drop it from the shared proxy'
has "$WORK/out" 'cred-proxy-shared' 'shared tenant: the shared proxy was not restarted'

# The purge failing (here: refused, not root outside the sandbox) stops BEFORE
# the login is deleted.
reset_fixture; cs_fixture own
FLEET_CREDSEP_TEST=0 run alice --delete-home --apply
[ "$RC" = 1 ] || { cat "$WORK/out" >&2; fail 'a refused purge did not stop the run'; }
has "$WORK/out" 'stopped before deleting the login' 'refused purge not explained'
not_has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser' 'login deleted although the credsep purge failed'
[ -d "$CS/db/alice" ] || fail 'refused purge: store removed anyway'

# A login whose services are still in the machine daemon's register (issue
# #2528): refused before anything runs — dry run and --apply — exit 6, with the
# move line for each; moved away, it goes ahead.
reset_fixture; cs_fixture own
mkdir -p "$WORK/node/logins/alice/services"; chmod 700 "$WORK/node/logins/alice"
printf '{}\n' > "$WORK/node/logins/alice/services/daily-report.json"
run alice
[ "$RC" = 6 ] || { cat "$WORK/out" >&2; fail "dry run with a registered service exited $RC, not 6"; }
has "$WORK/out" 'alice still has 1 registered service(s) on this machine: daily-report' 'register refusal does not name the service'
has "$WORK/out" "service move --login alice --name daily-report --to <新登录>" 'register refusal does not print the move line'
run alice --delete-home --apply
[ "$RC" = 6 ] || { cat "$WORK/out" >&2; fail "apply with a registered service exited $RC, not 6"; }
[ ! -s "$FLEET_TEST_LOG" ] || fail "a refused removal ran a command: $(head -3 "$FLEET_TEST_LOG")"
[ -f "$FLEET_TEST_LIVE" ] || fail 'a refused removal stopped the fleet'
rm "$WORK/node/logins/alice/services/daily-report.json"
run alice --delete-home --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail 'an emptied register still refused'; }
has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser alice' 'emptied register: the login was not deleted'

# A login the machine daemon took over (#2924): its tasks ran as root's demoted
# children, step 4 killed them, the daemon started them again — exit 1, three
# rounds. Now step 1c `account forget`s it before anything is booted out or
# killed: its accounts.json entry and logins/alice.env go, bob's stay, and the
# service it kept in the attic is never loaded back (only no longer kept).
reset_fixture; cs_fixture own
mkdir -p "$WORK/rt" "$WORK/node/logins" "$WORK/node/attic/a1"
cp "$BIN/fleet-node-supervisor.py" "$WORK/rt/"
printf '{"alice": {"managed": true, "since": 1}, "bob": {"managed": true, "since": 1}}\n' > "$WORK/node/accounts.json"
: > "$WORK/node/logins/alice.env"; : > "$WORK/node/logins/bob.env"
printf 'plist\n' > "$WORK/node/attic/a1/com.claude-fleet.dispatch.plist"
AT_SRC="$WORK/homes/alice/Library/LaunchAgents/com.claude-fleet.dispatch.plist"
printf '[{"id": "a1", "account": "alice", "keep": true, "src": "%s", "dst": "%s", "moved": 1, "uid": 602, "gid": 20, "mode": 420}]\n' \
  "$AT_SRC" "$WORK/node/attic/a1/com.claude-fleet.dispatch.plist" > "$WORK/node/attic/index.json"
run alice --delete-home
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail "managed dry run exited $RC"; }
has "$WORK/out" 'account forget alice' 'the dry run does not show the forget step'
grep -q '"alice"' "$WORK/node/accounts.json" || fail 'the dry run forgot alice'
FLEET_NODE_TEST=1 run alice --delete-home --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail "a managed login: exit $RC (want 0)"; }
python3 - "$FLEET_TEST_LOG" <<'PY2' || fail 'account forget must run before the services are booted out and the processes killed'
import sys
log = open(sys.argv[1]).read().splitlines()
f = next(i for i, l in enumerate(log) if 'account forget alice' in l)
k = next(i for i, l in enumerate(log) if 'pkill' in l or 'launchctl bootout' in l)
sys.exit(0 if f < k else 1)
PY2
python3 - "$WORK/node/accounts.json" <<'PY2' || fail "accounts.json after the remove: $(cat "$WORK/node/accounts.json")"
import json, sys
a = json.load(open(sys.argv[1]))
sys.exit(0 if "alice" not in a and a.get("bob", {}).get("managed") else 1)
PY2
[ ! -e "$WORK/node/logins/alice.env" ] && [ -e "$WORK/node/logins/bob.env" ] || fail 'logins/alice.env left (or bob.env taken)'
[ ! -e "$AT_SRC" ] || fail 'forget put the attic plist back'
grep -q '"keep"' "$WORK/node/attic/index.json" && fail 'the attic copy is still kept for a forgotten login'
has "$WORK/out" 'forgot alice: its tasks stopped, 1 service(s) left in the attic' 'the forget did not report what it did'
has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser alice' 'managed login: not deleted'
rm -rf "${WORK:?}/rt" "${WORK:?}/node"

# The local ssh road (issue #2994). A stub stands in for fleet-login-remove-ssh.sh:
# it logs each call and answers FAKE_ROAD (0 deleted · 5 cannot work · 7 the
# sshd session has no Full Disk Access). Fallback order: Full Disk Access here ⇒
# the direct road only; none ⇒ the road first, and the direct road only when the
# road did not delete.
cat > "$WORK/road.sh" <<'EOF'
#!/bin/sh
printf 'road %s\n' "$*" >> "$FLEET_TEST_LOG"
[ "$1" = run ] || exit 0
case "${FAKE_ROAD:-0}" in
  0) : > "$FLEET_TEST_DS/$2.gone"; rm -rf "${FLEET_LOGIN_HOMES:?}/$2"
     printf 'GroupMembership: admin1 bob\nGroupMembers: GUID-ADMIN1 GUID-BOB\n' > "$FLEET_TEST_DS/groups/com.apple.access_ssh"; exit 0 ;;
  7) echo 'fleet-login-remove-ssh: the ssh session has no Full Disk Access — turn on … 「允许远程用户完全磁盘访问」' >&2; exit 7 ;;
  *) echo 'fleet-login-remove-ssh: Remote Login is off' >&2; exit "$FAKE_ROAD" ;;
esac
EOF
export FLEET_LOGIN_REMOVE_SSH="$WORK/road.sh"
# FDA here: the road is never asked
reset_fixture; : > "$FLEET_TEST_LOG"
run alice --delete-home --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail "road leg (FDA): exit $RC"; }
not_has "$FLEET_TEST_LOG" 'road ' 'with Full Disk Access the ssh road was used'
has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser alice' 'with Full Disk Access the direct road did not run'
# no FDA, the road deletes: the direct road never runs, step 7 finds nothing left
reset_fixture; : > "$FLEET_TEST_LOG"; chmod 000 "$WORK/tcc/TCC.db"
FLEET_LOGIN_REMOVE_TCC_DB="$WORK/tcc/TCC.db" FAKE_TCC=1 run alice --delete-home --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail "road leg (deleted): exit $RC (want 0)"; }
has "$FLEET_TEST_LOG" "road setup --admin admin1" 'no FDA: the road was not set up'
has "$FLEET_TEST_LOG" "road run alice --admin admin1" 'no FDA: the road was not taken'
not_has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser' 'the road deleted, yet the direct road ran too'
not_has "$FLEET_TEST_LOG" 'dscl . -delete /Groups/com.apple.access_ssh' 'step 7 deleted what the road had already dropped'
has "$WORK/out" 'fleet-login-remove: done' 'road leg: not done'
# no FDA, the road cannot work (5), or its session has no FDA (7): said, then the direct road
for r in 5 7; do
  reset_fixture; : > "$FLEET_TEST_LOG"
  FLEET_LOGIN_REMOVE_TCC_DB="$WORK/tcc/TCC.db" FAKE_ROAD=$r FAKE_RECORD_STAYS=1 FAKE_USER_DELETE_FAILS=1 run alice --delete-home --apply
  [ "$RC" = 1 ] || { cat "$WORK/out" >&2; fail "road leg ($r): exit $RC (want 1)"; }
  has "$WORK/out" "the local ssh road did not delete alice (exit $r" "road $r: the fallback was not said"
  has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser alice' "road $r: no fallback to the direct road"
  has "$WORK/out" 'this process has no Full Disk Access' "road $r: #2974's reason is gone"
done
has "$WORK/out" '允许远程用户完全磁盘访问' 'road 7: the Remote Login switch was not named'
chmod 600 "$WORK/tcc/TCC.db"; rm -rf "$ARCH"/alice-*.left
unset FLEET_LOGIN_REMOVE_SSH

printf 'fleet-login-remove-selftest: PASS\n'
