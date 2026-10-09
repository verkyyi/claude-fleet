#!/bin/bash
# fleet-quit-selftest.sh — 退出 fleet (issue #2349): `fleet quit` /
# fleet-shell.sh `quit`, `fleet status` (`running --say`), and `fleet claude`
# leaving nothing behind (bin/fleet-home-session.sh step 3).
#
#   A  `fleet status` with no client: 「客户端没在运行（`fleet` 进入）。」, exit 1 —
#      then the who line (#2577: 登录人 …（GitHub）· 这台电脑 …)
#   B  `fleet quit` with the client up — its server, its stage, a keeper, a hub
#      loop, an actions loop, a warm loop, a lease: every one of them gone, the
#      lease given back (`release --lease L1`) and its files removed; a pid file
#      naming a process that is NOT that loop kills nothing; the «machine» (a
#      tmux server standing for the sessions) untouched; the terminal says
#      「fleet 已退出；会话仍在 m4/m5 上运行，`fleet` 重新进入。」; `fleet status` then
#      says 「客户端没在运行」
#   C  `fleet quit` again: 「fleet 客户端没在运行。」, exit 0
#   D  from inside the client (⌘Q / prefix Q / the menus run it on its own
#      server): it goes on in the background and the server still goes
#   E  `fleet claude` (fleet-home-session.sh, the shell stubbed) in a terminal:
#      `running`, the client up unattached, `home-session … --no-stage`, then its
#      own view `solo <machine> <worker id>` — a client already running gets no
#      re-attach pass at all (its lease, layout, stage, where untouched), and
#      `quit --quiet --if-unattached` after the view only when the client was not
#      running before (and nobody attached it since); a LOCAL placement attaches
#      the client
#   F  the guard (#1931): `fleet quit` / `fleet status` / `fleet-shell.sh quit`
#      start no client; a bare `fleet-shell.sh` still does
#
# Every tmux call goes to a socket under a temp dir (a PATH shim for `-L`), the
# loops are bounded stand-ins (≤ 2 min each), the hub is a recorder. Exit 0 = pass.
# Drives: bin/fleet, bin/fleet-shell.sh, bin/fleet-home-session.sh,
# bin/fleet-ui-lang.sh, hooks/bash-guard.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
REAL_TMUX=''
_ifs=$IFS; IFS=:
for d in $PATH; do
  case "$d" in */tmux-shim) continue ;; esac
  [ -x "$d/tmux" ] && { REAL_TMUX="$d/tmux"; break; }
done
IFS=$_ifs
[ -n "$REAL_TMUX" ] || { printf 'fleet-quit selftest: tmux not installed — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-quit selftest: python3 absent — SKIP\n'; exit 0; }

