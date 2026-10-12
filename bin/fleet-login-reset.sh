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
#   1 stop     fleet-login-remove.sh --recycle-stop: its steps 1–5 — the
#              login's fleets down, off the hub, `account forget`, its
#              services booted out, its credsep purged, the pool copy gone,
#              every process quiesced, the home archived (--keep-home, the
#              default) into --archive-dir (/Users/Shared/offboarded).
#   2 wash     the home moved aside into the archive dir and deleted, a fresh
#              one from the template (createhomedir, 700); the admin's
#              ~/<login>-onboard; its crontab; root's entry keys and task state
#              for it (<node state>/entry/keys/<login>, logins/<login>/); a
#              credsep store left over; any LaunchDaemon whose UserName it is;
#              every file it owns in /private/tmp, /private/var/tmp,
#              /Users/Shared (the archive dir excepted) — tmux sockets with them.
#   3 rejoin   fleet-login-new.sh <login> --recycle --share-pool: a new random
#              password, the key and the letter, the install, the hub's join
#              code (FLEET_LOGIN_JOIN_CODE / FLEET_LOGIN_HUB from the
#              environment, as for a create), credsep --fresh, account adopt
#              or its daemons, the fleet up.
#   4 check    fleet-login-reset-check.py <login> --since <the wash's start>:
#              only what predates the wash counts.
#
# The run ends with TWO lines the hub reads (EPIC #3500 convention 9):
#     reset: clean | reset: dirty <category>,…
#     credsep: separated | credsep: <anything else>
# A phase that fails is `reset: dirty <phase>` (stop · wash · rejoin · check).
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
#   FLEET_LOGIN_RESET_{REMOVE,NEW,CHECK} — the three scripts.
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
OPDIR="$HOME/$LOGIN-reset" OPF="$HOME/$LOGIN-reset/op"
cd / || die 'cannot cd / (every step runs from there; issue #1216)'
[ ! -L "$H" ] || refuse "symlinked home '$H'"
case "$ARCHIVE_DIR/" in "$H/"*) refuse "archiving '$H' into itself ($ARCHIVE_DIR)" ;; esac

show() { local q; q=$(printf '%q ' "$@"); printf '  $ %s\n' "${q% }"; }
step() { printf '\n[%s] %s\n' "$1" "$2"; }
CREDSEP_LINE='credsep: not reached'
# verdict <reset verdict> <exit>: the two last lines, then out
verdict() {
  printf '\n%s\n%s\n' "reset: $1" "$CREDSEP_LINE"
  exit "$2"
}
failed() { printf '%s: %s\n' "$PROG" "$2" >&2; verdict "dirty $1" "${3:-1}"; }
# wrun <phase> <argv…>: print, and under --apply run — a failure is that phase dirty
wrun() { local ph=$1; shift; show "$@"; [ "$APPLY" = 1 ] || return 0; "$@" || failed "$ph" "failed: $*"; }

# ---- the op file: where a cut-off run of the same op goes on from ----------
DONE_STOP=0 DONE_REJOIN=0 ARCHIVE='' SINCE=''
opget() { sed -n "s/^$1=//p" "$OPF" 2>/dev/null | tail -n 1; }
opput() { [ "$APPLY" = 1 ] || return 0; printf '%s=%s\n' "$1" "$2" >> "$OPF" || failed "$3" "cannot write $OPF"; }
if [ "$APPLY" = 1 ]; then
  if [ -n "$OPID" ] && [ "$(opget op)" = "$OPID" ]; then
    [ "$(opget done)" = stop ] || [ "$(opget done)" = rejoin ] && DONE_STOP=1
    [ "$(opget done)" = rejoin ] && DONE_REJOIN=1
    ARCHIVE=$(opget archive); CREDSEP_LINE=$(opget credsep); [ -n "$CREDSEP_LINE" ] || CREDSEP_LINE='credsep: not reached'
    SINCE=$(opget since)
    printf '%s: op %s again — going on (stop %s, rejoin %s)\n' "$PROG" "$OPID" \
      "$([ "$DONE_STOP" = 1 ] && echo done || echo 'to do')" "$([ "$DONE_REJOIN" = 1 ] && echo done || echo 'to do')"
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

