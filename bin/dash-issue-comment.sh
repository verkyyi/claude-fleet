#!/bin/bash
# dash-issue-comment.sh <issue-number> [confirm] — add a quick comment to a
# GitHub issue straight from the backlog panel (triage without leaving tmux).
# Called with just the number it opens a small popup that reads one line of
# text; the popup re-invokes it with `confirm`, which runs `gh issue comment`,
# then invalidates the issue's preview cache so the pane repaints with the new
# comment on the next hover. For a longer reply, open the issue on the web
# (⌃o) — this is the one-liner triage path ("dupe of #5", "wontfix", …).
num="${1//[^0-9]/}"; [ -z "$num" ] && exit 0
mode="${2:-}"
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"

FLEET_SESSION=$(fleet_current_session); export FLEET_SESSION
# repo: CF_REPO (passed through the popup) wins; else the fleet's cached repo,
# else the global FLEET_REPO — matching the backlog panel's resolution.
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
[ -n "${CF_REPO:-}" ] && REPO="$CF_REPO"
[ -z "$REPO" ] && { tmux display-message "backlog: no repo resolved — cannot comment on #$num"; exit 1; }
command -v gh >/dev/null 2>&1 || { tmux display-message "gh not found — cannot comment on #$num"; exit 1; }

# phase 1: pop the input dialog that re-invokes us in `confirm` mode.
if [ "$mode" != confirm ]; then
  tmux display-popup -w 90% -h 9 -E "CF_REPO='$REPO' bash '$BIN/dash-issue-comment.sh' '$num' confirm"
  exit 0
fi

# phase 2: running inside the popup — read one line, then post it.
printf '\n  Comment on \033[1m#%s\033[0m in %s\n  (empty = cancel)\n\n  ▸ ' "$num" "$REPO"
IFS= read -r body
[ -z "$body" ] && exit 0

# Route through fleet-comment.sh so the marker + per-role footer are stamped: a
# backlog triage note is fleet-internal (for the record/humans) → no-relay, so it
# can't loop back into a bound worker when the issue-bridge is on (issue #132), and
# it's posted as the `dash` role (--from dash, issue #224). --note is the default,
# named here for clarity. Fall back to plain gh with a minimal STATIC dash footer +
# marker appended INLINE if the wrapper isn't present (a partial/diverged install) —
# so triage commenting never silently breaks, stays loop-safe, AND keeps attribution.
if { [ -x "$BIN/fleet-comment.sh" ] && "$BIN/fleet-comment.sh" "$num" --repo "$REPO" --from dash --note --body "$body" >/dev/null 2>&1; } \
   || gh issue comment "$num" --repo "$REPO" --body "$body"$'\n\n— fleet · dash · #'"$num"$'\n<!-- fleet:from role=dash issue='"$num"$' -->\n<!-- fleet:no-relay -->' >/dev/null 2>&1; then
  : # posted (via wrapper or the marker-carrying fallback)
  # invalidate the per-issue preview cache so the pane refetches with the new
  # comment on the next hover / refresh-preview.
  FD=$(fleet_cache_dir "$(fleet_slug "$REPO")")              # fleets/<slug>/ (issue #181)
  rm -f "$FD/issue_${num}.json" "$FD/issue_${num}.json.ts"
  tmux display-message "commented on #$num ✓"
else
  printf '\n  \033[31mfailed to comment on #%s\033[0m — press any key ' "$num"; read -rsn1 _
fi
