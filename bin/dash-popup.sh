#!/bin/bash
# dash-popup.sh [--size S|M|L] [--title T] [--object O] [--client C] [--no-inline]
#               [-w <width>] [-h <height>] -- <command> [args…]
#
# THE way a fleet popup opens (issue #448; the one frame since #1535, EPIC #1529
# E6; one style since #1619). A script or bind opens a popup through here (a
# script may say `fleet_popup`, which calls this); the draw itself is
# bin/fleet-popup-lib.sh's, the only place tmux's popup command is spelled —
# dash-popup-selftest.sh greps for a second one. Every popup gets the same frame:
#
#   ╭──────────── 动作 · 对象 · 机器 ────────────╮      rounded, PAL_DIM
#   │ …                                          │
#   │  ↵ … · [✕ 关闭]                            │      the fzf's key line
#   ╰────────────────────────────────────────────╯
#
#   --size S|M|L   the three sizes (S a one-question prompt, M a table, L a
#                  list / sheet); -w / -h still override either axis
#   --title T      the action; a fleet-ui-lang.sh key is translated (popup_keys
#                  → 快捷键 / Keys), any other text is shown as given
#   --object O     what it acts on (a task, a machine) — optional
#                  the machine is appended only when the hub is on (the sidebar's
#                  remote cache names this machine, `#me`); one machine needs no
#                  name, so a hub-off login's titles stay 「动作 · 对象」
#   The key hints are the body's bottom line (fleet_fzf_hint, issue #1619): a
#   title shares its border with nothing, so on a 54-column client it is whole.
#   A client 80 columns or narrower gets 96% × 90% whatever the size.
#   --client C     draw on this client (a tmux bind passes '#{client_name}');
#                  default: resolved as below
#   --session S    the session the popup belongs to, when the caller already
#                  knows it (saves the read that would ask tmux; issue #1611)
#   --no-inline    a refused popup is NOT run in the caller's pane — for a bind's
#                  `run-shell -b` (no terminal to fall back to) or a caller that
#                  has its own fallback: toast why and exit 3
#
# It gives an in-pane popup the two things a `prefix`-bound popup gets for free
# and a raw a tmux popup in an fzf `execute()` bind never had:
#
#   1. AN EXPLICIT CLIENT (the reported bug). tmux's popup command has to draw on a
#      CLIENT. A prefix bind runs FROM the client that pressed the key, so tmux
#      always knows which one. A command run from a PANE PROCESS arrives on the
#      socket with no client of its own, so tmux must GUESS — and when it can't it
#      exits 1 with "no current client" and draws nothing. Inside `execute()` that
#      error goes nowhere the operator can see (the dash's own stdout/stderr are
#      /dev/null), so the keystroke looks DEAD. That is exactly the reported `?`
#      symptom, and exactly why it is INTERMITTENT: it works while a client is
#      cleanly attached and silently no-ops across a Termius drop / reconnect /
#      detached hub. We resolve the client ourselves — the most-recently-ACTIVE
#      one attached to this pane's session, so a stale ghost client left behind by
#      a dropped connection loses to the live one.
#      (`-t <pane>` does NOT help: it is position context, not client resolution.)
#   2. THE @popup_open EPOCH (issues #308/#431). A tmux popup is a client-side
#      overlay that does NOT freeze the panes under it, so the dash's 1Hz reload
#      keeps repainting beneath it and that churn flashes through the popup. The
#      modal prefix binds raise the flag for the popup's lifetime
#      (conf/tmux-attention.conf); the raw in-pane popups never did. Set as an
#      EPOCH, cleared to 0 on the way out via a trap, so an interrupted popup
#      cannot strand it (and dash-popup-wait.sh ages out whatever leaks anyway).
#
#   3. PROOF THAT THE POPUP ACTUALLY RAN (issue #454 — the second silent no-op).
#      tmux's popup command DOES NOT report a refusal: when it declines to open, tmux
#      exits **0** and prints NOTHING, and the command never runs. (tmux returns
#      CMD_RETURN_NORMAL on a failed popup_display() — verified on 3.5a: with an
#      overlay already up, a popup `-E … 'echo ran >> log'` gives rc 0, empty
#      stderr, and no `ran`.) So the exit status cannot tell "shown" from "silently
#      dropped", and the `&& exit 0` this script used to end on treated a dropped
#      popup as a success — the keystroke was dead again, invisibly, which is the
#      `?` bug reported after #448/#450 closed the no-client half.
#      THE REFUSAL THAT BITES IS NESTING: a client may hold exactly ONE overlay, so
#      any popup already up on it (a prefix+b backlog modal / prefix+c config modal
#      / prefix+? sheet, a menu, the dash itself running as a POPUP peek) makes the
#      next tmux's popup command a no-op. tmux offers no "did it open?" query, so we make
#      success OBSERVABLE instead of inferred: the popup's FIRST act is to drop a
#      marker file. Marker present when the popup command returns ⇒ it really ran (it
#      blocks until the popup closes, so there is no race); marker absent ⇒ it was
#      dropped ⇒ fall back to inline. One check covers EVERY refusal reason —
#      today's nesting and whatever tmux declines next — instead of enumerating them.
#
# NO-CLIENT / REFUSED FALLBACK: when no client can be resolved, or the popup was
# refused, run the command INLINE in the pane instead of vanishing. fzf's `execute`
# hands us the terminal for the duration and repaints after we return — which is
# precisely the contract this needs — so the fallback is a real path, not a
# consolation prize: `?` still shows the cheatsheet, ⌃n still files an issue. The
# invariant this script buys is that a dash popup bind NEVER silently does nothing.
#
# Bare `tmux` on purpose: run from the dash pane it inherits $TMUX and so targets
# THIS fleet's socket (issue #159).
set -u

