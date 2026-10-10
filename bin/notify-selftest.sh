#!/bin/bash
# notify-selftest.sh — a session needs you, and this computer says so (issue
# #2759, EPIC #2756 C3): bin/fleet_notify.py on the client's refresh loop
# (bin/fleet-hub-sessions.sh --refresh, client mode, the hub's answer a file),
# handing each event to bin/fleet-client-actions.py notify with a fake notifier
# (FLEET_CLIENT_NOTIFY_CMD) — no terminal attached to anything.
#
#   A. ask      the first round only remembers; needs → ONE notification (who,
#               what, where, with a sound); the same question every round →
#               none; working → needs → working → needs = 2; a new question
#               while still asking = a new one; logs/notify.ndjson one line each
#   B. stuck    needs/blocked → 卡住 with a sound; failed → 失败了
#   C. done     working → done: 做完, no sound, never the phone; a second of the
#               same batch within 10 minutes → ONE notification grown (same
#               group, 「做完了 2 个」); FLEET_NOTIFY_DONE=0 → none, logged skip
#   D. quiet    inside FLEET_NOTIFY_QUIET: still notified, no sound, no phone
#   E. orch     the orchestrator's decide=N going red → 「有事要你定」
#   F. phone    a Bark push for ask / stuck only, its address read from
#               secrets.env — never in the log, the argv, the environment
#   G. click    the notification's click lands `jump=wid:<worker>` on the list
#               and, no terminal attached, opens one running `fleet`
#   H. off      FLEET_NOTIFY=0: nothing — no notification, no state, no log
# No network, no live fleet. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'notify selftest: python3 absent — SKIP'; exit 0; }
REAL_TMUX=$(command -v tmux || true)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/notify-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
L="nfy$$"
cleanup() { [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
unset TMUX TMUX_PANE FLEET_NOTIFY FLEET_NOTIFY_DONE FLEET_NOTIFY_QUIET FLEET_NOTIFY_JUMP_SECS FLEET_CLIENT_NOTIFY_CMD \
      FLEET_CLIENT_ESCAPE_CMD CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_SESSIONS_LOCAL FLEET_NODE_ALIASES FLEET_HUB_URL \
      FLEET_NOTIFY_SEND_CMD FLEET_NOTIFY_LOG FLEET_NOTIFY_BARK_CMD FLEET_NOTIFY_OPEN_CMD
export HOME="$WORK/home" TMPDIR="$WORK/t" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 CCQUOTA_FLEET=1 \
       FLEET_HUB_SESSIONS_CLIENT="$L" FLEET_SHELL_SESSION="$L" FLEET_HUB_SESSIONS_USER='*' \
       FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions.json'" FLEET_UI_LANG=zh FLEET_ALLOW_SENDKEYS=1 \
       FLEET_NOTIFY_LOG="$WORK/notify.ndjson" FLEET_NOTIFY_QUIET=off
mkdir -p "$HOME" "$TMPDIR" "$FLEET_CONF_DIR"
G="$TMPDIR/.claude-dash/global"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }
has() { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) ;; *) fail "$1 (no '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1 ('$3' is there)" "$2" ;; esac; }

F=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
printf '{"caps":["notify"]}\n' > "$TMPDIR/client.where.json"
cat > "$WORK/notifier" <<'SH'
#!/bin/sh
# a fake notifier: title|body|sound, then — when asked — the person clicks it
printf '%s|%s|%s\n' "$1" "$2" "${FLEET_NOTIFY_SOUND:-}" >> "$NOTIFY_OUT"
[ -n "${CLICK_IT:-}" ] && [ -n "${FLEET_NOTIFY_CLICK:-}" ] && eval "$FLEET_NOTIFY_CLICK"
exit 0
SH
printf '#!/bin/sh\nprintf "%%s|%%s|%%s\\n" "$1" "$2" "$(cat)" >> "%s/phone"\n' "$WORK" > "$WORK/bark"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/opened"\n' "$WORK" > "$WORK/opener"
chmod +x "$WORK/notifier" "$WORK/bark" "$WORK/opener"
export NOTIFY_OUT="$WORK/out" FLEET_CLIENT_NOTIFY_CMD="$WORK/notifier" FLEET_NOTIFY_BARK_CMD="$WORK/bark" \
       FLEET_NOTIFY_OPEN_CMD="$WORK/opener"
: > "$NOTIFY_OUT"

