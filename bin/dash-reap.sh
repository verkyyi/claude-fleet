#!/bin/bash
# dash-reap.sh <window-target> [confirm] — reap a finished worker row from the
# dash on ONE key (⌃x, issue #289 merged the old ⌃x/⌥x pair): close its tmux
# window and remove its git worktree (when clean). The bound GitHub issue is NOT
# closed by a reap (issue #1542, from #1309/#867): a landed one is the PR's /
# worker's to close, an unlanded one stays OPEN with its claim released — see
# settle_issue().
# The gate is the SHARED fleet_reap_ok() (same guarantees as the
# worktree-autoclean.sh janitor).
#
#   ⌃x on a clean+merged row (a MERGED PR for the branch, or the tip is an
#      ancestor of base) reaps STRAIGHT AWAY — the common case, and the cleanup
#      daemon reaps those anyway, so no confirm.
#   ⌃x on anything else (dirty, or clean-but-not-merged) opens a y/n confirm
#      popup FIRST, then force-reaps — but STILL never removes a dirty worktree
#      (a dirty worktree is KEPT; only the window closes).
# The same one-key rule applies to BOTH a bound worker row (issue-<N>) and a raw
# `scratch-<N>` row (issue #290 gave scratch its own writable worktree).
#
#   Row state            ⌃x
#   clean + merged       record row, reap wt+branch+window, issue untouched (no confirm)
#   clean + NOT merged   confirm → record row, reap wt+branch+window; issue OPEN, claim released
#   dirty (any)          confirm → record row, close window, KEEP wt; issue OPEN, claim released
#   raw scratch, merged  record row, dispose wt+branch, close window (no confirm)
#   raw scratch, else    confirm → record row, dispose (dirty KEEPs the wt), close window
#   raw scratch, no wt   close window (ephemeral, pre-#290 / hermetic — nothing to record)
#   hub/panel (no issue) refuse
#
# EVERY ⌃x records a /fleet-history row before it disposes of anything (issue #471
# for a worker row, #466 for a scratch one) — ⌃x is the one path the SessionEnd hook
# can't cover (a `kill-window` is not a walk-away exit), and ledger-watch only
# notices ~60s later, by which time the worktree is gone and the row it writes has
# no sha to rebuild from. See reap_record() for the ordering rules.
#
# Operates on THIS fleet only (the dash's resolved fleet); never another fleet's
# worktree/issue. A kept dirty worktree stays on disk for later.
#
# NON-INTERACTIVE CALLERS (issue #596). `dash-reap.sh <target>` is a PUBLIC script
# interface — accepts @window-id, %pane-id, registered handle, issue-N/#N or
# scratch-N. Indexes and arbitrary names are refused (#565). Never assume a human is
# watching the fleet:
#
#   --yes | --force    skip the confirm popup and take the branch that popup would
#                      have taken — dirty → KEEP the worktree (window close
#                      only), anything else → full reap. Semantics are IDENTICAL to
#                      a confirmed ⌃x; only the question is skipped, so it opens NO
#                      new data-loss path (a dirty worktree is still never removed,
#                      and `git worktree remove` refuses one anyway). It runs
#                      SYNCHRONOUSLY, so what it reports is the outcome, not a
#                      dispatch receipt.
#   no attached client never open a popup. Without --yes, a row that needs a confirm
#                      is refused with a reason instead of drawing a y/n box onto
#                      whichever client the operator happens to be looking at — a
#                      box nobody asked for, and (with no client at all) one that
#                      nobody could ever press.
#   result token       one line on stdout + a distinct exit status, so a caller can
#                      tell what actually happened instead of reading the blanket
#                      `exit 0` this script used to answer everything with:
#                        reaped:full         0  wt + branch + window disposed
#                        reaped:keep         0  window closed, wt KEPT (dirty)
#                        skip:needs-confirm  3  needs a y/n the caller did not grant
#                        skip:live           3  active/young agent, a reap hold, or
#                                               unknown liveness (the reason is on stderr)
#                        dispatched:full     0  `--bg` only: handed to the background
#                                               tail, NOT yet done (the dash bind)
#                        failed:<slug>       5  the gate passed but the disposal did not
#                                               happen (sleep-record / kill-window)
#                        refused:<slug>      4  nothing to reap here (no-target /
#                                               no-git / no-issue / no-repo)
#                      A refusal is never 0 (issue #869: `cmd && echo ok` read a
#                      refused target as reaped). A window position (`sess:idx`) or
#                      bare name is refused:target on purpose — positions shift and
#                      names prefix-match (#565, #1537); use `issue-<N>` or `@id`.
#                      The token names the ACTION taken, not which artifacts existed:
#                      a scratch row with no worktree reports `reaped:full` because
#                      closing its window IS its full disposal.
#   --bg               the dash ⌃x bind only (issue #1244): run a clean+merged reap
#                      in the background so the bind returns instantly, and say so
#                      (`dispatched:full`). Every OTHER caller runs synchronously, so
#                      `reaped:full` always means the window is gone — before #1244 a
#                      bare `dash-reap.sh @65` backgrounded the tail, printed
#                      `reaped:full`, and the tail's own gate then refused silently.
#
# SLEEPING workers (issue #1244) are reaped WITHOUT a wake: fleet-reap-live.py passes
# a sleeper with no agent under it (no state/age gate — there is nothing to
# protect), the sleep record is retired (fleet_sleep_dispose) and the window killed.
# A reap HOLD (`fleet-sleep.py hold <@id>`) retains any worker until `release`.
#
# A worker that SHIPPED ITS OWN PR (issue #1542): the merged PR's mergedAt is
# handed to the liveness probe, which then waives the 30-minute young-agent gate
# (#1248, as the cleanup daemon already did for #1329) and a stale `looping` stamp
# (#1356) for an agent that was alive at the merge. An ACTIVE @loop mark, a
# running child or bg job still retain it (#1331 ruling A, #1370).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-ui-lang.sh"   # fleet_ui_fail — the one failure line (issue #1618)
. "$BIN/fleet-gh-lib.sh"   # merged-PR check with the REST fallback (issue #1042)

