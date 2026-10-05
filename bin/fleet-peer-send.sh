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
#             scratch-<N>                               → the window running that scratch
#             @<window-id> / %<pane-id>                 → the Claude under that pane
#             <pid>                                     → that Claude process
#             <session-uuid>                            → the process running it
#             wid:<worker_id> / wid:<key>               → that worker, wherever it lives
#   <text>    the message; `-` or omitted → read stdin (multi-line ok)
#   -L        tmux socket label for a tmux target when run outside the fleet
#             ($TMUX unset); inside a pane bare tmux is already the right server.
#             An identity target with neither -L nor $TMUX searches every fleet.
#   --repo    which repo's #N (REQUIRED in a fleet hosting 2+ repos)
#   --expect-issue  refuse unless the @id / %pane window carries @issue=<N>
#   REFUSED (exit 2): `<sess>:<idx>` / `<sess>:<name>` positions and bare window
#   names — a position renumbers under you, a name is prefix-matched by tmux.
#
# ONE RESOLVER (issues #1046, #1537). `<sess>:<idx>` is a POSITION: a window
# closing renumbers every window after it (renumber-windows on), so an index read
# a few minutes ago — or copied out of a handoff doc — silently lands on a
# DIFFERENT worker; a window NAME is prefix-matched (scratch-1 → scratch-12). Both
# refuse. `issue:<N>` / `scratch-<N>` go through fleet_win_for_key (fleet-lib.sh):
# exactly one live window, never a warm-pool one, never another repo's #N — zero
# or several matches refuse. `--expect-issue` pins an @id / %pane target.
#
# `wid:<fleet UUID>/<key>` (issue #1420) is the address that survives a machine
# boundary (docs/FLEET-HUB.md «Worker identity»); fleet_worker_locate resolves it.
# Since issue #1646 its lifelong form is `wid:<fleet UUID>/<fleet_id>` (the
# window's @fleet_id — it survives a rename, a restore, a migrate and a move);
# the key form stays an alias.
# Live on this machine → the window it found, then the path below as for any
# window. On another machine → the hub (issue #1421). Nowhere → exit 1; never a
# local window that merely shares the issue number.
#
# THREE OUTCOMES (issue #1647, EPIC #1645 rule 3), exactly one line, always:
#   sent → … (<window> · <worktree>)   exit 0 — it reached the recipient's inbox
#                                      (across machines: the hub's receipt said so)
#   queued → … — <why>                 exit 3 — it WAITS for the recipient: a sleeper
#                                      at a full fleet, a window with no live Claude or
#                                      an inbox that will not answer (this fleet's peer
#                                      queue, bin/fleet-peer-queue.sh, by the window's
#                                      @fleet_id), or a worker elsewhere whose machine
#                                      is offline / not in a fresh map / has not
#                                      answered yet (the hub holds it for its identity).
#                                      Delivered when it can be; EXPIRED after 7 days in
#                                      this fleet's delivery book.
#   one line on stderr                 exit 1 — refused: not found / ambiguous / not a
#                                      live session; nothing waits. 2 = usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-peer-send: %s\n' "$(printf '%s' "$2" | tr '\n' ' ' | sed 's/ *$//')" >&2; exit "$1"; }
usage() { sed -n '9,26p' "$0" >&2; exit 2; }

SOCK=""; EXPECT=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -L) SOCK="${2:-}"; shift 2 ;;
    -L*) SOCK="${1#-L}"; shift ;;
    --expect-issue) EXPECT="${2:-}"; shift 2 ;;
    --expect-issue=*) EXPECT="${1#*=}"; shift ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --repo=*) REPO="${1#*=}"; shift ;;
    -h|--help) sed -n '2,56p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
