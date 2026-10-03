#!/bin/bash
# fleet-transcript-archive.sh — move stale, unreferenced Claude transcripts out of
# ~/.claude/projects into a compressed, restorable archive (issue #1299).
#
# WHY: Claude Code writes one `<session-id>.jsonl` per session into
# ~/.claude/projects/<encoded-cwd>/ and never removes any. On 2026-10-03 this login
# held 6632 of them (2.6 GB), one scratchpad project dir alone 2822 — almost all of
# them the fleet's own status-classifier `claude -p` runs (issue #1296 stopped
# new ones). A directory that only grows is a startup cost every new session in
# that cwd pays, and eventually a stall.
#
# WHAT moves (the diskguard --watch tick runs `--run` once a day):
#   stale   a `.jsonl` untouched for FLEET_TRANSCRIPT_KEEP_DAYS (default 30)
#   helper  a fleet HELPER transcript (a known helper prompt in its head —
#           fleet_is_helper_transcript's `marker` kind, never `thin`, which can be a
#           short real chat) untouched for FLEET_TRANSCRIPT_HELPER_KEEP_HOURS
#           (default 24). Nobody resumes a classifier run; these are the bulk.
# Scratchpad project dirs (`…-scratchpad`) go first — they are where helpers piled up.
#
# WHAT NEVER moves — a REFERENCED transcript, whatever its age:
#   * any session id in a restore map ($FLEET_CONF_DIR/fleets/**/restore.map*) —
#     what a crash-restore resumes
#   * any session id in a /fleet-history ledger (logs/landed_*.tsv,
#     $FLEET_HISTORY_LEDGER) — what /fleet-history resumes
#   * every LIVE session: each fleet window's hook-recorded @cc_session_id and the
#     newest resumable transcript in its cwd (fleet_sockets), and every running
#     Claude process in the session registry (~/.claude/sessions/*.json)
# The match is on the id anywhere in those files, so a column added later is
# still honoured. A session's sibling `<id>/` dir (subagents, tool results) moves
# with it, in the same tarball.
#
# WHERE: $FLEET_CONF_DIR/transcript-archive/<project-dir>/<id>.tar.gz, plus an
# append-only archive.log (iso · archived|restored · reason · project · id · bytes).
# `--restore <id>` puts it back exactly where it was and touches it, so it starts a
# fresh lease instead of being re-archived on the next tick.
#
# Modes:
#   --run [--dry-run] [--budget S]   archive what qualifies; prints one summary line.
#                     Exit 0 = done, 75 = budget (default 30s) ran out with work
#                     left (the caller retries next tick), 1 = another run holds the lock.
#   --restore <id> [--quiet]         restore one archived session. Exit 0 restored or
#                     already present, 1 = not in the archive.
#   --list            archived sessions: "<project>\t<id>\t<bytes>"
#   --counts          per-project-dir .jsonl counts, largest first: "<n>\t<dir>"
#   --referenced      the referenced session ids, one per line (what is protected)
#   --help
#
# Config (fleet.conf; all optional):
#   FLEET_TRANSCRIPT_KEEP_DAYS          idle days before a session is archived (30)
#   FLEET_TRANSCRIPT_HELPER_KEEP_HOURS  idle hours before a helper is archived (24)
#   FLEET_TRANSCRIPT_ARCHIVE            0 = the daily diskguard pass is OFF (default 1)
#   CLAUDE_PROJECTS_DIR                 transcript root (default ~/.claude/projects)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

PROJ="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
ARCH="$FLEET_CONF_DIR/transcript-archive"
LOG="$ARCH/archive.log"
KEEP_DAYS="${FLEET_TRANSCRIPT_KEEP_DAYS:-30}"
HELPER_HOURS="${FLEET_TRANSCRIPT_HELPER_KEEP_HOURS:-24}"
case "$KEEP_DAYS" in ''|*[!0-9]*) KEEP_DAYS=30 ;; esac
case "$HELPER_HOURS" in ''|*[!0-9]*) HELPER_HOURS=24 ;; esac
[ "$KEEP_DAYS" -ge 1 ] || KEEP_DAYS=1            # a live session is never "stale"
[ "$HELPER_HOURS" -ge 1 ] || HELPER_HOURS=1      # nor is a helper still being written
LOCK=''
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

log_row() {   # $1=action $2=reason $3=project $4=id $5=bytes
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$5" >> "$LOG" 2>/dev/null
}