# --- script-facing result (issue #596) ----------------------------------------
# Print ONE token on stdout for the caller. The INTERACTIVE passes print UI, not
# tokens: the confirm invocation's stdout IS the prompt the operator reads,
# whether in a popup or the execute() inline fallback — emit is a no-op there.
emit() { [ "${confirm:-0}" = 1 ] || printf '%s\n' "$1"; }

# refuse <slug> <human message> — the slug is what scripts match (`refused:no-issue`),
# the message is what the operator sees on the status line. Exit 4, never 0: a
# refusal that reported success is exactly what let a caller believe it had reaped.
# A reap that WORKED draws nothing — the window going and its row leaving the list
# are the answer (issue #1618); only a refusal / failure says why, via fleet_ui_fail.
refuse() { local slug="$1"; shift; emit "refused:$slug"; fleet_ui_fail "reap: $*"; exit 4; }

# Is anyone attached to THIS fleet's tmux server? `tmux list-clients` with no -t
# lists every client on the server, and one fleet = one server (issue #159), so
# this is exactly "is an operator looking at this fleet". With none, a confirm
# popup is drawn into the void — nobody can answer it, so the reap would hang on a
# `y` that can never arrive while the caller walked away thinking it was done.
have_client() { [ -n "$(tmux list-clients -F '#{client_name}' 2>/dev/null)" ]; }

# Git ancestry cannot distinguish a finished session from a new, clean worker
# (#565). Recheck at each disposal entry, INCLUDING the delayed --exec tail,
# before reports/history/issue writes or killing anything. Explicit --yes and
# popup confirmation authorize disposal, not killing an active agent. Wait for
# done (or an empty state) and FLEET_REAP_MIN_AGE seconds (default 1800).
guard_live() {
  local why
  # MERGED_AT (issue #1542) = the branch's merged PR epoch, once known: the probe
  # then waives the young-agent (#1248) and stale `looping` (#1356) gates for an
  # agent that was alive at the merge — the worker shipped its own PR.
  if ! why=$(FLEET_REAP_MIN_AGE="${FLEET_REAP_MIN_AGE:-1800}" \
    python3 "$BIN/fleet-reap-live.py" "$target" ${MERGED_AT:+--merged-at "$MERGED_AT"} 2>/dev/null); then
    emit skip:live
    # A pending /loop (issue #1331) is not "live" in the busy sense — say what it is:
    # the window waits for its Loop to stop (stop:true / CronDelete / no renewal).
    [ "$why" = retained:loop ] && why='retained:loop — a Loop is still scheduled; it reaps once the Loop stops'
    printf 'reap: %s is live or could not be checked (%s) — leaving window and worktree alone\n' \
      "$target" "${why:-probe unavailable}" >&2
    # Also on the status line: in the backgrounded tail stderr goes nowhere, and a
    # refusal nobody can see is how #1244's "reaped" window was still standing.
    fleet_ui_fail "reap refused: $target — ${why:-probe unavailable}"
    exit 3
  fi
  case "$why" in waived:*) printf 'reap: %s %s (its PR merged during this agent'"'"'s life)\n' "$target" "$why" >&2 ;; esac
}

# Dispatch the --exec tail through the tmux server (issue #304). The tail re-runs
# the liveness gate (#565), so it must run it under the SAME knob the foreground
# did: run-shell does not inherit an inline `FLEET_REAP_MIN_AGE=…` (issue #1244),
# so a numeric override is forwarded explicitly. $1 = action, $2 = verdict (both
# fixed tokens, shell-safe to interpolate). The merge epoch rides as $3 (digits or
# empty, validated by the --exec parse) so the tail's gate waives what ours did.
bg_exec() {
  local env=""
  case "${FLEET_REAP_MIN_AGE:-}" in ''|*[!0-9]*) ;; *) env="FLEET_REAP_MIN_AGE=$FLEET_REAP_MIN_AGE " ;; esac
  fleet_bg "${env}bash '$BIN/dash-reap.sh' '$target' --exec $1 '$2' '${MERGED_AT:-}'"
}

