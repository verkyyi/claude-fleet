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
#      transcript from the shared base checkout" limit (#214): a scratch can be
#      summarized correctly, and (issue #466) it is now CAPTURED in the
#      /fleet-history ledger when its window closes — keyed by the `scratch-<N>`
#      slug this script allocates below — so it browses and RESUMES like a worker.
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
#   * reapers     — SKIP @raw windows (no issue/PR/land → nothing to act on),
#                   and it holds a slot so headroom checks see one fewer free slot.
#   * fleet-restore — the WINDOW is NOT snapshotted or restored (@raw is excluded):
#                     scratch windows are ephemeral. Its WORKTREE, however, survives
#                     a crash on disk and is reapable by the janitor's scratch rules.
#   * /fleet-history — INDEXED on close and resumable (#466): keyed `scratch-<N>`,
#                     listed as `~<N>`, restored with ⌃o into a fresh @raw window.
#
# With no <target-session> the window is created in the CALLER's fleet (the
# interactive dash path). Pass <target-session> to spawn into a specific fleet you
# are not attached to (headless) — in that mode focus never moves.
#
# The dash's ⌃s is a ONE-KEYSTROKE spawn (issue #444): no name popup, no confirm —
# press it and the scratch window is on its way. Naming was a prompt nobody filled
# in (the auto `scratch-<N>` matches the worktree and reads better in the dash), and
# a popup on the tap-first path cost a keyboard round-trip for an empty line. A name
# is still available non-interactively via --name, and any window can be renamed
# after the fact.
set -uo pipefail

# Args (order-independent): --name <n> / --name=<n> is the optional display-only
# window name (issue #225); --bg backgrounds the slow half of the spawn (the dash
# ⌃s path — see below); the lone positional is the headless <target-session>.
NAME=""; TARGET_SESS=""; BG=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)        NAME="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --name=*)      NAME="${1#--name=}"; shift ;;
    # --name-file=<f> (issue #304): the BACKGROUND spawn pass — the --bg pass staged
    # the (arbitrary user) name in a temp file and re-exec'd us via fleet_bg; read +
    # delete it. No --bg on that pass, so it falls straight through and spawns.
    --name-file=*) f="${1#--name-file=}"; NAME="$(cat "$f" 2>/dev/null)"; rm -f "$f"; shift ;;
    --bg)          BG=1; shift ;;
    *)             TARGET_SESS="$1"; shift ;;
  esac
done

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

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

# Backgrounded spawn (issues #304, #444): the cheap/authoritative checks above (session
# cap, MAIN) have passed synchronously, so a refusal is immediate and lands on the
# status line. Now hand the SLOW half — `git fetch` + the `git worktree add` retry
# loop + the window launch — to the BACKGROUND so the ⌃s keypress returns INSTANTLY
# instead of freezing the dash on checkout. Re-exec ourselves with no --bg (so the
# bg pass just spawns) and any name staged in a temp file (arbitrary user text —
# NEVER interpolated into the run-shell string). Only --bg backgrounds; a headless
# CLI call falls straight through and spawns in the foreground. The dash pane has
# $TMUX on THIS fleet's server, so bare fleet_bg lands correctly.
#
# The trailing `>/dev/null 2>&1` is REQUIRED, not tidiness (issues #192, #446):
# `run-shell` surfaces a backgrounded job's STDOUT as a view-mode overlay on the
# INVOKING pane — which is now the dash itself, not a popup that closes. One stray
# line (`git worktree add`'s "HEAD is now at …") therefore covered the dash until
# the user pressed Esc. Outcomes are reported via `tmux display-message`, so the
# job has nothing to say on stdout; the redirect keeps it that way for good.
if [ "$BG" = 1 ]; then
  nfarg=""
  if [ -n "$NAME" ]; then
    nf=$(mktemp "${TMPDIR:-/tmp}/dash-raw.XXXXXX") || { TM display-message "raw: cannot stage the scratch name" 2>/dev/null; exit 1; }
    printf '%s' "$NAME" > "$nf"
    nfarg=" --name-file='$nf'"
  fi
  fleet_bg "FLEET_SPAWN_FOCUS='${FLEET_SPAWN_FOCUS:-0}' bash '$0'$nfarg${TARGET_SESS:+ '$TARGET_SESS'} >/dev/null 2>&1"
  exit 0
fi

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

