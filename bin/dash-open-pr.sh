#!/bin/bash
# dash-open-pr.sh <landed-target> — open a landed row's PR in the browser (dash ⌃p).
#
# The pre-#261 landed-view Enter behavior (#130), extracted to its own key when Enter was
# repurposed to RESUME the finished session (= ⌃o). No-op on PR-less rows (landed:issue:<n>),
# non-landed rows (a live-view row / header), and empty input — so it's safe to bind
# unconditionally; it only fires on a numeric-PR landed row.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
target="${1:-}"

case "$target" in
  landed:issue:*|'') exit 0 ;;               # PR-less landed row / empty — nothing to open
  landed:*)          pr="${target#landed:}" ;;
  *)                 exit 0 ;;               # not a landed row (live view / header)
esac
case "$pr" in ''|*[!0-9]*) exit 0 ;; esac    # not a numeric PR

# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh" 2>/dev/null || true
repo=$(fleet_repo_cached "${FLEET_SESSION:-}" 2>/dev/null)
[ -z "$repo" ] && { fleet_load_conf "${FLEET_SESSION:-}" 2>/dev/null; repo="${FLEET_REPO:-}"; }
[ -n "$repo" ] && (sh "$BIN/open-url.sh" "https://github.com/$repo/pull/$pr" >/dev/null 2>&1 &)
exit 0
