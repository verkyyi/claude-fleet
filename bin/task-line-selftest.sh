#!/bin/bash
# task-line-selftest.sh — a session's first sentence becomes its @task_line (#2359).
# Real tmux on an isolated socket, bin/set-claude-state.sh driven with the same
# argument hooks/settings-hooks.json gives UserPromptSubmit and PostToolUse:
#   A. the first prompt stamps @task_line — control characters → one space,
#      runs of white space folded, at most 40 characters (39 + …)
#   B. a later prompt never replaces it; a PostToolUse never writes it
#   C. a blocked window still clears on that same first prompt (the payload is
#      read once, parsed by both)
#   E. a message from another session (T493): 「来自 X：its words」, never the
#      <cross-session-message …> envelope; an envelope with no words writes nothing
#   D. @agent_cwd (issue #3183): a Bash call's PostToolUse stamps the payload's
#      top-level cwd (never one inside tool_input); another tool's leaves it; a
#      relative or escaped one is not written
#   F. a blank new session (T652, EPIC T651 C1): a window opened on a placeholder
#      name (@title_pending) is renamed by its first prompt's first line (≤30) —
#      window name, @task_line, and `fleet-task-record.sh retitle T<n> --from
#      <placeholder>` — once; a cross-session message renames nothing
# No live Claude, no network. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
# the real tmux — never the fleet's tmux-shim (a session's PATH starts with it,
# and it would find the wrapper below on PATH and loop)
REAL_TMUX=''
for t in $(type -ap tmux); do case "$t" in */tmux-shim/*) continue ;; esac; REAL_TMUX=$t; break; done
[ -n "$REAL_TMUX" ] || { printf 'task-line: tmux absent — SKIP\n'; exit 0; }
st_need python3
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tline.XXXXXX")" || exit 2
SOCK="$WORK/s"
tf() { "$REAL_TMUX" -S "$SOCK" "$@"; }
cleanup() { tf kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
st_tally count

mkdir -p "$WORK/path" "$WORK/inst/bin" "$WORK/inst/logs"
cp "$BIN/set-claude-state.sh" "$BIN/fleet-ui-lang.sh" "$WORK/inst/bin/"
HOOK="$WORK/inst/bin/set-claude-state.sh"
st_tmux_socket "$WORK/path" "$SOCK" strip
PATH="$WORK/path:$PATH"; export PATH
unset CCQUOTA_FLEET FLEET_WT_PENDING
tf -f /dev/null new-session -d -s tl -n a 'exec sleep 300' || st_fail "could not start the isolated server"
tf new-window -d -t tl: -n b 'exec sleep 300'
PA=$(tf display-message -p -t tl:a '#{pane_id}')
PB=$(tf display-message -p -t tl:b '#{pane_id}')
TM="$SOCK,1,0"
# the verb settings-hooks.json binds to an event (one source, never assumed)
verb() {
  python3 - "$BIN/../hooks/settings-hooks.json" "$1" <<'PY'
import json, shlex, sys
for group in json.load(open(sys.argv[1]))["hooks"][sys.argv[2]]:
    for hook in group.get("hooks", []):
        parts = shlex.split(hook.get("command", ""))
        if any(p.endswith("set-claude-state.sh") for p in parts):
            print(parts[-1]); sys.exit(0)
PY
}
UPS=$(verb UserPromptSubmit); POST=$(verb PostToolUse)
[ -n "$UPS" ] && [ -n "$POST" ] || st_fail "settings-hooks.json binds no set-claude-state.sh verb"
hook() {   # <pane> <verb> <json>
  printf '%s' "$3" | env TMUX="$TM" TMUX_PANE="$1" CLAUDE_CODE_ENTRYPOINT=cli sh "$HOOK" "$2" >/dev/null 2>&1
}
ups() { python3 -c 'import json,sys; print(json.dumps({"hook_event_name": "UserPromptSubmit", "prompt": sys.argv[1]}))' "$1"; }
tl() { tf display-message -p -t "$1" '#{@task_line}'; }

# --- A ------------------------------------------------------------------------
hook "$PA" "$POST" '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":"UserPromptSubmit"}'
st_eq "A: a PostToolUse writes nothing" "" "$(tl "$PA")"
hook "$PA" "$UPS" "$(ups $'  帮我看下\tmac-d 的日志\n\n然后告诉我  ')"
st_eq "A: the first prompt — tab / newlines folded, trimmed" "帮我看下 mac-d 的日志 然后告诉我" "$(tl "$PA")"
long=$(python3 -c 'print("一二三四五六七八九十" * 5)')
hook "$PB" "$UPS" "$(ups "$long")"
got=$(tl "$PB")
st_eq "A: a long first prompt — 40 characters, the last an ellipsis" "40 …" \
   "$(python3 -c 'import sys; s = sys.argv[1]; print(len(s), s[-1])' "$got")"

# --- B ------------------------------------------------------------------------
hook "$PA" "$UPS" "$(ups '第二句话')"
st_eq "B: a later prompt never replaces it" "帮我看下 mac-d 的日志 然后告诉我" "$(tl "$PA")"

# --- C ------------------------------------------------------------------------
tf set-window-option -u -t "$PA" @task_line
tf set-window-option -t "$PA" @claude_state needs
tf set-window-option -t "$PA" @claude_needs blocked
hook "$PA" "$POST" '{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
st_eq "C: a blocked window stays blocked across a tool call" "needs/blocked" \
   "$(tf display-message -p -t "$PA" '#{@claude_state}/#{@claude_needs}')"
hook "$PA" "$UPS" "$(ups '答复：用 mac-a')"
st_eq "C: the first prompt both clears blocked…" "working" "$(tf display-message -p -t "$PA" '#{@claude_state}')"
st_eq "C: …and stamps the line" "答复：用 mac-a" "$(tl "$PA")"

# --- D ------------------------------------------------------------------------
ac() { tf display-message -p -t "$1" '#{@agent_cwd}'; }
hook "$PB" "$POST" '{"session_id":"s","cwd":"/w/wt-x/bin","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo \"cwd\": \"/nope\""}}'
st_eq "D: a Bash call stamps the payload's cwd" "/w/wt-x/bin" "$(ac "$PB")"
hook "$PB" "$POST" '{"session_id":"s", "cwd": "/w/wt-x/sub dir", "hook_event_name": "PostToolUse", "tool_name": "Bash"}'
st_eq "D: …spaced JSON, a path with a space" "/w/wt-x/sub dir" "$(ac "$PB")"
hook "$PB" "$POST" '{"session_id":"s","cwd":"/elsewhere","hook_event_name":"PostToolUse","tool_name":"Read"}'
st_eq "D: another tool's call leaves it" "/w/wt-x/sub dir" "$(ac "$PB")"
hook "$PB" "$POST" '{"session_id":"s","cwd":"rel/dir","hook_event_name":"PostToolUse","tool_name":"Bash"}'
hook "$PB" "$POST" '{"session_id":"s","cwd":"/a\\\"b","hook_event_name":"PostToolUse","tool_name":"Bash"}'
st_eq "D: a relative or escaped cwd is not written" "/w/wt-x/sub dir" "$(ac "$PB")"

# --- E ------------------------------------------------------------------------
tf set-window-option -u -t "$PB" @task_line
FLEET_UI_LANG=zh hook "$PB" "$UPS" "$(ups $'<cross-session-message from-name="fleet" from-mode="bypass">\n实施 ⌘P 面板方案 B\n</cross-session-message>')"
st_eq "E: a cross-session message — its sender and words" "来自 fleet：实施 ⌘P 面板方案 B" \
   "$(tl "$PB")"
tf set-window-option -u -t "$PB" @task_line
hook "$PB" "$UPS" "$(ups '<cross-session-message from-name="fleet"></cross-session-message>')"
st_eq "E: an envelope with no words writes nothing" "" "$(tl "$PB")"

# --- F ------------------------------------------------------------------------
cat > "$WORK/inst/bin/fleet-task-record.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$WORK/retitle.log'
EOF
PC=$(tf new-window -d -P -F '#{pane_id}' -t tl: -n 新会话 'exec sleep 300')
tf set-window-option -t "$PC" @title_pending 新会话
tf set-window-option -t "$PC" @task T7
FLEET_UI_LANG=zh hook "$PC" "$UPS" "$(ups '<cross-session-message from-name="fleet">看看</cross-session-message>')"
st_eq "F: a cross-session message renames nothing" "新会话|新会话" \
   "$(tf display-message -p -t "$PC" '#{window_name}|#{@title_pending}')"
tf set-window-option -u -t "$PC" @task_line
hook "$PC" "$UPS" "$(ups $'\n  修一下面板读取变慢，顺便看看为什么首帧要等 hub 才画出来呢\n第二行')"
st_eq "F: the first prompt's first line, 30 characters — the window's name" "修一下面板读取变慢，顺便看看为什么首帧要等 hub 才画出…" \
   "$(tf display-message -p -t "$PC" '#{window_name}')"
st_eq "F: …its @task_line, the stamp gone" "修一下面板读取变慢，顺便看看为什么首帧要等 hub 才画出…|" \
   "$(tf display-message -p -t "$PC" '#{@task_line}|#{@title_pending}')"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WORK/retitle.log" ] && break; sleep 0.2; done
st_eq "F: …and the record, once, from the placeholder" "retitle T7 --from 新会话 --title 修一下面板读取变慢，顺便看看为什么首帧要等 hub 才画出…" \
   "$(cat "$WORK/retitle.log" 2>/dev/null)"
tf set-window-option -u -t "$PC" @task_line
hook "$PC" "$UPS" "$(ups '再改一次')"
sleep 0.3
st_eq "F: a later first prompt (no stamp) renames nothing" "修一下面板读取变慢，顺便看看为什么首帧要等 hub 才画出…|1" \
   "$(tf display-message -p -t "$PC" '#{window_name}')|$(grep -c . "$WORK/retitle.log")"

printf 'task-line selftest: PASS (%s checks)\n' "$CHECKS"
