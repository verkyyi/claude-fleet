#!/bin/bash
# dash-open-pr.sh <landed-target> — open a landed row's PR in the browser (dash ⌃p).
#
# The pre-#261 landed-view Enter behavior (#130), extracted to its own key when Enter was
# repurposed to RESUME the finished session (= ⌃o). No-op on PR-less rows
# (landed:issue:<n>, landed:scratch:<key> — a scratch is addressed by its own key even
# when it escalated into a PR, #466), non-landed rows (a live-view row / header), and
# empty input — so it's safe to bind unconditionally; it only fires on a numeric-PR row.
#
# `--wid <@id|handle> [--probe]` (issue #898): a LIVE window's PR, for the task
# sidebar's row menu — the branch its worktree is on, looked up in this fleet's
# prmap cache (the same file the dash's PR column reads; no gh round-trip).
# `--probe` only prints the `#N` (nothing = no PR, so the menu greys the item).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
target="${1:-}"

if [ "$target" = --wid ]; then
  # shellcheck source=/dev/null
  . "$BIN/fleet-lib.sh" 2>/dev/null || exit 0
  w="$(fleet_wid_target "${2:-}")"
  case "$w" in @[0-9]*) ;; *) exit 0 ;; esac
  path=$(tmux display-message -p -t "$w" '#{@worktree}' 2>/dev/null)
  [ -n "$path" ] || path=$(tmux display-message -p -t "$w" '#{pane_current_path}' 2>/dev/null)
  branch=$(git -C "$path" branch --show-current 2>/dev/null)
  [ -n "$branch" ] || exit 0
  sess="${FLEET_SESSION:-$(tmux display-message -p -t "$w" '#{session_name}' 2>/dev/null)}"
  prmap=$(fleet_cache prmap "$sess")
  pr=$(awk -F'\t' -v b="$branch" '$1==b{print $2; exit}' "$prmap" 2>/dev/null)
  pr="${pr#\#}"
  case "$pr" in ''|*[!0-9]*) exit 0 ;; esac
  [ "${3:-}" = --probe ] && { printf '#%s\n' "$pr"; exit 0; }
  target="landed:$pr"
fi

# A merged landed row ends in `@<owner/name>` (issue #804): THAT repo's PR.
trepo=''
case "$target" in landed:*@*) trepo=${target#*@}; target=${target%@*} ;; esac
case "$target" in
  landed:issue:*|landed:scratch:*|'') exit 0 ;;   # PR-less / scratch row / empty — nothing to open
  landed:*)          pr="${target#landed:}" ;;
  *)                 exit 0 ;;               # not a landed row (live view / header)
esac
case "$pr" in ''|*[!0-9]*) exit 0 ;; esac    # not a numeric PR

# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh" 2>/dev/null || true
repo=$trepo
[ -n "$repo" ] || repo=$(fleet_repo_cached "${FLEET_SESSION:-}" 2>/dev/null)
[ -z "$repo" ] && { fleet_load_conf "${FLEET_SESSION:-}" 2>/dev/null; repo="${FLEET_REPO:-}"; }
[ -n "$repo" ] && sh "$BIN/open-url.sh" "https://github.com/$repo/pull/$pr"
exit 0