case "$EXPECT" in ''|[0-9]*) ;; *) die 2 "--expect-issue wants an issue number, got '$EXPECT'" ;; esac
case "$EXPECT" in *[!0-9]*) die 2 "--expect-issue wants an issue number, got '$EXPECT'" ;; esac
tgt="${1:-}"; [ -n "$tgt" ] || usage
shift
if [ $# -eq 0 ] || [ "$1" = "-" ]; then text=$(cat); else text="$*"; fi
[ -n "$text" ] || die 2 "empty message"

# --- worker_id → where it lives (issue #1420) -------------------------------------
case "$tgt" in
  wid:*)
    loc=$(fleet_worker_locate "$tgt" "$SOCK"); rc=$?
    case "$loc" in
      local\ *) loc=${loc#local }; tgt=${loc%% *}; SOCK=$(fleet_socket "${loc#* }") ;;
      *)
        # Another machine (issue #1421): through the hub. The full worker_id comes
        # from the hub map — or, when the map is stale, from the target itself: a
        # `<fleet UUID>/…` naming no fleet of this machine is all the hub routes on
        # (issue #1647), and it holds the message until that worker is live.
        node=''; full=''
        case "$loc" in remote\ *) node=${loc#remote } ;; esac
        if [ -n "$node" ]; then
          sp=$(_fleet_wid_split "$tgt"); full=$(fleet_hub_wid "${sp%%$'\t'*}" "${sp#*$'\t'}") \
            || die 1 "'$tgt' lives on ${node%:lost}, but the hub map has no full worker_id for it; nothing sent"
        elif [ "$rc" -ne 2 ] && [ "${CCQUOTA_FLEET:-0}" = 1 ]; then
          case "${tgt#wid:}" in ?*/?*) fleet_wid_home "$tgt" >/dev/null 2>&1 || full=${tgt#wid:} ;; esac
        fi
        if [ -z "$full" ]; then
          [ "$rc" -eq 2 ] && die 2 "bad worker id '$tgt' (want wid:<fleet UUID>/<fleet_id>, wid:<fleet UUID>/issue-<N>, wid:issue-<N> or wid:scratch-<N>)"
          die 1 "no live worker for '$tgt' on this machine; nothing sent"
        fi
        where=${node%:lost}; where=${where:-another machine}
        # The sender is THIS pane's worker, or nobody — a message needs a from the
        # hub can check belongs to this machine. It rides as its readable
        # `<fleet UUID>/<key>` (issue #1646): `from` labels the message and keys its
        # idempotency; it is never an address.
        me=''; mysess=$(fleet_current_session 2>/dev/null)
        [ -n "${TMUX_PANE:-}" ] && me=$(fleet_worker_id_key "$mysess" "$TMUX_PANE" 2>/dev/null)
        [ -n "$me" ] || die 1 "'$tgt' lives on $where — a cross-machine message must come from a worker or scratch pane (its worker_id is the sender); nothing sent"
        payload=$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}, ensure_ascii=False))' "$text") \
          || die 1 "could not encode the message"
        suf="$(date +%s).$$"
        f=$(fleet_hub_put message "$me" "$full" "$suf" "$payload") \
          || die 1 "'$tgt' lives on $where — the hub outbox is not available (CCQUOTA_FLEET=1 and a running ccquota agent carry it); nothing sent"
        # Sent only on the hub's receipt that the recipient's machine delivered it.
        if fleet_hub_wait_sent "$f" 3; then
          case "$node" in
            '') how='its machine is not in a fresh hub map' ;;
            *:lost) how='its machine is offline' ;;
            *) if bash "$BIN/fleet-peer-queue.sh" wait -L "$mysess" --rid "$me#$suf" \
                    --secs "${FLEET_HUB_RECEIPT_WAIT:-4}" >/dev/null 2>&1; then
                 printf 'sent → %s on %s (delivered)\n' "${full#*/}" "$node"
                 exit 0
               fi
               how='not delivered yet' ;;
          esac
        else
          how='the hub is not reachable from here; this machine sends it when it is'
        fi
        bash "$BIN/fleet-peer-queue.sh" note -L "$mysess" --rid "$me#$suf" --state QUEUED --to "$full" \
          --kind message --via hub --detail "$how" 2>/dev/null || :
        printf 'queued → %s%s（对方不在线，上线后补送 · %s）\n' "${full#*/}" "${node:+ on ${node%:lost}}" "$how"
        exit 3 ;;
    esac ;;
