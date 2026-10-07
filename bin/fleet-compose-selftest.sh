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
#   D. 「记成 issue」 off (Tab Tab, space) + ↵: a scratch — `acme/web scratch --name …`
#   E. (pure) payload: title = the first line, body = the whole text, a dropped
#      file listed as an attachment, a forged marker defused; dash-keymap's
#      `new` row is ⌘N · 928 · prefix c and the conf binds both to fleet-shell.sh portal
# The 「仓库」 option (issue #1956), one leg per choice:
#   F. (pure) the payload of each: auto (no repo named — resolved where the rows
#      are), --repo (named), --no-repo (none: no issue), --multi (orchestrate)
#   G. a repo: Tab to 「仓库」, space opens the menu (自动 · each hub repo ·
#      不关联仓库 · 多个仓库), ↓ ↵ picks acme/app: `acme/app new …`
#   H. 不关联仓库: no 「记成 issue」, its why-line; ↵ → `- scratch --name … --body-file`
#      (the text is the seed), and the session's row lands under the list's no repo heading
#   I. 多个仓库: 「编排」 and its why-line; ↵ → a no-repo scratch whose seed asks
#      it to split the work by repo (no orchestrator running: the old road)
# The orchestrator (issue #1957) — orch_fcs in the status dir names one (m4, U/orch);
# the faked fleet-remote-view.sh opens it as a stage window @remote m4:U/orch whose
# program turns bracketed paste on and logs what it is sent:
#   J. free: the area says so (编排空闲), 发法 编排, the go word ↵ 交给编排; a draft
#      and ⇧⇥ → the list's jump (wid:U/orch), the stage on it, the draft PASTED there
#      (bracketed, never sent), the area emptied — nothing placed
#   K. working: 「新任务」 wears the spinner, the area says what it is busy with,
#      发法 开工 — ↵ starts the work itself (acme/web new …)
#   L. waiting on you: 「新任务」 turns red `!`, the area's line says its question;
#      Tab to 发法 + space flips it to 编排; an empty ⇧⇥ just goes there
# A client update (issue #2113):
#   M. a portal window an older client made (@portal_ver) is respawned on ⌘N — same
#      window, new process, draft kept; the same version is left alone; a SIGHUP
#      mid-typing saves the draft first
# The direct key (issue #2146):
#   N. ESC[929~ (⌘E) with no orch_fcs: no jump, one line on the client (这台机器没有
#      编排会话); with one: the list's jump to wid:U/orch, the stage on it, nothing
#      pasted; prefix e is the same body
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
cat > "$WORK/recv.py" <<'PY'
import os, sys, tty
out = sys.argv[1]
tty.setraw(0)
os.write(1, b"\x1b[?2004h")
while True:
    data = os.read(0, 4096)
    if not data:
        break
    with open(out, "ab") as f:
        f.write(data)
PY
cat > "$SB/fleet-remote-view.sh" <<EOF
#!/bin/bash
[ "\$1" = open ] || exit 0
printf '%s\n' "\$2" >> "$VIEW"
# the orchestrator's row (issue #1957): a stage window that reads bracketed paste
if [ "\$2" = wid:U/orch ]; then
  T() { "$REAL_TMUX" -L fcs-stage "\$@"; }
  w=\$(T list-windows -t fcs-stage -F '#{window_id} #{@remote}' | awk '\$2 == "m4:U/orch" { print \$1 }')
  [ -n "\$w" ] || { w=\$(T new-window -d -P -F '#{window_id}' -t fcs-stage: "python3 '$WORK/recv.py' '$WORK/orch-in'"); T set-window-option -t "\$w" @remote m4:U/orch; }
  T select-window -t "\$w"
