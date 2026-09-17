#!/bin/bash
# dash-issue-session.sh <issue-number> [<target-session>] [--title <t>] [--agent <a>] — spawn a
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
#
# Exit status is the REASON, not just a verdict (issue #683) — a headless caller
# gets no toast, so the code + stderr are its only read of WHY nothing spawned:
#   0  spawned (or focused the window that already exists)
#   1  infrastructure — bad conf / worktree add / new-window / dispatch failed
#   2  at capacity — the global or per-fleet session cap (retry later)
#   3  already claimed — assignee / not OPEN / open PR (pick another, or --force)
# Every refusal ALSO prints its one-line reason on stderr, `dash-issue-session: …`,
# beside the sticky tmux toast a human at the client sees.
set -uo pipefail
# Parse: <issue-number> [<target-session>] [--title <t>] [--force].
# The two positionals keep their historic order (num, target-session). --title <t>
# is the
# AUTHORITATIVE window name (issue #216): a create-then-spawn caller
# (the operator's file+spawn op, the prefix+n quick-dispatch, the dash new-session box) passes
# the title it JUST wrote so the window is named after the WORK — not the bare
# issue-<N> slug it otherwise falls back to when the brand-new issue isn't in the
# collector cache yet and a post-create `gh issue view` lags or fails.
# --force (alias --reclaim) is the manual escape hatch past the cross-machine
# pre-spawn GitHub-claim dedup (issue #258): it spawns despite a live claim (a
# dead/abandoned peer worker that left the issue assigned+marked forever), skipping
# the claim check + claim-at-spawn entirely.
# --async (alias --detach-spawn) makes the SLOW tail — the multi-second `git
# worktree add` full checkout + the window spawn — run detached via
# `tmux run-shell -b`, so the caller (the fzf backlog Enter) returns instantly
# instead of freezing the popup on a big monorepo (issue #303). The synchronous
# GATE (cap / dedup / claim) still runs + refuses in the foreground; only its slow
# tail is backgrounded. Opt-in, interactive-only (a headless TARGET_SESS caller
# that needs the window id back stays synchronous).
num=""; TARGET_SESS=""; WIN_TITLE=""; ORIGIN=""; AGENT=""; FORCE_FLAG=0; ASYNC_FLAG=0; _pos=0; _want=""
for _a in "$@"; do
  # A value-taking flag (--title <t>) consumes the NEXT arg: _want carries that
  # expectation across one loop turn so the value isn't mistaken for a positional.
  if [ -n "$_want" ]; then
    case "$_want" in title) WIN_TITLE="$_a" ;; origin) ORIGIN="$_a" ;; agent) AGENT="$_a" ;; esac
    _want=""; continue
  fi
  case "$_a" in
    --force|--reclaim) FORCE_FLAG=1 ;;
    --async|--detach-spawn) ASYNC_FLAG=1 ;;
    --title) _want=title ;;      # value is the NEXT arg
    --title=*) WIN_TITLE="${_a#--title=}" ;;
    # --origin (issue #503): spawn provenance — who asked for this worker. A
    # headless caller states it (the dispatcher passes `autofill`, the bridge
    # `bridge`); left empty it is AUTO-DETECTED from the calling pane below
    # (a worker/scratch spawning a sibling), and empty-after-detect ≡ hub.
    --origin) _want=origin ;;
    --origin=*) ORIGIN="${_a#--origin=}" ;;
    # --agent (issue #547): which agent CLI THIS worker runs — `claude` or `codex`
    # — overriding the fleet's FLEET_AGENT for one spawn. Handed to the launcher
    # (bin/fleet-claude.sh --agent) inside the window command; validated below so
    # only a known token is ever embedded in that command string.
    --agent) _want=agent ;;
    --agent=*) AGENT="${_a#--agent=}" ;;
    # An UNKNOWN dash-flag is almost always a typo (e.g. --forc). Do NOT let it
    # fall through to the positional slots — treating "--forc" as the issue number
    # strips to "" and silently spawns the wrong thing. Warn loudly and ignore it.
    --*) printf 'dash-issue-session: ignoring unknown flag %s\n' "$_a" >&2
         tmux display-message "issues: ignoring unknown flag $_a" 2>/dev/null ;;
    *) _pos=$((_pos + 1)); case "$_pos" in 1) num="$_a" ;; 2) TARGET_SESS="$_a" ;; esac ;;
  esac