# Every session id something still points at. Over-protecting is free (a file is
# merely kept); under-protecting loses a resumable session, so read wide.
referenced_ids() {
  local f p d s
  {
    [ -d "$FLEET_CONF_DIR/fleets" ] && find "$FLEET_CONF_DIR/fleets" -maxdepth 4 -type f -name 'restore.map*' 2>/dev/null |
      while IFS= read -r f; do cat "$f" 2>/dev/null; done
    for f in "$BIN/../logs"/landed_*.tsv "$HOME/.claude/fleet/logs"/landed_*.tsv "${FLEET_HISTORY_LEDGER:-}"; do
      [ -n "$f" ] && [ -f "$f" ] && cat "$f" 2>/dev/null
    done
    # Every running Claude process — fleet pane or not — via its session registry.
    for f in "$FLEET_CC_SESSIONS_DIR"/*.json; do [ -f "$f" ] && cat "$f" 2>/dev/null; done
    # A live window's session: its hook-recorded @cc_session_id, plus the newest
    # resumable transcript in its cwd's dir — the rules the restore snapshot uses.
    fleet_list_windows_all '#{@cc_session_id}|#{pane_current_path}' 2>/dev/null | sort -u | while IFS='|' read -r s p; do
      [ -n "$s" ] && printf '%s\n' "$s"
      [ -n "$p" ] || continue
      d=$(fleet_transcript_dir "$p")
      fleet_newest_resumable_session "$d" 2>/dev/null
      s=$(fleet_newest_human_session "$d" 2>/dev/null); [ -n "$s" ] && printf '%s\n' "$s"
    done
  } | grep -oE "$UUID_RE" | sort -u
}

archive_one() {   # $1=jsonl path $2=reason $3=dry → 0 archived
  local f="$1" why="$2" dry="$3" pdir proj id dest out bytes members
  pdir=${f%/*}; proj=${pdir##*/}; id=${f##*/}; id=${id%.jsonl}
  printf '%s\n' "$id" | grep -qxE "$UUID_RE" || return 1
  bytes=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  if [ "$dry" = 1 ]; then printf 'would-archive\t%s\t%s\t%s\n' "$why" "$proj" "$id"; return 0; fi
  dest="$ARCH/$proj"; out="$dest/$id.tar.gz"
  mkdir -p "$dest" 2>/dev/null || return 1
  members="$id.jsonl"
  [ -d "$pdir/$id" ] && members="$members $id"
  # shellcheck disable=SC2086  # members are two fixed, space-free names
  tar -czf "$out.tmp" -C "$pdir" $members 2>/dev/null || { rm -f "$out.tmp"; return 1; }
  tar -tzf "$out.tmp" 2>/dev/null | grep -qxF "$id.jsonl" || { rm -f "$out.tmp"; return 1; }
  mv -f "$out.tmp" "$out" || { rm -f "$out.tmp"; return 1; }
  rm -f "$pdir/$id.jsonl"
  [ -d "$pdir/$id" ] && rm -rf "${pdir:?}/${id:?}"
  log_row archived "$why" "$proj" "$id" "${bytes:-0}"
  return 0
}

cmd_run() {
  local dry=0 budget=30
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --budget) budget="${2:-30}"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$budget" in ''|*[!0-9]*) budget=30 ;; esac
  [ -d "$PROJ" ] || { echo "transcript-archive: no $PROJ — nothing to do"; return 0; }
  mkdir -p "$ARCH" 2>/dev/null || return 1
  if [ "$dry" = 0 ]; then
    LOCK="$ARCH/.lock"
    if ! mkdir "$LOCK" 2>/dev/null; then
      # A lock older than an hour is a crashed run's; take it over.
      if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
        rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || { LOCK=''; return 1; }
      else
        echo "transcript-archive: another run holds $LOCK" >&2; LOCK=''; return 1
      fi
    fi
    trap '[ -n "$LOCK" ] && rmdir "$LOCK" 2>/dev/null' EXIT
  fi
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/fleet-transcript-archive.XXXXXX") || return 1
  referenced_ids > "$tmp/refs"
  # Candidates: every top-level .jsonl idle past the helper lease, as
  # "<stale 0|1>\t<scratchpad-first rank>\t<path>", minus the referenced ids.
  find "$PROJ" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -mmin +$((KEEP_DAYS * 1440)) 2>/dev/null > "$tmp/stale"
  find "$PROJ" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -mmin +$((HELPER_HOURS * 60)) 2>/dev/null |
    awk -v refs="$tmp/refs" -v stale="$tmp/stale" '
      BEGIN { while ((getline l < refs) > 0) ref[l] = 1
              while ((getline l < stale) > 0) old[l] = 1 }
      { id = $0; sub(/.*\//, "", id); sub(/\.jsonl$/, "", id)
        if (id in ref) { skipped++; next }
        rank = ($0 ~ /-scratchpad\/[^\/]*$/) ? 0 : 1
        printf "%d\t%d\t%s\n", (($0 in old) ? 1 : 0), rank, $0 }
      END { print skipped + 0 > "/dev/stderr" }' 2> "$tmp/nref" | sort -t "$(printf '\t')" -k2,2n -k1,1nr > "$tmp/cand"
  local nref stale_n=0 helper_n=0 left=0 is_old f
  nref=$(cat "$tmp/nref" 2>/dev/null); nref=${nref:-0}
  local start=$SECONDS out=0
  while IFS="$(printf '\t')" read -r is_old _ f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    if [ $((SECONDS - start)) -ge "$budget" ]; then out=75; left=$((left + 1)); continue; fi
    if [ "$is_old" = 1 ]; then
      archive_one "$f" stale "$dry" && stale_n=$((stale_n + 1))
    elif fleet_is_helper_transcript "$f" && [ "$FLEET_HELPER_REASON" = marker ]; then
      archive_one "$f" helper "$dry" && helper_n=$((helper_n + 1))
    fi
  done < "$tmp/cand"
  rm -rf "$tmp"
  printf 'transcript-archive: %s %d (stale %d, helper %d) · referenced-kept %s · left %d · keep %dd/helper %dh\n' \
    "$([ "$dry" = 1 ] && echo would-archive || echo archived)" $((stale_n + helper_n)) "$stale_n" "$helper_n" \
    "$nref" "$left" "$KEEP_DAYS" "$HELPER_HOURS"
  return "$out"
}

cmd_restore() {
  local id="" quiet=0 tb proj dest
  while [ $# -gt 0 ]; do
    case "$1" in --quiet) quiet=1; shift ;; *) id="$1"; shift ;; esac
  done
  id=${id%.jsonl}
  printf '%s\n' "$id" | grep -qxE "$UUID_RE" || { echo "transcript-archive: --restore needs a session id" >&2; return 2; }
  tb=$(find "$ARCH" -mindepth 2 -maxdepth 2 -type f -name "$id.tar.gz" 2>/dev/null | head -1)
  if [ -z "$tb" ]; then
    tb=$(find "$PROJ" -mindepth 2 -maxdepth 2 -type f -name "$id.jsonl" 2>/dev/null | head -1)
    if [ -n "$tb" ]; then [ "$quiet" = 1 ] || echo "transcript-archive: $tb already present"; return 0; fi
    [ "$quiet" = 1 ] || echo "transcript-archive: $id is not in $ARCH" >&2
    return 1
  fi
  proj=${tb%/*}; proj=${proj##*/}; dest="$PROJ/$proj"
  if [ -f "$dest/$id.jsonl" ]; then
    [ "$quiet" = 1 ] || echo "transcript-archive: $dest/$id.jsonl already present"
    return 0
  fi
  mkdir -p "$dest" || return 1
  tar -xzf "$tb" -C "$dest" 2>/dev/null && [ -f "$dest/$id.jsonl" ] || {
    echo "transcript-archive: extracting $tb failed" >&2; return 1; }
  touch "$dest/$id.jsonl"
  rm -f "$tb"
  log_row restored - "$proj" "$id" "$(wc -c < "$dest/$id.jsonl" | tr -d ' ')"
  [ "$quiet" = 1 ] || echo "transcript-archive: restored $dest/$id.jsonl"
  return 0
}

