#!/bin/bash
# fleet-epic-floor.sh — which version each member of an EPIC batch started on,
# and how many versions the batch spanned (issue #2934).
#
#   fleet-epic-floor.sh record <epic> <member> [--repo <owner/name>]   # at each spawn
#   fleet-epic-floor.sh show <epic> [--repo <owner/name>]              # the report's line
#
# WHY. Until #2934 a running batch held every install still (the EPIC hold), so a
# batch's members all ran on one version — bought by leaving the machine behind
# stable for as long as batches ran, which was all day. A switch never stops a
# running session, so the hold is off by default now and a batch may span
# versions. That is allowed, not blocked; it is only RECORDED: /fleet-epic-run
# calls `record` right after it spawns a member, and its report says
# 「本批跨了 K 个版本」 from `show`.
#
# The version is this login's live install (~/.claude/fleet, FLEET_LIVE_DIR): a
# link into fleet.versions/<sha>[-suffix] names its sha, a plain checkout its
# HEAD. One line per spawn in $FLEET_CONF_DIR/global/epic-floors/<repo slug>-<N>
# (`<epoch>\t<repo>\t<member>\t<sha>`); a member spawned twice keeps both — the
# version count is over every line. Needs no gh and no tmux.
#
# `show` prints `versions: K` then one line per version in first-seen order,
# `<sha7>  #a #b …` (the members that started on it). Nothing recorded ⇒ `versions: 0`.
#
# Exit: 0 recorded / shown · 2 usage.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

usage() { sed -n '5,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
MODE=${1:-}; shift 2>/dev/null || :
case "$MODE" in record|show) ;; *) usage ;; esac
EPIC=${1:-}; shift 2>/dev/null || :
case "$EPIC" in ''|*[!0-9]*) usage ;; esac
MEMBER=''
if [ "$MODE" = record ]; then
  MEMBER=${1:-}; shift 2>/dev/null || :
  MEMBER=${MEMBER#\#}
  case "$MEMBER" in ''|*[!0-9]*) usage ;; esac
fi
REPO="${FLEET_REPO:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)   shift; REPO="${1:-}" ;;
    --repo=*) REPO="${1#--repo=}" ;;
    *) usage ;;
  esac
  shift
done

dir="$FLEET_CONF_DIR/global/epic-floors"
case "$REPO" in ''|-) slug=_ ;; *) slug=$(fleet_slug "$REPO") ;; esac
file="$dir/$slug-$EPIC"

# floor_now — the live install's version (sha), or `?`.
floor_now() {
  local live t k
  live="${FLEET_LIVE_DIR:-$HOME/.claude/fleet}"
  if [ -L "$live" ]; then
    t=$(readlink "$live"); t=${t%/}; k=${t##*/}; k=${k%%-*}
    case "$k" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) printf '%s\n' "$k"; return 0 ;; esac
  fi
  k=$(git -C "$live" rev-parse HEAD 2>/dev/null) && [ -n "$k" ] && { printf '%s\n' "$k"; return 0; }
  printf '?\n'
}

if [ "$MODE" = record ]; then
  mkdir -p "$dir" 2>/dev/null || { printf 'fleet-epic-floor: cannot write %s\n' "$dir" >&2; exit 0; }
  sha=$(floor_now)
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "${REPO:--}" "$MEMBER" "$sha" >> "$file"
  printf 'recorded #%s on %s (epic %s)\n' "$MEMBER" "$(printf '%.7s' "$sha")" "$EPIC"
  exit 0
fi

[ -s "$file" ] || { printf 'versions: 0 (nothing recorded in %s)\n' "$file"; exit 0; }
awk -F'\t' '
  NF >= 4 {
    if (!($4 in who)) { order[++n] = $4; who[$4] = "" }
    if (!(($4 SUBSEP $3) in seen)) { seen[$4 SUBSEP $3] = 1; who[$4] = who[$4] " #" $3 }
  }
  END {
    printf "versions: %d\n", n
    for (i = 1; i <= n; i++) printf "%s %s\n", substr(order[i], 1, 7), who[order[i]]
  }' "$file"
