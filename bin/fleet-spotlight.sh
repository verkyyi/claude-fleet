#!/bin/bash
# fleet-spotlight.sh — a managed Mac runs with Spotlight OFF (issue #3402).
#
# Spotlight indexing every worktree, git object and session log ate the
# machine the sessions run on: 2026-10-11, macmini's fseventsd at 115% CPU
# (load 30 on 15 cores), mini2's spotlightknowledged at 99% for 7 hours —
# while every volume there already read «Indexing disabled». So OFF is two
# halves, and `mdutil` alone is only the first:
#   volumes   `mdutil -a -i off` (+ `mdutil -a -E` the first time, the old
#             index thrown away)
#   agents    each person's CoreSpotlight knowledge agents
#             (com.apple.spotlightknowledged{,.importer,.updater}) — not
#             governed by mdutil — disabled in their gui/ and user/ domains
#             and booted out
#
#   fleet-spotlight.sh off [--tick]    root: converge to off; one line. --tick
#                                      (the machine daemon's hourly task) is
#                                      quiet when nothing changed
#   fleet-spotlight.sh status [--check] any login: one line. --check exit 0 off ·
#                                      1 WARN (a volume indexing, a knowledge
#                                      agent still running, a Spotlight / fsevents
#                                      process hot) · 2 not a managed machine
#                                      (no row)
#
# The machine daemon (fleet-node-supervisor.py, the `spotlight` task) runs
# `off --tick` at its start and every hour, so a new managed machine is off once
# its daemon is up, and a macOS update that turns indexing back on is undone
# within the hour. `fleet doctor`'s `spotlight` row reads `status --check`.
# A machine that wants it on: `sudo touch /var/db/fleet-node/spotlight.keep`.
# Not a managed machine (no <state>/machine.env) ⇒ status says nothing, off
# refuses — a person's own Mac is theirs.
#
# Env (sandbox seams): FLEET_NODE_STATE (/var/db/fleet-node) · FLEET_NODE_TEST=1
# (no root needed) · FLEET_SPOTLIGHT_MDUTIL (mdutil) · FLEET_SPOTLIGHT_LAUNCHCTL
# (launchctl) · FLEET_SPOTLIGHT_PS (a command printing `user etime pcpu command`
# rows) · FLEET_SPOTLIGHT_UIDS (the people's uids; default every uid ≥ 500) ·
# FLEET_SPOTLIGHT_HOT_PCT (50) · FLEET_SPOTLIGHT_HOT_SECS (600)
# Exit: see above · 2 usage
set -uo pipefail

PROG=fleet-spotlight
STATE="${FLEET_NODE_STATE:-/var/db/fleet-node}"
MDUTIL="${FLEET_SPOTLIGHT_MDUTIL:-mdutil}"
LAUNCHCTL="${FLEET_SPOTLIGHT_LAUNCHCTL:-launchctl}"
HOT_PCT="${FLEET_SPOTLIGHT_HOT_PCT:-50}"
HOT_SECS="${FLEET_SPOTLIGHT_HOT_SECS:-600}"
AGENTS="com.apple.spotlightknowledged com.apple.spotlightknowledged.importer com.apple.spotlightknowledged.updater"
FIX="sudo ~/.claude/fleet/bin/fleet-spotlight.sh off"

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

managed() { [ -e "$STATE/machine.env" ]; }

# volumes_on — one volume per line whose index is on (mdutil -as reads without root)
volumes_on() {
  "$MDUTIL" -as 2>/dev/null | awk '
    /^[^ \t]/ { vol = $0; sub(/:$/, "", vol); next }
    /[Ii]ndexing enabled/ { print vol }'
}

# procs — `user etime pcpu name` for every running process (name = basename)
procs() {
  if [ -n "${FLEET_SPOTLIGHT_PS:-}" ]; then sh -c "$FLEET_SPOTLIGHT_PS"
  else ps -axo user=,etime=,pcpu=,comm= 2>/dev/null; fi | awk '{ n = $4; sub(/.*\//, "", n); print $1, $2, $3, n }'
}

# knowledge — the users a CoreSpotlight knowledge agent still runs for
knowledge() {
  procs | awk '$4 ~ /^spotlightknowledged(\.importer)?$/ && !seen[$1]++ { printf "%s%s", (n++ ? " " : ""), $1 }'
}

