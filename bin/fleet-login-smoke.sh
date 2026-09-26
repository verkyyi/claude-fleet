#!/bin/bash
# fleet-login-smoke.sh [--login <name>] [--keep] [--delete-home] [--no-share-pool]
#                      [--lang zh|en] [--timeout <secs>] [--ssh-host <h>] [--ssh-port <p>] [-v]
#   — the test-login real run as ONE command (issue #1218, EPIC #1212 R1):
#     open a throwaway login → its first SSH login → the guide speaks → capture
#     the guide pane → offboard → prove nothing is left; one PASS/FAIL line a
#     step, the three EPIC readings at the end.
#
# The last two batches ended with an admin walking a test login by hand
# (#1210): open it, ssh in, wait, capture-pane, remove it — and each time a
# step was skipped or a leftover stayed (a home, an SSH allow-list entry). This
# script is that walk, in order, and it always ends with the teardown — a step
# that FAILS still hands the login to fleet-login-remove.sh (unless --keep).
#
#   1 open      fleet-login-new.sh <login> --full-name … [--share-pool] --apply,
#               run FROM THE ADMIN'S HOME (a 0700 dir, #1210 ④ / #1216) with no
#               --pubkey, so the temporary key pair + welcome letter are made the
#               way a real onboarding makes them (#1195). Reads `installed N/N`
#               (#1210 ①) and the clone's stable sha.
#   2 welcome   ~/<login>-onboard/welcome.txt exists, is 600, and carries the
#               ssh line, the private key block, the ssh-config snippet, the key
#               swap steps and `cf --guide`. An unset FLEET_SSH_PUBLIC_HOST is a
#               WARN in the line, not a FAIL: the letter is complete, the admin
#               fills the host.
#   3 login     `ssh -tt <login>@<host>` with the temporary key, inside a tmux
#               server of its own (-L fleet-smoke-<login>, never the live one),
#               polled until <login>'s global/bootstrapped appears — read AS THE
#               LOGIN (`sudo -u`, the home is 0700). A `fleet-login-bootstrap:
#               <step>: FAIL` line in the pane, or ssh exiting first, fails the
#               step at once; --timeout bounds the wait. bootstrap.applied is
#               #1210 ②.
#   4 guide     global/guide.spoke (the guide really spoke — #1215) and then
#               global/onboarded (fleet-up, or the collector daemon's confirm),
#               within FLEET_SMOKE_ONBOARD_SECS of bootstrapped. onboarded seen
#               without guide.spoke is #1210 ③ — a FAIL.
#   5 capture   `tmux capture-pane -p -t <fleet>:guide`, run as the login on its
#               own socket (the EPIC's evidence line), printed inline and saved
#               under the run's log dir. Empty, or `Unknown command`, is a FAIL.
#   6 doctor    the login's own fleet-doctor-onboard.sh (its clone). The reading
#               «manual steps left» = its `needs:` items minus the person's own
#               (Codex device code, `gh auth login`, the temporary-key swap):
#               anything else left is a FAIL naming it.
#   7 daemons   every launchd/*.plist.tmpl of the login's clone is loaded as
#               system/com.claude-fleet.<login>.<unit> (`sudo launchctl list`),
#               and its plist sits in FLEET_INSTALL_DAEMON_DIR — #1210 ①.
#   8 offboard  fleet-login-remove.sh <login> --apply — the DEFAULT path
#               (archive, then delete; #1210 ⑤), `--delete-home` passes through.
#               The archive this run produced is verified (600) and then removed:
#               a smoke login's home holds nothing. --keep skips this step and
#               the next, leaves the login up for a look, and prints the command.
#   9 residue   no login record, no home, no plist, no loaded service, no
#               process of its uid, no name/GUID in any com.apple.access_* group.
#
# Then the summary and the three readings of EPIC #1212's table. The temporary
# key, password and letter (~/<login>-onboard/) are removed with the login;
# every child transcript + the captures stay in the run's log dir (printed).
#
# Needs: an admin login (never root), a sudo ticket (`sudo -v` first — nothing
# here prompts; the ticket is refreshed while polling), ssh, tmux, and sshd
# reachable at --ssh-host:--ssh-port (default 127.0.0.1:22 — this machine's own
# Remote Login; the public entry is for the letter, not for this run).
# NEVER from a fleet worker (EPIC #1212 convention 2): it opens a real login and
# runs sudo. Its selftest runs it against PATH shims only.
#
# Exit: 0 every step passed · 1 a step failed (the teardown still ran) ·
#       2 bad arguments / preflight · 3 the login (or its home) already exists
# Env: FLEET_SMOKE_SSH_HOST (127.0.0.1) · FLEET_SMOKE_SSH_PORT (22) ·
#      FLEET_SMOKE_TIMEOUT (900s, to bootstrapped) · FLEET_SMOKE_ONBOARD_SECS
#      (300s, bootstrapped → spoke → onboarded) · FLEET_SMOKE_POLL_SECS (5; a decimal is fine) ·
#      FLEET_LOGIN_HOMES (/Users) · FLEET_INSTALL_DAEMON_DIR (/Library/LaunchDaemons)
set -u