W="$(mktemp -d /tmp/fq-st.XXXXXX)" || exit 2   # AF_UNIX paths stop at 104 bytes
PIDS=''
cleanup() {
  local p s
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  for s in "$W"/s/*; do [ -S "$s" ] && "$REAL_TMUX" -S "$s" kill-server 2>/dev/null; done
  rm -rf "$W"
}
trap cleanup EXIT
CHECKS=0; FAILS=0
eq()  { CHECKS=$((CHECKS + 1)); if [ "$2" = "$3" ]; then :; else FAILS=$((FAILS + 1)); printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$1" "$2" "$3"; fi; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) FAILS=$((FAILS + 1)); printf 'FAIL %s\n  got: %s\n  missing: %s\n' "$1" "$2" "$3" ;; esac; }

mkdir -p "$W/s" "$W/path" "$W/fake" "$W/conf" "$W/home"
cat > "$W/path/tmux" <<EOF
#!/bin/sh
if [ "\$1" = -L ]; then l=\$2; shift 2; exec $REAL_TMUX -S $W/s/"\$l" "\$@"; fi
exec $REAL_TMUX "\$@"
EOF
chmod +x "$W/path/tmux"
export PATH="$W/path:$PATH" HOME="$W/home" FLEET_CONF_DIR="$W/conf" FLEET_UI_LANG=zh \
       FLEET_SHELL_SESSION=fq FLEET_SHELL_CACHE="$W/cache" FLEET_CLIENT_LEASE_CMD="$W/lease.sh"
unset TMUX TMUX_PANE FLEET_CLIENT_LAYOUT
CL="$W/cache/tmp"
G="$CL/.claude-dash/global"
mkdir -p "$G" "$CL/warm"
cat > "$W/lease.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> $W/lease.log
printf 'released\t%s\n' "\${3:-}"
EOF
chmod +x "$W/lease.sh"
# the loops' stand-ins: named as the real ones, so their argv is what quit checks
for n in fleet-shell.sh fleet-hub-sessions.sh; do
  printf '#!/bin/bash\nfor i in $(seq 1 120); do sleep 1; done\n' > "$W/fake/$n"
done
printf 'import time\ntime.sleep(120)\n' > "$W/fake/fleet-client-actions.py"
T() { tmux -L fq "$@"; }
alive() { kill -0 "$1" 2>/dev/null; }
# up — the client as fleet-shell.sh leaves it: two servers, four loops, a lease
up() {
  T -f /dev/null new-session -d -s fq "sleep 600"
  tmux -L fq-stage -f /dev/null new-session -d -s fq-stage "sleep 600"
  bash "$W/fake/fleet-shell.sh" keeper fq & K=$!
  bash "$W/fake/fleet-hub-sessions.sh" --loop & H=$!
  python3 "$W/fake/fleet-client-actions.py" run --session fq & A=$!
  bash "$W/fake/fleet-shell.sh" warm fq & WM=$!
  sleep 120 & OTHER=$!
  PIDS="$PIDS $K $H $A $WM $OTHER"
  disown $K $H $A $WM $OTHER 2>/dev/null   # no job notices when quit stops them
  printf '%s\n' "$K" > "$CL/keeper.pid"; printf '%s\n' "$H" > "$G/hubsess.pid"
  printf '%s\n' "$A" > "$CL/actions.pid"; printf '%s\n' "$OTHER" > "$CL/warm/loop.pid"   # not the warm loop
  printf 'L1\n' > "$CL/client.lease"; printf '{}\n' > "$CL/client.where.json"
  printf '#node\037m5\nwid:F/w1\037m5\037\037\037\037working\nwid:F/w2\037m4\037\037\037\037idle\nwid:F/w3\037m5\037\037\037\037idle\n' > "$G/remote_fq"
  sleep 0.3
}

# --- A ---------------------------------------------------------------------------
out=$(sh "$BIN/fleet" status 2>&1); rc=$?
eq "A fleet status, no client: exit 1" "$rc" 1
eq "A …and says so" "$(printf '%s\n' "$out" | head -n 1)" '客户端没在运行（`fleet` 进入）。'
has "A …then who is signed in and where (#2577)" "$out" '（GitHub）· 这台电脑 '

# --- B ---------------------------------------------------------------------------
tmux -L fq-node -f /dev/null new-session -d -s fleet "sleep 600"   # the sessions on their machine
up
eq "B fleet status, client up: exit 0" "$(sh "$BIN/fleet" status >/dev/null 2>&1; echo $?)" 0
has "B …in the background" "$(sh "$BIN/fleet" status 2>&1)" '客户端在后台运行（`fleet quit` 退出）'
out=$(sh "$BIN/fleet" quit 2>&1); rc=$?
eq "B fleet quit: exit 0" "$rc" 0
eq "B …the terminal's line" "$out" 'fleet 已退出；会话仍在 m4/m5 上运行，`fleet` 重新进入。'
eq "B the client's server gone" "$(T has-session -t =fq 2>/dev/null; echo $?)" 1
eq "B its stage gone" "$(tmux -L fq-stage has-session 2>/dev/null; echo $?)" 1
sleep 0.3
eq "B the keeper gone" "$(alive "$K" && echo alive || echo gone)" gone
eq "B the hub loop gone" "$(alive "$H" && echo alive || echo gone)" gone
eq "B the actions loop gone" "$(alive "$A" && echo alive || echo gone)" gone
eq "B a pid file naming another process kills nothing" "$(alive "$OTHER" && echo alive || echo gone)" alive
eq "B the lease given back" "$(cat "$W/lease.log" 2>/dev/null)" 'release --lease L1'
eq "B the lease's files gone" "$(ls "$CL"/client.lease "$CL"/client.where.json "$CL"/keeper.pid 2>/dev/null | wc -l | tr -d ' ')" 0
eq "B the sessions untouched" "$(tmux -L fq-node has-session -t =fleet 2>/dev/null; echo $?)" 0
kill "$WM" "$OTHER" 2>/dev/null
eq "B fleet status after: exit 1" "$(sh "$BIN/fleet" status >/dev/null 2>&1; echo $?)" 1

# --- C ---------------------------------------------------------------------------
out=$(sh "$BIN/fleet" quit 2>&1); rc=$?
eq "C fleet quit again: exit 0" "$rc" 0
eq "C …nothing to quit" "$out" 'fleet 客户端没在运行。'

# --- D ---------------------------------------------------------------------------
: > "$W/lease.log"
up
T run-shell -b "env PATH='$PATH' HOME='$HOME' FLEET_CONF_DIR='$W/conf' FLEET_SHELL_CACHE='$W/cache' FLEET_CLIENT_LEASE_CMD='$W/lease.sh' bash '$BIN/fleet-shell.sh' quit fq >/dev/null 2>&1"
n=0; while T has-session -t =fq 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
eq "D from inside the client: its server goes all the same" "$(T has-session -t =fq 2>/dev/null; echo $?)" 1
n=0; while alive "$K" && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
eq "D …and its keeper" "$(alive "$K" && echo alive || echo gone)" gone
eq "D …the lease given back" "$(cat "$W/lease.log" 2>/dev/null)" 'release --lease L1'
kill "$H" "$A" "$WM" "$OTHER" 2>/dev/null

# --- E ---------------------------------------------------------------------------
# the shell stubbed: one line per call; `running` answers $RUNNING, `home-session`
# the placement line $HLINE
cat > "$W/stubshell.sh" <<EOF
#!/bin/bash
printf '[%s]\n' "\$*" >> $W/stub.log
case "\${1:-}" in
  running) exit "\$(cat $W/running)" ;;
  home-session) cat $W/hline ;;
esac
exit 0
EOF
chmod +x "$W/stubshell.sh"
fhs() {   # in a terminal (fleet-home-session.sh wants one), to the end
  : > "$W/stub.log"; rm -f "$W/done"
  tmux -L fq-term -f /dev/null new-session -d -s t -x 100 -y 20 \
    "FLEET_HOME_SHELL=$W/stubshell.sh bash $BIN/fleet-home-session.sh claude hi; touch $W/done; sleep 30"
  n=0; while [ ! -e "$W/done" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  tmux -L fq-term kill-server 2>/dev/null
  sed "s#--body-file [^ ]*#--body-file B#" "$W/stub.log" | tr -d '\n'
}
printf '1\n' > "$W/running"
printf 'REMOTE m5 place done 1234-ab/fid-9\n' > "$W/hline"
eq "E no client before: its own view, then the client goes again" "$(fhs)" \
  '[running][][home-session claude --body-file B --new --no-stage][solo m5 1234-ab/fid-9][quit --quiet --if-unattached]'
printf '0\n' > "$W/running"
eq "E a client already running: no re-attach pass on it, the view, and it stays" "$(fhs)" \
  '[running][home-session claude --body-file B --new --no-stage][solo m5 1234-ab/fid-9]'
printf 'LOCAL host\t@7 x\n' > "$W/hline"
eq "E no hub (a LOCAL row): the client, as before" "$(fhs)" \
  '[running][home-session claude --body-file B --new --no-stage][]'

# --if-unattached (fleet claude's own quit): a client someone attached meanwhile stays
T -f /dev/null new-session -d -s fq "sleep 600"
tmux -L fq-term -f /dev/null new-session -d -s t -x 80 -y 20 "env -u TMUX $REAL_TMUX -S $W/s/fq attach -t fq"
n=0; while [ -z "$(T list-clients 2>/dev/null)" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
bash "$BIN/fleet-shell.sh" quit fq --quiet --if-unattached
eq "E --if-unattached: an attached client is left running" "$(T has-session -t =fq 2>/dev/null; echo $?)" 0
tmux -L fq-term kill-server 2>/dev/null; sleep 0.2
bash "$BIN/fleet-shell.sh" quit fq --quiet --if-unattached
eq "E --if-unattached: with no terminal on it, it goes" "$(T has-session -t =fq 2>/dev/null; echo $?)" 1

# --- F ---------------------------------------------------------------------------
g() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
        | env -u FLEET_HUB FLEET_WORKER_CRED=fwc1.x FLEET_HEAVY=0 FLEET_LIB=/nonexistent python3 "$ROOT/hooks/bash-guard.py" >/dev/null 2>&1
      echo $?; }
eq "F fleet quit starts no client" "$(g 'fleet quit')" 0
eq "F fleet status starts no client" "$(g 'fleet status')" 0
eq "F fleet-shell.sh quit starts no client" "$(g 'bash bin/fleet-shell.sh quit fq')" 0
eq "F a bare fleet-shell.sh still does" "$(g 'bash bin/fleet-shell.sh')" 2

printf 'fleet-quit selftest: %s checks, %s failed\n' "$CHECKS" "$FAILS"
[ "$FAILS" = 0 ]
