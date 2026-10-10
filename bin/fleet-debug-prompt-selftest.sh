#!/usr/bin/env bash
# fleet-debug-prompt-selftest.sh — bin/fleet-debug-prompt.sh (issue #2894, EPIC
# #2889 C5): after the third failure in half an hour the client asks whether the
# hub should take a look.
#
#   A  a fake hub refuses the placement (fleet-home-session.sh, its shell seam)
#      three times → only the third asks; y runs `fleet-debug report --note
#      <the last failure>` and passes its words on; the book is emptied
#   B  no terminal → never asked (the book still counts)
#   C  n → says how to run it later; asked again only 24 hours on
#   D  FLEET_DEBUG_PROMPT=0 · inside the client (FLEET_SHELL=1) · no debug
#      ticket → never asked; three failures spread past 30 minutes → not asked;
#      a success empties the book
#   E  `fleet login` failing three times (a fake fleet-login.py) → asked, the
#      login's exit code kept; FLEET_DEBUG_PROMPT=0 → nothing recorded
#   F  fleet-connect.py: a person's connect that cannot reach the hub is
#      written down (the reason with it); `--print` / `--pick` never are
#   G  the right pane's reconnect page (fleet-remote-view.sh run --shell, on an
#      isolated tmux socket) stuck past FLEET_DEBUG_STALL_SECS says 「按 d 让远端
#      看一眼」; d runs the report from there
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/fdprompt.XXXXXX")" || exit 2
T="$(cd "$T" && pwd -P)"
SOCK="$T/tmux.sock"
REAL_TMUX=''
trap '[ -n "$REAL_TMUX" ] && "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$T"' EXIT
fails=0
ok()  { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
has()   { case $2 in *"$3"*) ok "$1" ;; *) bad "$1 — wanted «$3» in: $(printf '%s' "$2" | tr '\n' '|' | cut -c1-400)" ;; esac; }
hasnt() { case $2 in *"$3"*) bad "$1 — «$3» should not be in: $(printf '%s' "$2" | tr '\n' '|' | cut -c1-400)" ;; *) ok "$1" ;; esac; }
eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1 — wanted «$2», got «$3»"; }

export FLEET_UI_LANG=zh HOME="$T/home"
mkdir -p "$HOME" "$T/conf"
export FLEET_CONF_DIR="$T/conf"
unset FLEET_SHELL FLEET_DEBUG_PROMPT FLEET_SHELL_CACHE FLEET_CLIENT_LOG_DIR
printf 'fdt1.eyJpZCI6InQxIn0.c2ln\n' > "$FLEET_CONF_DIR/debug-ticket"

# the report fleet-debug would send: its arguments kept, its words printed
cat > "$T/fake-debug" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/debug.calls"
echo 'fleet-debug · 已上传'
echo '  https://hub.example/s/abc123'
EOF
chmod +x "$T/fake-debug"
export FLEET_DEBUG_CMD="$T/fake-debug"
P="$BIN/fleet-debug-prompt.sh"
fresh() {   # a new cache: an empty book, nothing declined
  export FLEET_SHELL_CACHE="$T/cache.$1"
  rm -rf "$FLEET_SHELL_CACHE"; rm -f "$T/debug.calls"
}
book() { cat "$FLEET_SHELL_CACHE/debug-fails" 2>/dev/null; }
nbook() { book | awk 'END { print NR }'; }

# --- A: the placement refused three times, through fleet-home-session.sh -----
cat > "$T/fake-shell.sh" <<'EOF'
#!/bin/bash
# fleet-shell.sh's seam: the client starts; the hub refuses the session
case "${1:-}" in
  home-session) echo 'fleet claude: 没有机器能开 — macmini: load 1.22/core > 0.8' >&2; exit 4 ;;
esac
exit 0
EOF
chmod +x "$T/fake-shell.sh"
fresh A
home() {   # one `fleet claude`, answered with $1
  printf '%s\n' "$1" | FLEET_HOME_SHELL="$T/fake-shell.sh" FLEET_SHELL_NO_ATTACH=1 FLEET_DEBUG_PROMPT_TTY=1 \
    bash "$BIN/fleet-home-session.sh" claude 2>&1
}
o1=$(home y); rc1=$?
o2=$(home y)
eq 'A: the placement keeps its own exit code' 4 "$rc1"
hasnt 'A: the first failure asks nothing' "$o1" '要不要让远端帮你看一眼'
hasnt 'A: the second failure asks nothing' "$o2" '要不要让远端帮你看一眼'
eq 'A: two failures in the book' 2 "$(nbook)"
has 'A: a line is time · action · code' "$(book | tail -n 1)" "$(printf '\tplace\t4\t')"
o3=$(home y)
has 'A: the third failure asks' "$o3" '连了 3 次都没成。要不要让远端帮你看一眼？'
has 'A: it says what goes and what does not' "$o3" '不含密码、令牌、私钥'
has 'A: y passes the report on (the short link)' "$o3" 'https://hub.example/s/abc123'
has 'A: y ran fleet-debug report --note' "$(cat "$T/debug.calls" 2>/dev/null)" 'report --note'
has 'A: the note is the last failure' "$(cat "$T/debug.calls" 2>/dev/null)" 'place exit 4'
eq 'A: a sent report empties the book' 0 "$(nbook)"

