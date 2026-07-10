#!/bin/bash
# dash-raw-session.sh [<target-session>] — open a RAW (non-issue-bound) scratch
# Claude window in a fleet: plain `claude` on the fleet's socket, with NO GitHub
# issue, NO git worktree, and NO PR lifecycle. It is the counterpart to the
# issue-bound spawners (dash-issue-session.sh / backlog Enter / prefix+n), every
# one of which binds a window to exactly one issue (issue #214). Use it for ad-hoc
# exploration, questions, or throwaway commands in the fleet's checkout.
#
# The window:
#   * runs in $FLEET_MAIN (the fleet's base checkout) so you can read the repo —
#     like the steward pane, it has no worktree of its own.
#   * is marked @raw=1 and has NO @issue, so the issue machinery leaves it alone.
#   * is named `scratch` (or scratch-2, scratch-3, … when several coexist), which
#     is NOT one of the panel names (plan/dash/backlog) — so the dash LISTS it as
#     a real session.
#
# How the rest of the fleet treats it (all handled gracefully, most for free):
#   * dash        — LISTED (only plan/dash/backlog are excluded from the list).
#   * session cap — COUNTS toward FLEET_MAX_SESSIONS / the global cap (it is a
#                   real Claude session holding a slot), so it is cap-checked here.
#   * classifier / summarizer — run normally (its state + summary show in the dash).
#   * worktree janitor — never touches it: its cwd is the MAIN checkout, not an
#                        issue-<N> worktree (the janitor always skips the main one).
#   * autofill dispatcher — sees one fewer free slot (correct — it holds a slot).
#   * watcher     — SKIPS @raw windows (no issue/PR/land → nothing steward-actionable).
#   * fleet-restore — NOT snapshotted or restored (@raw is excluded): scratch
#                     sessions are ephemeral, and their transcript can't be
#                     reliably resolved from the shared base checkout (issue #214).
#
# With no <target-session> the window is created in the CALLER's fleet (the
# interactive prefix/dash path). Pass <target-session> to spawn into a specific
# fleet you are not attached to (headless) — in that mode focus never moves.
set -uo pipefail
TARGET_SESS="${1:-}"
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
[ -d "$MAIN" ] || { TM display-message "raw: FLEET_MAIN is not a directory — set it in fleet.conf" 2>/dev/null; exit 1; }

# Distinct, stable-ish window name: scratch, then scratch-2, scratch-3, … so the
# dash and any future tooling read one window per name. Dedup against THIS fleet's
# live window names.
existing=$(TM list-windows -t "$SESS" -F '#{window_name}' 2>/dev/null)
name="scratch"; n=2
while printf '%s\n' "$existing" | grep -qxF "$name"; do name="scratch-$n"; n=$((n + 1)); done

# Spawn non-invasive by default (matches dash-issue-session.sh): -d creates the
# window WITHOUT making it current, so a user attached to $SESS is not yanked over.
# The new session surfaces via the dash. Opt into jump-to-it with FLEET_SPAWN_FOCUS=1
# (the prefix bind sets this — a raw spawn from a keypress is an explicit "take me
# there"); a headless spawn (TARGET_SESS set) never steals focus. Route through
# fleet-claude.sh — no seed prompt, so it is a plain `claude` under the active
# subscription account + the fleet's default model (transparent when single-account).
win=$(TM new-window -d -P -F '#{window_id}' -t "$SESS:" -n "$name" -c "$MAIN" "'$BIN/fleet-claude.sh'; exec \$SHELL") \
  || { TM display-message "raw: new-window failed in $SESS" 2>/dev/null; exit 1; }
TM set-window-option -t "$win" @raw 1 2>/dev/null   # mark: raw/scratch, NOT issue-bound

# Seed the dash summary column so the row isn't blank until the session renders
# content (same key/format the readers expect; the LLM summarizer overwrites this
# placeholder once real content exists). The session prefix keeps per-fleet servers
# from colliding on the bare window id (issue #208).
C="${TMPDIR:-/tmp}/.claude-dash"; G="$C/global"; mkdir -p "$G"
printf 'scratch (raw session)' > "$G/summary_$(fleet_summary_key "$SESS" "$win")" 2>/dev/null || :

if [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && [ -z "$TARGET_SESS" ]; then
  TM select-window -t "$win" 2>/dev/null
elif [ -z "$TARGET_SESS" ]; then
  TM display-message "spawned raw session → $name" 2>/dev/null
fi