fi
exit 0
EOF
cat > "$SB/fleet-client-place.sh" <<EOF
#!/bin/bash
# the body first: the test reads it as soon as the argv is logged
prev=''; name=''; for a in "\$@"; do [ "\$prev" = --body-file ] && cat "\$a" > "$BODY"; [ "\$prev" = --name ] && name=\$a; prev=\$a; done
printf '%s\n' "\$*" >> "$LOG"
n=\$(grep -c . "$LOG")
sleep 2
case "\$1 \$2" in
  *' new') k=\$((42 + n)); nm=forty-three; [ "\$k" = 43 ] || nm=new-\$k
       printf 'wid:U/issue-%s${US}working${US}*${US}%s${US}${US}${US}0${US}${US}m4${US}%s${US}${US}\n' "\$k" "\$nm" "\$k" >> "$ROWS"
       printf 'REMOTE m4 op%s done U/issue-%s\tm5 busier\n' "\$n" "\$k" ;;
  '- scratch')
       printf 'hdr${US}none${US}${US}no repo (1)${US} \n' >> "$ROWS"
       printf 'wid:U/norepo-%s${US}working${US}*${US}%s${US}${US}${US}0${US}${US}m4${US}${US}${US}\n' "\$n" "\$name" >> "$ROWS"
       printf 'REMOTE m4 op%s done U/norepo-%s\t\n' "\$n" "\$n" ;;
  *)   printf 'wid:U/scratch-%s${US}working${US}*${US}draft${US}${US}${US}0${US}${US}m4${US}${US}${US}\n' "\$n" >> "$ROWS"
       printf 'REMOTE m4 op%s done U/scratch-%s\t\n' "\$n" "\$n" ;;
esac
EOF
chmod +x "$SB/tmux-dashboard-rows.sh" "$SB/fleet-client-place.sh" "$SB/fleet-remote-view.sh"
date +%s > "$FLEET_STATUS_G/hub_ok"
# the repos the hub says this person's machines host (fleet-hub-sessions.sh's cache)
printf '#ts%s%s\nacme/app\nacme/web\n' "$US" "$(date +%s)" > "$FLEET_STATUS_G/hub_repos"

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
pl=$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1")
has 'F: auto by default' "$pl" '"repo_mode": "auto"'
has 'F: …naming no repo (resolved where the rows are)' "$pl" '"repo": ""'
pl=$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1" --repo acme/app)
has 'F: --repo names it' "$pl" '"repo": "acme/app"'
has 'F: …repo_mode repo' "$pl" '"repo_mode": "repo"'
has 'F: …still an issue' "$pl" '"issue": true'
pl=$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1" --no-repo)
has 'F: --no-repo: none' "$pl" '"repo_mode": "none"'
has 'F: …never an issue' "$pl" '"issue": false'
hasnt 'F: …not orchestrated' "$pl" 'orchestrate'
pl=$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1" --multi)
has 'F: --multi: multi' "$pl" '"repo_mode": "multi"'
has 'F: …orchestrated' "$pl" '"orchestrate": true'
has 'F: …never an issue' "$pl" '"issue": false'
eq 'F: one choice only' 2 "$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1" --no-repo --multi >/dev/null 2>&1; echo $?)"
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
  | grep -E '^set -s user-keys\[92[89]\]|^bind -n User92[89] |^bind [ce] ' > "$WORK/keys.conf"
sh_ source-file "$WORK/keys.conf" || fail 'the ⌘N / ⌘E lines do not source'
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
st_ send-keys -t "$pw" Tab      # 「仓库」 (issue #1956)
st_ send-keys -t "$pw" Tab      # 「记成 issue」
st_ send-keys -t "$pw" Space
sleep .3
has 'D: the go word says 草稿会话' "$(compose)" '开草稿会话'
st_ send-keys -t "$pw" Enter
CHECKS=$((CHECKS + 1)); n=0; while [ "$(grep -c . "$LOG")" -lt 2 ] && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
eq 'D: a scratch, named by the line' 'acme/web scratch --name 看一下 m5 为什么慢 --node auto' "$(sed -n 2p "$LOG")"

# The 「仓库」 option (issue #1956). Each send waits for the one before it to land.
settled() { n=0; while screen | grep -qF '开工中' && [ $n -lt 80 ]; do sleep .1; n=$((n + 1)); done; }
placed_n() { n=0; while [ "$(grep -c . "$LOG")" -lt "$1" ] && [ $n -lt 60 ]; do sleep .1; n=$((n + 1)); done; sed -n "$1p" "$LOG"; }
# G. a repo, picked from the menu
settled
st_ send-keys -t "$pw" Tab
st_ send-keys -t "$pw" Space
sleep .4
menu=$(compose)
for want in '自动' 'web · 你刚才在这' 'app' 'acme' '不关联仓库' '多个仓库' '↑↓ 选'; do has "G: the menu lists $want" "$menu" "$want"; done
st_ send-keys -t "$pw" Down
st_ send-keys -t "$pw" Enter
sleep .3
has 'G: the field names the repo picked' "$(compose)" ' app ▾'
st_ send-keys -t "$pw" -l '修一下 app 的登录页'
sleep .2
st_ send-keys -t "$pw" Enter
line=$(placed_n 3)
has 'G: the picked repo, an issue' "$line" 'acme/app new --title 修一下 app 的登录页 --body-file '
CHECKS=$((CHECKS + 1)); waitfor 3 '自动 · web' compose || fail 'G: back to 自动 after a send' "$(compose)"