# stderr keeps the public one-token stdout protocol intact. Quote free text so
# spaces/newlines in a name or path cannot fabricate another diagnostic line.
describe_target() {
  local state name issue
  state=$(tmux display-message -p -t "$target" '#{@claude_state}' 2>/dev/null)
  name=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null)
  issue=$(tmux display-message -p -t "$target" '#{@issue}' 2>/dev/null)
  printf 'reap target: window=%s name=%q issue=%q state=%q worktree=%q reason=%s\n' \
    "$target" "$name" "${issue:--}" "${state:--}" "${2:--}" "$1" >&2
}

# Settle the bound issue (issue #1542). A reap disposes of a WINDOW and a
# WORKTREE; whether the issue is done is not its call:
#   landed (merged-pr | ancestor) → untouched. A merged PR's `Closes #N` already
#       closed it; one still OPEN is a worker that said "keep open until the
#       read-back" (#1309), and the cleanup daemon never closed issues either.
#   not landed (unmerged | dirty) → stays OPEN, the claim is released and one
#       no-relay note says what happened. Closing it read as CLOSED/COMPLETED — a
#       false "done" the EPIC report counts (#867), worst for a worker that
#       never started (zero commits of its own: tip == base).
#   no verdict (a pre-#471 dispatch in flight) → untouched: never guess.
settle_issue() {
  command -v gh >/dev/null 2>&1 || return 0
  case "${reason:-}" in unmerged|dirty) ;; *) return 0 ;; esac
  local st; st="$(gh -R "$REPO" issue view "$iss" --json state -q .state 2>/dev/null)"
  [ "$st" = OPEN ] || return 0
  local what="its work did not land" base n
  if [ -n "${whead:-}" ] && [ -n "${MAIN:-}" ]; then
    base="$(git -C "$MAIN" rev-parse --verify -q "origin/${FLEET_BASE_BRANCH:-main}" 2>/dev/null \
      || git -C "$MAIN" rev-parse --verify -q "${FLEET_BASE_BRANCH:-main}" 2>/dev/null)"
    n="$(git -C "$MAIN" rev-list --count "$base..$whead" 2>/dev/null)"
    [ -n "$base" ] && [ "$n" = 0 ] && what="it never started (no commits of its own)"
  fi
  [ "$reason" = dirty ] && what="$what; its dirty worktree is kept"
  gh -R "$REPO" issue edit "$iss" --remove-assignee @me >/dev/null 2>&1 || true
  gh -R "$REPO" issue comment "$iss" --body "Reaped from the fleet: window closed — $what. The issue stays OPEN and the claim is released, so it can be picked up again.

<!-- fleet:no-relay -->" >/dev/null 2>&1 || true
}

# RECORD this reap into the /fleet-history ledger (issue #471). ⌃x used to be the
# one reaper that wrote nothing — see the header note — so a ⌃x'd worker was only
# indexed later, worktree-less and therefore unresumable.
#
# ORDERING, both halves load-bearing: called AFTER the kill-window (so #313's
# instant row-vanish is untouched — the dash summary-cache FILE outlives the window,
# so the summary column still resolves) and BEFORE any `git worktree remove` (#384 —
# the row's transcript dir is derived from the worktree PATH, and its rebuild sha is
# read out of the worktree itself).
#
# $reason is the verdict the INTERACTIVE pass already decided, threaded in through
# the --exec dispatch. It is deliberately NOT re-derived here: a second
# fleet_reap_ok can disagree with what the operator just confirmed (a merge landing
# in between; the worktree turning dirty) and would record a verdict nobody agreed
# to — besides re-paying the `gh pr list` #304 moved off the bind. Empty (an
# in-flight pre-#471 dispatch string) → the helper no-ops, i.e. exactly the old
# behavior, never an invented row. Idempotent, so racing the cleanup daemon /
# ledger-watch still yields ONE row.
#
# Caveat, deliberate: on a FORCE-reaped `unmerged` row the recorded sha is neither
# in base nor on a surviving branch, so `resume` can rebuild it only until git gc
# prunes that unreachable object (~2 weeks by default). Strictly better than the
# no-sha row ledger-watch used to leave, and the degrade path is already handled
# (worktree add fails → REVIEW-ONLY).
reap_record() {
  # ${wname:-} = the window name, read alongside $wid BEFORE reap_* kills the
  # window — it becomes the row's fallback title (⌃e renames included), so a
  # ⌃x-recorded closed-unlanded row isn't "(untitled)". On the landed path gh's
  # PR title still wins inside fleet-history.
  fleet_reap_record "${reason:-}" "$REPO" "$MAIN" "$iss" "$wtdir" "${wid:-}" \
    "${FLEET_SESSION:-}" "" "$branch" "${wname:-}" "${worigin:-}"
}

# Close the window, truthfully (issue #1244): retire a sleeper's record first (a
# refusal leaves everything standing), then kill, then CHECK it is gone. Exits 5
# with a failed:<slug> token instead of letting a caller read success.
reap_kill() {
  if ! fleet_sleep_dispose "$target" "${FLEET_SESSION:-}"; then
    emit failed:sleep-record
    fleet_ui_fail "reap failed: $target — sleep record could not be retired"
    exit 5
  fi
  tmux kill-window -t "$target" 2>/dev/null || true
  if tmux display-message -p -t "$target" '#{window_id}' 2>/dev/null | grep -qxF "$target"; then
    emit failed:kill-window
    fleet_ui_fail "reap failed: $target — window still open"
    exit 5
  fi
}

