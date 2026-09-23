#!/bin/bash
# fleet-children-flush.sh — deliver the batched child reports as ONE digest (issue #939).
#
#   fleet-children-flush.sh [<session>...] [--parent <key>] [--force] [--dry-run] [-L <socket>]
#
# FLEET_CHILD_REPORT=batch turns fleet-report-parent.sh into a bookkeeper: a quiet
# report (MERGED, FAILED-while-fixing, a clean reap) is only written to the parent's
# children ledger ($FLEET_STATE/children/<parent-key>.ndjson). This is what delivers
# it — later, merged with its siblings, as one envelope with the global picture:
#
#   [children-digest] 3/5 ✓ · 1 ⏳ · 1 !
#     ! issue #104 "kid-needs" BLOCKED — needs a token only the operator has
#     ⏳ issue #103 "kid-ci" WAITING (pr-open)
#     ✓ issue #101 "kid-done" MERGED (PR #950) — rebuilt the comparator
#   no reply needed — <language notice>
#
# The header counts the whole subtree (fleet-children.sh's summary); the lines are
# only the children whose ledger changed since the last digest, ≤6, the rest folded.
# `<parent-key>.cursor` beside the ledger holds the highest seq delivered, advanced
# only on a delivery — so a repeated tick, a racing loud flush, or a parent migrated
# onto a new window id (same key, same cursor) never sends a thing twice.
#
# WHEN (fleet-children.py cmd_digest): deliverable news is pending AND
#   loud     a loud event is among it (fleet-report-parent.sh calls this at once)
#   barrier  every child under the parent is terminal (✓ ! –) — the batch is over
#   age      the oldest news has waited FLEET_CHILD_REPORT_BATCH_SECS (default 300)
#   idle     the parent itself is idle (its turn is done) — nothing to interrupt
# A parent with no window (reaped / another fleet) is skipped: its events stay in
# the ledger, readable by fleet-children.sh, and nothing errors.
#
# Run by the cleanup daemon's 60s tick (no daemon of its own, EPIC #935). With no
# <session>, every fleet on this machine; a fleet not in batch mode is skipped
# unless --parent names a key (the loud path, which already knows the mode).
#
#   --parent <key>  only this parent (issue-N / scratch-N / <slug>:issue-N)
#   --force         deliver pending news now, whatever the conditions
#   --dry-run       print what would be sent; send nothing, move no cursor
#   -L <socket>     the fleet's socket (= its session name) — the one fleet to flush
#   -h              this header
#
# Exit 0 always (a digest that could not be sent waits for the next tick), 2 on a
# usage mistake. Prints one `digest → <key> …` line per delivery.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-children-lib.sh"

PARENT='' FORCE=0 DRY=0 SESSIONS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --parent)  shift; PARENT="${1:-}" ;;
    --force)   FORCE=1 ;;
    --dry-run) DRY=1 ;;
    -L)        shift; [ -n "${1:-}" ] && SESSIONS+=("$1") ;;
    -L*)       SESSIONS+=("${1#-L}") ;;
    -h|--help) sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        printf 'fleet-children-flush: unknown argument %s\n' "$1" >&2; exit 2 ;;
    *)         SESSIONS+=("$1") ;;
  esac
  shift
done

log() { printf 'fleet-children-flush: %s\n' "$*" >&2; }

# flush_one <sess> <key> — one parent: decide, render, send, advance. Under a
# per-parent mkdir lock (portable; macOS has no flock(1)), so a loud report's flush
# and the tick's cannot both read the same cursor and send the same news twice.
flush_one() {
  local sess="$1" key="$2" sock dir pwin pstate res reason seq text msg lock args
  sock=$(fleet_socket "$sess")
  dir=$(children_dir "$sess") || return 0
  pwin=$(fleet_win_for_key "$key" "$sock") && [ -n "$pwin" ] || {
    [ "$DRY" = 1 ] && log "$key: no window on $sess (reaped, or another fleet) — kept in the ledger"
    return 0
  }
  pstate=$(tmux -L "$sock" display-message -p -t "$pwin" \
             '#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}' 2>/dev/null)
  lock="$dir/.$key.flush.lock"
  fleet_wid_lock "$lock" || { log "$key: another flush holds the lock — next tick"; return 0; }
  args=(digest --dir "$dir" --parent "$key" --batch-secs "$(children_batch_secs)" --parent-state "$pstate")
  [ "$FORCE" = 1 ] && args+=(--force)
  res=$(bash "$BIN/fleet-children.sh" "$key" --json -L "$sock" 2>/dev/null \
          | python3 "$BIN/fleet-children.py" "${args[@]}" 2>/dev/null)
  # reason <TAB> seq on line 1, the envelope text after it.
  res=$(printf '%s' "$res" | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except ValueError: sys.exit(0)
print("%s\t%s" % (d.get("flush") or "", d.get("seq") or 0)); print(d.get("text") or "", end="")' 2>/dev/null)
  reason=${res%%$'\t'*}; res=${res#*$'\t'}
  seq=${res%%$'\n'*};    text=${res#*$'\n'}
  if [ -z "$reason" ] || [ -z "$text" ] || [ "$text" = "$res" ]; then
    fleet_wid_unlock "$lock"; return 0
  fi
  msg="$text"$'\n'"no reply needed${FLEET_LANG_RULE_NOTICE:+ — $FLEET_LANG_RULE_NOTICE}"
  if [ "$DRY" = 1 ]; then
    printf 'would send digest → %s (%s) · %s · cursor → %s\n--- envelope ---\n%s\n' \
      "$key" "$pwin" "$reason" "$seq" "$msg"
  elif children_send "$sess" "$sock" "$pwin" "$msg" >/dev/null 2>&1; then
    children_cursor_set "$key" "$sess" "$seq"
    printf 'digest → %s (%s) · %s · cursor %s\n' "$key" "$pwin" "$reason" "$seq"
  else
    log "$key ($pwin): no reachable inbox — kept for the next tick"
  fi
  fleet_wid_unlock "$lock"
  return 0
}

# flush_fleet <sess> — in a subshell, so one fleet's conf never leaks into the next.
flush_fleet() { (
  sess="$1"
  fleet_load_conf "$sess"
  [ -n "$PARENT" ] || [ "$(children_report_mode)" = batch ] || exit 0
  dir=$(children_dir "$sess") || exit 0
  if [ -n "$PARENT" ]; then
    flush_one "$sess" "$(fleet_origin_canon "$PARENT" '')"
    exit 0
  fi
  [ -d "$dir" ] || exit 0
  python3 "$BIN/fleet-children.py" scan --dir "$dir" 2>/dev/null |
  while IFS= read -r key; do
    [ -n "$key" ] && flush_one "$sess" "$key"
  done
) }

if [ "${#SESSIONS[@]}" -eq 0 ]; then
  while IFS= read -r s; do
    [ -n "$s" ] && SESSIONS+=("$s")
  done < <(fleet_hub_sessions | sort)
fi
for s in ${SESSIONS[@]+"${SESSIONS[@]}"}; do
  flush_fleet "$s"
done
exit 0
