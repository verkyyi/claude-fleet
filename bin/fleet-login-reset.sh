#!/bin/bash
# fleet-login-reset.sh <login> [--keep-home|--delete-home] [--archive-dir <dir>] [--apply]
# Wash a Mac login for the next person (issue #3505, EPIC #3500 C20): what the
# last person left is gone, the fleet and its credential separation are set up
# again, and the OS user itself is KEPT — no sysadminctl, the record and its UID
# stay (deleting a user is minutes and a system prompt; making one is more).
# It is what `fleet-login-remove.sh <login> --recycle` runs — the hub's reset op
# (#3504) — so it needs no sudoers line of its own. Dry run by default; run as
# the admin login, from anywhere.
#
#   1 stop     fleet-login-remove.sh --recycle-stop --quick: off the hub (in
#              the background), `account forget`, its services booted out, its
#              credsep purged, the pool copy gone — no fleet-down, no quiesce,
#              no archive there (issue #4044: the wash does those, faster).
#   2 wash     the login quiesced (KILL, its launchd domains booted out, KILL —
#              polled, no grace: issue #4044) and only then the clock (--since)
#              started (issue #3979); the home RENAMED aside into the archive dir
#              (instant, out of the login's reach at once) — archived there
#              (--keep-home, once per op) and deleted by a detached job, off the
#              clock; quiesced once more; then all at once: a fresh home from
#              the template (createhomedir, 700); the admin's ~/<login>-onboard;
#              its crontab; root's entry keys and task state for it (<node
#              state>/entry/keys/<login>, logins/<login>/); a credsep store left
#              over; any LaunchDaemon whose UserName it is; every file it owns in
#              /private/tmp, /private/var/tmp, /Users/Shared (the archive dir
#              excepted) — tmux sockets with them; and its per-uid temp + cache
#              dir /private/var/folders/<xx>/<yy>/ (its $TMPDIR — the uid stays,
#              so it did too: issue #4044), emptied to its C/T/0 skeleton.
#   3 check    fleet-login-reset-check.py <login> --since <the wash's start>:
#              only what predates the wash counts. Before the rejoin (#4044): a
#              dirty login is never set up again or handed a join code.
#   4 rejoin   fleet-login-new.sh <login> --recycle --share-pool: a new random
#              password, the key and the letter, the install, the hub's join
#              code (FLEET_LOGIN_JOIN_CODE / FLEET_LOGIN_HUB from the
#              environment, as for a create), credsep --fresh, account adopt
#              or its daemons, the fleet up.
#
# Before the verdict, ONE line says where the time went (issue #4044):
#     timing: stop=… quiesce=… aside=… requiesce=… home+sweep=… check=… rejoin=… isolated=… total=…
# isolated = the wash itself: from the start until the check said clean. The
# hub keeps the line in the spare.recycle audit; the op dir keeps it too, with
# stop.log / rejoin.log (each child's steps stamped) and aside.log.
#
# The run ends with TWO lines the hub reads (EPIC #3500 convention 9):
#     reset: clean | reset: dirty <category>,…
#     credsep: separated | credsep: <anything else>
# A phase that fails is `reset: dirty <phase>` (stop · wash · check · rejoin).
#
# Re-entry: FLEET_LOGIN_OP_ID (the admin agent's op_id) is written to
# ~/<login>-reset/op with each finished phase; the SAME op run again goes on
# from where it was cut off — a stop that finished is redone without a second
# archive (it quiesces again), a rejoin that did not finish is washed away and
# redone. No op id, or another one ⇒ from the start.
#
# Exit: 0 clean (the credsep line says the rest) · 1 dirty, or a phase failed ·
#       2 usage · 3 refused · 4 no such login · 6 services not moved yet (the
#       remove script's).
#
# Env (tests): FLEET_LOGIN_HOMES · FLEET_INSTALL_DAEMON_DIR · FLEET_NODE_STATE ·
#   FLEET_CREDSEP_ROOT_BASE · FLEET_OFFBOARD_ARCHIVE_DIR — as the remove script's;
#   FLEET_LOGIN_RESET_ROOT prefixes the outside dirs and is the check's --root;
#   FLEET_LOGIN_RESET_SETTLE (seconds of watch after a quiesce, default 0) ·
#   FLEET_LOGIN_RESET_ASIDE=wait (the old home's archive + delete in the run);
#   FLEET_LOGIN_RESET_{REMOVE,NEW,CHECK} — the three scripts; FLEET_LOGIN_REMOVE_SSH
#   (the wash's road with no Full Disk Access, `0` = none) · FLEET_LOGIN_REMOVE_TCC_DB.
set -uo pipefail