PROG=fleet-login-smoke
BIN="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die2() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }

LOGIN='' KEEP=0 DELETE_HOME=0 SHARE=1 WLANG=zh VERBOSE=0
HOST=${FLEET_SMOKE_SSH_HOST:-127.0.0.1} PORT=${FLEET_SMOKE_SSH_PORT:-22}
TIMEOUT=${FLEET_SMOKE_TIMEOUT:-900} ONBOARD_SECS=${FLEET_SMOKE_ONBOARD_SECS:-300} POLL=${FLEET_SMOKE_POLL_SECS:-5}
while [ $# -gt 0 ]; do
  case "$1" in
    --login)    [ $# -ge 2 ] || usage; LOGIN=$2; shift 2 ;;
    --timeout)  [ $# -ge 2 ] || usage; TIMEOUT=$2; shift 2 ;;
    --ssh-host) [ $# -ge 2 ] || usage; HOST=$2; shift 2 ;;
    --ssh-port) [ $# -ge 2 ] || usage; PORT=$2; shift 2 ;;
    --lang)     [ $# -ge 2 ] || usage; WLANG=$2; shift 2 ;;
    --keep)     KEEP=1; shift ;;
    --delete-home) DELETE_HOME=1; shift ;;
    --no-share-pool) SHARE=0; shift ;;
    --share-pool) SHARE=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *)          die2 "unknown argument: $1" ;;
  esac
done
[ -n "$LOGIN" ] || LOGIN="smoke-$(date +%m%d%H%M)"
printf '%s' "$LOGIN" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' \
  || die2 "bad login name '$LOGIN' (lowercase letters, digits, _ and -; at most 32)"
for v in "TIMEOUT=$TIMEOUT" "ONBOARD_SECS=$ONBOARD_SECS" "PORT=$PORT"; do
  printf '%s' "${v#*=}" | grep -Eq '^[0-9]+$' || die2 "${v%%=*}: not a number: '${v#*=}'"
done
printf '%s' "$POLL" | grep -Eq '^([0-9]+\.?[0-9]*|\.[0-9]+)$' && [ "$POLL" != 0 ] || die2 "FLEET_SMOKE_POLL_SECS: not a number of seconds: '$POLL'"
case "$WLANG" in zh|en) ;; *) die2 "--lang: zh or en (got '$WLANG')" ;; esac
[ "$EUID" != 0 ] || die2 'run this as the admin login, not under sudo — it sudo'"'"'s what needs root'

HOMES=${FLEET_LOGIN_HOMES:-/Users}
H="$HOMES/$LOGIN"
DDIR=${FLEET_INSTALL_DAEMON_DIR:-/Library/LaunchDaemons}
ONBOARD="$HOME/$LOGIN-onboard"
KEY="$ONBOARD/id_ed25519"
WELCOME="$ONBOARD/welcome.txt"
G="$H/.config/claude-fleet/global"
SOCK="fleet-smoke-$LOGIN"        # this run's own tmux server (label), never the live one
TSESS=smoke
NEW_SH="$BIN/fleet-login-new.sh" RM_SH="$BIN/fleet-login-remove.sh"

