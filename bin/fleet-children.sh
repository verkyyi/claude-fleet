#!/bin/bash
# fleet-children.sh — what are MY children doing? (issue #937)
#
#   fleet-children.sh [<parent-key>] [--json] [--since <seq>] [-L <socket>]
#
# One line per child session this parent spawned (grandchildren included — they
# count toward the ultimate parent, #624's attribution), then one summary line:
#
#   children of scratch-29 · fleet-claude-fleet
#     ! issue-104        @5 needs           BLOCKED 3m             kid-needs
#     ▸ issue-103        @4 working         -                      kid-work
#     ✓ issue-101        gone               MERGED #950 12m        kid-done
#   3/5 ✓ · 1⏳ · 1!
#
# It merges the ledger every child report writes (fleet-report-parent.sh →
# $FLEET_STATE/children/<parent-key>.ndjson, bin/fleet-children-lib.sh) with the
# LIVE state of each child window (@claude_state / @worker_lifecycle) and the dash's
# PR cache — so a parent verifies a report with ONE command instead of `gh pr`
# plus a capture-pane per child. No gh, no network: the PR column is the prmap
# the dash already keeps fresh.
#
# Glyphs: ✓ done/merged · ⏳ turn over, PR still in flight (a WAITING report) ·
# ! needs a human (a needs/failed window, or a BLOCKED/FAILED report from a window
# that is gone) · ▸ working · – ended without landing (window gone, no merge).
# The summary spells itself like the dash's parent-row badge (`3/5 ✓ · 1!`), and
# attributes with the same rule (chain_v, ≤4 hops) — so for a live subtree the two
# agree exactly. The only split: a WAITING child the dash counts as ✓ shows as ⏳
# here (the dash cannot see the ledger).
#
#   <parent-key>   issue-N / scratch-N / <slug>:issue-N; default: THIS pane's own
#                  key (fleet_origin_key) — i.e. "my children"
#   --json         one JSON object {parent, session, seq, summary, children[…]}
#   --since <seq>  only children with a ledger event after <seq>; with --json also
#                  an `events` list of those events (a digest's cursor, C5)
#   -L <socket>    the fleet's socket, for a caller with no $TMUX
#   -h             this header
#
# Exit 0 on any answer (an empty ledger is `0 children`), 2 on a usage mistake or
# when no parent key can be resolved.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-children-lib.sh"

KEY='' JSON=0 SINCE=0 SOCK=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)    JSON=1 ;;
    --since)   shift; SINCE="${1:-}" ;;
    --since=*) SINCE="${1#--since=}" ;;
    -L)        shift; SOCK="${1:-}" ;;
    -L*)       SOCK="${1#-L}" ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        printf 'fleet-children: unknown argument %s\n' "$1" >&2; exit 2 ;;
    *)         KEY="$1" ;;
  esac
  shift
done
case "$SINCE" in ''|*[!0-9]*) printf 'fleet-children: --since wants a seq number\n' >&2; exit 2 ;; esac

TM() { if [ -n "$SOCK" ]; then tmux -L "$SOCK" "$@"; else tmux "$@"; fi; }

sess="$SOCK"; [ -n "$sess" ] || sess=$(fleet_current_session)
[ -n "$KEY" ] || KEY=$(fleet_origin_key)
[ -n "$KEY" ] || { printf 'fleet-children: no parent key — run it in a worker/scratch pane, or name one (issue-N / scratch-N)\n' >&2; exit 2; }
# Canonical spelling, exactly what a child's @origin carries (and so the file name).
KEY=$(fleet_origin_canon "$KEY" '')
dir=$(children_dir "$sess") || dir="$FLEET_CONF_DIR/fleets/_/children"

multi=0
[ -n "$sess" ] && _fleet_hosts_many "$sess" && multi=1
prmap=''; prdir=''
if [ -n "$sess" ]; then
  prmap=$(fleet_cache prmap "$sess"); prdir="$FLEET_C/fleets"
fi

# Live windows → `wid|state|needs|key|origin|name`, keyed like the dash's okey_v.
# One list-windows; window_name rides LAST (free text), `|` separators (tmux ≤3.4
# prints a 0x1f separator as a literal `\037`).
rows() {
  local line wid rest ws st needs iss wt path repo norepo name key pre slug
  TM list-windows -a -F '#{window_id}|#{session_name}|#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}|#{@claude_needs}|#{@issue}|#{@worktree}|#{@repo}|#{@norepo}|#{@origin}|#{pane_current_path}|#{window_name}' 2>/dev/null |
  while IFS= read -r line; do
    wid=${line%%|*};  rest=${line#*|}
    ws=${rest%%|*};   rest=${rest#*|}
    st=${rest%%|*};   rest=${rest#*|}
    needs=${rest%%|*}; rest=${rest#*|}
    iss=${rest%%|*};  rest=${rest#*|}
    wt=${rest%%|*};   rest=${rest#*|}
    repo=${rest%%|*}; rest=${rest#*|}
    norepo=${rest%%|*}; rest=${rest#*|}
    origin=${rest%%|*}; rest=${rest#*|}
    path=${rest%%|*}; name=${rest#*|}
    [ -n "$sess" ] && [ "$ws" != "$sess" ] && continue
    case "$name" in dash|plan|backlog) continue ;; esac
    pre=''
    if [ "$multi" = 1 ]; then
      # okp_v: the window's repo slug; unknown → `?:`, a key no @origin names.
      [ -n "$repo" ] || repo=$(fleet_window_repo "$sess" "$wid")
      slug=''; [ "$norepo" != 1 ] && [ -n "$repo" ] && slug=$(fleet_slug "$repo")
      pre="${slug:-?}:"
    fi
    key=''
    case "$iss" in
      ''|*[!0-9]*) key=$(fleet_scratch_key "$wt"); [ -n "$key" ] || key=$(fleet_scratch_key "$path")
                   [ -n "$key" ] && key="$pre$key" ;;
      *) key="${pre}issue-$iss" ;;
    esac
    [ -n "$key" ] || continue
    printf '%s|%s|%s|%s|%s|%s\n' "$wid" "$st" "$needs" "$key" "$origin" "$name"
  done
}

args=(show --dir "$dir" --parent "$KEY" --session "$sess" --since "$SINCE" --prmap "$prmap" --prmap-dir "$prdir")
[ "$JSON" = 1 ] && args+=(--json)
rows | python3 "$BIN/fleet-children.py" "${args[@]}"
