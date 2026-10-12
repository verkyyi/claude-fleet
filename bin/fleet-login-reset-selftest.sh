#!/bin/bash
# fleet-login-reset-selftest.sh — bin/fleet-login-reset.sh in a sandbox (issue
# #3505, EPIC #3500 C20; BREAK-IT `spare-reuse-leaks`).
#
#   A  dry run: the plan, nothing changed
#   B  one thing planted per category the check knows (darwin), --apply ⇒ the
#      last two lines are `reset: clean` · `credsep: separated`, exit 0, every
#      plant gone, the archive dir kept, the login's home fresh
#   C  something the wash cannot take (a process quiesce left) ⇒ `reset: dirty
#      processes`, exit 1
#   D  the rejoin fails ⇒ `reset: dirty rejoin`, exit 1
#   E  killed during the rejoin, the SAME op run again ⇒ it goes on: the stop
#      redone without a second archive, washed, set up, clean; once more ⇒ only
#      the check. Another op ⇒ from the start.
#   F  refusals: no such login (4), an admin (3), under root's uid as the caller
# fleet-login-remove.sh and fleet-login-new.sh are stubs (each has its own
# selftest); the check is the real fleet-login-reset-check.py. sudo, id,
# createhomedir, crontab, ps and launchctl are PATH shims; every system path sits
# under FLEET_LOGIN_RESET_ROOT. The login's uid is this runner's own (a file can
# only be planted as it), so the outside-files sweep runs ONLY inside the root.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d "${TMPDIR:-/tmp}/login-reset-selftest.XXXXXX") || exit 2
W=$(cd "$W" && pwd -P)
trap 'rm -rf "${W:?}"' EXIT INT TERM HUP
FAILS=0
fail() { FAILS=$((FAILS + 1)); printf 'selftest FAIL %s\n' "$1"; }
ok() { printf 'ok   %s\n' "$1"; }
L=fleetu7
U=$(id -u)
R="$W/sys"
export FLEET_LOGIN_RESET_ROOT="$R"
[ -n "${FLEET_LOGIN_RESET_ROOT:-}" ] || { echo 'no sandbox root: refusing to run' >&2; exit 2; }
export FLEET_LOGIN_HOMES="$R/Users" FLEET_INSTALL_DAEMON_DIR="$R/Library/LaunchDaemons" \
  FLEET_NODE_STATE="$R/var/db/fleet-node" FLEET_CREDSEP_ROOT_BASE="$R/var/db/fleet-cred" \
  FLEET_OFFBOARD_ARCHIVE_DIR="$R/Users/Shared/offboarded" \
  FLEET_LOGIN_RESET_REMOVE="$W/remove.sh" FLEET_LOGIN_RESET_NEW="$W/new.sh" \
  RS_LOG="$W/calls.log" RS_PS="$W/ps" RS_CRON="$W/cron" RS_U="$U" RS_TPL="$R/System/Library/User Template/Non_localized"
export HOME="$R/Users/admin" PATH="$W/shim:$PATH"
H="$R/Users/$L" ARCH="$FLEET_OFFBOARD_ARCHIVE_DIR"
S="$BIN/fleet-login-reset.sh"

mkdir -p "$W/shim"
cat > "$W/shim/id" <<'EOF'
#!/bin/sh
case "$*" in
  -u) echo "${RS_ADMIN_UID:-501}" ;;
  -un) echo admin1 ;;
  "-u fleetu7") echo "$RS_U" ;;
  "-u boss") echo 777 ;;
  "-Gn fleetu7") echo staff everyone ;;
  "-Gn boss") echo staff admin ;;
  *) exit 1 ;;
esac
EOF
cat > "$W/shim/sudo" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$RS_LOG"
[ "$1" = -u ] && { shift 2; [ "$1" = -H ] && shift; }
exec "$@"
EOF
cat > "$W/shim/createhomedir" <<'EOF'
#!/bin/sh
h="$FLEET_LOGIN_HOMES/$3"
[ -d "$h" ] || cp -R "$RS_TPL" "$h"
EOF
cat > "$W/shim/crontab" <<'EOF'
#!/bin/sh
case " $* " in
  *' -r '*|*' -r') if [ -s "$RS_CRON" ]; then : > "$RS_CRON"; exit 0; fi; echo "crontab: no crontab for $2" >&2; exit 1 ;;