PROG=fleet-login-reset
BIN="$(cd "$(dirname "$0")" && pwd)"
usage() { printf 'usage: %s <login> [--keep-home|--delete-home] [--archive-dir <dir>] [--apply]\n' "$PROG" >&2; exit 2; }
die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }
refuse() { printf '%s: refusing %s\n' "$PROG" "$1" >&2; exit 3; }

LOGIN='' APPLY=0 KEEP=1 ARCHIVE_DIR=${FLEET_OFFBOARD_ARCHIVE_DIR:-/Users/Shared/offboarded}
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-home) KEEP=1; shift ;;
    --delete-home) KEEP=0; shift ;;
    --archive-dir) [ $# -ge 2 ] && [ -n "$2" ] || die '--archive-dir needs a directory'; ARCHIVE_DIR=$2; shift 2 ;;
    --archive-dir=*) ARCHIVE_DIR=${1#*=}; [ -n "$ARCHIVE_DIR" ] || die '--archive-dir needs a directory'; shift ;;
    --apply) APPLY=1; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$LOGIN" ] || usage; LOGIN=$1; shift ;;
  esac
done
[ -n "$LOGIN" ] || usage
printf '%s' "$LOGIN" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' || die "bad login name '$LOGIN'"
OPID=${FLEET_LOGIN_OP_ID:-}
[ -z "$OPID" ] || printf '%s' "$OPID" | grep -Eq '^[0-9a-f]{1,64}$' || die 'FLEET_LOGIN_OP_ID is not an op id (hex)'
[ "$EUID" != 0 ] || refuse 'running under sudo/root; run as the admin login'
UIDT=$(id -u "$LOGIN" 2>/dev/null) || { printf '%s: no login %s on this machine: nothing to wash\n' "$PROG" "$LOGIN" >&2; exit 4; }
ADMIN_UID=$(id -u)
[ "$UIDT" != "$ADMIN_UID" ] || refuse "washing the current login '$LOGIN'"
case " $(id -Gn "$LOGIN" 2>/dev/null) " in *' admin '*) refuse "washing admin group member '$LOGIN'" ;; esac

