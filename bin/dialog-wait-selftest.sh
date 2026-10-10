#!/bin/bash
# dialog-wait-selftest.sh — a session waiting on a choice dialog is SEEN, and can be
# answered through one guarded road (issue #2958).
#
#   S  the state (bin/set-claude-state.sh, bin/classify-sessions.sh, isolated tmux):
#      a looping driver whose /loop wake opens an AskUserQuestion reads needs/ask;
#      a Stop and the mod's turn.complete arriving while the transcript still holds
#      it unanswered leave it needs/ask; the screen classifier leaves it (no model
#      call); answered (tool_result + PostToolUse) and stopped ⇒ looping again
#   W  the steward (bin/fleet_steward.py beat, its seams): a stale heartbeat with
#      the driver's window here and asking ⇒ ONE decision row carrying the question
#      and its options and the window; a fresh heartbeat ⇒ none; asking about a new
#      dialog closes the old row; not asking and stale past one TTL ⇒ a 「没在走」
#      row and the page's 待你动手 line; stale less than a TTL past ⇒ none;
#      `answer --row dialog-…` goes through the channel with the row's fp + label
#   C  the channel (bin/fleet_dialog_answer.py → bin/fleet-answer.sh) against a fake
#      dialog in an isolated tmux: answered + confirmed + the trail (decision log,
#      record-only comment); a fingerprint that differs ⇒ 3, nothing pressed; a label
#      not among the options ⇒ 3; a draft in the input box ⇒ 5, nothing pressed; a
#      press never confirmed ⇒ 4 and exactly ONE key reached the pane
#   G  hooks/bash-guard.py still refuses a raw `tmux send-keys` into a fleet and
#      lets the channel's script run
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=''
while IFS= read -r t; do case "$t" in */tmux-shim/*) ;; *) REAL_TMUX=$t; break ;; esac; done < <(type -ap tmux)
[ -n "$REAL_TMUX" ] || { echo "dialog-wait: tmux absent — SKIP"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "dialog-wait: python3 absent — SKIP"; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dlgw.XXXXXX") || exit 2
SOCK="$WORK/t.sock"
tf() { "$REAL_TMUX" -S "$SOCK" "$@"; }
cleanup() { tf kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$WORK/path" "$WORK/home/.claude/projects/p" "$WORK/conf/fleets/st/repos" "$WORK/gh"
export FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh FLEET_DECISION_TZ=UTC FLEET_SKIP_GLOBAL_CONF=1
printf 'FLEET_REPO="o/r"\n' > "$FLEET_CONF_DIR/fleets/st/repos/o-r.conf"
# every bare `tmux` (the hooks, fleet-lib, fleet-answer) reaches the isolated server
cat > "$WORK/path/tmux" <<EOF
#!/bin/sh
case "\${1:-}" in -L|-S) shift 2 ;; esac
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
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
hook done "$STOP"
[ "$(st)" = looping/ ] && ok "S: a driver with a Loop pending stops as looping" || bad "S: before the wake: $(st)"
# the wake's turn opens the dialog
ask toolu_A '谁来部署入口？' '我来部署 (Recommended)' '等发起人'
hook busy '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"谁来部署入口？","options":[{"label":"我来部署 (Recommended)"},{"label":"等发起人"}]}]}}'
[ "$(st)" = needs/ask ] && ok "S: the dialog opened inside the /loop wake reads needs/ask" || bad "S: wake dialog: $(st)"
hook done "$STOP"
[ "$(st)" = needs/ask ] && ok "S: a Stop with the dialog still open leaves needs/ask (not looping)" || bad "S: Stop over the open dialog: $(st)"
hook done '' '--via mod'
[ "$(st)" = needs/ask ] && ok "S: the mod's turn.complete (no payload: @cc_session_id's transcript) leaves needs/ask" \
  || bad "S: mod done over the open dialog: $(st)"
rm -f "$WORK/claude.calls"
env FLEET_MOD=0 CLASSIFY_SETTLE=0 bash "$BIN/classify-sessions.sh" --window "$PANE" >/dev/null 2>&1
[ "$(st)" = needs/ask ] && [ ! -f "$WORK/claude.calls" ] \
  && ok "S: the screen classifier leaves an open dialog alone (no model call)" \
  || bad "S: classifier: $(st), calls=$(cat "$WORK/claude.calls" 2>/dev/null | wc -l)"
answered toolu_A '我来部署 (Recommended)'
hook working '{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}'
[ "$(st)" = working/ ] || bad "S: after the answer: $(st)"
hook done "$STOP"
[ "$(st)" = looping/ ] && ok "S: answered, the turn ends ⇒ looping again" || bad "S: after the answer's Stop: $(st)"

# ===================== W — the steward ========================================
mkdir -p "$WORK/bin"
printf '#!/bin/sh\ncat "$ST_WINS" 2>/dev/null\n' > "$WORK/bin/wins"
printf '#!/bin/sh\nprintf "{\\"seq\\": 0, \\"children\\": []}\\n"\n' > "$WORK/bin/children"
printf '#!/bin/sh\n{ printf ">>> %%s\\n" "$1"; cat; printf "\\n"; } >> "$ST_GH/sends.log"\n' > "$WORK/bin/send"
printf '#!/bin/sh\n:\n' > "$WORK/bin/stamp"
printf '#!/bin/sh\nprintf "{\\"comments\\":[]}\\n"\n' > "$WORK/bin/gh-comments"
cat > "$WORK/bin/gh-post" <<'EOF'
#!/bin/sh
{ printf '>>> %s#%s %s\n' "$1" "$2" "$3"; cat; printf '\n'; } >> "$ST_GH/posts.log"
echo "https://github.com/$1/issues/$2#issuecomment-1"
EOF
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$ST_GH/channel.log"\n' > "$WORK/bin/channel"
printf '#!/bin/sh\nprintf "{\\"rows\\": []}\\n"\n' > "$WORK/bin/doctor"
printf '#!/bin/sh\n:\n' > "$WORK/bin/idle"
chmod +x "$WORK/bin/"*
export ST_GH="$WORK/gh" ST_WINS="$WORK/wins.txt" \
  FLEET_DECISION_COMMENTS_CMD="$WORK/bin/gh-comments" FLEET_DECISION_POST_CMD="$WORK/bin/gh-post" \
  FLEET_STEWARD_WINDOWS_CMD="$WORK/bin/wins" FLEET_STEWARD_CHILDREN_CMD="$WORK/bin/children" \
  FLEET_STEWARD_SEND_CMD="$WORK/bin/send" FLEET_STEWARD_STAMP_CMD="$WORK/bin/stamp" FLEET_STEWARD=1 \
  FLEET_STEWARD_PAGE_SHARE=0 FLEET_STEWARD_DOCTOR_CMD="$WORK/bin/doctor" FLEET_STEWARD_IDLE_CMD="$WORK/bin/idle" \
  FLEET_STEWARD_SLEEP_LOG="$WORK/sleep.log" FLEET_STEWARD_CLEANUP_LOG="$WORK/cleanup.log" FLEET_SLEEP=observe \
  FLEET_STEWARD_PARK=0 FLEET_STEWARD_DEBUG=0 FLEET_DIALOG_PROJECTS="$WORK/home/.claude/projects" \
  FLEET_STEWARD_DIALOG_CMD="$WORK/bin/channel"
STATE="$FLEET_CONF_DIR/global/steward.state.json"
mkdir -p "$FLEET_CONF_DIR/global/epic-running.d"
mark() {  # mark <epoch> — the batch's heartbeat (fleet-epic-heartbeat.sh's shape)
  printf 'epoch: %s\niso: x\nttl: 2700\nepic: 2482\nrepo: o/r\n' "$1" > "$FLEET_CONF_DIR/global/epic-running.d/o-r-2482"
}
drv() {   # drv <state> <needs> — the driver's window row (the windows seam)
  printf '@85\tworker\t%s\t\to/r\to/r#2482\tscratch-4\t\t%s\t%s\t批次·单会话像本地\n' "$1" "$2" "$SID" > "$ST_WINS"
}
TICK() { python3 "$BIN/fleet_steward.py" "$@" --session st; }
rows() {  # rows <prefix> — the open rows of that kind, `id<TAB>item`
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k, r in d["rows"].items():
    if k.startswith(sys.argv[2]) and r["state"] == "open": print(k + "\t" + r["item"])' "$STATE" "$1" 2>/dev/null
}
now=$(date +%s)
ask toolu_B '入口谁来部署？我这边已经准备好镜像' '我来部署 (Recommended)' '等发起人' '先不部署'
drv needs ask
mark "$now"
TICK beat --force >/dev/null 2>&1
[ -z "$(rows dialog-)" ] && ok "W: a fresh heartbeat with the driver asking puts no row up" || bad "W: fresh heartbeat: $(rows dialog-)"
mark $(( now - 3000 ))
TICK beat --force >/dev/null 2>&1
r=$(rows dialog-)
case "$r" in
  *'#2482'*'入口谁来部署？我这边已经准备好镜像'*'我来部署 (Recommended)、等发起人、先不部署'*'批次·单会话像本地'*)
    [ "$(printf '%s\n' "$r" | grep -c .)" = 1 ] && ok "W: stale heartbeat + the driver asking ⇒ ONE row: batch, question, options, window" \
      || bad "W: rows: $r" ;;
  *) bad "W: no dialog row with the question: [$r]" ;;
esac
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(a["id"] for a in d["new_asks"]))' \
  "$FLEET_CONF_DIR/global/steward.delta.json" | grep -q 'dialog-' \
  && ok "W: the row is a new ask in the delta (the steward is woken)" || bad "W: not in the delta's new_asks"
rid=$(rows dialog- | cut -f1)
TICK answer --row "$rid" --text '等发起人' --by person >/dev/null 2>&1
grep -q -- "@85 --fp ${rid#dialog-} --by person" "$ST_GH/channel.log" 2>/dev/null && grep -q -- '--pick 等发起人' "$ST_GH/channel.log" \
  && grep -q -- '--issue o/r#2482' "$ST_GH/channel.log" && [ -z "$(rows dialog-)" ] \
  && ok "W: answer --row dialog-… presses the label in through the channel (fp, window, trail issue) and closes it" \
  || bad "W: answer: $(cat "$ST_GH/channel.log" 2>/dev/null) open=[$(rows dialog-)]"
answered toolu_B '等发起人'
ask toolu_C '换个问题？' '是' '否'
TICK beat --force >/dev/null 2>&1
r=$(rows dialog-)
case "$r" in *'换个问题？'*) [ "$(printf '%s\n' "$r" | grep -c .)" = 1 ] && ok "W: a new dialog is a new row" || bad "W: rows: $r" ;;
  *) bad "W: new dialog: [$r]" ;; esac
answered toolu_C '是'
drv looping ''
mark $(( now - 3000 ))
TICK beat --force >/dev/null 2>&1
[ -z "$(rows dialog-)" ] && [ -z "$(rows stalled-)" ] \
  && ok "W: answered, stale less than a TTL past ⇒ the dialog row closes, no 「没在走」 row" \
  || bad "W: after the answer: dialog=[$(rows dialog-)] stalled=[$(rows stalled-)]"
mark $(( now - 6000 ))
TICK beat --force >/dev/null 2>&1
PAGE="$FLEET_CONF_DIR/fleets/st/steward/page.html"
r=$(rows stalled-)
case "$r" in *'没在走'*'批次·单会话像本地'*)
  grep -q '没在走' "$PAGE" 2>/dev/null && ok "W: not asking, stale past a TTL ⇒ a 「没在走」 row and the page's line" \
    || bad "W: no 没在走 on the page ($PAGE)" ;;
  *) bad "W: no stalled row: [$r]" ;; esac
mark "$now"
TICK beat --force >/dev/null 2>&1
[ -z "$(rows stalled-)" ] && ok "W: the heartbeat back ⇒ the 「没在走」 row closes" || bad "W: stalled still open: $(rows stalled-)"

# ===================== C — the channel ========================================
unset FLEET_STEWARD_DIALOG_CMD
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
[ "$rc" = 3 ] && [ ! -s "$WORK/keys.c1" ] && ok "C: a fingerprint that differs ⇒ 3, nothing pressed" \
  || bad "C: wrong fp rc=$rc keys=$(cat "$WORK/keys.c1" 2>/dev/null) $(cat "$WORK/ch.err")"
CH "$W" --fp "$FP" --pick 'Type something'; rc=$?
[ "$rc" = 3 ] && [ ! -s "$WORK/keys.c1" ] && ok "C: a label not among the options (free text) ⇒ 3, nothing pressed" \
  || bad "C: free text rc=$rc $(cat "$WORK/ch.err")"
CH "$W" --fp "$FP" --pick 等发起人 --by steward --basis '章程第 3 条'; rc=$?
DEC="$FLEET_CONF_DIR/fleets/st/steward/decision-$(date +%F).md"
[ "$rc" = 0 ] && grep -q '等发起人' "$CTP" && [ "$(grep -c . "$WORK/keys.c1")" = 1 ] \
  && grep -q '管家按章程代答（章程第 3 条）.*选「等发起人」' "$DEC" 2>/dev/null \
  && grep -q '^>>> o/r#2482 note' "$ST_GH/posts.log" && grep -q 'fleet:dialog-answer by=steward' "$ST_GH/posts.log" \
  && ok "C: answered + confirmed in the transcript, one key; the trail in decision-<day>.md and on the batch issue" \
  || bad "C: answer rc=$rc keys=$(cat "$WORK/keys.c1" 2>/dev/null | tr '\n' ' ') err=$(cat "$WORK/ch.err") dec=$(cat "$DEC" 2>/dev/null)"
CH "$W" --fp "$FP" --pick 等发起人; rc=$?
[ "$rc" = 3 ] && ok "C: the same dialog again (already answered) ⇒ 3" || bad "C: re-answer rc=$rc"
mkdialog c2 draft
CH "$W" --fp "$FP" --pick 等发起人; rc=$?
[ "$rc" = 5 ] && [ ! -s "$WORK/keys.c2" ] && ok "C: a draft in the input box ⇒ 5, nothing pressed" \
  || bad "C: draft rc=$rc keys=$(cat "$WORK/keys.c2" 2>/dev/null) $(cat "$WORK/ch.err")"
mkdialog c3 swallow
CH "$W" --fp "$FP" --pick 等发起人; rc=$?
[ "$rc" = 4 ] && [ "$(grep -c . "$WORK/keys.c3")" = 1 ] && grep -q '按了未确认' "$DEC" \
  && ok "C: pressed but never confirmed ⇒ 4, exactly one key, never pressed again (trail says so)" \
  || bad "C: unconfirmed rc=$rc keys=$(cat "$WORK/keys.c3" 2>/dev/null | tr '\n' ' ') $(cat "$WORK/ch.err")"
tf set-window-option -t "$W" @claude_needs perm
CH "$W" --fp "$FP" --pick 等发起人; rc=$?
[ "$rc" = 3 ] && ok "C: a window not waiting on a choice dialog (needs/perm) ⇒ 3" || bad "C: perm window rc=$rc"

# ===================== G — the guard ==========================================
mkdir -p "$WORK/gconf/fleets/fleet-x"; : > "$WORK/gconf/fleets/fleet-x/conf"
guard() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" \
  | env -u TMUX -u TMUX_PANE FLEET_CONF_DIR="$WORK/gconf" python3 "$BIN/../hooks/bash-guard.py" >/dev/null 2>&1; }
guard 'tmux -L fleet-x send-keys -t @85 2'; g1=$?
guard "$BIN/fleet-dialog-answer.sh @85 --fp $FP --pick 等发起人"; g2=$?
[ "$g1" = 2 ] && [ "$g2" = 0 ] && ok "G: a raw send-keys into a fleet is still refused; the channel's script runs" \
  || bad "G: send-keys rc=$g1, channel rc=$g2"

[ "$fails" = 0 ] && { echo "dialog-wait: all passed"; exit 0; }
echo "dialog-wait: $fails failed"; exit 1
