#!/bin/bash
# selftest-parts: 2
# fleet-login-reset-selftest.sh — bin/fleet-login-reset.sh in a sandbox (issue
# #3505, EPIC #3500 C20; BREAK-IT `spare-reuse-leaks`).
#
#   A  dry run: the plan, nothing changed
#   B  one thing planted per category the check knows (darwin), --apply ⇒ the
#      last two lines are `reset: clean` · `credsep: separated`, exit 0, every
#      plant gone (the uid's /private/var/folders dir emptied, its C/T/0 kept —
#      issue #4044), the archive dir kept, the old home archived from where it
#      was moved aside, the login's home fresh, the check BEFORE the rejoin, and
#      a `timing:` line before the verdict (stop · quiesce · … · isolated · total)
#   C  something the wash cannot take (a process quiesce left) ⇒ `reset: dirty
#      processes`, exit 1
#   D  the rejoin fails ⇒ `reset: dirty rejoin`, exit 1
#   E  killed during the rejoin, the SAME op run again ⇒ it goes on: the stop
#      redone without a second archive, washed, set up, clean; once more ⇒ only
#      the check. Another op ⇒ from the start.
#   F  refusals: no such login (4), an admin (3), under root's uid as the caller
#   R  root under the admin gate (issue #3723): FLEET_LOGIN_ADMIN_DIR + EUID 0
#      (FLEET_LOGIN_TEST_EUID) ⇒ clean, no step through sudo but the drops, the
#      op book <dir>/<login>-reset/op, the gate dir's <login>-onboard cleared,
#      nothing written in the admin's $HOME, both children handed the same;
#      EUID 0 with no dir ⇒ 3, nothing run
#   H  the stop is --quick, and the old home's archive + delete run detached:
#      the run is back before they are (FLEET_LOGIN_RESET_ASIDE unset)
#   T  the fresh home is a clone of root's home template (issue #4194): a
#      template there ⇒ cloned, no createhomedir; none for this version (exit 3)
#      ⇒ createhomedir, and a template build started off the clock
#   K  a login the machine daemon serves with its token in the credsep store
#      (issue #4195): the token kept root's — the store's node keys (only) and
#      node.key into <node state>/keep/<login>/ before the stop, the stop
#      --keep-node, the opener handed the keep dir, `node: kept` before the
#      verdict, the keep dir gone, a `keep=` lap; the opener not putting it back
#      ⇒ dirty rejoin and the keep dir stays for the same op again; no daemon
#      file, or FLEET_LOGIN_RESET_KEEP_NODE=0 ⇒ the old re-join, byte for byte
#   G  launchd relaunched a process of the uid after the stop's quiesce, before
#      the wash (distnoted, issue #3979) ⇒ the wash quiesces again before its
#      clock starts: clean, and the bootout + kill sit between stop and wash
# fleet-login-remove.sh and fleet-login-new.sh are stubs (each has its own
# selftest); the check is the real fleet-login-reset-check.py. sudo, id,
# createhomedir, crontab, ps, pgrep, pkill and launchctl are PATH shims (pkill
# NEVER real: the login's uid is the runner's); every system path sits
# under FLEET_LOGIN_RESET_ROOT. The login's uid is this runner's own (a file can
# only be planted as it), so the outside-files sweep runs ONLY inside the root.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-sections.sh"
selftest_sections 2
W=$(mktemp -d "${TMPDIR:-/tmp}/login-reset-selftest.XXXXXX") || exit 2
W=$(cd "$W" && pwd -P)
trap 'rm -rf "${W:?}"' EXIT INT TERM HUP
FAILS=0
fail() { FAILS=$((FAILS + 1)); printf 'selftest FAIL %s\n' "$1"; }
L=fleetu7
U=$(id -u)
R="$W/sys"
export FLEET_LOGIN_RESET_ROOT="$R"
[ -n "${FLEET_LOGIN_RESET_ROOT:-}" ] || { echo 'no sandbox root: refusing to run' >&2; exit 2; }
export FLEET_LOGIN_HOMES="$R/Users" FLEET_INSTALL_DAEMON_DIR="$R/Library/LaunchDaemons" \
  FLEET_NODE_STATE="$R/var/db/fleet-node" FLEET_CREDSEP_ROOT_BASE="$R/var/db/fleet-cred" \
  FLEET_OFFBOARD_ARCHIVE_DIR="$R/Users/Shared/offboarded" \
  FLEET_LOGIN_RESET_REMOVE="$W/remove.sh" FLEET_LOGIN_RESET_NEW="$W/new.sh" \
  RS_LOG="$W/calls.log" RS_PS="$W/ps" RS_CRON="$W/cron" RS_U="$U" RS_ADMIN_DEF="$((U + 1000))" RS_TPL="$R/System/Library/User Template/Non_localized"
