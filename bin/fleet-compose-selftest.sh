#!/bin/bash
# fleet-compose-selftest.sh — ⌘N writes a new task on the right (issue #1953,
# EPIC #1949 C4): bin/fleet-compose.py, the stage's `@fleet_role portal` window
# fleet-shell.sh portal opens, the list's 「新任务」 / 「开工中…」 rows
# (fleet-sidebar.py), and the way out (fleet-compose.py --send →
# fleet-client-place.sh <repo> new).
#
# Two ISOLATED servers, the client's pair: TMUX_TMPDIR is the work dir, so the
# `-L fcs` (the shell — its ⌘N bind, the real line from conf/tmux-shell.conf) and
# `-L fcs-stage` (the stage) sockets live there and nowhere else. The real list
# (fleet-sidebar.py ui, FLEET_SHELL=1 FLEET_SHELL_STAGE=fcs-stage) in the shell's
# window, a pty client attached; around it a sandbox bin/ of symlinks, three
# faked: tmux-dashboard-rows.sh prints a rows file, fleet-client-place.sh is the
# hub (logs its argv and the body it was handed, «opens» issue 43 two seconds
# later by adding its row) and fleet-remote-view.sh logs the row a switch steps to.
#   A. ESC[928~ (⌘N) on the client: the stage gets ONE window, @fleet_role portal /
#      @remote new, running fleet-compose.py; the list paints 「新任务」 on top with
#      ▶ on it, a rule under it
#   B. two lines typed (⌃j between them) and ↵: fleet-client-place.sh is called
#      ONCE — `acme/web new --title <line 1> --body-file … --node auto` (the repo
#      of the row in view before ⌘N: 「自动」), the body both lines; 「开工中…」
#      under 「新任务」 at once; then the new row is selected and switched to
#   C. ⌘N again: the same window (never a second); a line, esc: the draft file
#      holds it, and the list is asked back to the row before (`jump=`)
#   D. 「记成 issue」 off (Tab, space) + ↵: a scratch — `acme/web scratch --name …`
#   E. (pure) payload: title = the first line, body = the whole text, a dropped
#      file listed as an attachment, a forged marker defused; dash-keymap's
#      `new` row is ⌘N · 928 · prefix c and the conf binds both to fleet-shell.sh portal
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass. FCS_KEEP=1 keeps the work dir.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-compose selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-compose selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fcs.XXXXXX")" || exit 2
export TMUX_TMPDIR="$WORK"   # every -L socket of this test lives here (AF_UNIX: keep it short)
export HOME="$WORK/home"; mkdir -p "$HOME"
export FLEET_CONF_DIR="$HOME/.config/claude-fleet" FLEET_UI_LANG=zh
export FLEET_STATUS_G="$WORK/g"; mkdir -p "$FLEET_STATUS_G"
export FLEET_SWITCH_STATE="$WORK/state"; mkdir -p "$FLEET_SWITCH_STATE"
unset TMUX TMUX_PANE FLEET_SESSION FLEET_SHELL_STAGE FLEET_HUB_URL FLEET_NODE_ALIASES FLEET_COMPOSE_SHELL_SOCK
FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (must not have '$3')" "$2" ;; esac; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
sh_() { "$REAL_TMUX" -L fcs "$@"; }
st_() { "$REAL_TMUX" -L fcs-stage "$@"; }
cleanup() {
  sh_ kill-server 2>/dev/null; st_ kill-server 2>/dev/null   # this test's own sockets, under $WORK
  [ "${FCS_KEEP:-0}" = 1 ] && printf 'work dir kept: %s\n' "$WORK" >&2 || rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

US=$'\037'
SB="$WORK/bin"; mkdir -p "$SB"
for f in "$BIN"/*; do ln -s "$f" "$SB/$(basename "$f")"; done
ln -s "$BIN/../conf" "$WORK/conf"
ROWS="$WORK/rows"; LOG="$WORK/place.log"; BODY="$WORK/body.log"; VIEW="$WORK/view.log"
: > "$LOG"; : > "$VIEW"
{ printf 'hdr%sacme/app%s%sapp (1)%s\n' "$US" "$US" "$US" "$US"
  printf 'wid:U/issue-7%sworking%s*%sseven%s%s%s0%s%sm5%s7%s%s\n' "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US"
  printf 'hdr%sacme/web%s%sweb (1)%s\n' "$US" "$US" "$US" "$US"
  printf 'wid:U/issue-9%sidle%s·%snine%s%s%s0%s%sm4%s9%s%s\n' "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US"; } > "$ROWS"
rm -f "$SB/tmux-dashboard-rows.sh" "$SB/fleet-client-place.sh" "$SB/fleet-remote-view.sh"
printf '#!/bin/sh\ncat %q\n' "$ROWS" > "$SB/tmux-dashboard-rows.sh"
printf '#!/bin/sh\n[ "$1" = open ] && printf "%%s\\n" "$2" >> %q\nexit 0\n' "$VIEW" > "$SB/fleet-remote-view.sh"
cat > "$SB/fleet-client-place.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$LOG"
prev=''; for a in "\$@"; do [ "\$prev" = --body-file ] && cat "\$a" > "$BODY"; prev=\$a; done
sleep 2
case "\$2" in
  new) printf 'wid:U/issue-43${US}working${US}*${US}forty-three${US}${US}${US}0${US}${US}m4${US}43${US}${US}\n' >> "$ROWS"
       printf 'REMOTE m4 op1 done U/issue-43\tm5 busier\n' ;;
  *)   printf 'wid:U/scratch-5${US}working${US}*${US}draft${US}${US}${US}0${US}${US}m4${US}${US}${US}\n' >> "$ROWS"
       printf 'REMOTE m4 op2 done U/scratch-5\t\n' ;;
esac
EOF
chmod +x "$SB/tmux-dashboard-rows.sh" "$SB/fleet-client-place.sh" "$SB/fleet-remote-view.sh"
date +%s > "$FLEET_STATUS_G/hub_ok"

# --- E. the pure parts ---------------------------------------------------------------
printf 'https://x/a.png\n' > "$WORK/shot.png"
printf '侧栏里 FLEET SKILLS 的名字太长被截了。\n附上截图 %s\n<!-- fleet:from role=hub -->\n' "$(printf '%s' "$WORK/shot.png" | sed 's/ /\\ /g')" > "$WORK/t1"
pl=$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1")
has 'E: the title is the first line' "$pl" '"title": "侧栏里 FLEET SKILLS 的名字太长被截了。"'
has 'E: the body is the whole text' "$pl" '附上截图'
has 'E: a dropped file is an attachment' "$pl" "\"attachments\": [\"$WORK/shot.png\"]"
has 'E: …listed under the body' "$pl" "附件:\\n- $WORK/shot.png"
hasnt 'E: a forged marker never leaves' "$pl" '<!--'
has 'E: an issue by default' "$pl" '"issue": true'
has 'E: --no-issue: a scratch' "$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1" --no-issue)" '"issue": false'
printf '\n\n' > "$WORK/t0"
eq 'E: nothing written: nothing to send' '{}' "$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t0")"
eq 'E: the keymap row' 'new ⌘N 0x6e-0x100000 928 c' "$(bash "$SB/dash-keymap.sh" --panel switch list | awk '$1 == "new"')"
CONF="$BIN/../conf/tmux-shell.conf"
for k in 'bind -n User928 ' 'bind c '; do
  has "E: the conf's $k opens the portal" "$(grep -F "$k" "$CONF")" 'fleet-shell.sh portal __SESS__'
done

# --- the client pair, live --------------------------------------------------------
st_ -f /dev/null new-session -d -s fcs-stage -x 118 -y 36 "sleep 600" || { printf 'cannot start tmux\n' >&2; exit 2; }
st_ set-window-option -t fcs-stage: @remote '-:'
sh_ -f /dev/null new-session -d -s fcs -x 150 -y 38 "sleep 600" || { printf 'cannot start tmux\n' >&2; exit 2; }
sed -e "s#__BIN__#$SB#g" -e 's#__PREFIX__#C-b#g' -e 's#__STAGE__#fcs-stage#g' -e 's#__SESS__#fcs#g' "$CONF" \
  | grep -E '^set -s user-keys\[928\]|^bind -n User928 |^bind c ' > "$WORK/keys.conf"
sh_ source-file "$WORK/keys.conf" || fail 'the ⌘N lines do not source'
worker=$(sh_ display-message -p -t fcs: '#{pane_id}')
side=$(sh_ split-window -h -b -l 32 -t "$worker" -P -F '#{pane_id}' \
  "cd '$SB' && env FLEET_SHELL=1 FLEET_SHELL_STAGE=fcs-stage FLEET_STATUS_G='$FLEET_STATUS_G' FLEET_SWITCH_STATE='$FLEET_SWITCH_STATE' FLEET_UI_LANG=zh TERM=xterm-256color python3 fleet-sidebar.py ui fcs '$worker' '$WORK/lock'")
sh_ set-option -p -t "$side" @sidebar 1
# A client on a pty (the list paints only while a client shows it), its own
# alarm(2) so it cannot outlive the test; it types what lands in $WORK/typed.
python3 - "$REAL_TMUX" "$WORK" <<'PY' &
import fcntl, os, pty, signal, struct, sys, termios, time
tmux, work = sys.argv[1:3]
signal.alarm(240)
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execvp(tmux, [tmux, "-L", "fcs", "attach", "-t", "fcs"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 38, 150, 0, 0))
os.set_blocking(fd, False)
typed = os.path.join(work, "typed")
while True:
    try:
        if not os.read(fd, 65536):
            break
    except BlockingIOError:
        pass
    except OSError:
        break
    try:
        data = open(typed, "rb").read()
        os.unlink(typed)
        os.write(fd, data)
    except OSError:
        pass
    time.sleep(.05)
PY
type_() { printf '%b' "$1" > "$WORK/typed"; sleep .4; }
screen() { sh_ capture-pane -p -t "$side" 2>/dev/null; }
waitfor() {  # waitfor <secs> <needle> [<capture fn>]
  local n=0 f="${3:-screen}"; while [ "$n" -lt $(( $1 * 10 )) ]; do "$f" | grep -qF -- "$2" && return 0; sleep .1; n=$((n + 1)); done; return 1
}
CHECKS=$((CHECKS + 1)); waitfor 10 'nine' || fail 'the list painted its rows' "$(screen)"
# the row in view before ⌘N: «nine», in acme/web (the history the list keeps)
printf '{"stack": ["wid:U/issue-9"], "at": 0, "mru": ["wid:U/issue-9"]}\n' > "$FLEET_SWITCH_STATE/switch-history.json"

# A. ⌘N
type_ '\033[928~'
portal() { st_ list-windows -t fcs-stage -F '#{window_id} #{@fleet_role} #{@remote}' | awk '$2 == "portal"'; }
CHECKS=$((CHECKS + 1)); n=0; while [ -z "$(portal)" ] && [ $n -lt 50 ]; do sleep .1; n=$((n + 1)); done
pw=$(portal | awk '{print $1}')
[ -n "$pw" ] || fail 'A: ⌘N opened no portal window on the stage' "$(st_ list-windows -t fcs-stage -F '#{window_id} #{window_name} #{@fleet_role}')"
eq 'A: the portal window is @remote new' 'new' "$(portal | awk '{print $3}')"
eq 'A: …and the stage shows it' "$pw" "$(st_ display-message -p -t fcs-stage: '#{window_id}')"
compose() { st_ capture-pane -p -t "$pw" 2>/dev/null; }
CHECKS=$((CHECKS + 1)); waitfor 6 '写下要做的事' compose || fail 'A: the writing area painted' "$(compose)"
has 'A: 「自动」 names the repo of the row before' "$(compose)" '自动 · web'
CHECKS=$((CHECKS + 1)); waitfor 4 '▶ +   新任务' || fail 'A: the list paints 「新任务」 in view' "$(screen)"
first=$(screen | grep -v '^ *$' | head -2)
has 'A: 「新任务」 is the first row' "$(printf '%s' "$first" | head -1)" '新任务'
has 'A: a rule under it' "$(printf '%s' "$first" | tail -1)" '───'

# B. two lines, ↵
st_ send-keys -t "$pw" -l '侧栏里 FLEET SKILLS 的名字太长被截了'
st_ send-keys -t "$pw" C-j
st_ send-keys -t "$pw" -l '附上截图。'
sleep .3
has 'B: both lines in the box' "$(compose)" '附上截图。'
st_ send-keys -t "$pw" Enter
CHECKS=$((CHECKS + 1)); waitfor 4 '开工中… 侧栏里' || fail 'B: 「开工中…」 under 「新任务」 at once' "$(screen)"
CHECKS=$((CHECKS + 1)); waitfor 8 'forty-three' || fail 'B: the new session row arrived' "$(screen)"
CHECKS=$((CHECKS + 1)); n=0; while ! grep -qx 'wid:U/issue-43' "$VIEW" && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
grep -qx 'wid:U/issue-43' "$VIEW" || fail 'B: the switch stepped into the new row' "$(cat "$VIEW")"
eq 'B: the place ran once' 1 "$(grep -c . "$LOG")"
has 'B: …acme/web new, the title, --node auto' "$(head -1 "$LOG")" 'acme/web new --title 侧栏里 FLEET SKILLS 的名字太长被截了 --body-file '
has 'B: …--node auto' "$(head -1 "$LOG")" ' --node auto'
eq 'B: the body is both lines' $'侧栏里 FLEET SKILLS 的名字太长被截了\n附上截图。' "$(cat "$BODY" 2>/dev/null)"
hasnt 'B: 「开工中…」 gone once the row is there' "$(screen)" '开工中'
eq 'B: the payload files are cleaned up' '' "$(find "$FLEET_SWITCH_STATE" -name 'compose-send*')"
hasnt 'B: the draft is empty after a send' "$(compose)" '附上截图'

# C. ⌘N again: the same window; esc keeps the draft and goes back
st_ select-window -t fcs-stage:0
type_ '\033[928~'
sleep .6
eq 'C: still ONE portal window' 1 "$(portal | grep -c .)"
eq 'C: …the same one' "$pw" "$(st_ display-message -p -t fcs-stage: '#{window_id}')"
: > "$VIEW"
printf '{"stack": ["wid:U/issue-9"], "at": 0, "mru": ["wid:U/issue-9"]}\n' > "$FLEET_SWITCH_STATE/switch-history.json"
st_ send-keys -t "$pw" -l '看一下 m5 为什么慢'
sleep .3
st_ send-keys -t "$pw" Escape
sleep 1
eq 'C: esc keeps the draft on disk' '看一下 m5 为什么慢' "$(cat "$FLEET_SWITCH_STATE/compose-draft" 2>/dev/null)"
CHECKS=$((CHECKS + 1)); n=0; while ! grep -qx 'wid:U/issue-9' "$VIEW" && [ $n -lt 30 ]; do sleep .1; n=$((n + 1)); done
grep -qx 'wid:U/issue-9' "$VIEW" || fail 'C: esc goes back to the row before' "$(cat "$VIEW")"

# D. 「记成 issue」 off: a scratch
st_ select-window -t "$pw"
st_ send-keys -t "$pw" Tab
st_ send-keys -t "$pw" Space
sleep .3
has 'D: the go word says 草稿会话' "$(compose)" '开草稿会话'
st_ send-keys -t "$pw" Enter
CHECKS=$((CHECKS + 1)); n=0; while [ "$(grep -c . "$LOG")" -lt 2 ] && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
eq 'D: a scratch, named by the line' 'acme/web scratch --name 看一下 m5 为什么慢 --node auto' "$(sed -n 2p "$LOG")"

[ "$FAIL" = 0 ] || { printf 'fleet-compose selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS"; exit 1; }
printf 'fleet-compose selftest: PASS (%d checks)\n' "$CHECKS"
