#!/bin/bash
# fleet-restore.sh — crash-safe recovery for the fleet.
#
# The tmux server is a single point of failure: if it dies (crash, a stray
# kill-server/killall, a terminal teardown) every Claude session in every fleet
# dies with it, and bringing them back is a manual slog — fleet-up each fleet,
# reopen each work window, `claude --resume <id>` each session by hand.
#
# This turns that into one command by continuously SNAPSHOTTING the live layout
# (which fleets, which work windows, which worktree, which Claude session id) to
# a DURABLE map, then RESTORING from it — rebuilding each fleet's hub via
# fleet-up.sh and reopening each work window with `claude --resume` so the
# conversation comes back with full context.
#
# Modes:
#   --snapshot        record the current live layout to the durable map (cheap;
#                     the collector calls this every cycle). No tmux changes.
#   (no args)         restore: for every mapped fleet not currently live, rebuild
#                     it and resume its work windows. Idempotent — a fleet that is
#                     already up is left untouched.
#   --dry-run         print what restore WOULD do; change nothing.
#   --if-down         restore ONLY if the tmux server is entirely absent AND
#                     auto-restore is armed. This is what the launchd watcher runs,
#                     so it never fights a healthy server or a deliberate shutdown.
#   --arm / --disarm  enable/disable --if-down auto-restore (boot + crash watcher).
#
# The map lives under $FLEET_CONF_DIR/restore/ (durable across reboots, unlike the
# $TMPDIR dash cache). One <session>.map per fleet so a fleet-down drops its own.
# See docs/ARCHITECTURE.md.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

RDIR="$FLEET_CONF_DIR/restore"
ARM="$RDIR/autorestore.on"
LOG="${FLEET_RESTORE_LOG:-$RDIR/restore.log}"
# window names that are fleet UI panels (rebuilt by fleet-up/steward-session),
# NOT Claude work sessions — never snapshotted or restored as sessions.
PANEL_RE='^(plan|dash|backlog)$'

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }
say() { [ -n "${QUIET:-}" ] || echo "$*"; }

