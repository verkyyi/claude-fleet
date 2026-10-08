#!/bin/bash
# fleet-sessions-snapshot.sh — pin every live session before a node restart or
# update, and bring each one back afterwards (issue #2484, EPIC #2482 C5).
#
#   fleet-sessions-snapshot.sh save      refresh the restore maps, then pin the
#                                        unfinished sessions to
#                                        $FLEET_CONF_DIR/global/sessions.snapshot
#   fleet-sessions-snapshot.sh restore   reopen every pinned session that is not
#                                        live, then say per session whether it
#                                        came back (exit 0 all back · 1 not all ·
#                                        3 no snapshot)
#   fleet-sessions-snapshot.sh show      print the pinned snapshot
#
# Nothing here reopens a session itself: `restore` hands the pinned maps to
# fleet-restore.sh — the one road back (same name, same worktree, the same
# transcript via fleet-session-wrap.sh --resume, @fleet_id / @reap_policy stamped
# back) that the diskguard tick's --auto already takes after a kill-server. What
# this adds is the PIN: the collector rewrites restore.map every minute, so a map
# read after a restart is whatever the last tick saw; the snapshot is the layout
# as it stood the moment before the operator (or fleet-node-update.py) took the
# server down, and it is checked against GitHub on the way back:
#   · only unfinished sessions are pinned (@claude_state not done/exited);
#   · a session whose issue was CLOSED since is not reopened (`closed`);
#   · a session the fleet retired since (fleet_win_retire) is not (`retired`);
#   · a session whose worktree is gone is not (`gone`) — never one waking up in
#     a deleted directory (EPIC #2482's metric);
#   · a fleet `fleet-down` took down on purpose is left down (`down`).
#
# global/sessions.snapshot — one header line, then one TSV row per session:
#   <fleet session> <key> <cwd> <transcript id> <reap policy> <fleet_id> <issue> <state> <repo>
# ('-' for an empty field). global/sessions.snapshot.d/<fleet>.map is the same
# sessions in restore.map's own format — what `restore` hands to fleet-restore.sh.
#
# Restore takes fleet-restore's --auto lock, so a diskguard tick pulling the same
# fleet up waits its turn; either order ends with each session open once.
#
# Seams (selftests): FLEET_SESSIONS_STATE_CMD "<cmd>" is run as `<cmd> <repo>
# <issue>` and prints OPEN / CLOSED (default: fleet-gh.sh's cached read; no
# answer ⇒ treated as open — a session is never dropped on a failed read).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
PATH=$(fleet_path_fill); export PATH

GDIR="$FLEET_CONF_DIR/global"
SNAP="$GDIR/sessions.snapshot"
SDIR="$GDIR/sessions.snapshot.d"
RDIR="$FLEET_CONF_DIR/restore"
LOG="$RDIR/restore.log"
PANEL_RE='^(dash|plan|backlog|home)$'

log() { mkdir -p "$RDIR"; printf '%s sessions-snapshot: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null; }

# issue_state <repo> <issue> → OPEN | CLOSED | '' (unknown)
issue_state() {
  local repo="$1" n="$2"
  case "$n" in ''|-|*[!0-9]*) return 0 ;; esac
  case "$repo" in ''|-|norepo*) return 0 ;; esac
  if [ -n "${FLEET_SESSIONS_STATE_CMD:-}" ]; then
    $FLEET_SESSIONS_STATE_CMD "$repo" "$n" 2>/dev/null | head -n 1
    return 0
  fi
  bash "$BIN/fleet-gh.sh" issue view "$n" --repo "$repo" --json state --max-age 300 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("state",""))
except Exception: pass' 2>/dev/null
}

