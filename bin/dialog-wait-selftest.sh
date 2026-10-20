#!/bin/bash
# dialog-wait-selftest.sh — a session waiting on a choice dialog is SEEN, and can be
# answered through one guarded road (issue #2958).
#
#   S  the state (bin/set-claude-state.sh, isolated tmux):
#      a looping driver whose /loop wake opens an AskUserQuestion reads needs/ask;
#      a Stop and the mod's turn.complete arriving while the transcript still holds
#      it unanswered leave it needs/ask; answered (tool_result + PostToolUse) and
#      stopped ⇒ looping again
#   C  the channel (bin/fleet_dialog_answer.py → bin/fleet-answer.sh) against a fake
#      dialog in an isolated tmux: answered + confirmed + the trail (the answer log
#      代答记录, record-only comment); a fingerprint that differs ⇒ 3, nothing pressed; a label
#      not among the options ⇒ 3; a draft in the input box ⇒ 5, nothing pressed; a
#      press never confirmed ⇒ 4 and exactly ONE key reached the pane
#   G  hooks/bash-guard.py still refuses a raw `tmux send-keys` into a fleet and
#      lets the channel's script run
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
REAL_TMUX=''
while IFS= read -r t; do case "$t" in */tmux-shim/*) ;; *) REAL_TMUX=$t; break ;; esac; done < <(type -ap tmux)
[ -n "$REAL_TMUX" ] || { echo "dialog-wait: tmux absent — SKIP"; exit 0; }
st_need python3
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dlgw.XXXXXX") || exit 2
SOCK="$WORK/t.sock"
tf() { "$REAL_TMUX" -S "$SOCK" "$@"; }
cleanup() { tf kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
st_tally

mkdir -p "$WORK/path" "$WORK/home/.claude/projects/p" "$WORK/conf/fleets/st/repos" "$WORK/gh"
export FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh FLEET_SKIP_GLOBAL_CONF=1
printf 'FLEET_REPO="o/r"\n' > "$FLEET_CONF_DIR/fleets/st/repos/o-r.conf"
# every bare `tmux` (the hooks, fleet-lib, fleet-answer) reaches the isolated server
st_tmux_socket "$WORK/path" "$SOCK" strip
cat > "$WORK/path/claude" <<EOF
#!/bin/sh
cat >/dev/null; echo called >> "$WORK/claude.calls"; echo STOPPED
EOF
chmod +x "$WORK/path/"*
PATH="$WORK/path:$(printf '%s' "$PATH" | tr ':' '\n' | grep -v tmux-shim | paste -sd: -)"; export PATH

SID=11111111-2222-3333-4444-555555555555
TP="$WORK/home/.claude/projects/p/$SID.jsonl"
# ask <tuid> <question> <label>… — the assistant's AskUserQuestion, unanswered
ask() {
  python3 - "$TP" "$@" <<'PY'
import json, sys
path, tuid, q = sys.argv[1:4]
opts = [{"label": l, "description": ""} for l in sys.argv[4:]]
line = {"type": "assistant", "message": {"role": "assistant", "content": [
    {"type": "tool_use", "id": tuid, "name": "AskUserQuestion",
     "input": {"questions": [{"question": q, "header": "部署", "multiSelect": False, "options": opts}]}}]}}
open(path, "a").write(json.dumps(line, ensure_ascii=False) + "\n")
PY
}
answered() {
  python3 - "$TP" "$1" "$2" <<'PY'
import json, sys
path, tuid, label = sys.argv[1:4]
line = {"type": "user", "message": {"role": "user", "content": [
    {"type": "tool_result", "tool_use_id": tuid, "content": "User has answered: %s" % label}]}}
open(path, "a").write(json.dumps(line, ensure_ascii=False) + "\n")
PY
}

# ===================== S — the state ==========================================
tf -f /dev/null new-session -d -s st -n driver 'exec sleep 600' || { echo "dialog-wait: cannot start tmux"; exit 1; }
PANE=$(tf display-message -p -t st:driver '#{pane_id}')
TMUXV="$SOCK,1,0"
st() { tf display-message -p -t "$PANE" '#{@claude_state}/#{@claude_needs}'; }
hook() {  # hook <verb> [payload] [--via mod]
  local verb=$1 payload=${2:-} via=${3:-}
  printf '%s' "$payload" | env TMUX="$TMUXV" TMUX_PANE="$PANE" HOME="$WORK/home" CLAUDE_CODE_ENTRYPOINT=cli \
    FLEET_AUTO_HANDOFF_PCT=0 sh "$BIN/set-claude-state.sh" $via "$verb" >/dev/null 2>&1
}
next=$(( $(date +%s) + 1200 ))
tf set-window-option -t "$PANE" @cc_session_id "$SID"
tf set-window-option -t "$PANE" @loop "kind=wakeup next=$next ttl=1500"
STOP="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TP\"}"
: > "$TP"
hook 'done' "$STOP"
[ "$(st)" = looping/ ] && st_ok "S: a driver with a Loop pending stops as looping" || st_miss "S: before the wake: $(st)"
# the wake's turn opens the dialog
ask toolu_A '谁来部署入口？' '我来部署 (Recommended)' '等发起人'
hook busy '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"谁来部署入口？","options":[{"label":"我来部署 (Recommended)"},{"label":"等发起人"}]}]}}'
[ "$(st)" = needs/ask ] && st_ok "S: the dialog opened inside the /loop wake reads needs/ask" || st_miss "S: wake dialog: $(st)"
hook 'done' "$STOP"
[ "$(st)" = needs/ask ] && st_ok "S: a Stop with the dialog still open leaves needs/ask (not looping)" || st_miss "S: Stop over the open dialog: $(st)"
hook 'done' '' '--via mod'
[ "$(st)" = needs/ask ] && st_ok "S: the mod's turn.complete (no payload: @cc_session_id's transcript) leaves needs/ask" \
  || st_miss "S: mod done over the open dialog: $(st)"
answered toolu_A '我来部署 (Recommended)'
hook working '{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}'
[ "$(st)" = working/ ] || st_miss "S: after the answer: $(st)"
hook 'done' "$STOP"
[ "$(st)" = looping/ ] && st_ok "S: answered, the turn ends ⇒ looping again" || st_miss "S: after the answer's Stop: $(st)"

# the channel's trail comment goes to a fake poster (FLEET_DIALOG_POST_CMD)
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh-post" <<'EOF'
#!/bin/sh
{ printf '>>> %s#%s %s\n' "$1" "$2" "$3"; cat; printf '\n'; } >> "$ST_GH/posts.log"
echo "https://github.com/$1/issues/$2#issuecomment-1"
EOF
chmod +x "$WORK/bin/"*
export ST_GH="$WORK/gh" FLEET_DIALOG_POST_CMD="$WORK/bin/gh-post" FLEET_DIALOG_PROJECTS="$WORK/home/.claude/projects"

# ===================== C — the channel ========================================
# a fake AskUserQuestion: the question, two rows; a digit answers it — `answer`
# writes the tool_result, `swallow` clears the dialog and writes none
cat > "$WORK/tui.py" <<'PY'
import json, os, sys, termios, tty
tp, tuid, mode, keys = sys.argv[1:5]
fd = sys.stdin.fileno()
tty.setraw(fd)
draft = mode == "draft"
out = "\x1b[2J\x1b[H"
if draft:
    out += "  ⎿ earlier output\r\n" + "─" * 40 + "\r\n❯ half a sentence the person is typing\r\n" + "─" * 40 + "\r\n\r\n"
out += "谁来部署入口？\r\n\r\n❯ 1. 我来部署\r\n  2. 等发起人\r\n\r\nEnter to select · Esc to cancel\r\n"
sys.stdout.write(out); sys.stdout.flush()
while True:
    ch = os.read(fd, 1)
    with open(keys, "a") as f:
        f.write(repr(ch) + "\n")
    if ch in (b"1", b"2"):
        label = ["我来部署", "等发起人"][int(ch) - 1]
        sys.stdout.write("\x1b[2J\x1b[H· 谁来部署入口？ → %s\r\n" % label); sys.stdout.flush()
        if mode == "answer":
            line = {"type": "user", "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": tuid, "content": "User has answered: %s" % label}]}}
            open(tp, "a").write(json.dumps(line, ensure_ascii=False) + "\n")
PY
CSID=99999999-2222-3333-4444-555555555555
CTP="$WORK/home/.claude/projects/p/$CSID.jsonl"
mkdialog() {  # mkdialog <name> <mode> — a window holding the fake dialog, its transcript fresh
  : > "$CTP"; TP="$CTP" ask toolu_D '谁来部署入口？' '我来部署' '等发起人'
  rm -f "$WORK/keys.$1"
  tf new-window -d -t st -n "$1" "python3 '$WORK/tui.py' '$CTP' toolu_D $2 '$WORK/keys.$1'"
  W=$(tf display-message -p -t "st:$1" '#{window_id}')
  tf set-window-option -t "$W" @claude_state needs
  tf set-window-option -t "$W" @claude_needs ask
  tf set-window-option -t "$W" @cc_session_id "$CSID"
  tf set-window-option -t "$W" @epic o/r#2482
  sleep 0.5
}
: > "$CTP"; TP="$CTP" ask toolu_D '谁来部署入口？' '我来部署' '等发起人'
FP=$(python3 "$BIN/fleet_needs_detail.py" dialog "$CTP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fp"])')
CH() { env -u TMUX FLEET_ANSWER_POLL=0.3 FLEET_ANSWER_TIMEOUT=4 \
  python3 "$BIN/fleet_dialog_answer.py" "$@" -L x --session st >"$WORK/ch.out" 2>"$WORK/ch.err"; }
: > "$ST_GH/posts.log"
mkdialog c1 answer
CH "$W" --fp 0000000000000000 --pick 等发起人; rc=$?
[ "$rc" = 3 ] && [ ! -s "$WORK/keys.c1" ] && st_ok "C: a fingerprint that differs ⇒ 3, nothing pressed" \
  || st_miss "C: wrong fp rc=$rc keys=$(cat "$WORK/keys.c1" 2>/dev/null) $(cat "$WORK/ch.err")"
CH "$W" --fp "$FP" --pick 'Type something'; rc=$?
[ "$rc" = 3 ] && [ ! -s "$WORK/keys.c1" ] && st_ok "C: a label not among the options (free text) ⇒ 3, nothing pressed" \
  || st_miss "C: free text rc=$rc $(cat "$WORK/ch.err")"
CH "$W" --fp "$FP" --pick 等发起人 --by session --basis '章程第 3 条'; rc=$?
DEC="$FLEET_CONF_DIR/fleets/st/answers/answers-$(date +%F).md"
[ "$rc" = 0 ] && grep -q '等发起人' "$CTP" && [ "$(grep -c . "$WORK/keys.c1")" = 1 ] \
  && grep -q '会话按章程代答（章程第 3 条）.*选「等发起人」' "$DEC" 2>/dev/null \
  && grep -q '^>>> o/r#2482 note' "$ST_GH/posts.log" && grep -q 'fleet:dialog-answer by=session' "$ST_GH/posts.log" \
  && st_ok "C: answered + confirmed in the transcript, one key; the trail in answers-<day>.md and on the batch issue" \
  || st_miss "C: answer rc=$rc keys=$(cat "$WORK/keys.c1" 2>/dev/null | tr '\n' ' ') err=$(cat "$WORK/ch.err") dec=$(cat "$DEC" 2>/dev/null)"
CH "$W" --fp "$FP" --pick 等发起人; rc=$?
[ "$rc" = 3 ] && st_ok "C: the same dialog again (already answered) ⇒ 3" || st_miss "C: re-answer rc=$rc"
mkdialog c2 draft
CH "$W" --fp "$FP" --pick 等发起人; rc=$?
[ "$rc" = 5 ] && [ ! -s "$WORK/keys.c2" ] && st_ok "C: a draft in the input box ⇒ 5, nothing pressed" \
  || st_miss "C: draft rc=$rc keys=$(cat "$WORK/keys.c2" 2>/dev/null) $(cat "$WORK/ch.err")"
mkdialog c3 swallow
CH "$W" --fp "$FP" --pick 等发起人; rc=$?
[ "$rc" = 4 ] && [ "$(grep -c . "$WORK/keys.c3")" = 1 ] && grep -q '按了未确认' "$DEC" \
  && st_ok "C: pressed but never confirmed ⇒ 4, exactly one key, never pressed again (trail says so)" \
  || st_miss "C: unconfirmed rc=$rc keys=$(cat "$WORK/keys.c3" 2>/dev/null | tr '\n' ' ') $(cat "$WORK/ch.err")"
tf set-window-option -t "$W" @claude_needs perm
CH "$W" --fp "$FP" --pick 等发起人; rc=$?
[ "$rc" = 3 ] && st_ok "C: a window not waiting on a choice dialog (needs/perm) ⇒ 3" || st_miss "C: perm window rc=$rc"

# ===================== G — the guard ==========================================
mkdir -p "$WORK/gconf/fleets/fleet-x"; : > "$WORK/gconf/fleets/fleet-x/conf"
guard() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" \
  | env -u TMUX -u TMUX_PANE FLEET_CONF_DIR="$WORK/gconf" python3 "$BIN/../hooks/bash-guard.py" >/dev/null 2>&1; }
guard 'tmux -L fleet-x send-keys -t @85 2'; g1=$?
guard "$BIN/fleet-dialog-answer.sh @85 --fp $FP --pick 等发起人"; g2=$?
[ "$g1" = 2 ] && [ "$g2" = 0 ] && st_ok "G: a raw send-keys into a fleet is still refused; the channel's script runs" \
  || st_miss "G: send-keys rc=$g1, channel rc=$g2"

st_done