export HOME="$R/Users/admin" PATH="$W/shim:$PATH" FLEET_LOGIN_RESET_SETTLE=0 FLEET_LOGIN_RESET_ASIDE=wait
H="$R/Users/$L" ARCH="$FLEET_OFFBOARD_ARCHIVE_DIR"
S="$BIN/fleet-login-reset.sh"

mkdir -p "$W/shim"
cat > "$W/shim/id" <<'EOF'
#!/bin/sh
case "$*" in
  -u) echo "${RS_ADMIN_UID:-$RS_ADMIN_DEF}" ;;
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
# `install -o <uid>` is root's to do: as the runner, the owner is dropped
if [ "$1" = install ]; then
  shift; set -- install "$@"; n=$#; i=0
  while [ "$i" -lt "$n" ]; do
    a=$1; shift; i=$((i + 1))
    if [ "$a" = -o ]; then shift; i=$((i + 1)); continue; fi
    set -- "$@" "$a"
  done
fi
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
# the uid's processes are RS_PS's lines; a kill takes them unless RS_PROC_STAYS
cat > "$W/shim/pgrep" <<'EOF'
#!/bin/sh
[ -s "$RS_PS" ]
EOF
cat > "$W/shim/pkill" <<'EOF'
#!/bin/sh
printf 'pkill %s\n' "$*" >> "$RS_LOG"
[ -n "${RS_PROC_STAYS:-}" ] || : > "$RS_PS"
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
[ -z "${FLEET_LOGIN_ADMIN_DIR:-}" ] || printf 'remove-adir %s euid=%s\n' "$FLEET_LOGIN_ADMIN_DIR" "${FLEET_LOGIN_TEST_EUID:-}" >> "$RS_LOG"
login=$1; keep=0; apply=0
for a in "$@"; do case "$a" in --keep-home) keep=1 ;; --apply) apply=1 ;; esac; done
[ "$apply" = 1 ] || { echo 'fleet-login-remove: dry run complete'; exit 0; }
printf '\n[1b] off the hub\n\n[2] services out\n'
[ -n "${RS_PROC_STAYS:-}" ] || : > "$RS_PS"
# launchd brings one back after the quiesce, while the archive runs (#3979)
[ -z "${RS_RESPAWN:-}" ] || printf '%s 88669 00:00:30 distnoted\n' "$RS_U" > "$RS_PS"
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
[ -z "${FLEET_LOGIN_KEEP_NODE:-}" ] || printf 'new-keep %s %s\n' "$FLEET_LOGIN_KEEP_NODE" "$(tr '\n' ' ' < "$FLEET_LOGIN_KEEP_NODE/node.env")" >> "$RS_LOG"
[ -z "${FLEET_LOGIN_ADMIN_DIR:-}" ] || printf 'new-adir %s euid=%s\n' "$FLEET_LOGIN_ADMIN_DIR" "${FLEET_LOGIN_TEST_EUID:-}" >> "$RS_LOG"
login=$1; h="$FLEET_LOGIN_HOMES/$login"
case " $* " in *' --apply '*) ;; *) echo 'fleet-login-new: DRY RUN'; exit 0 ;; esac
[ -z "${RS_NEW_DIES:-}" ] || { kill -KILL "$PPID"; exit 1; }
mkdir -p "$h/.ssh" "$h/.config/claude-fleet" "$h/.claude/fleet" "$HOME/$login-onboard"
echo 'ssh-ed25519 AAAA new' > "$h/.ssh/authorized_keys"; : > "$h/.config/claude-fleet/fleet.conf"
: > "$HOME/$login-onboard/welcome.txt"
[ -z "${RS_NEW_FAILS:-}" ] || { echo 'credsep: pending — the proxy is still starting'; exit 1; }
[ -z "${FLEET_LOGIN_KEEP_NODE:-}" ] || [ -n "${RS_NEW_NO_KEEP:-}" ] || echo '  node: kept — the token root kept, never through the home'
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
  printf '%s 9999999 01:00:00 distnoted\n' "$U" > "$RS_PS"   # above any pid_max: never the checker's own (#4745)
  mkdir -p "$R/private/tmp/tmux-$U"; : > "$R/private/tmp/tmux-$U/default"
  : > "$R/private/var/tmp/left.txt"; mkdir -p "$R/Users/Shared/stuff"; : > "$R/Users/Shared/stuff/a"
  mkdir -p "$R/private/var/folders/zz/abc123/T" "$R/private/var/folders/zz/abc123/C" "$R/private/var/folders/zz/abc123/0"
  : > "$R/private/var/folders/zz/abc123/T/prev-tmp.txt"; : > "$R/private/var/folders/zz/abc123/C/cache.db"
  : > "$R/private/var/folders/zz/abc123/stray"
  mkdir -p "$R/private/var/folders/zz/abc123/X/clone.app"; : > "$R/private/var/folders/zz/abc123/X/clone.app/bin"
  : > "$ARCH/older.tar.gz"
  sleep 1   # every plant predates the wash (the check reads ctime by the second)
}
run() { bash "$S" "$@" > "$W/out" 2>&1; RC=$?; }
last2() { tail -n 2 "$W/out" | paste -sd'|' -; }
has() { grep -Fq -- "$2" "$1" && st_ok "$3" || fail "$3"; }
gone() { [ ! -e "$1" ] && st_ok "$2" || fail "$2 ($1 is still there)"; }

