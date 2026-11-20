#!/usr/bin/env bash
# fleet-worker-start-hook.sh — the grey line a worker session opens with (issue
# #3331, EPIC #3178 ⑧; T1470: no injected flow).
#
# dash-issue-session.sh seeds a repo session with the person's words (or the
# issue's title when nobody typed any) and stamps the window `@seed_words`; a
# development task (issue #4897) is stamped `@task T<n>` + `@task_flow 1`. This
# SessionStart hook (the ONE hook table, hooks/settings-hooks.json) reads those
# stamps and prints ONE thing — a `systemMessage` for the person:
#
#      「fleet-worker · tokenledger · 单 #3312」 / 「fleet-worker · tokenledger · 任务 T42」
#
# It gives the agent NO `additionalContext` (T1470): the first turn is the
# person's own words and Claude Code's default behaviour, with the repo's own
# CLAUDE.md, is the whole guidance. What the fleet must hold is held by a rail,
# not a prompt: the base checkout by hooks/base-readonly-guard.py, the issue
# ban by hooks/bash-guard.py (BREAK-IT `worker-issue-write`). How a repo lands its
# work (PR, merge on green) belongs in that repo's CLAUDE.md or the person's words.
#
# Only on `startup`: a resume / compact already has the conversation. A window
# with no @seed_words (and no @task_flow) — a scratch, a no-repo session, a desk
# ticket, a Codex session, an old window — prints nothing. Anything missing →
# nothing, exit 0: a SessionStart hook never blocks a session.
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
    line = ("%s · %s · task %s" if en else "%s · %s · 任务 %s") % (agent, name, os.environ["SW_TASK"])
else:
    line = ("%s · %s · #%s" if en else "%s · %s · 单 #%s") % (agent, name, num)
print(json.dumps({"systemMessage": line}, ensure_ascii=False))
' 2>/dev/null || :
exit 0
