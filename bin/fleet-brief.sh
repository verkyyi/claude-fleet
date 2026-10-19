#!/bin/bash
# fleet-brief.sh [--repo R] [-h] — the ONE opening read of a session that does
# development work (the `brief` tool; issue #4898, EPIC #4895 批 1).
#
# It replaced the claim brief when the GitHub-issue claim layer went: a
# session is bound to the hub's task record (@task T<n>), or — opened on an
# existing GitHub issue (@issue N) — to that issue's words, already its first
# turn. Nothing here claims, assigns, comments on or reads an issue: the record is
# the ticket, and a PR's `Closes #N` is the only thing that touches an issue.
#
# It prints, in order:
#   fleet     — session / repo / base / base checkout / merge (or land) method,
#               and the window's `@origin`: WHO spawned it, owed a report
#   task      — the record (title · state · the request), read off the hub
#   flow      — implement → PR → pr_verdict / pr_merge → report
#   directive — fleet_worker_prompt_body: the per-fleet HOW-to guidance (#234)
#   language  — the one-language rule (#620), LAST: the latest instruction wins
#
# Exit: 0 printed · 2 no fleet resolved (never guess a repo) · 4 nothing bound
# (no @task, no @issue, not an issue-<N> worktree) · 5 the record could not be
# read (no hub answer — everything else is still printed first).
# Strictly read-only.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

repo_arg=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)    shift; repo_arg="${1:-}" ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         printf 'fleet-brief: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

die() { printf '%s\n' "$1" >&2; exit "$2"; }

sess=$(fleet_current_session)
fleet_load_conf "$sess"
repo="${repo_arg:-$(fleet_pane_fmt '#{@repo}')}"
[ -n "$repo" ] || repo="${FLEET_REPO:-}"
[ -n "$repo" ] || repo=$(fleet_repo_cached "$sess")
base="${FLEET_BASE_BRANCH:-master}"
main="${FLEET_MAIN:-}"