if selftest_section 1; then
# ---- A: dry run ----
fixture
run "$L"
[ "$RC" = 0 ] && st_ok 'A dry run exits 0' || { cat "$W/out"; fail "A dry run: exit $RC"; }
has "$W/out" 'DRY RUN' 'A says DRY RUN'
has "$RS_LOG" "remove $L --recycle-stop --quick --delete-home --archive-dir $ARCH" 'A the stop is the remove script, --quick, dry'
has "$W/out" "sudo createhomedir -c -u $L" 'A the plan names the fresh home'
[ -f "$H/notes.txt" ] && [ -s "$RS_CRON" ] && [ ! -e "$HOME/$L-reset" ] && st_ok 'A nothing changed' || fail 'A the dry run changed something'

# ---- B: the whole wash ----
fixture
FLEET_LOGIN_JOIN_CODE=fj_aaaaaaaaaaaaaaaaaaaaaaaaaa FLEET_LOGIN_HUB=https://hub.example FLEET_LOGIN_OP_ID=abc1 run "$L" --apply
[ "$(last2)" = 'reset: clean|credsep: separated' ] && st_ok 'B the last two lines' || { cat "$W/out"; fail "B last two lines: $(last2)"; }
[ "$RC" = 0 ] && st_ok 'B exit 0' || fail "B exit $RC"
for f in "$FLEET_CREDSEP_ROOT_BASE/$L" "$FLEET_NODE_STATE/entry/keys/$L" "$FLEET_NODE_STATE/logins/$L" "$HOME/$L-onboard/password.txt" \
         "$FLEET_INSTALL_DAEMON_DIR/com.example.x.plist" "$R/private/tmp/tmux-$U" "$R/private/var/tmp/left.txt" "$R/Users/Shared/stuff" \
         "$H/notes.txt" "$H/Library/Keychains" "$H/.ssh/id_ed25519" "$H/.config/gh" \
         "$R/private/var/folders/zz/abc123/T/prev-tmp.txt" "$R/private/var/folders/zz/abc123/C/cache.db" "$R/private/var/folders/zz/abc123/stray"; do
  gone "$f" "B gone: ${f#"$R"/}"
