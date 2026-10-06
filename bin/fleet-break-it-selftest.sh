#!/bin/bash
# fleet-break-it-selftest.sh — every known way to break the fleet, done for real
# in a sandbox, and the fleet putting itself back (issue #1786, EPIC #1776 C10).
#
# docs/BREAK-IT.md is the list: one row per way (方式 · 后果 · 自愈方式 · 演练).
# Every row's 演练 cell names a `drill_<id>` below, or says 登记：<ticket> for a
# way fixed elsewhere (registered, never drilled). The table and the drills are
# held in lockstep: a row with no drill, or a drill with no row, is a FAIL. A new
# way to break the fleet gets its row and its drill FIRST (red), then the fix.
#
# Each drill breaks the thing, waits for the recovery and asserts an upper bound
# on how long it took; the run prints one line per row:
#   PASS  <id>  <secs>s ≤<cap>s  <what came back>
#
# Node half — an isolated tmux server (-S socket under $WORK, killed at exit), a
# sandbox install, a fake agent and a fake claude:
#   session-exit / session-ctrl-c / session-killed   bin/fleet-session-wrap.sh
#   last-window                                     fleet_server_resident (fleet-up.sh)
#   kill-server / disk-full                         bin/fleet-restore.sh --auto, fleet-diskguard.sh --gate
#   wedged-socket                                   fleet_socket_heal (fleet-restore.sh, fleet-up.sh)
#   no-claude-on-path                               bin/fleet-claude.sh, fleet_find_tool
#   install-sync-killed                             bin/fleet-install-sync.sh (the tick lock)
# Client half — the real client (bin/fleet → fleet-shell.sh) on isolated -L
# sockets, an ssh shim for the far end, a python pty as the person's terminal:
#   client-kill-keys / client-pane-killed / sidebar-ctrl-c / nested-drop
#                                                   conf/tmux-shell.conf, fleet-sidebar.py,
#                                                   fleet-remote-view.sh
#   client-kill-server                              bin/fleet (run again)
#   hub-unreachable                                 bin/fleet, fleet-client-badge.sh
#   static-forward / proxy-orphan                   bin/fleet-remote-view.sh (run), fleet-shell.sh
#
# tmux / python3 absent → SKIP (exit 0). BREAK_KEEP=1 keeps the work dir.
# BREAK_ONLY="<id> <id>" runs only those drills (the lockstep lint always runs).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
DOC="$ROOT/docs/BREAK-IT.md"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-break-it: python3 absent — SKIP\n'; exit 0; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'fleet-break-it: tmux absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/brk.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
CSESS="brk$$"                                    # the client's socket label
cleanup() {
  local s
  for s in "$WORK"/sock-*; do [ -S "$s" ] && "$REAL_TMUX" -S "$s" kill-server 2>/dev/null; done
  for s in "$CSESS" "$CSESS-stage" "${CSESS}h" "${CSESS}h-stage"; do "$REAL_TMUX" -L "$s" kill-server 2>/dev/null; done
  pkill -f "fleet-shell.sh keeper $CSESS" 2>/dev/null
  pkill -f "$WORK/" 2>/dev/null
  [ -n "${BREAK_KEEP:-}" ] && { printf 'kept %s\n' "$WORK" >&2; return; }
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

now() { python3 -c 'import time; print("%.3f" % time.time())'; }
since() { python3 -c 'import sys, time; print("%.1f" % (time.time() - float(sys.argv[1])))' "$1"; }
le() { python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$1" "$2"; }
# until_ok <secs> <command…> — true as soon as the command is
until_ok() {
  local secs="$1" _; shift
  for _ in $(seq 1 $((secs * 10))); do "$@" && return 0; sleep 0.1; done
  "$@"
}

# ============================================================== the list ========
# rows: "<id>" for a drilled row, "@<text>" for a registered one
ROWS=$(python3 - "$DOC" <<'PY'
import re, sys
for line in open(sys.argv[1], encoding="utf-8"):
    if not line.startswith("| ") or line.startswith("| 方式") or line.startswith("|---"):
        continue
    cells = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip())[1:-1]]
    if len(cells) != 4 or not all(cells):
        print("!" + line.strip()); continue
    m = re.fullmatch(r"`([a-z0-9-]+)`", cells[3])
    if m: print(m.group(1))
    elif cells[3].startswith("登记："): print("@" + cells[3])
    else: print("!" + line.strip())
PY
)
LINT=0
lintfail() { LINT=$((LINT + 1)); printf 'FAIL  lint: %s\n' "$1"; }
[ -f "$DOC" ] || lintfail "docs/BREAK-IT.md is missing"
DRILLS=$(sed -n 's/^drill_\([a-z0-9_]*\)() *{.*/\1/p' "$0" | tr _ -)
IDS=''
NROWS=0
while IFS= read -r r; do
  [ -n "$r" ] || continue
  NROWS=$((NROWS + 1))
  case "$r" in
    '!'*) lintfail "a row is not 4 cells ending in \`<id>\` or 登记：<ticket>: ${r#!}" ;;
    '@'*) ;;
    *) printf '%s\n' "$DRILLS" | grep -qx -- "$r" || lintfail "row \`$r\` has no drill_${r//-/_} in this script"
       IDS="$IDS $r" ;;
  esac
done <<EOF
$ROWS
EOF
for d in $DRILLS; do
  case " $IDS " in *" $d "*) ;; *) lintfail "drill_${d//-/_} has no row in docs/BREAK-IT.md" ;; esac
done
[ "$NROWS" -ge 8 ] || lintfail "the list has $NROWS rows (the issue asks for at least 8)"
# The convention is written down where the next person will read it.
grep -q 'BREAK-IT.md' "$ROOT/CLAUDE.md" 2>/dev/null || lintfail "CLAUDE.md does not name docs/BREAK-IT.md"

