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
#   C. notify   — moved to bin/notify-selftest.sh (issue #2759: the client's
#                 refresh loop decides it); here: the bar's old road is a no-op,
#                 and FLEET_NOTIFY=0 reaches the notifier
#   D. focus    — a notifier with no click of its own (iTerm2's OSC 9): the jump
#                 waits in @notify_jump and `jump-pending` (the client's focus-in)
#                 takes it once; past FLEET_NOTIFY_JUMP_SECS it is dropped
#   E. keys     — the bar's middle (conf/tmux-shell.conf @fleet_hint) for a real
#                 client attached to an isolated server: the session's keys by
#                 default (⌘N ⌘P ⌘↑↓ ⌘., each a `key-<key>` range); the prefix
#                 keys while prefix is pressed; ⌘P's while its popup is open; ↵ /
#                 esc in a question's pane; what a tap does on the list, with the
#                 highlighted row's detail (fleet-sidebar.py bar_hint, #2305 — #948's
#                 `? 快捷键` row is gone, the bar says it); the writing area's; a
#                 tap on a range is that key (MouseDown1Status → send-keys -K) and
#                 「! n 等你」 jumps to the one waiting (#2362: no ⌘J); narrower than 100 columns the line goes
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
# The notification itself is bin/fleet_notify.py's since issue #2759 (the
# client's refresh loop — bin/notify-selftest.sh); the bar's old road is a no-op.
eq "C: fleet_alerts_notify (the bar's road) is retired — nothing" "0|" \
   "$(TMUX="$SOCK,0,0" FLEET_SHELL=1 bash -c '. "$1/usage-lib.sh"; . "$1/fleet-alerts.sh"; fleet_alerts_notify; echo $?' _ "$BIN")|$(cat "$NOTIFY_LOG" 2>/dev/null)"
FLEET_NOTIFY=0 python3 "$BIN/fleet-client-actions.py" notify --title t --body b --jump wid:F/x; sleep 0.2
eq "C: FLEET_NOTIFY=0 reaches the notifier too → nothing" "" "$(cat "$NOTIFY_LOG" 2>/dev/null)"

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
# the bar is login · ⟳ · the keys of where the keyboard is (issue #2365)
eq "E: the keyboard in the session → its keys" " ⌘P 会话与动作  ⌘T 派单  ⌘N 编排  ⌘↑↓ 切换  ⌘Q 退出 fleet" "$(hint)"
case "$(raw)" in *"range=user|key-User927]"*"⌘P"*"range=user|key-User928]"*"⌘N"*) CHECKS=$((CHECKS+1)) ;; *) fail "E: each key is its own key-<key> range" "$(raw)" ;; esac
T set-option -g @fleet_layout solo
eq "E: the one-session view → ⌃\\ 会话 shell, ⌃D 放到后台 in ⌘↑↓'s place (issue #2566)" " ⌘P 会话与动作  ⌘T 派单  ⌘N 编排  ⌃\\ 会话 shell  ⌃D 放到后台  ⌘Q 退出 fleet" "$(hint)"
case "$(raw)" in *"range=user|key-C-d]"*"⌃D"*) CHECKS=$((CHECKS+1)) ;; *) fail "E: ⌃D is its key range" "$(raw)" ;; esac
T set-option -gu @fleet_layout
T switch-client -c "$CL" -T prefix
eq "E: prefix pressed → the prefix keys" " / 会话与动作  t 派单  c 编排  n p 切换  d 放到后台  Q 退出 fleet" "$(hint)"
T switch-client -c "$CL" -T root
T set-option -g @popup_open "$(date +%s)"; T set-option -g @popup_title popup_quickopen
eq "E: ⌘P open → the panel's keys" " ↵ 切过去  ⌃R 改名  ⌃X 回收  ⌃A 回答  ⌃E 回收方式  ⌃O PR  > 命令  esc 关" "$(hint)"
eq "E: …the panel's own last line says the same" "$(hint | sed 's/^ //')" "$(FLEET_UI_LANG=zh sh "$BIN/fleet-ui-lang.sh" t quickopen_keys)"
T set-option -g @popup_title popup_keys
eq "E: another popup → esc" " esc 关" "$(hint)"
T set-option -g @popup_open 0
T set-option -p -t "$PANE" @stage_ask 1
eq "E: a question's pane → ↵ / esc" " ↵ 确定  esc 取消" "$(hint)"
T set-option -pu -t "$PANE" @stage_ask
# a tap on the list, and the lit row's detail, change nothing (issue #2365)
T set-option -w -t "$PANE" @fleet_on_list 1
T set-option -w -t "$PANE" @fleet_hint_name 'issue-1909 · 一个很长很长的名字, 带逗号'
eq "E: a tap on the list / a lit row → the same keys" " ⌘P 会话与动作  ⌘T 派单  ⌘N 编排  ⌘↑↓ 切换  ⌘Q 退出 fleet" "$(hint)"
T set-option -uw -t "$PANE" @fleet_on_list
T set-option -uw -t "$PANE" @fleet_hint_name
T set-option -w -t "$PANE" @fleet_view portal
eq "E: the writing area in view → its keys" " ↵ 发出  ⇧↵ 换行  Tab 下一项  esc 回去" "$(hint)"
T set-option -w -t "$PANE" @fleet_orch 1
eq "E: …with an orchestrator: ⌘N 编排 and ⇧⇥ (issue #2146)" " ↵ 发出  ⇧↵ 换行  Tab 下一项  ⌘N 编排  ⇧⇥ 交给编排  esc 回去" "$(hint)"
case "$(raw)" in *"range=user|key-User928]"*"⌘N"*"range=user|key-BTab]"*"⇧⇥"*) CHECKS=$((CHECKS+1)) ;; *) fail "E: the writing area's ⌘N / ⇧⇥ are key ranges (issue #2146)" "$(raw)" ;; esac
T set-option -uw -t "$PANE" @fleet_view
eq "E: …and in a session, ⌘N is 编排 (issue #2616)" " ⌘P 会话与动作  ⌘T 派单  ⌘N 编排  ⌘↑↓ 切换  ⌘Q 退出 fleet" "$(hint)"
T set-option -g @fleet_compose 1
eq "E: …新任务 while FLEET_COMPOSE=1 brings the writing area back (issue #2616)" " ⌘P 会话与动作  ⌘T 派单  ⌘N 新任务  ⌘↑↓ 切换  ⌘Q 退出 fleet" "$(hint)"
T set-option -gu @fleet_compose
T set-option -uw -t "$PANE" @fleet_orch
sl=$(T display-message -p -c "$CL" '#{E:status-left}' | sed 's/#\[[^]]*\]//g')
case "$sl" in "B   ⌘P 会话与动作  ⌘T 派单  ⌘N 编排"*) CHECKS=$((CHECKS+1)) ;; *) fail "E: the status line at 150 columns carries the slot, then the hint, after the badge" "$sl" ;; esac
T set-option -g @fleet_layout solo
eq "E: the one-session view's bar is the same three things" "B   ⌘P 会话与动作  ⌘T 派单  ⌘N 编排  ⌃\\ 会话 shell  ⌃D 放到后台  ⌘Q 退出 fleet" \
  "$(T display-message -p -c "$CL" '#{E:status-left}' | sed 's/#\[[^]]*\]//g')"
