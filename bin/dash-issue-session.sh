#!/bin/bash
# dash-issue-session.sh <issue-number> [<target-session>] [--repo <owner/name>] [--title <t>] [--agent <a>] — spawn a
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
#   4  no live parent — inside tmux with no $TMUX_PANE and no --origin, or an
#      --origin key no live session answers to (issue #1355); `--origin hub` = you
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
num=""; TARGET_SESS=""; WIN_TITLE=""; ORIGIN=""; AGENT=""; REPO_ARG=""; NODE_ARG=""; ORIGIN_WID=""; ACCOUNT_ARG=""; REAP=""; FORCE_FLAG=0; ASYNC_FLAG=0; _pos=0; _want=""
for _a in "$@"; do
  # A value-taking flag (--title <t>) consumes the NEXT arg: _want carries that
  # expectation across one loop turn so the value isn't mistaken for a positional.
  if [ -n "$_want" ]; then
    case "$_want" in title) WIN_TITLE="$_a" ;; origin) ORIGIN="$_a" ;; agent) AGENT="$_a" ;; repo) REPO_ARG="$_a" ;;
      node) NODE_ARG="$_a" ;; origin-wid) ORIGIN_WID="$_a" ;; account) ACCOUNT_ARG="$_a" ;; reap) REAP="$_a" ;; esac
    _want=""; continue
  fi
  # A FUSED "--flag value" (issue #1543) is --flag=value: zsh — Claude's Bash tool —
  # does not word-split an unquoted $var, so `extra="--node local"; … $extra` hands
  # us ONE arg, which fell to the unknown-flag branch and let the hub place a pinned
  # spawn on another machine.
  case "$_a" in
    '--title '*|'--origin '*|'--agent '*|'--repo '*|'--node '*|'--origin-wid '*|'--account '*|'--reap '*)
      _v=${_a#* }; _v=${_v#"${_v%%[! ]*}"}; _a="${_a%% *}=$_v" ;;
  esac
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
    # --repo (issue #789): which of the fleet's repos issue <N> belongs to. REQUIRED
    # once the fleet hosts 2+ repos (issue #12 exists once per repo — never guess);
    # in a one-repo fleet it defaults to that repo and must name it when given.
    --repo) _want=repo ;;
    --repo=*) REPO_ARG="${_a#--repo=}" ;;
    # --node (issue #1425, EPIC #1419 C6): which machine opens it — `auto` (the
    # hub picks by load, account headroom and the per-person cap), `local`, or a
    # machine name. Default with the hub module on (CCQUOTA_FLEET=1):
    # FLEET_SPAWN_NODE, else auto (issue #1475). A start
    # the hub itself sent is already placed: fleet-control-read.sh says --node local.
    # With the module off nothing changes unless --node names another machine.
    --node) _want=node ;;
    --node=*) NODE_ARG="${_a#--node=}" ;;
    # --origin-wid: the parent's worker_id when the parent is on ANOTHER machine
    # (a hub-placed start, fleet-control-read.sh passes it) — stamped as the
    # window's @origin_wid verbatim instead of being derived from --origin.
    --origin-wid) _want=origin-wid ;;
    --origin-wid=*) ORIGIN_WID="${_a#--origin-wid=}" ;;
    # --account (issue #1540, EPIC #1529 R2): which kind of subscription THIS
    # session runs on — `local` (this login's own token files), `pool` (the hub's
    # leased accounts, #1415) or `any` (the pick as always). Default: the fleet
    # conf's / login's FLEET_ACCOUNT_CLASS, else any. Stamped on the window as
    # @account_class before the launcher runs, and sent along with a remote
    # placement so the machine that opens it honours the same choice.
    --account) _want=account ;;
    --account=*) ACCOUNT_ARG="${_a#--account=}" ;;
    # --reap (issue #1902): when the fleet may close this session on its own —
    # merged[:<dur>] | done[:<dur>] | loop-end | at:<time> | keep. None = merged,
    # the historic rule (PR merged + the fleet's grace). Stamped as @reap_policy.
    --reap) _want=reap ;;
    --reap=*) REAP="${_a#--reap=}" ;;
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
case "$ACCOUNT_ARG" in
  ''|local|pool|any) : ;;
  *) printf 'dash-issue-session: unknown --account %s (local|pool|any) — using the fleet default\n' "$ACCOUNT_ARG" >&2
     tmux display-message "issues: unknown --account $ACCOUNT_ARG — using the fleet default" 2>/dev/null; ACCOUNT_ARG="" ;;