# ======================================================= node: the sandbox =======
# A tmux shim pins every tmux call (bare, -L <label>) to $BREAK_SOCK.
mkdir -p "$WORK/tbin" "$WORK/wbin" "$WORK/home"
cat > "$WORK/tbin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "\$BREAK_SOCK" "\$@"
EOF
cat > "$WORK/tbin/claude" <<EOF
#!/bin/sh
printf '%s|%s\n' "\$PWD" "\$*" >> "$WORK/claude-argv"
printf '────────\n❯ \n────────\n'; exec sleep 600
EOF
chmod +x "$WORK/tbin/tmux" "$WORK/tbin/claude"
for f in fleet-session-wrap.sh fleet-session-page.py fleet_sleep_park.py; do ln -s "$BIN/$f" "$WORK/wbin/$f"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/recycled"\n' "$WORK" > "$WORK/wbin/session-end-hook.sh"
cat > "$WORK/fake-agent" <<'EOF'
#!/bin/bash
# The agent: logs its argv, stamps its session id as the hooks do, waits for
# `go`, then leaves the way $CTL/mode says.
printf '%s\n' "$*" >> "$CTL/argv"
tmux set-option -w -t "$TMUX_PANE" @cc_session_id SID-1
tmux set-option -w -t "$TMUX_PANE" @cc_agent claude
while [ ! -e "$CTL/go" ]; do sleep 0.05; done
rm -f "$CTL/go"
case "$(cat "$CTL/mode")" in rc0) exit 0 ;; rc130) exit 130 ;; kill) kill -9 $$ ;; esac
EOF
chmod +x "$WORK/wbin/session-end-hook.sh" "$WORK/fake-agent"

# The install --auto runs from: every bin/ file, fleet-up.sh a stub that builds
# the session the way the real one leaves it (fleet-up-selftest owns the real one).
mkdir -p "$WORK/inst/bin" "$WORK/econf/fleets/oc" "$WORK/emain"
for f in "$BIN"/* "$BIN"/.*.py; do [ -e "$f" ] && ln -s "$f" "$WORK/inst/bin/${f##*/}"; done
rm -f "$WORK/inst/bin/fleet-up.sh"
cat > "$WORK/inst/bin/fleet-up.sh" <<EOF
#!/bin/bash
tmux new-session -d -s oc -n home -c "$WORK/emain" 'exec sleep 600'
EOF
chmod +x "$WORK/inst/bin/fleet-up.sh"
for n in 1 2; do mkdir -p "$WORK/wt-$n"; done
printf 'FLEET_REPO=acme/widgets\nFLEET_MAIN=%s\nFLEET_BASE_BRANCH=main\n' "$WORK/emain" > "$WORK/econf/oc.conf"
write_map() {
  { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
    printf 'WIN\tissue-1\t%s\tsid-1\t1\tworking\t-\t-\n' "$WORK/wt-1"
    printf 'WIN\tissue-2\t%s\tsid-2\t2\tdone\t-\t-\n'    "$WORK/wt-2"
  } > "$WORK/econf/fleets/oc/restore.map"
}
# auto [VAR=val…] — one diskguard tick's pull-up, against the sandbox
auto() {
  env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/econf" FLEET_SKIP_GLOBAL_CONF=1 \
    BREAK_SOCK="$BREAK_SOCK" SHELL=/bin/sh FLEET_RESTORE_PROBE_SECS=2 FLEET_DISK_FLOOR_GB=0 \
    "$@" bash "$WORK/inst/bin/fleet-restore.sh" --auto >/dev/null 2>&1
}

nt() { "$REAL_TMUX" -S "$BREAK_SOCK" "$@"; }
o()  { nt display-message -p -t "$1" "#{$2}" 2>/dev/null; }

# wrapped <session> <win> <ctl> — a window running the wrapper as every spawner does
wrapped() {
  mkdir -p "$3"; : > "$3/argv"
  local cmd="env CTL='$3' FLEET_WRAP_LAUNCH='$WORK/fake-agent' FLEET_WRAP_FAST_FAIL=0 FLEET_UI_LANG=zh"
  cmd="$cmd '$WORK/wbin/fleet-session-wrap.sh' --agent claude 'the seed'; exec sleep 600"
  if nt has-session -t "$1" 2>/dev/null; then nt new-window -d -t "$1:" -n "$2" "$cmd"
  else nt -f /dev/null new-session -d -s "$1" -n "$2" -x 100 -y 30 "$cmd"; fi
}

# exit_drill <mode> <rc> <page headline> — the agent leaves; the window stays on
# the recovery page; ↵ resumes the same conversation.
exit_drill() {
  BREAK_SOCK="$WORK/sock-x$1"; local c="$WORK/x$1" t0 page_s
  wrapped sx w "$c" || { WHY="cannot start the isolated tmux server"; return 1; }
  until_ok 10 grep -q . "$c/argv" || { WHY="the agent never started"; return 1; }
  printf '%s' "$1" > "$c/mode"
  t0=$(now); : > "$c/go"
  until_ok 10 sh -c "'$REAL_TMUX' -S '$BREAK_SOCK' capture-pane -p -t sx:w | grep -qF '这个窗口不会关'" \
    || { WHY="no recovery page — the window shows: $(nt capture-pane -p -t sx:w 2>/dev/null | grep . | tail -2 | tr '\n' ' ')"; return 1; }
  page_s=$(since "$t0")
  nt list-windows -t sx -F '#{window_name}' 2>/dev/null | grep -qx w || { WHY="the window closed"; return 1; }
  [ "$(o sx:w @claude_state)" = exited ] || { WHY="@claude_state is [$(o sx:w @claude_state)], not exited"; return 1; }
  [ "$(o sx:w @wrap_exit_rc)" = "$2" ] || { WHY="exit status [$(o sx:w @wrap_exit_rc)], want $2"; return 1; }
  nt capture-pane -p -t sx:w | grep -qF -- "$3" || { WHY="the page does not say [$3]"; return 1; }
  nt send-keys -t sx:w Enter
  until_ok 10 sh -c "[ \$(grep -c . '$c/argv') = 2 ]" || { WHY="↵ relaunched nothing"; return 1; }
  [ "$(sed -n 2p "$c/argv")" = "--agent claude --resume SID-1" ] || { WHY="↵ ran [$(sed -n 2p "$c/argv")], not the same conversation"; return 1; }
  SECS=$(since "$t0"); WHAT="恢复页 ${page_s}s 出现，↵ 续上同一对话"
}

