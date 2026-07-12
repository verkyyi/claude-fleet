#!/bin/bash
# dash-raw-session.sh [--name <name>] [<target-session>] — open a RAW (non-issue-
# bound) scratch Claude window in a fleet: plain `claude` on the fleet's socket,
# with NO GitHub issue and NO seed prompt, but in its OWN git worktree off the base
# branch (issue #290). It is the counterpart to the issue-bound spawners
# (dash-issue-session.sh / backlog Enter / prefix+n), every one of which binds a
# window to exactly one issue (issue #214). Use it for ad-hoc exploration,
# experiments, or throwaway commands that may need to WRITE code.
#
# Why a worktree (not $FLEET_MAIN) — the three wins, issue #290:
#   1. WRITABLE — the base checkout is hook-enforced read-only; a scratch sitting
#      there literally can't edit code. In its own `scratch-<N>` worktree it can
#      experiment freely without touching base.
#   2. ESCALATABLE FOR FREE — a scratch that turns real just pushes its branch and
#      opens a PR (`fixes #N` optional). The prmap is repo-wide, so the janitor
#      reaps a merged `scratch-<N>` like any worker on merge — zero new machinery.
#   3. RESOLVABLE TRANSCRIPTS — the unique cwd fixes the "can't resolve the
#      transcript from the shared base checkout" limit (#214): a scratch can now be
#      summarized correctly and is eligible for ledger capture/resume later (out of
#      scope here — noted).
#
# The window:
#   * runs in a fresh `<repo-parent>/<repo-dir>-scratch-<N>` worktree on a new
#     `scratch-<N>` branch off origin/<base> (mirrors dash-issue-session.sh's
#     worktree mechanics), so it can edit code and land via PR like a worker.
#   * is marked @raw=1, carries @worktree=<path>, and has NO @issue, so the
#     issue machinery leaves it alone.
#   * is named `scratch-<N>` (matching its worktree suffix) by default, OR an
#     optional display-only name via --name (issue #225). The name is
#     cosmetic/navigational only — everything downstream keys off @raw=1 / absence
#     of @issue, NOT the window name — but it must not collide with a panel name
#     (plan/dash/backlog), which the dash hides; such a name (or one that empties
#     out after sanitizing) falls back to the auto `scratch-<N>` name.
#
# How the rest of the fleet treats it (all handled gracefully, most for free):
#   * dash        — LISTED (only plan/dash/backlog are excluded from the list).
#   * session cap — COUNTS toward FLEET_MAX_SESSIONS / the global cap (it is a
#                   real Claude session holding a slot), so it is cap-checked here.
#   * classifier / summarizer — run normally (its state + summary show in the dash).
#   * worktree janitor — REAPS it by the scratch rules (issue #290): once the window
#                        is gone, a clean+no-unpushed `scratch-<N>` worktree is
#                        removed silently; a dirty/unpushed one is KEPT and surfaced
#                        once — an experiment is never silently deleted. `dash ⌃x`
#                        force-reap covers manual disposal.
#   * watcher     — SKIPS @raw windows (no issue/PR/land → nothing steward-actionable),
#                   and it holds a slot so headroom checks see one fewer free slot.
#   * fleet-restore — the WINDOW is NOT snapshotted or restored (@raw is excluded):
#                     scratch windows are ephemeral. Its WORKTREE, however, survives
#                     a crash on disk and is reapable by the janitor's scratch rules.
#
# With no <target-session> the window is created in the CALLER's fleet (the
# interactive prefix/dash path). Pass <target-session> to spawn into a specific
# fleet you are not attached to (headless) — in that mode focus never moves.
set -uo pipefail

# Args (order-independent): --name <n> / --name=<n> is the optional display-only
# window name (issue #225); --prompt-read is the dash ⌃s popup phase (read the
# name off one line of stdin, then fall through to the normal spawn); the lone
# positional is the headless <target-session>.
NAME=""; TARGET_SESS=""; PROMPT_READ=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)        NAME="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --name=*)      NAME="${1#--name=}"; shift ;;
    --prompt-read) PROMPT_READ=1; shift ;;
    *)             TARGET_SESS="$1"; shift ;;
  esac
