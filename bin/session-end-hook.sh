#!/bin/bash
# session-end-hook.sh — the SessionEnd Claude Code hook (issue #403).
#
# Runs under BASH (wired `bash …` in settings-hooks.json, NOT `sh`): it sources
# fleet-lib.sh, which uses process substitution `< <(…)` that bash-as-/bin/sh
# (macOS posix mode) rejects at parse time — every fleet-lib-sourcing script in the
# tree is likewise `#!/bin/bash`. The `sh`-wired hooks (set-claude-state, summarize)
# deliberately do NOT source fleet-lib.
#
# When an operator MANUALLY exits a worker (Ctrl-D / `/exit`, or logout), react AT
# EXIT instead of waiting for the polling daemons:
#   1. CLOSE THE TMUX WINDOW — no leftover shell to exit by hand.
#   2. APPLY THE SHARED REAP GATE (fleet_reap_ok) and act on the worktree by verdict.
#   3. RECORD THE /fleet-history ROW NOW (idempotent) — the session is indexed +
#      resumable the instant it ends, not ~60s later when ledger-watch's snapshot-diff
#      notices the window vanished.
# This is the event-driven complement to #320 (which records vanished workers by
# polling); it reuses the SAME shared reap primitives (fleet_reap_ok /
# fleet_reap_record / fleet_reap_worktree_procs) so it never diverges from the other
# reapers (dash-reap.sh, worktree-autoclean.sh, fleet-cleanup.sh).
#
# Decision table (the crux: committed ≠ merged) — verdict from the shared gate:
#   merged-pr  reap: record landed         → remove wt+branch → close issue → close window
#   ancestor   reap: record closed-unlanded→ remove wt+branch →               close window
#   unmerged   keep: record closed-unlanded, keep wt + issue,                 close window
#   dirty      keep: record closed-unlanded, keep wt (git refuses --forceless),close window
# Only a merged PR / ancestor-of-base is reaped; committed-but-unmerged and dirty
# work is KEPT for resume. Equivalent to auto-firing the dash ⌃x one-key rule on exit.
# NB (matches #403's table, not the other reapers): only a MERGED PR closes the issue;
# a bare ancestor-of-base has no landed work, so its issue is kept OPEN for re-pickup.
#
# reason gate (only a GENUINE walk-away acts): prompt_input_exit | logout act; clear
# (`/clear`, and every `/fleet-handoff` cycle), resume, bypass_permissions_disabled,
# other are NO-OPs — skipping clear/resume is what prevents a spurious closed row +
# window-kill on every handoff cycle (the same reason ledger-watch keys on issue, not
# session-id). settings-hooks.json's matcher pre-filters to prompt_input_exit|logout;
# the in-script check below is defense-in-depth.
#
# Constraints (Claude Code SessionEnd — confirmed against the hooks reference):
#   • Can't block — fine; we react, not veto (SessionEnd is side-effects-only).
#   • Runs INSIDE the dying pane — so the gate + reap + close run in a DETACHED
#     --exec job via `tmux run-shell -b` (server-side): it survives the pane vanishing
#     and can remove the very cwd it stood in (mirrors dash-reap.sh's --exec pattern +
#     fleet-cleanup.sh's detach-when-caller-is-inside-worktree logic).
#   • Dirty is never deleted — plain `git worktree remove` (no --force) refuses it.
#   • Idempotent — fleet_reap_record + `gh issue close` dedup, so racing the cleanup
#     daemon / ledger-watch yields one row and one close.
#   • Scoped — only a numeric @issue worker (or @raw scratch → window-close only);
#     panels (dash/plan/backlog) carry no @issue/@raw and the steward hub is bailed on
#     defensively (@steward), so neither is ever touched.
#   • Opt-in per fleet: FLEET_CLOSE_ON_EXIT=1 (default off), matching the fleet-knob
#     idiom (FLEET_CLEANUP, FLEET_LEDGER_WATCH, FLEET_AUTO_HANDOFF_PCT).
#
# Testable seam: FLEET_SESSION_END_REASON overrides the stdin reason (the selftest
# has no real hook payload). Always exits 0 — SessionEnd cannot block.
set -u

BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

TAB=$(printf '\t')
strip_num() { printf '%s' "${1:-}" | tr -cd '0-9'; }

