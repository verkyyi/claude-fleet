#!/bin/bash
# fleet-worker-stop.sh <session> [<repo>:]<issue-N|scratch-N> — GRACEFUL stop of ONE live
# worker, addressed by its DURABLE key, never by a window number (issue #834).
#
# The Fleet Hub's `worker_stop` lands here. A tmux window id is an observation:
# `renumber-windows on` shifts indexes, `/fleet-handoff` swaps the native session
# in place, and an account migration re-creates the window outright. The one
# thing that names the same worker across all of those is its binding — the
# numeric `@issue` of a worker, or the `scratch-<N>` slug of an @raw scratch
# worktree — which is also the key every /fleet-history row and ledger-watch
# snapshot is keyed on. So this script takes the KEY, re-resolves it against the
# fleet's live windows at the moment it acts, and refuses when that resolution
# is not exactly one window. A window that merely has the number the caller last
# saw is never touched.
#
# What "graceful" means here — the same exit the operator's own /exit and the
# migration pass (fleet-migrate.sh) perform:
#   1. read the window's metadata WHILE it stands (id, name, cwd, @worktree,
#      @origin, @cc_agent) and the agent pid under the pane (fleet_pane_claude_pid);
#   2. Escape (cancels an in-flight turn / any open menu), then `/exit` + Enter —
#      the ONLY keys ever typed (issue #437's sanctioned FLEET_ALLOW_SENDKEYS=1);
#      wait for the pid to be gone, never typing anything else while it lives;
#   3. let the SessionEnd hook (session-end-hook.sh) close the window and record
#      the /fleet-history row — exactly what happens on a manual /exit, so the
#      session is resumable the instant it ends;
#   4. when no hook closes it (FLEET_CLOSE_ON_EXIT=0, or a pane that already sat
#      at a bare shell), record the closed-unlanded row ourselves and close the
#      pane-less / shell-only window — nothing runs in it, so that is not a kill.
#
# This script runs NO git command: the worktree, the branch and the issue are
# left exactly as they are, and the row it (or the hook) records keeps the
# session resumable via `worker_resume` / /fleet-history. The hook applies the
# fleet's ordinary exit policy to the worktree (it removes one only when its
# branch is merged or a strict ancestor of base — never uncommitted or unmerged
# work); a stop is not exempt from that policy, and not a reap either.
#
# Refusals (nothing typed, nothing closed):
#   refused:not-found    5   no live window holds this key on the fleet
#   refused:ambiguous    6   more than one live window holds it — resolve on the fleet
#   refused:hibernating  8   @worker_lifecycle is set: the sleep controller owns
#                            the pane (issue #808); wake it there before stopping
#   failed:no-exit       7   the agent did not exit within FLEET_STOP_EXIT_WAIT s —
#                            left as is; the caller reads this as unconfirmed
# Success (one token on stdout, exit 0):
#   stopped:exit         agent exited, the SessionEnd hook closed the window
#   stopped:closed       agent exited, no hook closed it — row recorded, window closed
#   stopped:shell        no agent under the pane — row recorded, window closed
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

SESS="${1:-}"; KEY="${2:-}"
# A multi-repo fleet (issue #1018) names the repo too: `<repo>:issue-N` (the #789
# spelling; <repo> = owner/name, slug or bare name), because two hosted repos can
# both have an issue-12. WREPO is then that hosted repo and only its windows
# match; a bare key matches every repo's, so two of them refuse as ambiguous.
WREPO=''
case "$KEY" in *:*)
  [ -n "$SESS" ] && WREPO=$(fleet_repo_for_slug "$SESS" "${KEY%%:*}") || WREPO=''
  if [ -z "$WREPO" ]; then KEY=""; else KEY=${KEY#*:}; fi ;;
esac
case "$KEY" in issue-[1-9]*|scratch-[1-9]*) ;; *) KEY="" ;; esac
case "${KEY#*-}" in *[!0-9]*) KEY="" ;; esac
if [ -z "$SESS" ] || [ -z "$KEY" ]; then
  printf 'usage: fleet-worker-stop.sh <session> [<repo>:]<issue-N|scratch-N>\n' >&2; exit 2
fi
fleet_load_conf "$SESS"
SOCK=$(fleet_socket "$SESS")
TM() { tmux -L "$SOCK" "$@"; }
# Sanctioned keystrokes (issue #437): the ONLY keys ever typed are Escape, `/exit`
# and Enter, at a window this script resolved itself a moment earlier.
SK() { FLEET_ALLOW_SENDKEYS=1 tmux -L "$SOCK" send-keys "$@"; }
EXIT_WAIT="${FLEET_STOP_EXIT_WAIT:-30}"     # s to wait for the agent to exit
CLOSE_WAIT="${FLEET_STOP_CLOSE_WAIT:-15}"   # s to wait for the SessionEnd hook to close the window

wopt() { TM display-message -p -t "$1" "$2" 2>/dev/null; }
# agent_alive <pid> — 0 iff the process exists AND is not a zombie. tmux 3.4 on
# Linux can lose SIGCHLD (issue #781): an agent that has exited then lingers as
# a zombie that still answers `kill -0`, so a liveness read must also consult
# `ps stat=` and treat Z as gone — otherwise a finished exit reads as no-exit.
agent_alive() {
  kill -0 "$1" 2>/dev/null || return 1
  local st; st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')
  case "$st" in Z*) return 1 ;; esac
  return 0
}
# window_closed <wid> — 0 iff the window is gone OR has no live pane (a dead
# remain-on-exit pane is "closed" for our purposes: nothing to type into).
window_closed() {
  local o; o=$(TM display-message -p -t "$1" '#{pane_pid}|#{pane_dead}' 2>/dev/null) || return 0
  case "$o" in ''|'|'*|*'|1') return 0;; esac
  return 1
}

