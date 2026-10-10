#!/bin/bash
# fleet-node-shell-retire.sh — take the person's CLIENT off a managed machine,
# once, for one login (issue #2702).
#
# A fleet machine runs sessions and services; the person runs `fleet` on their
# own device. What an SSH login used to leave behind here goes, in this order:
#
#   client   the client's processes — its keeper, stage / list tmux servers,
#            warm lines, hub-sessions loop, actions loop: first `fleet quit`
#            from the login's own copy (it gives the hub lease back), then
#            whatever still runs from ~/.cache/claude-fleet/shell (TERM, then
#            KILL after FLEET_RETIRE_GRACE seconds, default 3)
#   cache    ~/.cache/claude-fleet/shell, removed
#   zshrc    the lines that hook the fleet into a login shell — the first-login
#            block (`# >>> claude-fleet` … `# <<< claude-fleet <<<`), any line
#            sourcing shell/fleet-login.zsh or shell/cw.zsh, and the fleet's own
#            header comment above one (`# cfguest:shell …`, `# claude-fleet login:
#            …` — issue #2991): fleet-node-supervisor.py's shell_hooks, the ONE
#            rule its status and sweep count by. The ~/.local/bin
#            PATH line and everything else stay; the old file is kept as
#            ~/.zshrc.pre-shell-retire[.<stamp>]
#
# Each step looks first and says `skip` when there is nothing to do, so a rerun
# is harmless. Every file operation runs AS the login (root never writes through
# a path a login owns). The machine daemon's sweep names a login that still needs
# this (`clientshell` in `fleet-node-supervisor.py status`, the doctor's `shell`
# row). The login's sessions, ~/.claude/fleet and its services are not touched.
#
# Usage: sudo fleet-node-shell-retire.sh --login <login> [--dry-run] [--if-idle]
#        (as that login itself, no sudo needed)
#        --if-idle: the machine daemon's own run (issue #2981) — while the client
#        still runs, change nothing and exit 3 (a person may be using it; the
#        next sweep tries again)
# Env:   FLEET_NODE_USERS (/Users — where homes live; a test seam) ·
#        FLEET_RETIRE_GRACE (3) · FLEET_RETIRE_QUIT_WAIT (20, seconds for `fleet quit`)
# Exit:  0 done (or nothing to do) · 1 a step failed · 2 usage / not allowed ·
#        3 --if-idle and the client still runs (nothing changed)
set -uo pipefail
PROG=fleet-node-shell-retire

LOGIN='' DRY=0 IDLE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --login) LOGIN=${2:-}; shift 2 || shift ;;
    --dry-run) DRY=1; shift ;;
    --if-idle) IDLE=1; shift ;;
    -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '%s: unknown arg %s\n' "$PROG" "$1" >&2; exit 2 ;;
  esac
done
case "$LOGIN" in
  ''|*[!A-Za-z0-9._-]*) printf '%s: --login <login> is required\n' "$PROG" >&2; exit 2 ;;
esac
H="${FLEET_NODE_USERS:-/Users}/$LOGIN"
[ -d "$H" ] || { printf '%s: no home %s\n' "$PROG" "$H" >&2; exit 2; }
ME=$(id -un)
# the supervisor selftest's sandbox homes (FLEET_NODE_TEST=1): file ops run as us
[ "${FLEET_NODE_TEST:-}" = 1 ] && ME=$LOGIN
if [ "$ME" != "$LOGIN" ] && [ "$(id -u)" != 0 ]; then
  printf '%s: run it as root (sudo) or as %s\n' "$PROG" "$LOGIN" >&2
  exit 2
fi
say() { printf '%s: %s\n' "$PROG" "$*"; }
FAILS=0
fail() { say "$1: FAIL — $2"; FAILS=$((FAILS + 1)); }
# as_login <cmd…> — the command as the login (root drops to it; the login itself runs it)
as_login() {
  if [ "$ME" = "$LOGIN" ]; then
    env HOME="$H" "$@"
  else
    sudo -u "$LOGIN" -H env HOME="$H" PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$@"
  fi
}
CACHE="$H/.cache/claude-fleet/shell"

