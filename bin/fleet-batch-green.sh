#!/bin/bash
# fleet-batch-green.sh — a batch nobody drives still has green PRs: tell the person
# how many (issue #3369, the follow-up of EPIC #3111 C10's walk-through ⑦).
#
#   fleet-batch-green.sh [--dry-run]
#
# WHY. Once the EPIC driver's session is gone (closed, reaped, its loop ended),
# the only code that looked at its members' PRs was the steward's beat — and that
# runs only for a session HOLDING the steward role. With nobody holding it, a
# member that went green waited unseen: the sidebar's grey 「#N … 没人在跑」 row
# says the batch stopped, never that work is ready to land. This is the core's
# read-only half of it, on the diskguard tick (beside macos_watch): it MERGES
# NOTHING and spawns nobody — it counts and says.
#
# A batch here is one fleet_epic_stale_list gives (a heartbeat mark gone stale,
# its EPIC still on the open-issue list), minus any a live window still wears as
# its @epic (a driver window that is there but quiet is the steward's
# stuck-driver row, not this). For each, at most once per FLEET_BATCH_GREEN_SECS
# (600): its open sub-issues (fleet_sub_issues — ONE REST call), each member's
# PR off its repo's prmap (`issue-<M>`, the collector's copy — no gh): OPEN, CI ✓
# and `ready` (the merge gate's READY) counts. A count that differs from the last
# one said for that batch is said — `fleet-alerts.sh event batch-green` — when it
# is above 0; 0 is only remembered, so the next rise speaks again. Each batch is
# said once per count; a batch that is no longer stale leaves the book.
#
# No mark at all (fleet-epic not installed, no batch ever run here) ⇒ it reads
# nothing, writes nothing, says nothing. FLEET_BATCH_GREEN=0 turns it off.
# Book: $FLEET_CONF_DIR/global/batch-green.tsv, `<ref>\t<checked epoch>\t<said>`.
#
# Test seams: FLEET_BATCH_GREEN_MEMBERS_CMD `<cmd> <repo> <N>` in place of
# fleet_sub_issues (`<repo>\t<M>\t<state>` lines); FLEET_BATCH_GREEN_DRIVEN_CMD in
# place of the live windows' @epic read (`<ref>` words); FLEET_BATCH_GREEN_ALERT_CMD
# in place of bin/fleet-alerts.sh.
#
# Exit 0 always (a tick must never fail on it); --dry-run prints what it would say.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

DRY=0
[ "${1:-}" = --dry-run ] && DRY=1
[ "${FLEET_BATCH_GREEN:-1}" = 0 ] && exit 0

# No mark ⇒ not one read more (the degenerate case: fleet-epic not installed).
[ -n "$(fleet_epic_running_marks)" ] || exit 0

SECS=${FLEET_BATCH_GREEN_SECS:-600}
case "$SECS" in ''|*[!0-9]*) SECS=600 ;; esac
BOOK="$FLEET_CONF_DIR/global/batch-green.tsv"
NOW=$(date +%s)

# driven — every live window's @epic, as `<owner/name>#<N>` and `#<N>` words.
driven() {
  if [ -n "${FLEET_BATCH_GREEN_DRIVEN_CMD:-}" ]; then
    $FLEET_BATCH_GREEN_DRIVEN_CMD 2>/dev/null
    return 0
  fi
  local s
  for s in $(fleet_sockets 2>/dev/null); do
    tmux -L "$s" list-windows -a -F '#{@epic}' 2>/dev/null
  done
}
DRIVEN=" $(driven | awk 'NF { sub(/:.*/, ""); printf "%s ", $1 }') "

members() {
  if [ -n "${FLEET_BATCH_GREEN_MEMBERS_CMD:-}" ]; then
    $FLEET_BATCH_GREEN_MEMBERS_CMD "$1" "$2" 2>/dev/null
  else
    fleet_sub_issues "$1" "$2"
  fi
}

# book_get <ref> → `<checked>\t<said>` (nothing when not in the book)
book_get() { [ -f "$BOOK" ] && awk -F'\t' -v r="$1" '$1 == r { print $2 "\t" $3; exit }' "$BOOK" 2>/dev/null; }

NEWBOOK=''
while IFS=$'\t' read -r repo n _age title; do
  [ -n "$repo" ] && [ -n "$n" ] || continue
  ref="$repo#$n"
  case "$DRIVEN" in *" $ref "*|*" #$n "*) continue ;; esac
  prev=$(book_get "$ref"); checked=${prev%%$'\t'*}; said=${prev#*$'\t'}
  [ -n "$prev" ] || { checked=0; said=''; }
  case "$checked" in ''|*[!0-9]*) checked=0 ;; esac
  if [ $(( NOW - checked )) -lt "$SECS" ]; then
    NEWBOOK+="$ref"$'\t'"$checked"$'\t'"$said"$'\n'
    continue
  fi
  # only well-formed rows: gh prints its error JSON on stdout
  mlist=$(members "$repo" "$n" | grep -E $'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\t[0-9]+\t')
  if [ -z "$mlist" ]; then                     # an unread list is never «0 green»
    NEWBOOK+="$ref"$'\t'"$NOW"$'\t'"$said"$'\n'
    continue
  fi
  green=0 prs=''
  while IFS=$'\t' read -r mrepo m mstate; do
    case "$m" in ''|*[!0-9]*) continue ;; esac
    case "$mstate" in [Oo][Pp][Ee][Nn]) ;; *) continue ;; esac
    pm="$FLEET_C/fleets/$(fleet_slug "$mrepo")/prmap"
    [ -s "$pm" ] || continue
    line=$(awk -F'\t' -v b="issue-$m" '$1 == b { print; exit }' "$pm" 2>/dev/null)
    IFS=$'\t' read -r _b pnum pstate pci pready _rest <<<"$line"
    [ "${pstate:-}" = OPEN ] && [ "${pci:-}" = "✓" ] && [ "${pready:-}" = ready ] || continue
    green=$((green + 1)); prs+=" ${pnum}"
  done <<<"$mlist"
  if [ "$green" != "$said" ] && [ "$green" -gt 0 ]; then
    text="fleet: 批次 ${ref}${title:+「${title}」} 没人在跑 — 还有 ${green} 张已全绿，等你合:${prs}"
    if [ "$DRY" = 1 ]; then
      printf 'would say: %s\n' "$text"
    else
      bash "${FLEET_BATCH_GREEN_ALERT_CMD:-$BIN/fleet-alerts.sh}" event batch-green "$text" >/dev/null 2>&1 \
        || printf 'fleet-batch-green: the alert failed for %s\n' "$ref" >&2
    fi
  fi
  NEWBOOK+="$ref"$'\t'"$NOW"$'\t'"$green"$'\n'
done <<EOF_STALE
$(fleet_epic_stale_list "" 2>/dev/null)
EOF_STALE

[ "$DRY" = 1 ] && exit 0
# The book holds only the batches still stale: a batch that was picked up again,
# or whose EPIC closed, leaves it (and speaks afresh if it stalls again).
if [ -n "$NEWBOOK" ]; then
  mkdir -p "${BOOK%/*}" 2>/dev/null
  printf '%s' "$NEWBOOK" > "$BOOK.$$" 2>/dev/null && mv -f "$BOOK.$$" "$BOOK" 2>/dev/null || rm -f "$BOOK.$$"
else
  rm -f "$BOOK" 2>/dev/null
fi
exit 0
