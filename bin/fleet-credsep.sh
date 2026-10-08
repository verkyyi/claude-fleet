#!/usr/bin/env bash
# fleet-credsep.sh — on a trusted machine, keep this login's subscription
# credentials and node token where its sessions cannot read them (issue #1971,
# EPIC #1967 C4). bin/fleet-credsep.py does the work; this resolves the login,
# its conf and sudo.
#
#   fleet-credsep.sh install [--dry-run|--force]
#                                           separate (needs `sudo -n`, once;
#                                           --dry-run needs none: what it would do)
#   fleet-credsep.sh install --adopt        root takes the login's upstream / hub
#                                           settings into root's <LIB>/<login>.conf
#                                           (the only place the proxy reads them,
#                                           issue #2290) and restarts the proxy
#   sudo fleet-credsep.sh install --login <X> --fresh [--pool-src <dir>] [--install-dir <dir>]
#                                           a login fleet-login-new.sh has just
#                                           opened (issue #2294): separated before
#                                           its first session — the preflight is
#                                           "nothing runs as it"; --pool-src copies
#                                           the team pool INTO the store (the login
#                                           gets label markers only); --install-dir
#                                           = the login's own clone
#   fleet-credsep.sh uninstall [--dry-run]  undo: every file back where it was
#                                           (--dry-run, no sudo: the steps back)
#   fleet-credsep.sh status [--json]        separated or not (exit 3 = not)
#   fleet-credsep.sh check                  the doctor's `credsep` row
#   fleet-credsep.sh check --fix            and first move a root agent's log out of
#                                           the login's home (issue #2296; sudo once —
#                                           an admin: sudo bash … check --fix --login X)
#   fleet-credsep.sh rootlogs               the doctor's `rootlog` row: every root
#                                           service whose log lies in a home (WARN)
#   fleet-credsep.sh setenv [--check]      node.env's KEY=VALUE lines (stdin — the
#                                           token never on argv) into the store: root
#                                           edits its copy in place, node.pub.env
#                                           follows, C/node.env stays the link (issue
#                                           #2316 — fleet-node-join.sh, `fleet node
#                                           compute`). Exit 3 = not separated (write
#                                           node.env yourself), 4 = no password-less
#                                           sudo (the line to hand an admin printed);
#                                           --check answers that, writes nothing
#   fleet-credsep.sh plan                   every login on this machine: its state
#                                           and the exact commands — dry run, the
#                                           ONE sudo to type, status, the way back
#                                           (issue #2135; no sudo, changes nothing)
#
# Run as root (`sudo bash …/fleet-credsep.sh install`, the line this script and
# the doctor print), the login is SUDO_USER's — or `--login <login>` — and its
# conf dir is under THAT login's home: never root's (issue #2135, BREAK-IT
# `cred-sep-sudo-root`). Root with neither is refused (exit 2).
#   fleet-credsep.sh machine install|uninstall|refresh [--logins a,b] [--dry-run] [--force]
#                                           the machine's ONE shared proxy (issue
#                                           #2217): every login (default: each with
#                                           ~/.claude/fleet) a tenant of it — one
#                                           sudo for the machine; uninstall = back
#                                           to a proxy per login, byte for byte;
#                                           refresh = follow this install's code
#   fleet-credsep.sh machine join [--logins a,b] [--dry-run]
#                                           a login separated on its OWN proxy
#                                           (com.claude-fleet.credsep.<login>) onto
#                                           the shared one with no gap: the shared
#                                           proxy answers for it first, the agent's
#                                           leases follow, then the own proxy goes
#                                           (kept in the store's backup/) — issue #2432
#   fleet-credsep.sh machine leave --logins a,b
#                                           the way back: its own proxy again, on
#                                           its old port with its own key
#   fleet-credsep.sh machine status [--json]  anyone: shared or per-login, as whom,
#                                           which logins, the version
#   fleet-credsep.sh apply [--dry-run]      the install pass: converge on the
#                                           switch — FLEET_CRED_SEPARATE=1 and not
#                                           separated → install; 0 and separated →
#                                           uninstall; separated → refresh the
#                                           root-owned code copy. No password-less
#                                           sudo → one line saying what to run.
#
# Preflight (issue #2273): install / machine install refuse (exit 6, nothing
# moved) a login whose credential proxy is off or not running, whose live
# sessions do not all talk to it yet, or that has an EPIC batch running —
# moving the credentials first is what took m4's subscription away on
# 2026-10-07. --force skips it. A step that fails halfway puts every login it
# took from nothing back, from the store's meta.json (exit 1; 5 = the way back
# failed too, the steps to do by hand printed).
#
# Separated: a role account (_fleetcred / fleetcred) owns
# /var/db/fleet-cred/<login>/ (0700) — the leased credentials, Codex auth.json
# and node.env — and runs this login's credential proxy; the node agent starts
# as root, takes its token down a pipe and runs as the login. A session reading
# the store or node.env gets "Permission denied". Sessions reach the
# subscription only through the proxy (FLEET_CRED_PROXY=1, C5's wiring).
# Config: FLEET_CRED_SEPARATE in fleet.conf [common] (0 = today's files, byte
# for byte — the default). See docs/CRED-SEPARATE.md.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SUDO="${FLEET_CREDSEP_SUDO-sudo -n}"