esac

# --- identity → one live window (issues #1046, #1537) -----------------------------
# ONE resolver, fleet_win_for_key: issue:<N> / #<N> / issue-<N> → the key
# `issue-<N>` (`<slug>:issue-<N>` with --repo, and a 2+ repo fleet REFUSES the bare
# key); scratch-<N> → the window whose @worktree is that scratch. A warm-pool window
# never answers, two windows answering is a refusal, and the id it hands back is
# stable for the window's whole life, so the send below cannot drift onto a
# neighbour. A `<sess>:<idx>` position and a bare window NAME are not addresses.
key=""; want_issue=""
case "$tgt" in
  issue:*|issue-*|'#'*)
    want_issue="${tgt#issue:}"; want_issue="${want_issue#issue-}"; want_issue="${want_issue#\#}"
    case "$want_issue" in ''|*[!0-9]*) die 2 "bad issue target '$tgt' (want issue:<N>, #<N> or issue-<N>)" ;; esac
    key="issue-$want_issue" ;;
  scratch-*)
    case "${tgt#scratch-}" in ''|*[!0-9]*) die 2 "bad scratch target '$tgt' (want scratch-<N>)" ;; esac
    key="$tgt" ;;
  @*|%*|*-*-*-*-*) ;;
  *:*) die 2 "'$tgt' is a window position or name (<sess>:<idx> / <sess>:<name>) — a closing window renumbers it onto someone else; address the worker as issue:<N>, scratch-<N> or wid:<key>" ;;
  *[!0-9]*) die 2 "'$tgt' is a window name, not an address (tmux prefix-matches names); use issue:<N>, scratch-<N> or wid:<key>" ;;
esac
if [ -n "$key" ]; then
  [ -n "$REPO" ] && key="$(fleet_slug "$(fleet_norm_repo "$REPO")"):$key"
  if [ -n "$SOCK" ]; then socks="$SOCK"
  elif [ -n "${TMUX:-}" ]; then socks="-"          # bare tmux: this pane's own server
  else socks=$(fleet_sockets); fi
  hits=""; why=""
  errf=$(mktemp "${TMPDIR:-/tmp}/fleet-peer-send.XXXXXX") || die 1 "mktemp failed"
  trap 'rm -f "$errf"' EXIT
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if [ "$s" = "-" ]; then w=$(fleet_win_for_key "$key" '' 2>"$errf"); rc=$?
    else w=$(fleet_win_for_key "$key" "$s" 2>"$errf"); rc=$?; fi
    case "$rc" in
      0) [ -n "$w" ] && hits="$hits$s|$w"$'\n' ;;
      2) why=$(sed 's/^fleet: //' "$errf" | head -1) ;;   # AMBIGUOUS: the resolver's one line
    esac
  done <<EOF