# --- preflight (exit 2 / 3): nothing below has changed anything yet ------------
for t in ssh tmux sudo; do
  command -v "$t" >/dev/null 2>&1 || die2 "$t not found — nothing was changed"
done
[ -f "$NEW_SH" ] && [ -f "$RM_SH" ] || die2 "fleet-login-new.sh / fleet-login-remove.sh not found beside $0"
sudo -n -v >/dev/null 2>&1 || die2 "no sudo ticket — run 'sudo -v' first (this script never prompts)"
if id "$LOGIN" >/dev/null 2>&1; then
  printf '%s: login %s already exists — refusing (pick another --login, or offboard it: %s %s --apply)\n' "$PROG" "$LOGIN" "$RM_SH" "$LOGIN" >&2
  exit 3
fi
[ ! -e "$H" ] || { printf '%s: %s already exists (no such login) — refusing\n' "$PROG" "$H" >&2; exit 3; }

RUN=$(mktemp -d "${TMPDIR:-/tmp}/fleet-login-smoke.$LOGIN.XXXXXX") || die2 'mktemp failed'
if [ "$DELETE_HOME" = 1 ]; then POLICY=delete-home; else POLICY=archive; fi
[ "$KEEP" = 0 ] || POLICY="keep (no offboarding)"
printf '%s: login=%s  ssh=%s:%s  share-pool=%s  timeout=%ss  offboard=%s\n' \
  "$PROG" "$LOGIN" "$HOST" "$PORT" "$([ "$SHARE" = 1 ] && echo yes || echo no)" "$TIMEOUT" "$POLICY"
printf '%s: log dir %s\n' "$PROG" "$RUN"

# --- bookkeeping -----------------------------------------------------------------
T0=$SECONDS
STEP=0 NPASS=0 NFAIL=0 NSKIP=0
UIDN='' GUID='' STABLE='' SESS='' FLEET_LIVE=0 TMUX_UP=0 SUMMARISED=0
BOOT_AT='' SPOKE_AT='' ONBOARDED_AT=''
# the EPIC readings, filled as the steps go ('?' = never reached)
M_OPEN='?' M_INSTALLED='?' M_DAEMONS='?' M_APPLY='?' M_ORDER='?' M_OFFBOARD='?' M_MANUAL='?' M_WELCOME='?'

line() { STEP=$((STEP + 1)); printf '%-4s  %-9s %s\n' "$1" "$2" "$3"; }
pass() { NPASS=$((NPASS + 1)); line PASS "$1" "$2"; }
failstep() { NFAIL=$((NFAIL + 1)); line FAIL "$1" "$2"; }
skip() { NSKIP=$((NSKIP + 1)); line SKIP "$1" "$2"; }
note() { printf '        %s\n' "$*"; }
# tail_of <file> [n]: the file's last lines, indented, for a FAIL line's context
tail_of() { local n=${2:-15}; [ -s "$1" ] || return 0; tail -n "$n" "$1" | sed 's/^/        │ /'; }
elapsed() { printf '%ss' "$((SECONDS - T0))"; }
as_login() { sudo -n -u "$LOGIN" -H "$@"; }
login_has() { as_login test -e "$1" >/dev/null 2>&1; }
keep_sudo() { sudo -n -v >/dev/null 2>&1 || :; }
mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null; }
loaded_labels() { sudo -n launchctl list 2>/dev/null | awk 'NF { print $NF }'; }
# plists_of_login: how many com.claude-fleet.<login>.*.plist sit in the daemons dir
plists_of_login() { local n=0 f; for f in "$DDIR"/com.claude-fleet."$LOGIN".*.plist; do [ -e "$f" ] && n=$((n + 1)); done; printf '%s' "$n"; }
# run_logged <log> <cmd…>: the child's transcript to <log> (and to the screen
# under -v); the child's exit code, not tee's
run_logged() {
  local log=$1; shift
  if [ "$VERBOSE" = 1 ]; then
    "$@" 2>&1 | tee "$log" | sed 's/^/        │ /'
    return "${PIPESTATUS[0]}"
  fi
  "$@" > "$log" 2>&1
}
from_home() { ( cd "$HOME" && exec "$@" ); }
tmux_own() { TMUX='' tmux -L "$SOCK" "$@"; }
outer_pane() { tmux_own capture-pane -p -S - -t "$TSESS" 2>/dev/null | sed '/^[[:space:]]*$/d'; }
kill_own_tmux() {
  [ "$TMUX_UP" = 1 ] || return 0
  outer_pane > "$RUN/ssh-pane.txt" 2>/dev/null || :
  tmux_own kill-server >/dev/null 2>&1 || :
  TMUX_UP=0
}