# --- get a scratch window: WARM POOL first, cold spawn otherwise --------------
# With FLEET_SCRATCH_POOL>0 the slow half of a spawn already happened, minutes ago,
# to a window parked in the `<sess>-pool` holding session: worktree built, claude
# booted, and — the part that actually bites — PAST the TUI's input-mount flush,
# the ~1s window in which Claude Code silently discards whatever you type even
# though the `❯` box is already on screen. Claiming one is a `move-window` +
# rename: the pane, its pty and the running claude survive untouched, so the
# window is typeable in the same tick (measured 0.29s vs 7.0s cold).
# An empty claim (pool off, cold, stale, or account-rotated) falls straight
# through to the original cold path below — the pool is never load-bearing.
warm=0; win=""; slug=""; wt=""
claimed=$(bash "$BIN/scratch-pool.sh" claim "$SESS" 2>/dev/null | head -1)
if [ -n "$claimed" ]; then
  warm=1
  win=${claimed%%	*}; _rest=${claimed#*	}; slug=${_rest%%	*}; wt=${_rest#*	}
fi

# --- allocate a scratch worktree off the base branch (issue #290) -------------
# The branch `scratch-<N>` + worktree `<repo-parent>/<repo-dir>-scratch-<N>` mirror
# dash-issue-session.sh's mechanics. The allocator lives in fleet-lib.sh
# (fleet_scratch_alloc) because the warm pool allocates identically; `git worktree
# add -b` is itself the serialization point vs concurrent ⌃s presses.
if [ "$warm" = 0 ]; then
  alloc=$(fleet_scratch_alloc "$MAIN" "$BASE") || alloc=""
  if [ -n "$alloc" ]; then slug=${alloc%%	*}; wt=${alloc#*	}; fi
  [ -n "$slug" ] || { TM display-message "raw: could not create a scratch worktree" 2>/dev/null; exit 1; }
fi

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
if [ "$warm" = 1 ]; then
  # already spawned + already warm: it only needs this fleet's name on it. @raw /
  # @worktree were stamped when it was warmed; the @pool_* marks were cleared by
  # the claim, so from here on it is indistinguishable from a cold scratch window.
  TM rename-window -t "$win" -- "$name" 2>/dev/null
else
  win=$(TM new-window -d -P -F '#{window_id}' -t "$SESS:" -n "$name" -c "$wt" "'$BIN/fleet-claude.sh'; exec \$SHELL") \
    || { fleet_scratch_free "$MAIN" "$slug" "$wt"
         TM display-message "raw: new-window failed in $SESS" 2>/dev/null; exit 1; }
  TM set-window-option -t "$win" @raw 1 2>/dev/null        # mark: raw/scratch, NOT issue-bound
  TM set-window-option -t "$win" @worktree "$wt" 2>/dev/null # so ⌃x can resolve+reap the worktree
fi

# Seed the dash summary column so the row isn't blank until the session renders
# content (same key/format the readers expect; the LLM summarizer overwrites this
# placeholder once real content exists). The session prefix keeps per-fleet servers
# from colliding on the bare window id (issue #208).
C="${TMPDIR:-/tmp}/.claude-dash"; G="$C/global"; mkdir -p "$G"
rawseed="$name (raw session)"
printf '%s' "$rawseed" > "$G/summary_$(fleet_summary_key "$SESS" "$win")" 2>/dev/null || :
# …and as a window option, so the pane header carries it too (issue #455).
TM set-window-option -t "$win" @summary "$(fleet_summary_sanitize "$rawseed")" 2>/dev/null || :

# Refill the pool in the background, so the NEXT ⌃s is instant too — but NOT right
# now. Warming costs a whole cold claude boot (node + the fleet's MCP set), and
# firing it at the instant the operator starts typing into the window they just
# claimed is the one moment it hurts: on a box already running several sessions
# that contention pushed the first keystroke's echo from sub-second to tens of
# seconds — reintroducing, from the other end, exactly the stall this removes.
# So the refill sleeps first (FLEET_POOL_REFILL_DELAY, default 45s). run-shell -b
# because it is slow either way; a no-op when FLEET_SCRATCH_POOL is 0.
TM run-shell -b "sleep ${FLEET_POOL_REFILL_DELAY:-45}; bash '$BIN/scratch-pool.sh' ensure '$SESS' >/dev/null 2>&1" 2>/dev/null

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
