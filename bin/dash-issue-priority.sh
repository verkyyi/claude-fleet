#!/bin/bash
# dash-issue-priority.sh <issue-number> [cycle|p0|p1|p2|none] — set/cycle an
# issue's priority tier straight from the backlog panel (issue #235).
#
# Priority is the `priority:p{0,1,2}` LABEL the backlog rows tag + sort by
# (bin/tmux-issues-rows.sh) and the watcher's slotfree suggestion ranks by — so
# managing priority is just swapping that one
# label. This is the ⌃y keyboard path (bound in bin/tmux-issues.sh): NO text
# input, so it needs no popup and works identically in the windowed panel and the
# prefix+b popup (unlike ⌃t/⌃x, which prompt and so route through the sentinel).
#
#   cycle (default): raise the priority by one step and wrap —
#                      none → p2 → p1 → p0 → none.
#   p0|p1|p2|none    set that tier explicitly (used by the selftest; also handy
#                      if a caller wants a direct set).
#
# The interactive ⌃y path stays INSTANT (issue #304): it cycles from the tier the
# backlog row ALREADY shows (the labels cache) and repaints that row optimistically,
# then hands the slow NETWORK work — the authoritative `gh` read + edit — to a
# background job (fleet_bg → a `--commit` re-exec). The bg pass re-reads the issue's
# REAL labels and strips whatever priority label is actually there before adding the
# target, so a stale cache still can't leave two priority labels; the collector
# refetch then reconciles the cache. ⌃y never blocks on gh, yet the end state is
# authoritative.
set -uo pipefail
num="${1//[^0-9]/}"; [ -z "$num" ] && exit 0
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

# `--commit <tier>` = the BACKGROUND authoritative pass (dispatched by the
# interactive path via fleet_bg); anything else is the interactive keypress with an
# optional explicit action. An empty <tier> clears priority.
if [ "${2:-}" = "--commit" ]; then mode=commit; commit_target="${3:-}"
else mode=interactive; action="${2:-cycle}"; fi

FLEET_SESSION=$(fleet_current_session); export FLEET_SESSION
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
[ -n "${CF_REPO:-}" ] && REPO="$CF_REPO"
[ -z "$REPO" ] && { tmux display-message "backlog: no repo resolved — cannot set priority on #$num"; exit 1; }
command -v gh >/dev/null 2>&1 || { tmux display-message "gh not found — cannot set priority on #$num"; exit 1; }

# --- background authoritative pass: strip every REAL priority label, set target ---
if [ "$mode" = commit ]; then
  cur_labels=$(gh issue view "$num" --repo "$REPO" --json labels -q '.labels[].name' 2>/dev/null)
  # edit_args always carries --repo, so its expansion is safe under set -u even when
  # no labels are removed (bash 3.2 chokes on an empty declared-array expansion).
  edit_args=(--repo "$REPO")
  while IFS= read -r l; do
    case "$l" in priority:p0|priority:p1|priority:p2) edit_args+=(--remove-label "$l") ;; esac
  done <<EOF
$cur_labels
EOF
  [ -n "$commit_target" ] && edit_args+=(--add-label "priority:$commit_target")
  if ! gh issue edit "$num" "${edit_args[@]}" >/dev/null 2>&1; then
    tmux display-message "failed to set priority on #$num"   # corrects the optimistic toast
    exit 1
  fi
  # Reconcile the cache authoritatively (ordering/dedup across the fetch). Already
  # inside the backgrounded job, so run it inline — no extra detach needed.
  GH_TTL=0 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1
  exit 0
fi

# --- interactive keypress: cache-based cycle + optimistic repaint, bg the gh work -
# Cycle from the tier the backlog row ACTUALLY shows (the labels cache), so ⌃y is
# consistent with what's on screen and needs NO network round-trip to decide.
LBL=$(fleet_cache labels "$FLEET_SESSION")
cur=""
if [ -n "$LBL" ] && [ -f "$LBL" ]; then
  cur=$(awk -F'\t' -v n="$num" '$1==n{print $2; exit}' "$LBL" \
        | tr ',' '\n' | grep -m1 -E '^priority:p[0-2]$'); cur="${cur#priority:}"
fi

# Resolve the TARGET tier ("" = none).
case "$action" in
  p0|p1|p2) new="$action" ;;
  none|clear|"") new="" ;;
  cycle|*)                                 # raise one step, wrap: none→p2→p1→p0→none
    case "$cur" in p0) new="" ;; p1) new="p0" ;; p2) new="p1" ;; *) new="p2" ;; esac ;;
esac

# No-op if the target already matches (explicit set to the same tier).
if [ "$cur" = "$new" ]; then
  tmux display-message "#$num already ${new:+priority:$new}${new:-unprioritised}"
  exit 0
fi

# Optimistic labels-cache rewrite (SYNC) so the ⌃y reload shows the new tag AT ONCE
# (mirrors dash-issue-new/close). Strip priority:* from this issue's CSV, append the
# target, leave every other row untouched. Absent row (issue not cached yet) → left
# for the collector to add; the tag simply appears on the next tick.
if [ -n "$LBL" ] && [ -f "$LBL" ]; then
  tmp="$LBL.tmp.$$"
  if awk -F'\t' -v n="$num" -v np="$new" 'BEGIN{OFS="\t"}
    $1==n {
      out=""; m=split($2, a, ",")
      for(i=1;i<=m;i++) if(a[i]!="" && a[i] !~ /^priority:p[0-2]$/) out=(out==""?a[i]:out","a[i])
      if(np!="") out=(out==""?"priority:"np:out",priority:"np)
      $2=out
    }
    {print}' "$LBL" > "$tmp"; then mv -f "$tmp" "$LBL"; else rm -f "$tmp"; fi
fi

# Background the authoritative gh read+edit + reconcile (issue #304) so ⌃y returns
# INSTANTLY; on failure the bg job corrects the optimistic toast via display-message.
fleet_bg "bash '$0' '$num' --commit '$new'"
tmux display-message "#$num → ${new:+priority:$new}${new:-unprioritised} ✓"
exit 0
