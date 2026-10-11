#!/usr/bin/env bash
# fleet-role-windows.sh — move the old resident seats onto the new marks, in place
# (issue #3121, EPIC #3111 C10). install-apply's `roles-windows:` step; safe to re-run.
#
#   fleet-role-windows.sh [--dry-run] [--socket <fleet>]...
#
# Every live fleet (or each --socket), every window, ONE pass:
#   · `@fleet_role orchestrator` (the old seat, issue #3118 stopped writing it) →
#     `@fleet_role worker` + `@fleet_role_def orchestrator` + the role's line in
#     roles.held (fleet_roles_held_file) — the conversation keeps running, the
#     children it spawned still find it (fleet_role_holder ① names it). Another
#     window already holding the role keeps it; the seat becomes a plain row.
#     A seat with no @reap_policy gets `keep` (the seat was never reaped).
#   · `@fleet_role steward` → stopped by `fleet-worker-stop.sh <fleet> fid:<id>`
#     (Escape + /exit, the SessionEnd row, `fleet_win_retire` — restore never
#     reopens it). Its state files are left where they are.
#   · `@fleet_role_def epic-driver` with no `@agent_def` (a driver opened by
#     `--role epic-driver` before #3122) → `@agent_def epic-driver` +
#     `@agent_spawn 1` — the agent file grants every tool, so it still spawns.
#   · `@pin 1` → `@reap_policy keep`, ONCE per window (`@reap_pin_kept 1` remembers
#     it, so a policy the person sets afterwards is never overwritten): a pin
#     orders the list and no longer holds off the reaper (EPIC #3111 decision 3).
# The seats are left alone while the LIVE install (FLEET_INSTALL_ROOT, else
# ~/.claude/fleet — what the daemons run) still reopens them: its diskguard tick's
# home_watch would open a fresh seat seconds after this one became a row (issue
# #3121's first run did exactly that). install-apply runs this step on the new tree,
# so there it always proceeds; by hand before the switch it says so and skips them.
# It kills no process tree, touches no child session, changes no issue. Each
# change prints one line `<fleet> <window id> <name>: <what>`; the last line is
# the count. Exit 0 · 1 a change failed (the lines say which) · 2 usage.
# Selftest: bin/fleet-role-windows-selftest.sh.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"

DRY=0 SOCKS=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --socket) [ "$#" -ge 2 ] || { echo 'fleet-role-windows: --socket needs a fleet' >&2; exit 2; }
              SOCKS="$SOCKS $2"; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) printf 'fleet-role-windows: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$SOCKS" ] || SOCKS=$(fleet_sockets 2>/dev/null)

STOP=${FLEET_ROLE_WINDOWS_STOP:-$BIN/fleet-worker-stop.sh}   # selftest seam
LIVE="${FLEET_INSTALL_ROOT:-$HOME/.claude/fleet}"
SEATS=1
grep -qE 'fleet-(orchestrator|steward)\.sh" ensure' "$LIVE/bin/fleet-diskguard.sh" 2>/dev/null && SEATS=0
HELD=$(fleet_roles_held_file)
n=0 bad=0
KIND="the kind's rule"
say() { printf '%s\n' "$*"; }
act() { n=$((n + 1)); say "$1"; }

# held_line <role> <fleet> <fid> <wid> — the role's one line, by one rename.
held_line() {
  local r="$1" tmp
  mkdir -p "$(dirname "$HELD")" || return 1
  tmp="$HELD.tmp.$$"
  { [ -f "$HELD" ] && awk -F'\t' -v r="$r" '$1 != r' "$HELD"
    printf '%s\t%s\t%s\t%s\t%s\n' "$r" "$2" "$3" "$4" "$(date +%s)"; } > "$tmp" && mv -f "$tmp" "$HELD"
  local rc=$?; rm -f "$tmp"; return $rc
}