W=""; H=""; SIZE=""; TITLE=""; OBJECT=""; CLIENT=""; NO_INLINE=""; SESSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    -w) shift; W="${1:-}" ;;
    -h) shift; H="${1:-}" ;;
    --size) shift; SIZE="${1:-}" ;;
    --title) shift; TITLE="${1:-}" ;;
    --object) shift; OBJECT="${1:-}" ;;
    --client) shift; CLIENT="${1:-}" ;;
    --session) shift; SESSION="${1:-}" ;;
    --no-inline) NO_INLINE=1 ;;
    --) shift; break ;;
    *)  break ;;
  esac
  shift
done
[ $# -gt 0 ] || { echo "dash-popup.sh: no command" >&2; exit 2; }

# The three sizes (issue #1535). -w / -h given beside --size win on their axis.
case "$SIZE" in
  S) [ -n "$W" ] || W=84%; [ -n "$H" ] || H=16 ;;
  M) [ -n "$W" ] || W=86%; [ -n "$H" ] || H=60% ;;
  L) [ -n "$W" ] || W=94%; [ -n "$H" ] || H=86% ;;
  '') ;;
  *) echo "dash-popup.sh: --size is S, M or L" >&2; exit 2 ;;
esac

BIN="$(cd "$(dirname "$0")" && pwd)"

# One shell-command string (the popup command takes exactly one). %q-quote each token
# so a title/path with a space or metachar survives both the popup and the
# inline fallback intact.
cmd=$(printf '%q ' "$@")
# tmux gives a popup $TMUX but NO $TMUX_PANE. Every pane-identity read in the
# fleet (fleet_pane_fmt: fleet-comment.sh's sender, fleet_seat, …) refuses
# rather than fall back to "the current pane" (issue #1537 ④), so the popup
# inherits THIS pane's id — the dash pane the popup was opened from, which is the
# identity its command is acting as.
[ -n "${TMUX_PANE:-}" ] && cmd="TMUX_PANE=$(printf '%q' "$TMUX_PANE") $cmd"
# The ⌂ latency trace (issue #1611) crosses the same way — the popup's command
# starts from the SERVER's environment, not ours. No trace ⇒ nothing added.
. "$BIN/fleet-trace-lib.sh"

# This pane's session. `display-message -p` PRINTS (it does not need a client of
# its own), so this resolves even when nothing is attached — which is the case we
# are here to handle. A bind's run-shell names its client instead: that client's
# session, read in the same call as its width (the frame's narrow-screen size,
# issue #1619).
cw=''
if [ -n "$CLIENT" ]; then
  IFS='|' read -r cw s2 <<EOF_CW
$(tmux display-message -p -c "$CLIENT" '#{client_width}|#{?#{session_group},#{session_group},#{session_name}}' 2>/dev/null)
EOF_CW
  sess=${SESSION:-$s2}
elif [ -n "$SESSION" ]; then
  sess=$SESSION
