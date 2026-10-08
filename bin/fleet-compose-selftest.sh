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
#   D. (issue #2231) none of 记成 issue / 发法 / 多个仓库 / 编排 on the area; the
#      three options at their defaults — 仓库 the row in view (web), 节点 the
#      fewest running (m4, 推荐), Agent FLEET_AGENT (codex, 默认), the greyed
#      维护中 machine never picked; 节点 m5 + Agent claude by hand: `acme/web new …
#      --node m5host --agent claude`; after the send all three are back to default
#   E. (pure) payload: title = the first line, body = the whole text, a dropped
#      file listed as an attachment, a forged marker defused; dash-keymap's
#      `new` row is ⌘N · 928 · prefix c and the conf binds both to fleet-shell.sh portal
#   F. (pure) the payload's fields {title, body, attachments, repo, node, agent}:
#      repo named, --no-repo → null with the WHOLE text; node / agent null unless named
# The 「仓库」 option:
#   G. Tab to 「仓库」, space opens the menu (each hub repo, the one in view
#      marked 你刚才在这, 无仓库 · HOME — no 自动 / 不关联仓库 / 多个仓库), ↑ ↵ picks
#      acme/app: `acme/app new …`; back to web after the send
#   H. 无仓库 · HOME: ↵ → `- scratch --name … --body-file`, the body BOTH lines
#      (nothing dropped), its row under the list's no repo heading
#   I. a hand-picked option, then ⌘N from elsewhere: the defaults again (the last
#      send's repo, acme/app, when the row in view names none)
# The orchestrator (issue #1957) is no longer reached from the area — orch_fcs in
# the status dir names one (m4, U/orch); the faked fleet-remote-view.sh opens it as
# a stage window @remote m4:U/orch whose program logs what it is sent:
#   J. free: the area says nothing of it; ↵ starts the work (acme/web new …); ⇧⇥
#      carries nothing anywhere
#   K. working: 「新任务」 wears the spinner
#   L. waiting on you: 「新任务」 turns red `!`
# A client update (issue #2113):
#   M. a portal window an older client made (@portal_ver) is respawned on ⌘N — same
#      window, new process, draft kept; the same version is left alone; a SIGHUP
#      mid-typing saves the draft first
# How it is used (issue #1955, EPIC #1949 R2) — logs/compose.ndjson:
#   N. B's send wrote `sent` (how issue, the repo) · `placed` (rc 0, REMOTE, m4,
#      the worker_id) · `started` (the list found its row: session, fid, secs), one id;
#      H's is how norepo
#   O. (pure) fleet-history.sh drafts: a scratch book generation that holds a
#      child's report is a draft of its day — unless its pfid is a session the
#      writing area opened; a relayed row is no child; sends / started / the median
# The machine and the agent (issue #2232, EPIC #2230 C2):
#   Q. (pure) --send hands the payload's `node` / `agent` on as --node / --agent
#      (null = --node auto and no --agent — an older payload's argv, byte for byte);
#      a named --node / --agent beats the payload's; an agent other than claude /
#      codex is refused (2) before anything is placed
# The direct key (issue #2146):
#   P. ⌘N ON the writing area with an orchestrator: the list's jump to wid:U/orch,
#      the stage on it, nothing pasted; ⌘N again: back to the writing area. No
#      orch_fcs: ⌘N on the writing area changes nothing. 「新任务」's right-click
#      menu: 进编排会话 on the same road (greyed, saying why, with none)
# The switch (issue #2236, EPIC #2230 C6):
#   R. the hub answers done naming the worker_id while the list does not carry
#      its row yet: the stage is on it within 0.5 s of the answer (`switched`
#      t_switch in compose.ndjson, against the fake's reply), opened with --node
#      <m> --name <title>; 「开工中…」 stands in; once the row shows it replaces
#      the stand-in, one row, no second switch. An older hub (no worker_id): no
#      switch until the row shows, as before
# Nothing written is lost (issue #2240, EPIC #2482 C2):
#   S. the hub answers 503: the box keeps both lines, the line under the options
#      says 「没发出去：入口连不上… · 字还在，改好再 ↵」 until the next key, the
#      draft and compose-failed.json hold the text, nothing switched; the direct
#      road's reason is the place's message (place_why)
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
export FLEET_COMPOSE_LOG="$WORK/logs/compose.ndjson"   # issue #1955
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
printf '%s\n' "\$*" >> "$VIEW.args"
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
prev=''; name=''; title=''; for a in "\$@"; do [ "\$prev" = --body-file ] && cat "\$a" > "$BODY"; [ "\$prev" = --name ] && name=\$a; [ "\$prev" = --title ] && title=\$a; prev=\$a; done
printf '%s\n' "\$*" >> "$LOG"
n=\$(grep -c . "$LOG")
# R (issue #2236): the hub answers at once, the list carries the row only once
# $WORK/row-go appears — 先切 names the worker_id, 老入口 (an older hub) does not
case "\$title" in 先切*|老入口*)
  k=\$((42 + n)); nm=fast-\$k; who=U/issue-\$k
  case "\$title" in 老入口*) nm=old-\$k; who=@4 ;; esac
  ( i=0; while [ ! -e "$WORK/row-go" ] && [ \$i -lt 200 ]; do sleep .1; i=\$((i + 1)); done
    printf 'wid:U/issue-%s${US}working${US}*${US}%s${US}${US}${US}0${US}${US}m4${US}%s${US}${US}\n' "\$k" "\$nm" "\$k" >> "$ROWS" ) </dev/null >/dev/null 2>&1 &
  python3 -c 'import time; print(int(time.time() * 1000))' > "$WORK/t_reply"
  printf 'REMOTE m4 op%s done %s\tm5 busier\n' "\$n" "\$who"; exit 0 ;;