esac
BIN="$(cd "$(dirname "$0")" && pwd)"
SELF="$BIN/$(basename "$0")"                   # absolute path for the --async re-invoke
# The reap policy, canonical or refused before any gate runs (issue #1902).
if [ -n "$REAP" ]; then
  REAP=$(python3 "$BIN/fleet_reap_policy.py" norm "$REAP") || exit 2
fi
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-ui-lang.sh"   # fleet_ui_fail — the one failure line (issue #1618)
# Internal re-entry (issue #303): the --async dispatch below backgrounds a
# TAIL-ONLY re-invocation of THIS script through `tmux run-shell -b`, carrying the
# resolved session name in FLEET_SPAWN_TAIL. A non-empty FLEET_SPAWN_TAIL therefore
# does double duty: it (1) selects tail-only mode — the synchronous gate already ran
# + passed in the foreground, so skip it — and (2) names the target fleet, so the
# detached helper never leans on a "current client" that a run-shell context lacks.
TAIL_ONLY=0; [ -n "${FLEET_SPAWN_TAIL:-}" ] && TAIL_ONLY=1
SESS="${TARGET_SESS:-${FLEET_SPAWN_TAIL:-$(fleet_current_session)}}"
[ -z "$SESS" ] && { printf 'dash-issue-session: no target tmux session\n' >&2; fleet_ui_fail "issues: no target tmux session"; exit 1; }
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
ORIGIN_RAW=$ORIGIN                             # pre-canon: `hub` canonicalizes to empty
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
RC_INFRA=1; RC_CAP=2; RC_CLAIMED=3; RC_ORPHAN=4
REFUSE_MS="${FLEET_REFUSE_MS:-4000}"
case "$REFUSE_MS" in ''|*[!0-9]*) REFUSE_MS=4000;; esac
# The toast is fleet_ui_fail's (issue #1618): the one failure line, the palette's
# red, held FLEET_REFUSE_MS. A success draws nothing — the window is the answer.
refuse() {  # <reason> — stderr line + sticky red toast; the CALLER exits with the class code
  printf 'dash-issue-session: %s\n' "$1" >&2
  FLEET_UI_SOCK=$SOCK FLEET_REFUSE_MS=$REFUSE_MS fleet_ui_fail "$1"
}

# Which repo (issue #789). Every session is born with its repo written on it and
# spawns from THAT repo's checkout: its overlay (fleet_load_repo_conf) replaces
# whatever fleet_load_conf resolved — including a CALLER window's repo, which says
# nothing about the issue being spawned. A fleet hosting 2+ repos needs --repo; a
# one-repo fleet takes its only repo, and refuses a --repo naming any other.
MULTI=0; _fleet_hosts_many "$SESS" && MULTI=1
if [ "$MULTI" = 1 ] && [ -z "$REPO_ARG" ]; then
  refuse "#$num: this fleet hosts several repos — pass --repo <owner/name>"; exit "$RC_INFRA"
fi
if [ -n "$REPO_ARG" ] || [ "$MULTI" = 1 ]; then
  [ -n "$REPO_ARG" ] || REPO_ARG=$(fleet_repos "$SESS" | head -n1)
  REPO_ARG=$(fleet_norm_repo "$REPO_ARG")
  fleet_load_repo_conf "$SESS" "$REPO_ARG" \
    || { refuse "#$num: $REPO_ARG is not a repo this fleet hosts"; exit "$RC_INFRA"; }
