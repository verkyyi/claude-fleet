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
#   C. notify   — bin/fleet-alerts.sh fleet_alerts_notify on the CLIENT
#                 (FLEET_SHELL=1) through bin/fleet-client-actions.py notify, a
#                 fake notifier (FLEET_CLIENT_NOTIFY_CMD) and an isolated tmux
#                 server holding a list pane: the first look seeds silently; a new
#                 needs row is ONE notification — who, what they ask — and its
#                 click lands `jump=wid:<worker>` on the list (the ⌘P road); the
#                 same row again is none; answered and asked again is a new one;
#                 FLEET_NOTIFY=0 is nothing; a node (no FLEET_SHELL) never notifies
#   D. focus    — a notifier with no click of its own (iTerm2's OSC 9): the jump
#                 waits in @notify_jump and `jump-pending` (the client's focus-in)
#                 takes it once; past FLEET_NOTIFY_JUMP_SECS it is dropped
#   E. keys     — the bar's middle (conf/tmux-shell.conf @fleet_hint) for a real
#                 client attached to an isolated server: the session's keys by
#                 default (⌘N ⌘P ⌘↑↓ ⌘J ⌘/, each a `key-<key>` range); the prefix
#                 keys while prefix is pressed; ⌘P's while its popup is open; ↵ /
#                 esc in a question's pane; what a tap does on the list, with the
#                 highlighted row's detail (fleet-sidebar.py bar_hint, #2305 — #948's
#                 `? 快捷键` row is gone, the bar says it); the writing area's; a
#                 tap on a range is that key (MouseDown1Status → send-keys -K) and
#                 「! n 等你」 is ⌘J; narrower than 100 columns the line goes
# No network, no live fleet. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'needs-notify selftest: python3 absent — SKIP'; exit 0; }
REAL_TMUX=$(command -v tmux || true)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/needs-notify-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
L="nnotify$$"
cleanup() { [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
unset TMUX TMUX_PANE FLEET_NOTIFY FLEET_NOTIFY_JUMP_SECS FLEET_CLIENT_NOTIFY_CMD FLEET_CLIENT_ESCAPE_CMD CCQUOTA_FLEET
export TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/conf" FLEET_ALLOW_SENDKEYS=1
G="$WORK/.claude-dash/global"; mkdir -p "$G" "$WORK/conf/global"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }

ND="$BIN/fleet_needs_detail.py"
# ============================================================================
# A. detail — the one rule
# ============================================================================
eq "A: AskUserQuestion's first question" "演练放在 m5 还是只在 m4？" \
   "$(printf '%s' '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"演练放在 m5 还是只在 m4？","options":[]},{"question":"second"}]}}' | python3 "$ND" payload)"
eq "A: a permission's tool and command" "Bash: git push origin x" \
   "$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git push\n  origin x"}}' | python3 "$ND" payload)"
