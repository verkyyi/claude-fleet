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
# Parse: <issue-number> [<target-session>] [--title <t>] [--self-land] [--scout] [--force].
# The two positionals keep their historic order (num, target-session); --self-land
# may appear anywhere and switches the seed prompt to the worker-owned self-land
# lifecycle (issue #138); --scout spawns a READ-ONLY investigation worker that
# reports and never branches/ships/lands (issue #148). --title <t> is the
# AUTHORITATIVE window name (issue #216): a create-then-spawn caller
# (/fleet-new-issue, the prefix+n quick-dispatch, the dash new-session box) passes
# the title it JUST wrote so the window is named after the WORK — not the bare
# issue-<N> slug it otherwise falls back to when the brand-new issue isn't in the
# collector cache yet and a post-create `gh issue view` lags or fails.
# --force (alias --reclaim) is the manual escape hatch past the cross-machine
# pre-spawn GitHub-claim dedup (issue #258): it spawns despite a live claim (a
# dead/abandoned peer worker that left the issue assigned+marked forever), skipping
# the claim check + claim-at-spawn entirely.
num=""; TARGET_SESS=""; SELF_LAND_FLAG=0; SCOUT_FLAG=0; WIN_TITLE=""; FORCE_FLAG=0; _pos=0; _want=""
for _a in "$@"; do
  # A value-taking flag (--title <t>) consumes the NEXT arg: _want carries that
  # expectation across one loop turn so the value isn't mistaken for a positional.
  if [ -n "$_want" ]; then
    case "$_want" in title) WIN_TITLE="$_a" ;; esac
    _want=""; continue
  fi
  case "$_a" in
    --self-land) SELF_LAND_FLAG=1 ;;
    --scout) SCOUT_FLAG=1 ;;
    --force|--reclaim) FORCE_FLAG=1 ;;
    --title) _want=title ;;      # value is the NEXT arg
    --title=*) WIN_TITLE="${_a#--title=}" ;;
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
  # A scout and a worker for the same issue share the SAME issue-<N> worktree, so
  # they can't coexist — the existing window always wins the dedup. But the two
  # roles differ, so the message must be honest: a steward converting a scout
  # finding to ship work (spawn #N while its scout is still alive) must not read a
  # bare "already spawned" and believe a worker is implementing (issue #148). Tell
  # them a read-only scout holds the slot; the scout self-cleans when it reports,
  # freeing #N for a real worker spawn.
  existing_scout=$(TM show-options -w -v -t "$existing" @scout 2>/dev/null)
  if [ "$existing_scout" = 1 ] && [ "$SCOUT_FLAG" != 1 ]; then
    msg="#$num has a live READ-ONLY scout — wait for its report (it self-cleans), then re-spawn a worker"
  else
    msg="#$num already spawned"
  fi
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
# Enter, AND any headless spawn (dash-issue-session.sh <n> <sess>, incl. the
# autofill dispatcher) — so both caps are true ceilings regardless of who spawns.
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
# ledger, then claim AT SPAWN (not on the worker's first /fleet-claim turn — that gap
# WAS the race) so a peer sees the marker within ~1s. It is NOT a mutex (GitHub has
# no compare-and-swap on an issue), so two peers can still both pass in a sub-second
# overlap — the post-window tie-break below resolves that remainder. ON by default:
# the cross-machine safety is the right default and the marginal cost is a few gh
# READS per spawn — claim-at-spawn only MOVES the worker's own /fleet-claim writes
# earlier (same write count; /fleet-claim then no-ops), and a gh outage/absence
# degrades to spawn-anyway (never a false refusal). A single-machine fleet that wants
# the zero-gh fast path opts out with FLEET_PRESPAWN_DEDUP=0. Scouts are read-only (no
# branch/push/PR race) → exempt; --force/--reclaim is the manual escape hatch past a
# stale claim.
my_claim_id=""
if [ "${FLEET_PRESPAWN_DEDUP:-1}" != 0 ] && [ "$FORCE_FLAG" != 1 ] && [ "$SCOUT_FLAG" != 1 ] \
   && [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
  # One issue read (assignee count · state · a ▶ claiming-comment count) + one cheap
  # open-PR probe. Same-account caveat: every worker assigns the SAME gh account, so
  # we cannot tell "assigned to someone else" — assigned/marked AT ALL ⇒ taken. An
  # empty read (gh down / missing issue) leaves every counter 0 and state blank → NOT
  # taken, so a gh outage degrades to today's spawn-anyway behaviour, never a false
  # refusal.
  cs=$(gh issue view "$num" --repo "$REPO" --json assignees,state,comments \
        --jq '"\(.assignees|length)\t\(.state)\t\((.comments//[])|map(.body)|map(select(contains("▶ claiming")))|length)"' 2>/dev/null)
  n_assignee=${cs%%$'\t'*}; _rest=${cs#*$'\t'}; st=${_rest%%$'\t'*}; n_claim=${_rest##*$'\t'}
  n_assignee="${n_assignee//[^0-9]/}"; n_claim="${n_claim//[^0-9]/}"
  n_open_pr=$(gh pr list --repo "$REPO" --head "$slug" --state open --json number --jq 'length' 2>/dev/null)
  n_open_pr="${n_open_pr//[^0-9]/}"
  if [ "${n_assignee:-0}" -gt 0 ] || [ "${n_claim:-0}" -gt 0 ] \
     || { [ -n "$st" ] && [ "$st" != OPEN ]; } || [ "${n_open_pr:-0}" -gt 0 ]; then
    # Refuse and DO NOT spawn. Exit non-zero so a headless caller (the autofill
    # dispatcher) records an honest FAIL, not a false spawn — mirroring the cap check.
    TM display-message "#$num already claimed elsewhere — not spawning" 2>/dev/null
    exit 1
  fi
  # Free → claim NOW so a peer's check sees it within ~1s. /fleet-claim stays and
  # no-ops idempotently when it finds this pre-claim. Post the marker via
  # fleet-comment.sh so it carries <!-- fleet:no-relay --> (never loops back into the
  # worker via the issue-bridge) + the worker footer; capture the created comment URL
  # — its monotonic issuecomment REST id is our tie-break token. Fall back to a direct
  # comment that keeps BOTH markers inline if the wrapper is unavailable.
  gh issue edit "$num" --repo "$REPO" --add-assignee @me >/dev/null 2>&1
  claim_url=$("$BIN/fleet-comment.sh" "$num" --repo "$REPO" --from worker --note --body '▶ claiming' 2>/dev/null) \
    || claim_url=$(gh issue comment "$num" --repo "$REPO" \
         --body "$(printf '▶ claiming\n\n— fleet · worker · #%s\n<!-- fleet:from role=worker issue=%s -->\n<!-- fleet:no-relay -->' "$num" "$num")" 2>/dev/null)
  my_claim_id=$(printf '%s\n' "$claim_url" | sed -n 's/.*#issuecomment-\([0-9][0-9]*\).*/\1/p' | tail -1)
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
  TM display-message "note: #$num --scout supersedes --self-land (a scout opens no PR to land)" 2>/dev/null
  SELF_LAND=0
fi
if [ "$SELF_LAND" = 1 ] && [ "${FLEET_ISSUE_BRIDGE:-0}" != 1 ]; then
  TM display-message "note: #$num spawned --self-land but FLEET_ISSUE_BRIDGE!=1 — no /land trigger channel; will fall back to steward-lands" 2>/dev/null
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
  # (issue #138). The BODY between the /fleet-claim ritual and the tail is the one
  # operator-customizable piece (issue #234): FLEET_WORKER_PROMPT / _FILE overrides
  # it per fleet (default = the built-in instruction). fleet_worker_prompt_body
  # strips any trailing sentence punctuation so the body stays a clause that flows
  # into the tail's own leading '. '/', ' — keeping the DEFAULT seed byte-identical.
  # The head (issue binding), $claim, and the tail below stay structural + intact.
  body=$(fleet_worker_prompt_body "$num" "$REPO")
  prefix=$(printf 'Work GitHub issue #%s in this repo. %s %s' "$num" "$claim" "$body")
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
# Mark a scout window (issue #148) so its self-clean can assert it's a scout and
# tooling can tell "no PR expected" from a normal worker.
[ "$SCOUT" = 1 ] && TM set-window-option -t "$win" @scout 1 2>/dev/null

# --- Best-effort tie-break (issue #258): resolve a simultaneous cross-machine race.
# We claimed then created the window; re-read the ▶ claiming comments. GitHub has no
# CAS, so two peers can both pass the pre-spawn check in the sub-second overlap and
# both claim. The EARLIEST claim wins — issuecomment REST ids are globally monotonic,
# so a claim id strictly smaller than ours means a peer got there first and we LOST →
# roll back the just-created window/worktree/branch cleanly and refuse. (Eventual-
# consistency lag can hide a peer's just-posted comment; this shrinks the race window,
# it is not a mutex.) Runs only when we actually claimed above (my_claim_id set).
if [ -n "$my_claim_id" ]; then
  earliest=$(gh issue view "$num" --repo "$REPO" --json comments \
    --jq '.comments[] | select(.body|contains("▶ claiming")) | .url' 2>/dev/null \
    | sed -n 's/.*#issuecomment-\([0-9][0-9]*\).*/\1/p' | sort -n | head -n1)
  if [ -n "$earliest" ] && [ "$earliest" -lt "$my_claim_id" ]; then
    # Kill the window FIRST (its just-launched process releases the worktree cwd),
    # then drop the worktree + the brand-new (commit-less) branch we just added.
    TM kill-window -t "$win" 2>/dev/null
    git -C "$MAIN" worktree remove --force "$wt" >/dev/null 2>&1
    git -C "$MAIN" branch -D "$slug" >/dev/null 2>&1
    git -C "$MAIN" worktree prune >/dev/null 2>&1
    TM display-message "#$num claimed earlier elsewhere — rolled back, not spawning" 2>/dev/null
    exit 1
  fi
fi
# Seed the dash summary column synchronously so the row isn't blank until the
# session renders content. summarize-hook.sh's SessionStart run skips a still-
# blank pane (no screen text yet), so without this the column stays empty until
# the first Stop or the ~180s daemon sweep. The LLM summarizer overwrites this
# placeholder once real content exists (it change-gates on a screen hash, not on
# prior file contents). Same key/format the readers expect: summary_<sess>_<winIdDigits>
# = one plaintext line (see tmux-summarize.sh, tmux-dashboard-rows.sh). The session
# prefix keeps per-fleet servers from colliding on the bare window id (issue #208).
seed="starting #$num"; [ "$SCOUT" = 1 ] && seed="scouting #$num"; [ -n "$title" ] && seed="$seed: $title"
printf '%s' "$seed" > "$G/summary_$(fleet_summary_key "$SESS" "$win")" 2>/dev/null || :
# Non-invasive by default: leave the active window put and just confirm the spawn
# on the status line. Only jump to the new worker when the user opted in
# (FLEET_SPAWN_FOCUS=1) on an interactive spawn; a headless spawn stays silent.
if [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && [ -z "$TARGET_SESS" ]; then
  TM select-window -t "$win"
elif [ -z "$TARGET_SESS" ]; then
  TM display-message "spawned #$num → $wname" 2>/dev/null
fi
