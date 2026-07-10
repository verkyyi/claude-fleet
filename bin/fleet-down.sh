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

# Path-traversal guard (steward review, PR #196). $NAME becomes a path SEGMENT in
# several rm targets — rm -rf "$FLEET_CONF_DIR/fleets/$NAME", "$NAME.conf",
# "restore/$NAME.map". A raw operator typo like `fleet-down ..` or `fleet-down a/b`
# would escape fleets/<sess>/ and rm -rf a PARENT, wiping accounts/ (OAuth tokens),
# diskguard/, and every other fleet's state. A tmux session name is a plain token
# (fleet-up strips . : space → -), so reject anything that isn't one: contains '/',
# or is/contains a `.`/`..` traversal SEGMENT. A legit dotted basename (e.g.
# fleet-my.app) is fine — only path traversal is refused, never a bare dot in a name.
case "$NAME" in
  */*) die "refusing session name '$NAME' — contains '/' (not a tmux session name)";;
esac
case "/$NAME/" in
  */../* | */./*) die "refusing unsafe session name '$NAME' — path traversal ('.'/'..' segment)";;
esac

CONF="$(fleet_conf_file "$NAME")"     # new fleets/<sess>/conf, or a legacy flat one
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
  # One directory per fleet (issue #181): remove exactly fleets/<sess>/ — its whole
  # durable state (conf, restore.map, bridge/, watch/, sweep.due). Also sweep any
  # legacy flat conf the migrator hasn't reached yet.
  SDIR="$FLEET_CONF_DIR/fleets/$NAME"
  # belt-and-suspenders before an rm -rf: SDIR must be a DIRECT child of fleets/
  # (the name guard above already guarantees this — assert so a future change can't
  # silently regress it into a parent wipe).
  [ "$(dirname "$SDIR")" = "$FLEET_CONF_DIR/fleets" ] \
    || die "internal: refusing rm -rf '$SDIR' — not a direct child of $FLEET_CONF_DIR/fleets"
  [ -d "$SDIR" ] && { rm -rf "$SDIR" && echo "fleet-down: removed $SDIR"; }
  rm -f "$FLEET_CONF_DIR/$NAME.conf" 2>/dev/null || true
  if [ -n "$SLUG" ]; then
    # runtime cache: the fleet's own dir + any legacy flat slug-suffixed files. SLUG
    # is conf-derived + fleet_slug-sanitized (no '/'), but assert direct-child too.
    CDIR="$FLEET_C/fleets/$SLUG"
    [ "$(dirname "$CDIR")" = "$FLEET_C/fleets" ] \
      || die "internal: refusing rm -rf '$CDIR' — not a direct child of $FLEET_C/fleets"
    rm -rf "$CDIR"
    rm -f "$FLEET_C/prmap_$SLUG" "$FLEET_C/prmap_$SLUG.ts" \
          "$FLEET_C/issues_$SLUG" "$FLEET_C/issues_$SLUG.ts" \
          "$FLEET_C/labels_$SLUG" 2>/dev/null || true
    echo "fleet-down: purged cache for slug '$SLUG'"
  fi
fi

# if that was the LAST fleet (tmux server now gone), this was a deliberate full
# teardown — disarm crash auto-restore so the watcher doesn't resurrect it. A
# real crash never runs fleet-down, so it stays armed and gets restored.
if ! tmux info >/dev/null 2>&1; then
  bash "$BIN/fleet-restore.sh" --disarm >/dev/null 2>&1 || true
else
  # server still up: drop just this fleet's restore map so it isn't rebuilt
  # (new per-fleet layout + legacy path, issue #181)
  rm -f "$FLEET_CONF_DIR/fleets/$NAME/restore.map" "$FLEET_CONF_DIR/restore/$NAME.map" 2>/dev/null || true
  # refresh sessmap so the dead session drops out immediately
  ( GH_TTL=999999 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1 & )
fi
echo "fleet-down: done (checkout left on disk)"