done
[ ! -s "$RS_CRON" ] && st_ok 'B crontab emptied' || fail 'B crontab left'
[ -f "$FLEET_INSTALL_DAEMON_DIR/com.example.y.plist" ] && st_ok "B another login's daemon kept" || fail "B another login's daemon removed"
[ -f "$ARCH/older.tar.gz" ] && st_ok 'B the archive dir kept' || fail 'B the archive dir was swept'
[ -d "$R/private/var/folders/zz/abc123/T" ] && [ -d "$R/private/var/folders/zz/abc123/C" ] && st_ok 'B the uid dir keeps its C/T skeleton' || fail 'B the uid dir lost its skeleton'
[ -f "$R/private/var/folders/zz/abc123/X/clone.app/bin" ] && st_ok "B the SIP-held X is left alone (root's rm is refused there) and the check passes" || fail 'B the wash went into X'
has "$W/out" "archive=$ARCH/$L-" 'B the archive is named'
TGZ=$(ls "$ARCH"/$L-*.tar.gz 2>/dev/null | head -1)
# listed to a file first: under pipefail `tar | grep -q` is red whenever grep's early
# exit SIGPIPEs tar mid-listing — a found line read as a miss (#4243)
tar -tzf "$TGZ" > "$W/tgz.list" 2>&1 || :
[ -n "$TGZ" ] && grep -q "^$L/notes.txt" "$W/tgz.list" && st_ok 'B the archive holds the old home as <login>/' || fail "B archive: '$TGZ' $(head -3 "$W/tgz.list" | tr '\n' ' ')"
[ -z "$(ls -d "$ARCH"/*.wash 2>/dev/null)" ] && st_ok 'B the moved-aside home is deleted after its archive' || fail 'B a .wash dir is left'
grep -Eq '^timing: stop=[0-9.]+ quiesce=[0-9.]+ aside=[0-9.]+ requiesce=[0-9.]+ home\+sweep=[0-9.]+ check=[0-9.]+ rejoin=[0-9.]+ isolated=[0-9.]+ total=[0-9.]+$' "$W/out" \
  && st_ok 'B one timing line' || { grep timing "$W/out"; fail 'B no timing line'; }
[ "$(tail -n 4 "$W/out" | head -n 1 | cut -c1-7)" = 'timing:' ] && st_ok 'B the timing line sits right before the verdict' || fail 'B timing line misplaced'
has "$HOME/$L-reset/op" 'timing=stop=' 'B the op file keeps the timing'
grep -q 'steps: ' "$W/out" && st_ok 'B the children are stamped' || fail 'B no step stamps'
grep -q 'ssh-ed25519 AAAA new' "$H/.ssh/authorized_keys" && [ -f "$H/.profile" ] && st_ok 'B a fresh home, set up again' || fail 'B the home was not set up again'
has "$RS_LOG" "new $L --recycle --share-pool --apply op=abc1 code=fj_aaaaaaaaaaaaaaaaaaaaaaaaaa" 'B the opener gets --recycle, the op and the join code'
has "$RS_LOG" "launchctl bootout system $FLEET_INSTALL_DAEMON_DIR/com.example.x.plist" 'B the UserName daemon booted out'
python3 - "$RS_LOG" <<'PY' && st_ok 'B order: stop, wash, rejoin' || fail 'B wrong order'
import sys
lines = open(sys.argv[1]).read().splitlines()
at = lambda s: next(i for i, l in enumerate(lines) if s in l)
assert at('remove ') < at('createhomedir') < at('fleet-login-reset-check.py') < at('new ')
PY
has "$HOME/$L-reset/op" 'phase=rejoin' 'B the op file records the rejoin'

