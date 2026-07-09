#!/bin/bash
# dash-enter.sh <target sess:idx> <query> — Enter handler for the dash.
# Emits fzf actions on stdout (called from an fzf `transform` binding) and does
# the tmux side-effect. Modes:
#   bind mode    (bind flag, set by ctrl-g): bind/unbind <target> to issue query
#   rename mode  (rename flag, set by ctrl-e): rename <stored target> to query
#   jump         (default): select the target window (typed query is ignored)
set -uo pipefail
C="${TMPDIR:-/tmp}/.claude-dash"; flag="$C/rename_target"; bindflag="$C/bind_target"
target="${1:-}"; q="${2:-}"
PROMPT='▸ '
BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"

# LANDED view (dash ⌃t): rows carry a `landed:<pr>` / `landed:issue:<n>` target,
# not a live window — Enter opens that PR in your browser instead of jumping (#130).
# Per-fleet keyed (FLEET_SESSION), matching dash-view-toggle.sh. Clear any half-set
# rename/bind flag first so a mode toggled in landed view can't leak into the next
# live-view Enter (those flags are meaningless on a landed row).
if [ "$(cat "$C/dash_view_${FLEET_SESSION:-default}" 2>/dev/null)" = landed ]; then
  rm -f "$flag" "$bindflag"
  case "$target" in
    landed:issue:*)   echo "clear-query"; exit 0 ;;   # PR-less row — nothing to open
    landed:*)
      pr="${target#landed:}"
      # shellcheck source=/dev/null
      . "$BIN/fleet-lib.sh" 2>/dev/null || true
      repo=$(fleet_repo_cached "${FLEET_SESSION:-}" 2>/dev/null)
      [ -z "$repo" ] && { fleet_load_conf "${FLEET_SESSION:-}" 2>/dev/null; repo="${FLEET_REPO:-}"; }
      case "$pr" in
        ''|*[!0-9]*) : ;;                             # not a numeric PR — skip
        *) [ -n "$repo" ] && (sh "$BIN/open-url.sh" "https://github.com/$repo/pull/$pr" >/dev/null 2>&1 &) ;;
      esac
      echo "clear-query"; exit 0 ;;
  esac
fi

if [ -f "$bindflag" ]; then                       # bind-issue mode (empty q unbinds)
  t=$(cat "$bindflag"); rm -f "$bindflag"
  tmux set-window-option -t "$t" @issue "$q" 2>/dev/null
  echo "hide-input+change-prompt($PROMPT)+clear-query+reload(bash $ROWS)"
elif [ -f "$flag" ]; then                         # rename mode
  t=$(cat "$flag"); rm -f "$flag"
  if [ -n "$q" ]; then tmux rename-window -t "$t" "$q" 2>/dev/null
    echo "hide-input+change-prompt($PROMPT)+clear-query+reload(bash $ROWS)"
  else echo "hide-input+change-prompt($PROMPT)+clear-query"; fi
else                                              # jump (typed query is ignored)
  tmux select-window -t "$target" 2>/dev/null
  echo "clear-query"
fi