drill_session_exit()    { CAP=5; exit_drill rc0 0 '会话已退出'; }
drill_session_ctrl_c()  { CAP=5; exit_drill rc130 130 '会话已退出（按了 Ctrl+C）'; }
drill_session_killed()  { CAP=5; exit_drill kill 137 '会话被结束（信号 9）'; }

# home_back <old pid> — home holds a live shell other than <old pid>
home_back() {
  local p; p=$(nt display-message -p -t lw:home '#{pane_pid} #{pane_dead}' 2>/dev/null)
  [ -n "$p" ] && [ "${p% *}" != "$1" ] && [ "${p#* }" = 0 ]
}
# tmux ≤ 3.4 on a busy box can miss the exited shell's SIGCHLD: the pane reads
# dead, the shell stays a zombie, pane-died never fires (issue #1801; 3.5a/3.6a
# never did in 80 loaded runs). There the diskguard tick's fleet_home_heal is the
# rail; from 3.5 on the hook alone must bring it back.
tmux_lost_sigchld() {
  local v; v=$("$REAL_TMUX" -V 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\1 \2/')
  set -- $v
  [ -n "${2:-}" ] && { [ "$1" -lt 3 ] || { [ "$1" -eq 3 ] && [ "$2" -le 4 ]; }; }
}
drill_last_window() {
  CAP=5; BREAK_SOCK="$WORK/sock-lw"; local t0 hpid healed=''
  grep -q '^fleet_server_resident ' "$BIN/fleet-up.sh" || { WHY="fleet-up.sh no longer calls fleet_server_resident"; return 1; }
  sed -n '/^  --watch)/,/;;/p' "$BIN/fleet-diskguard.sh" | grep -q '^ *home_watch ' \
    || { WHY="the diskguard tick no longer runs home_watch (fleet_home_heal)"; return 1; }
  nt -f /dev/null new-session -d -s lw -n home -x 100 -y 30 'exec sh' || { WHY="cannot start the isolated tmux server"; return 1; }
  nt new-window -d -t lw: -n issue-9 'exec sleep 600'
  ( PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/lconf"; export PATH HOME FLEET_CONF_DIR BREAK_SOCK
    . "$BIN/fleet-lib.sh"; fleet_server_resident lw lw )
  t0=$(now)
  nt kill-window -t lw:issue-9                    # the last task ends …
  hpid=$(o lw:home pane_pid)
  nt send-keys -t lw:home 'exit' Enter            # … and home's shell exits
  if ! until_ok 5 home_back "$hpid"; then
    tmux_lost_sigchld || { WHY="home did not come back with a live shell ($("$REAL_TMUX" -V); pane: $(nt display-message -p -t lw:home 'pid=#{pane_pid} dead=#{pane_dead} status=#{pane_dead_status}' 2>&1))"; return 1; }
    # the missed SIGCHLD: one diskguard tick's home_watch, timed from the tick
    t0=$(now)
    healed=$( PATH="$WORK/tbin:$PATH" BREAK_SOCK="$BREAK_SOCK" FLEET_CONF_DIR="$WORK/lconf"; export PATH BREAK_SOCK FLEET_CONF_DIR
              . "$BIN/fleet-lib.sh"; fleet_home_heal lw lw )
    until_ok 5 home_back "$hpid" \
      || { WHY="home stayed dead, and the tick's fleet_home_heal did not respawn it [${healed}] (pane: $(nt display-message -p -t lw:home 'pid=#{pane_pid} dead=#{pane_dead}' 2>&1))"; return 1; }
  fi
  SECS=$(since "$t0")
  nt kill-session -t lw                           # and even no session at all …
  nt show-options -sv exit-empty >/dev/null 2>&1 || { WHY="the server died with its last session"; return 1; }
  WHAT="home 重开 shell，没有会话时服务器也还在${healed:+（tmux 漏了 SIGCHLD，节拍补救；节拍 60s 另计）}"
}

drill_kill_server() {
  CAP=20; BREAK_SOCK="$WORK/sock-oc"; local t0 wins
  sed -n '/^restore_watch()/,/^}/p' "$BIN/fleet-diskguard.sh" | grep -q 'fleet-restore.sh.*--auto' \
    || { WHY="the diskguard tick's restore_watch no longer runs fleet-restore.sh --auto"; return 1; }
  write_map; rm -f "$WORK/claude-argv"
  auto; nt has-session -t oc 2>/dev/null || { WHY="the sandbox fleet never came up"; return 1; }
  write_map
  nt kill-server                                  # the break
  rm -f "$WORK/claude-argv"
  t0=$(now)
  auto                                            # one diskguard tick
  until_ok "$CAP" nt has-session -t oc 2>/dev/null || { WHY="--auto did not bring it back: $(tail -3 "$WORK/econf/restore/restore.log" 2>/dev/null | tr '\n' ' ')"; return 1; }
  wins=$(nt list-windows -t oc -F '#{window_name}' | sort | tr '\n' ' ')
  [ "$wins" = "home issue-1 " ] || { WHY="came back with [$wins], want the unfinished one only"; return 1; }
  until_ok "$CAP" grep -q -- '--resume sid-1' "$WORK/claude-argv" 2>/dev/null || { WHY="issue-1 did not resume its conversation"; return 1; }
  SECS=$(since "$t0"); WHAT="下一拍拉起，只回来没做完的 issue-1（节拍 60s 另计）"
}

drill_disk_full() {
  CAP=20; BREAK_SOCK="$WORK/sock-oc"; local t0
  nt kill-server 2>/dev/null; write_map
  auto FLEET_DISK_FLOOR_GB=999999                 # the disk is "full"
  nt has-session -t oc 2>/dev/null && { WHY="--auto restored onto a full disk"; return 1; }
  grep -q 'held: disk below floor' "$WORK/econf/restore/restore.log" 2>/dev/null || { WHY="the hold left no log line"; return 1; }
  write_map
  t0=$(now)
  auto                                            # space freed: the next tick
  until_ok "$CAP" nt has-session -t oc 2>/dev/null || { WHY="space freed, still not restored"; return 1; }
  SECS=$(since "$t0"); WHAT="盘满时只记 held 不拉起，腾出空间后下一拍拉起"
}

# wedged-socket (issue #1729): the server is told to exit while one client never
# answers (an attach from a frozen ssh); it lives on, dropping every new client, so
# every tmux call on the label says `server exited unexpectedly`. -L <label> under
# a sandbox TMUX_TMPDIR, so fleet_socket_path resolves to this drill's socket.
drill_wedged_socket() {
  CAP=20; local tt="$WORK/tt" t0 out
  mkdir -p "$tt/tmux-$(id -u)"; chmod 700 "$tt/tmux-$(id -u)"
  BREAK_SOCK="$tt/tmux-$(id -u)/oc"
  write_map
  auto TMUX_TMPDIR="$tt"; nt has-session -t oc 2>/dev/null || { WHY="the sandbox fleet never came up"; return 1; }
  python3 -c 'import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(120)' "$BREAK_SOCK" &
  local pin=$!
  sleep 0.3
  write_map
  nt kill-server                                  # the break: told to exit, pinned alive
  sleep 0.3
  out=$(nt list-sessions 2>&1)
  case "$out" in *'server exited unexpectedly'*) ;; *) kill "$pin" 2>/dev/null; WHY="the break did not wedge the socket: [$out]"; return 1 ;; esac
  rm -f "$WORK/claude-argv"
  t0=$(now)
  auto TMUX_TMPDIR="$tt"                          # one diskguard tick
  until_ok "$CAP" nt has-session -t oc 2>/dev/null \
    || { kill "$pin" 2>/dev/null; WHY="--auto did not bring it back: $(tail -3 "$WORK/econf/restore/restore.log" 2>/dev/null | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  kill "$pin" 2>/dev/null
  grep -q 'cleared stale socket' "$WORK/econf/restore/restore.log" 2>/dev/null || { WHY="the clear left no restore.log line"; return 1; }
  grep -q "	oc	fleet: cleared stale socket" "$WORK/econf/socket-heal.log" 2>/dev/null || { WHY="no socket-heal.log row for the doctor"; return 1; }
  WHAT="下一拍清掉陈旧 socket 并拉起，restore.log 和 socket-heal.log 都记了一行"
}