# ---- 1 stop: the remove script's steps 1–5 ---------------------------------
# Again on a re-run, even when it finished: a rejoin cut off half way started
# the login's services, and they must be down before the wash. Its archive is
# taken once — a finished stop is redone with --delete-home.
step 1 "stop $LOGIN (fleet-login-remove.sh --recycle-stop: fleets down, off the hub, services out, credsep purged, quiesced$([ "$KEEP" = 1 ] && [ "$DONE_STOP" = 0 ] && echo ', home archived'))"
KEEPF=--keep-home; { [ "$KEEP" = 0 ] || [ "$DONE_STOP" = 1 ]; } && KEEPF=--delete-home
STOPA=(bash "$REMOVE_SH" "$LOGIN" --recycle-stop "$KEEPF" --archive-dir "$ARCHIVE_DIR")
[ "$APPLY" = 0 ] || STOPA+=(--apply)
show "${STOPA[@]}"
SOUT=$(mktemp "${TMPDIR:-/tmp}/fleet-login-reset.XXXXXX") || failed stop 'mktemp failed'
trap 'rm -f "$SOUT"' EXIT
"${STOPA[@]}" > "$SOUT" 2>&1; rc=$?
sed 's/^/    /' "$SOUT"
case "$rc" in
  0) ;;
  3|4|6) failed stop "the remove script refused (exit $rc, above)" "$rc" ;;
  *) failed stop "the remove script failed (exit $rc, above)" ;;
esac
if [ "$DONE_STOP" = 0 ]; then
  A=$(sed -n 's/^ *archive=//p' "$SOUT" | tail -n 1); [ -z "$A" ] || ARCHIVE=$A
  [ -z "$ARCHIVE" ] || opput archive "$ARCHIVE" stop
  opput done stop stop
fi
[ "$APPLY" = 0 ] || [ -z "$ARCHIVE" ] || printf '  archive=%s\n' "$ARCHIVE"