# pids — the login's processes running from the client's cache (literal match;
# the path rides the environment, so this awk's own argv never matches it)
pids() {
  ps -axo pid=,user=,command= 2>/dev/null | RETIRE_PAT="$CACHE/" awk -v u="$LOGIN" -v me=$$ \
    '$2 == u && $1 != me && index($0, ENVIRON["RETIRE_PAT"]) { print $1 }'
}

# --- client -------------------------------------------------------------------
n=$(pids | wc -l | tr -d ' ')
if [ "$n" != 0 ] && [ "$IDLE" = 1 ]; then
  say "client: $n process(es) of $LOGIN still run from $CACHE — left for later (--if-idle), nothing changed"
  exit 3
fi
if [ "$n" = 0 ]; then
  say "client: skip — nothing of $LOGIN's runs from $CACHE"
elif [ "$DRY" = 1 ]; then
  say "client: would stop $n process(es) (fleet quit, then TERM / KILL what is left)"
else
  if [ -f "$CACHE/bin/fleet-shell.sh" ]; then
    as_login bash "$CACHE/bin/fleet-shell.sh" quit --quiet </dev/null >/dev/null 2>&1 &
    qp=$!; i=0
    while kill -0 "$qp" 2>/dev/null && [ "$i" -lt "${FLEET_RETIRE_QUIT_WAIT:-20}" ]; do sleep 1; i=$((i + 1)); done
    kill "$qp" 2>/dev/null; wait "$qp" 2>/dev/null
  fi
  left=$(pids)
  if [ -n "$left" ]; then
    # shellcheck disable=SC2086  # a list of numeric pids
    kill $left 2>/dev/null
    sleep "${FLEET_RETIRE_GRACE:-3}"
    left=$(pids)
    # shellcheck disable=SC2086
    [ -z "$left" ] || kill -9 $left 2>/dev/null
    sleep 1
  fi
  m=$(pids | wc -l | tr -d ' ')
  if [ "$m" = 0 ]; then say "client: stopped $n process(es)"
  else fail client "$m process(es) of $LOGIN still run from $CACHE"; fi
fi

# --- cache --------------------------------------------------------------------
if [ ! -e "$CACHE" ] && [ ! -L "$CACHE" ]; then
  say "cache: skip — no $CACHE"
elif [ "$DRY" = 1 ]; then
  say "cache: would remove $CACHE ($(du -sh "$CACHE" 2>/dev/null | cut -f1))"
else
  sz=$(du -sh "$CACHE" 2>/dev/null | cut -f1)
  if as_login rm -rf "$CACHE" && [ ! -e "$CACHE" ]; then say "cache: removed $CACHE (${sz:-?})"
  else fail cache "could not remove $CACHE"; fi
fi

# --- zshrc --------------------------------------------------------------------
ZRC="$H/.zshrc"
# the ONE rule for which lines go (issue #2991): the machine daemon's shell_hooks,
# the same reading its `status` / sweep count — run AS the login, no state touched
SUP="$(cd "$(dirname "$0")" && pwd)/fleet-node-supervisor.py"
if [ "$DRY" = 1 ]; then out=$(as_login python3 "$SUP" shell-hooks "$ZRC" --dry-run); rc=$?
else out=$(as_login python3 "$SUP" shell-hooks "$ZRC"); rc=$?; fi
case "$out" in
  FAIL*) fail zshrc "${out#FAIL — }" ;;
  *) if [ "$rc" = 0 ]; then say "zshrc: $out"; else fail zshrc "${out:-exit $rc}"; fi ;;
esac

if [ "$FAILS" = 0 ]; then
  if [ "$DRY" = 1 ]; then say "dry run — nothing changed"; else say "retired: $LOGIN carries no client here"; fi
  exit 0
fi
say "$FAILS step(s) failed — fix what they say, then re-run"
exit 1
