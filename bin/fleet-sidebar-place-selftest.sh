#!/bin/bash
# fleet-sidebar-place-selftest.sh — in the client, new / restore / scratch open a
# session ON a machine: repo, then 「开在哪」, then over to it (issue #1778, EPIC
# #1776 C2).
#
# The real list (bin/fleet-sidebar.py ui, FLEET_SHELL=1) in a pane of an ISOLATED
# tmux server (-S, a socket under the work dir). The list takes no keys (issue
# #1950): its actions are verbs parked in @sidebar_ask (`new` `scratch`
# `restore`), every question opens on ONE line under the session
# (bin/fleet-ask.py, `@stage_ask`) and is answered there with send-keys, and
# what the list says is on the bar — read off the attached client's terminal. Around it a sandbox bin/ of symlinks to the shipped scripts, three
# faked: tmux-dashboard-rows.sh prints a rows file (two repo headings, an m5 row),
# fleet-client-place.sh is the hub — it logs its argv and answers per a scenario
# file (C1's exit codes), adding the new session's row to the rows file when it
# «opens» one — and fleet-remote-view.sh logs the row a switch steps into. The
# hub's /v1/nodes is a hub_nodes cache under FLEET_STATUS_G: m4 (1 running), m5
# (3 running), mbp (only coordinates).
#   A. `new`: the repo menu (both repos) → ↵ → the issue line → 42 ↵ → 「开在哪」:
#      自动 first and highlighted, m4 before m5 (fewer running), mbp greyed
#      只协调; ↓↓↓ never lands on mbp; ↵ on 自动 runs the place with
#      `acme/web 42 --node auto`; the bar says 正在…开; the new row appears,
#      is selected, and the switch stepped into it; the bar says 已切过去
#   B. `scratch`: a scratch — repo (the highlighted row's preselected), then
#      「开在哪」 → m4: `<repo> scratch --node <m4's hostname>`
#   C. `restore`: the key line takes issue-9 → `restore:issue-9`
#   D. the hub unreachable (hub_ok stale): `new` says 入口连不上，暂时不能新建 — no
#      menu, nothing run; the place itself unreachable (exit 1) says the same
#   E. no machine can take it (REFUSED, exit 4): the hub's reason, as it said it
#   F. held elsewhere (HELD, exit 3): 已在 m5 上跑 · y 切过去 → y steps into the
#      m5 row of that issue
#   G. degenerate: nothing in the list says 这台电脑上没有 fleet any more
#   (pure) an empty list (issue #1927): no hub_repos → the old toast; one repo
#      in it → straight to 「开在哪」; two → the repo menu; none → who to ask;
#      headings present → hub_repos is never read; a `#account` line (issue
#      #2069): opening → a sticky word and the ↵ held for a retry, failed /
#      none → sticky, naming who to ask
# Plus the pure parts, imported: where_menu with an 11-field hub_nodes (an older
# loop: nothing greyed but what is lost), fleet_status_hub_node still reading
# ver_state off a 13-field line.
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass. FSP_KEEP=1 keeps the work dir.
set -uo pipefail
# Every session its own row (issue #2675): the batch view folds a flat list into
# 「单独的活」 — sidebar-batch-view-selftest.sh pins it; these rows are the old ones.
export FLEET_SIDEBAR_FOLD=off
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-sidebar-place selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-sidebar-place selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fsp-st.XXXXXX")" || exit 2
SOCK="$WORK/s"   # short: AF_UNIX caps a socket path at 104 bytes
export HOME="$WORK/home"; mkdir -p "$HOME"
export FLEET_CONF_DIR="$HOME/.config/claude-fleet" FLEET_UI_LANG=zh
export FLEET_STATUS_G="$WORK/g"; mkdir -p "$FLEET_STATUS_G"
unset TMUX TMUX_PANE FLEET_SESSION FLEET_SHELL_STAGE FLEET_HUB_URL FLEET_NODE_ALIASES
FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (must not have '$3')" "$2" ;; esac; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
ts() { "$REAL_TMUX" -S "$SOCK" "$@"; }
cleanup() {
  ts kill-server 2>/dev/null   # the isolated socket of this test, nothing else
  [ "${FSP_KEEP:-0}" = 1 ] && printf 'work dir kept: %s\n' "$WORK" >&2 || rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

US=$'\037'
SB="$WORK/bin"; mkdir -p "$SB"
for f in "$BIN"/*; do ln -s "$f" "$SB/$(basename "$f")"; done
ln -s "$BIN/../conf" "$WORK/conf"
ROWS="$WORK/rows"; LOG="$WORK/place.log"; VIEW="$WORK/view.log"; SCEN="$WORK/scenario"
: > "$LOG"; : > "$VIEW"
rows_reset() {
  printf 'hdr%sacme/app%s%sapp (1)%s\n' "$US" "$US" "$US" "$US" > "$ROWS"
  printf 'wid:U/issue-7%sworking%s*%sseven%s%s%s0%s%sm5%s7%s%s\n' "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" >> "$ROWS"
  printf 'hdr%sacme/web%s%sweb (0)%s\n' "$US" "$US" "$US" "$US" >> "$ROWS"
}
rows_reset
rm -f "$SB/tmux-dashboard-rows.sh" "$SB/fleet-client-place.sh" "$SB/fleet-remote-view.sh"
printf '#!/bin/sh\ncat %q\n' "$ROWS" > "$SB/tmux-dashboard-rows.sh"
printf '#!/bin/sh\n[ "$1" = open ] && printf "%%s\\n" "$2" >> %q\nexit 0\n' "$VIEW" > "$SB/fleet-remote-view.sh"
cat > "$SB/fleet-client-place.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$LOG"
case "\$(cat "$SCEN")" in
  ok)   printf 'wid:U/issue-42${US}working${US}*${US}forty-two${US}${US}${US}0${US}${US}m4${US}42${US}${US}\n' >> "$ROWS"
        printf 'REMOTE m4 op1 done U/issue-42\tm5 busier\n'; exit 0 ;;
  full) printf 'REFUSED NO_CAPACITY\tm4: 满了 (6/6)；m5: 满了 (8/8)\n'; exit 4 ;;
  held) printf 'HELD m5\t#7 is leased on m5\n'; exit 3 ;;
  down) printf 'fleet-client-place: the hub could not be asked: timed out\n' >&2; exit 1 ;;
  *)    printf 'UNKNOWN m4 op9\tstill starting\n'; exit 6 ;;
esac
EOF
chmod +x "$SB/tmux-dashboard-rows.sh" "$SB/fleet-client-place.sh" "$SB/fleet-remote-view.sh"
node_row() { local IFS=$US; printf '%s\n' "$*"; }
{ printf '#ts%s%s\n' "$US" "$(date +%s)"
  node_row m5 online 1.00 8 40 3 abc 1 1 2 ok '' m5.local
  node_row mbp online 0.50 8 40 0 abc 1 1 2 ok coord MacBook-Pro.local
  node_row m4 online 1.00 8 40 1 abc 1 1 2 ok '' mac-mini-m4.local; } > "$FLEET_STATUS_G/hub_nodes"
hub_fresh() { date +%s > "$FLEET_STATUS_G/hub_ok"; }
hub_fresh

# --- the pure parts ---------------------------------------------------------------
pure=$(cd "$SB" && python3 - <<'PY' 2>&1
import importlib.util, os
spec = importlib.util.spec_from_file_location("sb", "fleet-sidebar.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("menu", [(v, l, n, g) for v, l, n, g in m.where_menu()])
g = os.environ["FLEET_STATUS_G"]
os.rename(g + "/hub_nodes", g + "/hub_nodes.13")
with open(g + "/hub_nodes", "w") as f:   # an older loop: 11 fields, no place word
    f.write("#ts\x1f1\nm5\x1fonline\x1f1\x1f8\x1f4\x1f2\x1fa\x1f1\x1f1\x1f2\x1fok\nm6\x1flost\x1f1\x1f8\x1f4\x1f0\x1fa\x1f1\x1f1\x1f2\x1fok\n")
print("old", [(v, n, g) for v, l, n, g in m.where_menu()])
os.rename(g + "/hub_nodes.13", g + "/hub_nodes")
rows = [["hdr", "acme/app", "", "app"], ["wid:U/issue-7", "working", "*", "seven", "", "", "0", "", "m5", "7", "", ""],
        ["hdr", "acme/web", "", "web"]]
print("repos", m.shell_repos(rows), m.repo_of(rows, "wid:U/issue-7"), m.repo_of(rows, "hdr:acme/web"))
# An empty list (issue #1927): the hub's hub_repos stands in for the headings.
def first(label, verb, rows=[]):
    ask, toast = m.place_start(verb, rows, "", name="tea")
    print(label, ask and ask.kind, ask and ask.plan.get("repo"), ask and [v for v, *_ in ask.menu], toast)
first("e0", "scratch")
with open(g + "/hub_repos", "w") as f:
    f.write("#ts\x1f1\nacme/solo\n")
first("e1", "scratch")
first("e1rows", "scratch", rows)     # headings present: hub_repos never read
with open(g + "/hub_repos", "w") as f:
    f.write("#ts\x1f1\nacme/a\nacme/b\n")
first("e2", "scratch")
with open(g + "/hub_repos", "w") as f:
    f.write("#ts\x1f1\n")
first("e3", "new")
# A login being opened for them (issue #2069): sticky, ↵ held for a retry;
# failed / none name who to ask; a repo next to the line is no newcomer.
def acct(label, line, repos=""):
    with open(g + "/hub_repos", "w") as f:
        f.write("#ts\x1f1\n#account\x1f" + line + "\x1f1\n" + repos)
    ask, toast = m.place_start("scratch", [], "a", name="tea")
    print(label, ask and ask.kind, type(toast).__name__, getattr(toast, "retry", None), toast)
acct("a1", "opening\x1f42\x1fm4.local\x1fverkyyi")
acct("a2", "failed\x1f\x1fm4.local\x1fverkyyi")
acct("a3", "none\x1f\x1f\x1fverkyyi")
acct("a4", "opening\x1f42\x1fm4.local\x1fverkyyi", "acme/solo\n")
print("a5", m.hub_repos(), m.hub_account())
os.unlink(g + "/hub_repos")
print("a6", m.hub_account())
PY
)
has 'pure: 自动 first' "$pure" "menu [('auto', '自动（入口挑最闲的）', '推荐', False)"
has 'pure: m4 (1 running) before m5 (3)' "$pure" "('mac-mini-m4.local', 'm4', '1 个在跑', False), ('m5.local', 'm5', '3 个在跑', False), ('MacBook-Pro.local', 'mbp', '只协调', True)"
has 'pure: an 11-field cache — its label is the node, a lost one greyed' "$pure" "old [('auto', '推荐', False), ('m5', '2 个在跑', False), ('m6', '失联', True)]"
has 'pure: the repos from the headings, a row in the heading above it' "$pure" "repos ['acme/app', 'acme/web'] acme/app acme/web"
has 'empty list, no hub_repos: the old toast, byte for byte' "$pure" "e0 None None None 还没有仓库：侧栏里先要有一个仓库的会话"
has 'empty list + one hub repo: straight to 「开在哪」' "$pure" "e1 place-where acme/solo ['auto', 'mac-mini-m4.local', 'm5.local', 'MacBook-Pro.local'] "
has 'headings present: the repo menu from them, hub_repos unread' "$pure" "e1rows place-repo  ['acme/app', 'acme/web'] "
has 'empty list + two hub repos: the repo menu' "$pure" "e2 place-repo  ['acme/a', 'acme/b'] "
has 'the hub says none: who to ask' "$pure" "e3 None None None 你还没有能开会话的机器：请入口管理员给你分一台"
has '#2069 opening: sticky, the ↵ held for a retry' "$pure" "a1 None Sticky ('scratch', 'a', 'tea', False) 正在为你开机器（m4.local），约 42 秒 — 开好后自动接着开"
has '#2069 failed: sticky, who to ask, no retry' "$pure" "a2 None Sticky None 给你开机器没成功：请找入口管理员 verkyyi"
has '#2069 none: sticky, names the admin' "$pure" "a3 None Sticky None 你还没有能开会话的机器：请找入口管理员 verkyyi 给你分一台"
has '#2069 a repo beside the line: straight to 「开在哪」' "$pure" "a4 place-where str None "
has '#2069 the #account line is never a repo' "$pure" "a5 ['acme/solo'] {'state': 'opening', 'eta': '42', 'machine': 'm4.local', 'ask': 'verkyyi'}"
has '#2069 no file: no account word' "$pure" "a6 None"
vst=$(FLEET_STATUS_G="$FLEET_STATUS_G" bash -c '. "$1/fleet-status-lib.sh"; fleet_status_hub_node mbp; printf "%s|%s" "$HN_VST" "$HN_SESS"' _ "$SB")
eq 'fleet_status_hub_node: ver_state off a 13-field line' 'ok|0' "$vst"

# --- the list, live ------------------------------------------------------------------
ts -f /dev/null new-session -d -s shell -x 130 -y 30 "sleep 600" || { printf 'cannot start tmux\n' >&2; exit 2; }
worker=$(ts display-message -p -t shell: '#{pane_id}')
side=$(ts split-window -h -b -l 40 -t "$worker" -P -F '#{pane_id}' \
  "cd '$SB' && env FLEET_SHELL=1 FLEET_STATUS_G='$FLEET_STATUS_G' FLEET_UI_LANG=zh FLEET_SIDEBAR_TOAST_SECS=1 TERM=xterm-256color python3 fleet-sidebar.py ui shell '$worker' '$WORK/lock'")
# A client on a pty (the view paints only while a client shows it): a python
# parent that drains the pty into TTY (the bar's words are read there), with its
# own alarm(2) so it cannot outlive the test; the server's end goes with
# cleanup's kill-server.
TTY="$WORK/tty.out"; : > "$TTY"
python3 - "$REAL_TMUX" "$SOCK" "$TTY" <<'PY' &
import fcntl, os, pty, signal, struct, sys, termios
tmux, sock, out = sys.argv[1:4]
signal.alarm(240)
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execvp(tmux, [tmux, "-S", sock, "attach", "-t", "shell"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 31, 130, 0, 0))
try:
    with open(out, "ab", buffering=0) as log:
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            log.write(chunk)
except OSError:
    pass
PY
screen() { ts capture-pane -p -t "$side" 2>/dev/null; }
# the question open under the session, and what it shows
askp() { ts list-panes -t "$worker" -F '#{pane_id} #{@stage_ask}' 2>/dev/null | awk '$2 == 1 { print $1; exit }'; }
aline() { local p; p=$(askp); [ -n "$p" ] && ts capture-pane -p -t "$p" 2>/dev/null; }
bar() { LC_ALL=C tr -d '\000' < "$TTY"; }
waitfor() {  # waitfor <secs> <needle> [screen|aline|bar]
  local n=0; while [ "$n" -lt $(( $1 * 10 )) ]; do "${3:-aline}" | grep -qaF -- "$2" && return 0; sleep .1; n=$((n + 1)); done; return 1
}
park() { ts set-option -p -t "$side" @sidebar_ask "$1" \; send-keys -t "$side" F12; sleep .3; }
# key <keys…> → into the question open now (waited for: the next one opens once
# the list has run the last answer); an answer (↵, y) waits for its line to close
key() {
  local p n=0
  while [ -z "$(askp)" ] && [ "$n" -lt 50 ]; do sleep .1; n=$((n + 1)); done
  p=$(askp); [ -n "$p" ] || return 0
  ts send-keys -t "$p" "$@"
  case " $* " in
    *" Enter "*|" y ") n=0; while [ "$(askp)" = "$p" ] && [ "$n" -lt 50 ]; do sleep .1; n=$((n + 1)); done ;;
    *) sleep .3 ;;
  esac
}
CHECKS=$((CHECKS + 1)); waitfor 10 'seven' screen || fail 'the list painted its rows' "$(screen)"

# A. new → repo → issue → where → auto
echo ok > "$SCEN"
park new
CHECKS=$((CHECKS + 1)); waitfor 5 '新会话 → 选仓库' || fail 'A: `new` opens the repo menu under the session' "$(aline)"
s=$(aline); has 'A: the repo menu lists app' "$s" 'app'; has 'A: …and web' "$s" 'web'
hasnt 'A: never the old refusal' "$s" '没有 fleet'
hasnt 'A: the list draws no question' "$(screen)" '选仓库'
key Down; key Enter
CHECKS=$((CHECKS + 1)); waitfor 5 'issue #›' || fail 'A: the issue line after the repo' "$(aline)"
key 4 2; key Enter
CHECKS=$((CHECKS + 1)); waitfor 5 '开在哪' || fail 'A: 「开在哪」 after the issue' "$(aline)"
s=$(aline)
has 'A: 「开在哪」 names the repo and the issue' "$s" 'web #42 → 开在哪'
has 'A: 自动 highlighted' "$s" '› 自动（入口挑最闲的）'
has 'A: mbp greyed 只协调' "$s" '只协调'
order=$(printf '%s\n' "$s" | grep -nE '自动|  m4|  m5|  mbp' | cut -d: -f1 | tr '\n' ' ')
m4l=$(printf '%s\n' "$s" | grep -n ' m4 ' | head -1 | cut -d: -f1); m5l=$(printf '%s\n' "$s" | grep -n ' m5 ' | head -1 | cut -d: -f1)
CHECKS=$((CHECKS + 1)); [ -n "$m4l" ] && [ -n "$m5l" ] && [ "$m4l" -lt "$m5l" ] || fail 'A: m4 (1 running) above m5 (3 running)' "$order"
key Down; key Down; key Down
has 'A: ↓↓↓ wraps past mbp, never onto it' "$(aline)" '› 自动'
hasnt 'A: mbp never highlighted' "$(aline)" '› mbp'
key Enter
# 「什么时候回收？」 (issue #1902): an issue's default highlighted, ↵ takes it
CHECKS=$((CHECKS + 1)); waitfor 5 '什么时候回收' || fail 'A: the reap question after 「开在哪」' "$(aline)"
has 'A: 合并后回收 highlighted for an issue' "$(aline)" '› 合并后回收'
key Enter
CHECKS=$((CHECKS + 1)); waitfor 8 '已在 m4 上开好，已切过去' bar || fail 'A: the bar says it switched' "$(bar | tail -c 400)"
has 'A: the bar said where it was opening' "$(bar)" '正在'
eq 'A: the place ran: repo, issue, --node auto' 'acme/web 42 --node auto' "$(tail -n1 "$LOG")"
eq 'A: the switch stepped into the new row' 'wid:U/issue-42' "$(tail -n1 "$VIEW")"
CHECKS=$((CHECKS + 1)); waitfor 5 'forty-two' screen || fail 'A: the new row is in the list' "$(screen)"
CHECKS=$((CHECKS + 1)); [ -z "$(askp)" ] || fail 'A: the question line outlived its last answer' "$(aline)"

# B. scratch → repo → where → m4
rows_reset; : > "$VIEW"
park scratch
CHECKS=$((CHECKS + 1)); waitfor 5 '新会话 → 选仓库' || fail 'B: `scratch` opens the repo menu' "$(aline)"
key Enter
CHECKS=$((CHECKS + 1)); waitfor 5 '开在哪' || fail 'B: a scratch goes straight to 「开在哪」' "$(aline)"
has 'B: it names a scratch' "$(aline)" '草稿'
key Down; key Enter
CHECKS=$((CHECKS + 1)); waitfor 5 '什么时候回收' || fail 'B: the reap question' "$(aline)"
has 'B: 做完就回收 highlighted for a scratch' "$(aline)" '› 做完就回收'
key Down; key Down; key Down; key Enter
sleep 1
has 'B: a scratch on m4, by its hostname' "$(tail -n1 "$LOG")" ' scratch --node mac-mini-m4.local'
has 'B: 常驻 rides along as --reap keep' "$(tail -n1 "$LOG")" '--reap keep'

# C. restore → repo → key → where
rows_reset; echo unknown > "$SCEN"; sleep 1.5; : > "$TTY"
park restore
CHECKS=$((CHECKS + 1)); waitfor 5 '新会话 → 选仓库' || fail 'C: `restore` opens the repo menu' "$(aline)"
key Enter
CHECKS=$((CHECKS + 1)); waitfor 5 '恢复›' || fail 'C: the key line' "$(aline)"
key i s s u e - 9; key Enter
CHECKS=$((CHECKS + 1)); waitfor 5 '开在哪' || fail 'C: 「开在哪」 after the key' "$(aline)"
key Enter
CHECKS=$((CHECKS + 1)); waitfor 5 'm4 还没回话' bar || fail 'C: an UNKNOWN says it has not answered' "$(bar | tail -c 400)"
has 'C: restore:issue-9' "$(tail -n1 "$LOG")" ' restore:issue-9 --node auto'

# D. the hub unreachable
n=$(wc -l < "$LOG"); sleep 1.5; : > "$TTY"
echo $(( $(date +%s) - 600 )) > "$FLEET_STATUS_G/hub_ok"
park new
CHECKS=$((CHECKS + 1)); waitfor 5 '入口连不上，暂时不能新建' bar || fail 'D: a stale hub refuses at once' "$(bar | tail -c 400)"
CHECKS=$((CHECKS + 1)); [ -z "$(askp)" ] || fail 'D: no menu' "$(aline)"
eq 'D: nothing run' "$n" "$(wc -l < "$LOG")"
hub_fresh; echo down > "$SCEN"; sleep 1.5; : > "$TTY"   # the word on the bar passes
park scratch; key Enter; key Enter; key Enter
CHECKS=$((CHECKS + 1)); waitfor 5 '入口连不上，暂时不能新建' bar || fail 'D: the place unreachable (exit 1) says the same' "$(bar | tail -c 400)"

# E. full
echo full > "$SCEN"; sleep 1.5; : > "$TTY"
park scratch; key Enter; key Enter; key Enter
CHECKS=$((CHECKS + 1)); waitfor 5 '开不了：m4: 满了 (6/6)' bar || fail 'E: the hub reason, as it said it' "$(bar | tail -c 400)"

# F. held elsewhere → y
echo held > "$SCEN"; : > "$VIEW"
park new; key Enter; key 7; key Enter; key Enter; key Enter
CHECKS=$((CHECKS + 1)); waitfor 5 '已在 m5 上跑' || fail 'F: HELD asks to switch' "$(aline)"
has 'F: …with y' "$(aline)" 'y 切过去'
key y
sleep .5
eq 'F: y stepped into the m5 row of #7' 'wid:U/issue-7' "$(tail -n1 "$VIEW")"

# G. the old refusal is gone from the view's strings
CHECKS=$((CHECKS + 1)); grep -q 'shell_local_only' "$BIN/fleet-sidebar.py" "$BIN/fleet-ui-lang.sh" && fail 'G: the 「这台电脑上没有 fleet」 refusal is still wired'

if [ "$FAIL" -eq 0 ]; then
  printf 'fleet-sidebar-place selftest: OK (%d checks)\n' "$CHECKS"; exit 0
fi
printf 'fleet-sidebar-place selftest: %d/%d FAILED\n' "$FAIL" "$CHECKS"; exit 1