# ---- C: something the wash cannot take ----
fixture
RS_PROC_STAYS=1 run "$L" --apply
[ "$(last2)" = 'reset: dirty processes|credsep: not reached' ] && [ "$RC" = 1 ] && st_ok 'C a process left ⇒ dirty, exit 1 (before any rejoin)'
grep -q '^new ' "$RS_LOG" && fail 'C a dirty check still rejoined' || st_ok 'C a dirty check: never set up again, no join code spent' || { tail -5 "$W/out"; fail "C: $(last2) rc $RC"; }

# ---- D: the rejoin fails ----
fixture
RS_NEW_FAILS=1 run "$L" --apply
[ "$(last2)" = 'reset: dirty rejoin|credsep: pending — the proxy is still starting' ] && [ "$RC" = 1 ] && st_ok 'D a failed rejoin ⇒ dirty rejoin, exit 1' || { tail -5 "$W/out"; fail "D: $(last2) rc $RC"; }

# ---- E: killed half way, the same op again ----
fixture
RS_NEW_DIES=1 FLEET_LOGIN_OP_ID=beef run "$L" --apply
[ "$RC" -ge 128 ] && st_ok 'E1 the run was killed in the rejoin' || fail "E1 exit $RC"
: > "$RS_LOG"
FLEET_LOGIN_OP_ID=beef run "$L" --apply
[ "$(last2)" = 'reset: clean|credsep: separated' ] && [ "$RC" = 0 ] && st_ok 'E2 the same op goes on to clean' || { cat "$W/out"; fail "E2: $(last2) rc $RC"; }
has "$RS_LOG" "remove $L --recycle-stop --quick" 'E2 the stop is redone'
[ "$(ls "$ARCH"/$L-*.tar.gz | wc -l | tr -d ' ')" = 1 ] && st_ok 'E2 one archive' || fail 'E2 a second archive'
: > "$RS_LOG"
FLEET_LOGIN_OP_ID=beef run "$L" --apply
[ "$(last2)" = 'reset: clean|credsep: separated' ] && st_ok 'E3 a finished op again: clean' || fail "E3: $(last2)"
grep -q '^new ' "$RS_LOG" && fail 'E3 the rejoin ran again' || st_ok 'E3 no second rejoin'
grep -q 'createhomedir' "$RS_LOG" && fail 'E3 the home was washed again' || st_ok 'E3 no second wash'
: > "$RS_LOG"
FLEET_LOGIN_OP_ID=cafe run "$L" --apply
grep -q 'createhomedir' "$RS_LOG" && has "$W/out" "archive=$ARCH/$L-" 'E4 another op starts over, its own archive'

# ---- F: refusals ----
run ghost --apply; [ "$RC" = 4 ] && st_ok 'F no such login: 4' || fail "F ghost: $RC"
run boss --apply; [ "$RC" = 3 ] && st_ok 'F an admin: 3' || fail "F boss: $RC"
RS_ADMIN_UID=$U run "$L" --apply; [ "$RC" = 3 ] && st_ok 'F the caller itself: 3' || fail "F self: $RC"
run "$L" --bogus; [ "$RC" = 2 ] && st_ok 'F a bad option: 2' || fail "F bogus: $RC"

fi

