#!/bin/bash
# dash-popup.sh [--size S|M|L] [--title T] [--object O] [--client C] [--no-inline]
#               [-w <width>] [-h <height>] -- <command> [args…]
#
# THE way a fleet popup opens (issue #448; the one frame since #1535, EPIC #1529
# E6 — no script, bind or conf line calls `display-popup` but this one, and
# dash-popup-selftest.sh greps for one). Every popup gets the same frame:
#
#   ┌─ 动作 · 对象 · 机器 ─────────────────── Esc 关闭 ─┐
#
#   --size S|M|L   the three sizes (S a one-question prompt, M a table, L a
#                  list / sheet); -w / -h still override either axis
#   --title T      the action; a fleet-ui-lang.sh key is translated (popup_keys
#                  → 快捷键 / Keys), any other text is shown as given
#   --object O     what it acts on (a task, a machine) — optional
#                  the machine is appended only when the hub is on (the sidebar's
#                  remote cache names this machine, `#me`); one machine needs no
#                  name, so a hub-off login's titles stay 「动作 · 对象」
#   The close hint is the title row's right end: tmux draws a popup's title on
#   its top border only, so that is where 「Esc 关闭」 can sit on every popup.
#   --client C     draw on this client (a tmux bind passes '#{client_name}');
#                  default: resolved as below
#   --no-inline    a refused popup is NOT run in the caller's pane — for a bind's
#                  `run-shell -b` (no terminal to fall back to) or a caller that
#                  has its own fallback: toast why and exit 3
#
# It gives an in-pane popup the two things a `prefix`-bound popup gets for free
# and a raw `tmux display-popup` in an fzf `execute()` bind never had:
#
#   1. AN EXPLICIT CLIENT (the reported bug). `display-popup` has to draw on a
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
#      `display-popup` DOES NOT report a refusal: when it declines to open, tmux
#      exits **0** and prints NOTHING, and the command never runs. (tmux returns
#      CMD_RETURN_NORMAL on a failed popup_display() — verified on 3.5a: with an
#      overlay already up, `display-popup -E … 'echo ran >> log'` gives rc 0, empty
#      stderr, and no `ran`.) So the exit status cannot tell "shown" from "silently
#      dropped", and the `&& exit 0` this script used to end on treated a dropped
#      popup as a success — the keystroke was dead again, invisibly, which is the
#      `?` bug reported after #448/#450 closed the no-client half.
#      THE REFUSAL THAT BITES IS NESTING: a client may hold exactly ONE overlay, so
#      any popup already up on it (a prefix+b backlog modal / prefix+c config modal
#      / prefix+? sheet, a menu, the dash itself running as a POPUP peek) makes the
#      next `display-popup` a no-op. tmux offers no "did it open?" query, so we make
#      success OBSERVABLE instead of inferred: the popup's FIRST act is to drop a
#      marker file. Marker present when display-popup returns ⇒ it really ran (it
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

W=""; H=""; SIZE=""; TITLE=""; OBJECT=""; CLIENT=""; NO_INLINE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -w) shift; W="${1:-}" ;;
    -h) shift; H="${1:-}" ;;
    --size) shift; SIZE="${1:-}" ;;
    --title) shift; TITLE="${1:-}" ;;
    --object) shift; OBJECT="${1:-}" ;;
    --client) shift; CLIENT="${1:-}" ;;
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

# NB the ${geom[@]+…} guard: macOS ships bash 3.2, where `set -u` treats an EMPTY
# array's "${geom[@]}" as an unbound variable and aborts. Both call sites pass -w/-h,
# but the helper must not detonate for one that doesn't.
geom=()
[ -n "$W" ] && geom+=(-w "$W")
[ -n "$H" ] && geom+=(-h "$H")

# One shell-command string (display-popup takes exactly one). %q-quote each token
# so a title/path with a space or metachar survives both the popup and the
# inline fallback intact.
cmd=$(printf '%q ' "$@")
# tmux gives a popup $TMUX but NO $TMUX_PANE. Every pane-identity read in the
# fleet (fleet_pane_fmt: fleet-comment.sh's sender, fleet_seat, …) refuses
# rather than fall back to "the current pane" (issue #1537 ④), so the popup
# inherits THIS pane's id — the dash pane the popup was opened from, which is the
# identity its command is acting as.
[ -n "${TMUX_PANE:-}" ] && cmd="TMUX_PANE=$(printf '%q' "$TMUX_PANE") $cmd"

# This pane's session. `display-message -p` PRINTS (it does not need a client of
# its own), so this resolves even when nothing is attached — which is the case we
# are here to handle. A bind's run-shell names its client instead: that client's
# session.
if [ -n "$CLIENT" ]; then
  sess=$(tmux display-message -p -c "$CLIENT" '#{?#{session_group},#{session_group},#{session_name}}' 2>/dev/null)
else
  sess=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{?#{session_group},#{session_group},#{session_name}}' 2>/dev/null)
fi

# Most-recently-active client attached to THIS session. Sorting by
# #{client_activity} is what demotes a ghost client (a dropped Termius session
# tmux has not reaped yet) below the one the operator is really looking at.
client=$CLIENT
[ -z "$client" ] && [ -n "$sess" ] && client=$(tmux list-clients -t "$sess" \
  -F '#{client_activity} #{client_name}' 2>/dev/null \
  | sort -rn | head -1 | cut -d' ' -f2-)

# The title row (issue #1535): 「动作 · 对象 · 机器」 left, 「Esc 关闭」 right.
# Every string from the one table; the machine from the sidebar's own cache
# (never the network). It is a tmux FORMAT, so a literal # doubles.
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
  geom+=(-T "#[align=left] $(printf '%s' "$title" | sed 's/#/##/g') #[align=right]#[dim] $(fleet_ui_t ui_close) ")
fi

# The did-it-run marker (see 3 above). A plain $$-suffixed path, not mktemp: it
# must NOT exist up front (existence IS the signal) and one path per process is
# already unique. Removed on every exit path so a dash pane never accretes them.
marker="${TMPDIR:-/tmp}/.dash-popup-ran.$$"
rm -f "$marker" 2>/dev/null || true

if [ -n "$client" ]; then
  trap 'rm -f "$marker" 2>/dev/null; tmux set -g @popup_open 0 \; set -gu @popup_pid 2>/dev/null || true' EXIT INT TERM HUP
  # `@popup_pid <epoch>:<pid>` names the holder of THIS epoch (issue #1536): the
  # sidebar pauses only while this process lives, so a holder SIGKILLed past
  # its trap (or a flag that outlived its popup) frees the list at once, not 30s on.
  epoch=$(date +%s)
  tmux set -g @popup_open "$epoch" \; set -g @popup_pid "$epoch:$$" 2>/dev/null || true
  # Stamp the marker INSIDE the popup, ahead of the real command, so its presence
  # proves the popup opened and started running. display-popup -E blocks until the
  # popup closes, so the check below is not racing it.
  tmux display-popup -c "$client" -E ${geom[@]+"${geom[@]}"} \
    "$(printf 'printf 1 > %q; ' "$marker")$cmd"
  # Ran ⇒ done. NB we test the MARKER, never tmux's exit status: a refused popup
  # exits 0 too, and trusting that is exactly the bug (issue #454).
  [ -e "$marker" ] && exit 0
  # Refused (an overlay already on this client, the client vanished mid-flight, …)
  # — fall through to inline rather than leaving the keystroke dead.
  tmux set -g @popup_open 0 \; set -gu @popup_pid 2>/dev/null || true
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