# full reap: remove worktree + delete branch, settle issue, kill window
reap_full() {
  guard_live
  # Kill the window FIRST (issue #313): the dash row is driven live by
  # `tmux list-windows`, so dropping the window here makes the reaped row vanish
  # on the very next repaint instead of lingering behind the slow tail below (the
  # network `gh issue` settle + `git worktree remove`). This whole function already
  # runs backgrounded (fleet_bg / run-shell -b, #304), so it never blocks the bind.
  reap_kill
  reap_record                                          # index it BEFORE the remove (#471)
  if [ -n "$wtdir" ] && [ -n "$MAIN" ]; then
    # Reap any detached process anchored to this worktree first (issue #151) — a
    # since-fixed hang left spinning would otherwise outlive the dir and drain a
    # core against the shared tmux server. (Also releases the just-killed pane's
    # shell if it was cwd'd in the worktree, so the remove below isn't blocked.)
    fleet_reap_worktree_procs "$wtdir" >/dev/null 2>&1
    # plain remove (no --force): git itself refuses a dirty worktree, so even a
    # TOCTOU race after the fleet_reap_ok check cannot delete uncommitted work.
    git -C "$MAIN" worktree remove "$wtdir" 2>/dev/null \
      && git -C "$MAIN" branch -D "$branch" >/dev/null 2>&1
    git -C "$MAIN" worktree prune 2>/dev/null || true
  fi
  settle_issue
}

# dirty force reap: KEEP the worktree, settle issue + kill window only
reap_keep() {
  guard_live
  reap_kill                                            # drop the row first (#313)
  reap_record                                          # the KEPT worktree is resumable (#471)
  # kept tree, but its detached LISTENERS go now — a `*` bind serves it to the LAN (#1154)
  [ -n "${wtdir:-}" ] && fleet_reap_worktree_listeners "$wtdir" >/dev/null 2>&1
  settle_issue
  printf 'reap: #%s window closed — worktree kept (dirty)\n' "$iss" >&2
}

# The disposal tail shared by the backgrounded --exec pass and the synchronous
# --yes path (issue #596). Reads the window metadata the ledger row needs WHILE THE
# WINDOW STILL STANDS (reap_* kills it), pushes the child-report backstop, then acts
# by verdict. $1 = the ACTION (full|keep); $reason = the gate verdict for the row.
reap_dispatch() {
  guard_live
  describe_target "${reason:-unknown}" "${wtdir:-}"
  # Window id + NAME for the ledger row — read BEFORE reap_* kills the window
  # (the summary cache FILE the id keys survives; neither would be resolvable
  # afterwards). Empty is tolerated: the row just records no summary / no title.
  wid="$(tmux display-message -t "$target" -p '#{window_id}' 2>/dev/null)"
  wname="$(tmux display-message -t "$target" -p '#{window_name}' 2>/dev/null)"
  worigin="$(tmux display-message -t "$target" -p '#{@origin}' 2>/dev/null)"   # provenance (#503), read pre-kill
  # Child-report BACKSTOP (issue #574): push the outcome to the session that
  # spawned this one before reap_* kills the window. --only-once because the ship
  # path already reported (and stamped @reported) for anything that landed on its
  # own — this covers the ⌃x on a worker that never got there. A missing parent is
  # a silent exit 0 inside the script, so it can never block the reap.
  bash "$BIN/fleet-report-parent.sh" --win "$target" --only-once \
    --state reaped --verdict "$1" --origin "$worigin" --issue "$iss" \
    >/dev/null 2>&1 || :
  case "$1" in keep) reap_keep ;; *) reap_full ;; esac
}

# --- parse args ---------------------------------------------------------------
confirm=0; yes=0; bg=0; MERGED_AT=""
target="${1:-}"
# Nothing to act on (an empty {1} from a dash with no rows) — still answer the
# caller with a token rather than a bare success, but stay silent on the status
# line: a ⌃x on an empty dash should not nag.
[ -z "$target" ] && { emit "refused:no-target"; exit 4; }
# The column header and #974's repo group headings carry `hdr` in both key fields:
# not a window, so ⌃x on one is the same quiet refusal as an empty dash.
[ "$target" = hdr ] && { emit "refused:no-target"; exit 4; }
# Validate the complete invocation before resolving anything: a second target
# must never be silently ignored. --exec is the existing private background tail.
shift || true
if [ "${1:-}" = --exec ]; then
  [ "$#" -ge 2 ] && [ "$#" -le 4 ] || refuse bad-args "--exec needs one action, optional verdict and merge epoch"
  case "$2" in full|keep) ;; *) refuse bad-args "invalid reap action" ;; esac
  case "${3:-}" in ''|merged-pr|ancestor|unmerged|dirty) ;; *) refuse bad-args "invalid reap verdict" ;; esac
  case "${4:-}" in *[!0-9]*) refuse bad-args "invalid merge epoch" ;; esac
else
  for a in "$@"; do case "$a" in
    confirm) confirm=1 ;;
    --yes|--force) yes=1 ;;
    --bg) bg=1 ;;
    *) refuse bad-args "one target only; unexpected argument: $a" ;;
  esac; done