eq "A: an edit names its file" "Edit: /a/b.py" "$(printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"/a/b.py"}}' | python3 "$ND" payload)"
long=$(python3 -c 'print("长" * 300)')
got=$(printf '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"%s"}]}}' "$long" | python3 "$ND" payload)
eq "A: at most 120 characters, … when cut" "120 …" "$(python3 -c 'import sys; t=sys.argv[1]; print(len(t), t[-1])' "$got")"
eq "A: not JSON → nothing, exit 0" "|0" "$(printf 'garbage' | python3 "$ND" payload; printf '|%s' $?)"
cat > "$WORK/t.jsonl" <<'J'
{"message":{"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"ls"}}]}}
{"message":{"content":[{"type":"tool_result","tool_use_id":"a"}]}}
{"message":{"content":[{"type":"tool_use","id":"b","name":"AskUserQuestion","input":{"questions":[{"question":"继续？"}]}}]}}
J
eq "A: the transcript's open tool_use" "继续？" "$(python3 "$ND" transcript "$WORK/t.jsonl")"
eq "A: no transcript → nothing" "" "$(python3 "$ND" transcript "$WORK/none.jsonl")"
eq "A: Codex's request params share the rule" "Path?" \
   "$(python3 -c 'import runpy,sys; print(runpy.run_path(sys.argv[1])["detail"]("", {"questions":[{"id":"q","question":"Path?"}]}))' "$ND")"

[ -n "$REAL_TMUX" ] || { printf 'needs-notify selftest: PASS (%s checks; tmux absent — B–D skipped)\n' "$CHECKS"; exit 0; }
T() { "$REAL_TMUX" -L "$L" "$@"; }
T -f /dev/null new-session -d -s "$L" -n home 'sleep 600' || fail "could not start the isolated server"
SOCK=$(T display-message -p '#{socket_path}')
PANE=$(T display-message -p -t "=$L:" '#{pane_id}')

# ============================================================================
# B. stamp — set-claude-state.sh writes the question beside needs/ask
# ============================================================================
st() { TMUX="$SOCK,0,0" TMUX_PANE="$PANE" sh "$BIN/set-claude-state.sh" "$@"; }
opt() { T display-message -p -t "$PANE" "$1"; }
printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"演练放在 m5 还是只在 m4？"}]}}' | st busy
eq "B: PreToolUse AskUserQuestion → needs/ask + its question" "needs/ask|演练放在 m5 还是只在 m4？" "$(opt '#{@claude_state}/#{@claude_needs}|#{@claude_needs_detail}')"
printf '%s' '{"hook_event_name":"PostToolUse"}' | st working
eq "B: answered → working, the question gone with the subtype" "working/|" "$(opt '#{@claude_state}/#{@claude_needs}|#{@claude_needs_detail}')"
printf '%s' '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"mod 的问题"}]}}' | st --via mod ask
eq "B: the mod's ask with the payload on stdin → the same" "needs/ask|mod 的问题" "$(opt '#{@claude_state}/#{@claude_needs}|#{@claude_needs_detail}')"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | st busy
eq "B: an ordinary tool → working, no question" "working|" "$(opt '#{@claude_state}|#{@claude_needs_detail}')"

# ============================================================================
# C. notify — once, with who and what, and a click that jumps
# ============================================================================
T split-window -d -t "$PANE" 'sleep 600'
LIST=$(T list-panes -t "=$L:" -F '#{pane_id}' | tail -1)
T set-option -p -t "$LIST" @sidebar 1
printf '{"caps":["notify"]}\n' > "$WORK/client.where.json"
cat > "$WORK/notifier" <<'SH'
#!/bin/sh
# a fake notifier: one line per notification, then the person clicks it
printf '%s|%s\n' "$1" "$2" >> "$NOTIFY_LOG"
[ -n "${FLEET_NOTIFY_CLICK:-}" ] && eval "$FLEET_NOTIFY_CLICK"
exit 0
SH
chmod +x "$WORK/notifier"
export NOTIFY_LOG="$WORK/notify.log" FLEET_CLIENT_NOTIFY_CMD="$WORK/notifier" FLEET_SHELL_SESSION="$L"
AF="$G/alerts.ndjson"
row() { printf '{"id":"needs-wid-%s","severity":"needs","subject":"%s","condition":"%s","value":"%s","since":1,"action":"jump","healed_at":0,"target":"wid:%s","detail":"%s"}\n' "${1//\//}" "$2" "$3" "$4" "$1" "$5"; }
notify() { TMUX="$SOCK,0,0" FLEET_SHELL="${SHELLV-1}" bash -c '. "$1/usage-lib.sh"; . "$1/fleet-alerts.sh"; fleet_alerts_notify' _ "$BIN"; }
# the notification is a background child: wait for its line (or 5s)
settle() { local i=0; while [ "$i" -lt 50 ]; do [ "$(wc -l < "$NOTIFY_LOG" 2>/dev/null | tr -d ' ')" = "$1" ] && break; sleep 0.1; i=$((i+1)); done; sleep 0.3; }
lines() { wc -l < "$NOTIFY_LOG" 2>/dev/null | tr -d ' '; }
: > "$NOTIFY_LOG"
row F/issue-7 '#7' question m4 '早就在问的' > "$AF"
notify; sleep 0.5
eq "C: the first look seeds silently" "0" "$(lines)"
eq "C: …and remembers the id" "needs-wid-Fissue-7" "$(cat "$AF.notified")"
{ row F/issue-7 '#7' question m4 '早就在问的'; row F/issue-1909 '#1909' question m5 '演练放在 m5 还是只在 m4？'; } > "$AF"
notify; settle 1
eq "C: a new wait → one notification: who, what, where" "#1909 在问你|演练放在 m5 还是只在 m4？ · m5" "$(cat "$NOTIFY_LOG")"
eq "C: its click lands on the list as jump=wid:<worker>" "jump=wid:F/issue-1909" "$(T show-options -pqv -t "$LIST" @sidebar_do | tr -d ' ')"
T set-option -up -t "$LIST" @sidebar_do
notify; sleep 0.5
eq "C: the same wait again → nothing" "1" "$(lines)"
row F/issue-7 '#7' question m4 '早就在问的' > "$AF"
notify; sleep 0.3
{ row F/issue-7 '#7' question m4 '早就在问的'; row F/issue-1909 '#1909' permission m5 'Bash: git push'; } > "$AF"
notify; settle 2
eq "C: answered, then a new wait → a new notification" "#1909 要你批准|Bash: git push · m5" "$(tail -1 "$NOTIFY_LOG")"
{ row F/issue-7 '#7' question m4 'x'; row F/scratch-3 'scratch-3' question m4 'y'; } > "$AF"
FLEET_NOTIFY=0 notify; sleep 0.5
eq "C: FLEET_NOTIFY=0 → nothing" "2" "$(lines)"
SHELLV=0 notify; sleep 0.5
eq "C: a node (no FLEET_SHELL) → nothing" "2" "$(lines)"
FLEET_NOTIFY=0 python3 "$BIN/fleet-client-actions.py" notify --title t --body b --jump wid:F/x; sleep 0.2
eq "C: FLEET_NOTIFY=0 reaches the notifier too → nothing" "2" "$(lines)"

