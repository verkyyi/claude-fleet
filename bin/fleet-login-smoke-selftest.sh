#!/bin/bash
# fleet-login-smoke-selftest.sh — bin/fleet-login-smoke.sh against PATH shims
# only (issue #1218, EPIC #1212 convention 2): no real login, no sudo, no ssh,
# no tmux server, no launchd. sudo / id / ssh / tmux / launchctl / dscl / ps /
# git are shims over a fixture directory, and fleet-login-new.sh /
# fleet-login-remove.sh beside the script under test are FAKES that build and
# tear down the fixture login (the real ones have their own selftests). The ssh
# shim plays the first login: it writes the login's global/ markers on a
# schedule picked per leg (FAKE_LOGIN), or prints a bootstrap FAIL, or exits,
# or hangs — the smoke's polling, its early failure detection and its timeout
# are exercised for real, on a 0.2s poll.
#
# What it pins:
#   A. usage       bad login / bad number / unknown flag → 2; no sudo ticket →
#                  2 naming `sudo -v`; an existing login → 3; nothing run
#   B. happy path  every step PASS, exit 0: login-new run FROM $HOME with
#                  --share-pool --apply and no --pubkey; ssh -tt with the
#                  temporary key on the run's own tmux socket; guide.spoke then
#                  onboarded; the guide pane captured AS THE LOGIN on its socket
#                  and printed; doctor `needs:` minus the person's own = 0;
#                  daemons N/N; login-remove --apply (default path) from $HOME,
#                  its archive verified then removed; nothing left; ~<login>-
#                  onboard/ removed; the three readings; the run's tmux server
#                  killed
#   C. --keep      offboard + residue SKIPPED with the remove command printed;
#                  the login, its onboard dir and the archive-less state stay
#   D. flags       --delete-home / --no-share-pool / --lang en pass through
#   E–O. one failing step each, and on EVERY one the teardown still runs
#                  (login-remove is called, or --keep said not to), exit 1:
#                  login-new fails (E) · bootstrap `apply: FAIL` in the pane —
#                  detected before the timeout (G) · ssh exits (I) · timeout (J)
#                  · guide never speaks (F) · onboarded before guide.spoke —
#                  #1210 ③ (H) · `Unknown command` in the guide pane (N) ·
#                  doctor leaves a step (M) · one daemon not loaded (L) ·
#                  login-remove fails → residue reported, onboard dir kept (K) ·
#                  a group entry left (O) · a letter without the key (P)
#   Q. bash 3.2    the whole thing runs under /bin/bash where that is 3.2
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/fleet-login-smoke.sh" ] || { printf 'selftest: %s/fleet-login-smoke.sh not found\n' "$BIN" >&2; exit 2; }
BASH_BIN=/bin/bash; [ -x "$BASH_BIN" ] || BASH_BIN=bash

