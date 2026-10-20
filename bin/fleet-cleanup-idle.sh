#!/bin/bash
# Automatic done-raw window cleanup. Keeps worktree/branch/transcript for restore.
# Also the finished sessions no PR will ever close (issue #1832): `cleaned:done-no-pr`
# / `skip:<why>` on stdout, one line a window — fleet-cleanup-idle.py no_pr().
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

# --now <ID> [--after <s>] [--fg] (T680): the moment a session's result lands
# (fleet-report-parent.sh, fleet-id.sh result — fleet_reap_soon) its window is
# watched, not left for the next tick: every FLEET_REAP_NOW_EVERY s (10) one pass
# over THAT window only (--only), its task grace <after> (60) past its last turn,
# so «做完» → closed is about a minute once the turn ends. Every gate of the
# task route still holds (history first, worktree kept, never while working,
# looping or holding a job). Ends when the window closes or is gone, or after
# FLEET_REAP_NOW_MAX s (1200) — the ordinary tick takes over then. One watcher an
# ID (a pid file under $FLEET_CONF_DIR/reap-now); detached unless --fg, cwd /.
if [ "${1:-}" = --now ]; then
  fid=${2:-}; after=60; fg=0
  if [ "$#" -ge 2 ]; then shift 2; else shift "$#"; fi
  while [ "$#" -gt 0 ]; do
    case "$1" in --after) shift; after=${1:-60} ;; --fg) fg=1 ;; esac
    [ "$#" -gt 0 ] && shift
  done
  fleet_is_fid "$fid" || { echo "usage: fleet-cleanup-idle.sh --now <fleet_id> [--after s] [--fg]" >&2; exit 2; }
  case "$after" in ''|*[!0-9]*) after=60 ;; esac
  [ "${FLEET_REAP_NOW:-1}" != 0 ] || exit 0
  cdir="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
  if [ "$fg" != 1 ]; then
    mkdir -p "$cdir/logs" 2>/dev/null
    ( cd / && nohup bash "$BIN/fleet-cleanup-idle.sh" --now "$fid" --after "$after" --fg \
        >>"$cdir/logs/reap-now.log" 2>&1 </dev/null & ) >/dev/null 2>&1
    exit 0
  fi
  # now_find → sess / win of the window carrying <ID>, empty when none here
  now_find() {
    sess='' win=''
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      w=$(fleet_win_for_fid "$fid" "$s" 2>/dev/null) && { sess=$s; win=$w; break; }
    done <<NOW_EOF
$(fleet_sockets)
NOW_EOF
  }
  # Only a task session's close is this watcher's (the task route); anything
  # else — no window here, a keyed issue worker, a no-repo session — is the tick's.
  now_find
  [ -n "$win" ] || exit 0
  case "$(tmux -L "$(fleet_socket "$sess")" display-message -p -t "$win" '#{@task_flow}|#{@task}' 2>/dev/null)" in
    1\|T[1-9]*) ;; *) exit 0 ;;
  esac
  mkdir -p "$cdir/reap-now" 2>/dev/null || exit 0
  lk="$cdir/reap-now/$fid.pid"
  if [ -f "$lk" ] && kill -0 "$(cat "$lk" 2>/dev/null)" 2>/dev/null; then exit 0; fi
  echo $$ > "$lk"
  trap 'rm -f "$lk"' EXIT
  every="${FLEET_REAP_NOW_EVERY:-10}"; max="${FLEET_REAP_NOW_MAX:-1200}"
  case "$every" in ''|*[!0-9]*|0) every=10 ;; esac
  case "$max" in ''|*[!0-9]*) max=1200 ;; esac
  end=$(( $(date +%s) + max ))
  export FLEET_REAP_MIN_AGE="${FLEET_REAP_MIN_AGE:-300}"
  while [ "$(date +%s)" -lt "$end" ]; do
    now_find
    [ -n "$win" ] || { printf '%s now %s gone\n' "$(date -u +%FT%TZ)" "$fid"; exit 0; }
    out=$( export FLEET_SESSION="$sess"
      fleet_load_conf "$sess"
      repo=$(fleet_window_repo "$sess" "$win") && [ -n "$repo" ] || exit 0
      fleet_load_repo_conf "$sess" "$repo" || exit 0
      [ "${FLEET_CLEANUP:-1}" != 0 ] || exit 0
      python3 "$BIN/fleet-cleanup-idle.py" --session "$sess" --socket-name "$(fleet_socket "$sess")" \
        --main "${FLEET_MAIN:-}" --repo "$repo" --base "${FLEET_BASE_BRANCH:-master}" \
        ${FLEET_FORGE:+--forge "$( [ "$FLEET_FORGE" = none ] && echo none || echo github )"} \
        --only "$win" --grace "$after" --limit 1 )
    [ -z "$out" ] || printf '%s now %s %s\n' "$(date -u +%FT%TZ)" "$fid" "$out"
    case "$out" in *reaped-*|*cleaned:*) exit 0 ;; esac
    sleep "$every"
  done
  printf '%s now %s timeout — the tick takes over\n' "$(date -u +%FT%TZ)" "$fid"
  exit 0