# --- 1 open ------------------------------------------------------------------------
step_open() {
  local args rc
  args="$LOGIN --full-name 'Smoke Test ($LOGIN)' --lang $WLANG$([ "$SHARE" = 1 ] && printf ' --share-pool') --apply"
  set -- "$LOGIN" --full-name "Smoke Test ($LOGIN)" --lang "$WLANG"
  [ "$SHARE" = 0 ] || set -- "$@" --share-pool
  set -- "$@" --apply
  run_logged "$RUN/login-new.log" from_home bash "$NEW_SH" "$@"; rc=$?
  M_INSTALLED=$(sed -n 's/^  installed \([0-9]*\/[0-9]*\).*/\1/p' "$RUN/login-new.log" | tail -n 1)
  [ -n "$M_INSTALLED" ] || M_INSTALLED='?'
  [ "$M_INSTALLED" = '?' ] || M_DAEMONS="$M_INSTALLED installed"   # until the daemons step counts what is loaded
  if [ "$rc" != 0 ]; then
    M_OPEN="FAILED (exit $rc, from $HOME)"
    failstep open "fleet-login-new.sh $args (from $HOME): exit $rc — $(tail -n 1 "$RUN/login-new.log")"
    tail_of "$RUN/login-new.log"
    return 1
  fi
  M_OPEN="ok (ran from $HOME)"
  UIDN=$(id -u "$LOGIN" 2>/dev/null || :)
  GUID=$(dscl . -read "/Users/$LOGIN" GeneratedUID 2>/dev/null | awk '$1=="GeneratedUID:" {print $2; exit}')
  STABLE=$(as_login git -C "$H/.claude/fleet" rev-parse --short HEAD 2>/dev/null || :)
  pass open "fleet-login-new.sh $args (from $HOME, a 0700 dir — #1210 ④): ok · daemons installed $M_INSTALLED · clone stable=${STABLE:-?} · $(elapsed)"
}

# --- 2 welcome ---------------------------------------------------------------------
step_welcome() {
  local missing='' m host port
  if [ ! -f "$WELCOME" ]; then
    M_WELCOME=missing
    failstep welcome "$WELCOME: not written"
    return 1
  fi
  m=$(mode_of "$WELCOME"); [ "$m" = 600 ] || missing="$missing mode=$m(not 600)"
  grep -Eq '^ *ssh -p [0-9]+ '"$LOGIN"'@' "$WELCOME" || missing="$missing ssh-line"
  grep -q 'BEGIN OPENSSH PRIVATE KEY' "$WELCOME" || missing="$missing private-key"
  grep -q '^Host ' "$WELCOME" || missing="$missing ssh-config"
  grep -q 'ssh-copy-id' "$WELCOME" || missing="$missing key-swap"
  grep -q 'cf --guide' "$WELCOME" || missing="$missing cf--guide"
  host=$(sed -n 's/^ *ssh -p \([0-9]*\) '"$LOGIN"'@\(.*\)$/\2/p' "$WELCOME" | head -n 1)
  port=$(sed -n 's/^ *ssh -p \([0-9]*\) '"$LOGIN"'@.*$/\1/p' "$WELCOME" | head -n 1)
  if [ -n "$missing" ]; then
    M_WELCOME="incomplete:$missing"
    failstep welcome "$WELCOME: missing$missing"
    return 1
  fi
  M_WELCOME="ok (host ${host:-?}, port ${port:-?})"
  pass welcome "$WELCOME (600): host ${host:-?} port ${port:-?} · temporary key inline · ssh config · key swap · cf --guide$([ "$host" = '<HOST>' ] && printf ' · WARN host is the <HOST> placeholder — set FLEET_SSH_PUBLIC_HOST')"
}