esac
# S (issue #2240): the hub out of reach — no line, a 503 on stderr, exit 1
case "\$title" in 入口挂了*) printf 'fleet-client-place: https://hub.invalid: HTTP 503 Service Unavailable\n' >&2; exit 1 ;; esac
sleep 2
case "\$1 \$2" in
  *' new') k=\$((42 + n)); nm=forty-three; [ "\$k" = 43 ] || nm=new-\$k
       # the node's timing points (issue #2238), as a new hub hands them on; the
       # other kinds play an older node that sends none
       [ -z "\${FLEET_PLACE_TIMING:-}" ] || printf '{"t_accepted": 1000, "t_window": 4500, "x": 1}' > "\$FLEET_PLACE_TIMING"
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
# the machines (fleet-hub-sessions.sh's hub_nodes): m4 the fewest running, m3 维护中
{ printf '#ts%s%s\n' "$US" "$(date +%s)"
  printf 'm5%sonline%s1.0%s8%s50%s3%sv%s0%s1%s2%sok%s%sm5host\n' "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US"
  printf 'm4%sonline%s1.0%s8%s50%s1%sv%s0%s1%s2%sok%s%sm4host\n' "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US"
  printf 'm3%sonline%s0.1%s8%s10%s0%sv%s0%s1%s2%sok%smaint%sm3host\n' "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US"; } > "$FLEET_STATUS_G/hub_nodes"
export FLEET_AGENT=codex   # this fleet's default agent: Agent's default (issue #2231)

# --- E. the pure parts ---------------------------------------------------------------
printf 'https://x/a.png\n' > "$WORK/shot.png"
printf '侧栏里 FLEET SKILLS 的名字太长被截了。\n附上截图 %s\n<!-- fleet:from role=hub -->\n' "$(printf '%s' "$WORK/shot.png" | sed 's/ /\\ /g')" > "$WORK/t1"
pl=$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1")
has 'E: the title is the first line' "$pl" '"title": "侧栏里 FLEET SKILLS 的名字太长被截了。"'
has 'E: the body is the whole text' "$pl" '附上截图'
has 'E: a dropped file is an attachment' "$pl" "\"attachments\": [\"$WORK/shot.png\"]"
has 'E: …listed under the body' "$pl" "附件:\\n- $WORK/shot.png"
hasnt 'E: a forged marker never leaves' "$pl" '<!--'
printf '\n\n' > "$WORK/t0"
eq 'E: nothing written: nothing to send' '{}' "$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t0")"
pl=$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1")
eq 'F: the fields are fixed (+ t_enter, the ↵ in ms — #2238)' 'agent at attachments body id node prev repo t_enter title' \
  "$(printf '%s' "$pl" | python3 -c 'import json, sys; print(" ".join(sorted(json.load(sys.stdin))))')"