# ============================================================================
# D. focus — a notifier with no click: the focus-in takes the jump
# ============================================================================
printf '{"caps":["iterm2"]}\n' > "$WORK/client.where.json"
printf '#!/bin/sh\ncat >> "%s/escapes"\n' "$WORK" > "$WORK/escape"; chmod +x "$WORK/escape"
export FLEET_CLIENT_ESCAPE_CMD="$WORK/escape"
T set-option -up -t "$LIST" @sidebar_do 2>/dev/null
python3 "$BIN/fleet-client-actions.py" notify --title '#1909 在问你' --body q --jump wid:F/issue-1909
case "$(T show-options -gqv @notify_jump)" in *" wid:F/issue-1909") CHECKS=$((CHECKS+1)) ;; *) fail "D: the jump waits in @notify_jump" "$(T show-options -gqv @notify_jump)" ;; esac
case "$(cat "$WORK/escapes" 2>/dev/null)" in *"1337;RequestAttention=yes"*"]9;#1909 在问你: q"*) CHECKS=$((CHECKS+1)) ;; *) fail "D: iTerm2 gets RequestAttention and OSC 9" "$(cat -v "$WORK/escapes")" ;; esac
python3 "$BIN/fleet-client-actions.py" jump-pending
eq "D: the focus-in takes it → the list jumps" "jump=wid:F/issue-1909" "$(T show-options -pqv -t "$LIST" @sidebar_do | tr -d ' ')"
eq "D: …once" "" "$(T show-options -gqv @notify_jump)"
T set-option -up -t "$LIST" @sidebar_do
T set-option -g @notify_jump "$(( $(date +%s) - 120 )) wid:F/issue-7"
python3 "$BIN/fleet-client-actions.py" jump-pending
eq "D: past FLEET_NOTIFY_JUMP_SECS → dropped, no jump" "|" "$(T show-options -pqv -t "$LIST" @sidebar_do)|$(T show-options -gqv @notify_jump)"