$socks
EOF
  if [ -n "$why" ]; then
    [ -n "$want_issue" ] && [ -z "$REPO" ] && why="$why — narrow with --repo <owner/name>"
    die 1 "$why"
  fi
  n=$(printf '%s' "$hits" | grep -c .)
  [ "$n" -gt 0 ] || die 1 "no live window for '$tgt'${REPO:+ in $REPO}"
  [ "$n" -eq 1 ] || die 1 "'$tgt' is ambiguous — found in $n fleets: $(printf '%s' "$hits" | cut -d'|' -f1 | paste -sd',' - | sed 's/,/, /g') (run it inside that fleet, or pass -L)"
  s=${hits%%|*}; rest=${hits#*|}; tgt=${rest%%$'\n'*}
  [ "$s" = "-" ] || SOCK="$s"
fi

tm=(tmux); [ -n "$SOCK" ] && tm+=(-L "$SOCK")
label=""
case "$tgt" in
  @*|%*)
    info=$("${tm[@]}" display-message -p -t "$tgt" '#{window_name}|#{@issue}|#{pane_current_path}|#{@worktree}' 2>/dev/null)
    [ -n "$info" ] || die 1 "no live window for '$tgt'"
    wname=${info%%|*}; info=${info#*|}; wiss=${info%%|*}; info=${info#*|}; pcwd=${info%%|*}; wwt=${info#*|}
    label="$wname · ${wwt:-$pcwd}"
    if [ -n "$EXPECT" ] && [ "$wiss" != "$EXPECT" ]; then
      die 1 "refused: '$tgt' is $wname (@issue=${wiss:-none}), not #$EXPECT — the window moved; address it as issue:$EXPECT"
    fi ;;
  *) [ -z "$EXPECT" ] || die 2 "--expect-issue needs an @<window-id> or %<pane-id> target" ;;
esac

case "$tgt" in
  @*|%*)
    lifecycle=$("${tm[@]}" display-message -p -t "$tgt" '#{@worker_lifecycle}' 2>/dev/null)
    evidence=$("${tm[@]}" display-message -p -t "$tgt" '#{@sleep_evidence}' 2>/dev/null)
    if [ -n "$lifecycle$evidence" ] && [ -f "$BIN/fleet-sleep.py" ]; then
      session=$("${tm[@]}" display-message -p -t "$tgt" '#{?#{session_group},#{session_group},#{session_name}}' 2>/dev/null)
      err=$(printf '%s' "$text" | python3 "$BIN/fleet-sleep.py" deliver --session "$session" "$tgt" 2>&1 >/dev/null); rc=$?
      # A sleeper at a full fleet keeps the message and wakes when a slot frees
      # (#1058): queued, exit 3 — never «sent» (issue #1647).
      if [ "$rc" -eq 3 ]; then
        echo "queued → $tgt: fleet at its session limit; delivers when a slot frees ($label)"; exit 3
      fi
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
      @*|%*) pid=$(fleet_pane_claude_pid "$tgt" "$SOCK") ;;
      *-*-*-*-*) pid=$(fleet_cc_pid_for_session "$tgt") ;;
    esac ;;
  *) pid="$tgt" ;;
esac
# queue_here <why> — a WINDOW that cannot take it now (issue #1647): this fleet's
# peer queue holds it for the window's lifelong @fleet_id, delivered on the cleanup
# tick or its wake. A pid / session-uuid target has no identity to wait on: refused.
queue_here() {
  local s fid
  case "$tgt" in @*|%*) ;; *) die 1 "$1" ;; esac
  s=$("${tm[@]}" display-message -p -t "$tgt" "$FLEET_SESSION_FMT" 2>/dev/null)
  [ -n "$s" ] || die 1 "$1"
  fid=$(fleet_window_fid "$s" "$tgt" "$SOCK" 2>/dev/null) || die 1 "$1"
  printf '%s' "$text" | bash "$BIN/fleet-peer-queue.sh" put -L "$s" --kind message \
    --rid "local:peer#$(date +%s).$$" --to-fid "$fid" --to "${label:-$tgt}" >/dev/null || die 1 "$1"
  echo "queued → $tgt${label:+ ($label)} — $1; delivered when it can take it"
  exit 3
}
[ -n "$pid" ] || queue_here "no live Claude session for '$tgt'"
kill -0 "$pid" 2>/dev/null || queue_here "pid $pid is not running"
[ -n "$label" ] || label=$(fleet_cc_session_field "$pid" cwd 2>/dev/null || :)
if fleet_peer_send "$pid" "$text"; then
  echo "sent → pid $pid (${label:-$(fleet_cc_session_field "$pid" name 2>/dev/null || :)})"
else
  queue_here "pid $pid has no reachable inbox (not a registered session, or no key/socket)"
fi
