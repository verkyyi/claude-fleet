#!/usr/bin/env bash
# fleet-worker-start-hook.sh — the flow of a session whose first turn is the
# person's own words (issue #3331, EPIC #3178 ⑧, D2 = ①).
#
# dash-issue-session.sh seeds a repo session with the person's words (or the
# issue's title when nobody typed any) and stamps the window `@seed_words` (any
# non-empty value — an older spawn wrote its claim command) before its agent starts. This SessionStart
# hook (the ONE hook table, hooks/settings-hooks.json) reads that stamp and prints
# SessionStart JSON:
#
#   systemMessage      one grey line for the person —
#                      「fleet-worker · tokenledger · 单 #3312 · 做完开 PR，门绿了自己合」
#   additionalContext  the agent's instruction: read the `brief`, then the flow —
#                      implement, PR, pr_verdict / pr_merge, report (issue #4898:
#                      no claim skill, nothing written to the issue).
#
# fleet-worker's body is empty on purpose (a body replaces Claude Code's own
# system prompt), so this is the only road the flow has in; the words and the
# stamp go together (the spawn writes both or neither), which is what
# seed-words-selftest.sh pins: words first ⇒ the brief is the next step.
#
# A development task with no issue (issue #4897) is stamped `@task T<n>` +
# `@task_flow 1` instead: its context is the task flow — read the record with the
# `brief` tool, implement, PR, merge on green, `report merged` (closes the record)
# — and it never names a GitHub issue.
#
# Only on `startup`: a resume / compact already has the conversation. A window
# with no @seed_words (and no @task_flow) — a scratch, a no-repo session, a desk ticket, a Codex
# session, an old window — prints nothing: no flow is put on it. Anything missing
# → nothing, exit 0: a SessionStart hook never blocks a session.
#
#   fleet-worker-start-hook.sh     (stdin: the hook's JSON)
set -uo pipefail
case "$0" in */*) BIN="${0%/*}" ;; *) BIN=. ;; esac
BIN="$(cd "${BIN:-/}" && pwd)"

ev=$(cat 2>/dev/null)
src=$(printf '%s' "$ev" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("source") or "")
except Exception: print("")' 2>/dev/null)
[ "$src" = startup ] || exit 0
# The pane's OWN window — never an empty target, which is "the pane the
# operator is looking at".
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || exit 0
row=$(tmux display-message -p -t "$TMUX_PANE" \
  '#{@seed_words}|#{@issue}|#{@repo}|#{@desk}|#{@agent_def}|#{@task}|#{@task_flow}' 2>/dev/null) || exit 0
# `|`, not a tab: a tab is IFS whitespace, so an empty field would shift the rest.
IFS='|' read -r cmd num repo desk adef task tflow <<EOF
$row
EOF
# A development task with no issue (issue #4897, EPIC #4895 批 0): the window
# carries the hub's record (@task T<n>) and @task_flow 1 (dash-raw-session.sh
# --repo --task, stamped before its agent starts). Its flow reads the RECORD —
# never a GitHub issue.
case "$task" in T[1-9]*) case "${task#T}" in *[!0-9]*) task='' ;; esac ;; *) task='' ;; esac
mode=issue
if [ -z "$num" ] && [ -n "$task" ] && [ "${tflow:-}" = 1 ] && [ -n "$repo" ]; then
  mode=task
else
  [ -n "$cmd" ] || exit 0
  case "$num" in ''|*[!0-9]*) exit 0 ;; esac
  [ "${desk:-}" = 1 ] && exit 0
fi
# The person's language: said outright, else their own choice on the hub, else
# 中文 — never this login's locale, which says nothing about who typed the words.
lang=zh
case "${FLEET_UI_LANG:-}" in
  en|en_*|en-*|EN*|english|English) lang=en ;;
  '') [ -f "$BIN/fleet-ui-lang.sh" ] && lang=$( . "$BIN/fleet-ui-lang.sh" >/dev/null 2>&1; fleet_ui_person_lang 2>/dev/null ) ;;
esac
[ "$lang" = en ] || lang=zh

SW_MODE="$mode" SW_TASK="$task" SW_NUM="$num" SW_REPO="$repo" SW_AGENT="${adef:-fleet-worker}" SW_LANG="${lang:-zh}" python3 -c '
import json, os
num, repo = os.environ["SW_NUM"], os.environ["SW_REPO"]
name = repo.rsplit("/", 1)[-1] or repo
agent = os.environ["SW_AGENT"]
en = os.environ["SW_LANG"] == "en"
if os.environ["SW_MODE"] == "task":
    task = os.environ["SW_TASK"]
    line = ("%s · %s · task %s · opens a PR when done, merges itself once the gate is green" if en
            else "%s · %s · 任务 %s · 做完开 PR，门绿了自己合") % (agent, name, task)
    head = ("# This session is a fleet worker on a hub task\n"
            "It is bound to the hub task record %s (repo %s) — NOT to a GitHub issue. The first user "
            "message is the person\x27s own words: the request that record holds.\n") % (task, repo)
    names = "its body names %s and carries no `Closes #N`" % task
    closes = "that closes %s and tells whoever dispatched it" % task
else:
    line = ("%s · %s · #%s · opens a PR when done, merges itself once the gate is green" if en
            else "%s · %s · 单 #%s · 做完开 PR，门绿了自己合") % (agent, name, num)
    head = ("# This session is a fleet worker\n"
            "It was opened on issue #%s of %s. The first user message is the person\x27s own words "
            "(or the issue\x27s title) — the request that issue records.\n") % (num, repo or "this repo")
    names = "its body carries `Closes #%s`" % num
    closes = "that tells whoever spawned you"
ctx = head + (
    "Before anything else, call the fleet tool `brief` with no arguments (it prints the fleet, repo, "
    "base, merge method, origin and the request). Then:\n"
    "1. Implement in this worktree (never the base checkout), and verify per the repo\x27s rules.\n"
    "2. Commit, push this branch, open the PR (`gh pr create --fill`); %s.\n"  # no-gh-ok: a message
    "3. Land it: the fleet tool `pr_verdict` (`wait: true` while PENDING), then `pr_merge` on "
    "READY; never merge red.\n"
    "4. Report: the fleet tool `report` (`state: merged`, `pr`, `summary`) right after the merge — "
    "%s. Blocked: `ask`, then `report` (`state: blocked`). Then stop.\n"
    "Never claim, comment on or close a GitHub issue yourself, and never file one: the fleet keeps "
    "no issue state (issue #4898). Do it yourself; never ask the person to run anything."
) % (names, closes)
print(json.dumps({"systemMessage": line,
                  "hookSpecificOutput": {"hookEventName": "SessionStart",
                                         "additionalContext": ctx}}, ensure_ascii=False))
' 2>/dev/null || :
exit 0