has 'F: node null by default (the hub picks)' "$pl" '"node": null'
has 'F: agent null by default (FLEET_AGENT)' "$pl" '"agent": null'
hasnt 'F: no 「记成 issue」 field' "$pl" '"issue"'
pl=$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1" --repo acme/app --node m5host --agent codex)
has 'F: --repo names it' "$pl" '"repo": "acme/app"'
has 'F: --node names it' "$pl" '"node": "m5host"'
has 'F: --agent names it' "$pl" '"agent": "codex"'
pl=$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1" --no-repo)
has 'F: --no-repo: HOME is repo null' "$pl" '"repo": null'
has 'F: …with the whole text' "$pl" '附上截图'
eq 'F: one choice only' 2 "$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1" --no-repo --repo acme/app >/dev/null 2>&1; echo $?)"
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
has 'A: 「仓库」 is the repo of the row before' "$(compose)" '仓库  web ▾'
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
# N. the send's three lines, one id (issue #1955)
clog() { python3 -c 'import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    print(" ".join("%s=%s" % (k, r[k]) for k in sys.argv[2:] if k in r))' "$FLEET_COMPOSE_LOG" "$@" 2>/dev/null; }
CHECKS=$((CHECKS + 1)); n=0; while ! grep -q '"started"' "$FLEET_COMPOSE_LOG" 2>/dev/null && [ $n -lt 30 ]; do sleep .1; n=$((n + 1)); done
eq 'N: sent · placed · switched · started' $'ev=sent how=issue repo=acme/web\nev=placed rc=0 result=REMOTE machine=m4 session=U/issue-43\nev=switched session=U/issue-43\nev=started session=U/issue-43 state=working' \
  "$(clog ev how repo rc result machine session state)"
eq 'N: …one id' 1 "$(clog id | sort -u | grep -c .)"
has 'N: started says the seconds since the ↵' "$(clog ev secs | tail -1)" 'secs='
# issue #2238: the ↵'s ms, the node's points on `placed`, and `ready` once the
# row reads a state the person can type into
case "$(clog ev t_enter | head -1)" in "ev=sent t_enter="[0-9]*) CHECKS=$((CHECKS + 1)) ;; *) fail 'N: sent carries t_enter' "$(clog ev t_enter)" ;; esac
eq 'N: placed carries the node timing' "ev=placed t_accepted=1000 timing={'t_accepted': 1000, 't_window': 4500}" "$(clog ev t_accepted timing | sed -n 2p)"
python3 -c 'import sys; p = sys.argv[1]; t = open(p).read().replace("wid:U/issue-43\x1fworking", "wid:U/issue-43\x1fdone"); open(p, "w").write(t)' "$ROWS"
CHECKS=$((CHECKS + 1)); n=0; while ! grep -q '"ready"' "$FLEET_COMPOSE_LOG" 2>/dev/null && [ $n -lt 50 ]; do sleep .1; n=$((n + 1)); done
case "$(clog ev session state t_ready | tail -1)" in "ev=ready session=U/issue-43 state=done t_ready="[0-9]*) ;; *) fail 'N: ready once the row reads done' "$(clog ev session state t_ready | tail -1)" ;; esac
eq 'N: …still one id' 1 "$(clog id | sort -u | grep -c .)"
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

# D. (issue #2231) the three options, their defaults, a hand-picked send
st_ select-window -t "$pw"
c=$(compose)
for gone in '记成 issue' '发法' '多个仓库' '编排'; do hasnt "D: no $gone on the area" "$c" "$gone"; done
has 'D: 仓库 — the row in view' "$c" '仓库  web ▾'
has 'D: 节点 — the fewest running' "$c" '节点  m4 ▾'
has 'D: Agent — FLEET_AGENT' "$c" 'Agent  codex ▾'
has 'D: the go word' "$c" '↵ 开工'
has 'D: one short keys line' "$c" '⇧↵ 换行 · Tab 改选项 · esc 返回'
st_ send-keys -t "$pw" Tab; st_ send-keys -t "$pw" Tab   # 「节点」
st_ send-keys -t "$pw" Enter
sleep .4
c=$(compose)
has 'D: the machines, the default marked 推荐' "$c" 'm4  推荐 · 1 个在跑'
has 'D: …the others by their count' "$c" 'm5  3 个在跑'
has 'D: …维护中 listed' "$c" 'm3  维护中'
st_ send-keys -t "$pw" Down; st_ send-keys -t "$pw" Down   # m5, then m3 (greyed: skipped) → m4
st_ send-keys -t "$pw" Down                                 # → m5
st_ send-keys -t "$pw" Enter
sleep .3
has 'D: a greyed machine is never picked' "$(compose)" '节点  m5 ▾'
st_ send-keys -t "$pw" Tab                                  # 「Agent」
st_ send-keys -t "$pw" Space
sleep .3
has 'D: the agents, the default marked' "$(compose | grep -F '✓ codex')" '默认'
st_ send-keys -t "$pw" Up; st_ send-keys -t "$pw" Enter
sleep .3
has 'D: Agent picked by hand' "$(compose)" 'Agent  claude ▾'
st_ send-keys -t "$pw" Enter                                # ↵ on an option opens it…
sleep .3
st_ send-keys -t "$pw" Escape                               # …esc closes only the menu
sleep .3                                                    # (ESC then Tab at once reads as one key)
st_ send-keys -t "$pw" Tab                                  # back to the text
sleep .2
st_ send-keys -t "$pw" Enter
CHECKS=$((CHECKS + 1)); n=0; while [ "$(grep -c . "$LOG")" -lt 2 ] && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
line=$(sed -n 2p "$LOG")
has 'D: an issue in the repo, the whole text' "$line" 'acme/web new --title 看一下 m5 为什么慢 --body-file '
has 'D: …the machine picked' "$line" ' --node m5host'
has 'D: …the agent picked' "$line" ' --agent claude'
eq 'D: the text travelled' '看一下 m5 为什么慢' "$(cat "$BODY" 2>/dev/null)"
CHECKS=$((CHECKS + 1)); waitfor 3 '节点  m4 ▾' compose || fail 'D: the machine back to its default after the send' "$(compose)"
has 'D: …the agent too' "$(compose)" 'Agent  codex ▾'