fi
# --- a worker on ANOTHER machine (issue #1589) --------------------------------
# With the hub on, a KEY no window here holds may live on another machine of this
# fleet (fleet_worker_locate: the hub's worker map). Its window is not on this
# server, so nothing here can reap it — the hub's worker_reap asks that machine's
# node to run THIS script there (`dash-reap.sh <key> --yes`, its own gate, its own
# history row) and fleet_hub_reap answers with its token, reason and exit status,
# exactly as a local reap would. The hub's reap is the CONFIRMED one (--yes: a
# dirty worktree is kept), so without --yes it is skip:needs-confirm — the answer
# a local row needing a y/n gives a caller who did not grant one. Hub off, or a
# key that is live here: nothing below runs. FLEET_REAP_LOCAL=1 (set by the
# node's own adapter) keeps a reap from bouncing back to the hub.
if [ "${FLEET_REAP_LOCAL:-0}" != 1 ] && [ "$confirm" = 0 ]; then
  case "$target" in
    wid:*|*/*|issue-*|scratch-*|*:issue-*|*:scratch-*)
      if fleet_hub_on "$(fleet_current_session 2>/dev/null)"; then
        loc_t=$target
        case "$target" in wid:*|*/*|issue-*|scratch-*) ;; *) loc_t="wid:$target" ;; esac
        # fleet_hub_on read the fleet's own conf line (#1539); the map readers
        # read the environment, so hand them the answer.
        loc=$(CCQUOTA_FLEET=1 fleet_worker_locate "$loc_t" 2>/dev/null)
        case "$loc" in
          remote\ *)
            node=${loc#remote }
            hwid=''
            sp=$(_fleet_wid_split "$loc_t") && hwid=$(CCQUOTA_FLEET=1 fleet_hub_wid "${sp%%$'\t'*}" "${sp#*$'\t'}")
            if [ -z "$hwid" ]; then
              emit refused:no-target
              printf 'reap: %s is on %s, but the hub map names no single worker for it\n' "$target" "$node" >&2
              exit 4
            fi
            if [ "$yes" != 1 ]; then
              emit skip:needs-confirm
              printf 'reap: %s lives on %s — a reap there is the confirmed one; re-run with --yes\n' "$target" "$node" >&2
              exit 3
            fi
            printf 'reap: %s lives on %s — reaping it there through the hub\n' "$target" "$node" >&2
            fleet_hub_reap "$hwid" "${FLEET_REAP_HUB_WAIT:-90}"
            exit $?
            ;;
        esac
      fi
      ;;
  esac
fi

# Unlike the general fleet_wid_target helper, this destructive entry never falls
# back from an unresolved handle to a window name. Pin a unique identity now;
# popup and delayed tail invocations carry only the resolved @id.
target=$(python3 "$BIN/fleet-reap-target.py" "$target") \
  || refuse target "target rejected; use a stable @id or explicit issue/scratch key"
case "$target" in @*) ;; *) refuse target "invalid window id" ;; esac
case "${target#@}" in ''|*[!0-9]*) refuse target "invalid window id" ;; esac

command -v git >/dev/null 2>&1 || refuse no-git "git not found"

# --- internal --exec <full|keep> [<gate-verdict>] (issue #304): the BACKGROUND reap
# the interactive path dispatches (via fleet_bg) ONCE the merged-check decision is
# made. Re-resolve only the CHEAP locals reap_full/reap_keep need — NO `gh pr list`
# (the decision is already made) — then run the slow tail (git worktree remove + gh
# issue settle) off the interactive ⌃x bind so it returned instantly. $TMUX is
# inherited from the run-shell job, so the bare tmux/gh calls below stay on THIS
# fleet's server.
#
# $3 carries the GATE verdict (merged-pr|ancestor|unmerged|dirty) the interactive
# pass already computed — the one thing this pass cannot cheaply re-derive and the
# one thing the ledger row needs (issue #471). $2 stays the ACTION (full|keep).
if [ "${1:-}" = "--exec" ]; then
  verdict="${2:-}"; reason="${3:-}"; MERGED_AT="${4:-}"
  iss="$(tmux display-message -t "$target" -p '#{@issue}' 2>/dev/null)"; iss="${iss//[^0-9]/}"
  [ -z "$iss" ] && exit 0
  FLEET_SESSION="$(fleet_current_session)"; export FLEET_SESSION
  # The TARGET window's repo, not the dash's (issue #791). Unknown → nothing
  # resolves, so no worktree is touched; the window still closes.
  fleet_load_window_conf "$FLEET_SESSION" "$target" || :
  guard_live
  REPO="$(fleet_resolved_repo "$FLEET_SESSION")"
  MAIN="${FLEET_MAIN:-}"; [ -n "$MAIN" ] && [ ! -d "$MAIN/.git" ] && MAIN=""
  branch="issue-$iss"
  wtdir=""; whead=""
  [ -n "$MAIN" ] && IFS=$'\t' read -r wtdir whead < <(fleet_worktree_head "$MAIN" "$branch")
  reap_dispatch "$verdict"
  exit 0
fi