# --- B: no terminal -------------------------------------------------------------
fresh B
for _ in 1 2 3; do o=$(sh "$P" after place 1 < /dev/null 2>&1); done
hasnt 'B: no terminal, never asked' "$o" '要不要'
eq 'B: the book still counts' 3 "$(nbook)"
[ -e "$T/debug.calls" ] && bad 'B: no report without a terminal' || ok 'B: no report without a terminal'

# --- C: n, and the 24 hours -----------------------------------------------------
fresh C
now=2000000000
ask() { printf '%s\n' "$1" | FLEET_DEBUG_PROMPT_TTY=1 FLEET_DEBUG_PROMPT_NOW=$now sh "$P" after "$2" 1 2>&1; }
ask n login >/dev/null; ask n login >/dev/null; o=$(ask n login)
has 'C: the third asks' "$o" '要不要让远端帮你看一眼'
has 'C: n says how to run it later' "$o" '需要时随时跑：fleet-debug report'
[ -e "$T/debug.calls" ] && bad 'C: n sends nothing' || ok 'C: n sends nothing'
now=$(( now + 3600 )); o=$(ask n login)
hasnt 'C: an hour after n, not asked again' "$o" '要不要'
now=$(( now + 86400 )); ask n login >/dev/null; ask n login >/dev/null; o=$(ask y login)
has 'C: past 24 hours it asks again' "$o" '要不要让远端帮你看一眼'

# --- D: the switches, the window, success -----------------------------------------
fresh D0
for _ in 1 2 3; do o=$(printf 'y\n' | FLEET_DEBUG_PROMPT=0 FLEET_DEBUG_PROMPT_TTY=1 sh "$P" after place 1 2>&1); done
hasnt 'D: FLEET_DEBUG_PROMPT=0 never asks' "$o" '要不要'
fresh D1
for _ in 1 2 3; do o=$(printf 'y\n' | FLEET_SHELL=1 FLEET_DEBUG_PROMPT_TTY=1 sh "$P" after connect 1 2>&1); done
hasnt 'D: inside the client (sidebar · stage · keeper) never asks' "$o" '要不要'
fresh D2
mv "$FLEET_CONF_DIR/debug-ticket" "$T/ticket.away"
for _ in 1 2 3; do o=$(printf 'y\n' | FLEET_DEBUG_PROMPT_TTY=1 sh "$P" after place 1 2>&1); done
hasnt 'D: no debug ticket (the hub has no remote debugging) never asks' "$o" '要不要'
sh "$P" can && bad 'D: can says no without a ticket' || ok 'D: can says no without a ticket'
mv "$T/ticket.away" "$FLEET_CONF_DIR/debug-ticket"
sh "$P" can && ok 'D: can says yes with a ticket' || bad 'D: can says yes with a ticket'
fresh D3
now=2000000000
for d in 0 1000 2000; do
  o=$(printf 'y\n' | FLEET_DEBUG_PROMPT_TTY=1 FLEET_DEBUG_PROMPT_NOW=$(( now + d )) sh "$P" after place 1 2>&1)
done
hasnt 'D: three failures spread past 30 minutes do not ask' "$o" '要不要'
sh "$P" after place 0
eq 'D: a success empties the book' 0 "$(nbook)"
fresh D4
mkdir -p "$FLEET_SHELL_CACHE/logs"
printf '2026-10-10T06:16:04Z\tplace\tm5\t-\t\trefused\tno machine can take it\n' > "$FLEET_SHELL_CACHE/logs/place.log"
sh "$P" fail place 1 < /dev/null
has 'D: no reason given → the client log’s last line' "$(book)" 'refused · no machine can take it'

