#!/bin/bash
# dash-issue-priority.sh <issue-number> [cycle|p0|p1|p2|none] — set/cycle an
# issue's priority tier straight from the backlog panel (issue #235).
#
# Priority is the `priority:p{0,1,2}` LABEL the autofill dispatcher already ranks
# by (bin/fleet-dispatch.sh) and the backlog rows now tag + sort by
# (bin/tmux-issues-rows.sh) — so managing priority is just swapping that one
# label. This is the ⌃y keyboard path (bound in bin/tmux-issues.sh): NO text
# input, so it needs no popup and works identically in the windowed panel and the
# prefix+b popup (unlike ⌃t/⌃x, which prompt and so route through the sentinel).
#
#   cycle (default): raise the priority by one step and wrap —
#                      none → p2 → p1 → p0 → none.
#   p0|p1|p2|none    set that tier explicitly (used by the selftest; also handy
#                      if a caller wants a direct set).
#
# Reads the issue's ACTUAL current priority label from gh (authoritative, one
# cheap call) so a stale cache can't leave two priority labels; removes whatever
# priority label is really there and adds the target. Then optimistically rewrites
# this issue's row in the labels cache so the panel's reload shows the new tag at
# once, and kicks a background collector refetch to reconcile.
set -uo pipefail
num="${1//[^0-9]/}"; [ -z "$num" ] && exit 0
action="${2:-cycle}"
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

FLEET_SESSION=$(fleet_current_session); export FLEET_SESSION
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
[ -n "${CF_REPO:-}" ] && REPO="$CF_REPO"
[ -z "$REPO" ] && { tmux display-message "backlog: no repo resolved — cannot set priority on #$num"; exit 1; }
command -v gh >/dev/null 2>&1 || { tmux display-message "gh not found — cannot set priority on #$num"; exit 1; }

# Authoritative current labels (so removes target what's really there).
cur_labels=$(gh issue view "$num" --repo "$REPO" --json labels -q '.labels[].name' 2>/dev/null)
cur=$(printf '%s\n' "$cur_labels" | grep -m1 -E '^priority:p[0-2]$'); cur="${cur#priority:}"

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

# Build ONE gh edit: strip every priority label actually present, add the target.
# edit_args always carries --repo, so its expansion is safe under set -u even when
# no labels are removed (bash 3.2 chokes on an empty declared-array expansion).
edit_args=(--repo "$REPO")
while IFS= read -r l; do
  case "$l" in priority:p0|priority:p1|priority:p2) edit_args+=(--remove-label "$l") ;; esac
done <<EOF
$cur_labels
EOF
[ -n "$new" ] && edit_args+=(--add-label "priority:$new")

if ! gh issue edit "$num" "${edit_args[@]}" >/dev/null 2>&1; then
  tmux display-message "failed to set priority on #$num"
  exit 1
fi

# Optimistic labels-cache rewrite so the ⌃y reload shows the new tag immediately
# (mirrors dash-issue-new/close). Strip priority:* from this issue's CSV, append
# the target, leave every other row untouched. Absent row (issue not cached yet) →
# left for the collector to add; the tag simply appears on the next tick.
LBL=$(fleet_cache labels "$FLEET_SESSION")
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
# Reconcile authoritatively in the background (ordering/dedup across the fetch).
( GH_TTL=0 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1 & )

tmux display-message "#$num → ${new:+priority:$new}${new:-unprioritised} ✓"
exit 0