cmd="${1:-}"; [ $# -gt 0 ] && shift
# --login <login> / --install-dir <dir> may sit anywhere after the command; the
# rest pass through
want='' instdir='' rest=()
while [ $# -gt 0 ]; do
  case "$1" in
    --login)   want="${2:-}"; [ $# -gt 1 ] && shift ;;
    --login=*) want="${1#--login=}" ;;
    --install-dir)   instdir="${2:-}"; [ $# -gt 1 ] && shift ;;
    --install-dir=*) instdir="${1#--install-dir=}" ;;
    *) rest+=("$1") ;;
  esac
  shift
done
set -- ${rest[@]+"${rest[@]}"}

# whose credentials: as root the login is SUDO_USER's or --login's, never root's
# (a `sudo bash fleet-credsep.sh install` used to separate a `root` store and
# leave the login's agent reading a node.env it no longer could — #2135)
SELF="$(id -un)"
if [ "$(id -u)" = 0 ]; then
  LOGIN="${want:-${SUDO_USER:-}}"
  if [ -z "$LOGIN" ] || [ "$LOGIN" = root ]; then
    case "$cmd" in install|uninstall|apply|setenv)
      echo "fleet-credsep: as root, say whose credentials: run it with sudo from the login, or add --login <login>" >&2
      exit 2 ;;
    esac
    LOGIN="$SELF"
  fi
elif [ "${FLEET_CREDSEP_TEST:-}" = 1 ] && [ -n "$want" ]; then
  LOGIN="$want"     # the selftest's sandbox: another login played by this user (FLEET_CREDSEP_PW)
else
  LOGIN="$SELF"
  if [ -n "$want" ] && [ "$want" != "$SELF" ]; then
    echo "fleet-credsep: --login $want is for root (sudo); this is $SELF" >&2; exit 2
  fi
fi
if [ "$LOGIN" = "$SELF" ] && [ "$(id -u)" != 0 ]; then
  CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
else
  LHOME=''
  if [ "${FLEET_CREDSEP_TEST:-}" = 1 ] && [ -f "${FLEET_CREDSEP_PW:-}" ]; then
    LHOME=$(awk -F: -v l="$LOGIN" 'NF == 4 && $1 == l { print $4; exit }' "$FLEET_CREDSEP_PW")
  fi
  [ -n "$LHOME" ] || LHOME="$(python3 -I -c 'import pwd, sys; print(pwd.getpwnam(sys.argv[1]).pw_dir)' "$LOGIN" 2>/dev/null)" \
    || { echo "fleet-credsep: no such login $LOGIN" >&2; exit 2; }
  CONF="${FLEET_CONF_DIR:-$LHOME/.config/claude-fleet}"
  [ "$(id -u)" = 0 ] || CONF="$LHOME/.config/claude-fleet"   # the sandbox's other login: its own
fi

# the install the login's launcher reads fleet.conf from: this one, or (root,
# opening a new login — fleet-login-new.sh, issue #2294) the login's own clone
INST="${instdir:-$BIN/..}"
_env_switch="${FLEET_CRED_SEPARATE:-}"
set -a
for f in "$BIN/../fleet.conf" "$CONF/fleet.settings" "$CONF/fleet.conf"; do
  # shellcheck source=/dev/null
  [ -f "$f" ] && . "$f" >/dev/null 2>&1
done
set +a
[ -n "$_env_switch" ] && FLEET_CRED_SEPARATE="$_env_switch"
export FLEET_CRED_SEPARATE="${FLEET_CRED_SEPARATE:-0}"