drill_no_claude_on_path() {
  CAP=5; local t0 out
  mkdir -p "$WORK/phome/.local/bin"
  printf '#!/bin/sh\necho "found-claude $*"\n' > "$WORK/phome/.local/bin/claude"; chmod +x "$WORK/phome/.local/bin/claude"
  t0=$(now)
  out=$(env -i HOME="$WORK/phome" PATH=/usr/bin:/bin FLEET_CONF_DIR="$WORK/pconf" FLEET_MOD=0 FLEET_AGENT_CFG=0 \
        bash "$BIN/fleet-claude.sh" --version 2>&1)
  case "$out" in "found-claude "*"--version") ;; *) WHY="PATH=/usr/bin:/bin: [$out]"; return 1 ;; esac
  SECS=$(since "$t0"); WHAT="PATH=/usr/bin:/bin 也找到 ~/.local/bin/claude"
}

# install-sync SIGKILLed mid-tick (launchctl kickstart -k): its trap never runs and
# the lock stays; the next tick must take a dead holder's lock over (issue #1691).
drill_install_sync_killed() {
  CAP=20; local t0 d="$WORK/isync" pid
  mkdir -p "$d/conf" "$d/home"
  (
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/install" 2>/dev/null
    mkdir -p "$d/install/bin" "$d/install/logs"
    printf 'echo "apply: ok"\n' > "$d/install/bin/fleet-install-apply.sh"
    printf 'while [ -f "%s/hold" ]; do sleep 0.1; done; echo doctor >> "%s/doctor.log"\n' "$d" "$d" > "$d/install/bin/fleet-doctor.sh"
    printf 'exit 0\n' > "$d/install/bin/fleet-diskguard.sh"; chmod +x "$d"/install/bin/*
    printf 'logs/\n' > "$d/install/.gitignore"
    git -C "$d/install" add -A && git -C "$d/install" commit -qm one && git -C "$d/install" push -q origin master
    echo two > "$d/install/f"; git -C "$d/install" add -A; git -C "$d/install" commit -qm two
    git -C "$d/install" push -q origin master; git -C "$d/install" reset -q --hard HEAD~1
    git --git-dir="$d/origin.git" update-ref refs/tags/stable master
  ) >/dev/null 2>&1 || { WHY="sandbox install did not build"; return 1; }
  isync() { HOME="$d/home" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 \
            bash "$BIN/fleet-install-sync.sh" --root "$d/install"; }
  touch "$d/hold"; isync >"$d/tick1.out" 2>&1 &              # held in its baseline doctor run
  until_ok 10 grep -q updating "$d/tick1.out" || { WHY="the first tick never got to updating: $(tail -2 "$d/tick1.out")"; return 1; }
  pid=$(cat "$d/conf/global/install-sync.lock/pid" 2>/dev/null)
  kill -9 "$pid" 2>/dev/null || { WHY="no live holder pid in the lock [$pid]"; return 1; }
  wait 2>/dev/null; rm -f "$d/hold"                           # killed mid-tick: no trap ran
  [ -d "$d/conf/global/install-sync.lock" ] || { WHY="SIGKILL left no lock — nothing to drill"; return 1; }
  t0=$(now)
  isync >"$d/tick2.out" 2>&1
  grep -q 'another tick holds' "$d/tick2.out" && { WHY="the next tick skipped on a dead holder's lock: $(grep 'another tick' "$d/tick2.out")"; return 1; }
  [ "$(git -C "$d/install" rev-parse HEAD)" = "$(git --git-dir="$d/origin.git" rev-parse stable)" ] \
    || { WHY="the next tick did not follow stable: $(tail -2 "$d/tick2.out")"; return 1; }
  grep -q "holder pid=$pid is dead" "$d/tick2.out" || { WHY="the takeover left no log line naming pid=$pid"; return 1; }
  SECS=$(since "$t0"); WHAT="下一拍接管死掉那一跳（pid=${pid}）的锁，跟上 stable"
}

# ===================================================== client: the sandbox =======
CLIENT_UP=''
client_env() {
  export HOME="$WORK/chome" XDG_CONFIG_HOME="$WORK/chome/.config" XDG_CACHE_HOME="$WORK/chome/.cache"
  export FLEET_CONF_DIR="$WORK/chome/.config/claude-fleet" FLEET_SHELL_CACHE="$WORK/ccache"
  export FLEET_REMOTE_BIN="$BIN" FLEET_REMOTE_VIA_HUB=0 FLEET_SHELL_NO_ATTACH=1
  export FLEET_HUB_SESSIONS_LOOP_SECS=8 FLEET_HUB_SESSIONS_EVERY=1 FLEET_HUB_SESSIONS_WATCHED_EVERY=1
  export FLEET_SHELL_WARM=0 FLEET_CLIENT_ACTIONS=0 FLEET_UI_LANG=zh
  unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_SESSION FLEET_SHELL FLEET_HUB_SESSIONS_CLIENT FLEET_SIDEBAR_SOURCE
  unset CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_NODE_ALIASES FLEET_SHELL_STAGE
  export FLEET_HUB_URL=https://hub.example FLEET_REMOTE_SSH_CMD="$WORK/shim/ssh"
  export FLEET_HUB_SESSIONS_CMD="cat $WORK/sessions.json" FLEET_HUB_SESSIONS_USER=verk
  mkdir -p "$HOME/.ssh" "$FLEET_CONF_DIR"
}
client_setup() {
  [ -n "$CLIENT_UP" ] && return 0
  CLIENT_UP=1
  local SB="$WORK/sbin"; mkdir -p "$SB" "$WORK/conf" "$WORK/shim"
  for f in "$BIN"/*; do [ -f "$f" ] && ln -s "$f" "$SB/${f##*/}"; done
  for f in "$ROOT"/conf/*; do [ -f "$f" ] && ln -s "$f" "$WORK/conf/${f##*/}"; done
  rm -f "$SB/fleet-connect.py"
  cat > "$SB/fleet-connect.py" <<'EOF'
