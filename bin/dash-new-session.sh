#!/bin/bash
# dash-new-session.sh "<task text>" — every new session is BOUND to a GitHub issue.
# Creates an issue from the typed task (backlog = source of truth), then spawns the
# bound worktree session via dash-issue-session.sh. (Pick an EXISTING issue instead
# from the backlog panel: prefix+b, Enter.)
set -uo pipefail
text="$*"; text="${text#"${text%%[![:space:]]*}"}"
[ -z "$text" ] && exit 0
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
SESS=$(fleet_current_session)
fleet_load_conf "$SESS"                        # multi-fleet: target THIS fleet's repo
REPO="${FLEET_REPO:-}"
[ -z "$REPO" ] && { tmux display-message "fleet.conf: FLEET_REPO not set — cannot create issue"; exit 1; }
command -v gh >/dev/null 2>&1 || { tmux display-message "gh not found — cannot create issue"; exit 1; }

# Session cap (issues #28, #70): check BEFORE creating the issue so a full fleet
# doesn't leave a dangling backlog issue with no session behind it. Pass "$SESS"
# so BOTH the global and this fleet's per-fleet (FLEET_MAX_SESSIONS) cap are
# checked here — otherwise a fleet at its per-fleet cap (but under the global one)
# would create the issue, then have the downstream spawn refused, stranding it.
# dash-issue-session.sh re-checks the same way, so this is belt-and-braces.
if ! cap_msg=$(fleet_session_cap_ok "$SESS"); then tmux display-message "$cap_msg"; exit 1; fi

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

# Instant cache refresh: optimistically append the new issue to THIS fleet's
# backlog cache (visible on the panels' next repaint), then kick a real fetch in
# the background so the authoritative row replaces it within seconds.
#
# Resolve the SAME file the readers do (fleet_cache: this fleet's slug'd cache if
# the collector has fetched it, flat fallback otherwise). The old code always
# wrote the flat cache, so on a non-primary fleet — whose readers resolve to
# issues_<slug> — the optimistic row was invisible.
ISSUES=$(fleet_cache issues "$SESS")
row=$(printf '· no milestone\t#%s\t·\t%s' "$num" "$(printf '%s' "$title" | tr '\t' ' ')")
# Atomic write: build the new content in a PID-unique temp, then rename into
# place, so a concurrent collector/reader never sees a torn line (the old `>>`
# raced the collector's replace of the same file).
tmp="$ISSUES.opt.$$"
{ [ -s "$ISSUES" ] && cat "$ISSUES"; printf '%s\n' "$row"; } > "$tmp" && mv "$tmp" "$ISSUES"
# Invalidate this fleet's .ts so the next collector cycle re-fetches. BACKDATE
# rather than delete: fleet_cache keys off the .ts EXISTING to pick the slug'd
# cache, so removing it would flip readers back to the flat cache and hide the
# row we just wrote. (Flat fallback has no live .ts — nothing to invalidate.)
[ -e "$ISSUES.ts" ] && echo 0 > "$ISSUES.ts"
( GH_TTL=0 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1 & )

exec bash "$BIN/dash-issue-session.sh" "$num"
