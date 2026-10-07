#!/usr/bin/env bash
# fleet-where-hook.sh — a Codex session knows where the person is from its first
# turn, the same as a Claude Code session (issue #1954, EPIC #1949 C5).
#
# A Claude Code session gets the line 「操作者此刻在：…」 from the fleet mod
# (mod/fleet/hooks/where.ts adds it to every request). Codex has no mod, so it
# used to know nothing until it ran `where` itself. This SessionStart hook (in the
# ONE hook table, hooks/settings-hooks.json — Codex gets it through
# hooks/codex-map.json) prints the same section as SessionStart
# `hookSpecificOutput.additionalContext`:
#
#   # 操作者此刻在哪
#   操作者此刻在：<the line bin/fleet-client-where.sh prints>
#   （fleet 客户端租约；…）
#
# The text is where.ts's whereSection, byte for byte; bin/fleet-client-where.sh
# stays the one reader (exit 0 names a client, 3 says nobody is connected —
# both carry a line; anything else is no answer).
#
# Only a Codex pane (FLEET_CODEX_LAUNCHER_PID, set by bin/fleet-codex.sh): a Claude
# Code session already has the line from the mod, and printing it twice would be
# the second place that says it. Anything missing → prints nothing, exits 0: a
# SessionStart hook never blocks a session.
#
#   fleet-where-hook.sh            (stdin: the hook's JSON, unread)
set -uo pipefail
case "$0" in */*) BIN="${0%/*}" ;; *) BIN=. ;; esac
BIN="$(cd "${BIN:-/}" && pwd)"

[ -n "${FLEET_CODEX_LAUNCHER_PID:-}" ] || exit 0
[ -f "$BIN/fleet-client-where.sh" ] || exit 0

out=$(bash "$BIN/fleet-client-where.sh" 2>/dev/null </dev/null); rc=$?
case "$rc" in 0|3) ;; *) exit 0 ;; esac
line=${out%%$'\n'*}
line=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
[ -n "$line" ] || exit 0

WHERE_LINE="$line" python3 -c '
import json, os
text = ("# 操作者此刻在哪\n操作者此刻在：" + os.environ["WHERE_LINE"] + "\n"
        "（fleet 客户端租约；换设备接管后这一行会跟着变。要最新的或要字段，运行 "
        "`~/.claude/fleet/bin/fleet-client-where.sh [--json]`；给操作者看网页/文件前按这里的「能：」选送达方式，不要自己猜终端或设备。）")
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                         "additionalContext": text}}, ensure_ascii=False))
' 2>/dev/null || :
exit 0