WORK=$(mktemp -d "${TMPDIR:-/tmp}/login-smoke-selftest.XXXXXX") || exit 2
WORK=$(cd "$WORK" && pwd -P)
ST="$WORK/state"
cleanup() {
  : > "$ST/stop" 2>/dev/null
  for p in "$ST"/pid.*; do
    [ -f "$p" ] || continue
    pid=$(cat "$p"); pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
  done
  rm -rf "${WORK:?}"
}
trap cleanup EXIT INT TERM HUP
mkdir -p "$WORK/bin" "$WORK/shim" "$WORK/homes" "$WORK/LaunchDaemons" "$WORK/admin" "$WORK/ds/groups" "$WORK/tmpl" "$ST"
cp "$BIN/fleet-login-smoke.sh" "$WORK/bin/"
cp "$BIN/../launchd/"com.claude-fleet.*.plist.tmpl "$WORK/tmpl/" 2>/dev/null
NTMPL=0; for t in "$WORK/tmpl"/*.tmpl; do [ -e "$t" ] && NTMPL=$((NTMPL + 1)); done
[ "$NTMPL" -gt 0 ] || { printf 'selftest FAIL: no launchd/*.plist.tmpl beside bin/\n' >&2; exit 1; }
S="$WORK/bin/fleet-login-smoke.sh"
LOG="$ST/calls.log"
export FLEET_LOGIN_HOMES="$WORK/homes" FLEET_INSTALL_DAEMON_DIR="$WORK/LaunchDaemons" HOME="$WORK/admin"
export FLEET_TEST_LOG="$LOG" FLEET_TEST_STATE="$ST" FLEET_TEST_TMPL="$WORK/tmpl" FLEET_TEST_DS="$WORK/ds" FLEET_TEST_ARCH="$WORK/offboarded"
export FLEET_SMOKE_POLL_SECS=0.2 FLEET_SMOKE_ONBOARD_SECS=2 FLEET_SMOKE_TIMEOUT=3
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
export PATH="$WORK/shim:$PATH"

# --- the fakes beside the script under test ------------------------------------
cat > "$WORK/bin/fleet-login-new.sh" <<'EOF'
#!/bin/sh
# FAKE fleet-login-new.sh: builds the fixture login. FAKE_NEW=fail → the login
# is half-made (home exists) and the script exits 1 at "step 8".
echo "login-new cwd=$PWD args=$*" >> "$FLEET_TEST_LOG"
LOGIN=$1; H="$FLEET_LOGIN_HOMES/$LOGIN"; ST=$FLEET_TEST_STATE
mkdir -p "$H/.ssh" "$H/.config/claude-fleet/fleets/fleet" "$H/.claude/fleet/launchd" "$H/.claude/fleet/bin"
cp "$FLEET_TEST_TMPL"/*.tmpl "$H/.claude/fleet/launchd/"
printf 'FLEET_REPO=verkyyi/claude-fleet\n' > "$H/.config/claude-fleet/fleets/fleet/conf"
cat > "$H/.claude/fleet/bin/fleet-doctor-onboard.sh" <<'DOC'
#!/bin/sh
d=${FAKE_DOCTOR:-'needs: GitHub login (gh auth login), Codex LOGIN valid (ccquota codex login), replace temporary SSH key'}
printf '%s\n' "$d"; case "$d" in ready:*) exit 0 ;; esac; exit 1
DOC
: > "$ST/live.fleet"          # the login's fleet server (tmux -L fleet) is up
O="$HOME/$LOGIN-onboard"; mkdir -p "$O"; chmod 700 "$O"
printf 'pw\n' > "$O/password.txt"; chmod 600 "$O/password.txt"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE\n-----END OPENSSH PRIVATE KEY-----\n' > "$O/id_ed25519"; chmod 600 "$O/id_ed25519"
printf 'ssh-ed25519 AAAAFAKE %s-onboard-temp\n' "$LOGIN" > "$O/id_ed25519.pub"
host=mini.example; [ "${FAKE_WELCOME:-full}" = nohost ] && host='<HOST>'
{
  printf '你好：\n\n1. 怎么连\n\n   ssh -p 22022 %s@%s\n\n2. 钥匙\n\n' "$LOGIN" "$host"
  [ "${FAKE_WELCOME:-full}" = nokey ] || cat "$O/id_ed25519"
  printf '\n3. ssh config 片段\n\nHost mini\n  HostName %s\n  Port 22022\n  User %s\n\n4. 换成你自己的钥匙\n      ssh-copy-id -i ~/.ssh/mini-own.pub ...\n\n5. 向导与 cf\n   - 向导窗口关了、或想再开：cf --guide\n' "$host" "$LOGIN"
} > "$O/welcome.txt"; chmod 600 "$O/welcome.txt"
n=0
for t in "$FLEET_TEST_TMPL"/*.tmpl; do
  u=${t##*/com.claude-fleet.}; u=${u%.plist.tmpl}
  : > "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.$LOGIN.$u.plist"
  if [ "${FAKE_DAEMONS_SHORT:-}" = "$u" ]; then continue; fi
  printf -- '-\t0\tcom.claude-fleet.%s.%s\n' "$LOGIN" "$u" >> "$ST/launchd.list"
  n=$((n + 1))
done
g="$FLEET_TEST_DS/groups/com.apple.access_ssh"
printf 'GroupMembership: admin1 %s\nGroupMembers: GUID-ADMIN1 GUID-%s\n' "$LOGIN" "$LOGIN" > "$g"
if [ "${FAKE_NEW:-ok}" = fail ]; then
  echo "fleet-login-new: FAILED at step 8 — stopped; nothing after it ran" >&2; exit 1