fi

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
# 2+ repos (issue #789): identity is (repo, N) — B#12 is not a duplicate of A#12. Scan
# every candidate and keep the first whose repo is this one OR unknown: a window of
# unknown repo still blocks (a refused spawn is recoverable, a duplicate is not).
if [ "$MULTI" = 1 ]; then
  existing=''
  for _w in $( { TM list-windows -t "$SESS" -F '#{@issue} #{window_id}' 2>/dev/null | awk -v n="$num" '$1==n{print $2}'
                 TM list-windows -t "$SESS" -F '#{window_name} #{window_id}' 2>/dev/null | awk -v s="$slug" '$1==s || $1 ~ ("·" s "$") {print $2}'; } ); do
    _wr=$(fleet_window_repo "$SESS" "$_w")
    if [ -z "$_wr" ] || [ "$_wr" = "$REPO_ARG" ]; then existing=$_w; break; fi
  done
  unset _w _wr
fi
if [ -n "$existing" ]; then
  # Non-invasive by default: don't yank the caller to the existing window; just
  # say why nothing new opened. Opt into the jump with FLEET_SPAWN_FOCUS=1
  # (interactive spawns only) — the jump IS the answer then, so no line (#1618).
  if [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && [ -z "$TARGET_SESS" ]; then
    TM select-window -t "$existing"
  elif [ -z "$TARGET_SESS" ]; then
    FLEET_UI_SOCK=$SOCK fleet_ui_fail "$(fleet_ui_t ui_already_open_fmt "$num")" "$(fleet_ui_t ui_already_open_next)"
  fi
  exit 0
fi

# (The "checking #N…" / "spawning #N…" acks of issue #331 retired with #1618: a
# spawn that works says nothing — its window appearing is the answer — and one
# that does not says why, once, through refuse.)

# Session cap (issues #28, #70): refuse to spawn once the GLOBAL cap
# (FLEET_GLOBAL_MAX_SESSIONS, default 0 = off, across ALL fleets) OR this fleet's
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
# Placement (issue #1425, below): a spawn the hub may send to ANOTHER machine
# must not be stopped by THIS machine's caps or headroom — that is exactly when
# it should go elsewhere. So when placing, a cap refusal is held until placement
# answers, and enforced only if the session opens here after all.
case "$ORIGIN_WID" in ''|*[!A-Za-z0-9/:._-]*) ORIGIN_WID='' ;; esac
# A parent on another machine still needs its KEY as @origin: the child-report
# path (fleet-report-parent.sh) treats an empty @origin as hub-spawned and stays
# silent; with @origin_wid beside it, it routes by worker_id, never to a local
# window that merely shares the key (issue #1421).
if [ -n "$ORIGIN_WID" ] && [ -z "$ORIGIN" ]; then ORIGIN=$(fleet_origin_canon "${ORIGIN_WID#*/}" '' '' ''); fi
# The parent must be a LIVE session (issue #1355, EPIC #1645 C2): no $TMUX_PANE
# and no --origin, or a key no window answers to, would open a worker whose
# reports reach nobody. Foreground only — the --async tail carries the value this
# pass already vetted.
if [ "$TAIL_ONLY" != 1 ]; then
  _why=$(fleet_origin_gate "$SESS" "$ORIGIN_RAW" "$ORIGIN" "$ORIGIN_WID") \
    || { refuse "#$num: $_why"; exit "$RC_ORPHAN"; }
  unset _why
fi
NODE="$NODE_ARG"
# No --node: FLEET_SPAWN_NODE (issue #1475) — `auto` (the default), `local`, or
# a machine name — is what every spawn on this login follows, autofill included
# (FLEET_AUTOFILL_NODE, when set, is autofill's own override and arrives as
# --node). Only read with the hub on: off, nothing is placed anyway.
if [ -z "$NODE" ] && [ "${CCQUOTA_FLEET:-0}" = 1 ]; then
  NODE="${FLEET_SPAWN_NODE:-$(fleet_spawn_node_default)}"   # personal machine → local (#1721)
  case "$NODE" in ''|*[!A-Za-z0-9._-]*) NODE=auto ;; esac