# --- 3 login -----------------------------------------------------------------------
step_login() {
  local cmd deadline pane t0
  cmd=$(printf '%q ' ssh -tt -i "$KEY" -p "$PORT" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=15 "$LOGIN@$HOST")
  if ! tmux_own new-session -d -s "$TSESS" -x 200 -y 50 \
       "${cmd% }; printf '[fleet-login-smoke] ssh exited %s\\n' \$?; sleep 3600" 2>"$RUN/tmux.err"; then
    failstep login "cannot start the run's own tmux server (-L $SOCK): $(head -n 1 "$RUN/tmux.err")"
    return 1
  fi
  TMUX_UP=1
  t0=$SECONDS; deadline=$((t0 + TIMEOUT))
  while :; do
    keep_sudo
    if login_has "$G/bootstrapped"; then
      BOOT_AT=$((SECONDS - t0)); break
    fi
    pane=$(outer_pane)
    if printf '%s\n' "$pane" | grep -Eq 'fleet-login-bootstrap: [a-z]+: FAIL'; then
      printf '%s\n' "$pane" > "$RUN/ssh-pane.txt"
      failstep login "first login via ssh -tt: bootstrap failed after $((SECONDS - t0))s — $(printf '%s\n' "$pane" | grep -E 'fleet-login-bootstrap: [a-z]+: FAIL' | head -n 1)"
      tail_of "$RUN/ssh-pane.txt"
      return 1
    fi
    case "$pane" in *'[fleet-login-smoke] ssh exited'*)
      printf '%s\n' "$pane" > "$RUN/ssh-pane.txt"
      failstep login "first login via ssh -tt: ssh exited before global/bootstrapped ($(printf '%s\n' "$pane" | grep '\[fleet-login-smoke\] ssh exited' | tail -n 1))"
      tail_of "$RUN/ssh-pane.txt"
      return 1 ;;
    esac
    if [ "$SECONDS" -ge "$deadline" ]; then
      printf '%s\n' "$pane" > "$RUN/ssh-pane.txt"
      failstep login "first login via ssh -tt: no global/bootstrapped after ${TIMEOUT}s (--timeout) — pane tail:"
      tail_of "$RUN/ssh-pane.txt"
      return 1
    fi
    sleep "$POLL"
  done
  if login_has "$G/bootstrap.applied"; then M_APPLY=ok; else M_APPLY=missing; fi
  if [ "$M_APPLY" = ok ]; then
    pass login "ssh -tt $LOGIN@$HOST:$PORT (temporary key): bootstrapped after ${BOOT_AT}s · bootstrap.applied ok (#1210 ②)"
  else
    failstep login "ssh -tt $LOGIN@$HOST:$PORT: bootstrapped after ${BOOT_AT}s but no global/bootstrap.applied (#1210 ②: the apply did not pass)"
    return 1
  fi
}

# --- 4 guide -----------------------------------------------------------------------
step_guide() {
  local deadline t0 spoke=0 onboarded=0
  t0=$SECONDS
  # the login step failed: one look, no wait — the guide had its chance
  if [ -n "$BOOT_AT" ]; then deadline=$((t0 + ONBOARD_SECS)); else deadline=$t0; fi
  while :; do
    keep_sudo
    if [ "$spoke" = 0 ] && login_has "$G/guide.spoke"; then spoke=1; SPOKE_AT=$((SECONDS - t0)); fi
    if [ "$onboarded" = 0 ] && login_has "$G/onboarded"; then
      onboarded=1; ONBOARDED_AT=$((SECONDS - t0))
      if [ "$spoke" = 0 ]; then
        M_ORDER='VIOLATED (onboarded before guide.spoke)'
        failstep guide "global/onboarded is written but global/guide.spoke is not — a guide that never spoke counted as onboarded (#1210 ③)"
        return 1
      fi
    fi
    [ "$spoke" = 1 ] && [ "$onboarded" = 1 ] && break
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep "$POLL"
  done
  if [ "$spoke" = 1 ] && [ "$onboarded" = 1 ]; then
    M_ORDER='ok (onboarded only after guide.spoke)'
    pass guide "guide.spoke +${SPOKE_AT}s after bootstrapped · onboarded +${ONBOARDED_AT}s (#1210 ③: written only after it spoke)"
    return 0
  fi
  outer_pane > "$RUN/ssh-pane.txt" 2>/dev/null || :
  if [ "$spoke" = 0 ]; then
    M_ORDER='guide never spoke'
    failstep guide "the guide never spoke: no global/guide.spoke within ${ONBOARD_SECS}s of bootstrapped (#1215) — ssh pane tail:"
  else
    M_ORDER='spoke, never confirmed'
    failstep guide "guide.spoke +${SPOKE_AT}s, but global/onboarded not written within ${ONBOARD_SECS}s — nobody confirmed it (fleet-up's wait, or com.claude-fleet.$LOGIN.collect — is it loaded?)"
  fi
  tail_of "$RUN/ssh-pane.txt"
  return 1
}

