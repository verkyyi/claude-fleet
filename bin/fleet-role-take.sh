#!/usr/bin/env bash
# fleet-role-take.sh — take a role in THIS session: take_role (issue #3114, EPIC #3111 C3).
#
#   fleet-role-take.sh <orchestrator|steward>            take it
#   fleet-role-take.sh <orchestrator|steward> --steal    take it from whoever holds it
#   fleet-role-take.sh <orchestrator|steward> --drop     give it back
#   fleet-role-take.sh <orchestrator|steward> --who      who holds it
#
# A role is a MARK on an ordinary window, never a kind of window (EPIC #3111 rule 4):
# any session that binds no issue may take it — a scratch, a no-repo session, the
# old seat. Taking it stamps `@fleet_role_def <role>` (fleet_spawn_refused lets that
# window spawn, rule 5) and writes the role's ONE line in
# `$FLEET_CONF_DIR/global/roles.held`; fleet_role_holder (bin/fleet-lib.sh) is the
# only reader, so `fleet_win_for_key orchestrator` — a child's report, a peer's
# send — finds whoever holds it now. One holder per role: a second taker is told
# who holds it (rc 4) and takes it only with --steal, which unmarks the old holder.
# The plugin's skill (/fleet-orchestrate) calls this first, through the dispatch
# group's `take_role` tool.
#
# Exit: 0 taken / dropped / held by this window already (--who: printed) ·
#       2 usage · 3 this window cannot take a role (it binds an issue, it is a
#       panel, or this is no fleet pane) · 4 another window holds it (named on
#       stdout; --drop: this window does not hold it) · 1 failure (--who: nobody).
# Selftest: bin/fleet-role-take-selftest.sh.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-role-take: %s\n' "$2" >&2; exit "$1"; }
role=${1:-}; [ "$#" -gt 0 ] && shift
act=take
while [ "$#" -gt 0 ]; do
  case "$1" in
    --steal) act=steal ;; --drop) act=drop ;; --who) act='who' ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
  shift
done
case " $FLEET_ROLES_TAKEN " in *" $role "*) [ -n "$role" ] || die 2 "usage: fleet-role-take.sh <orchestrator|steward> [--steal|--drop|--who]" ;;
  *) die 2 "a role is one of: $FLEET_ROLES_TAKEN (got '${role}')" ;; esac

HELD=$(fleet_roles_held_file)

# describe <win> → `<key> (<window id> · <name>)`, how a holder is named to a person.
describe() {
  local w="$1" sess key nm
  sess=$(tmux display-message -p -t "$w" "$FLEET_SESSION_FMT" 2>/dev/null)
  key=$(fleet_window_okey "$sess" "$w" 2>/dev/null)
  nm=$(tmux display-message -p -t "$w" '#{window_name}' 2>/dev/null)
  printf '%s (%s · %s)' "${key:-?}" "$w" "${nm:-?}"
}

# held_write <role> [<line>] — the role's one line (none: dropped), by one rename, under a lock.
held_write() {
  local r="$1" line="${2:-}" dir tmp lk i=0
  dir=$(dirname "$HELD"); mkdir -p "$dir" || return 1
  lk="$HELD.lock"
  while ! mkdir "$lk" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -ge 50 ] && { rm -rf "$lk"; continue; }   # a lock older than ~5 s is a dead taker's
    sleep 0.1
  done
  tmp="$HELD.tmp.$$"
  { if [ -f "$HELD" ]; then awk -F'\t' -v r="$r" '$1 != r' "$HELD"; fi
    if [ -n "$line" ]; then printf '%s\n' "$line"; fi; } > "$tmp" \
    && mv -f "$tmp" "$HELD"
  local rc=$?
  rm -f "$tmp"; rmdir "$lk" 2>/dev/null
  return $rc
}

holder=$(fleet_role_holder "$role" 2>/dev/null); hrc=$?
if [ "$act" = who ]; then
  [ "$hrc" = 0 ] || { printf '%s: nobody holds it\n' "$role"; exit 1; }
  printf '%s: %s\n' "$role" "$(describe "$holder")"
  exit 0
fi

[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || die 3 "not inside a fleet pane — a role is taken from the session that will hold it"
me=$(fleet_pane_fmt "#{window_id}|#{@issue}|#{@fleet_role}|$FLEET_SESSION_FMT") || die 3 "this pane's window cannot be read"
IFS='|' read -r wid iss frole sess <<EOF
$me
EOF
[ -n "$wid" ] || die 3 "this pane's window cannot be read"

if [ "$act" = drop ]; then
  [ "$hrc" = 0 ] && [ "$holder" != "$wid" ] && { printf '%s: held by %s, not this window\n' "$role" "$(describe "$holder")"; exit 4; }
  tmux set-window-option -u -t "$wid" @fleet_role_def 2>/dev/null
  held_write "$role" '' || die 1 "cannot write $HELD"
  printf '%s: dropped — nobody holds it now\n' "$role"
  exit 0
fi

case "$iss" in ''|*[!0-9]*) : ;; *) die 3 "this window works on issue #$iss — a role is taken by a session that binds no issue (a scratch, a no-repo session)" ;; esac
case "$frole" in home|panel) die 3 "this window is the fleet's $frole, not a session" ;; esac

if [ "$hrc" = 0 ] && [ "$holder" = "$wid" ]; then
  # already ours: make sure the record names us (a mark with no line, a moved fid)
  fid=$(fleet_window_fid "$sess" "$wid") || fid=''
  held_write "$role" "$(printf '%s\t%s\t%s\t%s\t%s' "$role" "$sess" "$fid" "$wid" "$(date +%s)")" || die 1 "cannot write $HELD"
  printf '%s: held by this window already — %s\n' "$role" "$(describe "$wid")"
  exit 0
fi
if [ "$hrc" != 1 ] && [ "$act" != steal ]; then
  if [ "$hrc" = 0 ]; then
    printf '%s: held by %s — ask there, or take it over with --steal\n' "$role" "$(describe "$holder")"
  else
    printf '%s: several windows claim it — take it over with --steal\n' "$role"
  fi
  exit 4
fi
if [ "$act" = steal ]; then
  # every other window marked with the role loses the mark (the old seat's
  # @fleet_role is not ours to change — the record names the new holder first)
  fleet_lw '#{window_id}|#{@fleet_role_def}' | awk -F'|' -v r="$role" -v me="$wid" '$2 == r && $1 != me { print $1 }' \
    | while IFS= read -r w; do tmux set-window-option -u -t "$w" @fleet_role_def 2>/dev/null; done
fi
fid=$(fleet_window_fid "$sess" "$wid") || fid=''
tmux set-window-option -t "$wid" @fleet_role_def "$role" 2>/dev/null || die 1 "cannot mark $wid"
held_write "$role" "$(printf '%s\t%s\t%s\t%s\t%s' "$role" "$sess" "$fid" "$wid" "$(date +%s)")" \
  || { tmux set-window-option -u -t "$wid" @fleet_role_def 2>/dev/null; die 1 "cannot write $HELD"; }
if [ "$act" = steal ] && [ "$hrc" = 0 ]; then
  printf '%s: taken over from %s — this window holds it now\n' "$role" "$(describe "$holder")"
else
  printf '%s: taken — this window (%s) holds it now\n' "$role" "$(describe "$wid")"
fi
exit 0