# The 「仓库」 option. Each send waits for the one before it to land.
settled() { n=0; while screen | grep -qF '开工中' && [ $n -lt 80 ]; do sleep .1; n=$((n + 1)); done; }
placed_n() { n=0; while [ "$(grep -c . "$LOG")" -lt "$1" ] && [ $n -lt 60 ]; do sleep .1; n=$((n + 1)); done; sed -n "$1p" "$LOG"; }
# G. a repo, picked from the menu
settled
st_ send-keys -t "$pw" Tab
st_ send-keys -t "$pw" Space
sleep .4
menu=$(compose)
for want in 'web' '你刚才在这' 'app' 'acme' '无仓库 · HOME' '在主目录开会话' '↑↓ 选'; do has "G: the menu lists $want" "$menu" "$want"; done
for gone in '自动' '不关联仓库' '多个仓库'; do hasnt "G: the menu has no $gone" "$menu" "$gone"; done
st_ send-keys -t "$pw" Up
st_ send-keys -t "$pw" Enter
sleep .3
has 'G: the field names the repo picked' "$(compose)" '仓库  app ▾'
st_ send-keys -t "$pw" -l '修一下 app 的登录页'
sleep .2
st_ send-keys -t "$pw" Enter
line=$(placed_n 3)
has 'G: the picked repo, an issue' "$line" 'acme/app new --title 修一下 app 的登录页 --body-file '
has 'G: …machine and agent left to their defaults' "$line" ' --node auto'
hasnt 'G: …no --agent' "$line" '--agent'
CHECKS=$((CHECKS + 1)); waitfor 3 '仓库  web ▾' compose || fail 'G: back to the row in view after a send' "$(compose)"

# H. 无仓库 · HOME: a session of no repo with the WHOLE text, under no repo
settled
st_ send-keys -t "$pw" Tab
st_ send-keys -t "$pw" Space
sleep .3
st_ send-keys -t "$pw" Down
st_ send-keys -t "$pw" Enter
sleep .3
has 'H: the field says HOME' "$(compose)" '无仓库 · HOME ▾'
st_ send-keys -t "$pw" -l '整理一下这周的日报'
st_ send-keys -t "$pw" C-j
st_ send-keys -t "$pw" -l '按项目分组。'
sleep .2
st_ send-keys -t "$pw" Enter
line=$(placed_n 4)
has 'H: no repo, a scratch named by the line' "$line" '- scratch --name 整理一下这周的日报 --body-file '
has 'H: …--node auto' "$line" ' --node auto'
eq 'H: the WHOLE text is its seed' $'整理一下这周的日报\n按项目分组。' "$(cat "$BODY" 2>/dev/null)"
CHECKS=$((CHECKS + 1)); waitfor 8 'no repo (1)' || fail 'H: the session row arrived' "$(screen)"
grp=$(screen | awk '/no repo/ { on = 1 } on && /整理一下/ { print "under"; exit }')
eq 'H: …under the no repo heading' under "$grp"

