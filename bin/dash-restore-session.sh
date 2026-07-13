#!/bin/bash
# dash-restore-session.sh <landed-target> [<target-session>] — RESTORE a finished
# (landed + cleaned-up) session into a NEW tmux window via `claude --resume`,
# reusing the recorded transcript/session id (issue #228). This is the one-key
# dash counterpart to `/fleet-history resume`: it reconstructs the removed worktree
# off the recorded squash SHA (bin/fleet-history.sh resume --exec) and opens a
# claude window resumed onto the surviving transcript — no cd/paste dance.
#
# <landed-target> is the dash landed-row's field1 (what the ⌃o bind passes as {1}):
#   landed:issue:<n>   PR-less landed row  → resume by issue number <n>
#   landed:<pr>        PR-bearing row      → resume by #<pr>
# Anything else (a live-view row, the header) is a no-op with a hint — restore only
# applies to the landed view (⌃t).
#
# Mirrors the spawn conventions of dash-issue-session.sh / dash-raw-session.sh:
#   * per-fleet socket (fleet_socket) — correct in-session and headless alike;
#   * session-cap gated (a restored session is a real Claude session);
#   * non-invasive focus — the new window surfaces in the dash; it never yanks the
#     operator over (matches ⌃g/⌃s). FLEET_SPAWN_FOCUS=1 opts into the jump.
# The reconstructed worktree is a THROWAWAY at the merged SHA: while the restored
# window is live the janitor keeps it (a live pane is cd'd inside — see
# worktree-autoclean.sh); once the window closes it is merged+clean+unattached
# again and the janitor prunes it. Binding @issue is safe — the bound issue is
# already closed, so the janitor's auto-close ("only if still open") is a no-op.
#
# --plan <target>: print the resolved resume key and exit (no tmux/git). For the
# hermetic selftest — the reconstruct/verdict logic itself is covered by
# fleet-history-selftest.sh (resume).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

# landed-row target → resume key (issue number, or #PR). Prints the key; returns
# non-zero when the target isn't a landed row (live row / header / empty).
restore_key_for() {
  case "${1:-}" in
    landed:issue:*) printf '%s' "${1#landed:issue:}" ;;
    landed:*)       printf '#%s' "${1#landed:}" ;;
    *)              return 1 ;;
  esac
}

# --plan short-circuit (no side effects) — used by the selftest.
if [ "${1:-}" = "--plan" ]; then
  restore_key_for "${2:-}"; echo; exit 0
fi

# --exec-bg (issue #304) is the BACKGROUND tail dispatched by the interactive path
# via fleet_bg — the same run, minus the "dispatch to bg" step. A real 2nd positional
# is the headless cross-session <target-session>, which stays synchronous (no $TMUX to
# run-shell onto). The bg re-exec carries the resolved session in FLEET_RESTORE_SESS.
TARGET="${1:-}"; TARGET_SESS=""; BG_EXEC=0
case "${2:-}" in
  --exec-bg) BG_EXEC=1 ;;
  "")        : ;;
  *)         TARGET_SESS="$2" ;;
esac
key=$(restore_key_for "$TARGET") || {
  tmux display-message "restore: not a landed session — ⌃t for the landed view, then ⌃o" 2>/dev/null
  exit 0
}

# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
SESS="${TARGET_SESS:-${FLEET_RESTORE_SESS:-$(fleet_current_session)}}"
[ -z "$SESS" ] && { tmux display-message "restore: no target tmux session" 2>/dev/null; exit 1; }
fleet_load_conf "$SESS"
SOCK=$(fleet_socket "$SESS")
TM() { tmux -L "$SOCK" "$@"; }

# Session cap (issues #28/#70): a restored session holds a slot like any spawn.
if ! cap_msg=$(fleet_session_cap_ok "$SESS"); then TM display-message "$cap_msg" 2>/dev/null; exit 1; fi

MAIN="${FLEET_MAIN:-}"; REPO="${FLEET_REPO:-}"
[ -d "$MAIN/.git" ] || { TM display-message "restore: FLEET_MAIN is not a git checkout" 2>/dev/null; exit 1; }

# All the CHEAP/authoritative checks (valid landed target, session cap, MAIN) have
# passed synchronously, so a refusal was immediate. Now hand the SLOW tail — the
# worktree reconstruct (`git worktree add` off the squash SHA, multi-second on a big
# monorepo) + the resumed-window spawn — to the BACKGROUND (issue #304) so the ⌃o
# bind / Enter-in-landed-view returns INSTANTLY. Re-exec ourselves with --exec-bg
# (the same run, minus this dispatch), carrying the focus knob + resolved session.
# The bind runs in the dash pane so bare fleet_bg lands on THIS fleet's server; the
# headless cross-session path (TARGET_SESS set) stays synchronous.
if [ "$BG_EXEC" != 1 ] && [ -z "$TARGET_SESS" ]; then
  fleet_bg "FLEET_SPAWN_FOCUS='${FLEET_SPAWN_FOCUS:-0}' FLEET_RESTORE_SESS='$SESS' bash '$0' '$TARGET' --exec-bg"
  exit 0