fi
total=$(ls "$FLEET_TEST_TMPL" | wc -l | tr -d ' ')
printf '[8] install %s background services\n  installed %s/%s\n\ndone: login %s created.\n' "$LOGIN" "$total" "$total" "$LOGIN"
EOF
cat > "$WORK/bin/fleet-login-remove.sh" <<'EOF'
#!/bin/sh
# FAKE fleet-login-remove.sh. FAKE_REMOVE=fail → exit 1, nothing removed;
# =leavegroup → everything but the access_ssh entry.
echo "login-remove cwd=$PWD args=$*" >> "$FLEET_TEST_LOG"
LOGIN=$1; H="$FLEET_LOGIN_HOMES/$LOGIN"; ST=$FLEET_TEST_STATE
if [ "${FAKE_REMOVE:-ok}" = fail ]; then echo 'fleet-login-remove: failed; stopped before deleting the login' >&2; exit 1; fi
rm -f "$ST/live.fleet" "$FLEET_INSTALL_DAEMON_DIR"/com.claude-fleet."$LOGIN".*.plist
grep -v "com.claude-fleet.$LOGIN\." "$ST/launchd.list" > "$ST/launchd.new" 2>/dev/null; mv "$ST/launchd.new" "$ST/launchd.list"
rm -rf "$H"
[ "${FAKE_REMOVE:-ok}" = leavegroup ] || printf 'GroupMembership: admin1\nGroupMembers: GUID-ADMIN1\n' > "$FLEET_TEST_DS/groups/com.apple.access_ssh"
case " $* " in
  *' --delete-home '*) printf '  home-policy=delete\n' ;;
  *) mkdir -p "$FLEET_TEST_ARCH"; a="$FLEET_TEST_ARCH/$LOGIN-20260925T000000Z.tar.gz"; : > "$a"; chmod 600 "$a"
     printf 'fleet-login-remove: done\n  archive=%s (4.0K)  (600, owned by uid 501; --delete-home skips it)\n' "$a"; exit 0 ;;
esac
printf 'fleet-login-remove: done\n'
EOF

# --- shims -----------------------------------------------------------------------
cat > "$WORK/shim/sudo" <<'EOF'
#!/bin/sh
# sudo -n -v: the ticket check · sudo -n [-u <login> -H] <cmd…>: run it as us
echo "sudo $*" >> "$FLEET_TEST_LOG"
[ "$1" = -n ] && shift
if [ "${1:-}" = -v ]; then exit "${FAKE_SUDO_NV_FAIL:-0}"; fi
if [ "${1:-}" = -u ]; then shift 2; [ "${1:-}" = -H ] && shift; fi
exec "$@"
EOF
cat > "$WORK/shim/id" <<'EOF'
#!/bin/sh
# a login exists ⇔ its fixture home exists (or a leftover record marker)
case "$1" in -u) l=$2 ;; *) l=$1 ;; esac
if [ -d "$FLEET_LOGIN_HOMES/$l" ] || [ -e "$FLEET_TEST_STATE/record.$l" ]; then
  [ "$1" = -u ] && echo 602 || echo "uid=602($l)"; exit 0
fi
echo "id: $l: no such user" >&2; exit 1
EOF
cat > "$WORK/shim/ssh" <<'EOF'
#!/bin/sh
# the first login, on a schedule (FAKE_LOGIN): writes <login>'s global/ markers
echo "ssh $*" >> "$FLEET_TEST_LOG"
for last; do :; done
LOGIN=${last%@*}; G="$FLEET_LOGIN_HOMES/$LOGIN/.config/claude-fleet/global"; mkdir -p "$G"
stamp() { date '+%Y-%m-%d %H:%M:%S' > "$G/$1"; }
park() { while [ ! -e "$FLEET_TEST_STATE/stop" ]; do sleep 0.2; done; exit 0; }
sleep "${FAKE_SSH_DELAY:-0.1}"
case "${FAKE_LOGIN:-ok}" in
  refused) echo 'ssh: connect to host 127.0.0.1 port 22: Connection refused' >&2; exit 255 ;;
  hang) park ;;
  applyfail) echo 'fleet-login-bootstrap: install: ok'; echo 'fleet-login-bootstrap: apply: FAIL no GUI session for smokey yet'; park ;;
  noapply) stamp bootstrapped; park ;;
  silent) stamp bootstrap.applied; stamp bootstrapped; park ;;
  unconfirmed) stamp bootstrap.applied; stamp bootstrapped; stamp guide.spoke; park ;;
  premature) stamp bootstrap.applied; stamp onboarded; stamp bootstrapped; park ;;
  ok) echo 'fleet-login-bootstrap: apply: ok'; stamp bootstrap.applied; stamp bootstrapped; stamp guide.spoke
      sleep "${FAKE_ONBOARD_DELAY:-0.2}"; stamp onboarded; echo 'fleet-up: opened the onboarding guide'; park ;;