esac
if [ -s "$RS_CRON" ]; then cat "$RS_CRON"; exit 0; fi
echo "crontab: no crontab for $4" >&2; exit 1
EOF
cat > "$W/shim/ps" <<'EOF'
#!/bin/sh
cat "$RS_PS" 2>/dev/null; exit 0
EOF
cat > "$W/shim/launchctl" <<'EOF'
#!/bin/sh
printf 'launchctl %s\n' "$*" >> "$RS_LOG"
EOF
# the remove script's steps 1–5: say what it was asked, quiesce (unless
# RS_PROC_STAYS), archive under --keep-home
cat > "$W/remove.sh" <<'EOF'
#!/bin/bash
printf 'remove %s\n' "$*" >> "$RS_LOG"
login=$1; keep=0; apply=0
for a in "$@"; do case "$a" in --keep-home) keep=1 ;; --apply) apply=1 ;; esac; done
[ "$apply" = 1 ] || { echo 'fleet-login-remove: dry run complete'; exit 0; }
[ -n "${RS_PROC_STAYS:-}" ] || : > "$RS_PS"
if [ "$keep" = 1 ]; then
  mkdir -p "$FLEET_OFFBOARD_ARCHIVE_DIR"; a="$FLEET_OFFBOARD_ARCHIVE_DIR/$login-$(date +%s%N).tar.gz"
  : > "$a"; echo "  archive=$a"
fi
echo 'fleet-login-remove: stopped (steps 1–5); the login is kept for the wash'
EOF
# the opener in --recycle: what a new person's setup leaves, its credsep line
cat > "$W/new.sh" <<'EOF'
#!/bin/bash
printf 'new %s op=%s code=%s\n' "$*" "${FLEET_LOGIN_OP_ID:-}" "${FLEET_LOGIN_JOIN_CODE:-}" >> "$RS_LOG"
login=$1; h="$FLEET_LOGIN_HOMES/$login"
case " $* " in *' --apply '*) ;; *) echo 'fleet-login-new: DRY RUN'; exit 0 ;; esac
[ -z "${RS_NEW_DIES:-}" ] || { kill -KILL "$PPID"; exit 1; }
mkdir -p "$h/.ssh" "$h/.config/claude-fleet" "$h/.claude/fleet" "$HOME/$login-onboard"
echo 'ssh-ed25519 AAAA new' > "$h/.ssh/authorized_keys"; : > "$h/.config/claude-fleet/fleet.conf"
: > "$HOME/$login-onboard/welcome.txt"
[ -z "${RS_NEW_FAILS:-}" ] || { echo 'credsep: pending — the proxy is still starting'; exit 1; }
echo 'credsep: separated'
EOF
chmod +x "$W/shim/"* "$W/remove.sh" "$W/new.sh"

