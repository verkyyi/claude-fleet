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
#   • Scoped — only a numeric @issue worker, or an @raw scratch (which is RECORDED
#     into the ledger and closed, but never reaped — see the raw branch below);
#     panels (dash/plan/backlog) carry no @issue/@raw and the operator hub pane is
#     bailed on defensively (@hub), so neither is ever touched.
#   • Default ON, GLOBALLY: reacts unless the GLOBAL fleet.conf sets
#     FLEET_CLOSE_ON_EXIT=0 (a machine-wide opt-out). The value is
#     GLOBAL-AUTHORITATIVE — it is snapshotted BEFORE the per-fleet overlay, so a
#     stray per-fleet conf value is ignored. Mirrors the default-on/opt-out idiom of
#     FLEET_CLEANUP / FLEET_LEDGER_WATCH, but the switch is global-only, not per-fleet.
#
# Testable seam: FLEET_SESSION_END_REASON overrides the stdin reason (the selftest
# has no real hook payload). Always exits 0 — SessionEnd cannot block.
set -u

BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# Snapshot the GLOBAL close-on-exit value NOW — the moment the global fleet.conf is
# sourced, BEFORE any per-fleet overlay (fleet_load_conf, below) can change it. The
# knob is GLOBAL-AUTHORITATIVE: default ON, and ONLY the global fleet.conf may turn it
# off (FLEET_CLOSE_ON_EXIT=0); a stray per-fleet conf value is ignored. The in-pane
# gate (step 3) decides on this snapshot; the --exec path never re-reads it.
_close_on_exit="${FLEET_CLOSE_ON_EXIT:-1}"       # default ON; global fleet.conf may set 0
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

TAB=$(printf '\t')
strip_num() { printf '%s' "${1:-}" | tr -cd '0-9'; }