# ============================================================================
# --exec MODE — the DETACHED, server-side reap the in-pane gate dispatches via
# `tmux run-shell -b`. It runs in the tmux server (not the dying pane), so it
# outlives the pane and can remove the very cwd the pane stood in. Everything it
# needs is passed as ARGS (the window may already be gone — it can't re-read it):
#   --exec <kind> <session> <window-id> <issue|->
#     kind = worker → gate-reap the issue-<N> worktree by verdict, then close window
#     kind = raw    → close the scratch window only (+ drop its dash summary seed)
# $TMUX is inherited from the run-shell job, so bare tmux/gh stay on THIS fleet's
# server/socket. Re-resolves conf from <session> — the server env carries no FLEET_*.
# ============================================================================
if [ "${1:-}" = "--exec" ]; then
  kind="${2:-}"; sess="${3:-}"; win="${4:-}"; iss=$(strip_num "${5:-}")

  # raw scratch → close the window ONLY (issue #403 scopes SessionEnd to a
  # window-close for @raw; a scratch worktree, if any, is left to the dash ⌃x /
  # worktree-autoclean). Drop the dash summary-cache seed so no stale row lingers.
  if [ "$kind" = raw ]; then
    [ -n "$sess" ] && [ -n "$win" ] && \
      rm -f "$(fleet_cache_global)/summary_$(fleet_summary_key "$sess" "$win")" 2>/dev/null
    [ -n "$win" ] && tmux kill-window -t "$win" 2>/dev/null
    exit 0
  fi

  # worker → resolve this fleet's checkout + the issue-<N> worktree, gate, record,
  # act by verdict (mirrors dash-reap.sh's --exec + reap_full/reap_keep).
  [ -n "$iss" ] || { [ -n "$win" ] && tmux kill-window -t "$win" 2>/dev/null; exit 0; }
  FLEET_SESSION="$sess"; export FLEET_SESSION
  fleet_load_conf "$sess"
  REPO="${FLEET_REPO:-}"
  _r=$(fleet_repo_cached "$sess"); [ -n "$_r" ] && REPO="$_r"
  MAIN="${FLEET_MAIN:-}"; [ -n "$MAIN" ] && [ ! -d "$MAIN/.git" ] && MAIN=""
  BASE="${FLEET_BASE_BRANCH:-master}"
  branch="issue-$iss"

  # worktree dir + HEAD for this branch (branch→worktree is authoritative). Capture
  # the tab-joined "<dir>\t<sha>" to a var and split — no `< <()` in our own code.
  wtdir=""; whead=""
  if [ -n "$MAIN" ]; then
    wl=$(fleet_worktree_head "$MAIN" "$branch")
    case "$wl" in *"$TAB"*) wtdir=${wl%%"$TAB"*}; whead=${wl#*"$TAB"} ;; esac
  fi

  # base ref for the ancestor test — locally-known origin/<base> (no blocking fetch;
  # a merged-but-not-local branch is still caught by the gh merged-PR check below).
  MASTER=""
  [ -n "$MAIN" ] && MASTER=$(git -C "$MAIN" rev-parse --verify -q "origin/$BASE" 2>/dev/null \
    || git -C "$MAIN" rev-parse --verify -q "$BASE" 2>/dev/null)

  # merged PR head-refs for this branch (a --head filter keeps it to one branch).
  MERGED_PRS=""
  command -v gh >/dev/null 2>&1 && MERGED_PRS=$(gh -R "$REPO" pr list \
    --state merged --head "$branch" --json headRefName -q '.[].headRefName' 2>/dev/null)

  verdict=$(fleet_reap_ok "$wtdir" "$MAIN" "$branch" "$whead" "$MASTER" "$MERGED_PRS")

  # RECORD the /fleet-history row FIRST — before any worktree removal (the row's
  # transcript-dir is derived from the worktree PATH). The shared helper maps the
  # verdict to the right row: merged-pr → landed; ancestor/unmerged/dirty →
  # closed-unlanded. Idempotent (dedups on session-id), so racing the cleanup daemon
  # / ledger-watch still yields ONE row.
  fleet_reap_record "$verdict" "$REPO" "$MAIN" "$iss" "$wtdir" "$win" "$sess" "" "$branch"

  # CLOSE THE WINDOW FIRST (mirrors dash-reap reap_full, #313): it frees the pane's
  # shell if it was cwd'd inside the worktree, so the remove below isn't blocked, and
  # the dash row vanishes on the next repaint. run-shell -b already backgrounds us.
  [ -n "$win" ] && tmux kill-window -t "$win" 2>/dev/null

  case "$verdict" in
    merged-pr|ancestor)
      if [ -n "$wtdir" ] && [ -n "$MAIN" ]; then
        # Reap any detached proc anchored to this worktree first (#151), then a PLAIN
        # remove (no --force): git refuses a dirty worktree, so even a TOCTOU race
        # after the gate cannot delete uncommitted work.
        fleet_reap_worktree_procs "$wtdir" >/dev/null 2>&1
        git -C "$MAIN" worktree remove "$wtdir" 2>/dev/null \
          && git -C "$MAIN" branch -D "$branch" >/dev/null 2>&1
        git -C "$MAIN" worktree prune 2>/dev/null || true
      fi
      # Close the issue ONLY on a merged PR (a bare ancestor-of-base has no merged
      # work — an empty/abandoned branch — so keep its issue OPEN for re-pickup, per
      # the #403 decision table). Idempotent: a merge may have closed it already.
      if [ "$verdict" = merged-pr ] && [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
        st=$(gh -R "$REPO" issue view "$iss" --json state -q .state 2>/dev/null)
        [ "$st" = OPEN ] && gh -R "$REPO" issue close "$iss" \
          --comment "Closed on manual worker exit: merged PR reaped, worktree cleaned." \
          >/dev/null 2>&1 || true
      fi
      ;;
    *)  # unmerged | dirty → KEEP the worktree + issue (resumable); window already closed.
      : ;;
  esac
  exit 0