# --- 1. resolve the key → exactly one live window ------------------------------
# One display-message per field, not a joined format split on a control byte:
# tmux ≤3.4 vis-escapes 0x1f in format output (memory: tmux-34-escapes-control-bytes).
found=''; count=0
while read -r wid; do
  [ -n "$wid" ] || continue
  iss=$(wopt "$wid" '#{@issue}'); iss="${iss//[^0-9]/}"
  k=''
  if [ -n "$iss" ]; then k="issue-$iss"
  elif [ "$(wopt "$wid" '#{@raw}')" = 1 ]; then
    wt=$(wopt "$wid" '#{@worktree}'); [ -n "$wt" ] || wt=$(wopt "$wid" '#{pane_current_path}')
    k=$(fleet_scratch_key "$wt")
  fi
  [ "$k" = "$KEY" ] || continue
  [ -z "$WREPO" ] || [ "$(fleet_window_repo "$SESS" "$wid")" = "$WREPO" ] || continue
  count=$((count + 1)); found="$wid"
done <<EOF
$(TM list-windows -t "=$SESS" -F '#{window_id}' 2>/dev/null)
EOF
[ "$count" -eq 0 ] && { printf 'refused:not-found\n'; exit 5; }
[ "$count" -gt 1 ] && { printf 'refused:ambiguous\n'; exit 6; }
wid="$found"
# The stopped window's OWN repo for the ledger row (issue #791). An unknown/no-repo
# window leaves FLEET_REPO/FLEET_MAIN unset, so its row lands in no guessed ledger.
fleet_load_window_conf "$SESS" "$wid" || :
# Hibernation owns the pane: its input is disabled and the agent is parked
# (issue #808). Typing /exit there would either be swallowed or land in the
# placeholder shell; the sleep controller is the only thing that may act on it.
[ -n "$(wopt "$wid" '#{@worker_lifecycle}')" ] && { printf 'refused:hibernating\n'; exit 8; }

# --- 2. read what the ledger row needs WHILE the window stands ----------------
wname=$(wopt "$wid" '#{window_name}')
cwd=$(wopt "$wid" '#{pane_current_path}')
wt=$(wopt "$wid" '#{@worktree}'); [ -n "$wt" ] || wt="$cwd"
origin=$(wopt "$wid" '#{@origin}')
agent=$(wopt "$wid" '#{@cc_agent}')
iss=''; case "$KEY" in issue-*) iss="${KEY#issue-}" ;; esac
cpid=$(fleet_pane_claude_pid "$wid" "$SOCK" 2>/dev/null) || cpid=''

# record_row — the closed-unlanded /fleet-history row for the paths where no
# SessionEnd hook writes one. Idempotent (record-closed dedups on session /
# transcript), never fails the caller; `unmerged` is the KEEP verdict: worktree
# + branch + issue stay, the row stays resumable (issue #466/#471).
record_row() {
  [ -n "${FLEET_REPO:-}" ] || ! fleet_has_repo_overlays "$SESS" || return 0
  fleet_reap_record unmerged "${FLEET_REPO:-}" "${FLEET_MAIN:-}" "$iss" "$wt" "$wid" \
    "$SESS" "" "$KEY" "$wname" "$origin" >/dev/null 2>&1 || :
}

if [ -z "$cpid" ]; then
  # No agent under the pane (a spawn parked at its shell, a crashed session): the
  # window holds nothing to exit. Index it, then close the shell-only window.
  record_row
  TM kill-window -t "$wid" 2>/dev/null || :
  printf 'stopped:shell\n'; exit 0
fi

# --- 3. ask the agent to exit, then WAIT for it ---------------------------------
SK -t "$wid" Escape 2>/dev/null; sleep 0.6
if [ "$agent" = codex ]; then
  # Codex takes its slash command inside a bracketed paste (fleet-sleep.py does
  # the same); Claude takes it as typed.
  SK -t "$wid" -l $'\e[200~/exit\e[201~' 2>/dev/null
else
  SK -t "$wid" -l '/exit' 2>/dev/null
fi
sleep 0.6; SK -t "$wid" Enter 2>/dev/null
alive=1
for ((i = 1; i <= EXIT_WAIT; i++)); do
  agent_alive "$cpid" || { alive=0; break; }
  # the slash-command menu may have swallowed the first Enter: one more at 6s
  [ "$i" = 6 ] && ! window_closed "$wid" && SK -t "$wid" Enter 2>/dev/null
  sleep 1
done
if [ "$alive" = 1 ]; then
  printf 'failed:no-exit\n'; exit 7
fi

# --- 4. the SessionEnd hook closes the window and records the row … -----------
for ((i = 1; i <= CLOSE_WAIT; i++)); do
  window_closed "$wid" && break
  sleep 1
done
if window_closed "$wid"; then
  # The hook recorded the row; record_row is idempotent (record-closed dedups on
  # the session / transcript), so this is a no-op then and the row itself when
  # the window went away without a hook. A window object can outlive its last
  # pane for a few seconds (the pane died before the hook's detached kill-window
  # ran); reap the pane-less ghost so the dash never shows it — nothing runs in
  # it, so this is not a destructive kill.
  record_row
  TM kill-window -t "$wid" 2>/dev/null || :
  printf 'stopped:exit\n'; exit 0
fi
# … or it doesn't (FLEET_CLOSE_ON_EXIT=0): the agent is verified gone and the
# pane sits at its `exec $SHELL`. Never close a pane a NEW agent came back under.
if fleet_pane_claude_pid "$wid" "$SOCK" >/dev/null 2>&1; then
  printf 'failed:no-exit\n'; exit 7
fi
record_row
TM kill-window -t "$wid" 2>/dev/null || :
printf 'stopped:closed\n'; exit 0