# ============================================================================
# --exec MODE — the DETACHED, server-side reap the in-pane gate dispatches via
# `tmux run-shell -b`. It runs in the tmux server (not the dying pane), so it
# outlives the pane and can remove the very cwd the pane stood in. Everything it
# needs is passed as ARGS (the window may already be gone — it can't re-read it):
#   --exec <kind> <session> <window-id> <issue|scratch-N|->
#     kind = worker → gate-reap the issue-<N> worktree by verdict, then close window
#     kind = raw    → record the scratch session into the ledger, then close the
#                     window (+ drop its dash summary seed). NEVER reaps (#466).
# $TMUX is inherited from the run-shell job, so bare tmux/gh stay on THIS fleet's
# server/socket. Re-resolves conf from <session> — the server env carries no FLEET_*.
# ============================================================================
if [ "${1:-}" = "--exec" ]; then
  # $5 is kind-dependent: the issue number for a worker, the scratch-<N> key for a
  # raw one (#466) — so it is read raw here and interpreted per branch below.
  kind="${2:-}"; sess="${3:-}"; win="${4:-}"; iss=$(strip_num "${5:-}")

  # raw scratch → RECORD it into the /fleet-history ledger, then close the window
  # (issue #466). A scratch has no issue, so the ledger keys it by the `scratch-<N>`
  # slug that names BOTH its branch and its worktree — which is also how we find the
  # worktree here: $5 carries the KEY (shell-safe by construction, unlike a path),
  # and the branch→worktree lookup is authoritative. Recording FIRST, while the
  # worktree still stands, is what captures the transcript path and the HEAD sha the
  # row needs to stay resumable after a later prune.
  #
  # What this deliberately does NOT do is REAP. #290's rule is that an experiment is
  # never silently deleted, and #403 scoped SessionEnd's scratch handling to the
  # window: disposal stays with worktree-autoclean's scratch rules (clean → pruned
  # silently; dirty/unmerged → kept + surfaced once) or a deliberate dash ⌃x. The
  # shared gate runs here only to pick the ROW KIND — a scratch that escalated into a
  # merged PR records `landed`, anything else `closed-unlanded` — never a removal.
  if [ "$kind" = raw ]; then
    key=$(fleet_scratch_key "${5:-}")
    if [ -n "$key" ]; then
      FLEET_SESSION="$sess"; export FLEET_SESSION
      fleet_load_conf "$sess"
      REPO="${FLEET_REPO:-}"
      _r=$(fleet_repo_cached "$sess"); [ -n "$_r" ] && REPO="$_r"
      MAIN="${FLEET_MAIN:-}"; [ -n "$MAIN" ] && [ ! -d "$MAIN/.git" ] && MAIN=""
      BASE="${FLEET_BASE_BRANCH:-master}"
      wtdir=""; whead=""; MASTER=""; MERGED_PRS=""
      if [ -n "$MAIN" ]; then
        wl=$(fleet_worktree_head "$MAIN" "$key")     # branch scratch-<N> → its worktree
        case "$wl" in *"$TAB"*) wtdir=${wl%%"$TAB"*}; whead=${wl#*"$TAB"} ;; esac
        MASTER=$(git -C "$MAIN" rev-parse --verify -q "origin/$BASE" 2>/dev/null \
          || git -C "$MAIN" rev-parse --verify -q "$BASE" 2>/dev/null)
      fi
      command -v gh >/dev/null 2>&1 && [ -n "$REPO" ] && MERGED_PRS=$(gh -R "$REPO" pr list \
        --state merged --head "$key" --json headRefName -q '.[].headRefName' 2>/dev/null)
      verdict=$(fleet_reap_ok "$wtdir" "$MAIN" "$key" "$whead" "$MASTER" "$MERGED_PRS")
      # No issue → pass an empty one; fleet_reap_record derives the scratch key from
      # the branch. record-closed skips a worktree with no transcript, so a scratch
      # that never produced one simply gets no row. The window NAME rides along as
      # the row's title — the window is still alive here (killed below), and without
      # it this instant record deduped away ledger-watch's later titled row, leaving
      # every hand-exited scratch "(untitled)" in /fleet-history.
      wname=$(tmux display-message -p -t "$win" '#{window_name}' 2>/dev/null)
      # @origin rides along as the row's provenance (issue #503) — read while the
      # window is still alive, exactly like the name.
      worigin=$(tmux display-message -p -t "$win" '#{@origin}' 2>/dev/null)
      fleet_reap_record "$verdict" "$REPO" "$MAIN" "" "$wtdir" "$win" "$sess" "" "$key" "$wname" "$worigin"
    fi
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
  # / ledger-watch still yields ONE row. The window name rides along as a fallback
  # title (the window is still alive — killed just below), so a closed-unlanded row
  # recorded here is never "(untitled)"; on the landed path gh's PR title still wins.
  wname=$(tmux display-message -p -t "$win" '#{window_name}' 2>/dev/null)
  # @origin rides along as the row's provenance (issue #503) — read pre-kill.
  worigin=$(tmux display-message -p -t "$win" '#{@origin}' 2>/dev/null)
  fleet_reap_record "$verdict" "$REPO" "$MAIN" "$iss" "$wtdir" "$win" "$sess" "" "$branch" "$wname" "$worigin"

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
#    SessionStart hook handoff-latch-reset).
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

# 3. Resolve THIS fleet, then honor the GLOBAL-AUTHORITATIVE gate. Default ON: skip
#    ONLY when the GLOBAL fleet.conf set FLEET_CLOSE_ON_EXIT=0 (captured in
#    $_close_on_exit above, before the per-fleet overlay). fleet_load_conf is still
#    needed to resolve FLEET_MAIN/REPO/BASE for the reap, but its per-fleet
#    FLEET_CLOSE_ON_EXIT (if any) is deliberately ignored — the switch is global-only.
#    Matches the default-on/opt-out idiom of FLEET_CLEANUP / FLEET_LEDGER_WATCH.
sess=$(fleet_current_session)
[ -n "$sess" ] || exit 0
fleet_load_conf "$sess"                          # still needed for FLEET_MAIN/REPO/BASE
[ "$_close_on_exit" = 0 ] && exit 0              # global opt-out only; per-fleet ignored

# 4. Scope: read this pane's window role markers. A worker window carries a numeric
#    @issue; a raw scratch carries @raw=1; the operator hub pane carries @hub=1; a
#    panel (dash/plan/backlog) carries none.
win=$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)
[ -n "$win" ] || exit 0
issue=$(strip_num "$(tmux display-message -p -t "$TMUX_PANE" '#{@issue}' 2>/dev/null)")
raw=$(tmux display-message -p -t "$TMUX_PANE" '#{@raw}' 2>/dev/null)
hub=$(tmux display-message -p -t "$TMUX_PANE" '#{@hub}' 2>/dev/null)

# Never touch the operator hub pane (defensive — it carries no @issue/@raw anyway).
[ "$hub" = 1 ] && exit 0

# 5. Dispatch the DETACHED reap. A numeric @issue → worker gate-reap; @raw=1 → record
#    the scratch + close its window (#466); anything else (a panel/hub) → no-op.
#    `run-shell -b` runs server-side so the work outlives this pane; pass everything as
#    args (the window may be gone by the time it runs). Every value is shell-safe by
#    construction (session = sanitized label, win = @<num>, issue = digits, scratch key
#    = scratch-<digits> — which is WHY the raw path passes the key and not the raw
#    @worktree path) — same quoting as dash-reap.sh's fleet_bg.
if [ -n "$issue" ]; then
  tmux run-shell -b "bash '$BIN/session-end-hook.sh' --exec worker '$sess' '$win' '$issue'" 2>/dev/null
elif [ "$raw" = 1 ]; then
  # @worktree is what dash-raw-session.sh binds at spawn; the pane cwd is the fallback
  # for a window that predates it. A key that doesn't resolve → the exec just closes
  # the window, exactly as it did before this.
  wt=$(tmux display-message -p -t "$TMUX_PANE" '#{@worktree}' 2>/dev/null)
  [ -z "$wt" ] && wt=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_current_path}' 2>/dev/null)
  skey=$(fleet_scratch_key "$wt")
  tmux run-shell -b "bash '$BIN/session-end-hook.sh' --exec raw '$sess' '$win' '${skey:--}'" 2>/dev/null
fi
exit 0