at_task=$(fleet_pane_fmt '#{@task}')
case "$at_task" in T[1-9]*) case "${at_task#T}" in *[!0-9]*) at_task='' ;; esac ;; *) at_task='' ;; esac
at_issue=$(fleet_pane_fmt '#{@issue}'); at_issue="${at_issue//[^0-9]/}"
cwd=$(pwd -P 2>/dev/null)
case "$cwd" in */*issue-[0-9]*) _n="${cwd##*issue-}"; [ -n "$at_issue" ] || at_issue="${_n%%[!0-9]*}" ;; esac
# The spawn's provenance (issue #574): who is owed the report.
at_origin=$(fleet_pane_fmt '#{@origin}' | tr -cd 'A-Za-z0-9._:-')
at_owid=$(fleet_pane_fmt '#{@origin_wid}' | tr -cd 'A-Za-z0-9._:/-')
at_remote=''
if [ -n "$at_owid" ] && [ -n "$at_origin" ]; then
  fleet_wid_home "$at_owid" >/dev/null 2>&1; [ "$?" = 1 ] && at_remote=1
fi

[ -n "$repo" ] || die 'ABORT: not inside a fleet (no repo) — never guess a repo.' 2
[ -n "$at_task" ] || [ -n "$at_issue" ] \
  || die 'FAIL: nothing bound (no @task, no @issue, not an issue-<N> worktree) — never guess.' 4

printf '===== fleet =====\n'
printf 'session=%s  repo=%s  base=%s\n' "$sess" "$repo" "$base"
printf 'main=%s   (READ-ONLY base checkout — edit only in this worktree)\n' "${main:-?}"
printf 'worktree=%s\n' "$cwd"
if [ "$(fleet_repo_land "$repo" "$sess")" = fleet ]; then
  # A repo the fleet lands itself (issue #3602): no PR, no gh — the land line instead.
  printf 'land: fleet  (no PR: pr_verdict → pr_merge with no pr — bin/fleet-land.sh rebases onto %s, runs the repo check %s, fast-forwards)\n' \
    "$base" "$(c=$(fleet_repo_conf_get "$sess" "$repo" FLEET_CHECK_CMD); [ -n "$c" ] && printf '`%s`' "$c" || printf '(none registered — 没跑检查)')"
else
  _gh_merge='gh pr merge'  # no-gh-ok: the command the brief names
  printf 'merge=%s  (how you land: pr_merge on a READY verdict — %s --%s --delete-branch)\n' \
    "$(fleet_merge_method)" "$_gh_merge" "$(fleet_merge_method)"
fi
if [ -n "$at_task" ]; then
  printf 'task=%s  (the hub task record is the ticket)\n' "$at_task"
else
  printf 'issue=%s  (a GitHub issue, read as words only: the fleet never claims, comments on or closes it — the PR'"'"'s `Closes #%s` does)\n' "$at_issue" "$at_issue"
fi
if [ -n "$at_remote" ]; then
  printf 'origin: %s on another machine (worker_id %s — the report tool carries it through the hub)\n' "$at_origin" "$at_owid"
elif [ -n "$at_origin" ]; then
  printf 'origin: %s (report to it when you ship: the report tool)\n' "$at_origin"
else
  printf 'origin: none (opened by a person — nothing to report back to)\n'
fi

rc=0
if [ -n "$at_task" ]; then
  printf '\n===== task %s · %s =====\n' "$at_task" "$repo"
  # FLEET_TASK_RECORD is the selftest's seam (a stub answering `get`).
  if trec=$(bash "${FLEET_TASK_RECORD:-$BIN/fleet-task-record.sh}" get "$at_task" 2>/dev/null) && [ -n "$trec" ]; then
    printf '%s' "$trec" | python3 -c '
import json, sys
t = (json.load(sys.stdin) or {}).get("task") or {}
try:
    words = (json.loads(t.get("request_payload") or "{}") or {}).get("body") or ""
except ValueError:
    words = ""
print("title: %s" % (t.get("title") or "-"))
print("state: %s   outcome: %s   repo: %s" % (t.get("state") or "-", t.get("outcome") or "open", t.get("repo") or "-"))
if t.get("parent_task") or t.get("parent_session"):
    print("dispatched by: %s%s" % (t.get("parent_task") or "", (" · " + t["parent_session"]) if t.get("parent_session") else ""))
print("")
print("----- the request -----")
print(words.strip() or "(only the title — the first message is the person\x27s words)")
' 2>/dev/null || printf '(the record could not be rendered)\n'
  else
    printf 'the hub did not answer for %s — the record could not be read (the rest is still valid)\n' "$at_task"
    rc=5
  fi
  names="the body names $at_task, no \`Closes #N\`"
  closes="it closes $at_task and tells the dispatcher"
else
  names="the body carries \`Closes #$at_issue\`"
  closes="it tells whoever spawned you"
fi

printf '\n===== flow =====\n'
_gh_create='gh pr create --fill'  # no-gh-ok: the command the flow names
printf '%s\n' \
  "1. Implement in this worktree and verify per the repo's rules (CI is the verdict)." \
  "2. Commit, push this branch, open the PR ($_gh_create); $names." \
  "3. pr_verdict (wait: true while PENDING) → pr_merge on READY. Never merge red." \
  "4. report (state: merged, pr, summary) right after the merge — $closes." \
  "   Blocked: ask, then report (state: blocked). Then stop."

printf '\n===== implementation directive · this fleet (issue #234) =====\n'
printf '%s\n' "$(fleet_worker_prompt_body "${at_task:-$at_issue}" "$repo")"
if [ -n "${FLEET_LANG_RULE_SEED:-}" ]; then
  printf '\n===== language · keep the session in ONE language (issue #620) =====\n'
  printf '%s\n' "$FLEET_LANG_RULE_SEED" \
                 "The fleet's own automation always speaks English (resume nudges, quota" \
                 "warnings, child reports). Those are notices, never a signal to switch language."
fi
exit "$rc"