fixture() {   # a used login: one thing per category
  rm -rf "$R"; : > "$RS_LOG"; : > "$RS_PS"; : > "$RS_CRON"
  mkdir -p "$RS_TPL/Library/Preferences" "$HOME" "$ARCH" "$FLEET_INSTALL_DAEMON_DIR" "$R/private/tmp" \
    "$R/private/var/tmp" "$R/var/root" "$FLEET_NODE_STATE/entry/keys" "$FLEET_NODE_STATE/logins" "$FLEET_CREDSEP_ROOT_BASE"
  printf 'x\n' > "$RS_TPL/.profile"
  cp -R "$RS_TPL" "$H"
  printf 'notes\n' > "$H/notes.txt"
  mkdir -p "$H/Library/Keychains" "$H/.ssh" "$H/.config/claude-fleet" "$H/.config/gh" "$H/Library/LaunchAgents"
  : > "$H/Library/Keychains/login.keychain-db"; : > "$H/.ssh/id_ed25519"
  echo 'ssh-ed25519 AAAA prev' > "$H/.ssh/authorized_keys"; : > "$H/.config/claude-fleet/fleet.conf"
  : > "$H/.config/gh/hosts.yml"; : > "$H/Library/LaunchAgents/com.example.x.plist"
  mkdir -p "$FLEET_CREDSEP_ROOT_BASE/$L/accounts"; : > "$FLEET_CREDSEP_ROOT_BASE/$L/accounts/p1"
  mkdir -p "$FLEET_NODE_STATE/entry/keys/$L" "$FLEET_NODE_STATE/logins/$L"
  : > "$FLEET_NODE_STATE/entry/keys/$L/k"; : > "$FLEET_NODE_STATE/logins/$L/state.json"
  mkdir -p "$HOME/$L-onboard"; : > "$HOME/$L-onboard/password.txt"
  echo '*/5 * * * * curl evil' > "$RS_CRON"
  python3 -c 'import plistlib,sys; plistlib.dump({"Label": "com.example.x", "UserName": sys.argv[2]}, open(sys.argv[1], "wb"))' \
    "$FLEET_INSTALL_DAEMON_DIR/com.example.x.plist" "$L"
  python3 -c 'import plistlib,sys; plistlib.dump({"Label": "com.example.y", "UserName": "bob"}, open(sys.argv[1], "wb"))' \
    "$FLEET_INSTALL_DAEMON_DIR/com.example.y.plist"
  printf '%s 4242 01:00:00 distnoted\n' "$U" > "$RS_PS"
  mkdir -p "$R/private/tmp/tmux-$U"; : > "$R/private/tmp/tmux-$U/default"
  : > "$R/private/var/tmp/left.txt"; mkdir -p "$R/Users/Shared/stuff"; : > "$R/Users/Shared/stuff/a"
  : > "$ARCH/older.tar.gz"
  sleep 1   # every plant predates the wash (the check reads ctime by the second)
}
run() { bash "$S" "$@" > "$W/out" 2>&1; RC=$?; }
last2() { tail -n 2 "$W/out" | paste -sd'|' -; }
has() { grep -Fq -- "$2" "$1" && ok "$3" || fail "$3"; }
gone() { [ ! -e "$1" ] && ok "$2" || fail "$2 ($1 is still there)"; }

# ---- A: dry run ----
fixture
run "$L"
[ "$RC" = 0 ] && ok 'A dry run exits 0' || { cat "$W/out"; fail "A dry run: exit $RC"; }
has "$W/out" 'DRY RUN' 'A says DRY RUN'
has "$RS_LOG" "remove $L --recycle-stop --keep-home --archive-dir $ARCH" 'A the stop is the remove script, dry'
has "$W/out" "sudo createhomedir -c -u $L" 'A the plan names the fresh home'
[ -f "$H/notes.txt" ] && [ -s "$RS_CRON" ] && [ ! -e "$HOME/$L-reset" ] && ok 'A nothing changed' || fail 'A the dry run changed something'

# ---- B: the whole wash ----
fixture
FLEET_LOGIN_JOIN_CODE=fj_aaaaaaaaaaaaaaaaaaaaaaaaaa FLEET_LOGIN_HUB=https://hub.example FLEET_LOGIN_OP_ID=abc1 run "$L" --apply
[ "$(last2)" = 'reset: clean|credsep: separated' ] && ok 'B the last two lines' || { cat "$W/out"; fail "B last two lines: $(last2)"; }
[ "$RC" = 0 ] && ok 'B exit 0' || fail "B exit $RC"
for f in "$FLEET_CREDSEP_ROOT_BASE/$L" "$FLEET_NODE_STATE/entry/keys/$L" "$FLEET_NODE_STATE/logins/$L" "$HOME/$L-onboard/password.txt" \
         "$FLEET_INSTALL_DAEMON_DIR/com.example.x.plist" "$R/private/tmp/tmux-$U" "$R/private/var/tmp/left.txt" "$R/Users/Shared/stuff" \
         "$H/notes.txt" "$H/Library/Keychains" "$H/.ssh/id_ed25519" "$H/.config/gh"; do
  gone "$f" "B gone: ${f#"$R"/}"