# I. a hand-picked option, then ⌘N from elsewhere: the defaults again; with no
# row in view that names a repo, the one the last send went to (acme/app, G)
settled
st_ send-keys -t "$pw" Tab; st_ send-keys -t "$pw" Tab; st_ send-keys -t "$pw" Tab
st_ send-keys -t "$pw" Space
sleep .3
st_ send-keys -t "$pw" Up; st_ send-keys -t "$pw" Enter
sleep .3
has 'I: Agent changed by hand' "$(compose)" 'Agent  claude ▾'
printf '{"stack": [], "at": 0, "mru": []}\n' > "$FLEET_SWITCH_STATE/switch-history.json"
st_ select-window -t fcs-stage:0
type_ '\033[928~'
CHECKS=$((CHECKS + 1)); waitfor 4 'Agent  codex ▾' compose || fail 'I: ⌘N puts the agent back' "$(compose)"
has 'I: …and 仓库 to the last send'"'"'s repo' "$(compose)" '仓库  app ▾'
printf '{"stack": ["wid:U/issue-9"], "at": 0, "mru": ["wid:U/issue-9"]}\n' > "$FLEET_SWITCH_STATE/switch-history.json"
st_ select-window -t fcs-stage:0
type_ '\033[928~'
CHECKS=$((CHECKS + 1)); waitfor 4 '仓库  web ▾' compose || fail 'I: ⌘N: the row in view again' "$(compose)"

# --- the orchestrator (issue #1957): its row, not the area ---------------------------
orch() { printf 'U/orch%sm4%sonline%s%s%s%s%s%s\n' "$US" "$US" "$US" "$1" "$US" "${2:-}" "$US" "${3:-}" > "$FLEET_STATUS_G/orch_fcs"; }
newtask() { screen | grep -F '新任务' | head -1; }
has 'N: H'"'"'s is no repo' "$(clog ev how | grep 'ev=sent')" 'ev=sent how=norepo'
hasnt 'N: nothing is a scratch of a repo any more' "$(clog ev how | grep 'ev=sent')" 'how=scratch'

# J. free: the area says nothing of it, ↵ starts the work, ⇧⇥ carries nothing
settled
orch 'done'
st_ select-window -t "$pw"
st_ send-keys -t "$pw" -l '活页里加一张 fleet 状态卡'
sleep 2.5
hasnt 'J: the area says nothing of the orchestrator' "$(compose)" '编排'
nlog=$(grep -c . "$LOG"); : > "$VIEW"; : > "$WORK/orch-in"
st_ send-keys -t "$pw" BTab
sleep .8
eq 'J: ⇧⇥ goes nowhere' '' "$(cat "$VIEW")"
st_ send-keys -t "$pw" Tab      # ⇧⇥ walked the options backwards: back to the text
st_ send-keys -t "$pw" Enter
line=$(placed_n $((nlog + 1)))
has 'J: ↵ starts the work itself' "$line" 'acme/web new --title 活页里加一张 fleet 状态卡 --body-file '
eq 'J: nothing pasted to it' '' "$(cat "$WORK/orch-in" 2>/dev/null)"

# K. working: 「新任务」 wears the spinner
settled
orch working '' '跑 #1935 的批'
spun() { newtask | grep -q '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'; }
CHECKS=$((CHECKS + 1)); n=0; while ! spun && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
spun || fail 'K: 「新任务」 wears the spinner' "$(newtask)"

# L. waiting on you: 「新任务」 turns red
orch needs ask '开一个 EPIC 还是三个快任务？'
red() { newtask | grep -q '!'; }
CHECKS=$((CHECKS + 1)); n=0; while ! red && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
red || fail 'L: 「新任务」 turns red !' "$(newtask)"

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
# O. (pure) fleet-history.sh drafts (issue #1955): its own conf dir and log
DC="$WORK/drafts"; CH="$DC/fleets/f/children"; mkdir -p "$CH"
now=$(date +%s); today=$(date +%Y-%m-%d); iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
yday=$(python3 -c 'import time; print(time.strftime("%Y-%m-%d", time.localtime(time.time() - 86400)))')
ygen="$((now - 86400)).77"
{ printf '{"ts": "%s", "child": "r:issue-1", "state": "MERGED", "pfid": "P-hand", "gen": "%s.1"}\n' "$iso" "$now"
  printf '{"ts": "%s", "child": "r:issue-2", "state": "MERGED", "pfid": "P-hand", "gen": "%s.1"}\n' "$iso" "$now"
  printf '{"ts": "%s", "child": "r:issue-3", "state": "MERGED", "pfid": "P-old", "gen": "%s"}\n' "$iso" "$ygen"; } > "$CH/r:scratch-1.ndjson"