py() { python3 -I "$BIN/fleet-credsep.py" "$@"; }
root_py() { # the privileged half, through sudo (env seams passed explicitly)
  # shellcheck disable=SC2086
  $SUDO env ${FLEET_CREDSEP_ROOT_BASE:+FLEET_CREDSEP_ROOT_BASE="$FLEET_CREDSEP_ROOT_BASE"} \
    ${FLEET_CREDSEP_RUN_BASE:+FLEET_CREDSEP_RUN_BASE="$FLEET_CREDSEP_RUN_BASE"} \
    ${FLEET_CREDSEP_LOG_BASE:+FLEET_CREDSEP_LOG_BASE="$FLEET_CREDSEP_LOG_BASE"} \
    ${FLEET_CREDSEP_LIB:+FLEET_CREDSEP_LIB="$FLEET_CREDSEP_LIB"} \
    ${FLEET_CREDSEP_DAEMON_DIR:+FLEET_CREDSEP_DAEMON_DIR="$FLEET_CREDSEP_DAEMON_DIR"} \
    ${FLEET_CREDSEP_ROLE:+FLEET_CREDSEP_ROLE="$FLEET_CREDSEP_ROLE"} \
    ${FLEET_CREDSEP_SVC:+FLEET_CREDSEP_SVC="$FLEET_CREDSEP_SVC"} \
    ${FLEET_CREDSEP_TEST:+FLEET_CREDSEP_TEST="$FLEET_CREDSEP_TEST"} \
    ${FLEET_CREDSEP_PREFLIGHT:+FLEET_CREDSEP_PREFLIGHT="$FLEET_CREDSEP_PREFLIGHT"} \
    ${FLEET_CREDSEP_BOOT_TRIES:+FLEET_CREDSEP_BOOT_TRIES="$FLEET_CREDSEP_BOOT_TRIES"} \
    ${FLEET_CREDSEP_PW:+FLEET_CREDSEP_PW="$FLEET_CREDSEP_PW"} \
    python3 -I "$BIN/fleet-credsep.py" "$@" --login "$LOGIN" --conf-dir "$CONF" --install-dir "$INST"
}
can_sudo() { [ -z "$SUDO" ] || $SUDO true 2>/dev/null; }
separated() { [ -f "$CONF/credsep.json" ]; }
shared() { grep -q '"shared": true' "$CONF/credsep.json" 2>/dev/null; }
root_machine() { # the machine verbs (issue #2217): no --login, the logins are named
  # shellcheck disable=SC2086
  $SUDO env ${FLEET_CREDSEP_ROOT_BASE:+FLEET_CREDSEP_ROOT_BASE="$FLEET_CREDSEP_ROOT_BASE"} \
    ${FLEET_CREDSEP_RUN_BASE:+FLEET_CREDSEP_RUN_BASE="$FLEET_CREDSEP_RUN_BASE"} \
    ${FLEET_CREDSEP_LOG_BASE:+FLEET_CREDSEP_LOG_BASE="$FLEET_CREDSEP_LOG_BASE"} \
    ${FLEET_CREDSEP_LIB:+FLEET_CREDSEP_LIB="$FLEET_CREDSEP_LIB"} \
    ${FLEET_CREDSEP_DAEMON_DIR:+FLEET_CREDSEP_DAEMON_DIR="$FLEET_CREDSEP_DAEMON_DIR"} \
    ${FLEET_CREDSEP_ROLE:+FLEET_CREDSEP_ROLE="$FLEET_CREDSEP_ROLE"} \
    ${FLEET_CREDSEP_SVC:+FLEET_CREDSEP_SVC="$FLEET_CREDSEP_SVC"} \
    ${FLEET_CREDSEP_TEST:+FLEET_CREDSEP_TEST="$FLEET_CREDSEP_TEST"} \
    ${FLEET_CREDSEP_PREFLIGHT:+FLEET_CREDSEP_PREFLIGHT="$FLEET_CREDSEP_PREFLIGHT"} \
    ${FLEET_CREDSEP_BOOT_TRIES:+FLEET_CREDSEP_BOOT_TRIES="$FLEET_CREDSEP_BOOT_TRIES"} \
    ${FLEET_CREDSEP_PW:+FLEET_CREDSEP_PW="$FLEET_CREDSEP_PW"} \
    ${FLEET_CREDSEP_USERS:+FLEET_CREDSEP_USERS="$FLEET_CREDSEP_USERS"} \
    ${FLEET_CREDSEP_HOMES:+FLEET_CREDSEP_HOMES="$FLEET_CREDSEP_HOMES"} \
    ${FLEET_CRED_SHARED_PORT:+FLEET_CRED_SHARED_PORT="$FLEET_CRED_SHARED_PORT"} \
    python3 -I "$BIN/fleet-credsep.py" machine "$@"
}