fi
# The account class (issue #1540): --account, else the fleet conf's (fleet_load_conf
# above) / login's FLEET_ACCOUNT_CLASS. Only `local` / `pool` are a constraint; `any`
# on the command line switches a conf default OFF for this session. Empty ⇒ the
# window command, the place command and the launcher are byte for byte unchanged.
ACCOUNT="${ACCOUNT_ARG:-${FLEET_ACCOUNT_CLASS:-}}"
case "$ACCOUNT" in local|pool) : ;; *) ACCOUNT='' ;; esac
PLACING=0
[ "$TAIL_ONLY" != 1 ] && [ -n "$NODE" ] && ! fleet_node_is_self "$NODE" && PLACING=1
CAP_HELD=''
if [ "$TAIL_ONLY" != 1 ] && ! cap_msg=$(fleet_session_cap_ok "$SESS"); then
  if [ "$PLACING" = 1 ] && [ "${CCQUOTA_FLEET:-0}" = 1 ]; then CAP_HELD=$cap_msg
  else refuse "$cap_msg"; exit "$RC_CAP"; fi
fi

MAIN="${FLEET_MAIN:-}"
[ -d "$MAIN/.git" ] || { refuse "fleet.conf: FLEET_MAIN is not a git checkout"; exit "$RC_INFRA"; }
REPO="${FLEET_REPO:-$(git -C "$MAIN" remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"
BASE="${FLEET_BASE_BRANCH:-main}"

# --- Hub issue lease (issue #1422, EPIC #1419 C3; only when CCQUOTA_FLEET=1) ---
# The GitHub claim below is not a mutex (no compare-and-swap on an issue), so two
# machines that spawn the same issue within a second can both pass it. With the
# cross-machine hub on, take the hub's lease on (repo, issue) FIRST: the hub
# grants it to exactly one node, and the loser refuses here with the class code
# for "claimed" (3) and the holder's name. The GitHub check stays as the second
# guard. The lease renews itself off the node's heartbeats while the window lives
# and is released when the window goes (or 30 min after the node goes silent);
# a refusal AFTER the grant gives it back at once (the EXIT trap). --force takes
# it from a live holder — the hub records that. A hub that cannot be asked
# (unreachable, no ccquota, no fleet UUID) leaves one stderr note and today's
# path runs unchanged; CCQUOTA_FLEET unset runs none of this. Sync-only: the
# --async tail already holds the lease the foreground took.
LEASE_HELD=0
# CLAIMED_HERE (issue #1606, #1610): this spawn assigned @me on GitHub and no
# window holds the issue yet — a non-zero exit takes the assignee back, so a
# failed spawn leaves no dead claim that only --force gets past (hub on only).
# The --async
# tail inherits it from the foreground that claimed (FLEET_SPAWN_CLAIMED).
CLAIMED_HERE=0
[ "$TAIL_ONLY" = 1 ] && [ "${FLEET_SPAWN_CLAIMED:-0}" = 1 ] && CLAIMED_HERE=1
_spawn_back() {  # EXIT: a non-zero exit gives back what this spawn took
  local rc=$?
  if [ "$rc" != 0 ]; then
    [ "$LEASE_HELD" = 1 ] && fleet_hub_lease release "$SESS" "$REPO" "$num" >/dev/null 2>&1
    if [ "$CLAIMED_HERE" = 1 ] && [ -n "$REPO" ] \
       && gh issue edit "$num" --repo "$REPO" --remove-assignee @me >/dev/null 2>&1; then
      printf 'dash-issue-session: #%s 的 GitHub 认领已撤回 — 再派不用 --force\n' "$num" >&2
    fi
  fi
  exit "$rc"
}
[ "$CLAIMED_HERE" = 1 ] && trap _spawn_back EXIT
if [ "$TAIL_ONLY" != 1 ] && [ "${CCQUOTA_FLEET:-0}" = 1 ] && [ -n "$REPO" ]; then
  _lf=''; [ "$FORCE_FLAG" = 1 ] && _lf=--force
  lease_out=$(fleet_hub_lease acquire "$SESS" "$REPO" "$num" $_lf); lease_rc=$?
  case "$lease_rc" in
    0) LEASE_HELD=1
       trap _spawn_back EXIT
       case "$lease_out" in
         FORCED\ *)
           printf 'dash-issue-session: #%s 的入口租约已强制从 %s 收回 (--force，已在入口记录)\n' "$num" "$(printf '%s' "$lease_out" | awk '{print $3}')" >&2 ;;
         GRANTED\ *)  # issue #1507: a grant is said out loud, so a missing line means no lease
           printf 'dash-issue-session: #%s 的入口租约已拿到 (%s)\n' "$num" "${lease_out#GRANTED }" >&2 ;;
       esac ;;
    3) _holder=$(printf '%s' "$lease_out" | awk '{print $2}')
       refuse "#$num 已被 ${_holder:-另一台机器} 认领 (hub lease $(printf '%s' "$lease_out" | awk '{print $3}')) — not spawning; --force overrides a stale lease"
       exit "$RC_CLAIMED" ;;
  esac
  unset _lf _holder