# --- 5 capture ---------------------------------------------------------------------
step_capture() {
  local names s cap n rc why
  names=$(as_login ls -1 "$H/.config/claude-fleet/fleets" 2>/dev/null || :)
  SESS=''
  for s in $names; do
    if as_login env HOME="$H" TMUX= tmux -L "$s" has-session -t "$s" >/dev/null 2>&1; then SESS=$s; FLEET_LIVE=1; break; fi
  done
  [ -n "$SESS" ] || SESS=$(printf '%s\n' "$names" | head -n 1)
  [ -n "$SESS" ] || SESS=fleet
  cap=$(as_login env HOME="$H" TMUX= tmux -L "$SESS" capture-pane -p -t "$SESS:guide" 2>"$RUN/capture.err"); rc=$?
  n=$(printf '%s\n' "$cap" | sed '/^[[:space:]]*$/d' | grep -c .)
  printf '%s\n' "$cap" > "$RUN/guide-pane.txt"
  if [ "$rc" != 0 ] || [ "$FLEET_LIVE" = 0 ] || [ "$n" = 0 ]; then
    if [ "$rc" != 0 ]; then why=$(head -n 1 "$RUN/capture.err"); why=${why:-exit $rc}
    elif [ "$FLEET_LIVE" = 0 ]; then why='no live fleet server'
    else why='empty pane'; fi
    failstep capture "tmux -L $SESS capture-pane -t $SESS:guide (as $LOGIN): $why"
    return 1
  fi
  if printf '%s\n' "$cap" | grep -q 'Unknown command'; then
    failstep capture "$SESS:guide (as $LOGIN) shows 'Unknown command' — the guide's /fleet-onboard is not installed (#1210 ②/③):"
    printf '%s\n' "$cap" | sed '/^[[:space:]]*$/d' | tail -n 20 | sed 's/^/        │ /'
    return 1
  fi
  pass capture "tmux -L $SESS capture-pane -p -t $SESS:guide (as $LOGIN): $n lines — the guide pane:"
  printf '%s\n' "$cap" | sed '/^[[:space:]]*$/d' | tail -n 40 | sed 's/^/        │ /'
}

# --- 6 doctor ----------------------------------------------------------------------
step_doctor() {
  local out rc left='' item
  out=$(as_login env HOME="$H" bash "$H/.claude/fleet/bin/fleet-doctor-onboard.sh" 2>&1); rc=$?
  printf '%s\n' "$out" > "$RUN/doctor-onboard.txt"
  case "$out" in
    ready:*) M_MANUAL=0 ;;
    needs:*)
      while IFS= read -r item; do
        [ -n "$item" ] || continue
        case "$item" in
          *'GitHub login'*|*'Codex LOGIN'*|*'replace temporary SSH key'*) ;;   # the person's own, by design
          *) left="$left · $item" ;;
        esac
      done <<EOF
$(printf '%s\n' "${out#needs:}" | tr ',' '\n' | sed 's/^ *//; s/ *$//')
EOF
      M_MANUAL=$(printf '%s' "$left" | grep -o '·' | grep -c .) ;;
    *)
      M_MANUAL='?'
      failstep doctor "fleet-doctor-onboard.sh (as $LOGIN) exit $rc: $(printf '%s\n' "$out" | head -n 1)"
      return 1 ;;
  esac
  if [ "$M_MANUAL" = 0 ]; then
    pass doctor "manual steps left after opening: 0 — onboard row: $out (GitHub / Codex / the temporary-key swap are the person's own)"
  else
    failstep doctor "manual steps left after opening: $M_MANUAL —${left} (onboard row: $out)"
    return 1
  fi
}