case "$cmd" in
  install|uninstall)
    if [ "${1:-}" = --dry-run ] && [ "$(id -u)" != 0 ]; then
      # a dry run moves nothing: run as the login, no sudo (what the operator
      # reads BEFORE typing the one sudo)
      python3 -I "$BIN/fleet-credsep.py" "$cmd" --dry-run --login "$LOGIN" --conf-dir "$CONF" --install-dir "$INST"
      exit $?
    fi
    can_sudo || { echo "fleet-credsep: $cmd needs password-less sudo once — run: sudo bash $BIN/fleet-credsep.sh $cmd" >&2; exit 4; }
    root_py "$cmd" "$@"
    ;;
  setenv)
    separated || { echo "fleet-credsep: $LOGIN is not separated — node.env is its own file" >&2; exit 3; }
    if [ "$(id -u)" != 0 ] && ! can_sudo; then
      echo "fleet-credsep: $LOGIN's node.env is in the credential store; writing it needs root once — an admin runs: printf '<KEY>=<value>\n' | sudo bash $BIN/fleet-credsep.sh setenv --login $LOGIN" >&2
      exit 4
    fi
    [ "${1:-}" = --check ] && exit 0
    root_py setenv
    ;;
  plan) python3 -I "$BIN/fleet-credsep.py" plan --bin "$BIN" ;;
  machine)
    verb="${1:-}"
    case "$verb" in
      status) exec python3 -I "$BIN/fleet-credsep.py" machine "$@" ;;
      install|uninstall|refresh|join|leave) ;;
      *) echo "fleet-credsep: machine install|uninstall|refresh|join|leave|status" >&2; exit 2 ;;
    esac
    case " $* " in
      *" --dry-run "*) [ "$(id -u)" = 0 ] || { python3 -I "$BIN/fleet-credsep.py" machine "$@"; exit $?; } ;;
    esac
    can_sudo || { echo "fleet-credsep: machine $verb needs root once — run: sudo bash $BIN/fleet-credsep.sh machine $*" >&2; exit 4; }
    root_machine "$@"
    ;;
  status) py status --conf-dir "$CONF" "$@" ;;
  check)
    if [ "${1:-}" = --fix ]; then
      # launchd opens a root job's log as root and follows a symlink: the agent's
      # log leaves the home for /var/log/fleet-cred/<login>/ (issue #2296)
      can_sudo || { echo "fleet-credsep: check --fix needs root once — run: sudo bash $BIN/fleet-credsep.sh check --fix" >&2; exit 4; }
      root_py relog || exit $?
      [ "$(id -u)" = 0 ] && exit 0     # root reads every store: the check is the login's to run
    fi
    py check --conf-dir "$CONF" ;;
  rootlogs) py rootlogs ;;
  apply)
    dry=''; [ "${1:-}" = --dry-run ] && dry=--dry-run
    if shared; then
      # a tenant of the machine's shared proxy (issue #2217): the machine switch
      # owns it, never this login's FLEET_CRED_SEPARATE. An admin login keeps the
      # root-owned code on this install's version (follows stable).
      if can_sudo; then
        out=$(root_machine refresh ${dry:+"$dry"} 2>&1); rc=$?
        [ "$rc" = 0 ] && echo "credsep: ok — shared · $(printf '%s\n' "$out" | tail -1)" \
                      || { echo "credsep: WARN — shared, refresh failed: $(printf '%s\n' "$out" | tail -1)"; exit 1; }
      else
        echo "credsep: ok — shared (the machine's proxy; its code follows an admin's sync: sudo bash $BIN/fleet-credsep.sh machine refresh)"
      fi
    elif [ "$FLEET_CRED_SEPARATE" = 1 ]; then
      if ! can_sudo; then
        separated && echo "credsep: ok — separated (code copy not refreshed: no password-less sudo)" \
                  || echo "credsep: WARN — FLEET_CRED_SEPARATE=1 needs root once: sudo bash $BIN/fleet-credsep.sh install"
        exit 0
      fi
      out=$(root_py install ${dry:+"$dry"} 2>&1); rc=$?
      [ "$rc" = 0 ] && echo "credsep: ok — $(printf '%s\n' "$out" | tail -1)" \
                    || { echo "credsep: WARN — $(printf '%s\n' "$out" | tail -1)"; exit 1; }
    elif separated; then
      can_sudo || { echo "credsep: WARN — FLEET_CRED_SEPARATE=0 but separated; undo needs root: sudo bash $BIN/fleet-credsep.sh uninstall"; exit 0; }
      out=$(root_py uninstall ${dry:+"$dry"} 2>&1); rc=$?
      [ "$rc" = 0 ] && echo "credsep: ok — $(printf '%s\n' "$out" | tail -1)" \
                    || { echo "credsep: WARN — $(printf '%s\n' "$out" | tail -1)"; exit 1; }
    else
      echo "credsep: skip — off (FLEET_CRED_SEPARATE=0)"
    fi
    ;;
  -h|--help|'')
    sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    [ -n "$cmd" ]; exit $?
    ;;
  *) echo "fleet-credsep: unknown command $cmd (see --help)" >&2; exit 2 ;;
esac
