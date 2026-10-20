#!/bin/bash
# needs-notify-selftest.sh — someone asks you, and you hear it without looking at
# the list (issue #1951, EPIC #1949 C2).
#
#   A. detail   — bin/fleet_needs_detail.py, the ONE rule for the question's own
#                 words: an AskUserQuestion's first question (Claude's payload and
#                 transcript, Codex's request_user_input params alike), a
#                 permission's `Bash: git push`, one line, ≤ 120 characters, never
#                 a failure
#   B. stamp    — bin/set-claude-state.sh (an isolated tmux socket): the PreToolUse
#                 AskUserQuestion payload → @claude_needs_detail beside
#                 needs/ask; the mod's `ask` with the payload on stdin → the same;
#                 the next `working` clears it with the subtype
#   C. notify   — moved to bin/notify-selftest.sh (issue #2759: fleet_notify.py
#                 decides it); here: the bar's old road is a no-op. The thin
#                 client's focus jump is fleet-thin-notify-selftest.sh D (the old
#                 client's D/E — its click, its bar's keys — went with it, #3008)
# No network, no live fleet. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
REAL_TMUX=$(command -v tmux || true)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/needs-notify-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
L="nnotify$$"
cleanup() { [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
unset TMUX TMUX_PANE FLEET_NOTIFY FLEET_NOTIFY_JUMP_SECS FLEET_CLIENT_NOTIFY_CMD FLEET_CLIENT_ESCAPE_CMD CCQUOTA_FLEET
export TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/conf" FLEET_ALLOW_SENDKEYS=1
G="$WORK/.claude-dash/global"; mkdir -p "$G" "$WORK/conf/global"

st_tally count

ND="$BIN/fleet_needs_detail.py"
# ============================================================================
# A. detail — the one rule
# ============================================================================
st_eq "A: AskUserQuestion's first question" "演练放在 mac-b 还是只在 mac-a？" \
   "$(printf '%s' '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"演练放在 mac-b 还是只在 mac-a？","options":[]},{"question":"second"}]}}' | python3 "$ND" payload)"
st_eq "A: a permission's tool and command" "Bash: git push origin x" \
   "$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git push\n  origin x"}}' | python3 "$ND" payload)"
st_eq "A: an edit names its file" "Edit: /a/b.py" "$(printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"/a/b.py"}}' | python3 "$ND" payload)"
long=$(python3 -c 'print("长" * 300)')
got=$(printf '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"%s"}]}}' "$long" | python3 "$ND" payload)
st_eq "A: at most 120 characters, … when cut" "120 …" "$(python3 -c 'import sys; t=sys.argv[1]; print(len(t), t[-1])' "$got")"
st_eq "A: not JSON → nothing, exit 0" "|0" "$(printf 'garbage' | python3 "$ND" payload; printf '|%s' $?)"
cat > "$WORK/t.jsonl" <<'J'
{"message":{"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"ls"}}]}}
{"message":{"content":[{"type":"tool_result","tool_use_id":"a"}]}}
{"message":{"content":[{"type":"tool_use","id":"b","name":"AskUserQuestion","input":{"questions":[{"question":"继续？"}]}}]}}
J
st_eq "A: the transcript's open tool_use" "继续？" "$(python3 "$ND" transcript "$WORK/t.jsonl")"
st_eq "A: no transcript → nothing" "" "$(python3 "$ND" transcript "$WORK/none.jsonl")"
st_eq "A: Codex's request params share the rule" "Path?" \
   "$(python3 -c 'import runpy,sys; print(runpy.run_path(sys.argv[1])["detail"]("", {"questions":[{"id":"q","question":"Path?"}]}))' "$ND")"

[ -n "$REAL_TMUX" ] || { printf 'needs-notify selftest: PASS (%s checks; tmux absent — B–D skipped)\n' "$CHECKS"; exit 0; }
T() { "$REAL_TMUX" -L "$L" "$@"; }
T -f /dev/null new-session -d -s "$L" -n home 'sleep 600' || st_fail "could not start the isolated server"
SOCK=$(T display-message -p '#{socket_path}')
PANE=$(T display-message -p -t "=$L:" '#{pane_id}')

# ============================================================================
# B. stamp — set-claude-state.sh writes the question beside needs/ask
# ============================================================================
st() { TMUX="$SOCK,0,0" TMUX_PANE="$PANE" sh "$BIN/set-claude-state.sh" "$@"; }
opt() { T display-message -p -t "$PANE" "$1"; }
printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"演练放在 mac-b 还是只在 mac-a？"}]}}' | st busy
st_eq "B: PreToolUse AskUserQuestion → needs/ask + its question" "needs/ask|演练放在 mac-b 还是只在 mac-a？" "$(opt '#{@claude_state}/#{@claude_needs}|#{@claude_needs_detail}')"
printf '%s' '{"hook_event_name":"PostToolUse"}' | st working
st_eq "B: answered → working, the question gone with the subtype" "working/|" "$(opt '#{@claude_state}/#{@claude_needs}|#{@claude_needs_detail}')"
printf '%s' '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"mod 的问题"}]}}' | st --via mod ask
st_eq "B: the mod's ask with the payload on stdin → the same" "needs/ask|mod 的问题" "$(opt '#{@claude_state}/#{@claude_needs}|#{@claude_needs_detail}')"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | st busy
st_eq "B: an ordinary tool → working, no question" "working|" "$(opt '#{@claude_state}|#{@claude_needs_detail}')"

# (C. the bar's old road, fleet_alerts_notify, is gone — #4790: conf/gone.list)

printf 'needs-notify selftest: PASS (%s checks)\n' "$CHECKS"