for s in $SOCKS; do
  rows=$(fleet_lw '#{window_id}|#{@fleet_role}|#{@fleet_role_def}|#{@agent_def}|#{@pin}|#{@reap_policy}|#{@reap_pin_kept}|#{@fleet_id}|#{window_name}' tmux -L "$s")
  T() { tmux -L "$s" "$@"; }
  while IFS='|' read -r wid role def adef pin reap kept fid name; do
    [ -n "$wid" ] || continue
    tag="$s $wid $name"
    case "$SEATS:$role" in 0:orchestrator|0:steward)
      say "$tag: old $role seat left as it is — the live install ($LIVE) still reopens a closed seat; the step runs again after its switch"
      continue ;;
    esac
    case "$role" in
      orchestrator)
        holder=$(fleet_role_holder orchestrator "$s" 2>/dev/null) || holder=''
        mark=1
        # another window holding the mark (a session that took the role) keeps it
        [ -n "$holder" ] && [ "$holder" != "$wid" ] \
          && [ "$(T show-options -wqv -t "$holder" @fleet_role_def 2>/dev/null)" = orchestrator ] && mark=0
        if [ "$DRY" = 1 ]; then
          act "$tag: would become an ordinary row$([ "$mark" = 1 ] && echo ' holding the orchestrator role')$([ -z "$reap" ] && echo ' · reap keep')"
          continue
        fi
        ok=1
        T set-window-option -t "$wid" @fleet_role worker 2>/dev/null || ok=0
        [ -z "$reap" ] && { T set-window-option -t "$wid" @reap_policy keep 2>/dev/null || ok=0; }
        if [ "$mark" = 1 ]; then
          T set-window-option -t "$wid" @fleet_role_def orchestrator 2>/dev/null || ok=0
          held_line orchestrator "$s" "$fid" "$wid" || ok=0
        fi
        if [ "$ok" = 1 ]; then
          act "$tag: ordinary row now$([ "$mark" = 1 ] && echo ' · holds the orchestrator role (roles.held)' || echo " · the role stays with $holder")$([ -z "$reap" ] && echo ' · reap keep')"
        else bad=$((bad + 1)); say "$tag: FAIL — could not re-mark the old orchestrator seat"; fi
        continue ;;
      steward)
        if ! fleet_is_fid "$fid"; then
          bad=$((bad + 1)); say "$tag: FAIL — old steward seat has no @fleet_id; stop it by hand"; continue
        fi
        if [ "$DRY" = 1 ]; then act "$tag: would stop the old steward seat (retired; state files kept)"; continue; fi
        if out=$(bash "$STOP" "$s" "fid:$fid" 2>&1); then
          act "$tag: old steward seat stopped (retired; state files kept)"
        else bad=$((bad + 1)); say "$tag: FAIL — fleet-worker-stop: $(printf '%s\n' "$out" | tail -1)"; fi
        continue ;;
    esac
    if [ "$def" = epic-driver ] && [ -z "$adef" ]; then
      if [ "$DRY" = 1 ]; then act "$tag: would stamp @agent_def epic-driver"
      elif T set-window-option -t "$wid" @agent_def epic-driver 2>/dev/null \
           && T set-window-option -t "$wid" @agent_spawn 1 2>/dev/null; then
        act "$tag: @agent_def epic-driver"
      else bad=$((bad + 1)); say "$tag: FAIL — could not stamp @agent_def"; fi
    fi
    if [ "$pin" = 1 ] && [ "$kept" != 1 ]; then
      if [ "$reap" = keep ]; then
        [ "$DRY" = 1 ] || T set-window-option -t "$wid" @reap_pin_kept 1 2>/dev/null
      elif [ "$DRY" = 1 ]; then act "$tag: pinned — would set reap keep (was ${reap:-$KIND})"
      elif T set-window-option -t "$wid" @reap_policy keep 2>/dev/null \
           && T set-window-option -t "$wid" @reap_pin_kept 1 2>/dev/null; then
        act "$tag: pinned — reap keep (was ${reap:-$KIND})"
      else bad=$((bad + 1)); say "$tag: FAIL — could not set reap keep"; fi
    fi
  done <<EOF
$rows
EOF
done

if [ "$bad" -gt 0 ]; then say "roles-windows: $n change(s), $bad failed"; exit 1; fi
say "roles-windows: $([ "$DRY" = 1 ] && echo "would change $n window(s)" || echo "$n window(s) changed")"