fi

# Reconstruct the worktree off the squash SHA and get the resume verdict/command.
# --exec actually does the `git worktree add`; the printed line is one of:
#   RESUME\t<worktree>\t<session-id>\t<claude-cmd>
#   FROM-PR\t<pr>\t<claude-cmd>
#   REVIEW-ONLY\t<reason>
verdict=$(bash "$BIN/fleet-history.sh" resume --exec --repo "$REPO" --main "$MAIN" "$key" 2>/dev/null)
kind=${verdict%%$'\t'*}

# Spawn is non-invasive by default: -d keeps the active window put; opt into the
# jump with FLEET_SPAWN_FOCUS=1 on an interactive (no TARGET_SESS) restore.
detach=(-d); [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && [ -z "$TARGET_SESS" ] && detach=()
G="${TMPDIR:-/tmp}/.claude-dash/global"; mkdir -p "$G" 2>/dev/null || true

announce() {  # $1 = window-id, $2 = message
  if [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && [ -z "$TARGET_SESS" ]; then TM select-window -t "$1"
  elif [ -z "$TARGET_SESS" ]; then TM display-message "$2" 2>/dev/null; fi
}

case "$kind" in
  RESUME)
    # verdict = RESUME\t<worktree>\t<session-id>\t<claude-cmd>; the session id is
    # already embedded in <claude-cmd>, so we only need the worktree + the command.
    IFS=$'\t' read -r _ wt _ cmd <<<"$verdict"
    [ -d "$wt" ] || { TM display-message "restore: worktree not reconstructed for $key" 2>/dev/null; exit 1; }
    # cmd = "claude --resume <sid> --fork-session"; route the args through
    # fleet-claude.sh (account rotation + fleet model), dropping the leading "claude".
    # --resume is cwd-scoped, so the window MUST run in the reconstructed worktree
    # (its encoded path is where the transcript lives) — that is why resume rebuilt
    # it at the original path.
    args=${cmd#claude }
    name="resume-${key#\#}"
    win=$(TM new-window ${detach[@]+"${detach[@]}"} -P -F '#{window_id}' -t "$SESS:" -n "$name" -c "$wt" \
      "'$BIN/fleet-claude.sh' $args; exec \$SHELL") \
      || { TM display-message "restore: new-window failed for $key" 2>/dev/null; exit 1; }
    # Bind @issue when resuming by issue number so the row reads like the original
    # worker (dash/backlog/PR-map recognise it); a #PR resume has no issue to bind.
    case "$key" in \#*) : ;; *) TM set-window-option -t "$win" @issue "$key" 2>/dev/null ;; esac
    TM set-window-option -t "$win" @restored 1 2>/dev/null   # mark: a resumed landed session
    printf 'resumed %s' "$key" > "$G/summary_$(fleet_summary_key "$SESS" "$win")" 2>/dev/null || :
    announce "$win" "restored $key → $name"
    ;;
  FROM-PR)
    IFS=$'\t' read -r _ pr cmd <<<"$verdict"
    # Degrade path: no recreatable worktree/transcript, but a PR — `claude --from-pr`
    # checks the PR out itself, so run it from the base checkout.
    args=${cmd#claude }
    name="resume-pr${pr}"
    win=$(TM new-window ${detach[@]+"${detach[@]}"} -P -F '#{window_id}' -t "$SESS:" -n "$name" -c "$MAIN" \
      "'$BIN/fleet-claude.sh' $args; exec \$SHELL") \
      || { TM display-message "restore: new-window failed for PR $pr" 2>/dev/null; exit 1; }
    TM set-window-option -t "$win" @restored 1 2>/dev/null
    printf 'resumed PR %s (from-pr)' "$pr" > "$G/summary_$(fleet_summary_key "$SESS" "$win")" 2>/dev/null || :
    announce "$win" "restored PR $pr (from-pr) → $name"
    ;;
  *)
    reason=${verdict#*$'\t'}; [ "$reason" = "$verdict" ] && reason=""
    TM display-message "restore: nothing resumable for $key — ${reason:-review via /fleet-history}" 2>/dev/null
    exit 0
    ;;
esac
