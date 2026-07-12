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

# LANDED view (dash ⌃t): rows carry a `landed:<pr>` / `landed:issue:<n>` target, not a
# live window — Enter RESUMES that finished session, identical to ⌃o: it hands the target
# to dash-restore-session.sh, which reconstructs the removed worktree off the squash SHA and
# reopens a `claude --resume` window (#261). Both row shapes resume (dash-restore-session.sh's
# restore_key_for handles landed:issue:<n> and landed:<pr>). Open the row's PR in the browser
# with ⌃p (dash-open-pr.sh) — the pre-#261 Enter behavior (#130), relocated so Enter can jump.
# Per-fleet keyed (FLEET_SESSION), matching dash-view-toggle.sh. Clear any half-set rename/bind
# flag first so a mode toggled in landed view can't leak into the next live-view Enter.
if [ "$(cat "$C/global/dash_view_${FLEET_SESSION:-default}" 2>/dev/null)" = landed ]; then
  rm -f "$flag" "$bindflag"
  case "$target" in
    landed:*)   # landed:<pr> or landed:issue:<n> — resume the finished session (= ⌃o, #261)
      bash "$BIN/dash-restore-session.sh" "$target" >/dev/null 2>&1
      echo "clear-query+reload(bash $ROWS)"; exit 0 ;;
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