esac
EOF
cat > "$WORK/shim/tmux" <<'EOF'
#!/bin/sh
# tmux -L <label> <cmd…> over the fixture: the run's own server runs its command
# in the background and its "pane" is the command's output; the login's fleet
# server (-L fleet) is "live" while state/live.fleet exists, and its guide
# window is the state/guide.txt fixture.
echo "tmux $*" >> "$FLEET_TEST_LOG"
L=default; [ "$1" = -L ] && { L=$2; shift 2; }
ST=$FLEET_TEST_STATE
case "$1" in
  new-session)
    for last; do :; done
    ( exec sh -c "$last" ) > "$ST/pane.$L" 2>&1 &
    echo $! > "$ST/pid.$L" ;;
  has-session)
    if [ -f "$ST/pid.$L" ]; then kill -0 "$(cat "$ST/pid.$L")" 2>/dev/null; else [ -e "$ST/live.$L" ]; fi ;;
  capture-pane)
    for last; do :; done
    case "$last" in
      *:guide) [ -e "$ST/live.$L" ] || { echo "no server running on /tmp/tmux-602/$L" >&2; exit 1; }
               [ -f "$ST/guide.txt" ] || { echo "can't find window: guide" >&2; exit 1; }
               cat "$ST/guide.txt" ;;
      *) cat "$ST/pane.$L" 2>/dev/null ;;
    esac ;;
  kill-server)
    if [ -f "$ST/pid.$L" ]; then p=$(cat "$ST/pid.$L"); : > "$ST/stop"; pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; rm -f "$ST/pid.$L"; fi ;;
