#!/bin/bash
# fleet-diskguard.sh — disk-pressure circuit-breaker + runaway-writer forensics.
#
# WHY: the fleet's tmux server is a single point of failure. When the volume that
# holds $TMPDIR/.claude-dash fills to 0 bytes, the collector's writes fail with
# ENOSPC and the tmux SERVER itself dies — taking every Claude session in every
# fleet down at once. A machine-wide disk-full is not isolated between fleets.
#
# This guards that in two ways:
#   1. GATE (--gate): a cheap precondition. fleet-up.sh (spawn) and
#      fleet-restore.sh --if-down (auto-restore) call it and REFUSE to add load
#      when free space is below FLEET_DISK_FLOOR_GB. That stops the crash-LOOP
#      where auto-restore rebuilds fleets straight back into a full disk.
#   2. WATCH (--watch): run frequently by launchd/systemd. When free space drops
#      below FLEET_DISK_WARN_GB it captures a forensic INCIDENT — the open-but-
#      deleted files (an unlinked fd is where a runaway's bytes hide and why they
#      vanish the instant the writer is killed), the largest just-written files,
#      and the top RSS processes — to a durable log, and fires FLEET_NOTIFY_CMD.
#      That is how we catch the next runaway red-handed instead of inferring it.
#
# Measures the volume backing $TMPDIR (where the crash actually happens), not "/".
# No sudo, no full-volume scans: lsof/find are scoped to the user + bounded roots.
#
# Modes:
#   --free            print integer GB free on the target volume; exit 0
#   --gate [floor]    exit 0 if free >= floor (default FLEET_DISK_FLOOR_GB), else
#                     print a one-line reason to stderr and exit 3
#   --watch           if free < FLEET_DISK_WARN_GB, capture an incident (cooldown-
#                     gated) + notify; always exit 0 (a watcher must never fail loud)
#   --probe           capture an incident right now regardless of free space
#   --help
#
# Config (fleet.conf / per-fleet conf; all optional):
#   FLEET_DISK_FLOOR_GB   gate refusal threshold      (default 12)
#   FLEET_DISK_WARN_GB    watch capture threshold     (default 15)
#   FLEET_DISK_TARGET     dir whose volume to measure (default $TMPDIR)
#   FLEET_DISK_COOLDOWN   min seconds between captures (default 300)
#   FLEET_NOTIFY_CMD      notifier run as `$CMD "<markdown>"` on an incident
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
[ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh"

FLOOR_GB="${FLEET_DISK_FLOOR_GB:-12}"
WARN_GB="${FLEET_DISK_WARN_GB:-15}"
TARGET="${FLEET_DISK_TARGET:-${TMPDIR:-/tmp}}"
COOLDOWN="${FLEET_DISK_COOLDOWN:-300}"
GDIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/diskguard"
STAMP="$GDIR/last-capture"

now() { date +%s; }

# Run a command with a hard wall-clock cap so a pathological directory can never
# hang the watcher. perl's alarm is present on macOS + Linux and needs no module;
# if perl is somehow absent the command simply doesn't run (the du is best-effort).
tmo() {
  local secs="$1"; shift
  command -v perl >/dev/null 2>&1 || return 0
  perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
}

# Integer GB available on the volume backing $TARGET. Portable: df -Pk yields
# 1024-byte blocks (POSIX), Avail is field 4; macOS Data volume and Linux "/"
# both resolve correctly because we df the DIR, not a hardcoded mount.
free_gb() {
  df -Pk "$TARGET" 2>/dev/null | awk 'NR==2 { printf "%d", int($4/1048576) }'
}

notify() {   # $1=markdown message — best-effort, never fails the caller
  [ -n "${FLEET_NOTIFY_CMD:-}" ] || return 0
  "$FLEET_NOTIFY_CMD" "$1" >/dev/null 2>&1 || true
}

# Write a full forensic snapshot. $1=reason $2=free-GB. Cooldown-gated by the
# caller (--probe bypasses it). Returns the incident path on stdout.
capture() {
  local reason="$1" free="$2" ts inc
  mkdir -p "$GDIR" || return 1
  ts=$(date '+%Y%m%dT%H%M%S')
  inc="$GDIR/incident-$ts.log"
  {
    echo "# fleet-diskguard incident — $ts"
    echo "reason:   $reason"
    echo "free:     ${free}GB on volume backing $TARGET (warn<${WARN_GB} floor<${FLOOR_GB})"
    echo "host:     $(hostname 2>/dev/null)"
    echo
    echo "## df (target volume)"
    df -Ph "$TARGET" 2>/dev/null
    echo
    echo "## live fleets (tmux sessions × windows — how much load is up)"
    if tmux info >/dev/null 2>&1; then
      tmux list-sessions -F '#{session_name} (#{session_windows} windows, created #{t:session_created})' 2>/dev/null
    else
      echo "(no tmux server)"
    fi
    echo
    # lsof is the primary forensic — fast (~0.2s) and it points straight at the
    # PROCESS holding the runaway. We deliberately do NOT walk the filesystem
    # (a full-tree `find` over $TMPDIR/~/.claude can take minutes and would hang
    # the watcher during the very emergency it exists for). Every open file has a
    # PID, so kill = free.
    echo "## open-but-DELETED files, largest first (lsof +L1)"
    echo "#  a runaway's bytes hide in an unlinked fd — this is what frees on kill."
    echo "#  COMMAND / PID / FD / SIZE-bytes / NAME:"
    # +L1 = files whose link count < 1 (deleted). Columns: COMMAND PID USER FD
    # TYPE DEVICE SIZE/OFF NLINK NODE NAME. Sort by SIZE/OFF (field 7) desc.
    lsof -nP +L1 2>/dev/null \
      | awk 'NR>1 && $7 ~ /^[0-9]+$/ { printf "%-14s %-8s %-5s %15d  %s\n", $1,$2,$4,$7,$NF }' \
      | sort -k4,4nr | head -20
    echo
    echo "## largest OPEN regular files >200MB (lsof) — a still-linked grower shows here"
    echo "#  COMMAND / PID / FD / SIZE-bytes / NAME:"
    lsof -nP -w 2>/dev/null \
      | awk '$5=="REG" && $7 ~ /^[0-9]+$/ && $7>209715200 { printf "%-14s %-8s %-5s %15d  %s\n", $1,$2,$4,$7,$NF }' \
      | sort -k4,4nr | awk '!seen[$0]++' | head -20
    echo
    echo "## size of fleet-owned dirs (bounded du, 8s watchdog each — never a full-volume walk)"
    for d in "${TMPDIR:-/tmp}/.claude-dash" "$HOME/.claude/projects" "$HOME/.config/claude-fleet" "$HOME/.colima"; do
      [ -d "$d" ] || continue
      printf '%12s  %s\n' "$(tmo 8 du -shx "$d" 2>/dev/null | awk '{print $1}')" "$d"
    done
    echo
    echo "## top processes by RSS"
    ps -Ao pid,rss,comm 2>/dev/null | sort -k2,2nr | head -15 \
      | awk '{ printf "%-8s %8.1fMB  %s\n", $1, $2/1024, $3 }'
  } > "$inc" 2>/dev/null
  printf '%s' "$inc"
}

case "${1:-}" in
  --free)
    free_gb; echo
    ;;
  --gate)
    floor="${2:-$FLOOR_GB}"
    free=$(free_gb)
    # If df failed (empty), fail OPEN — never block the fleet on a measurement bug.
    [ -z "$free" ] && exit 0
    if [ "$free" -lt "$floor" ]; then
      echo "fleet-diskguard: LOW DISK — ${free}GB free < ${floor}GB floor on $TARGET; refusing to add fleet load" >&2
      exit 3
    fi
    ;;
  --probe)
    free=$(free_gb); [ -z "$free" ] && free=-1
    inc=$(capture "manual --probe" "$free")
    now > "$STAMP" 2>/dev/null || true
    echo "fleet-diskguard: incident written → $inc"
    ;;
  --watch)
    free=$(free_gb)
    [ -z "$free" ] && exit 0                      # measurement failed — stay quiet
    [ "$free" -ge "$WARN_GB" ] && exit 0          # healthy
    # Below warn. Cooldown-gate so a sustained low-disk episode captures once, but
    # re-capture immediately if it got materially worse (dropped ≥5GB since last).
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    lastfree=$(cat "$STAMP.free" 2>/dev/null || echo 999)
    age=$(( $(now) - last ))
    if [ "$age" -lt "$COOLDOWN" ] && [ "$free" -ge $(( lastfree - 5 )) ]; then
      exit 0
    fi
    inc=$(capture "watch: free below ${WARN_GB}GB" "$free")
    now > "$STAMP" 2>/dev/null || true
    echo "$free" > "$STAMP.free" 2>/dev/null || true
    notify "# ⚠ fleet disk low: ${free}GB free
Volume backing \`$TARGET\` is under the ${WARN_GB}GB warn line. Forensic snapshot:
\`$inc\`
Fleet spawn/auto-restore is now gated at ${FLOOR_GB}GB — inspect the incident for the runaway writer."
    ;;
  -h|--help|"")
    sed -n '2,40p' "$0"
    ;;
  *)
    echo "fleet-diskguard: unknown mode '$1' (see --help)" >&2; exit 2
    ;;
esac
exit 0