# --- raw scratch row: close the window + dispose its worktree by the gate ------
# A raw/scratch session (@raw=1) has NO @issue, but since issue #290 it DOES own a
# `scratch-<N>` git worktree off the base branch. So ⌃x closes the window AND
# applies the SAME one-key rule the issue-bound path below uses: a clean+merged
# scratch worktree is disposed straight away; a dirty/unmerged one is disposed
# only after a y/n confirm (and a dirty worktree is still KEPT — never silently
# delete an experiment). With no resolvable worktree (a pre-#290 scratch, or a
# hermetic test) it degrades to the historic "just close the window" behavior.
# Detected BEFORE the hub/panel guard so a scratch stops looking like a no-op ⌃x;
# true hub/panel rows (plan/dash/backlog — no @issue AND no @raw) still fall
# through to the "nothing to reap" refuse below.
if [ "$(tmux display-message -t "$target" -p '#{@raw}' 2>/dev/null)" = 1 ]; then
  # Resolve this fleet's checkout + the scratch worktree. @worktree is written at
  # spawn (dash-raw-session.sh); fall back to the window's cwd. Only ever act on a
  # `scratch-<N>` branch under this fleet's MAIN — anything else degrades to a plain
  # window-close, so a stray cwd can never make ⌃x delete unrelated work.
  FLEET_SESSION="$(fleet_current_session)"; export FLEET_SESSION
  # The scratch's OWN repo (issue #791). A no-repo (@norepo) or unknown-repo
  # scratch resolves no MAIN, so it degrades to the plain window-close below —
  # the operator's explicit reap still closes it, with no worktree to drop.
  fleet_load_window_conf "$FLEET_SESSION" "$target" || :
  guard_live
  MAIN="${FLEET_MAIN:-}"; [ -n "$MAIN" ] && [ ! -d "$MAIN/.git" ] && MAIN=""
  swt="$(tmux display-message -t "$target" -p '#{@worktree}' 2>/dev/null)"
  [ -z "$swt" ] && swt="$(tmux display-message -t "$target" -p '#{pane_current_path}' 2>/dev/null)"
  sbranch=""; shead=""
  if [ -n "$swt" ] && [ -n "$MAIN" ] && [ -e "$swt" ] \
     && git -C "$swt" rev-parse --git-dir >/dev/null 2>&1; then
    sbranch="$(git -C "$swt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    shead="$(git -C "$swt" rev-parse HEAD 2>/dev/null)"
  fi
  case "$sbranch" in scratch-*) ;; *) sbranch="" ;; esac   # scratch-only guard

  # No resolvable scratch worktree → historic behavior: just close the window.
  # No confirm was ever involved here, so --yes changes nothing; closing the window
  # IS this row's full disposal, hence `reaped:full` (#596).
  if [ -z "$sbranch" ]; then
    guard_live
    describe_target ephemeral "$swt"
    tmux kill-window -t "$target" 2>/dev/null || true
    emit reaped:full
    exit 0
  fi

  # Gate the worktree the same way the issue-bound path does. No blocking fetch on
  # the interactive ⌃x path — use the locally-known origin/<base>.
  SBASE="${FLEET_BASE_BRANCH:-master}"
  SMASTER="$(git -C "$MAIN" rev-parse --verify -q "origin/$SBASE" 2>/dev/null \
    || git -C "$MAIN" rev-parse --verify -q "$SBASE" 2>/dev/null)"
  SMERGED=""
  command -v gh >/dev/null 2>&1 && SMERGED="$(fleet_gh_merged_heads "${FLEET_REPO:-}" "$sbranch" 2>/dev/null)"
  sreason="$(fleet_reap_ok "$swt" "$MAIN" "$sbranch" "$shead" "$SMASTER" "$SMERGED")"
  [ "$sreason" != live ] || { emit skip:live; printf 'reap: another live window uses this worktree\n' >&2; exit 3; }

  scratch_remove() {   # remove worktree + branch (reap anchored procs first, #151)
    fleet_reap_worktree_procs "$swt" >/dev/null 2>&1
    git -C "$MAIN" worktree remove "$swt" 2>/dev/null \
      && git -C "$MAIN" branch -D "$sbranch" >/dev/null 2>&1
    git -C "$MAIN" worktree prune 2>/dev/null || true
  }

  # RECORD the /fleet-history row BEFORE any removal (issue #466). Both halves of a
  # resumable row come from the worktree while it still stands: the transcript dir is
  # derived from its PATH, and the HEAD sha is what lets `resume` rebuild it after
  # this ⌃x deletes it. Reap-then-record would strand the scratch's transcript —
  # indexed ~60s later by ledger-watch, but with no sha, i.e. REVIEW-ONLY forever.
  # The shared helper keys the row by the scratch branch (no issue) and dedups, so a
  # confirm-popup re-invocation records once. Deliberately NOT called on the cancel
  # path: a scratch whose window survives ⌃x is not a closed session.
  # The window NAME rides along as the row's title (10th arg) — it's the one
  # human-readable identity a scratch has (⌃e renames land here too), and without
  # it a ⌃x-disposed scratch rendered as the bare `scratch-<N>` fallback while the
  # SessionEnd/ledger-watch paths already record the name. Read it NOW: the window
  # is still alive at every scratch_record call site (killed after).
  wid="$(tmux display-message -t "$target" -p '#{window_id}' 2>/dev/null)"
  swname="$(tmux display-message -t "$target" -p '#{window_name}' 2>/dev/null)"
  sworigin="$(tmux display-message -t "$target" -p '#{@origin}' 2>/dev/null)"   # provenance (#503), read pre-kill
  scratch_record() {
    fleet_reap_record "$sreason" "${FLEET_REPO:-}" "$MAIN" "" \
      "$swt" "$wid" "$FLEET_SESSION" "" "$sbranch" "$swname" "$sworigin"
    # Child-report BACKSTOP (issue #574), in the same "while the window still
    # stands" slot as the record — every path that closes this scratch calls
    # scratch_record first, and only those paths. --only-once: a scratch that
    # already reported its own outcome does not report again.
    bash "$BIN/fleet-report-parent.sh" --win "$target" --only-once \
      --state reaped --verdict "$sreason" --origin "$sworigin" --key "$sbranch" \
      >/dev/null 2>&1 || :
  }

  # The disposal tail, shared by the no-confirm path, the confirm popup and the
  # non-interactive --yes (issue #596) so all three stay one behavior: record first
  # (#466), KEEP a dirty worktree, close the window last. Echoes its result token.
  scratch_dispose() {
    guard_live
    describe_target "$sreason" "$swt"
    scratch_record
    guard_live
    [ "$sreason" = dirty ] || scratch_remove
    tmux kill-window -t "$target" 2>/dev/null || true
    if [ "$sreason" = dirty ]; then
      printf 'reap: scratch closed — worktree kept (dirty)\n' >&2
      emit reaped:keep
    else
      emit reaped:full
    fi
  }

  describe_target "$sreason" "$swt"

  # ⌃x (issue #289): a clean+merged scratch disposes straight away; a
  # dirty/unmerged one opens a y/n confirm popup FIRST (a dirty worktree stays
  # KEPT). The initial keypress (no `confirm` arg) decides which.
  if [ "$confirm" = 0 ]; then
    case "$sreason" in
      merged-pr|ancestor)
        scratch_dispose ;;
      *)   # dirty | unmerged — confirm before disposing / closing
        # --yes takes the confirm branch unasked (#596); with no client attached a
        # popup would be unanswerable, so refuse and say how to authorize it.
        if [ "$yes" = 1 ]; then
          scratch_dispose
        elif have_client; then
          bash "$BIN/dash-popup.sh" --size S -h 9 --title popup_reap --object "$target" -- \
            bash "$BIN/dash-reap.sh" "$target" confirm || true
          emit skip:needs-confirm
          exit 3
        else
          emit skip:needs-confirm
          printf 'reap: %s is %s — needs a y/n confirm and no client is attached; pass --yes to dispose non-interactively\n' \
            "$sbranch" "$sreason" >&2
          exit 3
        fi ;;
    esac
    exit 0
  fi

  # running inside the confirm popup. A DIRTY worktree is still KEPT (git refuses a
  # dirty remove anyway) — only the window closes.
  if [ "$sreason" = dirty ]; then
    msg="Dispose $sbranch? Worktree is DIRTY — it will be KEPT; window closes."
  else
    msg="Dispose $sbranch? Removes the scratch worktree + branch, closes the window."
  fi
  printf '\n  %s\n\n  [y] reap    [n] cancel ' "$msg"
  read -rsn1 ans; echo
  case "$ans" in y|Y) ;; *) exit 0;; esac
  scratch_dispose
  exit 0
