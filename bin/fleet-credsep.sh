#!/usr/bin/env bash
# fleet-credsep.sh — on a trusted machine, keep this login's subscription
# credentials and node token where its sessions cannot read them (issue #1971,
# EPIC #1967 C4). bin/fleet-credsep.py does the work; this resolves the login,
# its conf and sudo.
#
#   fleet-credsep.sh install [--dry-run]    separate (needs `sudo -n`, once)
#   fleet-credsep.sh uninstall [--dry-run]  undo: every file back where it was
#   fleet-credsep.sh status [--json]        separated or not (exit 3 = not)
#   fleet-credsep.sh check                  the doctor's `credsep` row
#   fleet-credsep.sh apply [--dry-run]      the install pass: converge on the
#                                           switch — FLEET_CRED_SEPARATE=1 and not
#                                           separated → install; 0 and separated →
#                                           uninstall; separated → refresh the
#                                           root-owned code copy. No password-less
#                                           sudo → one line saying what to run.
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
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
LOGIN="$(id -un)"
SUDO="${FLEET_CREDSEP_SUDO-sudo -n}"

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
    python3 -I "$BIN/fleet-credsep.py" "$@" --login "$LOGIN" --conf-dir "$CONF" --install-dir "$BIN/.."
}
can_sudo() { [ -z "$SUDO" ] || $SUDO true 2>/dev/null; }
separated() { [ -f "$CONF/credsep.json" ]; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  install|uninstall)
    can_sudo || { echo "fleet-credsep: $cmd needs password-less sudo once — run: sudo bash $BIN/fleet-credsep.sh $cmd" >&2; exit 4; }
    root_py "$cmd" "$@"
    ;;
  status) py status --conf-dir "$CONF" "$@" ;;
  check)  py check --conf-dir "$CONF" ;;
  apply)
    dry=''; [ "${1:-}" = --dry-run ] && dry=--dry-run
    if [ "$FLEET_CRED_SEPARATE" = 1 ]; then
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