fi

# --- Placement: which machine opens it (issue #1425, EPIC #1419 C6) ---
# With the hub on, a spawn need not name a machine: after the lease (above) the
# hub's pick_node chooses among this person's machines that host the repo —
# offline, >0.8 load/core, <1 GiB free or at the per-person cap are out, the rest
# scored on account headroom + load. LOCAL ⇒ carry on here exactly as before.
# REMOTE ⇒ the hub has handed that machine's fleet the lease and sent it the start
# (with this spawn's parent as origin_wid); nothing opens here and we exit 0. A
# hub that cannot be asked, or no machine that can take it, falls back to opening
# it here for `auto` — and refuses for a machine named explicitly, which the
# caller asked for by name. Sync-only, like the lease.
# Issue #1586: a REMOTE start is waited on (the hub's 60 s, issue #1606) until
# that machine really opened the window or really refused it. Refused ⇒ its
# reason on stderr and the same exit a refusal here gives (2 full · 3 claimed ·
# 1 anything else — a start that never reached that machine or never started
# there is 1 too), and the lease — the hub gave it back — released by the EXIT
# trap, so a re-send needs no --force. No final state in time ⇒ unknown: exit 1,
# never a success, and (issue #1606) the hub gave the lease back here as well.
# Refused for any reason but "claimed" with the issue unassigned before we
# asked ⇒ the GitHub claim that machine may have taken is withdrawn too (#1610).
# --async asks without waiting and leaves the operation id for fleet-children.sh.
# Every REMOTE answer is written to the parent's `children/<key>.dispatch`.
_place_note() {  # <state> <machine> <op> [<window>] [<exit>] [<line>]
  case "$ORIGIN" in issue-[0-9]*|scratch-[0-9]*|*:issue-[0-9]*) ;; *) return 0 ;; esac
  local ck="issue-$num"
  [ "$MULTI" = 1 ] && ck="$(fleet_slug "$REPO"):issue-$num"
  python3 "$BIN/fleet-children.py" dispatch \
    --file "$(fleet_state_dir "$SESS")/children/$(printf '%s' "$ORIGIN" | LC_ALL=C tr -cd 'A-Za-z0-9._:-').dispatch" \
    --child "$ck" --state "$1" --node "$2" --op "$3" --window "${4:-}" --exit "${5:-}" --line "${6:-}" >/dev/null 2>&1 || :
}
if [ "$PLACING" = 1 ]; then
  if [ "${CCQUOTA_FLEET:-0}" != 1 ] || [ -z "$REPO" ]; then
    if [ "$NODE" != auto ]; then
      refuse "--node $NODE needs the hub (CCQUOTA_FLEET=1) — not spawning #$num elsewhere"; exit "$RC_INFRA"
    fi
  else
    _pw="$ORIGIN_WID"
    if [ -z "$_pw" ] && _fleet_wid_split "$ORIGIN" >/dev/null 2>&1; then
      _pw=$(fleet_key_wid "$SESS" "$ORIGIN") || _pw=''   # by identity (#1646)
    fi
    _wait=''; [ "$ASYNC_FLAG" = 1 ] && _wait=0
    # Was the issue unassigned before we asked (issue #1610)? Only then may a
    # refused start's claim be withdrawn: an assignee that predates us is not
    # ours to take. Sync only — an --async ask hears no refusal to act on.
    _pre_asg=''
    if [ "$ASYNC_FLAG" != 1 ] && [ "${FLEET_PRESPAWN_DEDUP:-1}" != 0 ] && command -v gh >/dev/null 2>&1; then
      _pre_asg=$(gh issue view "$num" --repo "$REPO" --json assignees --jq '.assignees|length' 2>/dev/null)
    fi
    place_out=$(fleet_hub_place "$SESS" "$REPO" "$num" "$NODE" "$_pw" "$AGENT" "$_wait" "$ACCOUNT" '' "$REAP"); place_rc=$?
    _pv=${place_out%%$'\t'*}; _why=''; case "$place_out" in *$'\t'*) _why=${place_out#*$'\t'} ;; esac
    case "$place_rc:$_pv" in
      0:REMOTE\ *)
        # The lease is the remote fleet's now: the EXIT trap must not hand it back.
        LEASE_HELD=0
        read -r _ _m _op _st _w <<<"$_pv"
        if [ "$_st" = 'done' ]; then
          printf 'dash-issue-session: #%s → %s 已开窗 %s (hub operation %s) — %s\n' "$num" "$_m" "$_w" "$_op" "$_why" >&2
          _place_note 'done' "$_m" "$_op" "$_w" 0
        else
          printf 'dash-issue-session: #%s → %s (hub operation %s, %s) — %s\n' "$num" "$_m" "$_op" "$_st" "$_why" >&2
          _place_note accepted "$_m" "$_op"
        fi
        exit 0 ;;   # placed: its row on the list is the answer (issue #1618)
      5:DECLINED\ *)
        # That machine's spawn refused it. The hub handed the lease back to us,
        # so the EXIT trap (LEASE_HELD=1) releases it: the next send needs no --force.
        read -r _ _m _op _x <<<"$_pv"
        _place_note refused "$_m" "$_op" '' "$_x" "$_why"
        [ "$_x" != 3 ] && [ "$_pre_asg" = 0 ] && CLAIMED_HERE=1
        refuse "#$num 被 $_m 拒绝 (exit $_x): ${_why:-no reason given}"
        case "$_x" in 2) exit "$RC_CAP" ;; 3) exit "$RC_CLAIMED" ;; esac
        exit "$RC_INFRA" ;;
      6:UNKNOWN\ *)
        # Sent, but still running there when the wait ran out — not a success.
        # The hub gave the lease back (issue #1606): the EXIT trap releases it,
        # so nothing outlives a start nobody saw open. The GitHub claim stays —
        # should that machine open it after all, the claim keeps a second one off.
        read -r _ _m _op <<<"$_pv"
        _place_note unknown "$_m" "$_op" '' '' "$_why"
        refuse "#$num 已派到 $_m (hub operation $_op)，但没等到结果 — 未知，不当成功: ${_why:-no final state}"
        exit "$RC_INFRA" ;;
      0:LOCAL\ *)
        printf 'dash-issue-session: #%s 开在本机 %s — %s\n' "$num" "${_pv#LOCAL }" "$_why" >&2 ;;
      3:*)
        refuse "#$num 已被 ${_pv#HELD } 认领 (${_why}) — not spawning"; exit "$RC_CLAIMED" ;;
      *)
        if [ "$NODE" != auto ]; then
          refuse "#$num 不能开在 $NODE: ${_why:-${_pv:-hub unreachable}}"
          [ "$place_rc" = 4 ] && exit "$RC_CAP"; exit "$RC_INFRA"
        fi
        # Every machine at its session cap (issue #1587): the hub says all-full.
        # This one is full too, per its own gate ⇒ say 都满了, naming each machine;
        # it freed a slot since its last beat ⇒ open here after all.
        if [ "$_pv" = 'REFUSED AT_CAPACITY' ] && [ -n "$CAP_HELD" ]; then
          refuse "#$num 都满了 — 没有机器有空位: ${_why#all-full: }"; exit "$RC_CAP"
        fi
        [ "$place_rc" = 4 ] && printf 'dash-issue-session: 没有机器能接 #%s (%s) — 开在本机\n' "$num" "$_why" >&2 ;;
    esac
    unset _pw _u _pv _why _wait _pre_asg
  fi