done
num="${num//[^0-9]/}"; [ -z "$num" ] && exit 0
case "$AGENT" in
  ''|claude|codex) : ;;
  *) printf 'dash-issue-session: unknown --agent %s (claude|codex) — using the fleet default\n' "$AGENT" >&2
     tmux display-message "issues: unknown --agent $AGENT — using the fleet default" 2>/dev/null; AGENT="" ;;
esac
BIN="$(cd "$(dirname "$0")" && pwd)"
SELF="$BIN/$(basename "$0")"                   # absolute path for the --async re-invoke
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
# Internal re-entry (issue #303): the --async dispatch below backgrounds a
# TAIL-ONLY re-invocation of THIS script through `tmux run-shell -b`, carrying the
# resolved session name in FLEET_SPAWN_TAIL. A non-empty FLEET_SPAWN_TAIL therefore
# does double duty: it (1) selects tail-only mode — the synchronous gate already ran
# + passed in the foreground, so skip it — and (2) names the target fleet, so the
# detached helper never leans on a "current client" that a run-shell context lacks.
TAIL_ONLY=0; [ -n "${FLEET_SPAWN_TAIL:-}" ] && TAIL_ONLY=1
SESS="${TARGET_SESS:-${FLEET_SPAWN_TAIL:-$(fleet_current_session)}}"
[ -z "$SESS" ] && { printf 'dash-issue-session: no target tmux session\n' >&2; tmux display-message "issues: no target tmux session" 2>/dev/null; exit 1; }
fleet_load_conf "$SESS"                       # multi-fleet: target THIS fleet's checkout
# Each fleet is its OWN tmux server on a named socket (== session name, issue
# #159). This spawn path runs BOTH interactively (in the target fleet, $TMUX set)
# AND headless from the dispatcher / issue-bridge revive (no $TMUX) — so route
# EVERY tmux call through TM(), which names the target fleet's socket explicitly.
# Naming -L is correct in-session too (it resolves to the same current socket).
SOCK=$(fleet_socket "$SESS")
TM() { tmux -L "$SOCK" "$@"; }
# Spawn provenance (issue #503): detect the calling pane's own key — issue-<N> /
# scratch-<N> when a worker or scratch is spawning this, empty (≡ hub) for the
# dash/backlog/operator — then let fleet_origin_canon decide between it and an
# explicit --origin: a canonical key or known literal (the headless dispatcher's
# `autofill`, the bridge's `bridge`) is honoured, a worktree BASENAME is folded to
# its key (a Claude that read this header passed `cd-conductor-scratch-52` and the
# dash could not group it), garbage yields to the detected key, and a cross-fleet
# spawn stamps the SOURCE fleet (#516 — the key would name another window on the
# target's dash). FOREGROUND pass only: the --async tail runs under run-shell -b
# with no caller pane, so the foreground bakes the resolved value into the tail's
# --origin (canon is idempotent on it). Sanitized inside canon — it becomes a
# window option and a run-shell embed.
_det=''; [ "$TAIL_ONLY" != 1 ] && _det=$(fleet_origin_key)
_src=''; [ -n "$_det" ] && [ -n "$TARGET_SESS" ] && _src=$(fleet_current_session)
ORIGIN=$(fleet_origin_canon "$ORIGIN" "$_det" "$TARGET_SESS" "$_src")
unset _det _src
# POSIX single-quote a value for safe embedding in the run-shell command string
# (the --async tail is a `sh -c` string, and an issue title can carry quotes / $ /
# backticks). Wrap in single quotes, escaping any embedded single quote as '\''.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# A refusal (cap / claimed / worktree-add / new-window fail) is a one-shot
# transient toast that's easy to miss — worse on iPad/Termius (issue #331). Make
# it STICKY: red + bold + a longer display-time than the default ~750ms status
# line, so the operator actually sees WHY nothing spawned. Additive — keeps the
# display-message idiom, just styled + held longer (FLEET_REFUSE_MS overrides).
# The toast is for a human at the tmux client; it is NOT a record (issue #683). A
# headless caller — the autofill dispatcher, the bridge's revive, an agent
# spawning from another pane — never sees it: the toast lands on SOMEONE ELSE's
# screen, and all the caller gets back is `1`, which cannot tell "retry later"
# (cap) from "pick another issue / --remove-assignee first" (claimed) from
# "something is broken" (infra). So every refusal ALSO prints its reason on
# stderr — the one channel a pipe / log / `$( )` capture can read — and the exit
# code names the class (header: 1 infra · 2 cap · 3 claimed). stderr is the
# record; the status line is the glance (the same split as fleet-bind.sh's die).
RC_INFRA=1; RC_CAP=2; RC_CLAIMED=3
REFUSE_MS="${FLEET_REFUSE_MS:-4000}"
case "$REFUSE_MS" in ''|*[!0-9]*) REFUSE_MS=4000;; esac
refuse() {  # <reason> — stderr line + sticky red toast; the CALLER exits with the class code
  printf 'dash-issue-session: %s\n' "$1" >&2
  TM display-message -d "$REFUSE_MS" "#[fg=red,bold] $1 " 2>/dev/null
}

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