esac
exit 0
EOF
cat > "$WORK/shim/launchctl" <<'EOF'
#!/bin/sh
echo "launchctl $*" >> "$FLEET_TEST_LOG"
case "$1" in list) printf 'PID\tStatus\tLabel\n'; cat "$FLEET_TEST_STATE/launchd.list" 2>/dev/null ;; esac
exit 0
EOF
cat > "$WORK/shim/dscl" <<'EOF'
#!/bin/sh
DS=$FLEET_TEST_DS
case "$2" in
  -list) ls "$DS/groups" ;;
  -read) case "$3" in
           /Users/*) l=${3#/Users/}; [ "${4:-}" = GeneratedUID ] && echo "GeneratedUID: GUID-$l" ;;
           /Groups/*) f="$DS/groups/${3#/Groups/}"; [ -f "$f" ] || exit 56; grep "^${4:-}" "$f" ;;
         esac ;;
esac
exit 0
EOF
cat > "$WORK/shim/ps" <<'EOF'
#!/bin/sh
cat "$FLEET_TEST_STATE/ps.txt" 2>/dev/null
EOF
cat > "$WORK/shim/git" <<'EOF'
#!/bin/sh
echo "git $*" >> "$FLEET_TEST_LOG"
echo abc1234
EOF
chmod +x "$WORK/shim/"* "$WORK/bin/"*.sh

# --- harness -----------------------------------------------------------------------
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -z "${OUT:-}" ] || printf '%s\n' "--- output ---" "$OUT" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — missing [$3]" ;; esac; }
not_has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — unexpectedly has [$3]" ;; esac; }
has_re() { CHECKS=$((CHECKS + 1)); printf '%s\n' "$2" | grep -Eq -- "$3" || fail "$1 — no line matches /$3/"; }
called() { CHECKS=$((CHECKS + 1)); grep -q -- "$2" "$LOG" || fail "$1 — never called: $2"; }
not_called() { CHECKS=$((CHECKS + 1)); ! grep -q -- "$2" "$LOG" || fail "$1 — unexpectedly called: $2"; }
reset() {
  : > "$ST/stop"
  for p in "$ST"/pid.*; do [ -f "$p" ] && { pid=$(cat "$p"); pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }; done
  rm -rf "${WORK:?}/homes"/* "${WORK:?}/LaunchDaemons"/* "${WORK:?}/admin"/* "${WORK:?}/offboarded" "${ST:?}"/* "${WORK:?}/tmp"/*
  printf 'GroupMembership: admin1\nGroupMembers: GUID-ADMIN1\n' > "$WORK/ds/groups/com.apple.access_ssh"
  printf 'GroupMembership: admin1\nGroupMembers: GUID-ADMIN1\n' > "$WORK/ds/groups/com.apple.access_screensharing"
  printf '  ✻ Welcome to the fleet, smokey!\n\n  This fleet hosts:\n    verkyyi/claude-fleet  (starter)\n\n  Shall we add your own repo?\n' > "$ST/guide.txt"
  : > "$LOG"
}
run() { reset; OUT=$("$BASH_BIN" "$S" --login smokey "$@" 2>&1); RC=$?; }
L=smokey; H="$WORK/homes/$L"; OB="$HOME/$L-onboard"

# --- A. usage / preflight: nothing runs ------------------------------------------
reset
OUT=$("$BASH_BIN" "$S" --login 'Bad Name' 2>&1); eq 'A bad login exit' 2 $?
has 'A bad login says so' "$OUT" 'bad login name'
OUT=$("$BASH_BIN" "$S" --login ok --timeout x 2>&1); eq 'A bad timeout exit' 2 $?
OUT=$("$BASH_BIN" "$S" --bogus 2>&1); eq 'A unknown flag exit' 2 $?
OUT=$("$BASH_BIN" "$S" --login ok --lang fr 2>&1); eq 'A bad lang exit' 2 $?
OUT=$(FAKE_SUDO_NV_FAIL=1 "$BASH_BIN" "$S" --login smokey 2>&1); eq 'A no ticket exit' 2 $?
has 'A no ticket names sudo -v' "$OUT" "run 'sudo -v' first"
mkdir -p "$H"
OUT=$("$BASH_BIN" "$S" --login smokey 2>&1); eq 'A existing login exit' 3 $?
has 'A existing login says so' "$OUT" 'already exists'
not_called 'A existing login: login-new never run' 'login-new'
not_called 'A existing login: no ssh' 'ssh '
rm -rf "$H"

# --- B. the happy path ---------------------------------------------------------
run
eq 'B exit' 0 "$RC"
has 'B banner' "$OUT" "fleet-login-smoke: login=smokey  ssh=127.0.0.1:22  share-pool=yes  timeout=3s  offboard=archive"
has 'B open' "$OUT" "PASS  open      fleet-login-new.sh smokey --full-name 'Smoke Test (smokey)' --lang zh --share-pool --apply (from $HOME, a 0700 dir — #1210 ④): ok · daemons installed $NTMPL/$NTMPL · clone stable=abc1234"
called 'B login-new from the admin home' "login-new cwd=$HOME args=smokey --full-name Smoke Test (smokey) --lang zh --share-pool --apply"
has 'B welcome' "$OUT" "PASS  welcome   $OB/welcome.txt (600): host mini.example port 22022 · temporary key inline · ssh config · key swap · cf --guide"
not_has 'B welcome: no WARN' "$OUT" 'WARN host'
has_re 'B login' "$OUT" '^PASS  login     ssh -tt smokey@127.0.0.1:22 \(temporary key\): bootstrapped after [0-9]+s · bootstrap.applied ok \(#1210 ②\)$'
called 'B ssh with the temporary key' "ssh -tt -i $OB/id_ed25519 -p 22 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 smokey@127.0.0.1"
called 'B own tmux server' 'tmux -L fleet-smoke-smokey new-session -d -s smoke -x 200 -y 50 '
has_re 'B guide' "$OUT" '^PASS  guide     guide.spoke \+[0-9]+s after bootstrapped · onboarded \+[0-9]+s \(#1210 ③: written only after it spoke\)$'
has 'B capture' "$OUT" 'PASS  capture   tmux -L fleet capture-pane -p -t fleet:guide (as smokey): 4 lines — the guide pane:'
has 'B capture printed inline' "$OUT" '        │   ✻ Welcome to the fleet, smokey!'
has 'B capture printed the repo list' "$OUT" '        │     verkyyi/claude-fleet  (starter)'
called 'B capture as the login on its socket' 'sudo -n -u smokey -H env HOME='"$H"' TMUX= tmux -L fleet capture-pane -p -t fleet:guide'
has 'B doctor' "$OUT" 'PASS  doctor    manual steps left after opening: 0 — onboard row: needs: GitHub login (gh auth login), Codex LOGIN valid (ccquota codex login), replace temporary SSH key (GitHub / Codex / the temporary-key swap are the person'"'"'s own)'
has 'B daemons' "$OUT" "PASS  daemons   loaded $NTMPL/$NTMPL system/com.claude-fleet.smokey.* · $NTMPL plists in $WORK/LaunchDaemons (#1210 ①)"
has 'B offboard' "$OUT" "PASS  offboard  fleet-login-remove.sh smokey --apply (from $HOME; default path = archive then delete, #1210 ⑤): ok · archive $WORK/offboarded/smokey-20260925T000000Z.tar.gz (600) verified, then removed — a smoke login's home"
called 'B login-remove from the admin home' "login-remove cwd=$HOME args=smokey --apply"
[ ! -e "$WORK/offboarded/smokey-20260925T000000Z.tar.gz" ] || fail 'B the archive was not removed'
has 'B residue' "$OUT" 'PASS  residue   none: no login record, no home, no plist, no loaded service, no process, not in any com.apple.access_* group'
has_re 'B summary' "$OUT" '^fleet-login-smoke: PASS  9 passed · 0 skipped · [0-9]+s · log '"$WORK"'/tmp/fleet-login-smoke\.smokey\.'
has 'B reading 1' "$OUT" '  manual steps left after opening (开号后还要人手工补的步骤): 0'
has 'B reading 2' "$OUT" "  #1210 defects still open (上一批实跑查出、还没修的缺陷): 0/5  — ① daemons $NTMPL/$NTMPL loaded · ② first-login apply ok · ③ onboarded ok (onboarded only after guide.spoke) · ④ open from a 0700 cwd ok (ran from $HOME) · ⑤ offboard ok"
has 'B reading 3' "$OUT" '  letters to write by hand (开完号后要自己写给新人的说明): 0  — welcome.txt ok (host mini.example, port 22022)'
called 'B own server killed' 'tmux -L fleet-smoke-smokey kill-server'
[ ! -e "$OB" ] || fail 'B ~/<login>-onboard was not removed'
[ ! -e "$H" ] || fail 'B home remains'
[ ! -f "$ST/pid.fleet-smoke-smokey" ] || fail 'B the run'"'"'s tmux pid file remains'
python3 - "$LOG" <<'PY' || fail 'B wrong order: open → ssh → capture → remove → kill-server'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
def at(s): return next(i for i, l in enumerate(lines) if l.startswith(s))
assert at('login-new cwd=') < at('tmux -L fleet-smoke-smokey new-session') < at('ssh -tt') < at('sudo -n -u smokey -H env HOME=') < at('sudo -n launchctl list') < at('tmux -L fleet-smoke-smokey kill-server') < at('login-remove cwd=')
PY
[ "${FLEET_SMOKE_SELFTEST_SHOW:-0}" = 0 ] || printf '%s\n' "$OUT"   # the happy-path transcript, for the eye
# the log dir keeps every transcript + capture
RUNDIR=$(printf '%s\n' "$OUT" | sed -n 's/^fleet-login-smoke: log dir //p')
for f in login-new.log login-remove.log guide-pane.txt doctor-onboard.txt ssh-pane.txt; do
  [ -f "$RUNDIR/$f" ] || fail "B log dir lacks $f"
done

# --- C. --keep -----------------------------------------------------------------
run --keep
eq 'C exit' 0 "$RC"
has 'C banner' "$OUT" 'offboard=keep (no offboarding)'
has 'C offboard skipped' "$OUT" "SKIP  offboard  --keep: login smokey stays up for a look — offboard it with: $WORK/bin/fleet-login-remove.sh smokey --apply  (its key, password and letter: $OB)"
has 'C residue skipped' "$OUT" 'SKIP  residue   --keep'
not_called 'C login-remove not run' 'login-remove'
called 'C own server still killed' 'kill-server'
[ -d "$H" ] || fail 'C --keep removed the home'
[ -f "$OB/id_ed25519" ] || fail 'C --keep removed the onboard dir'
has 'C summary' "$OUT" 'PASS  7 passed · 2 skipped'
has 'C reading 2' "$OUT" '· ⑤ offboard skipped (--keep)'

# --- D. flags pass through ---------------------------------------------------------
run --delete-home --no-share-pool --lang en
eq 'D exit' 0 "$RC"
has 'D banner' "$OUT" 'share-pool=no  timeout=3s  offboard=delete-home'
called 'D login-new flags' 'login-new cwd='"$HOME"' args=smokey --full-name Smoke Test (smokey) --lang en --apply'
called 'D login-remove --delete-home' 'login-remove cwd='"$HOME"' args=smokey --delete-home --apply'
has 'D offboard line' "$OUT" 'PASS  offboard  fleet-login-remove.sh smokey --delete-home --apply (from '"$HOME"'; default path = archive then delete, #1210 ⑤): ok'
not_has 'D no archive talk' "$OUT" 'verified, then removed'
[ ! -e "$WORK/offboarded" ] || fail 'D --delete-home produced an archive'

# --- E. login-new fails: no ssh, but the half-made login is still offboarded --------
FAKE_NEW=fail run
eq 'E exit' 1 "$RC"
has 'E open failed' "$OUT" "FAIL  open      fleet-login-new.sh smokey --full-name 'Smoke Test (smokey)' --lang zh --share-pool --apply (from $HOME): exit 1 — fleet-login-new: FAILED at step 8 — stopped; nothing after it ran"
not_called 'E no ssh' 'ssh -tt'
not_called 'E no own tmux' 'new-session'
called 'E half-made login offboarded' 'login-remove cwd='"$HOME"' args=smokey --apply'
has 'E offboard' "$OUT" 'PASS  offboard'
has 'E residue' "$OUT" 'PASS  residue'
has 'E summary' "$OUT" 'fleet-login-smoke: FAIL  2 passed · 1 failed · 0 skipped'
has 'E reading 2' "$OUT" '#1210 defects still open (上一批实跑查出、还没修的缺陷): 4/5  — ① daemons ? · ② first-login apply ? · ③ onboarded ? · ④ open from a 0700 cwd FAILED (exit 1, from '"$HOME"') · ⑤ offboard ok'
has 'E reading 1' "$OUT" '手工补的步骤): ?'
[ ! -e "$OB" ] || fail 'E onboard dir kept after the login was removed'

# --- F. the guide never speaks ----------------------------------------------------
FAKE_LOGIN=silent run
eq 'F exit' 1 "$RC"
has 'F login passed' "$OUT" 'PASS  login     ssh -tt smokey@127.0.0.1:22 (temporary key): bootstrapped after'
has 'F guide' "$OUT" 'FAIL  guide     the guide never spoke: no global/guide.spoke within 2s of bootstrapped (#1215) — ssh pane tail:'
has 'F the rest still ran' "$OUT" 'PASS  capture'
has 'F doctor still ran' "$OUT" 'PASS  doctor'
called 'F teardown' 'login-remove cwd='
has 'F summary' "$OUT" 'FAIL  8 passed · 1 failed'
has 'F reading' "$OUT" '③ onboarded guide never spoke'

# --- G. bootstrap FAIL in the pane: detected long before the timeout ---------------
T=$SECONDS; FAKE_LOGIN=applyfail run; T=$((SECONDS - T))
eq 'G exit' 1 "$RC"
has 'G login' "$OUT" 'FAIL  login     first login via ssh -tt: bootstrap failed after'
has 'G names the step' "$OUT" 'fleet-login-bootstrap: apply: FAIL no GUI session for smokey yet'
has 'G pane tail' "$OUT" '        │ fleet-login-bootstrap: install: ok'
[ "$T" -lt 3 ] || fail "G did not fail early: ${T}s against a 3s timeout"
has 'G guide: one look, no wait' "$OUT" 'FAIL  guide     the guide never spoke'
has 'G capture still attempted' "$OUT" '  capture   '
called 'G teardown' 'login-remove cwd='
has 'G reading' "$OUT" '② first-login apply ?'

# --- H. onboarded before the guide spoke (#1210 ③) --------------------------------
FAKE_LOGIN=premature run
eq 'H exit' 1 "$RC"
has 'H guide' "$OUT" 'FAIL  guide     global/onboarded is written but global/guide.spoke is not — a guide that never spoke counted as onboarded (#1210 ③)'
has 'H reading' "$OUT" '③ onboarded VIOLATED (onboarded before guide.spoke)'
called 'H teardown' 'login-remove cwd='

# --- H2. spoke, never confirmed -----------------------------------------------------
FAKE_LOGIN=unconfirmed run
eq 'H2 exit' 1 "$RC"
has 'H2 guide' "$OUT" 'but global/onboarded not written within 2s — nobody confirmed it (fleet-up'"'"'s wait, or com.claude-fleet.smokey.collect — is it loaded?)'
has 'H2 reading' "$OUT" '③ onboarded spoke, never confirmed'

# --- H3. bootstrapped without bootstrap.applied (#1210 ②) ----------------------------
FAKE_LOGIN=noapply run
eq 'H3 exit' 1 "$RC"
has 'H3 login' "$OUT" 'but no global/bootstrap.applied (#1210 ②: the apply did not pass)'
has 'H3 reading' "$OUT" '② first-login apply missing'

# --- I. ssh exits before anything -----------------------------------------------
FAKE_LOGIN=refused run
eq 'I exit' 1 "$RC"
has 'I login' "$OUT" 'FAIL  login     first login via ssh -tt: ssh exited before global/bootstrapped ([fleet-login-smoke] ssh exited 255)'
has 'I pane tail' "$OUT" '        │ ssh: connect to host 127.0.0.1 port 22: Connection refused'
called 'I teardown' 'login-remove cwd='

# --- J. timeout ---------------------------------------------------------------------
FAKE_LOGIN=hang run --timeout 2
eq 'J exit' 1 "$RC"
has 'J login' "$OUT" 'FAIL  login     first login via ssh -tt: no global/bootstrapped after 2s (--timeout)'
called 'J teardown' 'login-remove cwd='
called 'J own server killed' 'kill-server'
[ ! -f "$ST/pid.fleet-smoke-smokey" ] || fail 'J the hung ssh was not killed'

# --- K. login-remove fails: residue reported, the key kept for a look ---------------
FAKE_REMOVE=fail run
eq 'K exit' 1 "$RC"
has 'K offboard' "$OUT" "FAIL  offboard  fleet-login-remove.sh smokey --apply (from $HOME): exit 1 — fleet-login-remove: failed; stopped before deleting the login"
has 'K residue' "$OUT" "FAIL  residue   left behind: · login record · home $H · $NTMPL plist(s) in $WORK/LaunchDaemons · $NTMPL loaded service(s) · com.apple.access_ssh lists smokey · com.apple.access_ssh lists its GUID"
has 'K key kept' "$OUT" "        kept $OB (its key still opens the login that is still there)"
[ -f "$OB/id_ed25519" ] || fail 'K onboard dir removed although the login remains'
has 'K summary' "$OUT" 'FAIL  7 passed · 2 failed'
has 'K reading' "$OUT" '⑤ offboard FAILED (exit 1)'

# --- L. one daemon not loaded --------------------------------------------------------
FAKE_DAEMONS_SHORT=collect run
eq 'L exit' 1 "$RC"
has 'L daemons' "$OUT" "FAIL  daemons   loaded $((NTMPL - 1))/$NTMPL system/com.claude-fleet.smokey.* — not loaded: collect · $NTMPL plists in $WORK/LaunchDaemons (#1210 ①)"
called 'L teardown' 'login-remove cwd='
has 'L reading' "$OUT" "1/5  — ① daemons $((NTMPL - 1))/$NTMPL loaded"   # login-new said N/N installed; what is LOADED is the verdict
has 'L summary' "$OUT" 'FAIL  8 passed · 1 failed'

# --- M. the doctor leaves a step that is not the person's own ---------------------------
FAKE_DOCTOR='needs: daemon collect, GitHub login (gh auth login), Codex LOGIN valid (ccquota codex login)' run
eq 'M exit' 1 "$RC"
has 'M doctor' "$OUT" 'FAIL  doctor    manual steps left after opening: 1 — · daemon collect (onboard row: needs: daemon collect, GitHub login (gh auth login), Codex LOGIN valid (ccquota codex login))'
has 'M reading' "$OUT" '手工补的步骤): 1'
FAKE_DOCTOR='ready: Claude, accounts, GitHub, Codex, SSH, daemons, guide' run
eq 'M2 exit' 0 "$RC"
has 'M2 doctor ready' "$OUT" 'PASS  doctor    manual steps left after opening: 0 — onboard row: ready:'

# --- N. `Unknown command` in the guide pane ------------------------------------------
reset; printf '> /fleet-onboard\n\n  Unknown command: /fleet-onboard\n\n> \n' > "$ST/guide.txt"
OUT=$("$BASH_BIN" "$S" --login smokey 2>&1); RC=$?
eq 'N exit' 1 "$RC"
has 'N capture' "$OUT" "FAIL  capture   fleet:guide (as smokey) shows 'Unknown command' — the guide's /fleet-onboard is not installed (#1210 ②/③):"
has 'N pane shown' "$OUT" '        │   Unknown command: /fleet-onboard'
called 'N teardown' 'login-remove cwd='
# no guide window at all
reset; rm -f "$ST/guide.txt"
OUT=$("$BASH_BIN" "$S" --login smokey 2>&1); RC=$?
eq 'N2 exit' 1 "$RC"
has 'N2 capture' "$OUT" "FAIL  capture   tmux -L fleet capture-pane -t fleet:guide (as smokey): can't find window: guide"

# --- O. an access group entry left after offboarding -----------------------------------
FAKE_REMOVE=leavegroup run
eq 'O exit' 1 "$RC"
has 'O residue' "$OUT" 'FAIL  residue   left behind: · com.apple.access_ssh lists smokey · com.apple.access_ssh lists its GUID'
has 'O reading' "$OUT" '⑤ offboard ok, but residue: · com.apple.access_ssh lists smokey'
# a process of its uid left
reset; printf '  501\n  602\n' > "$ST/ps.txt"
OUT=$("$BASH_BIN" "$S" --login smokey 2>&1); RC=$?
eq 'O2 exit' 1 "$RC"
has 'O2 residue' "$OUT" 'FAIL  residue   left behind: · 1 process(es) of uid 602'

# --- P. the letter -------------------------------------------------------------------
FAKE_WELCOME=nokey run
eq 'P exit' 1 "$RC"
has 'P welcome' "$OUT" "FAIL  welcome   $OB/welcome.txt: missing private-key"
has 'P reading' "$OUT" '说明): 1  — welcome.txt incomplete: private-key'
has 'P the rest ran' "$OUT" 'PASS  login'
FAKE_WELCOME=nohost run
eq 'P2 exit' 0 "$RC"
has 'P2 WARN, not FAIL' "$OUT" 'PASS  welcome   '"$OB"'/welcome.txt (600): host <HOST> port 22022 · temporary key inline · ssh config · key swap · cf --guide · WARN host is the <HOST> placeholder — set FLEET_SSH_PUBLIC_HOST'

# --- Q. -v streams the child transcripts -------------------------------------------------
run -v
eq 'Q exit' 0 "$RC"
has 'Q login-new streamed' "$OUT" "        │   installed $NTMPL/$NTMPL"
has 'Q login-remove streamed' "$OUT" '        │ fleet-login-remove: done'

# shellcheck disable=SC2016  # the expansion is the child bash's on purpose
printf 'fleet-login-smoke-selftest: PASS (%d checks, bash %s)\n' "$CHECKS" "$("$BASH_BIN" -c 'echo ${BASH_VERSION%%(*}')"