# hot — `name(user) pcpu%` for a Spotlight / fsevents process at ≥ HOT_PCT for ≥ HOT_SECS
hot() {
  procs | awk -v pct="$HOT_PCT" -v secs="$HOT_SECS" '
    function age(e,   d, p, n, s) {
      d = 0; if (index(e, "-")) { d = substr(e, 1, index(e, "-") - 1); e = substr(e, index(e, "-") + 1) }
      n = split(e, p, ":"); s = 0
      for (i = 1; i <= n; i++) s = s * 60 + p[i]
      return d * 86400 + s }
    $4 ~ /^(mds|mds_stores|mdworker.*|mdsync|spotlightknowledged.*|corespotlightd|fseventsd)$/ \
      && $3 + 0 >= pct && age($2) >= secs { printf "%s%s(%s) %s%%", (n++ ? ", " : ""), $4, $1, $3 }'
}

people() {
  if [ -n "${FLEET_SPOTLIGHT_UIDS+x}" ]; then printf '%s\n' $FLEET_SPOTLIGHT_UIDS
  else dscl . -list /Users UniqueID 2>/dev/null | awk '$1 !~ /^_/ && $2 >= 500 { print $2 }'; fi
}

cmd_status() {
  local check="${1:-}" vols kn ht warn=""
  if ! managed; then
    [ -n "$check" ] || echo "spotlight  not a managed machine ($STATE/machine.env missing) — left as it is"
    return 2
  fi
  if [ -e "$STATE/spotlight.keep" ]; then
    echo "Spotlight kept on by $STATE/spotlight.keep (the machine's choice)"; return 0
  fi
  vols=$(volumes_on | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  kn=$(knowledge)
  ht=$(hot)
  [ -z "$vols" ] || warn="indexing on: $vols"
  [ -z "$kn" ] || warn="${warn:+$warn; }knowledge agent running for: $kn"
  [ -z "$ht" ] || warn="${warn:+$warn; }hot ≥${HOT_PCT}% for ≥$((HOT_SECS / 60))m: $ht"
  if [ -n "$warn" ]; then
    echo "Spotlight still running on this managed machine — $warn. Turn it off: \`$FIX\` (the machine daemon does it hourly)"
    return 1
  fi
  echo "Spotlight off — no volume indexing, no knowledge agent running, nothing hot"
  return 0
}

cmd_off() {
  local tick="${1:-}" vols uid s did="" kn
  managed || { echo "$PROG: not a managed machine ($STATE/machine.env missing) — refusing to turn a person's Spotlight off" >&2; return 1; }
  if [ "$(id -u)" != 0 ] && [ "${FLEET_NODE_TEST:-}" != 1 ]; then
    echo "$PROG: off needs root — $FIX" >&2; return 1
  fi
  if [ -e "$STATE/spotlight.keep" ]; then
    [ -n "$tick" ] || echo "spotlight  kept on ($STATE/spotlight.keep)"
    return 0
  fi
  vols=$(volumes_on)
  if [ -n "$vols" ]; then
    "$MDUTIL" -a -i off >/dev/null 2>&1 || { echo "$PROG: mdutil -a -i off failed" >&2; return 1; }
    "$MDUTIL" -a -E >/dev/null 2>&1 || true
    did="indexing off + index erased on: $(printf '%s' "$vols" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  fi
  kn=$(knowledge)
  for uid in $(people); do
    for s in $AGENTS; do
      "$LAUNCHCTL" disable "gui/$uid/$s" >/dev/null 2>&1
      "$LAUNCHCTL" disable "user/$uid/$s" >/dev/null 2>&1
      "$LAUNCHCTL" bootout "gui/$uid/$s" >/dev/null 2>&1
      "$LAUNCHCTL" bootout "user/$uid/$s" >/dev/null 2>&1
    done
  done
  [ -z "$kn" ] || did="${did:+$did; }knowledge agents disabled + stopped for: $kn"
  if [ -n "$did" ]; then echo "spotlight  $did"
  elif [ -z "$tick" ]; then echo "spotlight  already off (knowledge agents disabled for every uid ≥ 500)"; fi
  return 0
}

case "${1:-}" in
  status) shift; case "${1:-}" in ''|--check) cmd_status "${1:-}" ;; *) usage >&2; exit 2 ;; esac ;;
  off) shift; case "${1:-}" in ''|--tick) cmd_off "${1:-}" ;; *) usage >&2; exit 2 ;; esac ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