# Immediate gate ack (issue #331): on a slow network the SYNCHRONOUS cap/dedup gh
# reads below run BEFORE the async "spawning #N…" ack — a 1–2s dead pause that
# makes Enter feel like it did nothing (worse on iPad/Termius). Emit a
# "checking #N…" toast at the TOP of the gate — interactive spawns only (a
# tail-only re-entry already passed the gate; a headless TARGET_SESS caller has no
# watcher) — so Enter always registers instantly, before any gh call.
if [ "$TAIL_ONLY" != 1 ] && [ -z "$TARGET_SESS" ]; then
  TM display-message "checking #${num}…" 2>/dev/null
fi

# Session cap (issues #28, #70): refuse to spawn once the GLOBAL cap
# (FLEET_GLOBAL_MAX_SESSIONS, default 8, across ALL fleets) OR this fleet's
# per-fleet cap (FLEET_MAX_SESSIONS, default 0 = unlimited) is reached. This is
# the shared choke point for every spawn path — the new-session box, the backlog
# Enter, AND any headless spawn (dash-issue-session.sh <n> <sess>) — so both caps
# are true ceilings regardless of who spawns.
# Passing $SESS enables the per-fleet check for THIS fleet. Exit RC_CAP (2) on
# refusal so a headless caller records an honest FAIL, not a false spawn — and
# can tell "retry later" from a claim or a broken spawn (issue #683).
# Sync-only: the --async tail re-entry (TAIL_ONLY) already passed this gate in the
# foreground — re-checking in the background could FALSE-refuse after we already
# acked "spawning" + claimed, if a sibling raced to the cap in between.
if [ "$TAIL_ONLY" != 1 ] && ! cap_msg=$(fleet_session_cap_ok "$SESS"); then refuse "$cap_msg"; exit "$RC_CAP"; fi