cmd_list() {
  [ -d "$ARCH" ] || return 0
  find "$ARCH" -mindepth 2 -maxdepth 2 -type f -name '*.tar.gz' 2>/dev/null | while IFS= read -r tb; do
    p=${tb%/*}; i=${tb##*/}
    printf '%s\t%s\t%s\n' "${p##*/}" "${i%.tar.gz}" "$(wc -c < "$tb" | tr -d ' ')"
  done | sort
}

cmd_counts() {
  [ -d "$PROJ" ] || return 0
  find "$PROJ" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' 2>/dev/null |
    awk '{ d = $0; sub(/\/[^\/]*$/, "", d); sub(/.*\//, "", d); n[d]++ }
         END { for (d in n) printf "%d\t%s\n", n[d], d }' | sort -rn
}

case "${1:-}" in
  --run)        shift; cmd_run "$@"; exit $? ;;
  --restore)    shift; cmd_restore "$@"; exit $? ;;
  --list)       cmd_list ;;
  --counts)     cmd_counts ;;
  --referenced) referenced_ids ;;
  -h|--help|"") awk 'NR > 1 && /^set -uo/ { exit } NR > 1' "$0" ;;
  *) echo "fleet-transcript-archive: unknown mode '$1' (see --help)" >&2; exit 2 ;;
esac
exit 0