if selftest_section 2; then
# ---- K: the node token kept (issue #4195) ----
keep_fixture() {
  fixture
  printf 'CCQUOTA_TOKEN=x\n' > "$FLEET_NODE_STATE/logins/$L.env"
  printf '{"login":"%s"}\n' "$L" > "$FLEET_CREDSEP_ROOT_BASE/$L/meta.json"
  printf '# node\nCCQUOTA_TOKEN=tok-kept\nCCQUOTA_HUB_URL=https://hub.example\nFLEET_X=1\n' > "$FLEET_CREDSEP_ROOT_BASE/$L/node.env"
  printf 'key\n' > "$FLEET_CREDSEP_ROOT_BASE/$L/node.key"; chmod 600 "$FLEET_CREDSEP_ROOT_BASE/$L/node.key"
}
KD="$FLEET_NODE_STATE/keep/$L"
keep_fixture
FLEET_LOGIN_OP_ID=abc7 run "$L" --apply
[ "$(last2)" = 'reset: clean|credsep: separated' ] && [ "$RC" = 0 ] && st_ok 'K clean' || { cat "$W/out"; fail "K: $(last2) rc $RC"; }
has "$RS_LOG" "remove $L --recycle-stop --quick --delete-home --archive-dir $ARCH --keep-node" 'K the stop keeps the node (no fleet node leave)'
has "$RS_LOG" "new-keep $KD CCQUOTA_TOKEN=tok-kept CCQUOTA_HUB_URL=https://hub.example " 'K the opener gets the keep dir: the node keys only'
[ "$(tail -n 3 "$W/out" | head -n 1)" = 'node: kept (root-held token, no re-join)' ] && st_ok 'K node: kept right before the verdict' || fail 'K no node: kept line'
grep -Eq '^timing: keep=[0-9.]+ stop=' "$W/out" && st_ok 'K the timing line has keep=' || fail 'K no keep= lap'
gone "$KD" 'K the keep dir is gone once set up'
grep -q "sudo cp -p $FLEET_CREDSEP_ROOT_BASE/$L/node.key $KD/node.key" "$RS_LOG" && st_ok 'K node.key kept, owner and mode with it' || fail 'K node.key not kept'
keep_fixture
RS_NEW_NO_KEEP=1 FLEET_LOGIN_OP_ID=abc8 run "$L" --apply
[ "$(last2)" = 'reset: dirty rejoin|credsep: separated' ] && [ -f "$KD/node.env" ] && st_ok 'K the token not put back ⇒ dirty rejoin, kept for the same op' \
  || { tail -5 "$W/out"; fail "K2: $(last2)"; }
FLEET_LOGIN_OP_ID=abc8 run "$L" --apply
[ "$(last2)" = 'reset: clean|credsep: separated' ] && grep -q 'kept by an earlier run of this op' "$W/out" && [ ! -e "$KD" ] \
  && st_ok 'K the same op again: the kept token, from the keep dir' || { tail -8 "$W/out"; fail "K3: $(last2)"; }
keep_fixture
FLEET_LOGIN_RESET_KEEP_NODE=0 FLEET_LOGIN_OP_ID=abc9 run "$L" --apply
! grep -q -- '--keep-node' "$RS_LOG" && ! grep -q '^new-keep' "$RS_LOG" && ! grep -q '^node: kept' "$W/out" \
  && st_ok 'K FLEET_LOGIN_RESET_KEEP_NODE=0 ⇒ the old re-join' || fail 'K the off switch kept the node'
keep_fixture; rm -f "$FLEET_NODE_STATE/logins/$L.env"
FLEET_LOGIN_OP_ID=abca run "$L" --apply
! grep -q -- '--keep-node' "$RS_LOG" && ! grep -q '^new-keep' "$RS_LOG" && grep -Eq '^timing: stop=' "$W/out" \
  && st_ok 'K not served by the machine daemon (the token was in the person'"'"'s reach) ⇒ re-join' || fail 'K kept a token the person could reach'