#!/usr/bin/env python3
import json, sys
if "--pick" in sys.argv:
    print(json.dumps({"machine": "m5", "hostname": "macmini", "reason": "last", "login": "verk",
                      "machines": [{"alias": "m5", "hostname": "macmini"}]}))
sys.exit(0)
EOF
  chmod +x "$SB/fleet-connect.py"
  # the far end: an attach paints a line and holds; killing its sleep is a drop
  cat > "$WORK/shim/ssh" <<EOF
#!/bin/bash
op=''
while [ \$# -gt 0 ]; do
  case "\$1" in -O) op=\$2; shift 2 ;; -S|-o|-L) shift 2 ;; -*) shift ;; *) break ;; esac
done
[ -n "\$op" ] && exit 1
case "\$*" in
  *" attach "*) printf 'FAR-END-SESSION\n'; echo \$\$ > "$WORK/attach.pid"; sleep 600 & wait \$!; exit 255 ;;
  *" watch "*|*" serve "*) sleep 600 ;;
esac
exit 0
EOF
  chmod +x "$WORK/shim/ssh"
  printf '{"sessions": [], "nodes": [{"machine_name": "macmini", "availability": "online", "sessions": 0, "observed_at": "2026-10-06T10:00:00Z"}]}\n' > "$WORK/sessions.json"
}
# client_start <socket label> [VAR=val…] — `fleet`, as the person types it
client_start() {
  local s="$1"; shift
  # shellcheck disable=SC2163  # "$@" are VAR=val words, exported as given
  ( client_env; export FLEET_SHELL_SESSION="$s"; [ $# -gt 0 ] && export "$@"
    "$WORK/sbin/fleet" >"$WORK/up-$s.out" 2>"$WORK/up-$s.err" )
  [ "$(cat "$WORK/up-$s.out" 2>/dev/null)" = "$s" ]
}
# attached <socket label> <secs> — a terminal attaches (the hooks draw the frame
# on attach); true once home has its list and a live right pane
attached() {
  python3 - "$REAL_TMUX" "$1" "$2" <<'PY'
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time
tmux, sess, secs = sys.argv[1], sys.argv[2], float(sys.argv[3])
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM="xterm-256color", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
    os.environ.pop("TMUX", None)
    os.execvp(tmux, [tmux, "-L", sess, "attach-session", "-t", "=" + sess])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
def whole():
    out = subprocess.run([tmux, "-L", sess, "list-panes", "-t", "=" + sess + ":home", "-F",
                          "#{?@sidebar,L,R}#{pane_dead}"], capture_output=True, text=True).stdout.split()
    return sorted(out) == ["L0", "R0"]
ok, end = False, time.time() + secs
while time.time() < end and not ok:
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        try: os.read(fd, 65536)
        except OSError: break
    ok = whole()
try: os.kill(pid, signal.SIGTERM)
except OSError: pass
sys.exit(0 if ok else 1)
PY
}

# The pty drive: the keys a person presses, run once for four rows.
DRIVEN=''
drive() {
  [ -n "$DRIVEN" ] && return 0
  DRIVEN=1
  client_setup
  client_start "$CSESS" || { printf 'client did not start: %s\n' "$(cat "$WORK/up-$CSESS.err")" > "$WORK/drive.err"; return 1; }
  python3 - "$REAL_TMUX" "$CSESS" "$WORK" > "$WORK/drive" 2>>"$WORK/drive.err" <<'PY'
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time
tmux, sess, work = sys.argv[1:4]
W, H = 200, 50
def t(*a, sock=sess):
    return subprocess.run([tmux, "-L", sock, *a], capture_output=True, text=True).stdout.strip()
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM="xterm-256color", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
    os.environ.pop("TMUX", None)
    os.execvp(tmux, [tmux, "-L", sess, "attach-session", "-t", "=" + sess])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", H, W, 0, 0))
def pump(secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: os.read(fd, 65536)
            except OSError: return
def key(data, wait=0.6):
    try: os.write(fd, data)
    except OSError: pass        # the client died: the frame checks say so
    pump(wait)
def until(secs, test):
    end = time.time() + secs
    while time.time() < end:
        if test(): return True
        pump(0.1)
    return test()
def frame():
    rows = [l.split() for l in t("list-panes", "-t", "=" + sess + ":home", "-F",
            "#{pane_id} #{pane_pid} #{?@sidebar,1,0} #{pane_dead}").splitlines()]
    lst = next((r for r in rows if r[2] == "1"), None)
    right = next((r for r in rows if r[2] != "1"), None)
    return (lst[0] if lst else "", lst[1] if lst else "", right[0] if right else "",
            right[1] if right else "", right[3] if right else "")
def stage():
    return t("list-windows", "-t", "=" + sess + "-stage", "-F", "x", sock=sess + "-stage").count("x")
def whole():
    f = frame()
    return bool(f[0]) and bool(f[2]) and f[4] == "0"
def say(k, v):
    print("%s=%s" % (k, v)); sys.stdout.flush()
def kill_tree(p):
    subprocess.run(["pkill", "-9", "-P", p], capture_output=True)
    try: os.kill(int(p), signal.SIGKILL)
    except (OSError, ValueError): pass
try:
    say("up", "1" if until(15, lambda: frame()[0] != "") else "0")
    pump(1.0)
    s0 = stage()
    # client-kill-keys: prefix x + y, prefix & + y, right-click + X on the list,
    # the right pane and the status line
    t0 = time.time(); broke = []
    for tag, seq in (("prefix x", [b"\x02x", b"y"]), ("prefix &", [b"\x02&", b"y"])):
        for b in seq: key(b, 1.0)
        if not whole() or stage() != s0: broke.append(tag)
    for tag, col, row in (("右键侧栏", 5, 10), ("右键右侧", 120, 10), ("右键状态栏", 3, H)):
        key(b"\x1b[<2;%d;%dM" % (col, row), 0.2); key(b"\x1b[<2;%d;%dm" % (col, row), 0.4)
        key(b"X", 1.0); key(b"\x1b", 0.3)
        if not whole() or stage() != s0: broke.append(tag)
    say("keys_broke", ",".join(broke)); say("keys_secs", "%.1f" % (time.time() - t0))
    # sidebar-ctrl-c: ⌃c / ⌃\ / ⌃z with the keyboard on the list
    lst, lpid = frame()[:2]
    t0 = time.time()
    key(b"\x02E", 0.8)
    for b in (b"\x03", b"\x1c", b"\x1a"): key(b, 0.8)
    key(b"\x1b", 0.5); pump(1.0)
    f = frame()
    say("cc_same", "1" if f[0] == lst and f[1] == lpid else "0")
    say("cc_state", subprocess.run(["ps", "-o", "stat=", "-p", lpid], capture_output=True, text=True).stdout.strip())
    say("cc_secs", "%.1f" % (time.time() - t0))
    # client-pane-killed: kill -9 the list, then the right pane
    t0 = time.time(); kill_tree(lpid)
    say("list_back", "1" if until(5, lambda: frame()[0] != "" and frame()[1] != lpid) else "0")
    say("list_secs", "%.1f" % (time.time() - t0))
    rpid = frame()[3]
    t0 = time.time(); kill_tree(rpid)
    say("right_back", "1" if until(5, lambda: whole() and frame()[3] != rpid) else "0")
    say("right_secs", "%.1f" % (time.time() - t0))
    # nested-drop: the far end's connection ends
    try:
        apid = open(os.path.join(work, "attach.pid")).read().strip()
        subprocess.run(["pkill", "-9", "-P", apid], capture_output=True)
    except OSError:
        pass
    t0 = time.time()
    seen = until(5, lambda: "回车立即重连" in t("capture-pane", "-p", "-t", "=" + sess + "-stage:", sock=sess + "-stage"))
    say("drop_note", "1" if seen else "0"); say("drop_secs", "%.1f" % (time.time() - t0))
    if not seen:   # what the stage window shows instead — a red drill says why
        cap = t("capture-pane", "-p", "-t", "=" + sess + "-stage:", sock=sess + "-stage")
        say("drop_pane", " | ".join(l.strip() for l in cap.splitlines() if l.strip())[-400:] or "(no window)")
    tsw = t("list-panes", "-t", "=" + sess + "-stage:", "-F", "#{pane_id}", sock=sess + "-stage")
    t("send-keys", "-t", tsw, "C-c", sock=sess + "-stage"); pump(1.0)
    say("drop_cc_kept", "1" if stage() == s0 else "0")
finally:
    try: os.kill(pid, signal.SIGTERM)
    except OSError: pass
PY
}
r() { sed -n "s/^$1=//p" "$WORK/drive" 2>/dev/null | tail -n 1; }
driven() {
  drive || { WHY="the client did not start: $(head -3 "$WORK/drive.err")"; return 1; }
  [ "$(r up)" = 1 ] || { WHY="the client drew no list: $(head -3 "$WORK/drive.err")"; return 1; }
}

drill_client_kill_keys() {
  CAP=15; driven || return 1
  [ -z "$(r keys_broke)" ] || { WHY="the frame lost a pane after: $(r keys_broke)"; return 1; }
  SECS=$(r keys_secs); WHAT="prefix x / & / 三处右键 + X 之后侧栏、右侧、远端窗口都在"
}
drill_sidebar_ctrl_c() {
  CAP=10; driven || return 1
  [ "$(r cc_same)" = 1 ] || { WHY="⌃c / ⌃\\ / ⌃z replaced or ended the list"; return 1; }
  case "$(r cc_state)" in T*) WHY="⌃z stopped the list ($(r cc_state))"; return 1 ;; esac
  SECS=$(r cc_secs); WHAT="⌃c ⌃\\ ⌃z 之后还是同一个侧栏进程"
}
drill_client_pane_killed() {
  CAP=5; driven || return 1
  [ "$(r list_back)" = 1 ] || { WHY="kill -9 the list: no new list within 5 s"; return 1; }
  [ "$(r right_back)" = 1 ] || { WHY="kill -9 the right pane: not respawned within 5 s"; return 1; }
  SECS=$(python3 -c 'import sys; print(max(float(a) for a in sys.argv[1:]))' "$(r list_secs)" "$(r right_secs)")
  WHAT="侧栏 $(r list_secs)s、右侧 $(r right_secs)s 重开"
}
drill_nested_drop() {
  CAP=5; driven || return 1
  [ "$(r drop_note)" = 1 ] || { WHY="a dropped line does not say 回车立即重连 — the stage shows: $(r drop_pane)"; return 1; }
  [ "$(r drop_cc_kept)" = 1 ] || { WHY="⌃c in the wait closed the stage's window"; return 1; }
  SECS=$(r drop_secs); WHAT="断线后停在「回车立即重连」，⌃c 不关窗口"
}
drill_client_kill_server() {
  CAP=20; local t0
  driven || return 1
  "$REAL_TMUX" -L "$CSESS" kill-server 2>/dev/null           # the break
  "$REAL_TMUX" -L "$CSESS" has-session 2>/dev/null && { WHY="kill-server left the client up"; return 1; }
  t0=$(now)
  client_start "$CSESS" || { WHY="\`fleet\` again did not start: $(head -3 "$WORK/up-$CSESS.err")"; return 1; }
  attached "$CSESS" "$CAP" || { WHY="\`fleet\` again: no list + right pane"; return 1; }
  SECS=$(since "$t0"); WHAT="再敲一次 fleet，侧栏 + 右侧回来"
}
drill_hub_unreachable() {
  CAP=20; local t0 s="${CSESS}h" badge
  client_setup
  printf '#!/bin/bash\nexit 1\n' > "$WORK/hubdown"; chmod +x "$WORK/hubdown"
  t0=$(now)
  client_start "$s" FLEET_HUB_URL=http://127.0.0.1:9 FLEET_HUB_SESSIONS_CMD="$WORK/hubdown" FLEET_CLIENT_WHERE_CMD="$WORK/hubdown" \
    || { WHY="the client does not open with the hub out of reach: $(head -3 "$WORK/up-$s.err")"; return 1; }
  attached "$s" "$CAP" || { WHY="hub out of reach: no list + right pane"; return 1; }
  SECS=$(since "$t0")
  badge=$( client_env; FLEET_SHELL_SESSION="$s" FLEET_CLIENT_WHERE_CMD="$WORK/hubdown" FLEET_CLIENT_BADGE_TTL=0 \
           FLEET_CLIENT_BADGE_CACHE="$WORK/badge" bash "$BIN/fleet-client-badge.sh" cw=120 )
  case "$badge" in *入口连不上*) ;; *) WHY="the bar does not say 入口连不上: [$badge]"; return 1 ;; esac
  WHAT="客户端照常打开，状态栏写「入口连不上」"
}

