#!/bin/bash
# fleet-task-run.sh — ONE attempt of a scheduled agent task (issue #2529, EPIC #2524
# C5). The machine's daemon (fleet-node-supervisor.py) runs it, demoted to the
# task's login, when a slot of a `kind: task` entry is due — never by hand; `fleet
# task run <name> --now` asks the daemon for one. Its output is appended to
# /var/log/fleet-node/logins/<login>/<name>.log; its exit code is the attempt's
# verdict, which the daemon turns into retry / ok / failed + alert:
#
#   0   the session opened (and, with a done file, finished with it in place)
#   10  bad setup — no prompt / window, no spawner, no fleet to open it in
#   11  the session did not open (the spawner's refusal: at capacity, no parent…)
#   12  timed out waiting for the session (FLEET_TASK_TIMEOUT)
#   13  the session finished without its output: idle FLEET_TASK_IDLE seconds, or
#       its window gone, and the done file still missing
#
# A window of the attempt's name already open (a run the daemon lost when it
# restarted) is ADOPTED, never opened twice. The session is the login's own fleet's,
# opened the way every headless caller opens one:
#   dash-raw-session.sh --no-repo --origin hub --print --name <window> --prompt <p> <fleet>
#
# The daemon hands it everything in the environment (fleet-node-supervisor.py
# task_entry): FLEET_TASK_PROMPT · FLEET_TASK_WINDOW · FLEET_TASK_DONE_FILE ·
# FLEET_TASK_TIMEOUT · FLEET_TASK_IDLE · FLEET_TASK_FLEET (else the login's only
# fleet) · FLEET_TASK_ATTEMPT · FLEET_TASK_SLOT · FLEET_SERVICE (the task's name).
#   --notify: the entry's Bark push instead — $FLEET_TASK_NOTIFY to the key held in
#             the credential named by $FLEET_TASK_BARK_CRED (never printed).
# Seams (an entry's env): FLEET_TASK_SPAWN (default the login's
# ~/.claude/fleet/bin/dash-raw-session.sh), FLEET_TASK_POLL (30 s),
# FLEET_TASK_BARK_URL (https://api.day.app).
set -uo pipefail

say() { printf '%s fleet-task %s · %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${FLEET_SERVICE:-?}" "$*"; }

if [ "${1:-}" = --notify ]; then
  c=${FLEET_TASK_BARK_CRED:-}
  key=''; [ -n "$c" ] && key=$(printenv "$c")
  [ -n "$key" ] || { say "bark: credential ${c:-?} not stored — fleet service cred set $c"; exit 10; }
  # the key travels on stdin (curl -K -), never an argv another login's ps can read
  if python3 -c 'import os, urllib.parse as u
q = lambda a: u.quote(a, safe="")
print("url = \"%s/%s/%s/%s\"" % (os.environ.get("FLEET_TASK_BARK_URL") or "https://api.day.app",
      q(os.environ[os.environ["FLEET_TASK_BARK_CRED"]]), q("fleet task"), q(os.environ.get("FLEET_TASK_NOTIFY") or "failed")))' \
     | curl -fsS -m 15 -o /dev/null -K - 2>/dev/null; then
    say "bark: sent"; exit 0
  fi
  say "bark: push failed"; exit 11
fi

P=${FLEET_TASK_PROMPT:-}
W=${FLEET_TASK_WINDOW:-}
DONE=${FLEET_TASK_DONE_FILE:-}
TO=${FLEET_TASK_TIMEOUT:-3600}
IDLE=${FLEET_TASK_IDLE:-600}
POLL=${FLEET_TASK_POLL:-30}
SPAWN=${FLEET_TASK_SPAWN:-$HOME/.claude/fleet/bin/dash-raw-session.sh}
say "--- slot ${FLEET_TASK_SLOT:-?} attempt ${FLEET_TASK_ATTEMPT:-1} window $W"
[ -n "$P" ] && [ -n "$W" ] || { say "no prompt / window"; exit 10; }
[ -x "$SPAWN" ] || { say "no spawner $SPAWN — is the fleet installed for $(id -un)?"; exit 10; }

# the login's fleet: the entry's, else its only one (one fleet per login, EPIC #977)
SESS=${FLEET_TASK_FLEET:-}
if [ -z "$SESS" ]; then
  n=0
  for f in "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"/fleets/*/conf; do
    [ -f "$f" ] || continue
    d=${f%/conf}; SESS=${d##*/}; n=$((n + 1))
  done
  [ "$n" = 1 ] || { say "found $n fleets for $(id -un) — name one: fleet task add … --fleet <name>"; exit 10; }
fi

# every window once (a view session lists them twice — fleet_lw's rule, issue #1489)
win_by_name() {
  tmux -L "$SESS" list-windows -a -F '#{window_id}	#{window_name}' 2>/dev/null \
    | awk -F '\t' -v w="$1" '$2 == w && !seen[$1]++ { print $1; exit }'
}

wid=$(win_by_name "$W")
if [ -n "$wid" ]; then
  say "adopted the open window $wid ($W) — not opening a second"
else
  out=$("$SPAWN" --no-repo --origin hub --print --name "$W" --prompt "$P" "$SESS" 2>&1)
  rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/  spawn: /'
  [ "$rc" = 0 ] || { say "the session did not open (spawner exit $rc)"; exit 11; }
  wid=$(printf '%s\n' "$out" | awk -F '\t' '$1 ~ /^@[0-9]+$/ { print $1; exit }')
  say "opened ${wid:-?} ($W) in fleet $SESS"
fi

[ -n "$DONE" ] || exit 0

# wait for the session to finish with its output in place
start=$SECONDS; idle_since=''
while :; do
  st=$(tmux -L "$SESS" display-message -p -t "${wid:-none}" '#{@claude_state}' 2>/dev/null); alive=$?
  if [ -e "$DONE" ] && [ "$st" != working ]; then say "done — $DONE"; exit 0; fi
  if [ "$alive" != 0 ] || [ -z "$wid" ] || [ "$st" = exited ]; then
    # gone: one more look (the file may land as the window closes), then a verdict
    sleep 1
    [ -e "$DONE" ] && { say "done — $DONE"; exit 0; }
    say "the session ended without $DONE"; exit 13
  fi
  if [ "$st" = working ]; then idle_since=''
  elif [ -z "$idle_since" ]; then idle_since=$SECONDS
  elif [ $((SECONDS - idle_since)) -ge "$IDLE" ]; then
    say "the session is $st for ${IDLE}s and $DONE is missing"; exit 13
  fi
  [ $((SECONDS - start)) -ge "$TO" ] && { say "timed out after ${TO}s waiting for $DONE"; exit 12; }
  sleep "$POLL"
done
