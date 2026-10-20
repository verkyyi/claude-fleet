#!/bin/bash
# fleet-view-reap-all.sh <fleet> <target>... — the 看台 panel's 「收起已结束的 N 个」 row
# at the end of 排队中 (issue #3731, 回收 D): every ended session there, one by one,
# through the reap a row's own Tab → 回收 runs. Nothing here decides what is safe:
#   a session here      dash-reap.sh <target> --yes — its own gate: a dirty
#                       worktree is KEPT (only the window closes), a live / young
#                       agent or a reap hold is skipped (skip:live)
#   wid:<worker_id>     another machine's — fleet-row-remote.sh reap, the hub's
#                       worker_reap, which is the same dash-reap.sh --yes there
# Prints ONE line for the person: how many were reaped, how many worktrees were
# kept for their uncommitted changes, how many were left (and why, the first one).
# rc 0 when nothing failed, 1 when one did, 2 on usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

[ "$#" -ge 2 ] || { echo "usage: fleet-view-reap-all.sh <fleet> <target>..." >&2; exit 2; }
FLEET=$1; shift
t() { sh "$BIN/fleet-ui-lang.sh" t "$@" 2>/dev/null; }

full=0 kept=0 left=0 bad=0 why=''
for tg in "$@"; do
  case "$tg" in
    wid:*)
      out=$(FLEET_REMOTE_SAY=print bash "$BIN/fleet-row-remote.sh" reap "$FLEET" "$tg" 2>&1); rc=$?
      if [ "$rc" = 0 ]; then full=$((full + 1)); else bad=$((bad + 1)); [ -n "$why" ] || why=$(printf '%s\n' "$out" | tail -1); fi
      continue ;;
  esac
  out=$(bash "$BIN/dash-reap.sh" "$tg" --yes 2>&1); rc=$?
  tok=$(printf '%s\n' "$out" | grep -E '^(reaped|skip|failed|refused|dispatched):' | tail -1)
  case "$tok" in
    reaped:keep)        kept=$((kept + 1)) ;;
    reaped:*|dispatched:*) full=$((full + 1)) ;;
    skip:*)             left=$((left + 1)); [ -n "$why" ] || why=$(printf '%s\n' "$out" | grep -v -E '^skip:' | tail -1) ;;
    *)                  bad=$((bad + 1)); [ -n "$why" ] || why="${tok:-rc $rc}" ;;
  esac
done

line=$(t view_reapall_done_fmt "$full")
[ "$kept" -gt 0 ] && line="$line · $(t view_reapall_kept_fmt "$kept")"
[ "$left" -gt 0 ] && line="$line · $(t view_reapall_left_fmt "$left")"
[ "$bad" -gt 0 ] && line="$line · $(t view_reapall_failed_fmt "$bad")"
[ -n "$why" ] && line="$line — ${why}"
printf '%s\n' "$line"
[ "$bad" = 0 ]