save() {
  bash "$BIN/fleet-restore.sh" --snapshot >/dev/null 2>&1 || :
  mkdir -p "$SDIR"
  local tmp="$SNAP.tmp.$$" d mf sess n=0 total=0
  printf '# fleet-sessions-snapshot v1 %s fleet sess · key · cwd · sid · reap · fleet_id · issue · state · repo\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
  rm -f "$SDIR"/*.map.tmp 2>/dev/null
  for d in "$FLEET_CONF_DIR"/fleets/*/; do
    [ -d "$d" ] || continue
    mf="${d}restore.map"; [ -f "$mf" ] || continue
    sess=${d%/}; sess=${sess##*/}
    fleet_is_pool_session "$sess" && continue
    # One pass over the map: REAP / FID rows ride with the WIN row they precede;
    # a finished or panel row drops with them. The map copy keeps restore.map's
    # own format; the TSV is the readable list.
    n=$(awk -F'\t' -v OFS='\t' -v sess="$sess" -v panel="$PANEL_RE" -v tsv="$tmp" -v map="$SDIR/$sess.map.tmp" '
      function v(x) { return (x == "" ? "-" : x) }
      $1 == "FLEET" { print > map; next }
      $1 == "REAP"  { reap[$2] = $3; pend = pend $0 "\n"; next }
      $1 == "FID"   { fid = $2; pend = pend $0 "\n"; next }
      $1 == "WIN" {
        keep = ($6 != "done" && $6 != "exited" && $2 !~ panel)
        if (keep) {
          printf "%s%s\n", pend, $0 > map
          repo = (NF >= 16 ? $16 : "")
          print sess, v($2), v($3), v($4), v(fid != "" ? reap[fid] : ""), v(fid), v($5), v($6), v(repo) >> tsv
          c++
        }
        pend = ""; fid = ""; next
      }
      { pend = ""; fid = "" }
      END { print c + 0 }' "$mf")
    if [ "${n:-0}" -gt 0 ]; then mv -f "$SDIR/$sess.map.tmp" "$SDIR/$sess.map"
    else rm -f "$SDIR/$sess.map.tmp" "$SDIR/$sess.map"; fi
    total=$((total + ${n:-0}))
  done
  # a fleet with no map any more leaves no stale copy behind
  for mf in "$SDIR"/*.map; do
    [ -f "$mf" ] || continue
    sess=${mf##*/}; sess=${sess%.map}
    [ -f "$FLEET_CONF_DIR/fleets/$sess/restore.map" ] || rm -f "$mf"
  done
  mv -f "$tmp" "$SNAP"
  log "save: $total session(s) pinned"
  printf 'saved %s session(s) → %s\n' "$total" "$SNAP"
}

# live_has <sock> <sess> <fid> <key> <cwd> — is this session open now?
live_has() {
  local rows
  rows=$(fleet_lw '#{@fleet_id}|#{window_name}|#{?@worktree,#{@worktree},#{pane_current_path}}' tmux -L "$1" 2>/dev/null)
  [ -n "$rows" ] || return 1
  [ "$3" != - ] && printf '%s\n' "$rows" | cut -d'|' -f1 | grep -qxF "$3" && return 0
  printf '%s\n' "$rows" | cut -d'|' -f2,3 | grep -qxF "$4|$5"
}

restore() {
  [ -s "$SNAP" ] || { printf 'no snapshot (%s) — run save first\n' "$SNAP" >&2; return 3; }
  mkdir -p "$RDIR"
  local lk="$RDIR/.auto.lock" holder i
  for i in $(seq 1 120); do
    mkdir "$lk" 2>/dev/null && break
    holder=$(cat "$lk/pid" 2>/dev/null)
    if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lk"; continue; fi
    sleep 1
  done
  [ -d "$lk" ] || { printf 'restore: the restore lock is held — try again\n' >&2; return 1; }
  printf '%s\n' "$$" > "$lk/pid"
  # shellcheck disable=SC2064
  trap "rm -rf '$lk'" EXIT

  local skip="$SDIR/.skip.$$" sess key cwd sid reap fid issue state repo st mf tmp
  : > "$skip"
  # 1. what must NOT come back: closed issue · retired · worktree gone · fleet down
  while IFS=$'\t' read -r sess key cwd sid reap fid issue state repo; do
    case "$sess" in ''|'#'*) continue ;; esac
    if [ -f "$FLEET_CONF_DIR/fleets/$sess/restore.down" ]; then
      printf '%s\t%s\tdown\n' "$sess" "$key" >> "$skip"; continue
    fi
    if [ "$fid" != - ] && fleet_fid_retired "$fid"; then
      printf '%s\t%s\tretired\n' "$sess" "$key" >> "$skip"; continue
    fi
    st=$(issue_state "$repo" "$issue")
    if [ "$st" = CLOSED ]; then printf '%s\t%s\tclosed\n' "$sess" "$key" >> "$skip"; continue; fi
    [ "$repo" = - ] && cwd="$HOME"
    [ -d "$cwd" ] || { printf '%s\t%s\tgone\n' "$sess" "$key" >> "$skip"; continue; }
  done < "$SNAP"

  # 2. the rest goes back through fleet-restore — one pinned map per fleet
  for mf in "$SDIR"/*.map; do
    [ -f "$mf" ] || continue
    sess=${mf##*/}; sess=${sess%.map}
    tmp="$SDIR/.$sess.restore.$$"
    awk -F'\t' -v sess="$sess" 'NR == FNR { if ($1 == sess) drop[$2] = 1; next }
      $1 == "FLEET" { print; next }
      $1 == "REAP" || $1 == "FID" { pend = pend $0 "\n"; next }
      $1 == "WIN" { if (!($2 in drop)) printf "%s%s\n", pend, $0; pend = ""; next }' "$skip" "$mf" > "$tmp"
    if grep -q '^WIN' "$tmp"; then
      log "restore: $sess — $(grep -c '^WIN' "$tmp") pinned session(s)"
      RESTORE_ONLY_MAP="$tmp" RESTORE_UNFINISHED=1 bash "$BIN/fleet-restore.sh" >/dev/null 2>&1 || :
    fi
    rm -f "$tmp"
  done

  # 3. one line per pinned session: did it come back?
  local miss=0 why sock
  while IFS=$'\t' read -r sess key cwd sid reap fid issue state repo; do
    case "$sess" in ''|'#'*) continue ;; esac
    why=$(awk -F'\t' -v s="$sess" -v k="$key" '$1 == s && $2 == k { print $3; exit }' "$skip")
    if [ -n "$why" ]; then printf '%s\t%s\t%s\t%s\n' "$why" "$sess" "$key" "$cwd"; continue; fi
    [ "$repo" = - ] && cwd="$HOME"
    sock=$(fleet_socket "$sess")
    if live_has "$sock" "$sess" "$fid" "$key" "$cwd"; then printf 'back\t%s\t%s\t%s\n' "$sess" "$key" "$cwd"
    else printf 'missing\t%s\t%s\t%s\n' "$sess" "$key" "$cwd"; miss=$((miss + 1)); fi
  done < "$SNAP"
  rm -f "$skip"
  log "restore: done, $miss missing"
  [ "$miss" = 0 ]
}

case "${1:-}" in
  save)    save ;;
  restore) restore; exit $? ;;
  show)    [ -s "$SNAP" ] && cat "$SNAP" || { printf 'no snapshot (%s)\n' "$SNAP" >&2; exit 3; } ;;
  *) echo "usage: fleet-sessions-snapshot.sh save|restore|show" >&2; exit 2 ;;
esac
