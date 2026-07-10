#!/bin/bash
# fleet-migrate-layout.sh — one-time migrator to the per-fleet directory layout
# (issue #181). Moves an existing estate's DURABLE state from the legacy flat
# namespace to one directory per fleet, keyed by tmux SESSION name:
#
#   BEFORE ($FLEET_CONF_DIR)                    AFTER
#   <sess>.conf                                 fleets/<sess>/conf
#   restore/<sess>.map                          fleets/<sess>/restore.map
#   issue-bridge/bridge_<slug>.{seen,since}     fleets/<sess>/bridge/{seen,since}
#   watch/watch_<slug>.{keys,needs}             fleets/<sess>/watch/{keys,needs}
#   sweep/<sess>.due                            fleets/<sess>/sweep.due
#
# Global durable state (accounts/, diskguard/, restore/{autorestore.on,restore.log})
# is left untouched. The runtime cache ($TMPDIR/.claude-dash) is EPHEMERAL — the
# collector/pr-refresh regenerate it into the new layout on their next tick, so it
# needs no migration.
#
# IDEMPOTENT + SAFE to re-run: a file already at its new location is never
# clobbered — the stale legacy source is simply removed. Nothing is deleted that
# wasn't already migrated. Bridge/watch state is keyed by repo SLUG; the migrator
# resolves slug→session from the (already-moved) confs, and leaves any bridge/watch
# file whose slug matches no configured fleet in place (logged), so no state is
# silently dropped.
#
# Invoked once by /fleet-sync-install; also runnable by hand. --dry-run prints the
# moves without touching anything.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  -h|--help) echo "usage: fleet-migrate-layout.sh [--dry-run]"; exit 0 ;;
  "") : ;;
  *) echo "fleet-migrate-layout: unknown arg '$1'" >&2; exit 2 ;;
esac

ROOT="$FLEET_CONF_DIR"
moved=0 skipped=0 orphan=0

say() { echo "fleet-migrate-layout: $*"; }
# move_one SRC DEST — idempotent: move SRC→DEST only if DEST is absent; if DEST
# already exists the SRC is a stale duplicate → drop it. Creates DEST's parent.
move_one() {
  local src="$1" dest="$2"
  [ -e "$src" ] || return 0
  if [ -e "$dest" ]; then
    if [ "$DRY" = 1 ]; then say "would drop stale (already migrated): $src"; else rm -f "$src"; fi
    skipped=$((skipped + 1)); return 0
  fi
  if [ "$DRY" = 1 ]; then
    say "would move: ${src#"$ROOT"/} → ${dest#"$ROOT"/}"
  else
    mkdir -p "$(dirname "$dest")" 2>/dev/null
    mv "$src" "$dest" || { say "FAILED to move $src"; return 0; }
  fi
  moved=$((moved + 1))
}

[ -d "$ROOT" ] || { say "no state dir ($ROOT) — nothing to migrate"; exit 0; }

# --- 1. per-session conf: <sess>.conf → fleets/<sess>/conf --------------------
# Glob only *.conf (never the *.conf.bak* backups fleet-up leaves behind).
for cf in "$ROOT"/*.conf; do
  [ -f "$cf" ] || continue
  sess=$(basename "$cf" .conf)
  move_one "$cf" "$ROOT/fleets/$sess/conf"
done

# --- 2. restore maps: restore/<sess>.map → fleets/<sess>/restore.map ----------
# Keep restore/autorestore.on + restore/restore.log (global control) in place.
if [ -d "$ROOT/restore" ]; then
  for mf in "$ROOT"/restore/*.map; do
    [ -f "$mf" ] || continue
    sess=$(basename "$mf" .map)
    move_one "$mf" "$ROOT/fleets/$sess/restore.map"
  done
fi

# --- slug→session map, from the (now-migrated) confs --------------------------
# Bridge/watch state is keyed by repo SLUG; build slug→sess so those files land in
# the right per-session dir. fleet_each_conf sees both the just-moved new-layout
# confs and any legacy flat conf a dry-run left in place.
SLUGMAP=""   # newline-separated "<slug>\t<sess>"
while IFS=$'\t' read -r sess conf; do
  [ -n "$sess" ] || continue
  rp=$( . "$conf" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
  [ -n "$rp" ] || continue
  slug=$(fleet_slug "$(fleet_norm_repo "$rp")")
  [ -n "$slug" ] && SLUGMAP="$SLUGMAP$slug	$sess
"
done < <(fleet_each_conf)

sess_for_slug() {  # $1=slug → session or empty
  printf '%s' "$SLUGMAP" | awk -F'\t' -v s="$1" '$1==s{print $2; exit}'
}

# --- 3. issue-bridge state: bridge_<slug>.{seen,since} → fleets/<sess>/bridge/ -
if [ -d "$ROOT/issue-bridge" ]; then
  for bf in "$ROOT"/issue-bridge/bridge_*.seen "$ROOT"/issue-bridge/bridge_*.since; do
    [ -f "$bf" ] || continue
    base=$(basename "$bf"); ext="${base##*.}"; slug="${base#bridge_}"; slug="${slug%.*}"
    sess=$(sess_for_slug "$slug")
    if [ -z "$sess" ]; then
      say "orphan bridge state (no fleet for slug '$slug'): ${bf#"$ROOT"/} — left in place"
      orphan=$((orphan + 1)); continue
    fi
    move_one "$bf" "$ROOT/fleets/$sess/bridge/$ext"
  done
fi

# --- 4. watch state: watch_<slug>.{keys,needs} → fleets/<sess>/watch/ ---------
if [ -d "$ROOT/watch" ]; then
  for wf in "$ROOT"/watch/watch_*.keys "$ROOT"/watch/watch_*.needs; do
    [ -f "$wf" ] || continue
    base=$(basename "$wf"); ext="${base##*.}"; slug="${base#watch_}"; slug="${slug%.*}"
    sess=$(sess_for_slug "$slug")
    if [ -z "$sess" ]; then
      say "orphan watch state (no fleet for slug '$slug'): ${wf#"$ROOT"/} — left in place"
      orphan=$((orphan + 1)); continue
    fi
    move_one "$wf" "$ROOT/fleets/$sess/watch/$ext"
  done
fi

# --- 5. sweep ledger: sweep/<sess>.due → fleets/<sess>/sweep.due --------------
if [ -d "$ROOT/sweep" ]; then
  for sf in "$ROOT"/sweep/*.due; do
    [ -f "$sf" ] || continue
    sess=$(basename "$sf" .due)
    move_one "$sf" "$ROOT/fleets/$sess/sweep.due"
  done
fi

say "$([ "$DRY" = 1 ] && printf '(dry-run) ')done — ${moved} moved, ${skipped} already-migrated, ${orphan} orphan"
exit 0
