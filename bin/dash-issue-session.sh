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
# Parse: <issue-number> [<target-session>] [--self-land] [--scout]. The two
# positionals keep their historic order (num, target-session); --self-land may
# appear anywhere and switches the seed prompt to the worker-owned self-land
# lifecycle (issue #138); --scout spawns a READ-ONLY investigation worker that
# reports and never branches/ships/lands (issue #148).
num=""; TARGET_SESS=""; SELF_LAND_FLAG=0; SCOUT_FLAG=0; _pos=0
for _a in "$@"; do
  case "$_a" in
    --self-land) SELF_LAND_FLAG=1 ;;
    --scout) SCOUT_FLAG=1 ;;
    # An UNKNOWN dash-flag is almost always a typo (e.g. --self-lan). Do NOT let it
    # fall through to the positional slots — treating "--self-lan" as the issue
    # number strips to "" and silently spawns a plain steward-lands worker, so a
    # later /land trigger no-ops. Warn loudly and ignore it instead.
    --*) printf 'dash-issue-session: ignoring unknown flag %s\n' "$_a" >&2
         tmux display-message "issues: ignoring unknown flag $_a" 2>/dev/null ;;
    *) _pos=$((_pos + 1)); case "$_pos" in 1) num="$_a" ;; 2) TARGET_SESS="$_a" ;; esac ;;
  esac