done

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

# dash ⌃s popup phase: running INSIDE a `tmux display-popup -E` (see
# tmux-dashboard.sh), read ONE optional line as the name and fall through to the
# spawn below. Empty input keeps the auto scratch[-N] name (the common case is
# one keystroke + Enter). Mirrors dash-issue-new.sh's confirm-box read.
if [ "$PROMPT_READ" = 1 ]; then
  printf '\n  New raw (scratch) session\n  (empty name = auto \342\200\230scratch\342\200\231)\n\n  name \342\226\270 '
  IFS= read -r NAME || NAME=""
fi

SESS="${TARGET_SESS:-$(fleet_current_session)}"
[ -z "$SESS" ] && { tmux display-message "raw: no target tmux session" 2>/dev/null; exit 1; }
fleet_load_conf "$SESS"                       # multi-fleet: target THIS fleet's checkout
# Each fleet is its OWN tmux server on a named socket (== session name, issue
# #159). Route EVERY tmux call through TM() so it names the target fleet's socket
# explicitly — correct in-session ($TMUX set) and headless alike.
SOCK=$(fleet_socket "$SESS")
TM() { tmux -L "$SOCK" "$@"; }

# Session cap (issues #28, #70): a raw session is a real Claude session, so it is
# subject to the SAME global + per-fleet ceilings as an issue spawn. Refuse (with a
# human-readable reason) once a cap is reached, rather than quietly overspend.
if ! cap_msg=$(fleet_session_cap_ok "$SESS"); then TM display-message "$cap_msg" 2>/dev/null; exit 1; fi

MAIN="${FLEET_MAIN:-}"
[ -d "$MAIN/.git" ] || { TM display-message "raw: FLEET_MAIN is not a git checkout — set it in fleet.conf" 2>/dev/null; exit 1; }
BASE="${FLEET_BASE_BRANCH:-master}"

# Window name (issue #225): an optional --name wins; otherwise the auto
# `scratch-<N>` (N == the worktree suffix, allocated below). A custom name is
# sanitized (trim; strip control chars + `#`, the tmux format char; cap ~24 chars)
# but its casing/spacing is PRESERVED — it's the user's scratch label, not a kebab
# slug. If it sanitizes to a panel name the dash hides (plan/dash/backlog), or
# empties out, fall back to the auto name with a one-line note (non-blocking: the
# user still gets a window).
note=""
custom=""
if [ -n "$NAME" ]; then
  san=$(printf '%s' "$NAME" \
    | LC_ALL=C tr -d '[:cntrl:]#' \
    | LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | cut -c1-24 \
    | LC_ALL=C sed -e 's/[[:space:]]*$//')
  case "$san" in
    plan|dash|backlog) note="'$san' is reserved — named it scratch instead" ;;
    "")                note="name empty after sanitize — named it scratch instead" ;;
    *)                 custom="$san" ;;
  esac
fi

# --- allocate a scratch worktree off the base branch (issue #290) -------------
# The branch `scratch-<N>` + worktree `<repo-parent>/<repo-dir>-scratch-<N>` mirror
# dash-issue-session.sh's mechanics. N is allocated atomic-ish vs concurrent ⌃s
# presses: `git worktree add -b` is itself the serialization point — it FAILS if the
# branch (or dir) already exists — so we retry with the next N on any loser, rather
# than trust a check-then-create gap. The cheap pre-checks (branch ref / dir exists)
# just skip obviously-taken candidates before the authoritative add. git/fs
# uniqueness is durable (a worktree outlives its window), unlike live window names.
MAIN_DIR="$(dirname "$MAIN")"; MAIN_BASE="$(basename "$MAIN")"
git -C "$MAIN" fetch origin "$BASE" --quiet 2>/dev/null
slug=""; wt=""; N=1
while [ "$N" -le 999 ]; do
  cand="scratch-$N"; cwt="$MAIN_DIR/$MAIN_BASE-$cand"
  if git -C "$MAIN" show-ref --verify --quiet "refs/heads/$cand" 2>/dev/null || [ -e "$cwt" ]; then
    N=$((N + 1)); continue
  fi
  if git -C "$MAIN" worktree add -b "$cand" "$cwt" "origin/$BASE" 2>/dev/null \
     || git -C "$MAIN" worktree add -b "$cand" "$cwt" "$BASE" 2>/dev/null; then
    slug="$cand"; wt="$cwt"; break
  fi
  N=$((N + 1))