T set-option -gu @fleet_layout
# The refresh slot (issue #2228): ⟳ lights in a two-cell slot the bar always
# keeps, so the keys start on the same column lit or not.
T set-option -w -t "$PANE" @fleet_refreshing 1
lit=$(T display-message -p -c "$CL" '#{E:status-left}' | sed 's/#\[[^]]*\]//g')
case "$lit" in "B⟳  ⌘P 会话与动作  ⌘T 派单  ⌘N 编排"*) CHECKS=$((CHECKS+1)) ;; *) fail "E: a waiting list lights ⟳ in the slot" "$lit" ;; esac
col() { python3 -c 'import sys; print(sys.argv[1].index("⌘P"))' "$1"; }
eq "E: the keys start on the same column, lit or not" "$(col "$sl")" "$(col "$lit")"
T set-option -uw -t "$PANE" @fleet_refreshing
eq "E: …and the slot goes back to two blanks" "$sl" "$(T display-message -p -c "$CL" '#{E:status-left}' | sed 's/#\[[^]]*\]//g')"
T resize-window -t "=$L:" -x 90 2>/dev/null; "$REAL_TMUX" -L "${L}o" resize-window -t =o -x 90 2>/dev/null; sleep 0.2
eq "E: narrower than 100 columns → the badge alone" "B" "$(T display-message -p -c "$CL" '#{E:status-left}')"
"$REAL_TMUX" -L "${L}o" kill-server 2>/dev/null
# the right end draws nothing; its job runs `part=quiet` for the notification (issue #2365)
grep -q '^set -g status-right "#(bash __BIN__/tmux-status.sh part=quiet ' "$CONF" || fail "E: status-right is not the quiet job"
CHECKS=$((CHECKS+1))
# a tap on a range is that key; 「! n 等你」 (an older bar's) jumps to the one waiting — the old ⌘J's body, inline (issue #2362)
grep -q "bind -n MouseDown1Status if -F '#{m:key-\*,#{mouse_status_range}}' { run-shell -C \"send-keys -K -c '#{client_name}' '#{s/^key-//:mouse_status_range}'\" }" "$CONF" \
  && grep -q "#{==:#{mouse_status_range},needs}' { if -F '#{@fleet_single}' { run-shell -b \"python3 __BIN__/fleet-quickopen.py do needs >/dev/null 2>&1 || :\" } { if -F '#{window_zoomed_flag}' { resize-pane -Z } ; if -F -t '{top-left}' '#{==:#{@sidebar},1}' { send-keys -t '{top-left}' F10 } } }" "$CONF" \
  || fail "E: the bar's taps are not the keys"
CHECKS=$((CHECKS+1))

printf 'needs-notify selftest: PASS (%s checks)\n' "$CHECKS"
