#!/bin/bash
# fleet-epic-loopers.sh [--session <sess>] [--repo <owner/name>] <issue>... — which
#   EPIC members still hold a pending Loop (issue #1331). Read-only.
#
# The operator's ruling on EPIC #1312 (option A): a member whose PR merged is
# DELIVERED — the batch may close — but a window still running its /loop is KEPT
# (fleet-reap-live.py answers `retained:loop`) and ends on its own. The report
# must tell those two apart, so each member gets one line:
#
#   <issue>\tlooping\t<reason>   a live window whose Loop is pending
#                                (fleet_window_loop: @loop mark or loop ledger)
#   <issue>\tidle\t<reason>      a live window with no Loop
#   <issue>\tgone\t-             no window bound to (repo, issue) any more
#
# /fleet-epic-report folds it with the PR state it already gathered: merged +
# `looping` → 「已合并，仍在循环」; merged + idle/gone → 「已合并」 as before (a
# window that no longer exists is simply merged). /fleet-epic-run's closing reap
# reads `retained:loop` the same way: not a failure, a 「保留：仍在循环」 note.
#
# Exit 0 always on a readable fleet; 2 = usage / no fleet.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

sess='' repo='' issues=()
while [ $# -gt 0 ]; do
  case "$1" in
    --session) sess="${2:-}"; shift 2 ;;
    --repo)    repo="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    -*)        printf 'fleet-epic-loopers: unknown argument %s\n' "$1" >&2; exit 2 ;;
    *)         case "$1" in *[!0-9#]*|'') printf 'fleet-epic-loopers: not an issue number: %s\n' "$1" >&2; exit 2 ;; esac
               issues+=("${1#\#}"); shift ;;
  esac
done
[ -n "$sess" ] || sess=$(fleet_current_session)
[ -n "$sess" ] || { printf 'fleet-epic-loopers: not inside a fleet — pass --session\n' >&2; exit 2; }
[ -n "$repo" ] || { fleet_load_conf "$sess" >/dev/null 2>&1 || :; repo="${FLEET_REPO:-}"; }

for i in ${issues[@]+"${issues[@]}"}; do
  w=$(fleet_issue_windows "$sess" "$repo" "$i" | head -n 1)
  if [ -z "$w" ]; then printf '%s\tgone\t-\n' "$i"; continue; fi
  out=$(fleet_window_loop "$sess" "$w"); rc=$?
  why=${out#* }
  if [ "$rc" = 0 ]; then printf '%s\tlooping\t%s\n' "$i" "$why"
  else printf '%s\tidle\t%s\n' "$i" "$why"; fi
done
exit 0
