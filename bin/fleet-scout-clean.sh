#!/bin/bash
# fleet-scout-clean.sh — a read-only SCOUT worker's self-destruct (issue #148).
#
# A scout has NO PR/branch to merge (unlike bin/fleet-land-self.sh's self_destruct),
# so this is TEARDOWN-ONLY: no land lease, no base pull, no history ledger — just
# kill this window and drop its read-only worktree (+ the unused issue-<N> branch).
#
# Ordering is load-bearing and mirrors self-land: the scout's own process holds the
# worktree cwd, so we can't remove it from under ourselves. `tmux run-shell -b` runs
# in the tmux SERVER (not this pane): it kills the window FIRST (our process dies,
# releasing the cwd) and only THEN removes the worktree + branch.
#
# Usage:  fleet-scout-clean.sh [--close] [--issue N] [--force] [--dry-run]
#   --close     close the bound issue before teardown (a scout that does NOT
#               convert to ship work); omit to leave it OPEN for conversion.
#   --issue N   the issue number (default: resolved from the issue-<N> branch or
#               the window's @issue binding).
#   --force     skip the @scout-marker guard (for a scout whose marker was lost,
#               e.g. after a tmux restart). Refuses on a non-scout window otherwise
#               — a normal worker's branch may hold unpushed work.
#   --dry-run   print the teardown command instead of running it (tests).
#
# Prints the teardown command on stderr; on --dry-run prints `dry:<cmd>` on stdout.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

note() { printf '%s\n' "$*" >&2; }

CLOSE=0; DRY="${SCOUT_CLEAN_DRY:-0}"; ISSUE=""; FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --close) CLOSE=1 ;;
    --issue) shift; ISSUE="${1:-}"; ISSUE="${ISSUE//[^0-9]/}" ;;
    --force) FORCE=1 ;;
    --dry-run|-n) DRY=1 ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) note "fleet-scout-clean: unknown flag $1"; exit 2 ;;
    *)  note "fleet-scout-clean: unexpected argument $1"; exit 2 ;;
  esac
  shift
done

# --- resolve fleet identity (this fleet only — never a cwd default) ------------
FLEET_SESSION=$(fleet_current_session)
fleet_load_conf "$FLEET_SESSION"
REPO="${FLEET_REPO:-}"; _r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
MAIN="${FLEET_MAIN:-}"
[ -d "$MAIN/.git" ] || { note "fleet-scout-clean: FLEET_MAIN is not a git checkout."; exit 2; }

# --- resolve THIS scout's issue / worktree / window ---------------------------
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$ISSUE" ]; then
  case "$BRANCH" in
    issue-[0-9]*) ISSUE="${BRANCH#issue-}"; ISSUE="${ISSUE%%[!0-9]*}" ;;
  esac
fi
[ -z "$ISSUE" ] && ISSUE=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}' 2>/dev/null)
ISSUE="${ISSUE//[^0-9]/}"
[ -z "$ISSUE" ] && { note "fleet-scout-clean: no issue resolved (not on an issue-<N> branch, no @issue) — nothing to tear down."; exit 2; }
# The worktree ROOT, not the cwd: a scout may have cd'd into a subdir, and
# `git worktree remove <subdir>` errors ("not a working tree") — leaving an
# orphaned worktree after the window is already killed. --show-toplevel gives the
# root from anywhere inside it; fall back to pwd only if git can't resolve it.
WT=$(git rev-parse --show-toplevel 2>/dev/null); [ -z "$WT" ] && WT=$(pwd -P 2>/dev/null)
WIN=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null)
# The teardown ORDER (kill the window first, then drop the worktree) is what makes
# it safe — the window's death releases the cwd our own process holds. Without a
# real window-id we'd `kill-window -t <garbage>` (a no-op), then `worktree remove`
# would run against a still-busy cwd. Refuse rather than fall back to a bogus
# literal (the @self/@scout-string trap): no window-id means "not in tmux", so
# there's nothing to detach-teardown here.
[ -z "$WIN" ] && { note "fleet-scout-clean: could not resolve this window-id (not attached to a tmux window?) — not running the detached teardown. Remove the worktree by hand: git -C '$MAIN' worktree remove --force '$WT'."; exit 2; }

# A scout must never remove the base checkout itself (only its own worktree). The
# base is read-only ground; tearing it down would take the steward's hub with it.
main_real=$(cd "$MAIN" 2>/dev/null && pwd -P)
if [ -n "$main_real" ] && [ "$WT" = "$main_real" ]; then
  note "fleet-scout-clean: refusing to tear down the base checkout ($MAIN) — run this from the scout's own worktree."
  exit 2
fi

# This is a DESTRUCTIVE teardown (worktree remove --force + branch -d) intended
# ONLY for a read-only scout window — a scout has no PR, so its branch is expendable.
# A NORMAL worker's issue-<N> branch may hold unpushed commits, so force-deleting it
# here would be silent data loss. Gate on the @scout marker the scout spawn sets
# (issue #148); `--force` is the deliberate escape hatch for a scout whose marker
# was lost (e.g. after a tmux restart).
SCOUT_MARK=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@scout}' 2>/dev/null)
if [ "$SCOUT_MARK" != 1 ] && [ "$FORCE" != 1 ]; then
  note "fleet-scout-clean: this window is not marked @scout — refusing to force-remove its worktree/branch (a normal worker may have unpushed work). If this really is a scout, re-run with --force."
  exit 2
fi

# --- optionally close the issue (a scout that does not convert to ship work) ---
# The teardown destroys the window/worktree, so a --close that can't reach the repo
# would orphan the issue OPEN with its context gone — refuse rather than silently
# skip the close the caller explicitly asked for.
if [ "$CLOSE" = 1 ] && [ -z "$REPO" ]; then
  note "fleet-scout-clean: --close requested but no repo resolved — refusing to tear down and orphan #$ISSUE open. Set FLEET_REPO (or close #$ISSUE by hand) and re-run."
  exit 2
fi
if [ "$CLOSE" = 1 ]; then
  note "fleet-scout-clean: closing #$ISSUE on $REPO"
  [ "$DRY" = 1 ] || gh issue close "$ISSUE" --repo "$REPO" >/dev/null 2>&1 || note "  (close failed — leaving #$ISSUE open)"
fi

# --- teardown: kill window → drop worktree → drop the (unused) branch ----------
# `branch -d` (safe delete), NOT `-D` (force): a scout's issue-<N> branch normally
# sits AT base (no commits), so -d deletes it cleanly. But if the scout committed
# against the prompt, -d REFUSES (branch not merged) and the branch survives —
# preserving that work rather than force-discarding it with no PR (issue #148).
# Silence the git steps: run-shell echoes any non-empty command output into a
# view-mode overlay on the attached client, and kill-window switches that client to
# the plan window — so `git branch -d`'s "Deleted branch …" line would surface as an
# Esc-to-dismiss overlay ON THE STEWARD (issue #192). Drop the git stdout/stderr;
# kill-window stays un-redirected (silent on success). branch -d already fails soft.
cmd="tmux kill-window -t $WIN; { git -C '$MAIN' worktree remove --force '$WT'; git -C '$MAIN' branch -d 'issue-$ISSUE'; } >/dev/null 2>&1"
note "fleet-scout-clean: teardown → $cmd"
if [ "$DRY" = 1 ]; then printf 'dry:%s\n' "$cmd"; exit 0; fi
tmux run-shell -b "$cmd" 2>/dev/null || {
  note "fleet-scout-clean: tmux run-shell failed — remove the idle worktree by hand (cwrm / git -C '$MAIN' worktree remove --force '$WT')."
  exit 1
}
exit 0