fi

# --- resolve the row: bound issue, repo, branch, worktree, base ---------------
iss="$(tmux display-message -t "$target" -p '#{@issue}' 2>/dev/null)"
iss="${iss//[^0-9]/}"
[ -z "$iss" ] && refuse no-issue "no issue on this row (hub/panel) — nothing to reap"

FLEET_SESSION="$(fleet_current_session)"; export FLEET_SESSION
# Overlay THIS fleet's per-session conf so FLEET_MAIN/FLEET_BASE_BRANCH/FLEET_REPO
# target the reaped row's fleet, not the global default (a secondary fleet has its
# own checkout) — same as dash-issue-session.sh / dash-new-session.sh. In a
# multi-repo fleet, the reaped WINDOW's repo overlay on top (issue #791): its MAIN,
# its branch, its PRs — never the conf repo's same-numbered issue.
fleet_load_window_conf "$FLEET_SESSION" "$target" \
  || refuse no-repo "cannot tell which repo #$iss belongs to — not reaping"
REPO="$(fleet_resolved_repo "$FLEET_SESSION")"
[ -z "$REPO" ] && refuse no-repo "no repo resolved — cannot reap #$iss"
branch="issue-$iss"

# merged PRs for this branch (a --head filter keeps it to one branch), each with
# its mergedAt. GraphQL rate-limited → REST `pulls?state=closed&head=` (issue
# #1042): under the limit this read came back empty and a MERGED PR reaped as
# `unmerged`. Read BEFORE the first liveness gate (issue #1542): the merge time is
# what lets the gate tell a worker that shipped its own PR — young (#1248) or
# still stamped `looping` (#1356) — from one that is genuinely still working.
MERGED_PRS=""; MERGED_AT=""
if command -v gh >/dev/null 2>&1; then
  while IFS=$'\t' read -r mref miso; do
    [ "$mref" = "$branch" ] || continue
    MERGED_PRS="$mref"
    mep="$(fleet_epoch_from_iso "$miso")"
    case "$mep" in ''|*[!0-9]*) ;; *) [ "$mep" -gt "${MERGED_AT:-0}" ] && MERGED_AT="$mep" ;; esac
  done < <(fleet_gh_merged_heads "$REPO" "$branch" --at 2>/dev/null)
