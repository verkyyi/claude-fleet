#!/bin/bash
# fleet-login-remove-selftest.sh — offboarding is tested with PATH shims only.
# No real account, tmux server, launchd domain or /Library path is touched.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/login-remove-selftest.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM HUP
mkdir -p "$WORK/bin" "$WORK/shim" "$WORK/homes" "$WORK/LaunchDaemons"
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
export FLEET_LOGIN_HOMES="$WORK/homes" FLEET_INSTALL_DAEMON_DIR="$WORK/LaunchDaemons"
export FLEET_CONF_DIR="$WORK/homes/alice/.config/claude-fleet" FLEET_SKIP_GLOBAL_CONF=1
export FLEET_TEST_LOG="$WORK/calls.log" FLEET_TEST_LIVE="$WORK/live"
export HOME="$WORK/admin" PATH="$WORK/shim:$PATH"
mkdir -p "$HOME" "$FLEET_CONF_DIR/fleets/alice-fleet" "$WORK/homes/alice/Library/LaunchAgents" "$FLEET_CONF_DIR/accounts"
printf 'FLEET_REPO=example/repo\n' > "$FLEET_CONF_DIR/fleets/alice-fleet/conf"
printf 'alive\n' > "$FLEET_TEST_LIVE"
printf 'token\n' > "$FLEET_CONF_DIR/accounts/alpha"
for p in "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.alice.spinner.plist" \
         "$WORK/homes/alice/Library/LaunchAgents/com.claude-fleet.collect.plist" \
         "$WORK/homes/alice/Library/LaunchAgents/com.ccquota.agent.plist" \
         "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.bob.spinner.plist"; do
  printf 'plist\n' > "$p"
done

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
if [ "$1" = -u ]; then shift 2; [ "$1" = -H ] && shift; fi
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
cat > "$WORK/shim/sysadminctl" <<'EOF'
#!/bin/sh
printf 'sysadminctl %s\n' "$*" >> "$FLEET_TEST_LOG"
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
chmod +x "$WORK/shim/"*

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
has() { grep -Fq "$2" "$1" || fail "$3"; }
not_has() { grep -Fq "$2" "$1" && fail "$3"; :; }
run() { : > "$FLEET_TEST_LOG"; bash "$S" "$@" > "$WORK/out" 2>&1; RC=$?; }

# Preview shows both daemon shapes and account/home policy, but executes none.
run alice
[ "$RC" = 0 ] || fail 'dry run failed'
has "$WORK/out" 'DRY RUN' 'dry-run banner'
has "$WORK/out" "bootout system $FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.alice.spinner.plist" 'system shape missing'
has "$WORK/out" 'bootout gui/602' 'GUI shape missing'
has "$WORK/out" 'com.ccquota.agent.plist' 'ccquota missing'
has "$WORK/out" 'sysadminctl -deleteUser alice -keepHome' 'default keepHome missing'
[ ! -s "$FLEET_TEST_LOG" ] || fail 'preview executed a mutating command'
[ -f "$FLEET_TEST_LIVE" ] && [ -f "$FLEET_CONF_DIR/accounts/alpha" ] || fail 'preview mutated fixture'

# Refuse self and admins before sudo, in either mode.
run me --apply; [ "$RC" = 3 ] || fail 'self-delete was not refused'
run bob --apply; [ "$RC" = 3 ] || fail 'admin delete was not refused'
[ ! -s "$FLEET_TEST_LOG" ] || fail 'refusal ran a command'

run alice --apply
[ "$RC" = 0 ] || { cat "$WORK/out" >&2; fail 'apply failed'; }
has "$FLEET_TEST_LOG" 'tmux -L alice-fleet kill-session -t alice-fleet' 'fleet was not stopped'
has "$FLEET_TEST_LOG" "launchctl bootout system $FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.alice.spinner.plist" 'system daemon not booted out'
has "$FLEET_TEST_LOG" 'launchctl bootout gui/602' 'GUI daemon not booted out'
has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser alice -keepHome' 'account was not deleted with keepHome'
has "$FLEET_TEST_LOG" 'pkill -TERM -U 602' 'remaining processes were not stopped'
[ ! -e "$FLEET_CONF_DIR/accounts" ] || fail 'pool was not removed'
[ ! -e "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.alice.spinner.plist" ] || fail 'system plist was not removed'
[ ! -e "$WORK/homes/alice/Library/LaunchAgents/com.ccquota.agent.plist" ] || fail 'ccquota plist was not removed'
[ -f "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.bob.spinner.plist" ] || fail 'another login plist was removed'
python3 - "$FLEET_TEST_LOG" <<'PY' || fail 'wrong step order'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
def at(s): return next(i for i, line in enumerate(lines) if s in line)
assert at('kill-session') < at('launchctl bootout system') < at('rm -rf') < at('pkill -TERM') < at('sysadminctl -deleteUser')
PY

# The destructive home policy must be explicit.
run alice --delete-home
[ "$RC" = 0 ] || fail 'delete-home preview failed'
has "$WORK/out" 'sysadminctl -deleteUser alice' 'delete-home command absent'
not_has "$WORK/out" 'sysadminctl -deleteUser alice -keepHome' 'delete-home retained home'

# If a service remains registered, stop before touching its plist or the account.
printf 'plist\n' > "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.alice.spinner.plist"
FAKE_BOOTOUT_FAIL=1 FAKE_LOADED=1 run alice --apply
[ "$RC" = 1 ] || fail 'loaded service did not stop removal'
has "$WORK/out" 'remains loaded; stopped' 'loaded-service failure not explained'
[ -f "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.alice.spinner.plist" ] || fail 'loaded plist was removed'
not_has "$FLEET_TEST_LOG" 'sysadminctl -deleteUser' 'account deleted with a loaded service'
printf 'fleet-login-remove-selftest: PASS\n'