# --- 7 daemons ---------------------------------------------------------------------
step_daemons() {
  local units u n=0 total=0 missing='' loaded plists
  units=$(as_login ls -1 "$H/.claude/fleet/launchd" 2>/dev/null | sed -n 's/^com\.claude-fleet\.\(.*\)\.plist\.tmpl$/\1/p')
  loaded=$(loaded_labels)
  for u in $units; do
    total=$((total + 1))
    if printf '%s\n' "$loaded" | grep -Fxq "com.claude-fleet.$LOGIN.$u"; then n=$((n + 1)); else missing="$missing $u"; fi
  done
  plists=$(plists_of_login)
  M_DAEMONS="$n/$total loaded"
  if [ "$total" = 0 ]; then
    failstep daemons "no launchd/*.plist.tmpl readable in $H/.claude/fleet/launchd (as $LOGIN) — nothing to count"
    return 1
  fi
  if [ "$n" = "$total" ]; then
    pass daemons "loaded $n/$total system/com.claude-fleet.$LOGIN.* · $plists plists in $DDIR (#1210 ①)"
  else
    failstep daemons "loaded $n/$total system/com.claude-fleet.$LOGIN.* — not loaded:$missing · $plists plists in $DDIR (#1210 ①)"
    return 1
  fi
}

# --- 8 offboard --------------------------------------------------------------------
step_offboard() {
  local rc archive m rest=''
  set -- "$LOGIN"
  [ "$DELETE_HOME" = 0 ] || set -- "$@" --delete-home
  set -- "$@" --apply
  run_logged "$RUN/login-remove.log" from_home bash "$RM_SH" "$@"; rc=$?
  archive=$(sed -n 's/^  archive=\([^ ]*\).*/\1/p' "$RUN/login-remove.log" | tail -n 1)
  if [ "$rc" != 0 ]; then
    M_OFFBOARD="FAILED (exit $rc)"
    failstep offboard "fleet-login-remove.sh $* (from $HOME): exit $rc — $(tail -n 1 "$RUN/login-remove.log")"
    tail_of "$RUN/login-remove.log"
    return 1
  fi
  if [ "$DELETE_HOME" = 0 ]; then
    if [ -n "$archive" ] && [ -f "$archive" ]; then
      m=$(mode_of "$archive")
      rm -f "$archive"
      rest=" · archive $archive ($m) verified, then removed — a smoke login's home"
      [ "$m" = 600 ] || rest="$rest · WARN archive mode was $m, not 600"
    else
      M_OFFBOARD="ok, but no archive at '${archive:-?}'"
      failstep offboard "fleet-login-remove.sh $*: ok, but the default path left no archive (${archive:-no archive= line})"
      return 1
    fi
  fi
  M_OFFBOARD=ok
  pass offboard "fleet-login-remove.sh $* (from $HOME; default path = archive then delete, #1210 ⑤): ok$rest"
}