printf '{"ts": "%s", "child": "r:issue-4", "state": "MERGED", "pfid": "p-area"}\n' "$iso" > "$CH/r:scratch-2.ndjson"
printf '{"ts": "%s", "child": "r:issue-5", "state": "MERGED", "relayed_from": "r:issue-9"}\n' "$iso" > "$CH/r:scratch-3.ndjson"
printf '{"ts": "%s", "child": "r:issue-6", "state": "MERGED"}\n' "$iso" > "$CH/r:issue-50.ndjson"
printf '{"ts": "%s", "child": "r:issue-7", "state": "MERGED"}\n' "$iso" > "$CH/orchestrator.ndjson"
{ printf '{"ev": "sent", "id": "a", "at": %s}\n{"ev": "started", "id": "a", "secs": 10, "fid": "p-area"}\n' "$now"
  printf '{"ev": "sent", "id": "b", "at": %s}\n{"ev": "started", "id": "b", "secs": 30}\n' "$now"
  printf '{"ev": "sent", "id": "c", "at": %s}\n{"ev": "placed", "id": "c", "rc": 4}\n' "$now"; } > "$DC/compose.ndjson"
out=$(FLEET_CONF_DIR="$DC" FLEET_COMPOSE_LOG="$DC/compose.ndjson" bash "$BIN/fleet-history.sh" drafts --days 2)
eq 'O: today — one hand draft (the area'"'"'s, a relayed row, an issue and the orchestrator are not), 3 sends, 2 started, median 20s' \
  "$today	drafts=1	sends=3	started=2	start_median=20s" "$(printf '%s\n' "$out" | sed -n 1p)"
eq 'O: yesterday — the recycled number'"'"'s earlier generation, dated by its allocation' \
  "$yday	drafts=1	sends=0	started=0	start_median=-" "$(printf '%s\n' "$out" | sed -n 2p)"
has 'O: --json' "$(FLEET_CONF_DIR="$DC" FLEET_COMPOSE_LOG="$DC/compose.ndjson" bash "$BIN/fleet-history.sh" drafts --days 1 --json)" '"drafts": 1, "sends": 3'