done
num="${num//[^0-9]/}"; [ -z "$num" ] && exit 0
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
# caller's). Like every spawn below, focus is non-invasive by default and only
# moves on an interactive spawn when FLEET_SPAWN_FOCUS=1.
existing=$(tmux list-windows -t "$SESS" -F '#{@issue} #{window_id}' 2>/dev/null | awk -v n="$num" '$1==n{print $2; exit}')
[ -z "$existing" ] && existing=$(tmux list-windows -t "$SESS" -F '#{window_name} #{window_id}' 2>/dev/null | awk -v s="$slug" '$1==s{print $2; exit}')
if [ -n "$existing" ]; then
  # A scout and a worker for the same issue share the SAME issue-<N> worktree, so
  # they can't coexist — the existing window always wins the dedup. But the two
  # roles differ, so the message must be honest: a steward converting a scout
  # finding to ship work (spawn #N while its scout is still alive) must not read a
  # bare "already spawned" and believe a worker is implementing (issue #148). Tell
  # them a read-only scout holds the slot; the scout self-cleans when it reports,
  # freeing #N for a real worker spawn.
  existing_scout=$(tmux show-options -w -v -t "$existing" @scout 2>/dev/null)
  if [ "$existing_scout" = 1 ] && [ "$SCOUT_FLAG" != 1 ]; then
    msg="#$num has a live READ-ONLY scout — wait for its report (it self-cleans), then re-spawn a worker"
  else
    msg="#$num already spawned"
  fi
  # Non-invasive by default: don't yank the caller to the existing window; just
  # note it. Opt into the jump with FLEET_SPAWN_FOCUS=1 (interactive spawns only).
  if [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && [ -z "$TARGET_SESS" ]; then
    tmux select-window -t "$existing"
    tmux display-message "$msg" 2>/dev/null
  elif [ -z "$TARGET_SESS" ]; then
    tmux display-message "$msg" 2>/dev/null
  fi
  exit 0
fi

# Session cap (issues #28, #70): refuse to spawn once the GLOBAL cap
# (FLEET_GLOBAL_MAX_SESSIONS, default 8, across ALL fleets) OR this fleet's
# per-fleet cap (FLEET_MAX_SESSIONS, default 0 = unlimited) is reached. This is
# the shared choke point for every spawn path — the new-session box, the backlog
# Enter, AND any headless spawn (dash-issue-session.sh <n> <sess>, incl. the
# autofill dispatcher) — so both caps are true ceilings regardless of who spawns.
# Passing $SESS enables the per-fleet check for THIS fleet. Exit non-zero on
# refusal so a headless caller records an honest FAIL, not a false spawn.
if ! cap_msg=$(fleet_session_cap_ok "$SESS"); then tmux display-message "$cap_msg"; exit 1; fi

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
# Self-land lifecycle (issue #138): a worker owns its ENTIRE lifecycle incl. the
# land. Opt in per spawn (--self-land) or per fleet (FLEET_SELF_LAND=1). Self-land
# NEEDS the issue-bridge running (it is how the steward's /land trigger reaches the
# worker) — warn if the fleet hasn't enabled it, since without it the trigger can't
# arrive and the worker falls back to steward-lands.
SCOUT="$SCOUT_FLAG"
SELF_LAND="$SELF_LAND_FLAG"; [ "${FLEET_SELF_LAND:-0}" = 1 ] && SELF_LAND=1
# A scout is a READ-ONLY investigation: it never branches/ships/lands, so scout
# mode supersedes self-land (issue #148). Warn if both were asked for, then drop
# the self-land lifecycle — there is no PR to land.
if [ "$SCOUT" = 1 ] && [ "$SELF_LAND" = 1 ]; then
  tmux display-message "note: #$num --scout supersedes --self-land (a scout opens no PR to land)" 2>/dev/null
  SELF_LAND=0
fi
if [ "$SELF_LAND" = 1 ] && [ "${FLEET_ISSUE_BRIDGE:-0}" != 1 ]; then
  tmux display-message "note: #$num spawned --self-land but FLEET_ISSUE_BRIDGE!=1 — no /land trigger channel; will fall back to steward-lands" 2>/dev/null
fi
# The claim ritual ("run /fleet-claim, else do it by hand") is identical for every
# lifecycle — scout, self-land, and steward-lands — so build it ONCE here and reuse
# it, rather than hand-maintaining three copies that can drift (issue #148).
# shellcheck disable=SC2016  # backticks/`#` are literal prompt text for the spawned session, not expansions
claim=$(printf 'Start by running /fleet-claim (it reads, claims, and plans the issue); if /fleet-claim is unavailable, do it manually: `gh issue view %s --repo %s --comments`, then `gh issue edit %s --repo %s --add-assignee @me`, and plan.' \
  "$num" "$REPO" "$num" "$REPO")
if [ "$SCOUT" = 1 ]; then
  # Read-only scout seed (issue #148): investigate + report, NEVER implement. No
  # branch, no PR, no ship mandate — the closing move is a findings comment + a
  # self-clean (bin/fleet-scout-clean.sh, driven by /fleet-scout-report).
  # shellcheck disable=SC2016  # backticks/`#` are literal prompt text for the spawned session, not expansions
  printf 'Investigate GitHub issue #%s in this repo as a READ-ONLY scout. %s This is a SCOUT task: investigate and REPORT — do NOT implement. Make NO code edits, create NO branch, open NO PR. Read the code and run read-only commands (gh/grep/git log) to gather findings. When your investigation is complete, run /fleet-scout-report — it posts your findings as an issue comment and self-cleans this window (there is no PR to merge). If /fleet-scout-report is unavailable, post your findings via `~/.claude/fleet/bin/fleet-comment.sh %s --repo %s --note --body '"'"'<findings>'"'"'` then run `~/.claude/fleet/bin/fleet-scout-clean.sh` to tear down. If the finding should convert to ship work, leave the issue OPEN and say so (a follow-up worker implements it); otherwise close it. Never open a PR.' \
    "$num" "$claim" "$num" "$REPO" > "$tf"
else
  # The claim→implement→ship preamble is identical for both non-scout lifecycles;
  # only the finish differs (steward-lands vs the worker's wait-for-trigger →
  # self-land). Build the shared prefix once, then append the seat-appropriate tail
  # (issue #138).
  prefix=$(printf 'Work GitHub issue #%s in this repo. %s Implement and verify per the repo conventions' "$num" "$claim")
  if [ "$SELF_LAND" = 1 ]; then
    # shellcheck disable=SC2016  # backticks are literal prompt text, not expansions
    tail=$(printf ', then run /fleet-ship (verify, push, open a PR that closes #%s). You own the FULL lifecycle of this issue including the land. After /fleet-ship, do NOT merge — WAIT. The steward reviews your PR and triggers the land by commenting `/land` (or `<!-- fleet:land -->`) on the issue, relayed to you as a turn by the issue-bridge. When you receive that trigger, run /fleet-land-self to land your OWN PR (re-verify green, sanitize your diff, lease-serialized squash-merge, base fast-forward, self-destruct). If it cannot land cleanly, run /fleet-blocked with the reason instead of forcing. Never merge un-triggered.' "$num")
  else
    tail=$(printf '. To finish, run /fleet-ship (verify, push, open a PR that closes #%s). IMPORTANT: open the PR and STOP — do NOT merge it yourself; the steward reviews and lands it (/fleet-land). If /fleet-ship is unavailable, open the PR manually and still do not merge.' "$num")
  fi
  printf '%s%s' "$prefix" "$tail" > "$tf"
fi
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
# Spawn is non-invasive by default: ALWAYS pass -d so new-window creates the
# window WITHOUT making it current — new-window makes the new window CURRENT by
# default, which yanks a user attached to $SESS over to it even though we skip
# select-window below, so -d is what actually keeps the active window put (for
# BOTH headless and interactive spawns). The new window surfaces via the dash
# instead. Opt back into jump-to-it with FLEET_SPAWN_FOCUS=1
# (interactive spawns only; a headless spawn must never steal focus).
detach=(-d); [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && [ -z "$TARGET_SESS" ] && detach=()
# ${detach[@]+"${detach[@]}"}: expand to the flag(s) when set, to NOTHING when the
# array is empty — bash 3.2 (macOS) errors on a bare "${detach[@]}" under `set -u`
# when empty, which aborted every INTERACTIVE spawn (no target session → empty array).
win=$(tmux new-window ${detach[@]+"${detach[@]}"} -P -F '#{window_id}' -t "$SESS:" -n "$wname" -c "$wt" "'$BIN/fleet-claude.sh' \"\$(cat '$tf')\"; exec \$SHELL") \
  || { tmux display-message "issues: new-window failed for $slug in $SESS"; exit 1; }
tmux set-window-option -t "$win" @issue "$num" 2>/dev/null   # bind window ↔ issue
# Mark a scout window (issue #148) so its self-clean can assert it's a scout and
# tooling can tell "no PR expected" from a normal worker.
[ "$SCOUT" = 1 ] && tmux set-window-option -t "$win" @scout 1 2>/dev/null
# Seed the dash summary column synchronously so the row isn't blank until the
# session renders content. summarize-hook.sh's SessionStart run skips a still-
# blank pane (no screen text yet), so without this the column stays empty until
# the first Stop or the ~180s daemon sweep. The LLM summarizer overwrites this
# placeholder once real content exists (it change-gates on a screen hash, not on
# prior file contents). Same key/format the readers expect: summary_<winIdDigits>
# = one plaintext line (see tmux-summarize.sh, tmux-dashboard-rows.sh).
seed="starting #$num"; [ "$SCOUT" = 1 ] && seed="scouting #$num"; [ -n "$title" ] && seed="$seed: $title"
printf '%s' "$seed" > "$C/summary_${win//[^0-9]/}" 2>/dev/null || :
# Non-invasive by default: leave the active window put and just confirm the spawn
# on the status line. Only jump to the new worker when the user opted in
# (FLEET_SPAWN_FOCUS=1) on an interactive spawn; a headless spawn stays silent.
if [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && [ -z "$TARGET_SESS" ]; then
  tmux select-window -t "$win"
elif [ -z "$TARGET_SESS" ]; then
  tmux display-message "spawned #$num → $wname" 2>/dev/null
fi