# ---- 2 wash ------------------------------------------------------------------
if [ "$DONE_REJOIN" = 0 ]; then
  # Only what predates this moment is the last person's (the check's --since):
  # set again on every wash — what a half rejoin made is washed with the rest.
  SINCE=$(date +%s)
  opput since "$SINCE" wash
  step 2 "wash $LOGIN: a fresh home, nothing of the last person anywhere"
  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  # The home is moved aside first: a rename needs no access to what is inside
  # (macOS privacy protection can keep root's rm out of ~/Library), and the old
  # home leaves the person's path at once. Then deleted; what macOS keeps from
  # this process stays in the admin's 700 archive dir, said once.
  if [ -e "$H" ]; then
    ASIDE="$ARCHIVE_DIR/$LOGIN-$STAMP.wash"
    wrun wash sudo install -d -m 700 -o "$ADMIN_UID" "$ARCHIVE_DIR"
    wrun wash sudo mv "$H" "$ASIDE"
    show sudo rm -rf "$ASIDE"
    if [ "$APPLY" = 1 ] && ! sudo rm -rf "$ASIDE" 2>/dev/null; then
      printf '%s: WARN %s could not be deleted whole (macOS privacy protection) — it is out of the login'"'"'s reach in %s; remove it from a session with Full Disk Access: sudo rm -rf %q\n' \
        "$PROG" "$ASIDE" "$ARCHIVE_DIR" "$ASIDE" >&2
    fi
  fi
  wrun wash sudo createhomedir -c -u "$LOGIN"
  wrun wash sudo chmod 700 "$H"
  if [ "$APPLY" = 1 ] && [ ! -d "$H" ]; then failed wash "createhomedir made no home at $H"; fi
  # the admin's onboarding papers (key pair, password, letter) — and root's
  wrun wash rm -rf "$HOME/$LOGIN-onboard"
  wrun wash sudo rm -rf "${RROOT}/var/root/$LOGIN-onboard"
  show sudo crontab -u "$LOGIN" -r
  if [ "$APPLY" = 1 ]; then
    cerr=$(sudo crontab -u "$LOGIN" -r 2>&1) || case "$cerr" in *'no crontab'*) ;; *) failed wash "crontab -r: $cerr" ;; esac
  fi
  # root's books about it: entry keys, the daemon's task state, a credsep store
  wrun wash sudo rm -rf "$NODE_STATE/entry/keys/$LOGIN" "$NODE_STATE/logins/$LOGIN" "$CRED_BASE/$LOGIN"
  # a LaunchDaemon run as it that the remove script's labels did not name
  for plist in "$DDIR"/*.plist; do
    [ -f "$plist" ] || continue
    u=$(python3 -I -c 'import plistlib,sys
try:
    print(plistlib.load(open(sys.argv[1], "rb")).get("UserName") or "")
except Exception:
    print("")' "$plist" 2>/dev/null) || u=''
    [ "$u" = "$LOGIN" ] || continue
    show sudo launchctl bootout system "$plist"
    [ "$APPLY" = 0 ] || sudo launchctl bootout system "$plist" >/dev/null 2>&1 || :
    wrun wash sudo rm -f "$plist"
  done
  # every file it owns outside the home (tmux sockets among them); the archive
  # dir is the admin's and stays
  for d in "$RROOT/private/tmp" "$RROOT/private/var/tmp" "$RROOT/Users/Shared"; do
    [ -d "$d" ] || continue
    FIND=(sudo find "$d" -xdev -mindepth 1 -path "$ARCHIVE_DIR" -prune -o -user "$UIDT" -prune -exec rm -rf {} +)
    show "${FIND[@]}"
    [ "$APPLY" = 0 ] || "${FIND[@]}" || failed wash "could not clear $d of uid $UIDT's files"
  done

  # ---- 3 rejoin: the opener, on the kept login ---------------------------------
  step 3 "set $LOGIN up again (fleet-login-new.sh --recycle: new password, key, install, the hub's join code, credsep, its services)"
  NEWA=(bash "$NEW_SH" "$LOGIN" --recycle --share-pool)
  [ "$APPLY" = 0 ] || NEWA+=(--apply)
  show "${NEWA[@]}"
  if [ "$APPLY" = 1 ]; then
    NOUT=$(mktemp "${TMPDIR:-/tmp}/fleet-login-reset.XXXXXX") || failed rejoin 'mktemp failed'
    trap 'rm -f "$SOUT" "$NOUT"' EXIT
    env ${OPID:+FLEET_LOGIN_OP_ID=$OPID} "${NEWA[@]}" > "$NOUT" 2>&1; rc=$?
    sed 's/^/    /' "$NOUT"
    L=$(sed -n 's/^\(credsep: .*\)$/\1/p' "$NOUT" | tail -n 1)
    [ -z "$L" ] || CREDSEP_LINE=$L
    [ "$rc" = 0 ] || failed rejoin "fleet-login-new.sh --recycle failed (exit $rc, above)"
    opput credsep "$CREDSEP_LINE" rejoin
    opput done rejoin rejoin
  fi
else
  printf '\n[2–3] (done in this op: washed at %s, set up again)\n' "$SINCE"
fi

# ---- 4 check -----------------------------------------------------------------
step 4 "check: nothing of the last person left (fleet-login-reset-check.py --since the wash)"
CHK=(sudo python3 -I "$CHECK_PY" "$LOGIN" --since "${SINCE:-0}" --home "$H" --uid "$UIDT"
     --homes-root "$HOMES" --node-state "$NODE_STATE" --cred-base "$CRED_BASE" --archive-dir "$ARCHIVE_DIR")
[ -z "$RROOT" ] || CHK+=(--root "$RROOT")
show "${CHK[@]}"
[ "$APPLY" = 1 ] || { printf '\n%s: dry run complete\n' "$PROG"; exit 0; }
[ -n "$SINCE" ] || failed check "no wash time in $OPF"
CERR="$SOUT.check"
trap 'rm -f "$SOUT" "${NOUT:-}" "$CERR"' EXIT
COUT=$("${CHK[@]}" 2>"$CERR"); rc=$?
sed 's/^/    /' "$CERR" >&2
V=$(printf '%s\n' "$COUT" | sed -n 's/^reset: //p' | tail -n 1)
case "$rc:$V" in
  0:clean) verdict clean 0 ;;
  1:dirty\ *) verdict "$V" 1 ;;
  *) failed check "the check did not answer (exit $rc)" ;;
esac
