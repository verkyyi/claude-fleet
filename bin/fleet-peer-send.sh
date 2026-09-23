#!/bin/bash
# fleet-peer-send.sh — deliver a message to a LIVE Claude session over its local
# inbox socket: the same channel the SendMessage / ListAgents tools use between
# sessions on this machine (issue #513). The recipient sees it as a message from
# another session on its next turn (queued while it is mid-turn). This is the
# sanctioned way for fleet tooling — the quota watch, an operator script — to talk
# to a running session; raw `tmux send-keys` into a prompt is not (issue #437).
#
#   fleet-peer-send.sh [-L <socket>] [--repo <o/r>] [--expect-issue <N>] <target> [<text> | -]
#
#   <target>  issue:<N> / #<N> / issue-<N>             → the window bound to that issue
#             scratch-<N> / <window-name>               → the window with that exact name
#             @<window-id> / %<pane-id> / <sess>:<idx>  → the Claude under that pane
#             <pid>                                     → that Claude process
#             <session-uuid>                            → the process running it
#   <text>    the message; `-` or omitted → read stdin (multi-line ok)
#   -L        tmux socket label for a tmux target when run outside the fleet
#             ($TMUX unset); inside a pane bare tmux is already the right server.
#             An identity target with neither -L nor $TMUX searches every fleet.
#   --repo    narrow an issue target to one repo (a multi-repo fleet can bind #N twice)
#   --expect-issue  refuse unless the resolved window carries @issue=<N>
#
# PREFER AN IDENTITY TARGET (issue #1046). `<sess>:<idx>` is a POSITION: a window
# closing renumbers every window after it (renumber-windows on), so an index read
# a few minutes ago — or copied out of a handoff doc — silently lands on a
# DIFFERENT worker. `issue:<N>` is resolved to exactly one live window at send
# time; zero or several matches refuse. A positional target can still be pinned
# with --expect-issue.
#
# Exactly one line of outcome, always: success prints `sent → … (<window> · <worktree>)`
# on stdout and exits 0; every failure exits non-zero with ONE line on stderr.
# Exit 1 = target not found / ambiguous / refused / not a live session; 2 = usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-peer-send: %s\n' "$(printf '%s' "$2" | tr '\n' ' ' | sed 's/ *$//')" >&2; exit "$1"; }
usage() { sed -n '9,23p' "$0" >&2; exit 2; }

SOCK=""; EXPECT=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -L) SOCK="${2:-}"; shift 2 ;;
    -L*) SOCK="${1#-L}"; shift ;;
    --expect-issue) EXPECT="${2:-}"; shift 2 ;;
    --expect-issue=*) EXPECT="${1#*=}"; shift ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --repo=*) REPO="${1#*=}"; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
case "$EXPECT" in ''|[0-9]*) ;; *) die 2 "--expect-issue wants an issue number, got '$EXPECT'" ;; esac
case "$EXPECT" in *[!0-9]*) die 2 "--expect-issue wants an issue number, got '$EXPECT'" ;; esac
tgt="${1:-}"; [ -n "$tgt" ] || usage
shift
if [ $# -eq 0 ] || [ "$1" = "-" ]; then text=$(cat); else text="$*"; fi
[ -n "$text" ] || die 2 "empty message"

# --- identity → one live window (issue #1046) ------------------------------------
# Resolved NOW, off the live server, never from a remembered index. Every
# candidate is a (socket, window-id) pair; the window id is stable for the
# window's whole life, so the send below can no longer drift onto a neighbour.
want_issue=""; want_name=""
case "$tgt" in
  issue:*|issue-*|'#'*)
    want_issue="${tgt#issue:}"; want_issue="${want_issue#issue-}"; want_issue="${want_issue#\#}"
    case "$want_issue" in ''|*[!0-9]*) die 2 "bad issue target '$tgt' (want issue:<N>, #<N> or issue-<N>)" ;; esac ;;
  @*|%*|*:*|*-*-*-*-*) ;;
  *[!0-9]*) want_name="$tgt" ;;
esac
if [ -n "$want_issue$want_name" ]; then
  if [ -n "$SOCK" ]; then socks="$SOCK"
  elif [ -n "${TMUX:-}" ]; then socks="-"          # bare tmux: this pane's own server
  else socks=$(fleet_sockets); fi
  hits=""
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if [ "$s" = "-" ]; then tm=(tmux); else tm=(tmux -L "$s"); fi
    # '|'-separated (tmux <=3.4 vis-escapes control bytes); @worktree LAST so a
    # path containing '|' stays intact.
    while IFS='|' read -r wid wname wiss wraw wrepo sess wwt; do
      [ -n "$wid" ] || continue
      if [ -n "$want_issue" ]; then
        [ "$wiss" = "$want_issue" ] || continue
        if [ -n "$REPO" ]; then
          [ -n "$wrepo" ] || wrepo=$(fleet_window_repo "$sess" "$wid" 2>/dev/null)
          [ "$wrepo" = "$REPO" ] || continue
        fi
      else
        # a scratch window: its name, or (@raw) the `-scratch-<N>` worktree it runs in
        if [ "$wname" != "$want_name" ]; then
          case "$want_name" in scratch-[0-9]*) ;; *) continue ;; esac
          [ "$wraw" = 1 ] || continue
          case "$wwt" in *-"$want_name") ;; *) continue ;; esac
        fi
      fi
      hits="$hits$s|$wid|$sess:$wname${wrepo:+ ($wrepo)}"$'\n'
    done <<EOF