fi
guard_live

MAIN="${FLEET_MAIN:-}"
[ -n "$MAIN" ] && [ ! -d "$MAIN/.git" ] && MAIN=""

# worktree dir + HEAD for this branch (branch→worktree is authoritative).
wtdir=""; whead=""
[ -n "$MAIN" ] && IFS=$'\t' read -r wtdir whead < <(fleet_worktree_head "$MAIN" "$branch")

# base ref for the ancestor test. No blocking `git fetch` on the interactive ⌃x
# path — use the locally-known origin/<base> (kept fresh by the fleet's normal
# fetches); a merged-but-not-locally-visible branch is still caught by the gh
# merged-PR check below, and a stale-negative only makes the SAFE path refuse
# (no data loss). BASE from FLEET_BASE_BRANCH default matches fleet-lib's 'main'.
BASE="${FLEET_BASE_BRANCH:-main}"; MASTER=""
if [ -n "$MAIN" ]; then
  MASTER="$(git -C "$MAIN" rev-parse --verify -q "origin/$BASE" 2>/dev/null \
    || git -C "$MAIN" rev-parse --verify -q "$BASE" 2>/dev/null)"
fi

reason="$(fleet_reap_ok "$wtdir" "$MAIN" "$branch" "$whead" "$MASTER" "$MERGED_PRS" "$MERGED_AT")"
[ "$reason" != live ] || { emit skip:live; printf 'reap: another live window uses this worktree\n' >&2; exit 3; }
describe_target "$reason" "$wtdir"

# --- ⌃x (issue #289): clean+merged reaps straight away; anything else confirms -
# first, then force-reaps. The initial keypress (no `confirm` arg) decides which:
#   merged-pr | ancestor → reap_full now (the cleanup daemon reaps these anyway);
#   dirty | unmerged     → open a y/n confirm popup that re-invokes us `confirm`.
if [ "$confirm" = 0 ]; then
  case "$reason" in
    dirty|unmerged)
      # --yes (issue #596): take the branch the confirm popup would have taken —
      # dirty KEEPs the worktree, unmerged force-reaps — without asking. Run it
      # SYNCHRONOUSLY rather than through fleet_bg: the whole point is that the
      # caller's exit is the outcome, not a dispatch receipt.
      if [ "$yes" = 1 ]; then
        if [ "$reason" = dirty ]; then reap_dispatch keep; emit reaped:keep
        else                           reap_dispatch full; emit reaped:full; fi
        exit 0
      fi
      # No attached client → never draw a confirm nobody can answer (#596): the
      # caller would read the old `exit 0` as done while the row sat there forever.
      if ! have_client; then
        emit skip:needs-confirm
        printf 'reap: #%s is %s — needs a y/n confirm and no client is attached; pass --yes to reap non-interactively\n' \
          "$iss" "$reason" >&2
        exit 3
      fi
      bash "$BIN/dash-popup.sh" --size S -h 9 --title popup_reap --object "$target" -- \
        bash "$BIN/dash-reap.sh" "$target" confirm || true
      # The popup is a SEPARATE invocation; this pass reaped nothing (#596).
      emit skip:needs-confirm
      exit 3 ;;
    # merged-pr | ancestor — clean+merged, no confirm. Background the reap (issue
    # #304): the slow git worktree remove + gh issue settle run off the ⌃x bind, which
    # returns instantly; the row clears when the bg kill-window lands + the dash
    # refreshes.
    # The verdict rides along so the bg pass can record the right row kind (#471);
    # it is a fixed token from fleet_reap_ok, so it is shell-safe to interpolate.
    # Only the dash bind asks for that (`--bg`, issue #1244) and it is told
    # `dispatched:full`; every other caller runs the disposal in the foreground,
    # so `reaped:full` means DONE rather than "dispatched" (#596).
    *)  if [ "$bg" = 1 ] && [ "$yes" = 0 ]; then
          bg_exec full "$reason"; emit dispatched:full; exit 0
        fi
        reap_dispatch full
        emit reaped:full; exit 0 ;;
  esac
fi

# running inside the confirm popup
if [ "$reason" = dirty ]; then
  msg="Force-reap #$iss? Worktree is DIRTY — it will be KEPT; window closes. Issue stays open, claim released."
else
  msg="Force-reap #$iss? Removes worktree + branch, closes the window. Issue stays open, claim released."
fi
printf '\n  %s\n\n  [y] reap    [n] cancel ' "$msg"
read -rsn1 ans; echo
case "$ans" in y|Y) ;; *) exit 0;; esac

# Background the confirmed reap too (issue #304) so the popup closes INSTANTLY
# instead of blocking on the git remove + gh close.
if [ "$reason" = dirty ]; then bg_exec keep "$reason"
else bg_exec full "$reason"; fi
exit 0