# The proxy pane's `run` loop (fleet-remote-view.sh) against an ssh shim: a
# session on a shared master that re-asks the person's static `RemoteForward`
# (open-url.sh's 2226) is refused like ssh refuses it (issue #1775); an attach
# that never returns is what kept a closed pane's loop alive (issue #1704).
rv_shim() {
  mkdir -p "$WORK/rv/tmp/warm"
  cat > "$WORK/rv/ssh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$RV_LOG"
op='' ctl='' clear=''
for a in "$@"; do [ "$a" = ClearAllForwardings=yes ] && clear=1; done
while [ $# -gt 0 ]; do
  case "$1" in
    -O) op=$2; shift 2 ;;
    -o) case "$2" in ControlPath=*) ctl=${2#ControlPath=} ;; esac; shift 2 ;;
    -S) ctl=$2; mux=1; shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
if [ -n "$op" ]; then case "$op" in check) [ -S "$ctl" ]; exit $? ;; *) exit 0 ;; esac; fi
if [ -n "${mux:-}" ] && [ -z "$clear" ]; then   # the config's RemoteForward 2226, asked again
  echo 'mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 2226' >&2
  echo 'muxclient: master forward request failed' >&2
  exit 255
fi
case "$*" in *" attach"*) [ "${RV_HANG:-}" = 1 ] && { printf '%s\n' $$ > "$RV_DIR/attach.pid"; exec sleep 300; }; sleep 0.3 ;; esac
exit 0
SH
  chmod +x "$WORK/rv/ssh"
  python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$WORK/rv/tmp/warm/m9.sock" 2>/dev/null
  : > "$WORK/rv/ssh.log"; rm -f "$WORK/rv/attach.pid"
}
RVWID=00000000-0000-0000-0000-000000000000/issue-1
rv_env() {
  printf 'HOME=%s TMPDIR=%s FLEET_CONF_DIR=%s FLEET_REMOTE_SSH_CMD=%s RV_LOG=%s RV_DIR=%s FLEET_REMOTE_VIA_HUB=0' \
    "$WORK/rv" "$WORK/rv/tmp" "$WORK/rv/conf" "$WORK/rv/ssh" "$WORK/rv/ssh.log" "$WORK/rv"
}
drill_static_forward() {
  CAP=5; local t0 n
  rv_shim; t0=$(now)
  # shellcheck disable=SC2046  # rv_env is KEY=VALUE words on purpose (no spaces in $WORK)
  env $(rv_env) bash "$BIN/fleet-remote-view.sh" run --shell m9 "$RVWID" > "$WORK/rv/out" 2>&1 < /dev/null
  n=$(grep -c ' attach' "$WORK/rv/ssh.log")
  [ "$n" = 1 ] || { WHY="the attach on the warm master was refused and retried ($n attaches): $(tail -n 1 "$WORK/rv/out")"; return 1; }
  SECS=$(since "$t0"); WHAT="骑共享连接的会话不再重复要 2226，一次 attach 成功"
}
drill_proxy_orphan() {
  CAP=8; local t0 so="$WORK/sock-rv" run att _
  rv_shim
  "$REAL_TMUX" -S "$so" -f /dev/null new-session -d -s rv -x 80 -y 20 \
    "env $(rv_env) RV_HANG=1 bash $BIN/fleet-remote-view.sh run m9 $RVWID"
  "$REAL_TMUX" -S "$so" new-window -d -t rv: 'sleep 600'
  for _ in $(seq 1 50); do [ -s "$WORK/rv/attach.pid" ] && break; sleep 0.1; done
  att=$(cat "$WORK/rv/attach.pid" 2>/dev/null)
  run=$("$REAL_TMUX" -S "$so" display-message -p -t rv:0 '#{pane_pid}' 2>/dev/null)
  [ -n "$att" ] && [ -n "$run" ] || { WHY="the proxy's attach never came up"; return 1; }
  t0=$(now)
  "$REAL_TMUX" -S "$so" kill-pane -t rv:0                       # the break
  until_ok "$CAP" sh -c "! kill -0 $run 2>/dev/null && ! kill -0 $att 2>/dev/null" \
    || { kill -KILL "$run" "$att" 2>/dev/null; WHY="the pane is gone, its run loop / attach still live after ${CAP}s"; return 1; }
  SECS=$(since "$t0"); WHAT="窗格关掉，run 循环和它的 ssh 一起退出"
}

