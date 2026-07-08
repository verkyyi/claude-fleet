#!/bin/bash
# dash-issue-session.sh <issue-number> [<target-session>] — spawn a Claude
# session to work a GitHub issue: a git worktree issue-<N> off the base branch +
# a tmux window running `claude` seeded to read, claim, and implement the issue.
# The window is NAMED after the issue title (falling back to issue-<N>) and bound
# to the issue via the @issue window option (both shown in the dash and backlog).
#
# With no <target-session> the window is created in the CALLER's fleet (the
# interactive dash/backlog path). Pass <target-session> to spawn into a specific
# fleet you are not attached to — a headless spawn; in that mode we do NOT
# select-window, so a user attached to that session is never yanked to the new
# window.
set -uo pipefail
num="${1:-}"; num="${num//[^0-9]/}"; [ -z "$num" ] && exit 0
TARGET_SESS="${2:-}"
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
SESS="${TARGET_SESS:-$(fleet_current_session)}"
[ -z "$SESS" ] && { tmux display-message "issues: no target tmux session"; exit 1; }
fleet_load_conf "$SESS"                       # multi-fleet: target THIS fleet's checkout

slug="issue-$num"

# Already spawned? Focus the existing window instead of stacking a duplicate, and
# short-circuit BEFORE the session cap — reusing a window adds no new session.
# Match on the @issue binding first (survives a ctrl-e rename), then the slug
# name. @issue is emitted FIRST so an unset value (empty) can't shift a window-id
# — which starts with '@' — into a numeric match. Target the resolved window-id:
# `select-window -t $SESS:issue-<N>` is ambiguous the moment two windows share
# that name (tmux errors "can't find window") — the very failure that left focus
# stranded on the dash. Scope the scan to $SESS (the target fleet, not the
# caller's) and, like every spawn below, only steal focus on the interactive path.
existing=$(tmux list-windows -t "$SESS" -F '#{@issue} #{window_id}' 2>/dev/null | awk -v n="$num" '$1==n{print $2; exit}')
[ -z "$existing" ] && existing=$(tmux list-windows -t "$SESS" -F '#{window_name} #{window_id}' 2>/dev/null | awk -v s="$slug" '$1==s{print $2; exit}')
if [ -n "$existing" ]; then
  [ -z "$TARGET_SESS" ] && tmux select-window -t "$existing"
  exit 0
fi

# Global session cap (issue #28): refuse to spawn once FLEET_GLOBAL_MAX_SESSIONS
# (default 8) Claude working sessions are already live across ALL fleets. This is
# the shared choke point for every spawn path — the new-session box, the backlog
# Enter, AND any headless spawn (dash-issue-session.sh <n> <sess>) — so the
# global cap is a true system-wide ceiling. Exit non-zero on refusal so a
# headless caller records an honest FAIL, not a false spawn.
if ! cap_msg=$(fleet_session_cap_ok); then tmux display-message "$cap_msg"; exit 1; fi

MAIN="${FLEET_MAIN:-}"
[ -d "$MAIN/.git" ] || { tmux display-message "fleet.conf: FLEET_MAIN is not a git checkout"; exit 1; }
REPO="${FLEET_REPO:-$(git -C "$MAIN" remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"
BASE="${FLEET_BASE_BRANCH:-main}"

wt="$(dirname "$MAIN")/$(basename "$MAIN")-$slug"

# Name the tmux window after the issue CONTENT, not a bare "issue-<N>". Resolve
# the title from THIS fleet's cached issues (no network — the dash writes the
# optimistic row before spawning; the collector fills it for backlog picks),
# and fall back to `gh issue view` only on a cache miss. The git branch/worktree
# stay "issue-<N>" (the PR map keys off the branch) — only the display name
# changes. Empty/non-latin titles fall back to the slug.
ISSUES=$(fleet_cache issues "$SESS")
title=$(awk -F'\t' -v n="#$num" '$2==n{print $4; exit}' "$ISSUES" 2>/dev/null)
[ -z "$title" ] && title=$(gh issue view "$num" --repo "$REPO" --json title -q .title 2>/dev/null)
wname=$(fleet_win_name "$title"); [ -z "$wname" ] && wname="$slug"

C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
tf="$C/task_$slug.txt"
# shellcheck disable=SC2016  # backticks/`#` are literal prompt text for the spawned session, not expansions
printf 'Work GitHub issue #%s in this repo. First read it: `gh issue view %s --repo %s --comments`. Then claim it (`gh issue edit %s --repo %s --add-assignee @me`), plan, and implement. Verify per the repo conventions before opening a PR that closes #%s.' \
  "$num" "$num" "$REPO" "$num" "$REPO" "$num" > "$tf"
git -C "$MAIN" fetch origin "$BASE" --quiet 2>/dev/null
if [ ! -d "$wt" ]; then
  git -C "$MAIN" worktree add -b "$slug" "$wt" "origin/$BASE" 2>/dev/null \
    || git -C "$MAIN" worktree add "$wt" "$slug" 2>/dev/null \
    || { tmux display-message "issues: worktree add failed for $slug"; exit 1; }
fi
# Capture the new window-id and drive every follow-up op through it — the window
# name is now the issue-title slug (not a unique handle), so targeting by
# "$SESS:$slug" name would bind/select the wrong window the moment that name
# collides (tmux errors "can't find window"); matches steward-session.sh /
# fleet-up.sh. Create in the fleet's session explicitly (the trailing ':' picks
# the next free window index) so it works headless with no client attached.
# Route through fleet-claude.sh so the session launches under the active
# subscription account (transparent `exec claude` when no accounts registered).
#
# Headless spawns (a <target-session> given) pass -d: new-window makes the new
# window CURRENT by default, which yanks a user attached to $SESS over to it even
# though we skip select-window below — so skipping select-window alone isn't
# enough to keep the active window put. Interactive spawns omit -d and select by id.
detach=(); [ -n "$TARGET_SESS" ] && detach=(-d)
# ${detach[@]+"${detach[@]}"}: expand to the flag(s) when set, to NOTHING when the
# array is empty — bash 3.2 (macOS) errors on a bare "${detach[@]}" under `set -u`
# when empty, which aborted every INTERACTIVE spawn (no target session → empty array).
win=$(tmux new-window ${detach[@]+"${detach[@]}"} -P -F '#{window_id}' -t "$SESS:" -n "$wname" -c "$wt" "'$BIN/fleet-claude.sh' \"\$(cat '$tf')\"; exec \$SHELL") \
  || { tmux display-message "issues: new-window failed for $slug in $SESS"; exit 1; }
tmux set-window-option -t "$win" @issue "$num" 2>/dev/null   # bind window ↔ issue
# Only steal focus for the interactive path; a headless spawn must not move the
# active window out from under an attached user.
[ -z "$TARGET_SESS" ] && tmux select-window -t "$win"
