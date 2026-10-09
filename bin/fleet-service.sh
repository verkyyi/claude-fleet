#!/bin/bash
# fleet-service.sh — `fleet service`: a program you keep running AS YOURSELF on a
# managed machine, registered with the machine's daemon (issue #2525, EPIC #2524
# C1). The daemon (fleet-node-supervisor.py, root) runs it demoted to you, keeps
# it up, and writes its output to /var/log/fleet-node/logins/<you>/<name>.log —
# no hand-written LaunchDaemon / LaunchAgent.
#
#   fleet service add <name> [--env K=V]… [--env-key K]… [--cred C]… [--path P]… -- <cmd> [args…]
#                               register (or replace) it; <cmd> is resolved to an
#                               absolute path here. --env-key K takes K's value from
#                               THIS shell. --cred C: the credential C (stored with
#                               `cred set`) is handed to it as $C at start — the
#                               entry holds the name only
#   fleet service rm|stop|start|restart <name>
#   fleet service ls [--json]   your services: state · command · last log line
#   fleet service logs <name> [-n N] [-f]
#   fleet service cred set <C>  the value on stdin (never an argument)
#   fleet service cred rm <C>
#
# Writing the register is root's: this runs the ROOT runtime's supervisor through
# `sudo -n`; with no passwordless sudo it prints the one line an admin runs.
#
# Seams (selftests): FLEET_NODE_SUPERVISOR (the supervisor script),
# FLEET_SERVICE_SUDO (default `sudo -n`; empty = run it directly),
# FLEET_SERVICE_LOGIN (default `id -un`), FLEET_NODE_LOG (the log root).
set -uo pipefail

SUP=${FLEET_NODE_SUPERVISOR:-"/Library/Application Support/claude-fleet/current/bin/fleet-node-supervisor.py"}
PY=/usr/bin/python3
[ -x "$PY" ] || PY=python3
SUDO=${FLEET_SERVICE_SUDO-sudo -n}
ME=${FLEET_SERVICE_LOGIN:-$(id -un)}

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "fleet service · $*" >&2; exit "${2:-1}"; }

[ -f "$SUP" ] || die "this machine has no fleet daemon ($SUP) — fleet service is for a managed machine (sudo fleet node install)"

# run the supervisor as root: directly when we are root, else through sudo; no
# passwordless sudo → the line an admin runs (stdin: say so, never echo a value)
as_root() {
  if [ "$(id -u)" = 0 ] || [ -z "$SUDO" ]; then
    "$PY" -I "$SUP" service "$@"; return
  fi
  if $SUDO "$PY" -I "$SUP" service "$@"; then return 0; fi
  local rc=$?
  if ! $SUDO -l "$PY" -I "$SUP" service >/dev/null 2>&1; then
    {
      echo "fleet service · 这台机器没有给你免密 sudo；请管理员运行："
      printf '  sudo %q -I %q service' "$PY" "$SUP"
      printf ' %q' "$@"
      printf '\n'
      case "$1" in cred) echo "  （值从标准输入读：管理员运行时粘贴，回车后 Ctrl-D）" ;; esac
    } >&2
    return 3
  fi
  return "$rc"
}

cmd=${1:-ls}
[ $# -gt 0 ] && shift
case $cmd in
  -h|--help|help) usage; exit 0 ;;
  ls)
    exec "$PY" -I "$SUP" service ls --login "$ME" "$@" ;;
  logs)
    [ $# -ge 1 ] || die "usage: fleet service logs <name> [-n N] [-f]" 2
    name=$1; shift
    n=50; follow=0
    while [ $# -gt 0 ]; do
      case $1 in
        -n) n=${2:-50}; shift 2 ;;
        -f) follow=1; shift ;;
        *) die "logs: unknown $1" 2 ;;
      esac
    done
    lg="${FLEET_NODE_LOG:-/var/log/fleet-node}/logins/$ME/$name.log"
    if [ "$follow" = 1 ]; then
      [ -r "$lg" ] || die "no log yet ($lg)"
      exec tail -n "$n" -F "$lg"
    fi
    exec "$PY" -I "$SUP" service logs --login "$ME" --name "$name" -n "$n" ;;
  rm|stop|start|restart)
    [ $# -eq 1 ] || die "usage: fleet service $cmd <name>" 2
    as_root "$cmd" --login "$ME" --name "$1" ;;
  cred)
    verb=${1:-}; c=${2:-}
    case $verb in set|rm) ;; *) die "usage: fleet service cred set|rm <name>  (set: the value on stdin)" 2 ;; esac
    [ -n "$c" ] || die "usage: fleet service cred $verb <name>" 2
    if [ "$verb" = set ] && [ -t 0 ]; then
      printf '%s 的值（不回显）：' "$c" >&2
      IFS= read -rs val; echo >&2
      [ -n "$val" ] || die "no value" 2
      printf '%s\n' "$val" | as_root cred set --login "$ME" --name "$c"
    else
      as_root cred "$verb" --login "$ME" --name "$c"
    fi ;;
  add)
    [ $# -ge 1 ] || die "usage: fleet service add <name> [opts…] -- <cmd> [args…]" 2
    name=$1; shift
    args=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do
      case $1 in
        --env|--cred|--path)
          [ $# -ge 2 ] || die "$1 needs a value" 2
          args+=("$1" "$2"); shift 2 ;;
        --env-key)
          [ $# -ge 2 ] || die "--env-key needs a name" 2
          printenv "$2" >/dev/null || die "--env-key $2: not set in this shell" 2
          args+=(--env "$2=$(printenv "$2")" --env-key "$2"); shift 2 ;;
        *) die "add: unknown $1 (the command goes after --)" 2 ;;
      esac
    done
    [ "${1:-}" = -- ] && shift
    [ $# -ge 1 ] || die "add: nothing to run — fleet service add $name -- <cmd> [args…]" 2
    want=$1; exe=$1; shift
    case $exe in
      /*) ;;
      */*) exe="$(cd "$(dirname "$exe")" 2>/dev/null && pwd -P)/$(basename "$exe")" ;;
      *) exe=$(command -v "$exe") || die "add: $want not found on PATH" 2 ;;
    esac
    [ -x "$exe" ] || die "add: $exe is not executable" 2
    as_root add --login "$ME" --name "$name" ${args[@]+"${args[@]}"} -- "$exe" "$@" ;;
  *) usage >&2; exit 2 ;;
esac