# ================================================================ run ===========
FAILS=$LINT; PASSES=0
printf 'fleet-break-it: %d rows in docs/BREAK-IT.md\n' "$NROWS"
while IFS= read -r r; do
  case "$r" in
    '@'*) printf 'REG   %-20s %s\n' '—' "${r#@}"; continue ;;
    '!'*|'') continue ;;
  esac
  if [ -n "${BREAK_ONLY:-}" ]; then case " $BREAK_ONLY " in *" $r "*) ;; *) continue ;; esac; fi
  fn="drill_${r//-/_}"
  type "$fn" >/dev/null 2>&1 || continue
  SECS='' CAP='' WHY='' WHAT=''
  if "$fn" && [ -n "$SECS" ] && le "$SECS" "$CAP"; then
    PASSES=$((PASSES + 1))
    printf 'PASS  %-20s %5ss ≤%ss  %s\n' "$r" "$SECS" "$CAP" "$WHAT"
  else
    FAILS=$((FAILS + 1))
    [ -n "$WHY" ] || WHY="recovered in ${SECS:-?}s, over the ${CAP}s bound"
    printf 'FAIL  %-20s %s\n' "$r" "$WHY"
  fi
done <<EOF
$ROWS
EOF
if [ "$FAILS" -gt 0 ]; then
  printf 'fleet-break-it selftest: %d FAILED, %d passed\n' "$FAILS" "$PASSES" >&2
  [ -s "$WORK/drive.err" ] && sed -n '1,10p' "$WORK/drive.err" >&2
  exit 1
fi
printf 'fleet-break-it selftest: OK (%d drills green)\n' "$PASSES"