# ---------------------------------------------------------------- snapshot ----
# Write one $RDIR/<session>.map per live fleet:
#   FLEET <TAB> session <TAB> repo <TAB> main-checkout-dir <TAB> base-branch
#   WIN   <TAB> window-name <TAB> worktree-path <TAB> claude-session-id <TAB> issue
# claude-session-id = newest transcript for that worktree ('-' if none).
snapshot() {
  tmux info >/dev/null 2>&1 || return 0
  mkdir -p "$RDIR" || return 0
  local sess
  for sess in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
    local repo main base conf tmp
    conf="$FLEET_CONF_DIR/$sess.conf"
    repo=""; main=""; base=""
    if [ -f "$conf" ]; then
      # shellcheck source=/dev/null
      repo=$( . "$conf" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
      # shellcheck source=/dev/null
      main=$( . "$conf" >/dev/null 2>&1; printf '%s' "${FLEET_MAIN:-}" )
      # shellcheck source=/dev/null
      base=$( . "$conf" >/dev/null 2>&1; printf '%s' "${FLEET_BASE_BRANCH:-}" )
    fi
    [ -z "$repo" ] && repo=$(fleet_repo_cached "$sess")
    [ -z "$repo" ] && repo=$(fleet_resolve_repo_for_session "$sess")
    repo=$(fleet_norm_repo "$repo")
    [ -z "$repo" ] && continue        # can't rebuild a fleet with no repo
    # main checkout: conf FLEET_MAIN, else a live window whose path basename ==
    # repo basename (the base checkout, not a worktree suffix), else skip.
    if [ -z "$main" ]; then
      local rb; rb=$(basename "$repo")
      main=$(tmux list-windows -t "$sess" -F '#{pane_current_path}' 2>/dev/null \
             | awk -v rb="$rb" 'NF && (($0 ~ ("/" rb "$"))) {print; exit}')
    fi
    [ -z "$base" ] && base="${FLEET_BASE_BRANCH:-}"

    tmp="$RDIR/.$sess.$$.map"
    printf 'FLEET\t%s\t%s\t%s\t%s\n' "$sess" "$repo" "$main" "$base" > "$tmp"
    # per-window rows, resolving the newest transcript id in python (cheap, one pass)
    tmux list-windows -t "$sess" -F '#{window_name}	#{pane_current_path}	#{@issue}' 2>/dev/null \
      | python3 "$BIN/.fleet-restore-resolve.py" >> "$tmp" 2>/dev/null
    mv "$tmp" "$RDIR/$sess.map" 2>/dev/null || rm -f "$tmp"
  done
  # NB: do NOT prune maps for absent sessions here. A CRASHED fleet's session is
  # gone but its map MUST survive so --if-down can rebuild it. fleet-down.sh is the
  # sole map remover (drops its own map on deliberate teardown). Pruning here
  # destroyed the recovery data on a partial crash: after the server came back with
  # only the surviving fleet, the next snapshot deleted the down fleet's map before
  # restore could use it.
}

# ----------------------------------------------------------------- restore ----
restore() {
  local dry="${1:-}"
  mkdir -p "$RDIR"
  local mf found=0
  for mf in "$RDIR"/*.map; do
    [ -f "$mf" ] || continue
    found=1
    local sess repo main base
    IFS=$'\t' read -r _ sess repo main base < <(awk -F'\t' '$1=="FLEET"{print;exit}' "$mf")
    [ -z "$sess" ] && continue
    if tmux has-session -t "$sess" 2>/dev/null; then
      say "· $sess already up — skipping"
      continue
    fi
    say "▸ restoring fleet $sess ($repo)"
    log "restore fleet $sess repo=$repo main=$main base=$base dry=${dry:-0}"
    if [ -n "$dry" ]; then
      say "    would: fleet-up.sh $repo ${main:-<clone>} --name $sess ${base:+--base $base}"
    else
      # rebuild hub + steward. fleet-up refuses if the session exists (it doesn't).
      local args; args=("$repo"); [ -n "$main" ] && args+=("$main")
      args+=(--name "$sess"); [ -n "$base" ] && args+=(--base "$base")
      env -u TMUX bash "$BIN/fleet-up.sh" "${args[@]}" >>"$LOG" 2>&1 \
        || { say "    ✗ fleet-up failed for $sess (see $LOG)"; continue; }
    fi
    # reopen each work window, resuming its Claude session
    local wname wpath wid wissue
    while IFS=$'\t' read -r _ wname wpath wid wissue; do
      [ -z "$wname" ] && continue
      echo "$wname" | grep -qE "$PANEL_RE" && continue
      if [ ! -d "$wpath" ]; then
        say "    ⚠ $wname: worktree gone ($wpath) — skipped"
        log "skip $sess/$wname worktree-missing $wpath"
        continue
      fi
      local cmd
      if [ -n "$wid" ] && [ "$wid" != "-" ]; then
        cmd="claude --resume '$wid'; exec \$SHELL"
        say "    ↻ $wname → claude --resume ${wid%%-*}…"
      else
        cmd="claude; exec \$SHELL"
        say "    + $wname → fresh claude (no transcript found)"
      fi
      if [ -z "$dry" ]; then
        tmux new-window -t "$sess:" -n "$wname" -c "$wpath" "$cmd" 2>/dev/null
        [ -n "$wissue" ] && [ "$wissue" != "-" ] \
          && tmux set-window-option -t "$sess:$wname" @issue "$wissue" 2>/dev/null
      fi
    done < <(awk -F'\t' '$1=="WIN"' "$mf")
  done
  [ "$found" = 0 ] && say "no restore maps under $RDIR — nothing to restore"
  return 0
}

# ------------------------------------------------------------------- main -----
case "${1:-}" in
  --snapshot) snapshot ;;
  --arm)      mkdir -p "$RDIR"; : > "$ARM"; echo "fleet-restore: auto-restore ARMED ($ARM)";;
  --disarm)   rm -f "$ARM"; echo "fleet-restore: auto-restore DISARMED";;
  --dry-run)  restore dry ;;
  --if-down)
    # launchd watcher: restore any MAPPED fleet whose tmux session is absent —
    # even when another fleet survived. A partial crash keeps the server "up" but
    # still loses fleets, so gating on whole-server-absence (the old behaviour)
    # left the down fleet stranded. restore() skips fleets already up, so acting
    # whenever ANY mapped fleet is down is safe.
    [ -f "$ARM" ] || exit 0
    ifd_down=0
    for ifd_mf in "$RDIR"/*.map; do
      [ -f "$ifd_mf" ] || continue
      ifd_s=$(awk -F'\t' '$1=="FLEET"{print $2; exit}' "$ifd_mf")
      [ -n "$ifd_s" ] && ! tmux has-session -t "$ifd_s" 2>/dev/null && ifd_down=1
    done
    [ "$ifd_down" = 0 ] && exit 0
    # Disk-pressure circuit-breaker: if a fleet died because the volume filled,
    # rebuilding straight back into a full disk just re-crashes it — a restore ⇄
    # crash LOOP every StartInterval. Refuse until there's room.
    if [ -x "$BIN/fleet-diskguard.sh" ] && ! bash "$BIN/fleet-diskguard.sh" --gate 2>/dev/null; then
      log "mapped fleet down + armed BUT disk below floor → NOT restoring (would crash-loop); see fleet-diskguard --free"
      exit 0
    fi
    log "mapped fleet down + armed → auto-restore"
    QUIET=1 restore ;;
  ""|--restore) restore ;;
  *) echo "usage: fleet-restore.sh [--snapshot|--dry-run|--if-down|--arm|--disarm]" >&2; exit 2;;
esac
