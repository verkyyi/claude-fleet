#!/bin/bash
# fleet-idle-cost.sh — what the fleet costs this machine when nobody is working
# (issue #4355, EPIC #4354 C1): processes started a second, who starts them, and
# the CPU the long-lived ones use — measured only while the machine is idle.
#
#   fleet-idle-cost.sh [--secs 60] [--top 10] [--json]
#       idle ⇒ measure one window (bin/fleet-idle-cost.py), print it (TSV, or the
#       JSON with --json) and keep it as $FLEET_CONF_DIR/idle-cost/last.json.
#       Busy at the start or at the end ⇒ nothing is measured: one line
#       `idle-cost<TAB>busy<TAB><reason>` (JSON: {"state":"busy",…}), exit 3.
#   fleet-idle-cost.sh --idle
#       only the idle predicate: prints `idle` (exit 0) or the reason (exit 1).
#   fleet-idle-cost.sh --last [--json]
#       the kept reading, unmeasured (exit 1: none yet).
#
# "Idle" is fleet_idle_now (bin/fleet-lib.sh) — the one definition every batch
# member's before / after reading uses. The measuring session is not "someone
# working": its own window is left out of the predicate and its own process tree
# (the caller's pane, and this script) out of the reading.
# FLEET_IDLE_COST_WARN (50 a second) is the doctor's `idle-cost` line; the rate
# is the number, the ranking (0.2 s `ps`, short-lived processes missed) says who.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

secs=60 top=10 fmt=tsv mode=measure
while [ $# -gt 0 ]; do
  case "$1" in
    --secs) secs="${2:-}"; shift ;;
    --top)  top="${2:-}"; shift ;;
    --json) fmt=json ;;
    --idle) mode=idle ;;
    --last) mode=last ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "fleet-idle-cost.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$secs" in ''|*[!0-9.]*) echo "fleet-idle-cost.sh: --secs wants seconds" >&2; exit 2 ;; esac
case "$top" in ''|*[!0-9]*) echo "fleet-idle-cost.sh: --top wants a number" >&2; exit 2 ;; esac

dir="$FLEET_CONF_DIR/idle-cost"
last="$dir/last.json"
render() { if [ "$fmt" = json ]; then python3 "$BIN/fleet-idle-cost.py" render "$1" --json
           else python3 "$BIN/fleet-idle-cost.py" render "$1" --top "$top"; fi; }
busy() {
  if [ "$fmt" = json ]; then
    python3 -c 'import json,sys,time; print(json.dumps({"ts": int(time.time()), "state": "busy", "reason": sys.argv[1]}, ensure_ascii=False))' "$1"
  else printf 'idle-cost\tbusy\t%s\n' "$1"; fi
  exit 3
}

case "$mode" in
  idle) fleet_idle_now; exit $? ;;
  last) [ -f "$last" ] || { echo "fleet-idle-cost.sh: no reading yet ($last)" >&2; exit 1; }
        render "$last"; exit $? ;;
esac

why=$(fleet_idle_now) || busy "$why"
mkdir -p "$dir" 2>/dev/null
tmp=$(mktemp "$dir/.reading.XXXXXX") || { echo "fleet-idle-cost.sh: cannot write $dir" >&2; exit 1; }
trap 'rm -f "$tmp"' EXIT
excl=(--exclude-pid "$$")
ppid_=$(fleet_pane_fmt '#{pane_pid}' 2>/dev/null)
case "$ppid_" in ''|*[!0-9]*) ;; *) excl+=(--exclude-pid "$ppid_") ;; esac
python3 "$BIN/fleet-idle-cost.py" sample --secs "$secs" --top "$top" --out "$tmp" "${excl[@]}" || exit 1
why=$(fleet_idle_now) || busy "$why (became busy during the window)"
mv -f "$tmp" "$last"
render "$last"