# H. 不关联仓库: a session of no repo, its row under the no repo heading
settled
st_ send-keys -t "$pw" Tab
st_ send-keys -t "$pw" Space
sleep .3
st_ send-keys -t "$pw" Down Down Down
st_ send-keys -t "$pw" Enter
sleep .3
c=$(compose)
has 'H: the field says 不关联仓库' "$c" '不关联仓库 ▾'
has 'H: …and why' "$c" '开一个会话，不开 issue，进 no repo 组'
has 'H: …the go word' "$c" '↵ 开会话'
hasnt 'H: no 「记成 issue」 (an issue belongs to a repo)' "$c" '记成 issue'
st_ send-keys -t "$pw" -l '整理一下这周的日报'
sleep .2
st_ send-keys -t "$pw" Enter
line=$(placed_n 4)
has 'H: no repo, a scratch named by the line' "$line" '- scratch --name 整理一下这周的日报 --body-file '
has 'H: …--node auto' "$line" ' --node auto'
eq 'H: the text is its seed' '整理一下这周的日报' "$(cat "$BODY" 2>/dev/null)"
CHECKS=$((CHECKS + 1)); waitfor 8 'no repo (1)' || fail 'H: the session row arrived' "$(screen)"
grp=$(screen | awk '/no repo/ { on = 1 } on && /整理一下/ { print "under"; exit }')
eq 'H: …under the no repo heading' under "$grp"

# I. 多个仓库: 「编排」
settled
st_ send-keys -t "$pw" Tab
st_ send-keys -t "$pw" Space
sleep .3
st_ send-keys -t "$pw" Up
st_ send-keys -t "$pw" Enter
sleep .3
c=$(compose)
has 'I: the field says 多个仓库' "$c" '多个仓库 ▾'
has 'I: …why it is orchestrated' "$c" '跨仓库的事交给编排会话，由它按仓库拆'
has 'I: …the go word is 编排' "$c" '↵ 编排'
hasnt 'I: no 「记成 issue」' "$c" '记成 issue'
st_ send-keys -t "$pw" -l '活页里加一张 fleet 状态卡'
sleep .2
st_ send-keys -t "$pw" Enter
line=$(placed_n 5)
has 'I: a session of no repo' "$line" '- scratch --name 活页里加一张 fleet 状态卡 --body-file '
has 'I: the seed is the text…' "$(cat "$BODY" 2>/dev/null)" '活页里加一张 fleet 状态卡'
has 'I: …and asks it to split by repo' "$(cat "$BODY" 2>/dev/null)" '按仓库各开 issue'

# --- the orchestrator (issue #1957) ------------------------------------------------
orch() { printf 'U/orch%sm4%sonline%s%s%s%s%s%s\n' "$US" "$US" "$US" "$1" "$US" "${2:-}" "$US" "${3:-}" > "$FLEET_STATUS_G/orch_fcs"; }
newtask() { screen | grep -F '新任务' | head -1; }
# J. free: 编排 by default; ⇧⇥ carries the draft over
settled
orch 'done'
st_ select-window -t "$pw"
st_ send-keys -t "$pw" -l '活页里加一张 fleet 状态卡：在跑几个会话'
CHECKS=$((CHECKS + 1)); waitfor 4 '编排空闲' compose || fail 'J: the area says the orchestrator is free' "$(compose)"
c=$(compose)
has 'J: 发法 编排 by default while it is free' "$c" '发法  编排 '
has 'J: …the go word hands it over' "$c" '↵ 交给编排'
has 'J: the keys line names ⇧⇥' "$c" '⇧⇥ 交给编排'
has 'J: 「新任务」 is no busy row' "$(newtask)" '+'
nlog=$(grep -c . "$LOG"); : > "$VIEW"
st_ send-keys -t "$pw" BTab
CHECKS=$((CHECKS + 1)); n=0; while ! grep -qx 'wid:U/orch' "$VIEW" && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
grep -qx 'wid:U/orch' "$VIEW" || fail 'J: ⇧⇥ asked the list to jump to the orchestrator' "$(cat "$VIEW")"
CHECKS=$((CHECKS + 1)); n=0; while ! grep -qF '状态卡' "$WORK/orch-in" 2>/dev/null && [ $n -lt 60 ]; do sleep .1; n=$((n + 1)); done
got=$(cat "$WORK/orch-in" 2>/dev/null)
eq 'J: the draft pasted into it, bracketed, not sent' $'\e[200~活页里加一张 fleet 状态卡：在跑几个会话\e[201~' "$got"
eq 'J: the stage shows the orchestrator' m4:U/orch "$(st_ display-message -p -t fcs-stage: '#{@remote}')"
st_ select-window -t "$pw"
CHECKS=$((CHECKS + 1)); waitfor 4 '已交给编排：活页里加一张' compose || fail 'J: the area says it went over' "$(compose)"
hasnt 'J: …and is empty' "$(compose | sed -n '/╭/,/╰/p')" '状态卡'
eq 'J: nothing placed' "$nlog" "$(grep -c . "$LOG")"