fi

# ============================================================================
# IN-PANE GATE (default) — runs synchronously inside the exiting pane. Does ONLY
# the CHEAP checks (reason, opt-in, seat/scope), then dispatches the reap as a
# detached --exec job so the actual git/gh/worktree work survives the pane dying.
# ============================================================================

# No-op outside tmux / with no owning pane (a bare `claude` exit, not a fleet pane).
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0

# 1. Resolve the SessionEnd reason. Prefer the test override; else parse the hook's
#    stdin JSON ({"...","reason":"prompt_input_exit",...}). Guard against a tty so a
#    manual invocation without a piped payload never hangs on cat (mirrors the
#    SessionStart hooks steward-readopt / handoff-latch-reset).
if [ -n "${FLEET_SESSION_END_REASON:-}" ]; then
  reason="$FLEET_SESSION_END_REASON"
elif [ ! -t 0 ]; then
  reason=$(cat 2>/dev/null \
    | sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p' | head -n1)
else
  reason=""
fi

# 2. Only a GENUINE walk-away acts. clear (/clear + every /fleet-handoff cycle),
#    resume, bypass_permissions_disabled, other → NO-OP. The settings-hooks.json
#    matcher already pre-filters to prompt_input_exit|logout; this is defense-in-depth.
case "$reason" in
  prompt_input_exit|logout) : ;;
  *) exit 0 ;;
esac

# 3. Resolve THIS fleet + honor the opt-in. FLEET_CLOSE_ON_EXIT defaults OFF, so an
#    un-opted fleet is a COMPLETE no-op (matches the FLEET_CLEANUP / FLEET_LEDGER_WATCH
#    knob idiom). Resolve the session, overlay its conf, then read the knob.
sess=$(fleet_current_session)
[ -n "$sess" ] || exit 0
fleet_load_conf "$sess"
[ "${FLEET_CLOSE_ON_EXIT:-0}" = 1 ] || exit 0

# 4. Scope: read this pane's window role markers. A worker window carries a numeric
#    @issue; a raw scratch carries @raw=1; the steward hub carries @steward=1; a
#    panel (dash/plan/backlog) carries none.
win=$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)
[ -n "$win" ] || exit 0
issue=$(strip_num "$(tmux display-message -p -t "$TMUX_PANE" '#{@issue}' 2>/dev/null)")
raw=$(tmux display-message -p -t "$TMUX_PANE" '#{@raw}' 2>/dev/null)
steward=$(tmux display-message -p -t "$TMUX_PANE" '#{@steward}' 2>/dev/null)

# Never touch the steward hub (defensive — it carries no @issue/@raw anyway).
[ "$steward" = 1 ] && exit 0

# 5. Dispatch the DETACHED reap. A numeric @issue → worker gate-reap; @raw=1 → close
#    the scratch window only; anything else (a panel/hub) → no-op. `run-shell -b` runs
#    server-side so the reap outlives this pane; pass everything as args (the window
#    may be gone by the time it runs). Values are shell-safe (session = sanitized
#    label, win = @<num>, issue = digits) — same quoting as dash-reap.sh's fleet_bg.
if [ -n "$issue" ]; then
  tmux run-shell -b "bash '$BIN/session-end-hook.sh' --exec worker '$sess' '$win' '$issue'" 2>/dev/null
elif [ "$raw" = 1 ]; then
  tmux run-shell -b "bash '$BIN/session-end-hook.sh' --exec raw '$sess' '$win' -" 2>/dev/null
fi
exit 0
