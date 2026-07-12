#!/bin/bash
# dash-issue-session.sh <issue-number> [<target-session>] [--title <t>] — spawn a
# Claude session to work a GitHub issue: a git worktree issue-<N> off the base
# branch + a tmux window running `claude` seeded to read, claim, and implement the
# issue. The window is NAMED after the issue CONTENT (a short kebab of its title,
# falling back to issue-<N>) and bound to the issue via the @issue window option
# (both shown in the dash and backlog). Pass --title when you already know the
# title (a create-then-spawn caller) so the window is named descriptively without
# a cache/network round-trip — see the --title note below (issue #216).
#
# With no <target-session> the window is created in the CALLER's fleet (the
# interactive dash/backlog path). Pass <target-session> to spawn into a specific
# fleet you are not attached to — a headless spawn; in that mode we do NOT
# select-window, so a user attached to that session is never yanked to the new
# window.
set -uo pipefail
# Parse: <issue-number> [<target-session>] [--title <t>] [--force].
# The two positionals keep their historic order (num, target-session). --title <t>
# is the
# AUTHORITATIVE window name (issue #216): a create-then-spawn caller
# (the steward's file+spawn op, the prefix+n quick-dispatch, the dash new-session box) passes
# the title it JUST wrote so the window is named after the WORK — not the bare
# issue-<N> slug it otherwise falls back to when the brand-new issue isn't in the
# collector cache yet and a post-create `gh issue view` lags or fails.
# --force (alias --reclaim) is the manual escape hatch past the cross-machine
# pre-spawn GitHub-claim dedup (issue #258): it spawns despite a live claim (a
# dead/abandoned peer worker that left the issue assigned+marked forever), skipping
# the claim check + claim-at-spawn entirely.
num=""; TARGET_SESS=""; WIN_TITLE=""; FORCE_FLAG=0; _pos=0; _want=""
for _a in "$@"; do
  # A value-taking flag (--title <t>) consumes the NEXT arg: _want carries that
  # expectation across one loop turn so the value isn't mistaken for a positional.
  if [ -n "$_want" ]; then
    case "$_want" in title) WIN_TITLE="$_a" ;; esac
    _want=""; continue
  fi
  case "$_a" in
    --force|--reclaim) FORCE_FLAG=1 ;;
    --title) _want=title ;;      # value is the NEXT arg
    --title=*) WIN_TITLE="${_a#--title=}" ;;
    # An UNKNOWN dash-flag is almost always a typo (e.g. --forc). Do NOT let it
    # fall through to the positional slots — treating "--forc" as the issue number
    # strips to "" and silently spawns the wrong thing. Warn loudly and ignore it.
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
# Each fleet is its OWN tmux server on a named socket (== session name, issue
# #159). This spawn path runs BOTH interactively (in the target fleet, $TMUX set)
# AND headless from the dispatcher / issue-bridge revive (no $TMUX) — so route
# EVERY tmux call through TM(), which names the target fleet's socket explicitly.
# Naming -L is correct in-session too (it resolves to the same current socket).
SOCK=$(fleet_socket "$SESS")
TM() { tmux -L "$SOCK" "$@"; }

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
existing=$(TM list-windows -t "$SESS" -F '#{@issue} #{window_id}' 2>/dev/null | awk -v n="$num" '$1==n{print $2; exit}')
[ -z "$existing" ] && existing=$(TM list-windows -t "$SESS" -F '#{window_name} #{window_id}' 2>/dev/null | awk -v s="$slug" '$1==s{print $2; exit}')
if [ -n "$existing" ]; then
  msg="#$num already spawned"
  # Non-invasive by default: don't yank the caller to the existing window; just
  # note it. Opt into the jump with FLEET_SPAWN_FOCUS=1 (interactive spawns only).
  if [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && [ -z "$TARGET_SESS" ]; then
    TM select-window -t "$existing"
    TM display-message "$msg" 2>/dev/null
  elif [ -z "$TARGET_SESS" ]; then
    TM display-message "$msg" 2>/dev/null
  fi
  exit 0
fi

# Session cap (issues #28, #70): refuse to spawn once the GLOBAL cap
# (FLEET_GLOBAL_MAX_SESSIONS, default 8, across ALL fleets) OR this fleet's
# per-fleet cap (FLEET_MAX_SESSIONS, default 0 = unlimited) is reached. This is
# the shared choke point for every spawn path — the new-session box, the backlog
# Enter, AND any headless spawn (dash-issue-session.sh <n> <sess>) — so both caps
# are true ceilings regardless of who spawns.
# Passing $SESS enables the per-fleet check for THIS fleet. Exit non-zero on
# refusal so a headless caller records an honest FAIL, not a false spawn.
if ! cap_msg=$(fleet_session_cap_ok "$SESS"); then TM display-message "$cap_msg"; exit 1; fi

MAIN="${FLEET_MAIN:-}"
[ -d "$MAIN/.git" ] || { TM display-message "fleet.conf: FLEET_MAIN is not a git checkout"; exit 1; }
REPO="${FLEET_REPO:-$(git -C "$MAIN" remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"
BASE="${FLEET_BASE_BRANCH:-main}"

# --- Cross-machine pre-spawn dedup (issue #258; ON by default, FLEET_PRESPAWN_DEDUP=0 opts out) ---
# The local-tmux dedup above only sees THIS fleet's server. When two fleets run on
# DIFFERENT machines against the same repo, a peer's worker is invisible — both can
# spawn issue-<N> (duplicate worktrees, a non-fast-forward push race, competing PRs).
# This is the cross-machine backstop: consult the shared GitHub issue as the claim
# ledger, then claim AT SPAWN (assign @me — not on the worker's first /fleet-claim
# turn — that gap WAS the race) so a peer sees the assignee within ~1s. It is NOT a
# mutex (GitHub has no compare-and-swap on an issue), so a sub-second cross-machine
# overlap can still let two peers both pass — this shrinks the window, it does not
# eliminate it (there is no longer a comment-id tie-break; see issue #283). ON by
# default: the cross-machine safety is the right default and the marginal cost is a
# few gh READS per spawn — claim-at-spawn only MOVES the worker's own /fleet-claim
# assign earlier (same write; /fleet-claim then no-ops), and a gh outage/absence
# degrades to spawn-anyway (never a false refusal). A single-machine fleet that wants
# the zero-gh fast path opts out with FLEET_PRESPAWN_DEDUP=0. --force/--reclaim is the
# manual escape hatch past a stale claim.
if [ "${FLEET_PRESPAWN_DEDUP:-1}" != 0 ] && [ "$FORCE_FLAG" != 1 ] \
   && [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
  # One issue read (assignee count · state) + one cheap open-PR probe. THE ASSIGNEE
  # IS THE CLAIM (issue #283): we no longer read or write a "▶ claiming" comment — its
  # substring match false-fired on any comment that merely MENTIONED the marker string
  # (e.g. this very issue's design comment tripped the dedup). Same-account caveat:
  # every worker assigns the SAME gh account, so we cannot tell "assigned to someone
  # else" — assigned AT ALL ⇒ taken. An empty read (gh down / missing issue) leaves
  # the counter 0 and state blank → NOT taken, so a gh outage degrades to today's
  # spawn-anyway behaviour, never a false refusal.
  cs=$(gh issue view "$num" --repo "$REPO" --json assignees,state \
        --jq '"\(.assignees|length)\t\(.state)"' 2>/dev/null)
  n_assignee=${cs%%$'\t'*}; st=${cs#*$'\t'}
  n_assignee="${n_assignee//[^0-9]/}"
  n_open_pr=$(gh pr list --repo "$REPO" --head "$slug" --state open --json number --jq 'length' 2>/dev/null)
  n_open_pr="${n_open_pr//[^0-9]/}"
  if [ "${n_assignee:-0}" -gt 0 ] \
     || { [ -n "$st" ] && [ "$st" != OPEN ]; } || [ "${n_open_pr:-0}" -gt 0 ]; then
    # Refuse and DO NOT spawn. Exit non-zero so a headless caller records an honest
    # FAIL, not a false spawn — mirroring the cap check.
    TM display-message "#$num already claimed elsewhere — not spawning" 2>/dev/null
    exit 1
  fi
  # Free → claim NOW by assigning @me so a peer's check sees it within ~1s.
  # /fleet-claim stays and no-ops idempotently when it finds this pre-claim.
  gh issue edit "$num" --repo "$REPO" --add-assignee @me >/dev/null 2>&1
fi

wt="$(dirname "$MAIN")/$(basename "$MAIN")-$slug"

# Name the tmux window after the issue CONTENT, not a bare "issue-<N>". Resolution
# order (issue #216): an explicit --title wins — the create-then-spawn caller just
# wrote the issue and KNOWS its title, so it needs no network and can't miss the
# way a brand-new issue does in the not-yet-refreshed collector cache. Else fall
# back to THIS fleet's cached issues (a backlog pick is already collected; the
# dash writes an optimistic row before spawning), then to a `gh issue view`
# round-trip (which can lag/fail right after create). The git branch/worktree stay
# "issue-<N>" (the PR map keys off the branch) — only the display name changes.
# Empty/non-latin titles fall back to the slug.
title="$WIN_TITLE"
if [ -z "$title" ]; then
  ISSUES=$(fleet_cache issues "$SESS")
  title=$(awk -F'\t' -v n="#$num" '$2==n{print $4; exit}' "$ISSUES" 2>/dev/null)
  [ -z "$title" ] && title=$(gh issue view "$num" --repo "$REPO" --json title -q .title 2>/dev/null)
fi
wname=$(fleet_win_name "$title"); [ -z "$wname" ] && wname="$slug"

C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
G="$C/global"; mkdir -p "$G"
# The seed-prompt handoff is per-fleet (keyed by issue-N, which repeats across
# repos) → fleets/<repo-slug>/ so two fleets spawning the same issue# never collide
# (issue #181).
tf="$(fleet_cache_dir "$(fleet_slug "$REPO")")/task_$slug.txt"
# Lifecycle (issues #277, #283): THE FLEET NEVER MERGES, and /fleet-claim now
# carries the WHOLE worker lifecycle (claim → load charter → ground → implement →
# open PR + ARM GitHub auto-merge). So the seed COLLAPSES to essentially "run
# /fleet-claim": the skill owns the steps that used to live in separate /fleet-ship
# and /fleet-blocked prompts. The manual fallback spells out the same lifecycle for
# when the skill isn't installed. The claim is native (assign @me — no ▶ marker).
# shellcheck disable=SC2016  # backticks/`#` are literal prompt text for the spawned session, not expansions
claim=$(printf 'Run /fleet-claim — it claims the issue (assigns you), loads your worker charter, grounds you in the issue thread and the code, and carries the whole lifecycle through to opening the PR and arming GitHub auto-merge (the fleet never merges). If /fleet-claim is unavailable, do it by hand: `gh issue view %s --repo %s --comments`, then claim it with `gh issue edit %s --repo %s --add-assignee @me`, and implement in THIS worktree.' \
  "$num" "$REPO" "$num" "$REPO")
# The BODY between the /fleet-claim ritual and the tail is the one operator-
# customizable piece (issue #234): FLEET_WORKER_PROMPT / _FILE overrides it per
# fleet (default = the built-in instruction). fleet_worker_prompt_body strips any
# trailing sentence punctuation so the body stays a clause that flows into the
# tail's own leading '. '. The head (issue binding), $claim, and the tail below
# stay structural + intact.
body=$(fleet_worker_prompt_body "$num" "$REPO")
prefix=$(printf 'Work GitHub issue #%s in this repo. %s %s' "$num" "$claim" "$body")
tail=$(printf '. To finish: verify, push, and open a PR that closes #%s, then arm GitHub auto-merge with `gh pr merge --auto` — IMPORTANT: open the PR, arm auto-merge, and STOP; do NOT merge it yourself. GitHub merges the PR when it goes green, and the com.claude-fleet.cleanup daemon reaps this worktree/window afterward. If you hit a blocker you cannot resolve, say why in a comment on the issue and stop.' "$num")
printf '%s%s' "$prefix" "$tail" > "$tf"
git -C "$MAIN" fetch origin "$BASE" --quiet 2>/dev/null
if [ ! -d "$wt" ]; then
  git -C "$MAIN" worktree add -b "$slug" "$wt" "origin/$BASE" 2>/dev/null \
    || git -C "$MAIN" worktree add "$wt" "$slug" 2>/dev/null \
    || { TM display-message "issues: worktree add failed for $slug"; exit 1; }
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
win=$(TM new-window ${detach[@]+"${detach[@]}"} -P -F '#{window_id}' -t "$SESS:" -n "$wname" -c "$wt" "'$BIN/fleet-claude.sh' \"\$(cat '$tf')\"; exec \$SHELL") \
  || { TM display-message "issues: new-window failed for $slug in $SESS"; exit 1; }
TM set-window-option -t "$win" @issue "$num" 2>/dev/null   # bind window ↔ issue

# (The sub-second cross-machine tie-break that re-read the ▶ claiming comment ids
# was retired with the claiming marker in issue #283 — the assignee is now the
# claim, and workers share one gh account so a per-attempt tie token no longer
# exists. Claim-at-spawn still shrinks the race window; it was never a mutex.)
# Seed the dash summary column synchronously so the row isn't blank until the
# session renders content. summarize-hook.sh's SessionStart run skips a still-
# blank pane (no screen text yet), so without this the column stays empty until
# the first Stop or the ~180s daemon sweep. The LLM summarizer overwrites this
# placeholder once real content exists (it change-gates on a screen hash, not on
# prior file contents). Same key/format the readers expect: summary_<sess>_<winIdDigits>
# = one plaintext line (see tmux-summarize.sh, tmux-dashboard-rows.sh). The session
# prefix keeps per-fleet servers from colliding on the bare window id (issue #208).
seed="starting #$num"; [ -n "$title" ] && seed="$seed: $title"
printf '%s' "$seed" > "$G/summary_$(fleet_summary_key "$SESS" "$win")" 2>/dev/null || :
# Non-invasive by default: leave the active window put and just confirm the spawn
# on the status line. Only jump to the new worker when the user opted in
# (FLEET_SPAWN_FOCUS=1) on an interactive spawn; a headless spawn stays silent.
if [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && [ -z "$TARGET_SESS" ]; then
  TM select-window -t "$win"
elif [ -z "$TARGET_SESS" ]; then
  TM display-message "spawned #$num → $wname" 2>/dev/null
fi
