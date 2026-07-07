#!/bin/bash
# dash-new-session.sh "<task text>" — every new session is BOUND to a GitHub issue.
# Creates an issue from the typed task (backlog = source of truth), then spawns the
# bound worktree session via dash-issue-session.sh. (Pick an EXISTING issue instead
# from the backlog panel: prefix+b, Enter.)
text="$*"; text="${text#"${text%%[![:space:]]*}"}"
[ -z "$text" ] && exit 0
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
REPO="${FLEET_REPO:-}"
[ -z "$REPO" ] && { tmux display-message "fleet.conf: FLEET_REPO not set — cannot create issue"; exit 1; }
command -v gh >/dev/null 2>&1 || { tmux display-message "gh not found — cannot create issue"; exit 1; }

# Backstop throttle (multi-line pastes are coalesced upstream by
# dash-task-buffer.sh, so a burst reaches us as ONE call; this only guards
# against pathological loops).
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
now=$(date +%s); last=$(cat "$C/last_issue_create" 2>/dev/null || echo 0)
if [ $(( now - last )) -lt 5 ]; then
  tmux display-message "issue create throttled — wait 5s"; exit 0
fi
echo "$now" > "$C/last_issue_create"

# first line = title, rest (if any) = body
title="${text%%$'\n'*}"
url=$(gh issue create --repo "$REPO" --title "$title" \
        --body "Created from the claude-fleet dashboard new-session box.

$text" 2>/dev/null)
num=$(printf '%s' "$url" | grep -oE '[0-9]+$')
if [ -z "$num" ]; then tmux display-message "issue create failed — session not spawned"; exit 1; fi

# Instant cache refresh: optimistically append the new issue to the backlog
# cache (visible on the panels' next repaint), then kick a real fetch in the
# background so the authoritative row replaces it within seconds.
printf '· no milestone\t#%s\t·\t%s\n' "$num" "$(printf '%s' "$title" | tr '\t' ' ')" >> "$C/issues"
rm -f "$C/issues.ts"
( GH_TTL=0 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1 & )

exec bash "$BIN/dash-issue-session.sh" "$num"
