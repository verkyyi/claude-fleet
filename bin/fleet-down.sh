#!/bin/bash
# fleet-down.sh <session> [--yes] [--purge]
#
# Tear down a fleet: kill its tmux session. The local checkout is ALWAYS left on
# disk (your work lives there). With --purge, also remove the per-fleet conf and
# this fleet's slug'd cache files. See docs/ARCHITECTURE.md.
#
# It asks first (issue #1846): one slip took a dozen sessions and a running batch
# down, and getting them back was by memory. With the fleet live it lists the
# sessions that would stop; on a terminal you type the fleet's name to go on,
# anything else cancels; with no terminal it refuses (exit 2) unless --yes — a
# script that means it says so. Before the kill the fleet's restore map is
# snapshotted and kept as fleets/<sess>/restore.map.down-<UTC>, so
# `fleet up --undo` (fleet-restore.sh --undo) brings every session back on its
# own conversation. A fleet with no live session has nothing to lose: no prompt.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

die() { echo "fleet-down: $*" >&2; exit 1; }

NAME=""; PURGE=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1; shift;;
    --yes|-y) YES=1; shift;;
    -*) die "unknown flag $1";;
    *) [ -z "$NAME" ] && NAME="$1"; shift;;
  esac
done
[ -n "$NAME" ] || die "usage: fleet-down.sh <session> [--yes] [--purge]"

# Path-traversal guard (review of PR #196). $NAME becomes a path SEGMENT in
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

# This fleet's own tmux server socket (== session name, issue #159). Killing its
# lone session also tears the server down, so the socket goes away — leaving every
# OTHER fleet's server untouched (that isolation is the whole point).
SOCK=$(fleet_socket "$NAME")
DOWNMAP=''
if tmux -L "$SOCK" has-session -t "$NAME" 2>/dev/null; then
  # What would stop: every session window (by role, issue #1844), with its state.
  LIST=$(tmux -L "$SOCK" list-windows -t "$NAME" -F "#{window_name}|#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}|$FLEET_ROLE_FMT" 2>/dev/null \
         | awk -F'|' "$FLEET_ROLE_AWK"'
             frole($3) == "worker" { printf "  %-28s %s\n", $1, ($2 == "" ? "-" : $2) }')
  N=$(printf '%s' "$LIST" | grep -c .)
  if [ "$YES" != 1 ]; then
    {
      printf 'fleet-down: 要关掉 fleet「%s」' "$NAME"
      if [ "$N" -gt 0 ]; then printf '，下面 %s 个会话会一起停：\n%s\n' "$N" "$LIST"; else printf '（没有执行会话）。\n'; fi
      [ "$PURGE" = 1 ] || printf '关掉后 fleet up --undo 可以把它们原样拉回。\n'
    } >&2
    if [ -t 0 ]; then
      printf '输入 fleet 名「%s」确认（其他任何输入取消）：' "$NAME" >&2
      ANSWER=''; IFS= read -r ANSWER || ANSWER=''
      [ "$ANSWER" = "$NAME" ] || { echo "fleet-down: 已取消，什么都没关" >&2; exit 2; }
    else
      echo "fleet-down: 没有终端可确认，什么都没关。在终端里运行，或加 --yes（自动化）" >&2
      exit 2
    fi
  fi
  # Keep the map it is about to lose (issue #1846): a fresh snapshot first, so a
  # session opened since the collector's last cycle is in it too.
  if [ "$PURGE" != 1 ]; then
    bash "$BIN/fleet-restore.sh" --snapshot >/dev/null 2>&1
    for m in "$FLEET_CONF_DIR/fleets/$NAME/restore.map" "$FLEET_CONF_DIR/restore/$NAME.map"; do
      [ -f "$m" ] || continue
      DOWNMAP="$FLEET_CONF_DIR/fleets/$NAME/restore.map.down-$(date -u +%Y%m%dT%H%M%SZ)"
      cp "$m" "$DOWNMAP" 2>/dev/null && echo "fleet-down: kept ${DOWNMAP#"$FLEET_CONF_DIR"/} — fleet up --undo brings it back" || DOWNMAP=''
      break
    done
    # older downs: the newest five are plenty
    for m in "$FLEET_CONF_DIR/fleets/$NAME"/restore.map.down-*; do
      case "$m" in *.disarmed) ;; *) [ -f "$m" ] && printf '%s\n' "$m" ;; esac
    done | sort -r | sed -n '6,$p' \
      | while IFS= read -r m; do rm -f "$m" "$m.disarmed"; done
  fi
  tmux -L "$SOCK" kill-session -t "$NAME" && echo "fleet-down: killed tmux session '$NAME'"
  # The server outlives its last session now (exit-empty off, issue #1784), so a
  # deliberate teardown ends it here — this fleet's own socket only.
  [ -z "$(tmux -L "$SOCK" list-sessions -F x 2>/dev/null)" ] \
    && FLEET_ALLOW_TMUX_DESTROY=1 tmux -L "$SOCK" kill-server 2>/dev/null
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
  fleet_conf_reserved "$NAME" || rm -f "$FLEET_CONF_DIR/$NAME.conf" 2>/dev/null || true   # fleet.conf is the machine's (#1887)
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

# Down on purpose (issue #1784): the diskguard tick's --auto pull-up leaves this
# fleet alone until fleet-up brings it back. A crash never writes this.
[ "$PURGE" = 1 ] || { mkdir -p "$FLEET_CONF_DIR/fleets/$NAME" 2>/dev/null && : > "$FLEET_CONF_DIR/fleets/$NAME/restore.down"; }

# if that was the LAST fleet (no live fleet server remains), this was a deliberate
# full teardown — disarm crash auto-restore so the watcher doesn't resurrect it. A
# real crash never runs fleet-down, so it stays armed and gets restored. With
# per-fleet sockets there is no single shared server to probe, so ask
# fleet_sockets whether ANY fleet is still live.
if [ -z "$(fleet_sockets)" ]; then
  bash "$BIN/fleet-restore.sh" --disarm >/dev/null 2>&1 || true
  [ -n "$DOWNMAP" ] && : > "$DOWNMAP.disarmed"      # --undo re-arms it
else
  # other fleets still up: drop just this fleet's restore map so it isn't rebuilt
  # (new per-fleet layout + legacy path, issue #181)
  rm -f "$FLEET_CONF_DIR/fleets/$NAME/restore.map" "$FLEET_CONF_DIR/restore/$NAME.map" 2>/dev/null || true
  # refresh sessmap so the dead session drops out immediately
  ( GH_TTL=999999 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1 & )
fi
echo "fleet-down: done (checkout left on disk)"
