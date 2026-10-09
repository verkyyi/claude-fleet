#!/bin/bash
# task-line-selftest.sh — a session's first sentence becomes its @task_line (#2359).
# Real tmux on an isolated socket, bin/set-claude-state.sh driven with the same
# argument hooks/settings-hooks.json gives UserPromptSubmit and PostToolUse:
#   A. the first prompt stamps @task_line — control characters → one space,
#      runs of white space folded, at most 40 characters (39 + …)
#   B. a later prompt never replaces it; a PostToolUse never writes it
#   C. a blocked window still clears on that same first prompt (the payload is
#      read once, parsed by both)
# No live Claude, no network. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# the real tmux — never the fleet's tmux-shim (a session's PATH starts with it,
# and it would find the wrapper below on PATH and loop)
REAL_TMUX=''
for t in $(type -ap tmux); do case "$t" in */tmux-shim/*) continue ;; esac; REAL_TMUX=$t; break; done
[ -n "$REAL_TMUX" ] || { printf 'task-line: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'task-line: python3 absent — SKIP\n'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tline.XXXXXX")" || exit 2
SOCK="$WORK/s"
tf() { "$REAL_TMUX" -S "$SOCK" "$@"; }
cleanup() { tf kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
CHECKS=0
fail() { printf 'task-line selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')"; }

mkdir -p "$WORK/path" "$WORK/inst/bin" "$WORK/inst/logs"
cp "$BIN/set-claude-state.sh" "$WORK/inst/bin/"
HOOK="$WORK/inst/bin/set-claude-state.sh"
cat > "$WORK/path/tmux" <<SH
#!/bin/sh
case "\${1:-}" in -L|-S) shift 2 ;; esac
exec "$REAL_TMUX" -S "$SOCK" "\$@"
SH
chmod +x "$WORK/path/tmux"
PATH="$WORK/path:$PATH"; export PATH
unset CCQUOTA_FLEET FLEET_WT_PENDING
tf -f /dev/null new-session -d -s tl -n a 'exec sleep 300' || fail "could not start the isolated server"
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
[ -n "$UPS" ] && [ -n "$POST" ] || fail "settings-hooks.json binds no set-claude-state.sh verb"
hook() {   # <pane> <verb> <json>
  printf '%s' "$3" | env TMUX="$TM" TMUX_PANE="$1" CLAUDE_CODE_ENTRYPOINT=cli sh "$HOOK" "$2" >/dev/null 2>&1
}
ups() { python3 -c 'import json,sys; print(json.dumps({"hook_event_name": "UserPromptSubmit", "prompt": sys.argv[1]}))' "$1"; }
tl() { tf display-message -p -t "$1" '#{@task_line}'; }

# --- A ------------------------------------------------------------------------
hook "$PA" "$POST" '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":"UserPromptSubmit"}'
eq "A: a PostToolUse writes nothing" "" "$(tl "$PA")"
hook "$PA" "$UPS" "$(ups $'  帮我看下\tmini2 的日志\n\n然后告诉我  ')"
eq "A: the first prompt — tab / newlines folded, trimmed" "帮我看下 mini2 的日志 然后告诉我" "$(tl "$PA")"
long=$(python3 -c 'print("一二三四五六七八九十" * 5)')
hook "$PB" "$UPS" "$(ups "$long")"
got=$(tl "$PB")
eq "A: a long first prompt — 40 characters, the last an ellipsis" "40 …" \
   "$(python3 -c 'import sys; s = sys.argv[1]; print(len(s), s[-1])' "$got")"

# --- B ------------------------------------------------------------------------
hook "$PA" "$UPS" "$(ups '第二句话')"
eq "B: a later prompt never replaces it" "帮我看下 mini2 的日志 然后告诉我" "$(tl "$PA")"

# --- C ------------------------------------------------------------------------
tf set-window-option -u -t "$PA" @task_line
tf set-window-option -t "$PA" @claude_state needs
tf set-window-option -t "$PA" @claude_needs blocked
hook "$PA" "$POST" '{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
eq "C: a blocked window stays blocked across a tool call" "needs/blocked" \
   "$(tf display-message -p -t "$PA" '#{@claude_state}/#{@claude_needs}')"
hook "$PA" "$UPS" "$(ups '答复：用 m4')"
eq "C: the first prompt both clears blocked…" "working" "$(tf display-message -p -t "$PA" '#{@claude_state}')"
eq "C: …and stamps the line" "答复：用 m4" "$(tl "$PA")"

printf 'task-line selftest: PASS (%s checks)\n' "$CHECKS"
