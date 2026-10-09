#!/bin/bash
# fleet-task.sh — `fleet task`: a scheduled AGENT task on a managed machine (issue
# #2529, EPIC #2524 C5) — "every day at 07:00, as me, open a session that runs this
# prompt". The same register as `fleet service` (an entry with `kind: task`); the
# machine's daemon opens the session when a slot is due, keeps every attempt,
# retries a failed one and, past the limit, marks it failed and raises an alert.
#
#   fleet task add <name> (--at HH:MM | --cron 'm h dom mon dow') --prompt <text>
#                  [--tz Asia/Shanghai] [--retries N (2)] [--retry-delay S (300)]
#                  [--window <name, {date} = the slot's day> (<name>-{date})]
#                  [--done-file <path, {date}>] [--timeout S (3600)] [--idle S (600)]
#                  [--fleet <session>] [--bark <credential>] [--env K=V]… [--cred C]…
#                  [--path P]… (its work / skill dirs: `fleet service move` carries them, #2530)
#                               register (or replace) it. With --done-file a run is ok
#                               only when the session finishes with that file in place
#   fleet task ls [--json]      your tasks: status · schedule · last run · next run
#   fleet task run <name> --now one run now, outside the schedule
#   fleet task schedule <name> (--at HH:MM | --cron '…') [--tz Z]
#                               a new schedule; a slot it skips is not caught up
#   fleet task logs <name> [-n N] [-f]
#   fleet task rm|stop|start|restart <name>
#   fleet task cred set|rm <C>  = fleet service cred (a --bark key lives there)
#
# Seams (selftests): those of fleet-service.sh (FLEET_NODE_SUPERVISOR,
# FLEET_SERVICE_SUDO, FLEET_SERVICE_LOGIN, FLEET_NODE_LOG).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
SUP=${FLEET_NODE_SUPERVISOR:-"/Library/Application Support/claude-fleet/current/bin/fleet-node-supervisor.py"}
PY=/usr/bin/python3
[ -x "$PY" ] || PY=python3
ME=${FLEET_SERVICE_LOGIN:-$(id -un)}

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "fleet task · $*" >&2; exit "${2:-1}"; }

[ -f "$SUP" ] || die "this machine has no fleet daemon ($SUP) — fleet task is for a managed machine (sudo fleet node install)"

cmd=${1:-ls}
[ $# -gt 0 ] && shift
case $cmd in
  -h|--help|help) usage; exit 0 ;;
  ls)
    exec "$PY" -I "$SUP" service ls --login "$ME" --kind task "$@" ;;
  logs|cred)
    exec bash "$here/fleet-service.sh" "$cmd" "$@" ;;
  rm|stop|start|restart)
    [ $# -eq 1 ] || die "usage: fleet task $cmd <name>" 2
    exec bash "$here/fleet-service.sh" __root "$cmd" --login "$ME" --name "$1" ;;
  run)
    [ $# -ge 1 ] || die "usage: fleet task run <name> --now" 2
    name=$1; shift
    [ "${1:-}" = --now ] || die "usage: fleet task run $name --now   (the schedule runs it otherwise)" 2
    exec bash "$here/fleet-service.sh" __root run --login "$ME" --name "$name" ;;
  schedule)
    [ $# -ge 3 ] || die "usage: fleet task schedule <name> (--at HH:MM | --cron '…') [--tz Z]" 2
    name=$1; shift
    args=()
    while [ $# -gt 0 ]; do
      case $1 in
        --at|--cron|--tz) [ $# -ge 2 ] || die "$1 needs a value" 2; args+=("$1" "$2"); shift 2 ;;
        *) die "schedule: unknown $1" 2 ;;
      esac
    done
    exec bash "$here/fleet-service.sh" __root schedule --login "$ME" --name "$name" ${args[@]+"${args[@]}"} ;;
  add)
    [ $# -ge 1 ] || die "usage: fleet task add <name> (--at HH:MM | --cron '…') --prompt <text> [opts…]" 2
    name=$1; shift
    args=()
    while [ $# -gt 0 ]; do
      case $1 in
        --at|--cron|--tz|--prompt|--retries|--retry-delay|--window|--done-file|--timeout|--idle|--fleet|--bark|--env|--cred|--path)
          [ $# -ge 2 ] || die "$1 needs a value" 2
          args+=("$1" "$2"); shift 2 ;;
        *) die "add: unknown $1" 2 ;;
      esac
    done
    exec bash "$here/fleet-service.sh" __root add --kind task --login "$ME" --name "$name" ${args[@]+"${args[@]}"} ;;
  *) usage >&2; exit 2 ;;
esac