abs_dir() { case "$1" in /*) printf '%s\n' "$1" ;; *) ( cd -- "$1" 2>/dev/null && pwd -P ) || printf '%s/%s\n' "$PWD" "$1" ;; esac; }
HOMES=$(abs_dir "${FLEET_LOGIN_HOMES:-/Users}")
H="$HOMES/$LOGIN"
DDIR=$(abs_dir "${FLEET_INSTALL_DAEMON_DIR:-/Library/LaunchDaemons}")
ARCHIVE_DIR=$(abs_dir "$ARCHIVE_DIR")
NODE_STATE=$(abs_dir "${FLEET_NODE_STATE:-/var/db/fleet-node}")
CRED_BASE=$(abs_dir "${FLEET_CREDSEP_ROOT_BASE:-/var/db/fleet-cred}")
RROOT=${FLEET_LOGIN_RESET_ROOT:-}; RROOT=${RROOT%/}
REMOVE_SH=${FLEET_LOGIN_RESET_REMOVE:-$BIN/fleet-login-remove.sh}
NEW_SH=${FLEET_LOGIN_RESET_NEW:-$BIN/fleet-login-new.sh}
CHECK_PY=${FLEET_LOGIN_RESET_CHECK:-$BIN/fleet-login-reset-check.py}
RM_SSH=${FLEET_LOGIN_REMOVE_SSH:-$BIN/fleet-login-remove-ssh.sh}
TCC_DB=${FLEET_LOGIN_REMOVE_TCC_DB:-/Library/Application Support/com.apple.TCC/TCC.db}
OPDIR="$HOME/$LOGIN-reset" OPF="$HOME/$LOGIN-reset/op"
cd / || die 'cannot cd / (every step runs from there; issue #1216)'
[ ! -L "$H" ] || refuse "symlinked home '$H'"
case "$ARCHIVE_DIR/" in "$H/"*) refuse "archiving '$H' into itself ($ARCHIVE_DIR)" ;; esac

show() { local q; q=$(printf '%q ' "$@"); printf '  $ %s\n' "${q% }"; }
step() { printf '\n[%s] %s\n' "$1" "$2"; }
CREDSEP_LINE='credsep: not reached'
# verdict <reset verdict> <exit>: the two last lines, then out
verdict() {
  timing_line
  printf '\n%s\n%s\n' "reset: $1" "$CREDSEP_LINE"
  exit "$2"
}
failed() { printf '%s: %s\n' "$PROG" "$2" >&2; verdict "dirty $1" "${3:-1}"; }
# wrun <phase> <argv…>: print, and under --apply run — a failure is that phase dirty
wrun() { local ph=$1; shift; show "$@"; [ "$APPLY" = 1 ] || return 0; "$@" || failed "$ph" "failed: $*"; }

# ---- the clock (issue #4044) ----------------------------------------------
# Every phase is timed; the run ends with ONE `timing:` line (before the two
# verdict lines, so the agent's tail carries it to the hub's audit):
#   timing: stop=… quiesce=… aside=… requiesce=… home+sweep=… check=… rejoin=… isolated=… total=…
# isolated = from the start until the check said clean: the person's things are
# gone and checked — the wash itself; the rejoin after it sets the login up again.
# Each child's step headers ([1b] …) get the seconds since it started, and its
# last line lists every step's length (`steps: [1c] 0.4s · …`).
now() { python3 -c 'import time; print("%.3f" % time.time())' 2>/dev/null || date +%s; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
T0=$(now) LAPT=$T0 TIMES='' ISOLATED=''
lap() { local t; t=$(now); TIMES="${TIMES:+$TIMES }$1=$(secs "$LAPT" "$t")"; LAPT=$t; }
timing_line() {
  [ "$APPLY" = 1 ] || return 0
  local t; t=$(now)
  printf '\ntiming: %s%s total=%s\n' "${TIMES:-none}" "${ISOLATED:+ isolated=$ISOLATED}" "$(secs "$T0" "$t")"
  [ ! -f "${OPF:-/nonexistent}" ] || printf 'timing=%s%s total=%s\n' "$TIMES" "${ISOLATED:+ isolated=$ISOLATED}" "$(secs "$T0" "$t")" >> "$OPF" 2>/dev/null || :
}
# shellcheck disable=SC2016 # python, not shell
STAMP_PY='import sys, time
t0 = time.time(); last = None; steps = []
for l in sys.stdin:
    if l.startswith("["):
        t = time.time()
        if last:
            steps.append("%s %.1fs" % (last[0], t - last[1]))
        last = (l.split("]", 1)[0] + "]", t)
        l = "%s  (+%.1fs)\n" % (l.rstrip("\n"), t - t0)
    sys.stdout.write(l); sys.stdout.flush()
if last:
    steps.append("%s %.1fs" % (last[0], time.time() - last[1]))
if steps:
    print("  steps: " + " · ".join(steps))'
# stamped <out file> <argv…>: run it, its output stamped into the file; rc = its exit
stamped() {
  local of=$1; shift
  "$@" 2>&1 | python3 -u -c "$STAMP_PY" > "$of"
  return "${PIPESTATUS[0]}"
}

# quiesce: no process of the login, and none coming back — as the remove
# script's (issue #2866), run before the wash's clock starts and once more when
# the old home has moved aside (issue #3979: launchd relaunched
# /usr/sbin/distnoted for the uid between a stop and its wash). Nothing is let
# through by name. The person is gone, so nothing gets a grace: KILL first,
# then the uid's launchd domains booted out (with nothing left to wait for),
# KILL again, polled every 0.1 s (issue #4044 — the old TERM, sleeps and a 3 s
# watch made two quiesces ~10 s). FLEET_LOGIN_RESET_SETTLE seconds of watch
# after (default 0: whatever comes back after the clock started is newer than
# --since, and after the move it cannot reach the old home — moved into the
# admin's 700 archive dir). Still running after three rounds ⇒ a WARN and on:
# the check names it (processes).
SETTLE=${FLEET_LOGIN_RESET_SETTLE:-0}
pidle() { ! pgrep -U "$UIDT" >/dev/null 2>&1; }
# wait_idle <tenths>: true once no process of the uid runs
wait_idle() { local n=0; while [ "$n" -lt "$1" ]; do pidle && return 0; sleep 0.1; n=$((n + 1)); done; pidle; }
quiesce() {
  show sudo pkill -KILL -U "$UIDT"
  show sudo launchctl bootout "user/$UIDT"
  show sudo launchctl bootout "gui/$UIDT"
  [ "$APPLY" = 1 ] || return 0
  local round
  for round in 1 2 3; do
    sudo pkill -KILL -U "$UIDT" 2>/dev/null || :   # no processes is normal
    sudo launchctl bootout "user/$UIDT" >/dev/null 2>&1 || :   # none is normal
    if sudo launchctl print "gui/$UIDT" >/dev/null 2>&1; then
      sudo launchctl bootout "gui/$UIDT" >/dev/null 2>&1 || :
    fi
    sudo pkill -KILL -U "$UIDT" 2>/dev/null || :
    if wait_idle 10 && { [ "$SETTLE" = 0 ] || ! wait_busy "$((SETTLE * 10))"; }; then return 0; fi
    printf '%s: WARN a process of uid %s is still there or back (round %s): %s\n' "$PROG" "$UIDT" "$round" \
      "$(ps -o comm= -U "$UIDT" 2>/dev/null | head -3 | tr '\n' ' ')" >&2
  done
  printf '%s: WARN processes still run as uid %s after three rounds of kill + bootout — the check will name them\n' "$PROG" "$UIDT" >&2
}
# wait_busy <tenths>: true as soon as a process of the uid is back
wait_busy() { local n=0; while [ "$n" -lt "$1" ]; do pidle || return 0; sleep 0.1; n=$((n + 1)); done; ! pidle; }

# ---- the op file: where a cut-off run of the same op goes on from ----------
DONE_STOP=0 DONE_REJOIN=0 ARCHIVE='' SINCE=''
opget() { sed -n "s/^$1=//p" "$OPF" 2>/dev/null | tail -n 1; }
opput() { [ "$APPLY" = 1 ] || return 0; printf '%s=%s\n' "$1" "$2" >> "$OPF" || failed "$3" "cannot write $OPF"; }
if [ "$APPLY" = 1 ]; then
  if [ -n "$OPID" ] && [ "$(opget op)" = "$OPID" ]; then
    [ "$(opget phase)" = stop ] || [ "$(opget phase)" = rejoin ] && DONE_STOP=1
    [ "$(opget phase)" = rejoin ] && DONE_REJOIN=1
    ARCHIVE=$(opget archive); CREDSEP_LINE=$(opget credsep); [ -n "$CREDSEP_LINE" ] || CREDSEP_LINE='credsep: not reached'
    SINCE=$(opget since)
    printf '%s: op %s again — going on (stop %s, rejoin %s)\n' "$PROG" "$OPID" \
      "$([ "$DONE_STOP" = 1 ] && echo 'done' || echo 'to do')" "$([ "$DONE_REJOIN" = 1 ] && echo 'done' || echo 'to do')"
  else
    ( umask 077 && mkdir -p "$OPDIR" \
      && printf 'op=%s\npid=%s\nstarted=%s\n' "${OPID:--}" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OPF" ) \
      || { printf '%s: cannot write %s — nothing was changed\n' "$PROG" "$OPF" >&2; exit 1; }
  fi
  printf '%s: washing login %s (uid %s) for the next person — the login stays\n' "$PROG" "$LOGIN" "$UIDT"
else
  printf '%s: DRY RUN — no change; re-run with --apply\n' "$PROG"
fi
printf '  home=%s  archive=%s  op=%s\n' "$H" "$([ "$KEEP" = 1 ] && echo "$ARCHIVE_DIR" || echo none)" "${OPID:--}"
SOUT=$(mktemp "${TMPDIR:-/tmp}/fleet-login-reset.XXXXXX") || failed stop 'mktemp failed'
JOBS=$(mktemp -d "${TMPDIR:-/tmp}/fleet-login-reset.jobs.XXXXXX") || failed stop 'mktemp failed'
NOUT='' CERR="$SOUT.check"
trap 'rm -rf "$SOUT" "${NOUT:-}" "$CERR" "$JOBS"' EXIT

# ---- 1 stop: the remove script's steps 1b–3, --quick ------------------------
# Again on a re-run, even when it finished: a rejoin cut off half way started
# the login's services, and they must be down before the wash. --quick: no
# fleet-down (the daemon lets go, the wash kills), the hub leave beside the rest,
# no quiesce and no archive there — the wash does both.
step 1 "stop $LOGIN (fleet-login-remove.sh --recycle-stop --quick: off the hub, out of the daemon, services out, credsep purged)"
STOPA=(bash "$REMOVE_SH" "$LOGIN" --recycle-stop --quick --delete-home --archive-dir "$ARCHIVE_DIR")
[ "$APPLY" = 0 ] || STOPA+=(--apply)
show "${STOPA[@]}"
stamped "$SOUT" "${STOPA[@]}"; rc=$?
sed 's/^/    /' "$SOUT"
[ "$APPLY" = 0 ] || cp "$SOUT" "$OPDIR/stop.log" 2>/dev/null || :
case "$rc" in
  0) ;;
  3|4|6) failed stop "the remove script refused (exit $rc, above)" "$rc" ;;
  *) failed stop "the remove script failed (exit $rc, above)" ;;
esac
[ "$DONE_STOP" = 1 ] || opput phase stop stop
lap stop

# ---- 2 wash ------------------------------------------------------------------
# job <name> <argv…>: one sweep, in the background beside the others; a failure
# is recorded by name and fails the wash once all are back.
# A function job says nothing itself: its commands are shown before it.
job() {
  local name=$1; shift
  [ "$(type -t "$1")" = function ] || show "$@"
  [ "$APPLY" = 1 ] || return 0
  ( "$@" > "$JOBS/$name.out" 2>&1 || printf '%s\n' "$name" >> "$JOBS/failed" ) &
}
jobs_wait() {
  wait
  [ "$APPLY" = 1 ] || return 0
  local f
  for f in "$JOBS"/*.out; do [ -s "$f" ] && sed 's/^/    /' "$f"; done 2>/dev/null
  [ ! -s "$JOBS/failed" ] || failed wash "could not $(tr '\n' ' ' < "$JOBS/failed" | sed 's/ $//') (above)"
}
fresh_home() { sudo createhomedir -c -u "$LOGIN" && sudo chmod 700 "$H" && [ -d "$H" ]; }
cron_clear() {
  local cerr
  cerr=$(sudo crontab -u "$LOGIN" -r 2>&1) && return 0
  case "$cerr" in *'no crontab'*) return 0 ;; esac
  printf 'crontab -r: %s\n' "$cerr"; return 1
}
# a LaunchDaemon run as it that the remove script's labels did not name — one
# python for the whole dir (one per plist was a second a few dozen plists)
daemons_clear() {
  local plist rc=0
  while IFS= read -r plist; do
    [ -n "$plist" ] || continue
    printf '  booted out and removed %s\n' "$plist"
    sudo launchctl bootout system "$plist" >/dev/null 2>&1 || :
    sudo rm -f "$plist" || rc=1
  done <<EOF
$(python3 -I -c 'import os, plistlib, sys
d, who = sys.argv[1], sys.argv[2]
for n in sorted(os.listdir(d)) if os.path.isdir(d) else []:
    if not n.endswith(".plist"):
        continue
    p = os.path.join(d, n)
    try:
        if plistlib.load(open(p, "rb")).get("UserName") == who:
            print(p)
    except Exception:
        pass' "$DDIR" "$LOGIN")
EOF
  return "$rc"
}
# the uid's per-user temp + cache dir, /private/var/folders/<xx>/<yy>/ (its
# $TMPDIR, issue #4044): the uid outlives the wash, and so did this dir. Its
# C / T / 0 skeleton stays (macOS makes it per uid), and so does X — macOS's
# code-signing clones of app bundles it ran, SIP-protected: even root's rm is
# refused there (macmini, fleetu4) — app copies, not the person's files.
# Everything else in it goes; what rm
# still cannot take is a WARN, never the wash's verdict — the check judges.
folders_clear() {
  local vf="$RROOT/private/var/folders" u
  [ -d "$vf" ] || return 0
  for u in $(sudo find "$vf" -mindepth 2 -maxdepth 2 -type d -user "$UIDT" 2>/dev/null); do
    sudo find "$u" -mindepth 1 -maxdepth 1 ! -name C ! -name T ! -name 0 ! -name X -exec rm -rf {} + 2>&1 \
      || printf 'WARN %s: not all of it could be removed (above); the check judges what is left\n' "$u"
    sudo find "$u" -mindepth 2 -maxdepth 2 ! -path "$u/X/*" -exec rm -rf {} + 2>&1 \
      || printf 'WARN %s: not all of it could be removed (above); the check judges what is left\n' "$u"
  done
  return 0
}
# aside_later <dir> <tgz|"">: the old home, off the clock — archived when kept
# (the tar.gz the stop used to write, Library/Caches left out, 600 the
# admin's), then deleted. A tar that does not read back keeps the dir, said in
# <op dir>/aside.log. Detached: nothing waits for it, and the person's home is
# already out of the login's reach (the admin's 700 archive dir).
ASIDE_MODE=${FLEET_LOGIN_RESET_ASIDE:-background}
aside_later() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  local cmd=(sudo bash -c 'a=$1 t=$2 l=$3 o=$4
if [ -n "$t" ]; then
  tar --exclude="$l/Library/Caches" -czf "$t" -C "$a" "$l" 2>/dev/null
  if ! tar -tzf "$t" >/dev/null 2>&1; then echo "archive $t did not read back: $a kept"; exit 1; fi
  chown "$o" "$t" && chmod 600 "$t"
fi
rm -rf "$a" || echo "WARN $a could not be deleted whole (macOS privacy protection): sudo rm -rf $a from a session with Full Disk Access"' _ "$1" "$2" "$LOGIN" "$ADMIN_UID")
  show "${cmd[@]}"
  [ "$APPLY" = 1 ] || return 0
  if [ "$ASIDE_MODE" = wait ]; then
    "${cmd[@]}" >> "$OPDIR/aside.log" 2>&1
  else
    nohup "${cmd[@]}" >> "$OPDIR/aside.log" 2>&1 < /dev/null &
    disown 2>/dev/null || :
  fi
}

if [ "$DONE_REJOIN" = 0 ]; then
  # Only what predates this moment is the last person's (the check's --since):
  # set again on every wash — what a half rejoin made is washed with the rest.
  step 2 "wash $LOGIN: a fresh home, nothing of the last person anywhere"
  quiesce
  lap quiesce
  SINCE=$(date +%s)
  opput since "$SINCE" wash
  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  # The home is moved aside first: a rename needs no access to what is inside
  # (macOS privacy protection can keep root's rm out of ~/Library), and the old
  # home leaves the person's path at once — into the admin's 700 archive dir,
  # where it is archived (--keep-home, once per op) and deleted off the clock.
  # No Full Disk Access here (the admin agent, unless a person granted it)
  # ⇒ macOS refuses even root's rename of a home: the wash rides the remove
  # script's local ssh road (issue #3508, as its delete does — #2994), and the
  # direct road below runs only when that one cannot.
  if [ "$APPLY" = 1 ] && [ -e "$H" ] && [ "$RM_SSH" != 0 ] && [ -f "$RM_SSH" ] \
     && [ "$H" = "/Users/$LOGIN" ] && [ "$ARCHIVE_DIR" = /Users/Shared/offboarded ] \
     && ! sudo head -c 1 "$TCC_DB" >/dev/null 2>&1; then
    ME_ADMIN=$(id -un 2>/dev/null)
    printf '  (no Full Disk Access here: washing through a local ssh session as %s — no archive, and the delete is on the clock)\n' "$ME_ADMIN"
    show sudo bash "$RM_SSH" setup --admin "$ME_ADMIN"
    sudo bash "$RM_SSH" setup --admin "$ME_ADMIN" 2>&1 | sed 's/^/    /'
    WSTAMP=$(date -u +%Y%m%d%H%M%S)
    show sudo bash "$RM_SSH" wash "$LOGIN" --admin "$ME_ADMIN" --stamp "$WSTAMP"
    sudo bash "$RM_SSH" wash "$LOGIN" --admin "$ME_ADMIN" --stamp "$WSTAMP" 2>&1 | sed 's/^/    /'
    [ ! -e "$H" ] || printf '%s: WARN the local ssh road did not wash %s (why above) — trying directly\n' "$PROG" "$H" >&2
  fi
  if [ -e "$H" ] || [ "$APPLY" = 0 ]; then
    ASIDE="$ARCHIVE_DIR/$LOGIN-$STAMP.wash"
    TGZ=''
    [ "$KEEP" = 1 ] && [ -z "$ARCHIVE" ] && TGZ="$ARCHIVE_DIR/$LOGIN-$STAMP.tar.gz"
    wrun wash sudo install -d -m 700 -o "$ADMIN_UID" "$ARCHIVE_DIR"
    wrun wash sudo install -d -m 700 "$ASIDE"
    wrun wash sudo mv "$H" "$ASIDE/$LOGIN"
    if [ -n "$TGZ" ]; then
      ARCHIVE=$TGZ; opput archive "$ARCHIVE" wash
      printf '  archive=%s  (written from %s off the clock, then that is deleted)\n' "$ARCHIVE" "$ASIDE"
    fi
    aside_later "$ASIDE" "$TGZ"
  fi
  lap aside
  # Once more with the old home gone: anything relaunched between the clock and
  # the move is killed before it could hold a file of the old home open.
  quiesce
  lap requiesce
  # The fresh home and every sweep at once: none of them touches another's.
  show sudo createhomedir -c -u "$LOGIN"; show sudo chmod 700 "$H"
  job home fresh_home
  # the admin's onboarding papers (key pair, password, letter) — and root's;
  # root's books about it: entry keys, the daemon's task state, a credsep store
  job onboard rm -rf "$HOME/$LOGIN-onboard"
  job books sudo rm -rf "${RROOT}/var/root/$LOGIN-onboard" "$NODE_STATE/entry/keys/$LOGIN" "$NODE_STATE/logins/$LOGIN" "$CRED_BASE/$LOGIN"
  show sudo crontab -u "$LOGIN" -r
  job crontab cron_clear
  show sudo launchctl bootout system "<every $DDIR/*.plist whose UserName is $LOGIN>"
  job launchd daemons_clear
  # every file it owns outside the home (tmux sockets among them); the archive
  # dir is the admin's and stays
  n=0
  for d in "$RROOT/private/tmp" "$RROOT/private/var/tmp" "$RROOT/Users/Shared"; do
    [ -d "$d" ] || [ "$APPLY" = 0 ] || continue
    n=$((n + 1))
    job "outside-$n" sudo find "$d" -xdev -mindepth 1 -path "$ARCHIVE_DIR" -prune -o -user "$UIDT" -prune -exec rm -rf {} +
  done
  show sudo find "$RROOT/private/var/folders" -mindepth 2 -maxdepth 2 -type d -user "$UIDT" "(then everything in it but its C/T/0 skeleton and the SIP-held X)"
  job user-tmp folders_clear
  jobs_wait
  lap home+sweep
fi

# ---- 3 check -----------------------------------------------------------------
# Before the rejoin (issue #4044): what the wash left is all there is to judge —
# the rejoin only makes new things, newer than --since, which the check never
# counted anyway — and a dirty login is never set up again or handed a code.
step 3 "check: nothing of the last person left (fleet-login-reset-check.py --since the wash)"
CHK=(sudo python3 -I "$CHECK_PY" "$LOGIN" --platform darwin --since "${SINCE:-0}" --home "$H" --uid "$UIDT"
     --homes-root "$HOMES" --node-state "$NODE_STATE" --cred-base "$CRED_BASE" --archive-dir "$ARCHIVE_DIR")
[ -z "$RROOT" ] || CHK+=(--root "$RROOT")
show "${CHK[@]}"
if [ "$APPLY" = 1 ]; then
  [ -n "$SINCE" ] || failed check "no wash time in $OPF"
  COUT=$("${CHK[@]}" 2>"$CERR"); rc=$?
  sed 's/^/    /' "$CERR" >&2
  V=$(printf '%s\n' "$COUT" | sed -n 's/^reset: //p' | tail -n 1)
  lap check
  case "$rc:$V" in
    0:clean) ISOLATED=$(secs "$T0" "$(now)") ;;
    1:dirty\ *) verdict "$V" 1 ;;
    *) failed check "the check did not answer (exit $rc)" ;;
  esac
fi

# ---- 4 rejoin: the opener, on the kept login ---------------------------------
if [ "$DONE_REJOIN" = 0 ]; then
  step 4 "set $LOGIN up again (fleet-login-new.sh --recycle: new password, key, install, the hub's join code, credsep, its services)"
  NEWA=(bash "$NEW_SH" "$LOGIN" --recycle --share-pool)
  [ "$APPLY" = 0 ] || NEWA+=(--apply)
  show "${NEWA[@]}"
  if [ "$APPLY" = 1 ]; then
    NOUT=$(mktemp "${TMPDIR:-/tmp}/fleet-login-reset.XXXXXX") || failed rejoin 'mktemp failed'
    stamped "$NOUT" env ${OPID:+FLEET_LOGIN_OP_ID=$OPID} "${NEWA[@]}"; rc=$?
    sed 's/^/    /' "$NOUT"
    cp "$NOUT" "$OPDIR/rejoin.log" 2>/dev/null || :
    L=$(sed -n 's/^\(credsep: .*\)$/\1/p' "$NOUT" | tail -n 1)
    [ -z "$L" ] || CREDSEP_LINE=$L
    lap rejoin
    [ "$rc" = 0 ] || failed rejoin "fleet-login-new.sh --recycle failed (exit $rc, above)"
    opput credsep "$CREDSEP_LINE" rejoin
    opput phase rejoin rejoin
  fi
else
  printf '\n[4] (done in this op: washed at %s, set up again)\n' "$SINCE"
fi
[ "$APPLY" = 1 ] || { printf '\n%s: dry run complete\n' "$PROG"; exit 0; }
verdict clean 0