# ---- G: a process relaunched between the stop and the wash ----
fixture
RS_RESPAWN=1 run "$L" --apply
[ "$(last2)" = 'reset: clean|credsep: separated' ] && [ "$RC" = 0 ] && st_ok 'G a relaunch after the stop is quiesced before the clock: clean' || { tail -8 "$W/out"; fail "G: $(last2) rc $RC"; }
python3 - "$RS_LOG" <<'PY' && st_ok 'G the wash boots out and kills before its clock, and again before the fresh home' || fail 'G no quiesce between stop and wash'
import sys
lines = open(sys.argv[1]).read().splitlines()
at = lambda s, f=0: next(i for i, l in enumerate(lines) if i >= f and s in l)
r = at('remove ')
k = at('launchctl bootout user/', at('pkill -KILL -U', r))
k2 = at('pkill -KILL -U', at(' mv ', k))
assert k2 < at('createhomedir', k2) < at('new ')
PY

# ---- H: the old home's archive is off the clock ----
fixture
# The tar is held until the run is back (a gate file, not a clock: a slow
# macOS runner took 3s for the run alone — issue #4275). A run that waited for
# the archive comes back only after the hold's own 30s bound, tar done.
REAL_TAR=$(command -v tar)
rm -f "$W/tar-go"
cat > "$W/shim/tar" <<EOF
#!/bin/sh
n=0; while [ ! -e "$W/tar-go" ] && [ "\$n" -lt 300 ]; do sleep 0.1; n=\$((n + 1)); done
exec "$REAL_TAR" "\$@"
EOF
chmod +x "$W/shim/tar"
t0=$(date +%s)
FLEET_LOGIN_RESET_ASIDE='' run "$L" --apply
t1=$(date +%s)
[ "$(last2)" = 'reset: clean|credsep: separated' ] && st_ok 'H clean' || { tail -8 "$W/out"; fail "H: $(last2)"; }
[ -n "$(ls -d "$ARCH"/*.wash 2>/dev/null)" ] && [ -z "$(ls "$ARCH"/$L-*.tar.gz 2>/dev/null)" ] \
  && st_ok "H the run did not wait for the archive ($((t1 - t0))s, tar still held)" || fail "H the run waited for the archive ($((t1 - t0))s)"
touch "$W/tar-go"
n=0; while [ "$n" -lt 150 ] && [ -n "$(ls -d "$ARCH"/*.wash 2>/dev/null)" ]; do sleep 0.2; n=$((n + 1)); done
rm -f "$W/shim/tar"
[ -z "$(ls -d "$ARCH"/*.wash 2>/dev/null)" ] && [ -n "$(ls "$ARCH"/$L-*.tar.gz 2>/dev/null)" ] \
  && st_ok 'H the detached job archived and deleted the old home' || fail 'H the detached job did not finish'

# ---- T: the home template (issue #4194) ----
cat > "$W/tpl.py" <<'EOF'
import os, sys
open(os.environ["RS_LOG"], "a").write("tpl %s\n" % " ".join(sys.argv[1:]))
if sys.argv[1] == "clone":
    if os.environ.get("RS_TPL_RC") == "3":
        print("none 0123456789ab — no template for this version"); sys.exit(3)
    h = sys.argv[sys.argv.index("--home") + 1]
    os.makedirs(h); open(os.path.join(h, ".from-template"), "w").close()
    print("cloned 0123456789ab → %s (clonefile, 0.1s)" % h)