# P. ⌘N twice (issue #2146): the writing area ⇄ the orchestrator, no draft carried
settled
orch 'done'
st_ select-window -t "$pw"
st_ send-keys -t "$pw" C-u
st_ send-keys -t "$pw" -l '留在写作区的半句'
sleep .3
: > "$VIEW"; : > "$WORK/orch-in"
type_ '\033[928~'
CHECKS=$((CHECKS + 1)); n=0; while ! grep -qx 'wid:U/orch' "$VIEW" && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
grep -qx 'wid:U/orch' "$VIEW" || fail 'P: ⌘N on the writing area asked the list to jump to the orchestrator' "$(cat "$VIEW")"
CHECKS=$((CHECKS + 1)); n=0; while [ "$(st_ display-message -p -t fcs-stage: '#{@remote}')" != m4:U/orch ] && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
eq 'P: the stage shows the orchestrator' m4:U/orch "$(st_ display-message -p -t fcs-stage: '#{@remote}')"
sleep .5
eq 'P: …pasting nothing' '' "$(cat "$WORK/orch-in")"
type_ '\033[928~'
CHECKS=$((CHECKS + 1)); n=0; while [ "$(st_ display-message -p -t fcs-stage: '#{window_id}')" != "$pw" ] && [ $n -lt 40 ]; do sleep .1; n=$((n + 1)); done
eq 'P: ⌘N again: back to the writing area' "$pw" "$(st_ display-message -p -t fcs-stage: '#{window_id}')"
has 'P: …the draft still there' "$(compose)" '留在写作区的半句'
# …and 「新任务」's right-click menu (fleet-sidebar-menu.sh `menu <s> new`): 进编排会话
# first, on the same road; none → greyed, with the reason
pmenu() { FLEET_SHELL=1 bash -c 'BIN=$1; sess=$2; verb=menu; set -- menu "$2" new --print
  . "$BIN/fleet-lib.sh"; . "$BIN/fleet-ui-lang.sh"; . "$BIN/fleet-sidebar-menu.sh"' _ "$BIN" fcs 2>/dev/null; }
m=$(pmenu)
eq 'P: 「新任务」 has a menu, titled with its name' $'title\t新任务' "$(printf '%s\n' "$m" | head -1)"
has 'P: …its first item goes to the orchestrator' "$(printf '%s\n' "$m" | sed -n 2p | cut -f1,2)" $'b\t进编排会话'
has 'P: …by fleet-compose.py --orch' "$(printf '%s\n' "$m" | sed -n 2p | tr -d "'\\\\")" 'fleet-compose.py --orch fcs'
rm -f "$FLEET_STATUS_G/orch_fcs"
: > "$VIEW"
type_ '\033[928~'
sleep 1
eq 'P: no orchestrator → ⌘N on the writing area changes nothing' "$pw|" "$(st_ display-message -p -t fcs-stage: '#{window_id}')|$(cat "$VIEW")"
has 'P: none → greyed, saying why' "$(pmenu | sed -n 2p | cut -f1,2)" $'b\t-进编排会话 · 这台机器没有编排会话'

# R. (issue #2236) the hub names the new session: the stage is on it within 0.5 s
# of the answer, the 「开工中…」 row stands in for it; the list's next round
# swaps in the real row, once. An older hub (no worker_id): as before.
send_r() { settled; rm -f "$WORK/row-go" "$WORK/t_reply"; : > "$VIEW"; : > "$VIEW.args"
  st_ select-window -t "$pw"; st_ send-keys -t "$pw" C-u; st_ send-keys -t "$pw" -l "$1"; sleep .3
  st_ send-keys -t "$pw" Enter; }
send_r '先切过去再说'
CHECKS=$((CHECKS + 1)); n=0; while ! grep -q . "$VIEW" && [ $n -lt 80 ]; do sleep .05; n=$((n + 1)); done
k=$(sed -n 's#^wid:U/issue-##p' "$VIEW" | head -1)
[ -n "$k" ] || fail 'R: the stage switched before the row showed' "$(cat "$VIEW")"
has 'R: …on the machine the hub named, under the title' "$(cat "$VIEW.args")" "open wid:U/issue-$k --node m4 --name 先切过去再说"
sw=$(python3 -c 'import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["ev"] == "switched" and r.get("session") == sys.argv[2]:
        print(r["t_switch"])' "$FLEET_COMPOSE_LOG" "U/issue-$k" 2>/dev/null | tail -1)
CHECKS=$((CHECKS + 1)); [ -n "$sw" ] && [ $((sw - $(cat "$WORK/t_reply"))) -le 500 ] \
  || fail 'R: switched within 0.5 s of the answer' "t_switch=$sw t_reply=$(cat "$WORK/t_reply" 2>/dev/null)"
has 'R: the 「开工中…」 row stands in for it' "$(screen)" '开工中… 先切过去再说'
hasnt 'R: …no real row yet' "$(screen)" "fast-$k"
touch "$WORK/row-go"
CHECKS=$((CHECKS + 1)); waitfor 6 "fast-$k" || fail 'R: the real row arrived' "$(screen)"
settled
hasnt 'R: the stand-in gone with it' "$(screen)" '开工中'
eq 'R: the new session is in the list once' 1 "$(screen | grep -c "fast-$k")"
eq 'R: switched once, never again when the row showed' 1 "$(grep -c . "$VIEW")"
send_r '老入口不给'
sleep 1.2
eq 'R: an older hub (no worker_id): no switch before the row' '' "$(cat "$VIEW")"
has 'R: …the 「开工中…」 row meanwhile' "$(screen)" '开工中… 老入口不给'
touch "$WORK/row-go"
CHECKS=$((CHECKS + 1)); n=0; while ! grep -q 'wid:U/issue-' "$VIEW" && [ $n -lt 60 ]; do sleep .1; n=$((n + 1)); done
has 'R: …switched once the row showed, as before' "$(cat "$VIEW")" 'wid:U/issue-'
hasnt 'R: …found by the list, no --node' "$(cat "$VIEW.args")" '--node'
# S. (issue #2240) the hub answers 503: the text stays in the box as written,
# the line under the options says why and what next until the next key, the
# payload is kept as compose-failed.json; the next ↵ that opens empties it
settled; : > "$VIEW"
st_ select-window -t "$pw"; st_ send-keys -t "$pw" C-u
st_ send-keys -t "$pw" -l '入口挂了也别丢'; st_ send-keys -t "$pw" C-j; st_ send-keys -t "$pw" -l '第二行也在'; sleep .3
st_ send-keys -t "$pw" Enter
CHECKS=$((CHECKS + 1)); waitfor 8 '没发出去' compose || fail 'S: the area says it was not sent' "$(compose)"
has 'S: …why, in the list'"'"'s words' "$(compose)" '入口连不上'
has 'S: …and what next' "$(compose)" '字还在，改好再 ↵'
has 'S: the first line is still in the box' "$(compose)" '入口挂了也别丢'
has 'S: …and the second' "$(compose)" '第二行也在'
has 'S: the draft on disk holds it' "$(cat "$FLEET_SWITCH_STATE/compose-draft" 2>/dev/null)" '第二行也在'
has 'S: the payload is kept' "$(cat "$FLEET_SWITCH_STATE/compose-failed.json" 2>/dev/null)" '入口挂了也别丢'
eq 'S: nothing switched' '' "$(cat "$VIEW")"
sleep 1
has 'S: the reason stays while no key is pressed' "$(compose)" '没发出去'
st_ send-keys -t "$pw" End; sleep .4
hasnt 'S: …and goes with the next key' "$(compose)" '没发出去'
has 'S: …the text still there' "$(compose)" '入口挂了也别丢'
# the direct road (no list): --send from the area's own process says the same
out=$(cd "$SB" && python3 -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("c", "fleet-compose.py"); c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
print(c.place_why("fleet-client-place: https://hub.invalid: HTTP 503 Service Unavailable"))
print(c.place_why("REFUSED NO_CAPACITY\t没有机器有空\tafter m4:op1:5"))' 2>&1)
eq 'S: the reason off the place: the last line, or the line'"'"'s message' \
  $'fleet-client-place: https://hub.invalid: HTTP 503 Service Unavailable\n没有机器有空' "$out"
# Q. (pure) the machine and the agent (issue #2232): a sandbox bin/ whose
# fleet-client-place.sh prints its argv (the body file's path masked)
QB="$WORK/q-bin"; mkdir -p "$QB"
for f in "$BIN"/*; do ln -sf "$f" "$QB/"; done
rm -f "$QB/fleet-client-place.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" | sed "s#--body-file [^ ]*#--body-file B#"\n' > "$QB/fleet-client-place.sh"
chmod +x "$QB/fleet-client-place.sh"
qsend() { printf '%s\n' "$1" > "$WORK/q.json"; shift
  FLEET_SWITCH_STATE="$WORK/q-state" FLEET_COMPOSE_LOG="$WORK/q.ndjson" python3 "$QB/fleet-compose.py" --send "$WORK/q.json" "$@" 2>&1; }
mkdir -p "$WORK/q-state"
eq 'Q: an older payload (no node, no agent) → --node auto, no --agent' \
  'acme/web new --title 看日志 --body-file B --node auto' \
  "$(qsend '{"title":"看日志","body":"看日志\n再看看","repo":"acme/web"}')"
eq 'Q: node / agent null → the same argv' \
  'acme/web new --title 看日志 --body-file B --node auto' \
  "$(qsend '{"title":"看日志","body":"看日志\n再看看","repo":"acme/web","node":null,"agent":null}')"
eq 'Q: m4 + codex → --node m4 --agent codex' \
  'acme/web new --title 看日志 --body-file B --node m4 --agent codex' \
  "$(qsend '{"title":"看日志","body":"看日志\n再看看","repo":"acme/web","node":"m4","agent":"codex"}')"
eq 'Q: a scratch of no repo carries them too' \
  '- scratch --name 看日志 --body-file B --node m4 --agent codex' \
  "$(qsend '{"title":"看日志","body":"看日志","repo_mode":"none","node":"m4","agent":"codex"}')"
eq 'Q: a named --node / --agent beats the payload'"'"'s' \
  'acme/web new --title 看日志 --body-file B --node m5 --agent claude' \
  "$(qsend '{"title":"看日志","body":"看日志\n再看看","repo":"acme/web","node":"m4","agent":"codex"}' --node m5 --agent claude)"
out=$(qsend '{"title":"看日志","repo":"acme/web","agent":"gpt"}'); rc=$?
eq 'Q: an unknown agent is refused (2), nothing placed' '2|fleet-compose: agent is claude or codex, not gpt' "$rc|$out"
[ "$FAIL" = 0 ] || { printf 'fleet-compose selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS"; exit 1; }
printf 'fleet-compose selftest: PASS (%d checks)\n' "$CHECKS"