else
  sess=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{?#{session_group},#{session_group},#{session_name}}' 2>/dev/null)
fi

# Most-recently-active client attached to THIS session. Sorting by
# #{client_activity} is what demotes a ghost client (a dropped Termius session
# tmux has not reaped yet) below the one the operator is really looking at.
client=$CLIENT
if [ -z "$client" ] && [ -n "$sess" ]; then
  # `<name> <width>` after the activity; a line with no width is a bare name
  client=$(tmux list-clients -t "$sess" -F '#{client_activity} #{client_name} #{client_width}' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)
  case "$client" in *' '*) cw=${client##* }; client=${client% *} ;; esac
fi

# The title (issue #1535): 「动作 · 对象 · 机器」, centred on the top border
# (issue #1619 — the key hints are the body's bottom line now, fleet_fzf_hint).
# Every string from the one table; the machine from the sidebar's own cache
# (never the network). fleet_popup_title makes it a tmux format (# doubles).
. "$BIN/fleet-ui-lang.sh"
fleet_ui_pin
title=''
if [ -n "$TITLE" ]; then
  title=$(fleet_ui_t "$TITLE")
  [ -z "$OBJECT" ] || title="$title · $OBJECT"
  me=''
  if [ -n "$sess" ]; then
    # shellcheck disable=SC2034  # read by the lib sourced on the next line
    FLEET_STATUS_G="${TMPDIR:-/tmp}/.claude-dash/global"; . "$BIN/fleet-status-lib.sh"
    fleet_status_remote_head "$sess" && me=$FSR_ME
  fi
  [ -z "$me" ] || title="$title · $me"
fi
. "$BIN/fleet-popup-lib.sh"

# The did-it-run marker (see 3 above). A plain $$-suffixed path, not mktemp: it
# must NOT exist up front (existence IS the signal) and one path per process is
# already unique. Removed on every exit path so a dash pane never accretes them.
marker="${TMPDIR:-/tmp}/.dash-popup-ran.$$"
rm -f "$marker" 2>/dev/null || true

if [ -n "$client" ]; then
  trap 'rm -f "$marker" 2>/dev/null; tmux set -g @popup_open 0 \; set -gu @popup_pid \; set -gu @popup_title 2>/dev/null || true' EXIT INT TERM HUP
  # `@popup_pid <epoch>:<pid>` names the holder of THIS epoch (issue #1536): the
  # sidebar pauses only while this process lives, so a holder SIGKILLed past
  # its trap (or a flag that outlived its popup) frees the list at once, not 30s on.
  epoch=$(date +%s)
  # `@popup_title` (issue #1951): WHICH popup — the client's bar says its keys.
  tmux set -g @popup_open "$epoch" \; set -g @popup_pid "$epoch:$$" \; set -g @popup_title "${TITLE:-}" 2>/dev/null || true
  # Stamp the marker INSIDE the popup, ahead of the real command, so its presence
  # proves the popup opened and started running. the popup blocks until the
  # popup closes, so the check below is not racing it. (Kept as its own tmux call:
  # dash-popup-selftest.sh's shims dispatch on the subcommand.)
  fleet_home_mark popup
  [ -z "${FLEET_HOME_MS:-}" ] || cmd="FLEET_HOME_MS=$(printf '%q' "$FLEET_HOME_MS") $cmd"
  fleet_popup_draw "$client" "$cw" "$title" "$(printf 'printf 1 > %q; ' "$marker")$cmd" "$W" "$H"
  # Ran ⇒ done. NB we test the MARKER, never tmux's exit status: a refused popup
  # exits 0 too, and trusting that is exactly the bug (issue #454).
  [ -e "$marker" ] && exit 0
  # Refused (an overlay already on this client, the client vanished mid-flight, …)
  # — fall through to inline rather than leaving the keystroke dead.
  tmux set -g @popup_open 0 \; set -gu @popup_pid \; set -gu @popup_title 2>/dev/null || true
  trap - EXIT INT TERM HUP
fi

# No client to draw a popup on — or the popup was refused. --no-inline: there is
# no pane of ours to run it in (a bind's run-shell -b), so say so where the
# operator is looking and let the caller decide (exit 3).
if [ -n "$NO_INLINE" ]; then
  rm -f "$marker" 2>/dev/null || true
  [ -z "$client" ] || tmux display-message -c "$client" "$(fleet_ui_t popup_refused)" 2>/dev/null || true
  exit 3
fi
# Otherwise run it right here in the pane. fzf repaints over us when we return.
# `exec` replaces this shell, so no EXIT trap can fire afterwards: clear the
# marker now.
rm -f "$marker" 2>/dev/null || true
exec bash -c "$cmd"