# ============================================================================
# E. keys — the bar's middle says what you can press right now
# ============================================================================
CONF="$BIN/../conf/tmux-shell.conf"
grep -E '^set -g @fleet_hint' "$CONF" > "$WORK/hint.conf"
T source-file "$WORK/hint.conf" || fail "E: the hint lines do not load"
T set-option -g status-left "$(sed -n 's/^set -g status-left "\(.*\)"$/\1/p' "$CONF" | sed 's|#(bash __BIN__/fleet-client-badge.sh cw=#{client_width})|B|')"
"$REAL_TMUX" -L "${L}o" -f /dev/null new-session -d -s o -x 150 -y 20 "env -u TMUX $REAL_TMUX -L $L attach -t '=$L'" \
  || fail "E: could not attach a client"
i=0; CL=''; while [ -z "$CL" ] && [ "$i" -lt 30 ]; do CL=$(T list-clients -F '#{client_name}' | head -1); sleep 0.1; i=$((i+1)); done
[ -n "$CL" ] || fail "E: no client attached"
hint() { T display-message -p -c "$CL" '#{E:@fleet_hint}' | sed 's/#\[[^]]*\]//g'; }
raw() { T display-message -p -c "$CL" '#{E:@fleet_hint}'; }
T select-pane -t "$PANE"
eq "E: the keyboard in the session → its keys" " ⌘N 新任务  ⌘P 跳转  ⌘↑↓ 切换  ⌘J 等你的  ⌘. 展开/收起  ⌘/ 按键  ⌘Q 退出 fleet" "$(hint)"
case "$(raw)" in *"range=user|key-User928]"*"⌘N"*"range=user|key-User924]"*"⌘J"*) CHECKS=$((CHECKS+1)) ;; *) fail "E: each key is its own key-<key> range" "$(raw)" ;; esac
T switch-client -c "$CL" -T prefix
eq "E: prefix pressed → the prefix keys" " n p 切换  k 等你的  c 新任务  / 跳转  ? 按键  d 放到后台  Q 退出 fleet" "$(hint)"
T switch-client -c "$CL" -T root
T set-option -g @popup_open "$(date +%s)"; T set-option -g @popup_title popup_quickopen
eq "E: ⌘P open → its keys" " ↵ 去  > 命令  esc 关" "$(hint)"
T set-option -g @popup_title popup_keys
eq "E: another popup → esc" " esc 关" "$(hint)"
T set-option -g @popup_open 0
T set-option -p -t "$PANE" @stage_ask 1
eq "E: a question's pane → ↵ / esc" " ↵ 确定  esc 取消" "$(hint)"
T set-option -pu -t "$PANE" @stage_ask
T set-option -w -t "$PANE" @fleet_on_list 1
eq "E: a tap on the list → what a tap does" " 点一行 切过去  右键 菜单  ⌘P 跳转  ⌘N 新任务  ⌘. 展开/收起  ⌘/ 按键" "$(hint)"
T set-option -w -t "$PANE" @fleet_hint_name 'issue-1909 · 一个很长很长的名字, 带逗号'
eq "E: …with the clipped row's whole name first" " issue-1909 · 一个很长很长的名字, 带逗号  │  点一行 切过去  右键 菜单  ⌘P 跳转  ⌘N 新任务  ⌘. 展开/收起  ⌘/ 按键" "$(hint)"
T set-option -uw -t "$PANE" @fleet_on_list
T set-option -w -t "$PANE" @fleet_view portal
eq "E: the writing area in view → its keys" " ↵ 发出  ⇧↵ 换行  Tab 下一项  esc 回去" "$(hint)"
T set-option -w -t "$PANE" @fleet_orch 1
eq "E: …with an orchestrator: ⌘N 编排 and ⇧⇥ (issue #2146)" " ↵ 发出  ⇧↵ 换行  Tab 下一项  ⌘N 编排  ⇧⇥ 交给编排  esc 回去" "$(hint)"
case "$(raw)" in *"range=user|key-User928]"*"⌘N"*"range=user|key-BTab]"*"⇧⇥"*) CHECKS=$((CHECKS+1)) ;; *) fail "E: the writing area's ⌘N / ⇧⇥ are key ranges (issue #2146)" "$(raw)" ;; esac
T set-option -uw -t "$PANE" @fleet_view
eq "E: …and in a session, ⌘N is still 新任务" " ⌘N 新任务  ⌘P 跳转  ⌘↑↓ 切换  ⌘J 等你的  ⌘. 展开/收起  ⌘/ 按键  ⌘Q 退出 fleet" "$(hint)"
T set-option -uw -t "$PANE" @fleet_orch
sl=$(T display-message -p -c "$CL" '#{E:status-left}' | sed 's/#\[[^]]*\]//g')
case "$sl" in "B   ⌘N 新任务  ⌘P 跳转"*) CHECKS=$((CHECKS+1)) ;; *) fail "E: the status line at 150 columns carries the slot, then the hint, after the badge" "$sl" ;; esac
# The refresh slot (issue #2228): ⟳ lights in a two-cell slot the bar always
# keeps, so the keys start on the same column lit or not.
T set-option -w -t "$PANE" @fleet_refreshing 1
lit=$(T display-message -p -c "$CL" '#{E:status-left}' | sed 's/#\[[^]]*\]//g')
case "$lit" in "B⟳  ⌘N 新任务  ⌘P 跳转"*) CHECKS=$((CHECKS+1)) ;; *) fail "E: a waiting list lights ⟳ in the slot" "$lit" ;; esac
col() { python3 -c 'import sys; print(sys.argv[1].index("⌘N"))' "$1"; }
eq "E: the keys start on the same column, lit or not" "$(col "$sl")" "$(col "$lit")"
T set-option -uw -t "$PANE" @fleet_refreshing
eq "E: …and the slot goes back to two blanks" "$sl" "$(T display-message -p -c "$CL" '#{E:status-left}' | sed 's/#\[[^]]*\]//g')"
T resize-window -t "=$L:" -x 90 2>/dev/null; "$REAL_TMUX" -L "${L}o" resize-window -t =o -x 90 2>/dev/null; sleep 0.2
eq "E: narrower than 100 columns → the badge alone" "B" "$(T display-message -p -c "$CL" '#{E:status-left}')"
"$REAL_TMUX" -L "${L}o" kill-server 2>/dev/null
# the list's half (fleet-sidebar.py bar_hint): the highlighted row's detail (issue #2305)
out=$(python3 - "$BIN" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("side", sys.argv[1] + "/fleet-sidebar.py")
side = importlib.util.module_from_spec(spec); spec.loader.exec_module(side)
long = ["@3", "needs", "?", "issue-1909 · 一个很长很长很长很长很长很长的名字 #x", "  ", "", "0", "", ""]
short = ["@4", "done", "✓", "ok", "  ", "", "0", "", ""]
rows = [["hdr", "acme", "", "acme"], long, short]
print(side.bar_hint(rows, "@3", "@4", 30))
print(side.bar_hint(rows, "@4", "@4", 30))
print(side.bar_hint(rows, "@4", side.PORTAL_KEY, 30))
print(side.bar_hint(rows, "@4", side.PORTAL_KEY, 30, True))
PY
)
eq "E: bar_hint — the highlighted row's detail (# doubled), the writing area as a view" \
   "('', 'issue-1909 · 一个很长很长很长很长很长很长的名字 ##x', '')
('', 'ok', '')
('portal', 'ok', '')
('portal', 'ok', '1')" "$out"
# a tap on a range is that key; 「! n 等你」 is ⌘J
grep -q "bind -n MouseDown1Status if -F '#{m:key-\*,#{mouse_status_range}}' { run-shell -C \"send-keys -K -c '#{client_name}' '#{s/^key-//:mouse_status_range}'\" }" "$CONF" \
  && grep -q "#{==:#{mouse_status_range},needs}' { run-shell -C \"send-keys -K -c '#{client_name}' User924\" }" "$CONF" \
  || fail "E: the bar's taps are not the keys"
CHECKS=$((CHECKS+1))

printf 'needs-notify selftest: PASS (%s checks)\n' "$CHECKS"
