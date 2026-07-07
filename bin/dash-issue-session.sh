#!/bin/bash
# dash-issue-session.sh <issue-number> — spawn a Claude session to work a GitHub
# issue: a git worktree issue-<N> off the base branch + a tmux window running
# `claude` seeded to read, claim, and implement the issue. The window is bound
# to the issue via the @issue window option (shown in the dash and backlog).
num="${1//[^0-9]/}"; [ -z "$num" ] && exit 0
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
MAIN="${FLEET_MAIN:-}"
[ -d "$MAIN/.git" ] || { tmux display-message "fleet.conf: FLEET_MAIN is not a git checkout"; exit 1; }
REPO="${FLEET_REPO:-$(git -C "$MAIN" remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"
BASE="${FLEET_BASE_BRANCH:-main}"

slug="issue-$num"; wt="$(dirname "$MAIN")/$(basename "$MAIN")-$slug"
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
tf="$C/task_$slug.txt"
printf 'Work GitHub issue #%s in this repo. First read it: `gh issue view %s --repo %s --comments`. Then claim it (`gh issue edit %s --repo %s --add-assignee @me`), plan, and implement. Verify per the repo conventions before opening a PR that closes #%s.' \
  "$num" "$num" "$REPO" "$num" "$REPO" "$num" > "$tf"
git -C "$MAIN" fetch origin "$BASE" --quiet 2>/dev/null
if [ ! -d "$wt" ]; then
  git -C "$MAIN" worktree add -b "$slug" "$wt" "origin/$BASE" 2>/dev/null \
    || git -C "$MAIN" worktree add "$wt" "$slug" 2>/dev/null \
    || { tmux display-message "issues: worktree add failed for $slug"; exit 1; }
fi
tmux new-window -n "$slug" -c "$wt" "claude \"\$(cat '$tf')\"; exec \$SHELL"
tmux set-window-option -t "$slug" @issue "$num" 2>/dev/null   # bind window ↔ issue
tmux select-window -t "$slug"