fi

FLEET_SESSION="${1:?session required}"; shift
fleet_load_conf "$FLEET_SESSION"
# FLEET_CLEANUP is switched per repo (issue #978) — in the loop below.
export FLEET_SESSION
export FLEET_REAP_MIN_AGE="${FLEET_REAP_MIN_AGE:-300}"
export FLEET_REAP_IDLE_DONE_MIN="${FLEET_REAP_IDLE_DONE_MIN:-30}"
# One pass per hosted repo (issues #791, #1941), each with THAT repo's MAIN/base,
# sharing the caller's --limit. The pass only considers windows stamped with its
# repo; a window whose repo is unknown or none is never closed here.
limit=4; rest=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --limit) shift; limit="${1:-4}" ;;
    *) rest+=("$1") ;;
  esac
  shift
done
case "$limit" in ''|*[!0-9]*) limit=4 ;; esac
# Resolve every window's repo ONCE first — @repo is the only field the per-repo
# pass reads. fleet_window_repo stamps it from the window's @worktree; a worktree
# window it answers by the fleet's ONLY repo (a worktree with no origin) is
# stamped here too, so adding a second repo later cannot orphan it (#1941).
_sock=$(fleet_socket "$FLEET_SESSION")
while IFS='|' read -r w wr wt; do   # '|', not a space: an empty @repo must not collapse
  [ -n "$w" ] && [ -z "$wr" ] || continue
  r=$(fleet_window_repo "$FLEET_SESSION" "$w")
  [ -n "$r" ] && [ -n "$wt" ] && tmux -L "$_sock" set-option -w -t "$w" @repo "$r" 2>/dev/null
done <<EOF
$(tmux -L "$_sock" list-windows -t "$FLEET_SESSION" -F '#{window_id}|#{@repo}|#{@worktree}' 2>/dev/null)
EOF
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  [ "$limit" -gt 0 ] || break
  out=$( fleet_load_repo_conf "$FLEET_SESSION" "$repo" || exit 0
    [ "${FLEET_CLEANUP:-1}" != 0 ] || exit 0
    python3 "$BIN/fleet-cleanup-idle.py" --session "$FLEET_SESSION" \
      --socket-name "$(fleet_socket "$FLEET_SESSION")" --main "${FLEET_MAIN:-}" \
      --repo "$repo" --base "${FLEET_BASE_BRANCH:-master}" --window-repo \
      ${FLEET_FORGE:+--forge "$( [ "$FLEET_FORGE" = none ] && echo none || echo github )"} \
      --limit "$limit" ${rest[@]+"${rest[@]}"} )
  rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  [ "$rc" = 75 ] && exit 75
  limit=$(( limit - $(printf '%s\n' "$out" | grep -cE '^(reaped-idle|reaped-task|cleaned:done-no-pr)') ))
done <<EOF
$(fleet_repos "$FLEET_SESSION")
EOF
exit 0