# --- E: fleet login -------------------------------------------------------------------
fresh E
SB="$T/sbin"; mkdir -p "$SB"
for f in fleet fleet-debug-prompt.sh fleet-ui-lang.sh; do ln -s "$BIN/$f" "$SB/$f"; done
printf '#!/bin/sh\necho "fleet login: [SSL: CERTIFICATE_VERIFY_FAILED]" >&2\nexit 1\n' > "$SB/fleet-login.py"
chmod +x "$SB/fleet-login.py"
login() { printf '%s\n' "$1" | FLEET_DEBUG_PROMPT_TTY=1 FLEET_NODE_STATE="$T/nonode" sh "$SB/fleet" login 2>&1; }
login y >/dev/null; login y >/dev/null; o=$(login y); rc=$?
eq 'E: fleet login keeps its exit code' 1 "$rc"
has 'E: the third failed login asks' "$o" '要不要让远端帮你看一眼'
has 'E: y sends the report' "$(cat "$T/debug.calls" 2>/dev/null)" 'login exit 1'
fresh E2
printf 'y\n' | FLEET_DEBUG_PROMPT=0 FLEET_DEBUG_PROMPT_TTY=1 FLEET_NODE_STATE="$T/nonode" sh "$SB/fleet" login >/dev/null 2>&1
eq 'E: FLEET_DEBUG_PROMPT=0 records nothing (exec as before)' 0 "$(nbook)"

# --- F: fleet-connect.py --------------------------------------------------------------
fresh F
export FLEET_CLIENT_LOG_DIR="$T/clog"
python3 "$BIN/fleet-connect.py" --hub http://127.0.0.1:9 m5 < /dev/null > /dev/null 2>&1
eq 'F: a connect that cannot reach the hub is written down' 1 "$(nbook)"
has 'F: as connect' "$(book)" "$(printf '\tconnect\t')"
python3 "$BIN/fleet-connect.py" --hub http://127.0.0.1:9 --print m5 < /dev/null > /dev/null 2>&1
python3 "$BIN/fleet-connect.py" --hub http://127.0.0.1:9 --pick < /dev/null > /dev/null 2>&1
eq 'F: --print / --pick are never written down' 1 "$(nbook)"
unset FLEET_CLIENT_LOG_DIR

# --- G: the reconnect page's 「按 d」 ---------------------------------------------------
IFS=: read -r -a pdirs <<< "$PATH"
for d in ${pdirs[@]+"${pdirs[@]}"}; do
  case $d in *tmux-shim*) continue ;; esac
  [ -x "$d/tmux" ] && { REAL_TMUX="$d/tmux"; break; }
done
if [ -z "$REAL_TMUX" ]; then
  echo 'skip  G: no tmux'
else
  fresh G
  mkdir -p "$T/rv/tmp/warm"
  cat > "$T/rv/ssh" <<'EOF'
#!/bin/bash
for a in "$@"; do [ "$a" = -O ] && exit 1; done
echo 'ssh: connect to host m5 port 22: Connection refused' >&2
exit 255
EOF
  chmod +x "$T/rv/ssh"
  wid=00000000-0000-0000-0000-000000000000/issue-1
  "$REAL_TMUX" -S "$SOCK" -f /dev/null new-session -d -s rv -x 120 -y 20 \
    "env HOME=$HOME TMPDIR=$T/rv/tmp FLEET_CONF_DIR=$FLEET_CONF_DIR FLEET_SHELL_CACHE=$FLEET_SHELL_CACHE \
       FLEET_REMOTE_SSH_CMD=$T/rv/ssh FLEET_REMOTE_VIA_HUB=0 FLEET_SHELL_WARM=0 FLEET_UI_LANG=zh \
       FLEET_DEBUG_STALL_SECS=2 FLEET_DEBUG_CMD=$T/fake-debug \
       bash $BIN/fleet-remote-view.sh run --shell m5 $wid; sleep 30"
  seen=''
  for _ in $(seq 1 80); do
    "$REAL_TMUX" -S "$SOCK" capture-pane -p -t '=rv:' 2>/dev/null | grep -q '按 d 让远端看一眼' && { seen=1; break; }
    sleep 0.1
  done
  [ -n "$seen" ] && ok 'G: stuck past the bound, the page says 按 d 让远端看一眼' \
    || bad "G: no 按 d on the page: $("$REAL_TMUX" -S "$SOCK" capture-pane -p -t '=rv:' 2>/dev/null | grep . | tr '\n' '|')"
  "$REAL_TMUX" -S "$SOCK" send-keys -t '=rv:' d
  for _ in $(seq 1 50); do [ -s "$T/debug.calls" ] && break; sleep 0.1; done
  has 'G: d runs the report from the page' "$(cat "$T/debug.calls" 2>/dev/null)" 'report --note 正在连接 m5 卡住'
  for _ in $(seq 1 30); do
    "$REAL_TMUX" -S "$SOCK" capture-pane -p -t '=rv:' 2>/dev/null | grep -q 'hub.example/s/abc123' && break; sleep 0.1
  done
  has 'G: its link is on the page' "$("$REAL_TMUX" -S "$SOCK" capture-pane -p -t '=rv:' 2>/dev/null)" 'https://hub.example/s/abc123'
  "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null
fi

echo
[ "$fails" -eq 0 ] && { echo "fleet-debug-prompt-selftest: PASS"; exit 0; }
echo "fleet-debug-prompt-selftest: $fails FAIL"; exit 1