$("${tm[@]}" list-windows -a -F '#{window_id}|#{window_name}|#{@issue}|#{@raw}|#{@repo}|#{session_name}|#{@worktree}' 2>/dev/null)
EOF
  done <<EOF
$socks
EOF
  n=$(printf '%s' "$hits" | grep -c .)
  [ "$n" -gt 0 ] || die 1 "no live window for '$tgt'${REPO:+ in $REPO}"
  [ "$n" -eq 1 ] || die 1 "'$tgt' is ambiguous — $n windows match: $(printf '%s' "$hits" | cut -d'|' -f3 | paste -sd',' - | sed 's/,/, /g')${want_issue:+ (narrow with --repo)}"
  s=${hits%%|*}; rest=${hits#*|}; tgt=${rest%%|*}
  [ "$s" = "-" ] || SOCK="$s"
fi

tm=(tmux); [ -n "$SOCK" ] && tm+=(-L "$SOCK")
label=""
case "$tgt" in
  @*|%*|*:*)
    info=$("${tm[@]}" display-message -p -t "$tgt" '#{window_name}|#{@issue}|#{pane_current_path}|#{@worktree}' 2>/dev/null)
    [ -n "$info" ] || die 1 "no live window for '$tgt'"
    wname=${info%%|*}; info=${info#*|}; wiss=${info%%|*}; info=${info#*|}; pcwd=${info%%|*}; wwt=${info#*|}
    label="$wname · ${wwt:-$pcwd}"
    if [ -n "$EXPECT" ] && [ "$wiss" != "$EXPECT" ]; then
      die 1 "refused: '$tgt' is $wname (@issue=${wiss:-none}), not #$EXPECT — the window moved; address it as issue:$EXPECT"
    fi ;;
  *) [ -z "$EXPECT" ] || die 2 "--expect-issue needs a window target (issue:<N>, a name, @id, %pane or sess:idx)" ;;
esac

case "$tgt" in
  @*|%*|*:*)
    lifecycle=$("${tm[@]}" display-message -p -t "$tgt" '#{@worker_lifecycle}' 2>/dev/null)
    evidence=$("${tm[@]}" display-message -p -t "$tgt" '#{@sleep_evidence}' 2>/dev/null)
    if [ -n "$lifecycle$evidence" ] && [ -f "$BIN/fleet-sleep.py" ]; then
      session=$("${tm[@]}" display-message -p -t "$tgt" '#{session_name}' 2>/dev/null)
      err=$(printf '%s' "$text" | python3 "$BIN/fleet-sleep.py" deliver --session "$session" "$tgt" 2>&1 >/dev/null); rc=$?
      [ "$rc" -eq 0 ] || die 1 "${err:-sleep delivery to $tgt failed (exit $rc)}"
      echo "sent → $tgt via wake-delivery ($label)"; exit 0
    fi
    agent=$("${tm[@]}" display-message -p -t "$tgt" '#{@cc_agent}' 2>/dev/null)
    if [ "$agent" = codex ]; then
      out=$(printf '%s' "$text" | python3 "$BIN/fleet-codex-session.py" send --pane "$tgt" --socket "$SOCK" 2>&1); rc=$?
      [ "$rc" -eq 0 ] || die 1 "${out:-Codex queue to $tgt failed (exit $rc)}"
      echo "sent → codex ${out##* } ($label)"; exit 0
    fi ;;
esac

pid=""
case "$tgt" in
  ''|*[!0-9]*)
    case "$tgt" in
      @*|%*|*:*) pid=$(fleet_pane_claude_pid "$tgt" "$SOCK") ;;
      *-*-*-*-*) pid=$(fleet_cc_pid_for_session "$tgt") ;;
    esac ;;
  *) pid="$tgt" ;;
esac
[ -n "$pid" ] || die 1 "no live Claude session for '$tgt'${label:+ ($label)}"
kill -0 "$pid" 2>/dev/null || die 1 "pid $pid is not running"
[ -n "$label" ] || label=$(fleet_cc_session_field "$pid" cwd 2>/dev/null || :)
if fleet_peer_send "$pid" "$text"; then
  echo "sent → pid $pid (${label:-$(fleet_cc_session_field "$pid" name 2>/dev/null || :)})"
else
  die 1 "pid $pid has no reachable inbox (not a registered session, or no key/socket)"
fi