MAIN="${FLEET_MAIN:-}"
[ -d "$MAIN/.git" ] || { refuse "fleet.conf: FLEET_MAIN is not a git checkout"; exit "$RC_INFRA"; }
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
# Sync-only ([ "$TAIL_ONLY" != 1 ]): the READ gates the refusal and the WRITE
# (claim-at-spawn) is the anti-collision rail — both stay in the foreground so a
# refusal is immediate and the claim lands within ~1s (issue #303 keeps the gating
# synchronous + authoritative; only the slow worktree/window tail goes async). On
# the tail re-entry this already ran, and re-reading would see OUR OWN assignee and
# false-refuse.
issue_json=''; issue_fetched_at=0
if [ "$TAIL_ONLY" != 1 ] && [ "${FLEET_PRESPAWN_DEDUP:-1}" != 0 ] && [ "$FORCE_FLAG" != 1 ] \
   && [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
  # One issue read (assignee count · state) + one cheap open-PR probe. THE ASSIGNEE
  # IS THE CLAIM (issue #283): we no longer read or write a "▶ claiming" comment — its
  # substring match false-fired on any comment that merely MENTIONED the marker string
  # (e.g. this very issue's design comment tripped the dedup). Same-account caveat:
  # every worker assigns the SAME gh account, so we cannot tell "assigned to someone
  # else" — assigned AT ALL ⇒ taken. An empty read (gh down / missing issue) leaves
  # the counter 0 and state blank → NOT taken, so a gh outage degrades to today's
  # spawn-anyway behaviour, never a false refusal.
  # Keep the same gate header, followed by compact JSON from the SAME read (#459).
  # A failed pre-claim must never cache the pre-edit empty assignee as authoritative.
  issue_fetched_at=$(date +%s)
  cs=$(gh issue view "$num" --repo "$REPO" --json assignees,state,number,title,url,body,labels,comments \
        --jq '"\(.assignees|length)\t\(.state)", tojson' 2>/dev/null) || cs=''
  case "$cs" in
    *$'\n'*) issue_json=${cs#*$'\n'}; cs=${cs%%$'\n'*} ;;
  esac
  n_assignee=${cs%%$'\t'*}; st=${cs#*$'\t'}
  n_assignee="${n_assignee//[^0-9]/}"
  n_open_pr=$(gh pr list --repo "$REPO" --head "$slug" --state open --json number --jq 'length' 2>/dev/null)
  n_open_pr="${n_open_pr//[^0-9]/}"
  why=''
  if [ "${n_assignee:-0}" -gt 0 ]; then why='assigned'
  elif [ -n "$st" ] && [ "$st" != OPEN ]; then why="state $st"
  elif [ "${n_open_pr:-0}" -gt 0 ]; then why="open PR on $slug"
  fi
  if [ -n "$why" ]; then
    # Refuse and DO NOT spawn. Exit RC_CLAIMED (3) so a headless caller records an
    # honest FAIL, not a false spawn — mirroring the cap check — and can tell
    # "taken" from "at capacity". The reason names WHICH ledger read tripped: a
    # dangling assignee left by a killed worker (#631) needs `--remove-assignee`
    # or --force, a state/PR hit needs a different issue (issue #683). Sticky (#331).
    refuse "#$num already claimed elsewhere ($why) — not spawning; --force overrides a stale claim"
    exit "$RC_CLAIMED"
  fi
  # Free → claim NOW by assigning @me so a peer's check sees it within ~1s.
  # /fleet-claim stays and no-ops idempotently when it finds this pre-claim.
  gh issue edit "$num" --repo "$REPO" --add-assignee @me >/dev/null 2>&1 || issue_json=''
fi

wt="$(dirname "$MAIN")/$(basename "$MAIN")-$slug"

# Name the tmux window after the issue CONTENT, not a bare "issue-<N>". Resolution
# order (issue #216): an explicit --title wins — the create-then-spawn caller just
# wrote the issue and KNOWS its title, so it needs no network and can't miss the
# way a brand-new issue does in the not-yet-refreshed collector cache. Else fall
# back to the issue JSON just read by the gate (#459), then THIS fleet's cached
# issues (a backlog pick is already collected; the
# dash writes an optimistic row before spawning), then to a `gh issue view`
# round-trip (which can lag/fail right after create). The git branch/worktree stay
# "issue-<N>" (the PR map keys off the branch) — only the display name changes.
# CJK and other non-latin titles name the window in their own script (issue #579);
# only a title with no LETTERS at all (emoji/punctuation-only) falls back to the slug.
title="$WIN_TITLE"
if [ -z "$title" ] && [ -n "$issue_json" ]; then
  title=$(printf '%s\n' "$issue_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])' 2>/dev/null) || title=''
fi
if [ -z "$title" ]; then
  ISSUES=$(fleet_cache issues "$SESS")
  title=$(awk -F'\t' -v n="#$num" '$2==n{print $4; exit}' "$ISSUES" 2>/dev/null)
  [ -z "$title" ] && title=$(gh issue view "$num" --repo "$REPO" --json title -q .title 2>/dev/null)
fi
wname=$(fleet_win_name "$title"); [ -z "$wname" ] && wname="$slug"

# --- issue #303: --async backgrounds the SLOW tail (worktree add + new-window) ----
# The synchronous gate above has already run + passed (cap / dedup / claim-at-spawn),
# so any refusal has ALREADY surfaced and the issue is claimed. Now hand the
# multi-second `git worktree add` (a full checkout on a big monorepo is what froze
# the fzf backlog popup) plus the window spawn to the tmux SERVER via `run-shell -b`
# — the fleet's established detached-work idiom, which survives the popup closing
# (unlike a fragile shell &/disown) — and return NOW so the popup closes instantly.
# The detached helper is a TAIL-ONLY re-invocation of THIS script: FLEET_SPAWN_TAIL
# carries the session (and selects tail-only mode, skipping the gate just re-run);
# --title carries the already-resolved name so the window is still named from issue
# content with no cache/gh round-trip. Interactive-only: a headless TARGET_SESS
# caller needs the window id back, so it keeps today's synchronous behavior.
if [ "$ASYNC_FLAG" = 1 ] && [ "$TAIL_ONLY" != 1 ] && [ -z "$TARGET_SESS" ]; then
  TM display-message "spawning #${num}…" 2>/dev/null
  # run-shell -b runs in the tmux SERVER's environment, not this pane's, so any
  # pane-scoped knob the tail needs must be BAKED into the command. FLEET_SPAWN_TAIL
  # selects tail-only mode + names the fleet; FLEET_SPAWN_FOCUS is carried through
  # so "focus the new worker when ready" still works (default no-focus otherwise).
  _bg="FLEET_SPAWN_TAIL=$(shq "$SESS")"
  [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && _bg="$_bg FLEET_SPAWN_FOCUS=1"
  # >/dev/null 2>&1 on the detached tail (belt-and-suspenders for issue #401):
  # `tmux run-shell` DISPLAYS its command's stdout in an Esc-to-dismiss view, so
  # ANY stray tail stdout (the worktree add's "HEAD is now at …", a future addition)
  # would surface as a popup. Redirect the whole tail so nothing can. The tail's own
  # error reporting is unaffected — refuse() surfaces via `tmux display-message`, a
  # separate client call independent of this process's fds (its stderr copy is what
  # this redirect drops, and the tail has no caller left to read it — the
  # interactive --async path is toast-only by construction).
  _bg="$_bg exec $(shq "$SELF") $(shq "$num") --title $(shq "$title") --origin $(shq "$ORIGIN")${AGENT:+ --agent $AGENT} >/dev/null 2>&1"
  TM run-shell -b "$_bg" 2>/dev/null \
    || { refuse "spawn failed for #$num: dispatch"; exit "$RC_INFRA"; }
  exit 0
fi

# The seed-prompt handoff is per-fleet (keyed by issue-N, which repeats across
# repos) → fleets/<repo-slug>/ so two fleets spawning the same issue# never collide
# (issue #181).
tf="$(fleet_cache_dir "$(fleet_slug "$REPO")")/task_$slug.txt"
# Lifecycle (issues #277, #283, #299, #441): /fleet-claim is the SINGLE SOURCE OF
# TRUTH for the whole worker lifecycle — claim → load charter → ground → implement
# (weaving in the per-fleet FLEET_WORKER_PROMPT body ITSELF) → open a PR closing #N
# → merge it once the gate reads READY → STOP; a blocker → comment + stop.
# So the seed COLLAPSES to a bare `/fleet-claim` (issue #299): no #<N>, no claim
# line, no per-fleet body (issue #234) and no ship tail are duplicated here — the
# skill self-discovers its issue from the window's @issue binding set just below
# (fallback: the issue-<N> worktree name), reads FLEET_WORKER_PROMPT itself via
# fleet_worker_prompt_body, and owns the steps that used to live in the separate
# /fleet-ship and /fleet-blocked prompts. The claim stays native (assign @me).
#
# SLASH on purpose: claude EXPANDS a slash command supplied as the initial prompt
# (verified — it injects the skill's text deterministically), which is more
# reliable than seeding a prose "Run /fleet-claim" and hoping the model chooses to
# invoke it. If a future claude ever stops expanding an initial-prompt slash
# command, the documented fallback is to seed `Run /fleet-claim` instead. Scouts
# keep their OWN seed (read-only, never ship) and never route through this spawn.
#
# NOT hardcoded (issue #611): a plugin-installed fleet serves the SAME command
# namespaced — `/fleet:fleet-claim` — and a bare slash does not resolve there, so
# the seed would land as literal text and the worker would never claim. fleet_cmd
# probes which install path this machine has and types the form that resolves.
printf '%s' "$(fleet_cmd fleet-claim)" > "$tf"
git -C "$MAIN" fetch origin "$BASE" --quiet 2>/dev/null
if [ ! -d "$wt" ]; then
  # >/dev/null 2>&1 (BOTH streams), not just 2>/dev/null: `git worktree add`
  # prints "HEAD is now at …" / "branch … set up to track …" to STDOUT, and under
  # --async this runs in the run-shell -b tail whose stdout tmux surfaces as an
  # Esc-to-dismiss view (issue #401). Silence both so the spawn stays silent.
  git -C "$MAIN" worktree add -b "$slug" "$wt" "origin/$BASE" >/dev/null 2>&1 \
    || git -C "$MAIN" worktree add "$wt" "$slug" >/dev/null 2>&1 \
    || { refuse "spawn failed for #$num: worktree add"; exit "$RC_INFRA"; }
fi
# Machine-local, per-worktree Git metadata, never repo/charter content (#459).
# Clear on EVERY spawn (including force/opt-out/tail-only) so an old snapshot
# cannot survive a reuse. Async tails deliberately fall back to a fresh gh read.
python3 "$BIN/fleet-issue-cache.py" clear "$wt" 2>/dev/null || :
if [ -n "$issue_json" ]; then
  printf '%s\n' "$issue_json" | python3 "$BIN/fleet-issue-cache.py" write \
    "$wt" "$REPO" "$num" "$issue_fetched_at" 2>/dev/null || :
fi
# Capture the new window-id and drive every follow-up op through it — the window
# name is now the issue-title slug (not a unique handle), so targeting by
# "$SESS:$slug" name would bind/select the wrong window the moment that name
# collides (tmux errors "can't find window"); matches hub-session.sh /
# fleet-up.sh. Create in the fleet's session explicitly (the trailing ':' picks
# the next free window index) so it works headless with no client attached.
# Route through fleet-claude.sh so the session launches under the active
# subscription account (transparent `exec claude` when no accounts registered) —
# and, since issue #547, under the fleet's agent (FLEET_AGENT / --agent codex).
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
# `--agent <a>` (issue #547) rides inside the command when a caller chose one; the
# launcher consumes it and picks the agent. Validated to claude|codex above, so it
# is safe to embed bare. Absent (the default) the command string is unchanged.
win=$(TM new-window ${detach[@]+"${detach[@]}"} -P -F '#{window_id}' -t "$SESS:" -n "$wname" -c "$wt" "'$BIN/fleet-claude.sh'${AGENT:+ --agent $AGENT} \"\$(cat '$tf')\"; exec \$SHELL") \
  || { refuse "spawn failed for #$num: new-window"; exit "$RC_INFRA"; }
TM set-window-option -t "$win" @issue "$num" 2>/dev/null   # bind window ↔ issue
# Window handle (issue #566): the fleet's own short, typeable name for this window
# (`a1`…`z9`), unique among the fleet's live windows and accepted wherever a window
# target is. Best-effort by design — a lock timeout or an exhausted alphabet just
# leaves it unstamped and the dash's render-time backfill assigns one.
fleet_wid_stamp "$win" "$SOCK" >/dev/null 2>&1 || :
# Spawn provenance (issue #503): stamp WHO spawned this worker beside the binding.
# Unset ≡ hub-spawned (the default, untagged in the dash); the dash groups a
# tagged child under its live parent, and the reapers copy it into the history
# ledger's origin column before the window dies.
[ -n "$ORIGIN" ] && TM set-window-option -t "$win" @origin "$ORIGIN" 2>/dev/null

# (The sub-second cross-machine tie-break that re-read the ▶ claiming comment ids
# was retired with the claiming marker in issue #283 — the assignee is now the
# claim, and workers share one gh account so a per-attempt tie token no longer
# exists. Claim-at-spawn still shrinks the race window; it was never a mutex.)
# Non-invasive by default: leave the active window put and just confirm the spawn
# on the status line. Only jump to the new worker when the user opted in
# (FLEET_SPAWN_FOCUS=1) on an interactive spawn; a headless spawn stays silent.
if [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && [ -z "$TARGET_SESS" ]; then
  TM select-window -t "$win"
elif [ -z "$TARGET_SESS" ]; then
  TM display-message "spawned #$num → $wname" 2>/dev/null
fi
