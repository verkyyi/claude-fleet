#!/bin/bash
# fleet-down.sh <session> [--purge]
#
# Tear down a fleet: kill its tmux session. The local checkout is ALWAYS left on
# disk (your work lives there). With --purge, also remove the per-fleet conf and
# this fleet's slug'd cache files. See docs/ARCHITECTURE.md.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

die() { echo "fleet-down: $*" >&2; exit 1; }

NAME=""; PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1; shift;;
    -*) die "unknown flag $1";;
    *) [ -z "$NAME" ] && NAME="$1"; shift;;
  esac
done
[ -n "$NAME" ] || die "usage: fleet-down.sh <session> [--purge]"

CONF="$FLEET_CONF_DIR/$NAME.conf"
# resolve this fleet's repo/slug BEFORE deleting the conf (for cache purge)
SLUG=""
if [ -f "$CONF" ]; then
  r=$( . "$CONF" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
  [ -n "$r" ] && SLUG=$(fleet_slug "$(fleet_norm_repo "$r")")
fi

if tmux has-session -t "$NAME" 2>/dev/null; then
  tmux kill-session -t "$NAME" && echo "fleet-down: killed tmux session '$NAME'"
else
  echo "fleet-down: no live tmux session '$NAME'"
fi

if [ "$PURGE" = 1 ]; then
  [ -f "$CONF" ] && { rm -f "$CONF" && echo "fleet-down: removed $CONF"; }
  if [ -n "$SLUG" ]; then
    rm -f "$FLEET_C/prmap_$SLUG" "$FLEET_C/prmap_$SLUG.ts" \
          "$FLEET_C/issues_$SLUG" "$FLEET_C/issues_$SLUG.ts"
    echo "fleet-down: purged cache for slug '$SLUG'"
  fi
fi

# refresh sessmap so the dead session drops out immediately
( GH_TTL=999999 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1 & )
echo "fleet-down: done (checkout left on disk)"