# K. working: 开工 by default, the line says why
orch working '' '跑 #1935 的批'
st_ send-keys -t "$pw" -l '修一下 web 的页脚'
CHECKS=$((CHECKS + 1)); waitfor 4 '编排在忙：跑 #1935 的批' compose || fail 'K: the area says what it is busy with' "$(compose)"
c=$(compose)
has 'K: 发法 开工 while it works' "$c" '发法  开工 '
has 'K: …the go word starts it' "$c" '↵ 开工'
spun() { newtask | grep -q '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'; }
CHECKS=$((CHECKS + 1)); n=0; while ! spun && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
spun || fail 'K: 「新任务」 wears the spinner' "$(newtask)"
st_ send-keys -t "$pw" Enter
line=$(placed_n $((nlog + 1)))
has 'K: ↵ started the work itself' "$line" 'acme/web new --title 修一下 web 的页脚 --body-file '

# L. waiting on you: red 「新任务」, its question; 发法 can be flipped; an empty ⇧⇥ goes there
settled
orch needs ask '开一个 EPIC 还是三个快任务？'
st_ select-window -t "$pw"
st_ send-keys -t "$pw" -l '再看一眼'
CHECKS=$((CHECKS + 1)); waitfor 4 '! 编排在等你回答：开一个 EPIC 还是三个快任务？' compose || fail 'L: the area says its question' "$(compose)"
red() { newtask | grep -q '!'; }
CHECKS=$((CHECKS + 1)); n=0; while ! red && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
red || fail 'L: 「新任务」 turns red !' "$(newtask)"
st_ send-keys -t "$pw" Tab Tab Tab
st_ send-keys -t "$pw" Space
sleep .3
has 'L: Tab to 发法, space: 编排' "$(compose)" '↵ 交给编排'
st_ send-keys -t "$pw" Tab      # back to the text
st_ send-keys -t "$pw" C-u
sleep .2
: > "$VIEW"; : > "$WORK/orch-in"
st_ send-keys -t "$pw" BTab
CHECKS=$((CHECKS + 1)); n=0; while ! grep -qx 'wid:U/orch' "$VIEW" && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
grep -qx 'wid:U/orch' "$VIEW" || fail 'L: an empty ⇧⇥ goes there' "$(cat "$VIEW")"
sleep .5
eq 'L: …pasting nothing' '' "$(cat "$WORK/orch-in")"

# M. a client update under a running writing area (issue #2113): the window made
# by an older client (@portal_ver not this code's) is respawned on ⌘N — same
# window, a new process, the draft kept; the same version keeps its process; a
# hang-up mid-typing (a respawn's SIGHUP) still lands the draft on disk
ppid_() { st_ display-message -p -t "$pw" '#{pane_pid}'; }
pver() { st_ show-window-option -v -t "$pw" @portal_ver 2>/dev/null; }
settled
st_ select-window -t fcs-stage:0
type_ '\033[928~'
sleep .6
v_now=$(pver)
[ -n "$v_now" ] || fail 'M: the portal window carries @portal_ver'
p0=$(ppid_)
st_ select-window -t fcs-stage:0
type_ '\033[928~'
sleep .6
eq 'M: the same version keeps its process' "$p0" "$(ppid_)"
st_ send-keys -t "$pw" -l '升级前写的半句'
st_ set-window-option -t "$pw" @portal_ver old-client
st_ select-window -t fcs-stage:0
type_ '\033[928~'
CHECKS=$((CHECKS + 1)); n=0; while [ "$(ppid_)" = "$p0" ] && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
[ "$(ppid_)" != "$p0" ] || fail 'M: an older version is respawned on ⌘N'
eq 'M: …in the same window' "$pw" "$(portal | awk '{print $1}')"
eq 'M: …still ONE portal window' 1 "$(portal | grep -c .)"
eq 'M: …stamped with this code' "$v_now" "$(pver)"
eq 'M: …still @remote new' 'new' "$(portal | awk '{print $3}')"
eq 'M: the draft survived the respawn' '升级前写的半句' "$(cat "$FLEET_SWITCH_STATE/compose-draft" 2>/dev/null)"
CHECKS=$((CHECKS + 1)); waitfor 6 '升级前写的半句' compose || fail 'M: the new process shows the draft' "$(compose)"
p1=$(ppid_)
st_ send-keys -t "$pw" -l '，再补一句'
sleep .15
st_ respawn-pane -k -t "$pw"
CHECKS=$((CHECKS + 1)); n=0; while [ "$(ppid_)" = "$p1" ] && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
sleep .3
eq 'M: a hang-up mid-typing saves the draft first' '升级前写的半句，再补一句' "$(cat "$FLEET_SWITCH_STATE/compose-draft" 2>/dev/null)"