# --- 9 residue ---------------------------------------------------------------------
step_residue() {
  local left='' g loaded n
  id "$LOGIN" >/dev/null 2>&1 && left="$left · login record"
  [ ! -e "$H" ] || left="$left · home $H"
  n=$(plists_of_login)
  [ "$n" = 0 ] || left="$left · $n plist(s) in $DDIR"
  loaded=$(loaded_labels | grep -c "^com\.claude-fleet\.$LOGIN\.")
  [ "$loaded" = 0 ] || left="$left · $loaded loaded service(s)"
  if [ -n "$UIDN" ]; then
    n=$(ps -axo uid= 2>/dev/null | awk -v u="$UIDN" '$1 == u' | grep -c .)
    [ "$n" = 0 ] || left="$left · $n process(es) of uid $UIDN"
  fi
  for g in $(dscl . -list /Groups 2>/dev/null | grep '^com\.apple\.access_' || :); do
    dscl . -read "/Groups/$g" GroupMembership 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$LOGIN" && left="$left · $g lists $LOGIN"
    [ -z "$GUID" ] || { dscl . -read "/Groups/$g" GroupMembers 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$GUID" && left="$left · $g lists its GUID"; }
  done
  if [ -z "$left" ]; then
    pass residue "none: no login record, no home, no plist, no loaded service, no process, not in any com.apple.access_* group"
  else
    [ "$M_OFFBOARD" = ok ] && M_OFFBOARD="ok, but residue:$left"
    failstep residue "left behind:$left"
    return 1
  fi
}

# --- the end: teardown, summary, readings — every exit path lands here ---------------
finish() {
  [ "$SUMMARISED" = 0 ] || return 0
  SUMMARISED=1
  kill_own_tmux
  if [ "$KEEP" = 1 ]; then
    skip offboard "--keep: login $LOGIN stays up for a look — offboard it with: $RM_SH $LOGIN --apply  (its key, password and letter: $ONBOARD)"
    skip residue '--keep'
    M_OFFBOARD='skipped (--keep)'
  else
    if id "$LOGIN" >/dev/null 2>&1 || [ -e "$H" ]; then
      step_offboard || :
    else
      M_OFFBOARD="nothing to offboard (login was never created)"
      skip offboard "login $LOGIN was never created — nothing to remove"
    fi
    step_residue || :
    if id "$LOGIN" >/dev/null 2>&1; then
      note "kept $ONBOARD (its key still opens the login that is still there)"
    else
      rm -rf "$ONBOARD"
    fi
  fi
  printf '\n'
  if [ "$NFAIL" = 0 ]; then
    printf '%s: PASS  %d passed · %d skipped · %s · log %s\n' "$PROG" "$NPASS" "$NSKIP" "$(elapsed)" "$RUN"
  else
    printf '%s: FAIL  %d passed · %d failed · %d skipped · %s · log %s\n' "$PROG" "$NPASS" "$NFAIL" "$NSKIP" "$(elapsed)" "$RUN"
  fi
  local defects=0 d1 d2 d3 d4 d5 n
  d1="$M_DAEMONS"; n=${M_DAEMONS%% *}
  case "$n" in ?*/*) [ "${n%/*}" = "${n#*/}" ] || defects=$((defects + 1)) ;; *) defects=$((defects + 1)) ;; esac
  d2="$M_APPLY";       [ "$M_APPLY" = ok ] || defects=$((defects + 1))
  d3="$M_ORDER";       case "$M_ORDER" in ok*) ;; *) defects=$((defects + 1)) ;; esac
  d4="$M_OPEN";        case "$M_OPEN" in ok*) ;; *) defects=$((defects + 1)) ;; esac
  d5="$M_OFFBOARD";    case "$M_OFFBOARD" in ok|'skipped (--keep)') ;; *) defects=$((defects + 1)) ;; esac
  printf '\nreadings (EPIC #1212):\n'
  printf '  manual steps left after opening (开号后还要人手工补的步骤): %s\n' "$M_MANUAL"
  printf '  #1210 defects still open (上一批实跑查出、还没修的缺陷): %d/5  — ① daemons %s · ② first-login apply %s · ③ onboarded %s · ④ open from a 0700 cwd %s · ⑤ offboard %s\n' \
    "$defects" "$d1" "$d2" "$d3" "$d4" "$d5"
  printf '  letters to write by hand (开完号后要自己写给新人的说明): %s  — welcome.txt %s\n' \
    "$([ "${M_WELCOME#ok}" != "$M_WELCOME" ] && echo 0 || echo 1)" "$M_WELCOME"
  [ "$NFAIL" = 0 ] && exit 0
  exit 1
}
# A signal mid-run (^C, the pane closing) must not leave the login half-made:
# the same teardown and summary, exit 1.
on_signal() { trap - INT TERM HUP; printf '\n%s: interrupted — tearing down\n' "$PROG" >&2; finish; }
trap on_signal INT TERM HUP

step_open || finish
step_welcome || :
step_login || :
step_guide || :
step_capture || :
step_doctor || :
step_daemons || :
finish