done
[ ! -s "$RS_CRON" ] && ok 'B crontab emptied' || fail 'B crontab left'
[ -f "$FLEET_INSTALL_DAEMON_DIR/com.example.y.plist" ] && ok "B another login's daemon kept" || fail "B another login's daemon removed"
[ -f "$ARCH/older.tar.gz" ] && ok 'B the archive dir kept' || fail 'B the archive dir was swept'
[ "$(grep -c "\.tar\.gz" "$W/out")" -ge 1 ] && has "$W/out" "archive=$ARCH/$L-" 'B the archive is named'
grep -q 'ssh-ed25519 AAAA new' "$H/.ssh/authorized_keys" && [ -f "$H/.profile" ] && ok 'B a fresh home, set up again' || fail 'B the home was not set up again'
has "$RS_LOG" "new $L --recycle --share-pool --apply op=abc1 code=fj_aaaaaaaaaaaaaaaaaaaaaaaaaa" 'B the opener gets --recycle, the op and the join code'
has "$RS_LOG" "launchctl bootout system $FLEET_INSTALL_DAEMON_DIR/com.example.x.plist" 'B the UserName daemon booted out'
python3 - "$RS_LOG" <<'PY' && ok 'B order: stop, wash, rejoin' || fail 'B wrong order'
import sys
lines = open(sys.argv[1]).read().splitlines()
at = lambda s: next(i for i, l in enumerate(lines) if s in l)
assert at('remove ') < at('createhomedir') < at('new ') < at('fleet-login-reset-check.py')
PY
has "$HOME/$L-reset/op" 'done=rejoin' 'B the op file records the rejoin'

# ---- C: something the wash cannot take ----
fixture
RS_PROC_STAYS=1 run "$L" --apply
[ "$(last2)" = 'reset: dirty processes|credsep: separated' ] && [ "$RC" = 1 ] && ok 'C a process left ⇒ dirty, exit 1' || { tail -5 "$W/out"; fail "C: $(last2) rc $RC"; }

# ---- D: the rejoin fails ----
fixture
RS_NEW_FAILS=1 run "$L" --apply
[ "$(last2)" = 'reset: dirty rejoin|credsep: pending — the proxy is still starting' ] && [ "$RC" = 1 ] && ok 'D a failed rejoin ⇒ dirty rejoin, exit 1' || { tail -5 "$W/out"; fail "D: $(last2) rc $RC"; }

# ---- E: killed half way, the same op again ----
fixture
RS_NEW_DIES=1 FLEET_LOGIN_OP_ID=beef run "$L" --apply
[ "$RC" -ge 128 ] && ok 'E1 the run was killed in the rejoin' || fail "E1 exit $RC"
: > "$RS_LOG"
FLEET_LOGIN_OP_ID=beef run "$L" --apply
[ "$(last2)" = 'reset: clean|credsep: separated' ] && [ "$RC" = 0 ] && ok 'E2 the same op goes on to clean' || { cat "$W/out"; fail "E2: $(last2) rc $RC"; }
has "$RS_LOG" "remove $L --recycle-stop --delete-home" 'E2 the stop is redone without a second archive'
[ "$(ls "$ARCH"/$L-*.tar.gz | wc -l | tr -d ' ')" = 1 ] && ok 'E2 one archive' || fail 'E2 a second archive'
: > "$RS_LOG"
FLEET_LOGIN_OP_ID=beef run "$L" --apply
[ "$(last2)" = 'reset: clean|credsep: separated' ] && ok 'E3 a finished op again: clean' || fail "E3: $(last2)"
grep -q '^new ' "$RS_LOG" && fail 'E3 the rejoin ran again' || ok 'E3 no second rejoin'
grep -q 'createhomedir' "$RS_LOG" && fail 'E3 the home was washed again' || ok 'E3 no second wash'
: > "$RS_LOG"
FLEET_LOGIN_OP_ID=cafe run "$L" --apply
has "$RS_LOG" "remove $L --recycle-stop --keep-home" 'E4 another op starts over'

# ---- F: refusals ----
run ghost --apply; [ "$RC" = 4 ] && ok 'F no such login: 4' || fail "F ghost: $RC"
run boss --apply; [ "$RC" = 3 ] && ok 'F an admin: 3' || fail "F boss: $RC"
RS_ADMIN_UID=$U run "$L" --apply; [ "$RC" = 3 ] && ok 'F the caller itself: 3' || fail "F self: $RC"
run "$L" --bogus; [ "$RC" = 2 ] && ok 'F a bad option: 2' || fail "F bogus: $RC"

[ "$FAILS" = 0 ] || { printf 'fleet-login-reset-selftest: %s FAILED\n' "$FAILS"; exit 1; }
printf 'fleet-login-reset-selftest: PASS\n'