# N. ⌘E (issue #2146): straight to the orchestrator, no draft; none → one line
settled
rm -f "$FLEET_STATUS_G/orch_fcs"
st_ select-window -t fcs-stage:0
: > "$VIEW"; : > "$WORK/orch-in"
type_ '\033[929~'
sleep 1
eq 'N: no orchestrator → no jump' '' "$(cat "$VIEW")"
CHECKS=$((CHECKS + 1)); n=0; while ! sh_ show-messages 2>/dev/null | grep -qF '这台机器没有编排会话' && [ $n -lt 30 ]; do sleep .1; n=$((n + 1)); done
sh_ show-messages 2>/dev/null | grep -qF '这台机器没有编排会话' || fail 'N: …one line on the client says so' "$(sh_ show-messages 2>&1 | tail -3)"
eq 'N: …the stage stays where it was' 0 "$(st_ display-message -p -t fcs-stage: '#{window_index}')"
orch done
type_ '\033[929~'
CHECKS=$((CHECKS + 1)); n=0; while ! grep -qx 'wid:U/orch' "$VIEW" && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
grep -qx 'wid:U/orch' "$VIEW" || fail 'N: ⌘E asked the list to jump to the orchestrator' "$(cat "$VIEW")"
CHECKS=$((CHECKS + 1)); n=0; while [ "$(st_ display-message -p -t fcs-stage: '#{@remote}')" != m4:U/orch ] && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
eq 'N: the stage shows the orchestrator' m4:U/orch "$(st_ display-message -p -t fcs-stage: '#{@remote}')"
sleep .5
eq 'N: …pasting nothing' '' "$(cat "$WORK/orch-in")"
kb() { sh_ list-keys -T "$1" | awk -v k="$2" '$4 == k { $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); print }'; }
has 'N: ⌘E runs fleet-compose.py --orch' "$(kb root User929)" 'fleet-compose.py --orch fcs'
eq 'N: prefix e runs ⌘E'"'"'s body' "$(kb root User929)" "$(kb prefix e)"

# …and 「新任务」's right-click menu (fleet-sidebar-menu.sh `menu <s> new`): 进编排会话
# first, on the same road; none → greyed, with the reason
pmenu() { FLEET_SHELL=1 bash -c 'BIN=$1; sess=$2; verb=menu; set -- menu "$2" new --print
  . "$BIN/fleet-lib.sh"; . "$BIN/fleet-ui-lang.sh"; . "$BIN/fleet-sidebar-menu.sh"' _ "$BIN" fcs 2>/dev/null; }
m=$(pmenu)
eq 'N: 「新任务」 has a menu, titled with its name' $'title\t新任务' "$(printf '%s\n' "$m" | head -1)"
has 'N: …its first item goes to the orchestrator' "$(printf '%s\n' "$m" | sed -n 2p | cut -f1,2)" $'b\t进编排会话'
has 'N: …by fleet-compose.py --orch' "$(printf '%s\n' "$m" | sed -n 2p | tr -d "'\\\\")" 'fleet-compose.py --orch fcs'
rm -f "$FLEET_STATUS_G/orch_fcs"
has 'N: none → greyed, saying why' "$(pmenu | sed -n 2p | cut -f1,2)" $'b\t-进编排会话 · 这台机器没有编排会话'
[ "$FAIL" = 0 ] || { printf 'fleet-compose selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS"; exit 1; }
printf 'fleet-compose selftest: PASS (%d checks)\n' "$CHECKS"