# row <key> <state> [needs] [detail] [extra json] — one session of the hub's answer
row() { printf '{"worker_id":"%s/%s","fleet_id":"%s","machine_name":"m5","os_user":"u","availability":"online","worker":{"issue":%s,"repo":"o/r","state":"%s","needs":"%s","detail":"%s","agent":"claude","name":"%s"%s}}' \
          "$F" "$1" "$F" "${1#issue-}" "$2" "${3:-}" "${4:-}" "$1" "${5:-}"; }
answer() { local IFS=,; printf '{"sessions":[%s],"nodes":[{"machine_name":"m5","availability":"online","sessions":1}]}\n' "$*" > "$WORK/sessions.json"; }
round() { bash "$BIN/fleet-hub-sessions.sh" --refresh >/dev/null 2>"$WORK/refresh.err"; }
lines() { wc -l < "$NOTIFY_OUT" | tr -d ' '; }
# the send is detached: wait for the n-th line (or 5 s), then a beat more
settle() { local i=0; while [ "$i" -lt 50 ] && [ "$(lines)" -lt "$1" ]; do sleep 0.1; i=$((i+1)); done; sleep 0.3; }
last() { tail -1 "$NOTIFY_OUT"; }

# ============================================================================ A
answer "$(row issue-1909 working)" "$(row issue-7 needs ask '早就在问的')"
round
eq "A: the first round only remembers (a client starting with one waiting is no notification)" 0 "$(lines)"
[ -s "$G/notify.state.json" ] || fail "A: no state file after the first round" "$(cat "$WORK/refresh.err")"
answer "$(row issue-1909 needs ask '演练放在 m5 还是只在 m4？')" "$(row issue-7 needs ask '早就在问的')"
round; settle 1
eq "A: needs → one notification: who, what, where, with a sound" "#1909 在问你|演练放在 m5 还是只在 m4？ · m5|1" "$(last)"
round; round; sleep 0.5
eq "A: the same question every round → nothing more" 1 "$(lines)"
answer "$(row issue-1909 working)" "$(row issue-7 needs ask '早就在问的')"; round
answer "$(row issue-1909 needs perm 'Bash: git push')" "$(row issue-7 needs ask '早就在问的')"; round; settle 2
eq "A: working → needs → working → needs = 2" 2 "$(lines)"
eq "A: …the second says what is asked now" "#1909 要你批准|Bash: git push · m5|1" "$(last)"
answer "$(row issue-1909 needs ask '换一个问题')" "$(row issue-7 needs ask '早就在问的')"; round; settle 3
eq "A: a new question while still asking → a new one" "#1909 在问你|换一个问题 · m5|1" "$(last)"
n=$(grep -c '"state": "ask"' "$WORK/notify.ndjson" 2>/dev/null)
eq "A: logs/notify.ndjson: one line per notification" 3 "$n" "$(cat "$WORK/notify.ndjson" 2>/dev/null)"
has "A: …key · state · sent" "$(tail -1 "$WORK/notify.ndjson")" "\"key\": \"$F/issue-1909\", \"state\": \"ask\", \"sent\": \"notified\""

# ============================================================================ B
answer "$(row issue-1909 needs blocked 'CI 红了，等你看')" "$(row issue-7 failed)"; round; settle 5
eq "B: needs/blocked → 卡住, with a sound" 1 "$(grep -c '^#1909 被卡住了|CI 红了，等你看 · m5|1$' "$NOTIFY_OUT")"
eq "B: failed → 失败了, with a sound" 1 "$(grep -c '^#7 失败了|m5|1$' "$NOTIFY_OUT")"

# ============================================================================ C
E=',"epic":"o/r#2756:1/3"'
answer "$(row issue-1909 working '' '' "$E")" "$(row issue-7 working '' '' "$E")" "$(row issue-8 working)"; round
answer "$(row issue-1909 done '' '' "$E")" "$(row issue-7 working '' '' "$E")" "$(row issue-8 working)"; round; settle 6
eq "C: working → done: 做完, no sound" "#1909 做完了|m5|" "$(last)"
answer "$(row issue-1909 done '' '' "$E")" "$(row issue-7 done '' '' "$E")" "$(row issue-8 working)"; round; settle 7
eq "C: the same batch within 10 minutes → its one notification grown" "#2756 做完了 2 个|最新：#7 · m5|" "$(last)"
answer "$(row issue-1909 done '' '' "$E")" "$(row issue-7 done '' '' "$E")" "$(row issue-8 done)"
FLEET_NOTIFY_DONE=0 round; sleep 0.5
eq "C: FLEET_NOTIFY_DONE=0 → no 做完" 7 "$(lines)"
has "C: …logged as a skip" "$(tail -1 "$WORK/notify.ndjson")" '"skip": "done-off"'
eq "C: a done never reaches the phone" "" "$(grep -c '做完' "$WORK/phone" 2>/dev/null | grep -v '^0$')"