EOF
fixture
FLEET_LOGIN_RESET_TEMPLATE="$W/tpl.py" run "$L" --apply
[ "$(last2)" = 'reset: clean|credsep: separated' ] && [ "$RC" = 0 ] && st_ok 'T1 a template home: clean' || { tail -8 "$W/out"; fail "T1: $(last2) rc $RC"; }
[ -f "$H/.from-template" ] && st_ok 'T1 the home is the clone' || fail 'T1 the home is not the clone'
grep -q 'createhomedir' "$RS_LOG" && fail 'T1 createhomedir ran beside the clone' || st_ok 'T1 no createhomedir'
has "$RS_LOG" "tpl clone $L --home $H" 'T1 cloned for the login, into its home'
fixture
RS_TPL_RC=3 FLEET_LOGIN_RESET_TEMPLATE="$W/tpl.py" run "$L" --apply
[ "$(last2)" = 'reset: clean|credsep: separated' ] && [ "$RC" = 0 ] && st_ok 'T2 no template: clean the old way' || { tail -8 "$W/out"; fail "T2: $(last2) rc $RC"; }
has "$RS_LOG" "sudo createhomedir -c -u $L" 'T2 createhomedir made the home'
n=0; while [ "$n" -lt 50 ] && ! grep -q '^tpl build' "$RS_LOG"; do sleep 0.1; n=$((n + 1)); done
has "$RS_LOG" 'tpl build' 'T2 a template build started for the next wash'

# ---- R: root under the admin gate (issue #3723) ----
fixture
GD="$W/gate"; rm -rf "$GD"; mkdir -p "$GD/$L-onboard"; : > "$GD/$L-onboard/password.txt"
# root's `install -o 0`, played by the runner: the owner is dropped (as the sudo shim does)
mkdir -p "$W/shim-root"
cat > "$W/shim-root/install" <<'EOF'
#!/bin/sh
n=$#; i=0
while [ "$i" -lt "$n" ]; do a=$1; shift; i=$((i + 1)); if [ "$a" = -o ]; then shift; i=$((i + 1)); continue; fi; set -- "$@" "$a"; done
exec /usr/bin/install "$@"
EOF
chmod +x "$W/shim-root/install"
PATH="$W/shim-root:$PATH" FLEET_LOGIN_TEST_EUID=0 FLEET_LOGIN_ADMIN_DIR="$GD" FLEET_LOGIN_OP_ID=abc7 run "$L" --apply
[ "$(last2)" = 'reset: clean|credsep: separated' ] && [ "$RC" = 0 ] && st_ok 'R a root run washes clean' || { tail -12 "$W/out"; fail "R: $(last2) rc $RC"; }
[ "$(grep '^sudo ' "$RS_LOG" | grep -vc '^sudo -u ')" = 0 ] && st_ok 'R no step through sudo but the drops' || { grep '^sudo ' "$RS_LOG"; fail 'R a step went through sudo'; }
[ "$(grep '^  \$ sudo ' "$W/out" | grep -vc '^  \$ sudo -u ')" = 0 ] && st_ok 'R no shown step says sudo' || fail 'R a shown step still says sudo'
grep -q '^op=abc7' "$GD/$L-reset/op" 2>/dev/null && st_ok 'R the op book is the gate dir'"'"'s' || fail 'R no op book under the gate dir'
[ ! -e "$HOME/$L-reset" ] && st_ok 'R nothing in the admin'"'"'s home' || fail 'R a root run wrote the admin'"'"'s home'
gone "$GD/$L-onboard/password.txt" "R the gate dir's onboarding papers cleared"
has "$RS_LOG" "remove-adir $GD euid=0" 'R the stop runs as root under the gate too'
has "$RS_LOG" "new-adir $GD euid=0" 'R the rejoin runs as root under the gate too'
: > "$RS_LOG"
FLEET_LOGIN_TEST_EUID=0 run "$L" --apply
[ "$RC" = 3 ] && [ ! -s "$RS_LOG" ] && st_ok 'R root with no gate dir: 3, nothing run' || fail "R root with no gate dir: $RC"

fi

[ "$FAILS" = 0 ] || { printf 'fleet-login-reset-selftest: %s FAILED\n' "$FAILS"; exit 1; }
printf 'fleet-login-reset-selftest: PASS (section %s/2)\n' "$SELFTEST_SECTION"