fi
# Opening here after all: this machine's cap verdict, held above, now applies.
if [ -n "$CAP_HELD" ]; then refuse "$CAP_HELD"; exit "$RC_CAP"; fi

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
  if gh issue edit "$num" --repo "$REPO" --add-assignee @me >/dev/null 2>&1; then
    # Hub off ⇒ today's path, byte for byte (EPIC #1645 rule 6): no take-back.
    [ "${CCQUOTA_FLEET:-0}" = 1 ] && { CLAIMED_HERE=1; trap _spawn_back EXIT; }
  else
    issue_json=''
  fi
fi

# The ONE path exit (issue #886): FLEET_WORKTREE_ROOT, else a sibling of the base.
wt="$(fleet_worktree_dir "$MAIN" "$slug")"

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
# No repo tag on the name, even with 2+ repos (issue #1023 dropped #793's `tl·`
# prefix): the dash's repo headings + badge already say which repo a window is,
# and identity is `@repo`/`@issue`, never the name. The `·slug$` dedup above still
# reads a legacy `tl·issue-12` window until it closes.

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
  # run-shell -b runs in the tmux SERVER's environment, not this pane's, so any
  # pane-scoped knob the tail needs must be BAKED into the command. FLEET_SPAWN_TAIL
  # selects tail-only mode + names the fleet; FLEET_SPAWN_FOCUS is carried through
  # so "focus the new worker when ready" still works (default no-focus otherwise).
  _bg="FLEET_SPAWN_TAIL=$(shq "$SESS")"
  [ "$CLAIMED_HERE" = 1 ] && _bg="$_bg FLEET_SPAWN_CLAIMED=1"
  [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && _bg="$_bg FLEET_SPAWN_FOCUS=1"
  # >/dev/null 2>&1 on the detached tail (belt-and-suspenders for issue #401):
  # `tmux run-shell` DISPLAYS its command's stdout in an Esc-to-dismiss view, so
  # ANY stray tail stdout (the worktree add's "HEAD is now at …", a future addition)
  # would surface as a popup. Redirect the whole tail so nothing can. The tail's own
  # error reporting is unaffected — refuse() surfaces via `tmux display-message`, a
  # separate client call independent of this process's fds (its stderr copy is what
  # this redirect drops, and the tail has no caller left to read it — the
  # interactive --async path is toast-only by construction).
  _bg="$_bg exec $(shq "$SELF") $(shq "$num") --title $(shq "$title") --origin $(shq "$ORIGIN")${AGENT:+ --agent $AGENT}${REPO_ARG:+ --repo $(shq "$REPO_ARG")}${ORIGIN_WID:+ --origin-wid $(shq "$ORIGIN_WID")}${ACCOUNT_ARG:+ --account $ACCOUNT_ARG}${REAP:+ --reap $REAP} >/dev/null 2>&1"
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
  # >/dev/null: `git worktree add` prints "HEAD is now at …" to STDOUT, and under
  # --async this runs in the run-shell -b tail whose stdout tmux surfaces as an
  # Esc-to-dismiss view (issue #401). fleet_worktree_create is silent on both
  # streams itself; this discards the path it prints. --reuse: a respawn whose
  # issue-<N> branch survived checks that branch out again.
  fleet_worktree_create "$MAIN" "$slug" "$BASE" --reuse >/dev/null \
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
# 2+ repos (issue #789): the window stamps its OWN @repo/@worktree before the launcher
# runs — the launcher's fleet_load_conf is window-aware, and a set-option from here
# after new-window would race it (repo A's trust/model/MCP for a repo-B worker). A
# one-repo fleet's command string is unchanged.
stamp=''; [ "$MULTI" = 1 ] && stamp=$(fleet_win_stamp_cmd @repo "$REPO" @worktree "$wt")
# The session's account class (issue #1540) rides the same way: @account_class is on
# the window before fleet-claude.sh reads it, and it is the window's — a conf
# default changed later does not move a running session.
[ -n "$ACCOUNT" ] && stamp="$stamp$(fleet_win_stamp_cmd @account_class "$ACCOUNT")"
win=$(TM new-window ${detach[@]+"${detach[@]}"} -P -F '#{window_id}' -t "$SESS:" -n "$wname" -c "$wt" "$stamp'$BIN/fleet-session-wrap.sh'${AGENT:+ --agent $AGENT} \"\$(cat '$tf')\"; exec \$SHELL") \
  || { _why=''; fleet_socket_wedged "$SOCK" && _why=" — this fleet's tmux server is gone: its socket $(fleet_socket_path "$SOCK") is held by a dying server that drops every client (tmux says \"server exited unexpectedly\"); fleet-up.sh clears it and brings the fleet back"  # issue #1729
       refuse "spawn failed for #$num: new-window$_why"; exit "$RC_INFRA"; }
CLAIMED_HERE=0   # a window holds the issue now: its claim is the worker's
# A session is on its way: wake the idle-gated daemons so the dash is fresh on
# their very next tick, not up to FLEET_DAEMON_IDLE_AFTER later (issue #1077).
[ -f "$BIN/fleet-daemon-lib.sh" ] && ( . "$BIN/fleet-daemon-lib.sh" && fleet_daemon_wake "$BIN/.." ) 2>/dev/null || true
TM set-window-option -t "$win" @issue "$num" 2>/dev/null   # bind window ↔ issue
# The session's lifelong identity (issue #1646): minted once, here, and carried by
# every restore / migrate / move after — the address its children report to.
fleet_window_fid "$SESS" "$win" "$SOCK" >/dev/null 2>&1 || :
fleet_window_born "$SESS" "$win" "$SOCK" >/dev/null 2>&1 || :   # its place on the list (#1750)
fleet_win_role_stamp "$win" worker "$SOCK"   # what it IS, whatever it is renamed to (#1844)
# When the fleet may close it on its own (issue #1902): the one asked for, else an
# issue session's default — after its PR merged, the rule it always had.
TM set-window-option -t "$win" @reap_policy "${REAP:-merged}" 2>/dev/null
# The window's repo + worktree (issue #789) — every worker carries both, so any
# consumer resolves its repo via fleet_window_repo without a git read.
[ -n "$REPO" ] && TM set-window-option -t "$win" @repo "$REPO" 2>/dev/null
TM set-window-option -t "$win" @worktree "$wt" 2>/dev/null
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
# …and the parent's worker_id (issue #1420), the address that survives a machine
# boundary. Nothing when this machine has no fleet UUID or the origin is no key.
# A hub-placed start (issue #1425) was handed its parent's worker_id outright —
# the parent lives on another machine, so it cannot be derived from --origin.
if [ -n "$ORIGIN_WID" ]; then TM set-window-option -t "$win" @origin_wid "$ORIGIN_WID" 2>/dev/null
elif [ -n "$ORIGIN" ]; then fleet_stamp_origin_wid "$SESS" "$win" "$ORIGIN" "$SOCK"; fi
# …and the generation of that key it was spawned under (issue #1538), so a
# recycled scratch number never takes this child's report as its own. A parent on
# another machine (ORIGIN_WID) has no generation here.
[ -n "$ORIGIN" ] && [ -z "$ORIGIN_WID" ] && fleet_stamp_origin_gen "$SESS" "$win" "$ORIGIN" "$SOCK"

# (The sub-second cross-machine tie-break that re-read the ▶ claiming comment ids
# was retired with the claiming marker in issue #283 — the assignee is now the
# claim, and workers share one gh account so a per-attempt tie token no longer
# exists. Claim-at-spawn still shrinks the race window; it was never a mutex.)
# Non-invasive by default: leave the active window put — the new window and its
# list row are the confirmation, so a success draws no line (issue #1618). Only
# jump to the new worker when the user opted in (FLEET_SPAWN_FOCUS=1) on an
# interactive spawn.
if [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && [ -z "$TARGET_SESS" ]; then
  TM select-window -t "$win"
fi