# ============================================================================ D
answer "$(row issue-1909 working)" "$(row issue-7 working)" "$(row issue-8 working)"; round
answer "$(row issue-1909 needs ask '夜里的问题')" "$(row issue-7 working)" "$(row issue-8 working)"
q=$(python3 -c 'import time; t=time.localtime(); h=t.tm_hour; print("%02d:00-%02d:00" % (h, (h + 2) % 24))')
: > "$WORK/phone"
printf 'FLEET_NOTIFY_BARK_URL="https://api.day.app/SeCrEtKeY123"\n' > "$FLEET_CONF_DIR/secrets.env"
FLEET_NOTIFY_QUIET=$q round; settle 8
eq "D: quiet hours: still notified, no sound" "#1909 在问你|夜里的问题 · m5|" "$(last)"
eq "D: …and nothing to the phone" "" "$(cat "$WORK/phone")"

# ============================================================================ E
O='"role":"orchestrator"'
answer "$(row issue-1909 needs ask '夜里的问题')" "$(row issue-90 done '' '' ",$O")"; round
answer "$(row issue-1909 needs ask '夜里的问题')" "$(row issue-90 done '' '' ",$O,\"orch_decide\":2")"; round; settle 9
eq "E: the orchestrator's decide=N going red → 有事要你定" "编排会话 有事要你定|决定单 2 行 · m5|1" "$(last)"

# ============================================================================ F
eq "F: ask → the phone, its address from secrets.env" "编排会话 有事要你定|决定单 2 行 · m5|https://api.day.app/SeCrEtKeY123" "$(cat "$WORK/phone")"
hasnt "F: the address is never in logs/notify.ndjson" "$(cat "$WORK/notify.ndjson")" SeCrEtKeY123
has "F: …which says the phone was sent" "$(tail -1 "$WORK/notify.ndjson")" '"phone": "sent"'
hasnt "F: …nor in the client's environment list (fleet-shell.sh SHELL_ENV)" "$(grep -n 'FLEET_NOTIFY_BARK' "$BIN/fleet-shell.sh")" BARK
FLEET_NOTIFY_BARK_URL=https://evil.example/x python3 -c 'import importlib.util,sys
spec = importlib.util.spec_from_file_location("a", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.bark_url())' "$BIN/fleet-client-actions.py" > "$WORK/bu"
eq "F: …read from secrets.env alone, never the environment" "https://api.day.app/SeCrEtKeY123" "$(cat "$WORK/bu")"

# ============================================================================ G
if [ -n "$REAL_TMUX" ]; then
  T() { "$REAL_TMUX" -L "$L" "$@"; }
  T -f /dev/null new-session -d -s "$L" -n home 'sleep 600' || fail "G: could not start the isolated server"
  T split-window -d -t "=$L:" 'sleep 600'
  LIST=$(T list-panes -t "=$L:" -F '#{pane_id}' | tail -1)
  T set-option -p -t "$LIST" @sidebar 1
  answer "$(row issue-1909 working)"; round
  answer "$(row issue-1909 needs ask '点我')"
  CLICK_IT=1 round; settle 10
  i=0; while [ "$i" -lt 30 ] && [ ! -s "$WORK/opened" ]; do sleep 0.1; i=$((i+1)); done
  eq "G: the click lands on the list as jump=wid:<worker>" "jump=wid:$F/issue-1909" "$(T show-options -pqv -t "$LIST" @sidebar_do | tr -d ' ')"
  has "G: …and with no terminal attached, one opens running fleet" "$(cat "$WORK/opened" 2>/dev/null)" fleet
fi

# ============================================================================ H
rm -f "$G/notify.state.json" "$WORK/notify.ndjson"; : > "$NOTIFY_OUT"
answer "$(row issue-1909 working)"; FLEET_NOTIFY=0 round
answer "$(row issue-1909 needs ask 'x')"; FLEET_NOTIFY=0 round; sleep 0.5
eq "H: FLEET_NOTIFY=0 → no notification, no state, no log" "0||" "$(lines)|$(cat "$G/notify.state.json" 2>/dev/null)|$(cat "$WORK/notify.ndjson" 2>/dev/null)"
eq "H: …and the old road is a no-op (fleet_alerts_notify)" "0" \
   "$(FLEET_SHELL=1 bash -c '. "$1/usage-lib.sh"; . "$1/fleet-alerts.sh"; fleet_alerts_notify; echo $?' _ "$BIN")"

printf 'notify selftest: PASS (%s checks)\n' "$CHECKS"