done
[ -n "$slug" ] || { TM display-message "raw: could not create a scratch worktree" 2>/dev/null; exit 1; }

# Distinct, stable-ish window name. Default is the worktree slug `scratch-<N>` so a
# window and its worktree read alike; a custom --name is deduped against THIS
# fleet's live window names (<name>, <name>-2, …). The name is cosmetic — the
# worktree/branch uniqueness is what git/fs guarantee above.
existing=$(TM list-windows -t "$SESS" -F '#{window_name}' 2>/dev/null)
name="${custom:-$slug}"; n=2
while printf '%s\n' "$existing" | grep -qxF "$name"; do name="${custom:-$slug}-$n"; n=$((n + 1)); done

# Spawn non-invasive by default (matches dash-issue-session.sh): -d creates the
# window WITHOUT making it current, so a user attached to $SESS is not yanked over.
# The new session surfaces via the dash. Opt into jump-to-it with FLEET_SPAWN_FOCUS=1
# (the prefix bind sets this — a raw spawn from a keypress is an explicit "take me
# there"); a headless spawn (TARGET_SESS set) never steals focus. Route through
# fleet-claude.sh — no seed prompt, so it is a plain `claude` under the active
# subscription account + the fleet's default model (transparent when single-account).
# On a new-window failure, roll back the just-created worktree + branch so a failed
# spawn leaves no orphan (the janitor would otherwise inherit it).
win=$(TM new-window -d -P -F '#{window_id}' -t "$SESS:" -n "$name" -c "$wt" "'$BIN/fleet-claude.sh'; exec \$SHELL") \
  || { git -C "$MAIN" worktree remove --force "$wt" >/dev/null 2>&1
       git -C "$MAIN" branch -D "$slug" >/dev/null 2>&1
       git -C "$MAIN" worktree prune >/dev/null 2>&1
       TM display-message "raw: new-window failed in $SESS" 2>/dev/null; exit 1; }
TM set-window-option -t "$win" @raw 1 2>/dev/null        # mark: raw/scratch, NOT issue-bound
TM set-window-option -t "$win" @worktree "$wt" 2>/dev/null # so ⌃x can resolve+reap the worktree

# Seed the dash summary column so the row isn't blank until the session renders
# content (same key/format the readers expect; the LLM summarizer overwrites this
# placeholder once real content exists). The session prefix keeps per-fleet servers
# from colliding on the bare window id (issue #208).
C="${TMPDIR:-/tmp}/.claude-dash"; G="$C/global"; mkdir -p "$G"
printf '%s (raw session)' "$name" > "$G/summary_$(fleet_summary_key "$SESS" "$win")" 2>/dev/null || :

if [ -z "$TARGET_SESS" ]; then
  # Surface a reserved-name fallback note regardless of the focus path so the user
  # learns why their name wasn't used (non-blocking — they still got a window).
  if [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ]; then
    TM select-window -t "$win" 2>/dev/null
    [ -n "$note" ] && TM display-message "$note" 2>/dev/null
  else
    msg="spawned raw session → $name"; [ -n "$note" ] && msg="$msg ($note)"
    TM display-message "$msg" 2>/dev/null
  fi
fi
