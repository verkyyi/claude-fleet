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
#   session-ctrl-z                                  bin/fleet-session-wrap.sh (the TSTP guard)
#   resume-fails-fast / codex-no-id                 bin/fleet-session-wrap.sh, fleet-session-page.py
#   merged-then-commit / q-releases-claim           bin/session-end-hook.sh --recycle, fleet_reap_ok
#   last-window                                     fleet_server_resident (fleet-up.sh)
#   kill-server / disk-full                         bin/fleet-restore.sh --auto, fleet-diskguard.sh --gate
#   wedged-socket                                   fleet_socket_heal (fleet-restore.sh, fleet-up.sh)
#   no-claude-on-path                               bin/fleet-claude.sh, fleet_find_tool
#   window-renamed                                  fleet_win_role (fleet-lib.sh), fleet-restore.sh
#   break-pane                                      bin/fleet-window-carry.sh (conf/tmux-attention.conf hook)
#   install-sync-killed                             bin/fleet-install-sync.sh (the tick lock)
#   personal-tmux-conf                              conf/tmux-fleet-server.conf, fleet_server_new_session,
#                                                   fleet_tmuxconf_check, reapply-tmux-attention.sh
#   personal-hook-hangs / personal-hook-errors      bin/fleet-hook-personal.sh (timeout, strikes)
#   personal-mcp-missing / personal-mcp-over-default / personal-cache-truncated
#                                                   bin/fleet-agent-team.py (personal_layer), fleet-claude.sh, fleet-codex.sh
#   personal-breaks-session                         bin/fleet-session-wrap.sh, fleet-session-page.py (p), FLEET_PERSONAL=0
#   conf-keys-lost                                  bin/fleet-migrate-layout.sh, bin/fleet-conf.sh migrate
#                                                   (install-apply's layout + conf passes), fleet_conf_reserved
#   node-menu / node-prefix-keys                    conf/tmux-node-human.conf (via tmux-fleet-server.conf)
#   window-killed                                   bin/fleet-restore.sh --auto (pull-back), fleet_win_retire
#   loop-window-killed                              bin/fleet-restore.sh (loop re-arm), fleet_loop_mark.py rearm
#   fleet-down-confirm                              bin/fleet-down.sh (confirm, --yes), fleet-up.sh --undo,
#                                                   fleet-restore.sh --undo
# Client half — the real client (bin/fleet → fleet-shell.sh) on isolated -L
# sockets, an ssh shim for the far end, a python pty as the person's terminal:
#   client-kill-keys / client-pane-killed / sidebar-ctrl-c / nested-drop
#                                                   conf/tmux-shell.conf, fleet-sidebar.py,
#                                                   fleet-remote-view.sh
#   client-kill-server                              bin/fleet (run again)
#   hub-unreachable                                 bin/fleet, fleet-client-badge.sh
#   offline-list-moves                              tmux-dashboard-rows.sh (lost rows stay put), fleet-sidebar.py
#   static-forward / proxy-orphan                   bin/fleet-remote-view.sh (run), fleet-shell.sh
#   reconnect-stale-view / reconnect-mouse          bin/fleet-remote-view.sh (run, open, select)
#   view-reconnect-shared                           bin/fleet-remote-view.sh (attach, rv_prune)
#   client-files-swapped                            bin/fleet-client-update.sh (tick), fleet-shell.sh reload
# Shell half — a sandbox fleet on -L kf (TMUX_TMPDIR under $WORK), the real wrapper:
#   shell-kill-fleet                                bin/tmux-shim/tmux, fleet-session-wrap.sh, hooks/bash-guard.py
#   zsh-guard-fleet-label                           shell/cw.zsh tmux()
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
  for s in kf "kscr$$"; do TMUX_TMPDIR="$WORK/ktt" "$REAL_TMUX" -L "$s" kill-server 2>/dev/null; done
  for s in vrn vrc; do TMUX_TMPDIR="$WORK/vt" "$REAL_TMUX" -L "$s" kill-server 2>/dev/null; done
  for s in "$CSESS" "$CSESS-stage" "${CSESS}h" "${CSESS}h-stage" "${CSESS}o" "${CSESS}o-stage" "${CSESS}u" "${CSESS}u-stage"; do "$REAL_TMUX" -L "$s" kill-server 2>/dev/null; done
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
for f in fleet-session-wrap.sh fleet-session-page.py fleet_sleep_park.py fleet-hook-personal.sh; do ln -s "$BIN/$f" "$WORK/wbin/$f"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/recycled"\n' "$WORK" > "$WORK/wbin/session-end-hook.sh"
cat > "$WORK/fake-agent" <<'EOF'
#!/bin/bash
# The agent: logs its argv, stamps its session id as the hooks do, waits for
# `go`, then leaves the way $CTL/mode says.
# $CTL/agent = codex: a Codex session whose id was never recorded (#1842 ④).
# $CTL/resume-fails: a resume dies at once, the way a lost conversation does.
printf '%s\n' "$*" >> "$CTL/argv"
printf '%s\n' "${FLEET_PERSONAL:-}" >> "$CTL/personal"
# $CTL/hook: a personal hook's command, run the way Claude Code runs it (through
# bin/fleet-hook-personal.sh) four times, each answer's exit code logged.
if [ -s "$CTL/hook" ]; then
  for _ in 1 2 3 4; do
    echo '{}' | sh "$(dirname "$0")/wbin/fleet-hook-personal.sh" PreToolUse -- "$(cat "$CTL/hook")" >/dev/null 2>&1
    echo $? >> "$CTL/hook-rc"
  done
fi
agent=$(cat "$CTL/agent" 2>/dev/null); [ -n "$agent" ] || agent=claude
case " $* " in *" --resume "*|*" resume "*)
  [ -e "$CTL/resume-fails" ] && { printf 'Error: No conversation found with session ID: SID-1\n' >&2; exit 1; } ;;
esac
[ "$agent" = claude ] && tmux set-option -w -t "$TMUX_PANE" @cc_session_id SID-1
tmux set-option -w -t "$TMUX_PANE" @cc_agent "$agent"
echo $$ > "$CTL/pid"
while [ ! -e "$CTL/go" ]; do
  # `z`: suspend the way Claude Code does on Ctrl+Z — tear the UI down, hook
  # SIGCONT to bring it back, then SIGTSTP to the whole process group.
  if [ -e "$CTL/z" ]; then rm -f "$CTL/z" "$CTL/cont"; trap ': > "$CTL/cont"' CONT; kill -TSTP 0; fi
  sleep 0.05
done
rm -f "$CTL/go"
case "$(cat "$CTL/mode")" in rc0) exit 0 ;; rc130) exit 130 ;; kill) kill -9 $$ ;; esac
EOF
chmod +x "$WORK/wbin/session-end-hook.sh" "$WORK/fake-agent"

# The install --auto runs from: every bin/ file, fleet-up.sh a stub that builds
# the session the way the real one leaves it (fleet-up-selftest owns the real one);
# its --undo goes where the real one sends it (drill_fleet_down_confirm greps that).
mkdir -p "$WORK/inst/bin" "$WORK/econf/fleets/oc" "$WORK/emain"
for f in "$BIN"/* "$BIN"/.*.py; do [ -e "$f" ] && ln -s "$f" "$WORK/inst/bin/${f##*/}"; done
rm -f "$WORK/inst/bin/fleet-up.sh"
cat > "$WORK/inst/bin/fleet-up.sh" <<EOF
#!/bin/bash
[ "\${1:-}" = --undo ] && { shift; exec bash "$WORK/inst/bin/fleet-restore.sh" --undo "\$@"; }
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
  local cmd="env CTL='$3' FLEET_WRAP_LAUNCH='$WORK/fake-agent' FLEET_WRAP_FAST_FAIL=${WRAP_FAST:-0} FLEET_UI_LANG=zh"
  [ -n "${PERS_CONF:-}" ] && cmd="$cmd FLEET_CONF_DIR='$PERS_CONF'"
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

# Ctrl+Z (issue #1843). The pane's process group is orphaned (its leader, the
# pane's shell, is a session leader whose parent is the tmux server), so the
# kernel discards a SIGTSTP — nothing ever stops; but Claude Code / Codex suspend
# THEMSELVES on Ctrl+Z (UI torn down, a SIGCONT handler armed, `kill(0, SIGTSTP)`)
# and wait for a `fg` no shell will ever type. The drill does all three breaks: a
# Ctrl+Z on the pane's tty, a `kill -TSTP` aimed at the agent, and the agent's own
# suspend — within 1s it is running, resumed (its SIGCONT arrived), the window is
# not marked exited, and the guard left its stamp.
drill_session_ctrl_z() {
  CAP=1; BREAK_SOCK="$WORK/sock-xz"; local c="$WORK/xz" t0 pid st
  wrapped sz w "$c" || { WHY="cannot start the isolated tmux server"; return 1; }
  until_ok 10 test -s "$c/pid" || { WHY="the agent never started"; return 1; }
  pid=$(cat "$c/pid")
  nt send-keys -t sz:w C-z; kill -TSTP "$pid" 2>/dev/null
  sleep 0.2
  t0=$(now); : > "$c/z"
  until_ok "$CAP" test -e "$c/cont" \
    || { WHY="the agent suspended itself and nothing sent SIGCONT — it waits for an fg no shell will type"; return 1; }
  SECS=$(since "$t0")
  st=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$st" in ''|T*) WHY="the agent is [${st:-gone}] after Ctrl+Z, not running"; return 1 ;; esac
  [ "$(o sz:w @claude_state)" != exited ] || { WHY="the window went to exited"; return 1; }
  [ -n "$(o sz:w @wrap_ctrl_z)" ] || { WHY="the guard left no @wrap_ctrl_z stamp"; return 1; }
  WHAT="Ctrl+Z / kill -TSTP / 自挂起后 ${SECS}s 内收到 SIGCONT、照常运行"
}

# page_says <ctl-free text> — the recovery page on sx:w shows it
page_says() { "$REAL_TMUX" -S "$BREAK_SOCK" capture-pane -p -t sx:w 2>/dev/null | grep -qF -- "$1"; }

# A resume that dies within the fast-fail window (the conversation is gone, the
# login lapsed): the window stays on the page and says why (#1842 ③).
drill_resume_fails_fast() {
  CAP=6; BREAK_SOCK="$WORK/sock-rf"; local c="$WORK/rf" t0
  WRAP_FAST=1 wrapped sx w "$c" || { WHY="cannot start the isolated tmux server"; return 1; }
  until_ok 10 grep -q . "$c/argv" || { WHY="the agent never started"; return 1; }
  sleep 1.2; printf rc0 > "$c/mode"; : > "$c/go"     # a real session: it ran past the window
  until_ok 10 page_says '这个窗口不会关' || { WHY="no recovery page after the first exit"; return 1; }
  : > "$c/resume-fails"
  t0=$(now); nt send-keys -t sx:w Enter
  until_ok 10 sh -c "[ \$(grep -c . '$c/argv') = 2 ]" || { WHY="↵ relaunched nothing"; return 1; }
  until_ok 5 page_says '续上原对话失败' \
    || { WHY="no page after the failed resume — the window shows: $(nt capture-pane -p -t sx:w 2>/dev/null | grep . | tail -2 | tr '\n' ' ')"; return 1; }
  nt list-windows -t sx -F '#{window_name}' 2>/dev/null | grep -qx w || { WHY="the window closed"; return 1; }
  page_says '找不到这个对话' || { WHY="the page does not say why (找不到这个对话)"; return 1; }
  SECS=$(since "$t0"); WHAT="续对话 1 秒内失败，窗口留在恢复页写「找不到这个对话」"
}

# A Codex session with no recorded id: ↵ must never `resume --last` — in a shared
# Codex home that is somebody else's conversation (#1842 ④). The window's own
# thread (@codex_thread_id) is resumed; with none, a new conversation.
drill_codex_no_id() {
  CAP=8; BREAK_SOCK="$WORK/sock-cx"; local c="$WORK/cx" t0
  mkdir -p "$c"; printf codex > "$c/agent"
  wrapped sx w "$c" || { WHY="cannot start the isolated tmux server"; return 1; }
  until_ok 10 grep -q . "$c/argv" || { WHY="the agent never started"; return 1; }
  t0=$(now); printf rc0 > "$c/mode"; : > "$c/go"
  until_ok 10 page_says '这个窗口不会关' || { WHY="no recovery page"; return 1; }
  page_says '回车新开' || { WHY="the page does not say ↵ starts a new conversation"; return 1; }
  nt send-keys -t sx:w Enter
  until_ok 10 sh -c "[ \$(grep -c . '$c/argv') = 2 ]" || { WHY="↵ relaunched nothing"; return 1; }
  [ "$(sed -n 2p "$c/argv")" = "--agent codex" ] || { WHY="no id, no thread: ↵ ran [$(sed -n 2p "$c/argv")], not a new conversation"; return 1; }
  nt set-option -w -t sx:w @codex_thread_id T-9
  printf rc0 > "$c/mode"; : > "$c/go"
  until_ok 10 page_says '这个窗口不会关' || { WHY="no recovery page the second time"; return 1; }
  nt send-keys -t sx:w Enter
  until_ok 10 sh -c "[ \$(grep -c . '$c/argv') = 3 ]" || { WHY="↵ relaunched nothing the second time"; return 1; }
  [ "$(sed -n 3p "$c/argv")" = "--agent codex resume T-9" ] || { WHY="with the window's thread: ↵ ran [$(sed -n 3p "$c/argv")], not resume T-9"; return 1; }
  grep -q -- '--last' "$c/argv" && { WHY="a relaunch ran resume --last"; return 1; }
  SECS=$(since "$t0"); WHAT="无 id：↵ 新开；有本窗口 thread：续它；从不 resume --last"
}

# ---- the recovery page's q, on the real session-end-hook (#1842 ① ②) ----------
# A real git repo with an issue worktree, a fake gh (one merged PR, with its head
# sha) and a fake tmux that runs run-shell inline — session-end-hook-selftest's rig.
seh_rig() {
  local R="$WORK/seh"; [ -d "$R" ] && return 0
  mkdir -p "$R/fp" "$R/conf" "$R/proj"
  git init -q "$R/main"; git -C "$R/main" config user.email t@t; git -C "$R/main" config user.name t
  printf 'seed\n' > "$R/main/f"; git -C "$R/main" add f; git -C "$R/main" commit -qm seed
  git -C "$R/main" branch -M main
  cat > "$R/fp/tmux" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = run-shell ]; then shift; [ "${1:-}" = -b ] && shift; sh -c "$1"; exit 0; fi
case "$*" in
  *@issue*) printf '%s\n' "${ISS:-}" ;;
  *window_id*) printf '@9\n' ;;
  *session_name*) printf 's1\n' ;;
  *kill-window*) printf 'KILL\n' >> "$SEHLOG" ;;
esac
exit 0
FAKE
  cat > "$R/fp/gh" <<'FAKE'
#!/bin/bash
head=""; prev=""; for a in "$@"; do [ "$prev" = --head ] && head="$a"; prev="$a"; done
case "$*" in
  *"pr list"*headRefOid*) [ "$head" = "${GH_MERGED_HEAD:-}" ] && printf '%s\t%s\n' "$head" "$GH_MERGED_OID" ;;
  *"pr list"*headRefName*) [ "$head" = "${GH_MERGED_HEAD:-}" ] && printf '%s\n' "$head" ;;
  *"issue view"*) printf 'OPEN\n' ;;
  *issue*) printf 'GH %s\n' "$*" >> "$SEHLOG" ;;
esac
exit 0
FAKE
  chmod +x "$R/fp/tmux" "$R/fp/gh"
}
# seh_q <issue> [VAR=val…] — press q on issue-<N>'s recovery page
seh_q() {
  local R="$WORK/seh" n="$1"; shift
  env "$@" ISS="$n" SEHLOG="$R/log" PATH="$R/fp:$PATH" HOME="$WORK/home" \
    FLEET_REPO=acme/widgets FLEET_MAIN="$R/main" FLEET_BASE_BRANCH=main \
    FLEET_CONF_DIR="$R/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$R" \
    FLEET_HISTORY_LEDGER="$R/ledger" CLAUDE_PROJECTS_DIR="$R/proj" TMUX=fake TMUX_PANE=%1 \
    bash "$BIN/session-end-hook.sh" --recycle >/dev/null 2>&1
}

# Merged, then one more commit, then q: the branch and the commit stay (#1842 ①).
drill_merged_then_commit() {
  CAP=10; seh_rig; local R="$WORK/seh" wt="$WORK/seh/wt-7" t0 pr_head n
  git -C "$R/main" worktree add -q -b issue-7 "$wt" >/dev/null 2>&1
  printf 'a\n' > "$wt/a"; git -C "$wt" add a; git -C "$wt" commit -qm 'the PR'
  pr_head=$(git -C "$wt" rev-parse HEAD)
  printf 'b\n' > "$wt/b"; git -C "$wt" add b; git -C "$wt" commit -qm 'after the merge'   # the break
  : > "$R/log"; t0=$(now)
  seh_q 7 GH_MERGED_HEAD=issue-7 GH_MERGED_OID="$pr_head"
  SECS=$(since "$t0")
  git -C "$R/main" rev-parse -q --verify refs/heads/issue-7 >/dev/null || { WHY="q deleted branch issue-7 and the commit made after the merge"; return 1; }
  [ -d "$wt" ] || { WHY="q removed the worktree"; return 1; }
  n=$(git -C "$R/main" rev-list --count main..issue-7)
  [ "$n" = 2 ] || { WHY="branch issue-7 holds $n commits, want 2"; return 1; }
  grep -q 'issue close' "$R/log" && { WHY="q closed the issue as landed"; return 1; }
  WHAT="合并后再提交再按 q：分支 issue-7 仍在，$n 个提交（1 个在合并之后）"
}

# q on an unmerged issue: the claim goes, the issue can be dispatched again (#1842 ②).
drill_q_releases_claim() {
  CAP=10; seh_rig; local R="$WORK/seh" wt="$WORK/seh/wt-8" t0
  git -C "$R/main" worktree add -q -b issue-8 "$wt" >/dev/null 2>&1
  printf 'w\n' > "$wt/w"; git -C "$wt" add w; git -C "$wt" commit -qm 'half done'
  : > "$R/log"; t0=$(now)
  seh_q 8
  SECS=$(since "$t0")
  grep -q 'issue edit 8 .*--remove-assignee @me' "$R/log" || { WHY="q left the claim on #8 (gh: $(tr '\n' ' ' < "$R/log"))"; return 1; }
  [ -d "$wt" ] || { WHY="q removed the unmerged worktree"; return 1; }
  WHAT="未合并单按 q：认领放开、可再派，worktree 留着"
}

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

# window-renamed (issue #1844): a name is not an identity. Home renamed, a worker
# renamed `home`, a restored session renamed — every automatic reader still finds
# the right window, because it reads @fleet_role / @fleet_id, not the name.
# rlib <fn> <args…> — one fleet-lib call against this drill's sandbox server
rlib() {
  ( PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/rconf"; export PATH HOME FLEET_CONF_DIR BREAK_SOCK
    . "$BIN/fleet-lib.sh"; "$@" )
}
drill_window_renamed() {
  CAP=20; BREAK_SOCK="$WORK/sock-rn"; local t0 hw ww hpid wpid n wins
  for f in dash-issue-session.sh dash-raw-session.sh; do
    grep -q 'fleet_win_role_stamp .*worker' "$BIN/$f" || { WHY="$f no longer stamps its window @fleet_role worker"; return 1; }
  done
  nt -f /dev/null new-session -d -s rn -n home -x 100 -y 30 'exec sh' || { WHY="cannot start the isolated tmux server"; return 1; }
  ww=$(nt new-window -d -P -F '#{window_id}' -t rn: -n issue-3 'exec sleep 600')
  hw=$(o rn:home window_id)
  rlib fleet_server_resident rn rn                # as fleet-up leaves home
  rlib fleet_win_role_stamp "$ww" worker rn       # as a spawner leaves its window
  t0=$(now)
  nt rename-window -t "$hw" 'my shell'            # the break: home renamed …
  n=$(rlib fleet_session_count_for rn)
  [ "$n" = 1 ] || { WHY="with home renamed, the fleet counts $n sessions, want 1: it is no longer known as a fleet"; return 1; }
  nt rename-window -t "$ww" home                  # … and the worker named `home`
  n=$(rlib fleet_session_count_for rn)
  [ "$n" = 1 ] || { WHY="with the worker named home, the fleet counts $n sessions, want 1"; return 1; }
  # home's shell exits and tmux misses the SIGCHLD (#1801): the tick's heal
  nt set-hook -uw -t "$hw" pane-died
  hpid=$(o "$hw" pane_pid); wpid=$(o "$ww" pane_pid)
  nt send-keys -t "$hw" 'exit' Enter
  until_ok 5 sh -c "[ \"\$('$REAL_TMUX' -S '$BREAK_SOCK' display-message -p -t '$hw' '#{pane_dead}')\" = 1 ]" || { WHY="home's shell did not exit"; return 1; }
  rlib fleet_home_heal rn rn >/dev/null
  until_ok 5 sh -c "p=\$('$REAL_TMUX' -S '$BREAK_SOCK' display-message -p -t '$hw' '#{pane_pid} #{pane_dead}'); [ \"\${p% *}\" != '$hpid' ] && [ \"\${p#* }\" = 0 ]" \
    || { WHY="the renamed home stayed dead: the tick's fleet_home_heal looked for it by name"; return 1; }
  [ "$(o "$ww" pane_pid)" = "$wpid" ] || { WHY="the heal respawned the worker that wears the name home"; return 1; }
  # a restored session renamed: the next tick must not open a second one
  write_fid_map() {
    { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
      printf 'FID\t1f0e0000-0000-4000-8000-000000000001\n'
      printf 'WIN\tissue-1\t%s\tsid-1\t1\tworking\t-\t-\n' "$WORK/wt-1"
    } > "$WORK/econf/fleets/oc/restore.map"
  }
  BREAK_SOCK="$WORK/sock-rr"
  write_fid_map; auto
  until_ok 10 sh -c "'$REAL_TMUX' -S '$BREAK_SOCK' list-windows -t oc -F '#{window_name}' 2>/dev/null | grep -qx issue-1" \
    || { WHY="the sandbox fleet never restored issue-1"; return 1; }
  nt rename-window -t oc:issue-1 'my task'
  write_fid_map                                   # a reconcile run on the live fleet
  env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/econf" FLEET_SKIP_GLOBAL_CONF=1 \
    BREAK_SOCK="$BREAK_SOCK" SHELL=/bin/sh FLEET_RESTORE_PROBE_SECS=2 FLEET_DISK_FLOOR_GB=0 \
    bash "$WORK/inst/bin/fleet-restore.sh" >/dev/null 2>&1
  wins=$(nt list-windows -t oc -F '#{window_name}' | sort | tr '\n' ' ')
  [ "$wins" = "home my task " ] || { WHY="after renaming issue-1 a reconcile left [$wins], want [home my task ] (no duplicate)"; return 1; }
  SECS=$(since "$t0"); WHAT="home 改名照样自愈、计数照旧、改名的会话不被重开"
}

# break-pane (issue #1844): the agent pane broken out with prefix ! takes the
# session's identity with it, so its recovery page still resumes the conversation.
drill_break_pane() {
  CAP=10; BREAK_SOCK="$WORK/sock-bp"; local c="$WORK/bp" t0 hook ap ow nw v
  hook=$(grep 'fleet-window-carry.sh' "$ROOT/conf/tmux-attention.conf" | grep '^set-hook' | sed "s#~/.claude/fleet/bin/#$BIN/#")
  [ -n "$hook" ] || { WHY="conf/tmux-attention.conf has no hook carrying a broken-out pane's identity"; return 1; }
  wrapped sb issue-5 "$c" || { WHY="cannot start the isolated tmux server"; return 1; }
  printf '%s\n' "$hook" > "$WORK/bp-hook.conf"
  nt source-file "$WORK/bp-hook.conf" || { WHY="the conf's hook line does not parse"; return 1; }
  ow=$(o sb:issue-5 window_id)
  nt set-option -w -t "$ow" @issue 5; nt set-option -w -t "$ow" @fleet_id 1f0e0000-0000-4000-8000-000000000005
  nt set-option -w -t "$ow" @fleet_role worker
  until_ok 10 grep -q . "$c/argv" || { WHY="the agent never started"; return 1; }
  until_ok 5 sh -c "[ -n \"\$('$REAL_TMUX' -S '$BREAK_SOCK' show-options -wqv -t '$ow' @cc_session_id)\" ]" || { WHY="the agent never stamped its id"; return 1; }
  ap=$(o "$ow" pane_id)
  nt split-window -d -t "$ow" 'exec sleep 600'
  t0=$(now)
  nt break-pane -d -s "$ap"                       # the break: prefix !
  wopt() { "$REAL_TMUX" -S "$BREAK_SOCK" show-options -wqv -t "$1" "$2" 2>/dev/null; }
  until_ok "$CAP" sh -c "[ \"\$('$REAL_TMUX' -S '$BREAK_SOCK' show-options -wqv -t '$ap' @issue)\" = 5 ]" \
    || { WHY="the broken-out window has no @issue: the identity stayed behind"; return 1; }
  SECS=$(since "$t0")
  nw=$(o "$ap" window_id)
  [ "$nw" != "$ow" ] || { WHY="break-pane did not make a new window"; return 1; }
  for v in "@fleet_id 1f0e0000-0000-4000-8000-000000000005" "@cc_session_id SID-1" "@fleet_role worker"; do
    [ "$(wopt "$nw" "${v%% *}")" = "${v#* }" ] || { WHY="the new window's ${v%% *} is [$(wopt "$nw" "${v%% *}")], want ${v#* }"; return 1; }
  done
  [ "$(o "$nw" window_name)" = issue-5 ] || { WHY="the new window is named [$(o "$nw" window_name)], not issue-5"; return 1; }
  [ -z "$(wopt "$ow" @fleet_id)$(wopt "$ow" @issue)" ] || { WHY="the old window still carries the identity: two windows answer to it"; return 1; }
  [ "$(wopt "$ow" @fleet_role)" = panel ] || { WHY="the left-behind window is [$(wopt "$ow" @fleet_role)], not a panel"; return 1; }
  printf rc0 > "$c/mode"; : > "$c/go"             # the agent then exits …
  until_ok 10 sh -c "'$REAL_TMUX' -S '$BREAK_SOCK' capture-pane -p -t '$ap' | grep -qF '这个窗口不会关'" || { WHY="no recovery page in the new window"; return 1; }
  nt send-keys -t "$ap" Enter                     # … and ↵ resumes it
  until_ok 10 sh -c "[ \$(grep -c . '$c/argv') = 2 ]" || { WHY="↵ relaunched nothing"; return 1; }
  [ "$(sed -n 2p "$c/argv")" = "--agent claude --resume SID-1" ] || { WHY="↵ ran [$(sed -n 2p "$c/argv")], not the same conversation"; return 1; }
  WHAT="拆出的窗口带着 @issue / @fleet_id / 对话 id 和名字，恢复页 ↵ 续上同一对话"
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
  until_ok 10 grep -q switching "$d/tick1.out" || { WHY="the first tick never got to switching: $(tail -2 "$d/tick1.out")"; return 1; }
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

# personal-tmux-conf (issue #1845): the person's ~/.tmux.conf has a syntax error
# (and the fleet's own source line in it is commented out). The fleet's server
# starts from conf/tmux-fleet-server.conf the way fleet-up.sh starts it
# (fleet_server_new_session): the fleet layer is on — the reap hook, the rename
# guard, @fleet_conf_loaded — the person's lines before the error still apply,
# fleet_tmuxconf_check (the doctor's tmuxconf row) says ok, and
# reapply-tmux-attention.sh no longer takes the commented line for the real one.
drill_personal_tmux_conf() {
  CAP=5; BREAK_SOCK="$WORK/sock-pc"; local t0 h="$WORK/pchome" chk out
  grep -q 'fleet_server_new_session "\$SOCK"' "$BIN/fleet-up.sh" \
    || { WHY="fleet-up.sh does not start its server through fleet_server_new_session (-f conf/tmux-fleet-server.conf)"; return 1; }
  mkdir -p "$h"
  { printf 'set -g @personal_before 1\n'
    printf "# if-shell '[ -f %s/conf/tmux-attention.conf ]' 'source-file %s/conf/tmux-attention.conf'\n" "$ROOT" "$ROOT"
    printf 'set -g status-left "an unterminated quote\n'
    printf 'set -g @personal_after 1\n'; } > "$h/.tmux.conf"
  t0=$(now)
  ( PATH="$WORK/tbin:$PATH" HOME="$h" FLEET_CONF_DIR="$WORK/pcconf"; export PATH HOME FLEET_CONF_DIR BREAK_SOCK
    . "$BIN/fleet-lib.sh"; fleet_server_new_session pc -d -s pc -n home -x 100 -y 30 'exec sleep 600' ) >/dev/null 2>&1 \
    || { WHY="the fleet server did not start beside a broken ~/.tmux.conf"; return 1; }
  nt show-hooks -g window-unlinked 2>/dev/null | grep -q 'fleet-window-reap.sh' || { WHY="the reap hook (window-unlinked → fleet-window-reap.sh) is not on the server"; return 1; }
  [ "$(nt show-options -gv allow-rename 2>/dev/null)" = off ] || { WHY="the rename guard (allow-rename off) is not on the server"; return 1; }
  [ -n "$(nt show-options -gqv @fleet_conf_loaded 2>/dev/null)" ] || { WHY="@fleet_conf_loaded is not set on the server"; return 1; }
  [ "$(nt show-options -gqv @personal_before 2>/dev/null)" = 1 ] || { WHY="the person's own settings were not loaded"; return 1; }
  chk=$( PATH="$WORK/tbin:$PATH" BREAK_SOCK="$BREAK_SOCK"; export PATH BREAK_SOCK
         . "$BIN/fleet-lib.sh"; fleet_tmuxconf_check pc )
  case "$chk" in ok*) ;; *) WHY="fleet_tmuxconf_check (the doctor's tmuxconf row) says [$chk]"; return 1 ;; esac
  out=$(PATH="$WORK/tbin:$PATH" HOME="$h" BREAK_SOCK="$BREAK_SOCK" sh "$BIN/reapply-tmux-attention.sh" 2>&1)
  grep -q '^[[:space:]]*[^#[:space:]].*tmux-attention\.conf' "$h/.tmux.conf" \
    || { WHY="reapply-tmux-attention.sh took the commented line for the real one: [$out]"; return 1; }
  SECS=$(since "$t0"); WHAT="个人配置有语法错，fleet 层照常（回收 hook、改名保护、@fleet_conf_loaded），tmuxconf 核对 ok，reapply 补回 source 行"
}

# ---- a personal configuration written badly (issue #1862, EPIC #1855 C7) -------
# The person's own layer (C2 #1857, C3 #1858) follows them to every machine — so
# does a mistake in it. Each drill writes one bad layer; the session must still
# open and work, and say which item is bad.
#
# ph_hook <timeout> <command> <calls> — one personal hook run the way Claude Code
# runs it (bin/fleet-hook-personal.sh), <calls> times in ONE session ($PH_LAUNCH);
# prints each call's "<rc>:<secs>" on one line.
ph_hook() {
  local out='' t
  for _ in $(seq 1 "$3"); do
    t=$(now)
    echo '{"session_id":"S-1"}' | env HOME="$WORK/ph" FLEET_CONF_DIR="$WORK/ph/conf" FLEET_PERSONAL_HOOK_TIMEOUT="$1" \
      FLEET_WRAP_LAUNCH_ID="$PH_LAUNCH" sh "$BIN/fleet-hook-personal.sh" PreToolUse -- "$2" >/dev/null 2>"$WORK/ph-hook.err"
    out="$out $?:$(since "$t")"
  done
  printf '%s\n' "${out# }"
}
# A personal hook that hangs: cut off at the timeout (C3) — and after 3 failures
# in a row it is off for the rest of this session, so the next call costs nothing.
drill_personal_hook_hangs() {
  CAP=6; local t0 r last; PH_LAUNCH="hang$$"; mkdir -p "$WORK/ph/conf"
  t0=$(now); r=$(ph_hook 1 'sleep 30' 5)
  last=${r##* }
  case "$r" in 1:*' '1:*' '1:*) ;; *) WHY="the first three calls were not cut off at 1s: [$r]"; return 1 ;; esac
  [ "${last%%:*}" = 0 ] && le "${last#*:}" 0.5 \
    || { WHY="after 3 timeouts the hook still runs — every tool call waits on it again: [$r]"; return 1; }
  ls "$WORK/ph/conf/personal-hook-strikes/$PH_LAUNCH/"*.off >/dev/null 2>&1 \
    || { WHY="nothing records the hook as off (the recovery page has nothing to say)"; return 1; }
  SECS=$(since "$t0"); WHAT="个人规则卡死：每次 1s 切断，连续 3 次后本会话停用（第 5 次 ${last#*:}s）"
}
# A personal hook that always errors (exit 1, a missing command → 127): off after
# 3 in a row. A deliberate deny (exit 2) is the hook doing its job — never a strike.
drill_personal_hook_errors() {
  CAP=3; local t0 r; mkdir -p "$WORK/ph/conf"
  t0=$(now); PH_LAUNCH="err$$"; r=$(ph_hook 5 'exit 1' 4)
  case "$r" in 1:*' '1:*' '1:*' '0:*) ;; *) WHY="a hook that fails every time is never switched off: [$r]"; return 1 ;; esac
  PH_LAUNCH="err127$$"; r=$(ph_hook 5 'no-such-personal-tool-xyz --go' 4)
  case "$r" in 127:*' '127:*' '127:*' '0:*) ;; *) WHY="a hook whose command is missing is never switched off: [$r]"; return 1 ;; esac
  PH_LAUNCH="deny$$"; r=$(ph_hook 5 'echo no >&2; exit 2' 5)
  case "$r" in 2:*' '2:*' '2:*' '2:*' '2:*) ;; *) WHY="a deny (exit 2) was counted as a failure: [$r]"; return 1 ;; esac
  SECS=$(since "$t0"); WHAT="个人规则一直报错（exit 1 / 命令不存在）连续 3 次后本会话停用；拒绝（exit 2）不算失败"
}
# pt <args…> — fleet-agent-team.py against the sandbox login $WORK/pt: the
# person's answer is $WORK/pt/presp.json, the team layer empty, ~/.claude.json
# carrying the fleet default github server (as the agents pass leaves it).
pt_rig() {
  local H="$WORK/pt"; rm -rf "$H"; mkdir -p "$H/.claude" "$H/.codex" "$H/conf"
  python3 -c 'import json, sys
gh = json.load(open(sys.argv[1]))["mcpServers"]["github"]
json.dump({"numStartups": 1, "mcpServers": {"github": gh}}, open(sys.argv[2], "w"))' \
    "$ROOT/conf/agent-defaults/claude/mcp.default.json" "$H/.claude.json"
  echo '{}' > "$H/.claude/settings.json"; : > "$H/.codex/config.toml"
  printf '%s\n' '{"version":1,"prev":0,"bundle":{}}' > "$H/tresp.json"
}
pt() {
  local H="$WORK/pt"
  ( cd "$H" && env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$H/conf" CODEX_HOME="$H/.codex" ${PT_ENV:+"$PT_ENV"} \
    FLEET_TEAM_BUNDLE_CMD="cat '$H/tresp.json'" FLEET_PERSON_BUNDLE_CMD="cat '$H/presp.json'" \
    python3 "$ROOT/bin/fleet-agent-team.py" "$@" --root "$ROOT" --claude-config "$H/.claude.json" \
    --claude-settings "$H/.claude/settings.json" --claude-skills "$H/.claude/skills" --codex-home "$H/.codex" 2>&1 )
}
ptj() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2]), sort_keys=True))' "$@" 2>/dev/null; }
# A personal MCP server whose command is not on this machine (the person's laptop
# has it, this login does not): never written into the login's files, never
# handed to a session — and the session's start line names it.
drill_personal_mcp_missing() {
  CAP=10; local t0 H="$WORK/pt" out s
  pt_rig
  printf '%s\n' '{"version":1,"prev":0,"bundle":{"mcp":{"mytool":{"command":"/nonexistent/bin/mytool"},"fine":{"command":"sh","args":["-c","cat"]}}}}' > "$H/presp.json"
  t0=$(now)
  out=$(pt sync)
  [ "$(ptj "$H/.claude.json" "'mytool' in d['mcpServers']")" = false ] \
    || { WHY="sync wrote the missing-command server into ~/.claude.json: [$out]"; return 1; }
  [ "$(ptj "$H/.claude.json" "d['mcpServers']['fine']['command']")" = '"sh"' ] || { WHY="the good personal server did not land: [$out]"; return 1; }
  grep -q mytool "$H/.codex/config.toml" && { WHY="sync wrote it into config.toml"; return 1; }
  printf '%s' "$out" | grep -q 'mytool' || { WHY="sync says nothing about mytool: [$out]"; return 1; }
  s=$(pt session claude)
  printf '%s\n' "$s" | grep -q $'^note\t.*mytool.*/nonexistent/bin/mytool' || { WHY="the session's start line does not name it: [$s]"; return 1; }
  printf '%s\n' "$s" | sed -n 's/^mcp\t//p' | xargs cat 2>/dev/null | grep -q mytool && { WHY="the session was handed mytool"; return 1; }
  grep -q 'note)' "$BIN/fleet-claude.sh" && grep -q 'note)' "$BIN/fleet-codex.sh" \
    || { WHY="fleet-claude.sh / fleet-codex.sh do not print the composer's note lines"; return 1; }
  SECS=$(since "$t0"); WHAT="个人 MCP 命令不存在：不写进本机文件、不交给会话，启动行点名"
}
# The personal layer replaces a fleet default MCP server (github) with one whose
# command is not here: the fleet default stays in force; the start line says why.
drill_personal_mcp_over_default() {
  CAP=10; local t0 H="$WORK/pt" out s gh
  pt_rig; gh=$(ptj "$H/.claude.json" "d['mcpServers']['github']")
  printf '%s\n' '{"version":1,"prev":0,"bundle":{"mcp":{"github":{"command":"/nonexistent/gh-mcp"}}}}' > "$H/presp.json"
  t0=$(now)
  out=$(pt sync)
  [ "$(ptj "$H/.claude.json" "d['mcpServers']['github']")" = "$gh" ] \
    || { WHY="the personal layer broke the fleet's github server: $(ptj "$H/.claude.json" "d['mcpServers']['github']") [$out]"; return 1; }
  [ "$(ptj "$H/conf/agent-effective.json" "d['items'].get('claude.mcp.github', {}).get('source')")" != '"personal"' ] \
    || { WHY="agent-effective.json says github is the personal layer's"; return 1; }
  s=$(pt session claude)
  printf '%s\n' "$s" | grep -q $'^note\t.*github' || { WHY="the session's start line does not name github: [$s]"; return 1; }
  SECS=$(since "$t0"); WHAT="个人层把 github 换成不存在的命令：fleet 默认照常生效，启动行点名"
}
# person-bundle.json cut short (a disk full mid-write, a crash, a bad hand edit):
# the session uses the last good copy and says so — the person's items do not
# silently vanish, and the next apply does not take them back.
drill_personal_cache_truncated() {
  CAP=10; local t0 H="$WORK/pt" out s
  pt_rig
  printf '%s\n' '{"version":1,"prev":0,"bundle":{"mcp":{"pm":{"command":"sh","args":["-c","cat"]}},"claude_settings":{"includeCoAuthoredBy":false}}}' > "$H/presp.json"
  pt sync >/dev/null
  [ "$(ptj "$H/.claude.json" "d['mcpServers']['pm']['command']")" = '"sh"' ] || { WHY="the rig's personal server did not land"; return 1; }
  head -c 25 "$H/conf/person-bundle.json" > "$H/pb.cut" && mv "$H/pb.cut" "$H/conf/person-bundle.json"
  t0=$(now)
  s=$(pt session claude)
  printf '%s\n' "$s" | grep -q $'^src\t.* personal:v1 ' || { WHY="a truncated cache dropped the personal layer from the session: [$s]"; return 1; }
  printf '%s\n' "$s" | grep -q $'^note\t.*person-bundle.json' || { WHY="the session's start line does not say the cache is broken: [$s]"; return 1; }
  out=$(pt apply)
  [ "$(ptj "$H/.claude.json" "d['mcpServers'].get('pm', {}).get('command')")" = '"sh"' ] \
    || { WHY="apply took the personal server back on a truncated cache: [$out]"; return 1; }
  [ "$(ptj "$H/.claude/settings.json" "d.get('includeCoAuthoredBy')")" = false ] || { WHY="apply took the personal setting back: [$out]"; return 1; }
  SECS=$(since "$t0"); WHAT="个人缓存被截断：用上一份完好的 v1，启动行告警，本机文件不被收回"
}
# The personal layer makes the session useless (a hook that refuses every call, a
# setting that breaks it): the recovery page offers p — the SAME conversation, this
# window only, without the personal layer (FLEET_PERSONAL=0: personal hooks do not
# run, the composer leaves the layer out). Hooks switched off in the run that just
# ended are named on the page.
drill_personal_breaks_session() {
  CAP=8; BREAK_SOCK="$WORK/sock-pb"; local c="$WORK/pb" t0 out rc
  mkdir -p "$c/conf" && printf '%s\n' '{"version":3,"bundle":{}}' > "$c/conf/person-bundle.json"
  printf 'exit 1' > "$c/hook"
  PERS_CONF="$c/conf" wrapped sx w "$c" || { WHY="cannot start the isolated tmux server"; return 1; }
  until_ok 15 sh -c "[ \"\$(grep -c . '$c/hook-rc' 2>/dev/null)\" = 4 ]" || { WHY="the agent's personal hook calls never finished"; return 1; }
  t0=$(now); printf rc0 > "$c/mode"; : > "$c/go"
  until_ok 10 page_says '这个窗口不会关' || { WHY="no recovery page"; return 1; }
  page_says '不带个人配置重开' \
    || { WHY="the page offers no way to reopen without the personal layer: $(nt capture-pane -p -t sx:w | grep . | tail -1)"; return 1; }
  page_says '个人自动规则' || { WHY="the page does not say a personal hook was switched off"; return 1; }
  rm -f "$c/hook"; nt send-keys -t sx:w p
  until_ok 10 sh -c "[ \$(grep -c . '$c/argv') = 2 ]" || { WHY="p relaunched nothing"; return 1; }
  [ "$(sed -n 2p "$c/argv")" = "--agent claude --resume SID-1" ] || { WHY="p ran [$(sed -n 2p "$c/argv")], not the same conversation"; return 1; }
  [ "$(sed -n 2p "$c/personal")" = 0 ] || { WHY="the relaunch did not run with FLEET_PERSONAL=0 ([$(sed -n 2p "$c/personal")])"; return 1; }
  out=$(echo '{}' | FLEET_PERSONAL=0 sh "$BIN/fleet-hook-personal.sh" PreToolUse -- 'echo no >&2; exit 2' 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="under FLEET_PERSONAL=0 a personal hook still runs (rc $rc: $out)"; return 1; }
  pt_rig; printf '%s\n' '{"version":2,"prev":1,"bundle":{"claude_settings":{"includeCoAuthoredBy":false}}}' > "$WORK/pt/presp.json"
  pt sync >/dev/null
  out=$(PT_ENV=FLEET_PERSONAL=0 pt session claude)
  printf '%s\n' "$out" | grep -q $'^src\t.* personal:off ' || { WHY="the composer under FLEET_PERSONAL=0 still uses the layer: [$out]"; return 1; }
  SECS=$(since "$t0"); WHAT="恢复页 p：同一对话、本窗口不带个人配置重开；停用的个人规则在页上点名"
}

# node-menu / node-prefix-keys / window-killed (issue #1840): what a PERSON can
# reach on a node's fleet server deletes nothing, and a session window deleted
# anyway comes back on the next tick, same conversation.
# hpty <sock> <window> <out> <bytes…> — a real client in a python pty, attached to
# <window>; each <bytes> arg (python escapes) is typed 0.6s apart; everything the
# client drew lands in <out>.
hpty() {
  python3 - "$REAL_TMUX" "$@" <<'PY'
import os, pty, select, struct, sys, time, fcntl, termios
tm, sock, win, out = sys.argv[1:5]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(tm, [tm, "-S", sock, "attach", "-t", win])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
buf = b""
def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: buf += os.read(fd, 65536)
            except OSError: return
pump(0.8)
for b in sys.argv[5:]:
    os.write(fd, b.encode().decode("unicode_escape").encode("latin-1")); pump(0.6)
pump(0.4)
open(out, "wb").write(buf)
try: os.kill(pid, 9)
except OSError: pass
PY
}
# hnode <label> — a node server started the way fleet-up starts one (-f
# conf/tmux-fleet-server.conf), beside a personal ~/.tmux.conf that puts tmux's
# deletes back, with two execution windows
hnode() {
  BREAK_SOCK="$WORK/sock-$1"; local h="$WORK/$1home"
  mkdir -p "$h"
  { printf 'bind x kill-pane\nbind & kill-window\n'
    printf 'bind -n MouseDown3Pane display-menu -t = -x M -y M Kill X { kill-pane } Respawn R { respawn-pane -k }\n'; } > "$h/.tmux.conf"
  HOME="$h" "$REAL_TMUX" -S "$BREAK_SOCK" -f "$ROOT/conf/tmux-fleet-server.conf" new-session -d -s "$1" -n home -x 100 -y 30 'exec sleep 600' \
    || { WHY="the node server did not start from conf/tmux-fleet-server.conf"; return 1; }
  nt set-option -g mouse on
  nt new-window -d -t "$1:" -n issue-1 'exec sleep 600'
  nt new-window -d -t "$1:" -n issue-2 'exec sleep 600'
}

drill_node_menu() {
  CAP=5; local t0 out="$WORK/hm.out" item
  hnode hm || return 1
  t0=$(now)
  # the break: a right-click on the session's pane (SGR mouse, button 3) …
  hpty "$BREAK_SOCK" hm:issue-1 "$out" '\x1b[<2;20;10M' '\x1b[<2;20;10m'
  grep -aq 'Kill\|Respawn' "$out" && { WHY="the right-click menu still offers Kill / Respawn"; return 1; }
  for item in 复制这一屏 它在哪台 给它发消息 看它的单; do
    grep -aq "$item" "$out" || { WHY="the right-click menu has no 「$item」 (did it open at all?)"; return 1; }
  done
  # … and no other right-click (Alt, the status line) deletes either
  nt list-keys -T root | grep -E 'MouseDown3' | grep -Eq 'kill-|respawn-' \
    && { WHY="a right-click binding still deletes: $(nt list-keys -T root | grep -E 'MouseDown3' | grep -E 'kill-|respawn-' | awk '{print $4}' | tr '\n' ' ')"; return 1; }
  [ "$(nt list-windows -t hm -F '#{window_name}' | sort | tr '\n' ' ')" = "home issue-1 issue-2 " ] || { WHY="a window went missing"; return 1; }
  SECS=$(since "$t0"); WHAT="右键弹只读菜单（复制 · 在哪台 · 发消息 · 看单），没有 Kill / Respawn；个人配置加不回来"
}

drill_node_prefix_keys() {
  CAP=10; local t0 out="$WORK/hk.out" wins
  hnode hk || return 1
  t0=$(now)
  # the break: a direct attach typing prefix x y, prefix & y, prefix $ <name> ↵, prefix < (C-b = \x02)
  hpty "$BREAK_SOCK" hk:issue-1 "$out" '\x02x' 'y' '\x02&' 'y' '\x02$' 'gone\r' '\x02<' '\x1b'
  wins=$(nt list-windows -t hk -F '#{window_name}' 2>/dev/null | sort | tr '\n' ' ')
  [ "$wins" = "home issue-1 issue-2 " ] || { WHY="after prefix x / & the windows are [$wins], want [home issue-1 issue-2 ]"; return 1; }
  nt has-session -t '=hk' 2>/dev/null || { WHY="prefix \$ renamed the fleet session"; return 1; }
  [ "$(nt show-options -gqv @fleet_human)" = v1 ] || { WHY="the human layer (@fleet_human) is not on the server"; return 1; }
  SECS=$(since "$t0"); WHAT="prefix x / & / \$ / < 都不起作用，个人配置绑回的 x / & 也被最后一层拿掉"
}

drill_window_killed() {
  CAP=20; BREAK_SOCK="$WORK/sock-wk"; local t0 wins w2 f led="$WORK/wk-ledger.tsv"
  local f1=1f0e0000-0000-4000-8000-0000000018a1 f2=1f0e0000-0000-4000-8000-0000000018a2
  for f in dash-reap.sh session-end-hook.sh fleet-cleanup.sh fleet-move.sh fleet-worker-stop.sh scratch-pool.sh fleet-cleanup-idle.py; do
    grep -q 'retire' "$BIN/$f" || { WHY="$f closes a session window without marking it (fleet_win_retire): the next tick would pull it back"; return 1; }
  done
  mkdir -p "$WORK/gbin"
  printf '#!/bin/sh\necho 0\n' > "$WORK/gbin/gh"; chmod +x "$WORK/gbin/gh"     # no merged PR
  { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
    printf 'FID\t%s\n' "$f1"; printf 'WIN\tissue-1\t%s\tsid-1\t1\tworking\t-\t-\n' "$WORK/wt-1"
    printf 'FID\t%s\n' "$f2"; printf 'WIN\tissue-2\t%s\tsid-2\t2\tidle\t-\t-\n'    "$WORK/wt-2"
  } > "$WORK/econf/fleets/oc/restore.map"
  auto
  until_ok 10 sh -c "[ \"\$('$REAL_TMUX' -S '$BREAK_SOCK' list-windows -t oc -F '#{@fleet_id}' 2>/dev/null | grep -c .)\" = 2 ]" \
    || { WHY="the sandbox fleet never came up with both sessions"; return 1; }
  # issue-2 the fleet closes on purpose (the recovery page's q, a reap): marked first
  w2=$(nt list-windows -t oc -F '#{window_id} #{@fleet_id}' | awk -v f="$f2" '$2 == f { print $1 }')
  ( PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/econf"; export PATH HOME FLEET_CONF_DIR BREAK_SOCK
    . "$BIN/fleet-lib.sh"; fleet_win_retire "$w2" oc )
  : > "$WORK/claude-argv"
  nt kill-window -t "$w2"
  nt kill-window -t oc:issue-1                    # the break: a session window deleted by hand
  t0=$(now)
  auto PATH="$WORK/gbin:$WORK/tbin:$PATH" FLEET_HISTORY_LEDGER="$led"     # one diskguard tick
  until_ok "$CAP" sh -c "'$REAL_TMUX' -S '$BREAK_SOCK' list-windows -t oc -F '#{@fleet_id}' 2>/dev/null | grep -qx '$f1'" \
    || { WHY="the killed issue-1 did not come back: $(grep pullback "$WORK/econf/restore/restore.log" 2>/dev/null | tail -3 | tr '\n' ' ')"; return 1; }
  until_ok "$CAP" grep -q -- '--resume sid-1' "$WORK/claude-argv" 2>/dev/null || { WHY="issue-1 came back without its conversation (--resume sid-1)"; return 1; }
  SECS=$(since "$t0")
  wins=$(nt list-windows -t oc -F '#{window_name}' | sort | tr '\n' ' ')
  [ "$wins" = "home issue-1 " ] || { WHY="after the tick the fleet has [$wins], want [home issue-1 ] (the fleet's own close stays closed)"; return 1; }
  grep -q 'sid-1.*reason=killed-window' "$led" 2>/dev/null || { WHY="/fleet-history has no reason=killed-window row: [$(cat "$led" 2>/dev/null)]"; return 1; }
  auto PATH="$WORK/gbin:$WORK/tbin:$PATH" FLEET_HISTORY_LEDGER="$led"     # a second tick: nothing doubles
  [ "$(nt list-windows -t oc -F '#{window_name}' | grep -c '^issue-1$')" = 1 ] || { WHY="a second tick opened issue-1 twice"; return 1; }
  WHAT="被删的 issue-1 下一拍以原对话回来，/fleet-history 记 reason=killed-window；fleet 自己关的 issue-2 不拉回（节拍 60s 另计）"
}

# ---- /loop and fleet down (issue #1846) ------------------------------------------
# A transcript in the sandbox HOME's project dir for <worktree>/<sid>: one
# successful ScheduleWakeup <secs> ago, the way Claude Code writes it.
loop_transcript() {
  local wt="$1" sid="$2" lprompt="$3" d
  d=$(HOME="$WORK/home" CLAUDE_PROJECTS_DIR='' bash -c '. "$1/fleet-lib.sh"; fleet_transcript_dir "$2"' _ "$BIN" "$wt")
  mkdir -p "$d"
  python3 - "$d/$sid.jsonl" "$lprompt" <<'PY'
import datetime, json, sys
ts = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=60)).strftime('%Y-%m-%dT%H:%M:%S.000Z')
with open(sys.argv[1], 'w') as f:
    f.write(json.dumps({'type': 'user', 'timestamp': ts, 'message': {'role': 'user', 'content': '/loop ' + sys.argv[2]}}) + '\n')
    f.write(json.dumps({'type': 'assistant', 'timestamp': ts, 'message': {'role': 'assistant', 'content': [
        {'type': 'tool_use', 'id': 'tu1', 'name': 'ScheduleWakeup',
         'input': {'delaySeconds': 1200, 'prompt': sys.argv[2], 'reason': 'next tick'}}]}}) + '\n')
    f.write(json.dumps({'type': 'user', 'timestamp': ts, 'message': {'role': 'user', 'content': [
        {'type': 'tool_result', 'tool_use_id': 'tu1', 'content': 'scheduled'}]}}) + '\n')
PY
}

# A worker running /loop is deleted by hand: the next tick brings it back with its
# conversation AND its loop — `/loop <its input>` is the resumed session's first turn.
drill_loop_window_killed() {
  CAP=20; BREAK_SOCK="$WORK/sock-lk"; local t0 f1=1f0e0000-0000-4000-8000-0000000018b1
  mkdir -p "$WORK/gbin" "$WORK/wt-3"
  printf '#!/bin/sh\necho 0\n' > "$WORK/gbin/gh"; chmod +x "$WORK/gbin/gh"     # no merged PR
  loop_transcript "$WORK/wt-3" sid-3 '/fleet-epic-run 1851'
  { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
    printf 'FID\t%s\n' "$f1"; printf 'WIN\tissue-3\t%s\tsid-3\t3\tlooping\t-\t-\n' "$WORK/wt-3"
  } > "$WORK/econf/fleets/oc/restore.map"
  auto
  until_ok 10 sh -c "'$REAL_TMUX' -S '$BREAK_SOCK' list-windows -t oc -F '#{@fleet_id}' 2>/dev/null | grep -qx '$f1'" \
    || { WHY="the sandbox fleet never came up with the looping session"; return 1; }
  : > "$WORK/claude-argv"
  nt kill-window -t oc:issue-3                    # the break
  t0=$(now)
  auto PATH="$WORK/gbin:$WORK/tbin:$PATH"         # one diskguard tick
  until_ok "$CAP" grep -q -- '--resume sid-3' "$WORK/claude-argv" 2>/dev/null \
    || { WHY="the killed issue-3 did not come back with its conversation"; return 1; }
  grep -q -- '--resume sid-3 /loop /fleet-epic-run 1851$' "$WORK/claude-argv" \
    || { WHY="issue-3 came back without its loop: [$(tail -1 "$WORK/claude-argv")], want --resume sid-3 /loop /fleet-epic-run 1851"; return 1; }
  SECS=$(since "$t0"); WHAT="被删的 issue-3 下一拍以原对话回来，第一轮就是 /loop /fleet-epic-run 1851（节拍 60s 另计）"
}

# pty_run <answer> <command…> — run it on a terminal, type <answer>⏎ at the
# first prompt; the screen goes to $WORK/pty.out, the exit status is ours.
pty_run() {
  python3 - "$@" > "$WORK/pty.out" 2>&1 <<'PY'
import os, pty, select, sys, time
answer, argv = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
out, sent, end = b'', False, time.time() + 20
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try: data = os.read(fd, 4096)
        except OSError: break
        if not data: break
        out += data
    if not sent and ('确认'.encode() in out and out.rstrip().endswith(b':') or out.rstrip().endswith('：'.encode())):
        os.write(fd, answer.encode() + b'\r'); sent = True
sys.stdout.write(out.decode('utf-8', 'replace'))
_, st = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(st) if hasattr(os, 'waitstatus_to_exitcode') else st >> 8)
PY
}

# fleet down asks first (a terminal: type the fleet's name; a script: --yes) and
# keeps the map it is about to lose; `fleet up --undo` brings every session back.
drill_fleet_down_confirm() {
  CAP=20; BREAK_SOCK="$WORK/sock-fd"; local t0 rc wins f1=1f0e0000-0000-4000-8000-0000000018c1 f2=1f0e0000-0000-4000-8000-0000000018c2
  local fenv="PATH=$WORK/tbin:$PATH HOME=$WORK/home FLEET_CONF_DIR=$WORK/econf FLEET_SKIP_GLOBAL_CONF=1 BREAK_SOCK=$BREAK_SOCK SHELL=/bin/sh FLEET_RESTORE_PROBE_SECS=2 FLEET_DISK_FLOOR_GB=0"
  grep -q 'fleet-restore.sh.*--undo' "$BIN/fleet-up.sh" 2>/dev/null \
    || { WHY="fleet-up.sh has no --undo (it should hand it to fleet-restore.sh --undo)"; return 1; }
  rm -f "$WORK/econf/fleets/oc/restore.down" "$WORK/econf/fleets/oc"/restore.map.*
  { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
    printf 'FID\t%s\n' "$f1"; printf 'WIN\tissue-1\t%s\tsid-1\t1\tworking\t-\t-\n' "$WORK/wt-1"
    printf 'FID\t%s\n' "$f2"; printf 'WIN\tissue-2\t%s\tsid-2\t2\tdone\t-\t-\n'    "$WORK/wt-2"
  } > "$WORK/econf/fleets/oc/restore.map"
  env $fenv bash "$WORK/inst/bin/fleet-restore.sh" >/dev/null 2>&1
  until_ok 10 sh -c "[ \"\$('$REAL_TMUX' -S '$BREAK_SOCK' list-windows -t oc -F '#{@fleet_id}' 2>/dev/null | grep -c .)\" = 2 ]" \
    || { WHY="the sandbox fleet never came up with both sessions"; return 1; }
  # their hooks stamp the session id; the conversation is on disk (the snapshot keeps an id only then)
  nt set-option -w -t oc:issue-1 @cc_session_id sid-1; nt set-option -w -t oc:issue-2 @cc_session_id sid-2
  loop_transcript "$WORK/wt-1" sid-1 x; loop_transcript "$WORK/wt-2" sid-2 x
  nt set-option -w -t oc:issue-1 @claude_state working; nt set-option -w -t oc:issue-2 @claude_state 'done'
  # 1. a script, no --yes: nothing goes down, and it says what would have
  env $fenv bash "$WORK/inst/bin/fleet-down.sh" oc </dev/null > "$WORK/fd.out" 2>&1; rc=$?
  [ "$rc" != 0 ] || { WHY="fleet-down with no terminal and no --yes went ahead (exit 0)"; return 1; }
  nt has-session -t oc 2>/dev/null || { WHY="fleet-down with no confirmation took the fleet down"; return 1; }
  grep -q 'issue-1' "$WORK/fd.out" && grep -q 'issue-2' "$WORK/fd.out" && grep -q -- '--yes' "$WORK/fd.out" \
    || { WHY="the refusal does not list the sessions and --yes: [$(tr '\n' ' ' < "$WORK/fd.out")]"; return 1; }
  # 2. a terminal, the wrong name: nothing goes down
  pty_run nope env $fenv bash "$WORK/inst/bin/fleet-down.sh" oc; rc=$?
  [ "$rc" != 0 ] && nt has-session -t oc 2>/dev/null \
    || { WHY="a wrong name at the prompt still took the fleet down (exit $rc): [$(tr '\n' ' ' < "$WORK/pty.out")]"; return 1; }
  grep -q '确认' "$WORK/pty.out" || { WHY="no confirmation prompt on a terminal: [$(tr '\n' ' ' < "$WORK/pty.out")]"; return 1; }
  # 3. --yes: down, the map kept aside
  env $fenv bash "$WORK/inst/bin/fleet-down.sh" oc --yes </dev/null >/dev/null 2>&1
  nt has-session -t oc 2>/dev/null && { WHY="fleet-down --yes left the fleet up"; return 1; }
  ls "$WORK/econf/fleets/oc"/restore.map.down-* >/dev/null 2>&1 || { WHY="fleet-down kept no restore.map.down-<time>"; return 1; }
  # 4. fleet up --undo: every session back, on its own conversation
  : > "$WORK/claude-argv"
  t0=$(now)
  env $fenv bash "$WORK/inst/bin/fleet-up.sh" --undo >/dev/null 2>&1
  until_ok "$CAP" sh -c "grep -q -- '--resume sid-1' '$WORK/claude-argv' && grep -q -- '--resume sid-2' '$WORK/claude-argv'" \
    || { WHY="--undo did not resume both sessions: [$(tr '\n' ' ' < "$WORK/claude-argv")] $(grep -i undo "$WORK/econf/restore/restore.log" 2>/dev/null | tail -2 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  wins=$(nt list-windows -t oc -F '#{window_name}' | sort | tr '\n' ' ')
  [ "$wins" = "home issue-1 issue-2 " ] || { WHY="after --undo the fleet has [$wins], want [home issue-1 issue-2 ]"; return 1; }
  [ "$(o oc:issue-1 @fleet_id)" = "$f1" ] || { WHY="issue-1 came back with another identity [$(o oc:issue-1 @fleet_id)]"; return 1; }
  [ -e "$WORK/econf/fleets/oc/restore.down" ] && { WHY="--undo left restore.down: --auto would never bring it back again"; return 1; }
  [ -e "$WORK/econf/restore/autorestore.off" ] && { WHY="--undo left auto-restore off"; return 1; }
  WHAT="不确认不关（脚本无 --yes、终端输错名字）；--yes 关后 fleet up --undo 两个会话都以原对话回来"
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

# The list does not move while a line is down (issue #1882): the real client on
# its own -L socket, a fake hub serving sessions in two repos on two machines.
# Before, a lost machine's rows moved into a `─ m4 失联 ─` group at the foot and
# came back when it answered again — the list reshuffled twice. The sidebar pane
# is captured before / during / after: during, the same lines in the same order,
# only the lost rows' `@m4!` (the colour is the view's, never in a capture).
off_hub() {   # the fake hub: `down` = unreachable, else the current answer
  mkdir -p "$WORK/off"
  printf '#!/bin/bash\n[ -f "%s/off/down" ] && exit 1\ncat "%s/off/cur.json"\n' "$WORK" "$WORK" > "$WORK/off/hub"
  chmod +x "$WORK/off/hub"
  python3 - "$WORK/off" <<'PY'
import json, sys
d = sys.argv[1]
def s(host, key, name, repo, origin=None, state="working"):
    f = "11111111-2222-3333-4444-55555555555" + ("4" if host == "m4" else "5")
    w = dict(key=key, name=name, repo=repo, state=state, lifecycle="awake", agent="claude")
    if origin:
        w["origin_wid"] = f + "/" + origin
    return dict(worker_id=f + "/" + key, machine_name=host, os_user="verk", fleet_id=f,
                fleet_name="x", availability="online", worker=w, observed_at="2026-10-06T10:00:00Z")
rows = [s("m5", "acme-app:scratch-1", "app-root", "acme/app", state="looping"),
        s("m4", "acme-app:issue-2", "app-kid", "acme/app", origin="acme-app:scratch-1"),
        s("m4", "acme-app:issue-3", "app-m4", "acme/app"),
        s("m5", "acme-tool:issue-4", "tool-m5", "acme/tool"),
        s("m4", "acme-tool:issue-5", "tool-m4", "acme/tool", state="done"),
        s("m4", "acme-x:scratch-6", "loose-m4", None)]
def node(host, av):
    return dict(machine_name=host, availability=av, sessions=3, observed_at="2026-10-06T10:00:00Z")
on = dict(sessions=rows, nodes=[node("m4", "online"), node("m5", "online")])
lost = dict(sessions=[dict(r, availability="lost") if r["machine_name"] == "m4" else r for r in rows],
            nodes=[node("m4", "lost"), node("m5", "online")])
json.dump(on, open(d + "/on.json", "w")); json.dump(lost, open(d + "/m4lost.json", "w"))
PY
  cp "$WORK/off/on.json" "$WORK/off/cur.json"; rm -f "$WORK/off/down" "$WORK/off/stop"
}
off_list() {   # the sidebar pane as it reads (text only), blank lines dropped
  local p
  p=$("$REAL_TMUX" -L "$1" list-panes -t "=$1:home" -F '#{@sidebar} #{pane_id}' 2>/dev/null | awk '$1 == 1 { print $2; exit }')
  [ -n "$p" ] && "$REAL_TMUX" -L "$1" capture-pane -p -t "$p" 2>/dev/null | sed -e 's/[[:space:]]*$//' | grep -v '^$'
}
# the rows only: from the first row naming a session to the last — the footer
# (input line, hints) is the bar's business, not the list's
off_rows() { off_list "$1" | awk '/app-root|app-kid|app-m4|tool-m5|tool-m4|loose-m4|\([0-9]+\)$|失联/ { print }' | spin_off; }
spin_off() { sed -e 's/[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/*/g'; }       # the working spinner turns on its own
off_norm() { LC_ALL=C sed -e 's/!//g' -e 's/  */ /g'; }
off_wait() {   # <socket> <secs> <grep -E pattern> [v] — until the rows (do not) show it
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    if [ "${4:-}" = v ]; then off_rows "$1" | grep -qE "$3" || return 0
    else off_rows "$1" | grep -qE "$3" && return 0; fi
    sleep 0.2
  done
  return 1
}
drill_offline_list_moves() {
  CAP=30; local s="${CSESS}o" t0 before during
  client_setup; off_hub
  # its own cache + TMPDIR (refresher, hub_ok, the remote list): an earlier
  # drill's client may still run a refresher on the shared ones
  mkdir -p "$WORK/off/tmp"
  client_start "$s" FLEET_SHELL_CACHE="$WORK/off/cache" TMPDIR="$WORK/off/tmp" FLEET_HUB_SESSIONS_CMD="$WORK/off/hub" FLEET_HUB_SESSIONS_STALE=12 FLEET_HUB_SESSIONS_LOOP_SECS=150 \
    || { WHY="the client did not start: $(head -3 "$WORK/up-$s.err")"; return 1; }
  # a terminal stays attached for the whole drill (the list is drawn for a
  # client); it leaves on its own at the stop file or after 150s, never later
  python3 - "$REAL_TMUX" "$s" "$WORK/off/stop" <<'PY' &
import os, pty, select, signal, struct, fcntl, sys, termios, time
tmux, sess, stop = sys.argv[1:4]
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM="xterm-256color", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
    os.environ.pop("TMUX", None)
    os.execvp(tmux, [tmux, "-L", sess, "attach-session", "-t", "=" + sess])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 160, 0, 0))
end = time.time() + 150
while time.time() < end and not os.path.exists(stop):
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try: os.read(fd, 65536)
        except OSError: break
try: os.kill(pid, signal.SIGTERM)
except OSError: pass
PY
  off_wait "$s" 30 'loose-m4' || { WHY="the hub's rows never reached the list: [$(off_list "$s" | tr '\n' '|')]"; : > "$WORK/off/stop"; return 1; }
  sleep 1; before=$(off_rows "$s")
  # 1. one machine lost: the hub says m4 is lost
  cp "$WORK/off/m4lost.json" "$WORK/off/cur.json"
  off_wait "$s" 20 '@m4!|@m!' || { WHY="m4 lost never showed on its rows: $(off_rows "$s" | tr '\n' '|')"; return 1; }
  sleep 1; during=$(off_rows "$s")
  case "$during" in *'@本!'*|*'@m5!'*) WHY="m4 lost dimmed m5's rows too (the hub went stale?): $(printf '%s' "$during" | tr '\n' '|')"; return 1 ;; esac
  case "$during" in *失联*) WHY="a 失联 heading came back: $(printf '%s' "$during" | tr '\n' '|')"; return 1 ;; esac
  [ "$(printf '%s\n' "$during" | off_norm)" = "$(printf '%s\n' "$before" | off_norm)" ] \
    || { WHY="m4 lost moved the list: before [$(printf '%s' "$before" | tr '\n' '|')] during [$(printf '%s' "$during" | tr '\n' '|')]"; return 1; }
  # 2. the hub unreachable: every row lost, still the same lines
  cp "$WORK/off/on.json" "$WORK/off/cur.json"
  off_wait "$s" 20 '@m4!|@m!' v || { WHY="m4 never came back after its loss"; return 1; }
  : > "$WORK/off/down"
  off_wait "$s" 40 '@m5!|@本!|@本机!' || { WHY="入口连不上 never dimmed the m5 rows: $(off_rows "$s" | tr '\n' '|')"; return 1; }
  sleep 1; during=$(off_rows "$s")
  [ "$(printf '%s\n' "$during" | off_norm)" = "$(printf '%s\n' "$before" | off_norm)" ] \
    || { WHY="入口连不上 moved the list: before [$(printf '%s' "$before" | tr '\n' '|')] during [$(printf '%s' "$during" | tr '\n' '|')]"; return 1; }
  # 3. back: the very lines of before, no `!` left
  t0=$(now); rm -f "$WORK/off/down"
  off_wait "$s" "$CAP" '!' v || { WHY="the rows stayed lost after the hub answered: $(off_rows "$s" | tr '\n' '|')"; return 1; }
  [ "$(off_rows "$s")" = "$before" ] || { WHY="back online, the list differs from before: [$(off_rows "$s" | tr '\n' '|')]"; return 1; }
  SECS=$(since "$t0"); : > "$WORK/off/stop"
  "$REAL_TMUX" -L "$s" kill-server 2>/dev/null; "$REAL_TMUX" -L "$s-stage" kill-server 2>/dev/null
  WHAT="m4 失联 / 入口连不上：行数、顺序、分组不变，只多 @m4!；恢复后与断开前逐行一致"
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
case "$*" in *" attach"*)
  # the line is down (issue #1876): the connect fails, as ssh says it
  [ -f "$RV_DIR/down" ] && { echo 'ssh: connect to host m9 port 22: Network is unreachable' >&2; exit 255; }
  # the far end's tmux turns the mouse on in the pane it draws (issue #1876)
  [ "${RV_MOUSE:-}" = 1 ] && printf '\033[?1000h\033[?1002h\033[?1006hFAR-END\n'
  [ "${RV_HANG:-}" = 1 ] && { printf '%s\n' $$ > "$RV_DIR/attach.pid"; exec sleep 300; }; sleep 0.3 ;; esac
exit 0
SH
  chmod +x "$WORK/rv/ssh"
  python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$WORK/rv/tmp/warm/m9.sock" 2>/dev/null
  : > "$WORK/rv/ssh.log"; rm -f "$WORK/rv/attach.pid" "$WORK/rv/down"
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

# A dropped line, then a switch (issue #1876). The proxy pane (run --shell, on
# the warm master) is attached to worker 1; the line goes down (the attach dies,
# reconnects are refused), comes back while the loop still waits out its
# back-off, and the person clicks worker 2 of the same machine. Before: `open`
# saw the warm master answer `-O check`, sent a one-shot `select` that the far
# end "did" in the fleet session (no view session was live) and kept the pane —
# whose next round attached worker 1 again. The recovery: the pane attaches
# worker 2 within CAP seconds of the click.
rv_tmux() { printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$1" > "$WORK/rv/tbin/tmux"; chmod +x "$WORK/rv/tbin/tmux"; }
rv_drop() {   # <socket> <session> — the line goes down; true once the wait page shows
  : > "$WORK/rv/down"
  kill "$(cat "$WORK/rv/attach.pid" 2>/dev/null)" 2>/dev/null
  until_ok 5 sh -c "\"$REAL_TMUX\" -S \"$1\" capture-pane -p -t \"=$2:\" | grep -q 回车立即重连"
}
rv_reconnect_stale_view() {
  CAP=3; local t0 so="$WORK/sock-rs" wid2="${RVWID%/*}/issue-2" w
  rv_shim; mkdir -p "$WORK/rv/tbin" "$WORK/rv/tmp/.claude-dash/global"; rv_tmux "$so"
  printf 'wid:%s\037m9\037online\0372\037acme/app\037working\037claude\037第二个\n' "$wid2" \
    > "$WORK/rv/tmp/.claude-dash/global/remote_rs"
  # shellcheck disable=SC2046  # rv_env is KEY=VALUE words on purpose (no spaces in $WORK)
  env $(rv_env) RV_HANG=1 "$REAL_TMUX" -S "$so" -f /dev/null new-session -d -s rs -x 100 -y 20 \
    "bash $BIN/fleet-remote-view.sh run --shell m9 $RVWID"
  w=$("$REAL_TMUX" -S "$so" display-message -p -t '=rs:' '#{window_id}')
  "$REAL_TMUX" -S "$so" set-window-option -t "$w" @remote "m9:$RVWID"
  until_ok 5 test -s "$WORK/rv/attach.pid" || { WHY="the proxy's first attach never came up"; return 1; }
  rv_drop "$so" rs || { WHY="the drop page never showed: $("$REAL_TMUX" -S "$so" capture-pane -p -t '=rs:' | grep . | tr '\n' '|')"; return 1; }
  rm -f "$WORK/rv/down"; : > "$WORK/rv/ssh.log"        # the line is back; the loop still waits
  t0=$(now)
  # shellcheck disable=SC2046
  env $(rv_env) PATH="$WORK/rv/tbin:$PATH" FLEET_SESSION=rs CCQUOTA_FLEET=1 FLEET_SHELL=1 \
    bash "$BIN/fleet-remote-view.sh" open "wid:$wid2" > /dev/null 2>&1
  until_ok "$CAP" sh -c "grep ' attach' \"$WORK/rv/ssh.log\" | tail -n 1 | grep -q 'issue-2'" \
    || { WHY="the right pane did not follow the switch in ${CAP}s — attached: $(grep -o "attach.*" "$WORK/rv/ssh.log" | tail -n 1 | cut -c1-90); shows: $("$REAL_TMUX" -S "$so" capture-pane -p -t '=rs:' | grep . | tail -n 2 | tr '\n' '|')"; return 1; }
  SECS=$(since "$t0"); WHAT="断线重连期间切换，右侧立即换到新会话"
}
drill_reconnect_stale_view() {   # its own server goes with it: a later drill's shim must not feed it
  local rc; rv_reconnect_stale_view; rc=$?
  "$REAL_TMUX" -S "$WORK/sock-rs" kill-server 2>/dev/null
  return $rc
}
# The same drop with the far end's mouse on (issue #1876): the outer tmux keeps
# handing the pane SGR mouse reports nobody reads, and the wait page echoed them
# — a drag across the right pane wrote `^[[<32;14;6M…` on the screen. The
# recovery: the pane's mouse reporting is off and a drag leaves no `[<` behind.
rv_reconnect_mouse() {
  CAP=3; local t0 so="$WORK/sock-rm" p cap
  rv_shim
  # shellcheck disable=SC2046
  env $(rv_env) RV_HANG=1 RV_MOUSE=1 "$REAL_TMUX" -S "$so" -f /dev/null new-session -d -s rm -x 100 -y 20 \
    "bash $BIN/fleet-remote-view.sh run --shell m9 $RVWID"
  "$REAL_TMUX" -S "$so" set-option -g mouse on
  p=$("$REAL_TMUX" -S "$so" display-message -p -t '=rm:' '#{pane_id}')
  until_ok 5 sh -c "[ \"\$(\"$REAL_TMUX\" -S \"$so\" display-message -p -t $p '#{mouse_any_flag}')\" = 1 ]" \
    || { WHY="the far end's mouse never came on in the pane"; return 1; }
  t0=$(now)
  rv_drop "$so" rm || { WHY="the drop page never showed"; return 1; }
  python3 - "$REAL_TMUX" "$so" <<'PYDRAG'
import fcntl, os, pty, select, signal, struct, sys, termios, time
tmux, so = sys.argv[1:3]
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM="xterm-256color", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
    os.environ.pop("TMUX", None)
    os.execvp(tmux, [tmux, "-S", so, "attach-session", "-t", "=rm"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 20, 100, 0, 0))
def pump(secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: os.read(fd, 65536)
            except OSError: return
pump(0.3)                     # inside the wait page's 2 s back-off
for seq in (b"\x1b[<0;10;5M", b"\x1b[<32;12;5M", b"\x1b[<32;14;6M", b"\x1b[<0;14;6m", b"\x1b[<0;20;8M", b"\x1b[<0;20;8m"):
    os.write(fd, seq); pump(0.05)
pump(0.2)
try: os.kill(pid, signal.SIGTERM)
except OSError: pass
PYDRAG
  "$REAL_TMUX" -S "$so" send-keys -t "$p" -X cancel 2>/dev/null   # a drag the outer tmux took: copy mode
  cap=$("$REAL_TMUX" -S "$so" capture-pane -p -t "$p")
  case "$cap" in *'[<'*|*';6M'*|*';5M'*) WHY="the drag left mouse reports on the screen: $(printf '%s' "$cap" | grep -F '[<' | head -n 2 | tr '\n' '|')"; return 1 ;; esac
  [ "$("$REAL_TMUX" -S "$so" display-message -p -t "$p" '#{mouse_any_flag}')" = 0 ] \
    || { WHY="the dropped pane still has the far end's mouse reporting on"; return 1; }
  SECS=$(since "$t0"); WHAT="断线后右侧不再收鼠标上报，拖动、点击不留乱码"
}
drill_reconnect_mouse() {   # its own server goes with it: a later drill's shim must not feed it
  local rc; rv_reconnect_mouse; rc=$?
  "$REAL_TMUX" -S "$WORK/sock-rm" kill-server 2>/dev/null
  return $rc
}

# A reconnect onto the SAME view id while the last connection's attach is still
# half alive (issue #1907, m4 2026-10-06): `run` keeps its view id across
# reconnects, the far end's old attach still held `<fleet>@view-<id>`, the new
# one's `new-session` failed and it fell back to a plain client of the fleet
# session — the node's own status line under the stage's header, its prefix
# live — and the old one's exit then removed the NEW registration. The drill:
# a node fleet on an isolated socket, a first `attach --shell - V` that never
# leaves, a second with the same id; the second must sit in a view session of
# its own (status off, prefix None), nobody on the fleet session, the row its.
vr_env() {
  printf 'env -u TMUX -u TMUX_PANE TMUX_TMPDIR=%s FLEET_CONF_DIR=%s HOME=%s PATH=%s' \
    "$WORK/vt" "$WORK/vr/conf" "$WORK/vr" "${REAL_TMUX%/*}:/usr/bin:/bin"
}
vr() { TMUX_TMPDIR="$WORK/vt" "$REAL_TMUX" -L "$1" "${@:2}"; }
vr_clients() { vr vrn list-clients -F '#{client_session}' 2>/dev/null | sort | tr '\n' ' '; }
vr_pid() { cut -f5 "$WORK/vr/conf/remote-views/$1" 2>/dev/null; }
vr_view_reconnect() {
  CAP=5; local t0 one s opts
  mkdir -p "$WORK/vt" "$WORK/vr/conf/fleets/vrn"
  printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s\n' "$WORK/vr" > "$WORK/vr/conf/fleets/vrn/conf"
  vr vrn -f /dev/null new-session -d -s vrn -n home -x 100 -y 20 'exec sleep 600' || { WHY="no node server"; return 1; }
  vr vrc -f /dev/null new-session -d -s vrc -n t1 -x 100 -y 20 \
    "$(vr_env) bash $BIN/fleet-remote-view.sh attach --shell - V1; exec sleep 600"
  until_ok 5 sh -c "[ \"\$(TMUX_TMPDIR='$WORK/vt' '$REAL_TMUX' -L vrn list-clients -F '#{client_session}')\" = 'vrn@view-V1' ]" \
    || { WHY="the first attach never sat in its view session: [$(vr_clients)]"; return 1; }
  one=$(vr_pid V1)
  t0=$(now)
  # the reconnect: the same view id, while the first attach still holds it
  vr vrc new-window -d -t vrc: -n t2 "$(vr_env) bash $BIN/fleet-remote-view.sh attach --shell - V1; exec sleep 600"
  until_ok "$CAP" sh -c "two=\$(cut -f5 '$WORK/vr/conf/remote-views/V1' 2>/dev/null); [ -n \"\$two\" ] && [ \"\$two\" != '$one' ] \
      && [ \"\$(TMUX_TMPDIR='$WORK/vt' '$REAL_TMUX' -L vrn list-clients -F '#{client_session}')\" = 'vrn@view-V1' ]" \
    || { WHY="after the reconnect the node's clients are [$(vr_clients)] (want one, on vrn@view-V1), row pid $(vr_pid V1) (first was $one)"; return 1; }
  SECS=$(since "$t0")
  s=$(vr vrn list-clients -F '#{client_session}' | head -n 1)
  opts="$(vr vrn show-options -qv -t "=$s:" status) $(vr vrn show-options -qv -t "=$s:" prefix)"
  [ "$opts" = "off None" ] || { WHY="the view session $s has status/prefix [$opts], want [off None]"; return 1; }
  kill -0 "$one" 2>/dev/null && { WHY="the first attach ($one) is still alive beside the second"; return 1; }
  # the second leaves: its own row and session go, nothing else is left behind
  vr vrc kill-window -t vrc:t2
  until_ok 5 sh -c "[ ! -e '$WORK/vr/conf/remote-views/V1' ] && ! TMUX_TMPDIR='$WORK/vt' '$REAL_TMUX' -L vrn has-session -t '=vrn@view-V1' 2>/dev/null" \
    || { WHY="the second's exit left its row ($(vr_pid V1)) or its session behind"; return 1; }
  # An orphan: a registered attach whose tmux client the server no longer has
  # (its line died, the client hangs in a tty write). `health` counts it, the
  # next attach reaps it and its row.
  mkdir -p "$WORK/vr/fake"; printf 'sleep 600\n' > "$WORK/vr/fake/fleet-remote-view.sh"
  bash "$WORK/vr/fake/fleet-remote-view.sh" attach --shell - V9 >/dev/null 2>&1 </dev/null & one=$!
  printf '/dev/ttys999\tvrn\tshell\t%s\t%s\n' "$(date +%s)" "$one" > "$WORK/vr/conf/remote-views/V9"
  s=$(eval "$(vr_env) FLEET_REMOTE_ORPHAN_SECS=0 bash $BIN/fleet-remote-view.sh health" 2>&1)
  [ "$s" = "shared=0 orphans=1" ] || { pkill -P "$one"; kill "$one" 2>/dev/null; WHY="health with one orphan says [$s]"; return 1; }
  vr vrc new-window -d -t vrc: -n t3 "$(vr_env) FLEET_REMOTE_ORPHAN_SECS=0 bash $BIN/fleet-remote-view.sh attach --shell - V3; exec sleep 600"
  until_ok 5 sh -c "! kill -0 $one 2>/dev/null && [ ! -e '$WORK/vr/conf/remote-views/V9' ]" \
    || { pkill -P "$one"; kill "$one" 2>/dev/null; WHY="the next attach left the orphan ($one) or its row"; return 1; }
  wait "$one" 2>/dev/null
  s=$(eval "$(vr_env) bash $BIN/fleet-remote-view.sh health" 2>&1)
  [ "$s" = "shared=0 orphans=0" ] || { WHY="health after the reap says [$s]"; return 1; }
  WHAT="同一 view id 重连：旧 attach 收掉，新的在自己的视图会话（status off、prefix None），无人挂在 fleet 会话上；孤儿 attach 下一次 attach 收掉"
}
drill_view_reconnect_shared() {
  local rc; vr_view_reconnect; rc=$?
  vr vrc kill-server 2>/dev/null; vr vrn kill-server 2>/dev/null
  return $rc
}

# The client's files replaced under the running client with no reload (issue
# #1829): a pre-#1781 `start` moved the whole home aside while the shell ran
# (the person's laptop, 02:31), or the install line wrote it in place. The old
# proxy loop kept running beside new code that opened a second connection —
# #1775's refused 2226. The drill: an installed client (its own home, a
# .client-version) running with its keeper on a 1 s beat; the break is new
# files in that home; the recovery is the keeper reloading them into the
# running servers — the stamp moves, the proxy pane is a new process.
drill_client_files_swapped() {
  CAP=15; local s="${CSESS}u" H="$WORK/uhome" t0 pp
  client_setup
  mkdir -p "$H/bin"
  cp -P "$WORK"/sbin/* "$H/bin/"
  for f in fleet-shell.sh fleet-client-update.sh; do rm -f "$H/bin/$f"; cp "$BIN/$f" "$H/bin/$f"; done
  ln -s "$WORK/conf" "$H/conf"
  printf 'version=v1\ncompat=1\ncommit=c0ffee1\nhub=https://hub.example\n' > "$H/.client-version"
  ( client_env
    export FLEET_SHELL_SESSION="$s" FLEET_SHELL_CACHE="$WORK/ucache" FLEET_CLIENT_LEASE_CMD=false \
           FLEET_CLIENT_LEASE_EVERY=1 FLEET_CLIENT_IDLE_SECS=0 FLEET_CLIENT_CHECK_SECS=999999
    mkdir -p "$XDG_CACHE_HOME/claude-fleet/client"; date +%s > "$XDG_CACHE_HOME/claude-fleet/client/checked"
    bash "$H/bin/fleet-shell.sh" >"$WORK/up-$s.out" 2>"$WORK/up-$s.err" )
  [ "$(cat "$WORK/up-$s.out" 2>/dev/null)" = "$s" ] || { WHY="the installed client did not start: $(head -3 "$WORK/up-$s.err")"; return 1; }
  upid() { "$REAL_TMUX" -L "$s-stage" list-panes -s -F '#{pane_pid} #{pane_start_command}' 2>/dev/null | awk '/fleet-remote-view.sh/ { print $1; exit }'; }
  until_ok 5 sh -c "[ -n \"\$(\"$REAL_TMUX\" -L $s-stage list-panes -s -F '#{pane_start_command}' 2>/dev/null | grep fleet-remote-view.sh)\" ]" \
    || { WHY="no proxy pane on the installed client's stage"; return 1; }
  pp=$(upid)
  t0=$(now)
  printf 'version=v2\ncompat=1\ncommit=beef002\nhub=https://hub.example\n' > "$H/.client-version"   # the break
  until_ok "$CAP" sh -c "[ \"\$(\"$REAL_TMUX\" -L $s show-options -gqv @client_version 2>/dev/null)\" = v2 ]" \
    || { WHY="the running client still runs what it loaded (@client_version=$("$REAL_TMUX" -L "$s" show-options -gqv @client_version 2>/dev/null)) after ${CAP}s"; return 1; }
  until_ok 5 sh -c "p=\$(\"$REAL_TMUX\" -L $s-stage list-panes -s -F '#{pane_pid} #{pane_start_command}' 2>/dev/null | awk '/fleet-remote-view.sh/ { print \$1; exit }'); [ -n \"\$p\" ] && [ \"\$p\" != $pp ]" \
    || { WHY="the old proxy loop ($pp) was kept beside the new code"; return 1; }
  SECS=$(since "$t0")
  grep -q '"phase": "done"' "$WORK/ucache/update.state" 2>/dev/null || { WHY="no trace of the update: update.state is not done"; return 1; }
  WHAT="新文件载入正在跑的客户端，旧代理换掉，留下「已更新到」"
}

# ============================================ a fleet's tmux, deleted from a shell ======
# (issue #1841, EPIC #1851 C2) A fleet is `-L <its label>` since #159, so the old
# guard's "a -L means an isolated test server" let every fleet through; and only an
# interactive zsh that sourced cw.zsh had a guard at all — a session's `bash -c`,
# `sh -c`, Codex's shell, Claude's `!` went straight to tmux. The sandbox: a fleet
# `kf` (its conf in a sandbox FLEET_CONF_DIR) on a -L label under a sandbox
# TMUX_TMPDIR, one session window (@fleet_id) beside home, and the real
# fleet-session-wrap.sh launching a fake agent that types the deletes.
kf_env() {
  export FLEET_CONF_DIR="$WORK/kconf" TMUX_TMPDIR="$WORK/ktt" ZDOTDIR="$WORK/kzd"
  unset TMUX TMUX_PANE FLEET_ALLOW_TMUX_DESTROY FLEET_HUB
  mkdir -p "$FLEET_CONF_DIR/fleets/kf" "$TMUX_TMPDIR" "$ZDOTDIR"
  printf 'FLEET_REPO=acme/widgets\n' > "$FLEET_CONF_DIR/fleets/kf/conf"
  "$REAL_TMUX" -L kf has-session -t kf 2>/dev/null && return 0
  "$REAL_TMUX" -L kf new-session -d -s kf -n home 'exec sleep 600' \
    && "$REAL_TMUX" -L kf new-window -d -t kf -n issue-7 'exec sleep 600' \
    && "$REAL_TMUX" -L kf set-option -w -t kf:issue-7 @fleet_id 7f7f7f7f
}
kf_up() { "$REAL_TMUX" -L kf has-session -t kf 2>/dev/null && [ "$("$REAL_TMUX" -L kf list-windows -t kf -F '#{window_name}' 2>/dev/null | sort | tr '\n' ' ')" = "home issue-7 " ]; }
# kf_agent <script> — run <script> (bash) as the agent the real wrapper launches
kf_agent() {
  printf '#!/bin/bash\n%s\n' "$1" > "$WORK/kagent"; chmod +x "$WORK/kagent"
  FLEET_WRAP_LAUNCH="$WORK/kagent" FLEET_MCP=0 bash "$BIN/fleet-session-wrap.sh" 2>&1
}

drill_shell_kill_fleet() {
  CAP=30; local t0 out sh cmd
  t0=$(now)
  ( kf_env
    for sh in 'bash -c' 'sh -c' 'zsh -fc'; do
      command -v "${sh%% *}" >/dev/null 2>&1 || continue      # no zsh on a linux runner
      for cmd in 'tmux -L kf kill-server' 'tmux -L kf kill-session -t kf' 'tmux -L kf kill-window -t kf:issue-7' \
                 "tmux -S $TMUX_TMPDIR/tmux-$(id -u)/kf kill-server"; do
        out=$(kf_agent "$sh '$cmd'")
        kf_up || { echo "WHY=$sh '$cmd' deleted it: [$out]"; exit 1; }
        case "$out" in *拒绝*FLEET_ALLOW_TMUX_DESTROY=1*) ;; *) echo "WHY=$sh '$cmd' gave no reason/hatch: [$out]"; exit 1 ;; esac
      done
    done
    # the test server and a non-session window are not the fleet's
    "$REAL_TMUX" -L "kscr$$" new-session -d -s s 'exec sleep 600'
    out=$(kf_agent "bash -c 'tmux -L kscr$$ kill-server'")
    "$REAL_TMUX" -L "kscr$$" has-session 2>/dev/null && { echo "WHY=-L kscr$$ kill-server was not let through: [$out]"; exit 1; }
    "$REAL_TMUX" -L kf new-window -d -t kf -n scratchpad 'exec sleep 600'
    out=$(kf_agent "bash -c 'tmux -L kf kill-window -t kf:scratchpad'")
    kf_up || { echo "WHY=a plain window's kill-window was refused or took more: [$out]"; exit 1; }
    # the Bash tool (Claude's and Codex's): hooks/bash-guard.py says the same,
    # before it runs — a login shell's path_helper puts the real tmux back in front
    for cmd in 'tmux -L kf kill-server' "bash -lc 'tmux -L kf kill-server'" \
               "zsh -lc \"echo hi; tmux -L kf kill-session -t kf\"" "${REAL_TMUX} -L kf kill-window -t kf:issue-7"; do
      out=$(python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))' "$cmd" \
            | python3 "$ROOT/hooks/bash-guard.py" 2>&1)
      [ $? = 2 ] || { echo "WHY=bash-guard let [$cmd] through: [$out]"; exit 1; }
    done
    out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"tmux -L scratch kill-server"}}' | python3 "$ROOT/hooks/bash-guard.py" 2>&1)
    [ $? = 0 ] || { echo "WHY=bash-guard refused -L scratch: [$out]"; exit 1; }
    # the escape hatch, last: it really deletes
    out=$(FLEET_ALLOW_TMUX_DESTROY=1 kf_agent "bash -c 'tmux -L kf kill-server'")
    "$REAL_TMUX" -L kf has-session 2>/dev/null && { echo "WHY=FLEET_ALLOW_TMUX_DESTROY=1 did not let it through: [$out]"; exit 1; }
    exit 0
  ) > "$WORK/kf.out"; local rc=$?
  [ "$rc" = 0 ] || { WHY=$(sed -n 's/^WHY=//p' "$WORK/kf.out" | head -1); WHY=${WHY:-"the drill died (rc $rc)"}; return 1; }
  SECS=$(since "$t0"); WHAT="bash / sh / zsh -c / 登录 shell / Bash 工具里删 fleet 都被拒，-L 测试服务器和逃生口放行"
}

drill_zsh_guard_fleet_label() {
  CAP=30; local t0 out
  command -v zsh >/dev/null 2>&1 || { SECS=0; WHAT="zsh 不在，跳过"; return 0; }
  t0=$(now)
  ( kf_env
    # an interactive zsh, as the person's: -i stops the shim's plumbing walk there
    z() { zsh -fic "source '$ROOT/shell/cw.zsh' >/dev/null 2>&1; $1" 2>&1 </dev/null; }
    out=$(PATH="/usr/bin:/bin:${REAL_TMUX%/*}" z 'tmux -L kf kill-server')
    kf_up || { echo "WHY=cw.zsh's tmux() let -L kf kill-server through: [$out]"; exit 1; }
    case "$out" in *拒绝*) ;; *) echo "WHY=no reason given: [$out]"; exit 1 ;; esac
    "$REAL_TMUX" -L "kscr$$" new-session -d -s s 'exec sleep 600'
    out=$(z "tmux -L kscr$$ kill-server")
    "$REAL_TMUX" -L "kscr$$" has-session 2>/dev/null && { echo "WHY=cw.zsh refused -L kscr$$: [$out]"; exit 1; }
    out=$(FLEET_ALLOW_TMUX_DESTROY=1 z 'tmux -L kf kill-server')
    "$REAL_TMUX" -L kf has-session 2>/dev/null && { echo "WHY=the hatch did not pass: [$out]"; exit 1; }
    exit 0
  ) > "$WORK/kz.out"; local rc=$?
  [ "$rc" = 0 ] || { WHY=$(sed -n 's/^WHY=//p' "$WORK/kz.out" | head -1); WHY=${WHY:-"the drill died (rc $rc)"}; return 1; }
  SECS=$(since "$t0"); WHAT="交互 zsh 的 tmux() 不再把 -L <fleet> 当测试服务器"
}

# conf-keys-lost (issue #1887): the machine's fleet.conf carries a key a person
# added ([client] FLEET_UI_LANG=zh) on a laptop that only coordinates — a fleet
# conf fleet-up left behind, no node.env, no fleet running. A sync runs
# install-apply's two passes, layout then conf. Before the fix the layout pass
# took fleet.conf for fleet `fleet`'s stale duplicate and deleted it, the conf
# pass rebuilt it from its template — the key gone, no backup — and called the
# machine 承载 (FLEET_HOST=1) for its leftover fleet conf. Now: the key stays,
# hub-defaults.conf stays where the shell reads it, a migrated FLEET_HOST=1 goes
# to 0 once with the old file kept as .bak-<time>; an old FLEET_ROLE="client,node"
# on a node.env COMPUTE=0 machine becomes FLEET_HOST=0 with its keys and a backup;
# a real host (node.env, no COMPUTE line) keeps FLEET_HOST=1.
drill_conf_keys_lost() {
  CAP=5; local t0 d="$WORK/ck" c out
  ck() {   # <case> <cmd…> — one sandbox login per case
    local h="$d/$1"; shift
    env -u TMUX HOME="$h/home" FLEET_CONF_DIR="$h/conf" XDG_CONFIG_HOME="$h/home/.config" \
      FLEET_LAUNCHD_AGENTS_DIR="$h/home/LA" FLEET_INSTALL_DAEMON_DIR="$h/home/LD" \
      TMUX_TMPDIR="$h/tt" FLEET_SKIP_GLOBAL_CONF=1 "$@"
  }
  ckconf() {   # <case> <common lines> <client lines>
    mkdir -p "$d/$1/conf/fleets/fleet" "$d/$1/home" "$d/$1/tt"
    printf 'FLEET_REPO="o/r"\nFLEET_MAIN="%s/nowhere"\nFLEET_BASE_BRANCH="master"\n' "$d" > "$d/$1/conf/fleets/fleet/conf"
    printf '# hub-defaults.conf — the team defaults\nFLEET_SIDEBAR_WIDTH=30\n' > "$d/$1/conf/hub-defaults.conf"
    { printf "# claude-fleet — this machine's ONE config file (issue #1623). Assignments only.\n"
      printf '# Migrated by fleet-conf.sh 2026-10-05 23:23:53 from: fleets/fleet/conf\n\n# ---- [common] ----\n%s\n' "$2"
      printf 'export FLEET_HUB_URL="https://hub.example"\n\n# ---- [client] — only the shell ----\n'
      printf 'if [ "${FLEET_SHELL:-0}" = 1 ]; then\n:\n%s\nfi  # ---- [client] end ----\n' "$3"
      printf '\n# ---- [node] ----\nif [ "${FLEET_SHELL:-0}" != 1 ]; then\n:\nfi  # ---- [node] end ----\n'
    } > "$d/$1/conf/fleet.conf"
  }
  sync_passes() { ck "$1" bash "$BIN/fleet-migrate-layout.sh" && ck "$1" bash "$BIN/fleet-conf.sh" migrate; }
  ckconf laptop 'FLEET_HOST=1' 'export FLEET_UI_LANG=zh'
  ckconf role 'FLEET_ROLE="client,node"' 'export FLEET_UI_LANG=zh'
  printf 'CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_FLEET_COMPUTE=0\n' > "$d/role/conf/node.env"
  ckconf host 'FLEET_HOST=1' 'export FLEET_UI_LANG=zh'
  printf 'CCQUOTA_HUB_URL=https://hub.example\n' > "$d/host/conf/node.env"
  t0=$(now)
  for c in laptop role host; do
    out=$(sync_passes "$c" 2>&1) || { WHY="$c: a sync pass failed: $(printf '%s' "$out" | tail -1)"; return 1; }
    [ -f "$d/$c/conf/fleet.conf" ] || { WHY="$c: the sync deleted fleet.conf: $(printf '%s' "$out" | head -1)"; return 1; }
    sed -n '/FLEET_SHELL:-0}" = 1/,/\[client\] end/p' "$d/$c/conf/fleet.conf" | grep -q '^export FLEET_UI_LANG=zh$' \
      || { WHY="$c: [client] lost FLEET_UI_LANG=zh: $(grep -c . "$d/$c/conf/fleet.conf") lines, $(printf '%s' "$out" | tail -1)"; return 1; }
    [ -f "$d/$c/conf/hub-defaults.conf" ] || { WHY="$c: hub-defaults.conf was moved away from where the shell reads it"; return 1; }
  done
  for c in laptop role; do
    grep -q '^FLEET_HOST=0$' "$d/$c/conf/fleet.conf" \
      || { WHY="$c: a machine that hosts nothing reads $(grep -E '^FLEET_(HOST|ROLE)=' "$d/$c/conf/fleet.conf" | tr '\n' ' ')"; return 1; }
    ls "$d/$c/conf"/fleet.conf.bak-* >/dev/null 2>&1 || { WHY="$c: rewrote fleet.conf with no fleet.conf.bak-<time>"; return 1; }
  done
  grep -q '^FLEET_HOST=1$' "$d/host/conf/fleet.conf" || { WHY="host: a real host lost FLEET_HOST=1"; return 1; }
  out=$(sync_passes laptop 2>&1); grep -q '^FLEET_HOST=0$' "$d/laptop/conf/fleet.conf" \
    && [ "$(ls "$d/laptop/conf"/fleet.conf.bak-* | wc -l | tr -d ' ')" = 1 ] \
    || { WHY="laptop: the second sync changed it again: $out"; return 1; }
  SECS=$(since "$t0"); WHAT="同步后手加的键还在、有备份；只协调的机器 FLEET_HOST=0，真承载的仍是 1"
}

# A session's test takes the person's client (issue #1931, EPIC #1906 C12): on
# 2026-10-06 a drill (#1901) on m4 connected to the hub as the operator and took
# their one client lease — the MacBook fell to its standby screen again and again.
# A fake hub on loopback keeps the hub's rules (an acquire takes the slot over; a
# request marked X-Fleet-Worker that asks for the person's lease is 403, with the
# reason; the test door is its own slot) and dies on its own deadline. The person
# acquires first; then, from a SESSION's environment (a worker credential):
# fleet-client-lease.py acquire asks at the test door, as test, marked — and the
# person's lease and where are unchanged; FLEET_CLIENT_IDENTITY=person is refused
# 403 with the reason; outside a session the person's acquire is unmarked; and
# bash-guard refuses a session starting `fleet` / `fleet m4` / fleet-shell.sh /
# `ssh m4 fleet` without --test-identity, lets `fleet --test-identity`,
# `fleet doctor` and the hatch through.
drill_session_takes_client() {
  CAP=30; local t0 hub port out rc h before after
  t0=$(now)
  hub="$WORK/fakehub-$$"; mkdir -p "$hub"
  cat > "$hub/hub.py" <<'PY2'
import json, os, signal, sys, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
signal.alarm(int(sys.argv[2]))           # never outlives the drill
D = sys.argv[1]
cur = {}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        worker = (self.headers.get("X-Fleet-Worker") or "").strip()
        test = self.path == "/v1/fleet/client/test" or body.get("identity") == "test"
        with open(os.path.join(D, "log"), "a") as f:
            f.write("%s %s worker=%s identity=%s\n" % (self.path, body.get("action"), "yes" if worker else "no", body.get("identity", "")))
        if self.path not in ("/v1/fleet/client", "/v1/fleet/client/test"):
            self.send_response(404); self.end_headers(); return
        if worker and not test:
            out, code = {"error": "a session may not take the person's client lease — run as the test identity"}, 403
        else:
            slot = "test" if test else "person"
            a = body.get("action")
            if a == "acquire":
                cur[slot] = {"id": uuid.uuid4().hex[:12], "device": body.get("device", "")}
            out = {"state": "active" if cur.get(slot) else "none", "lease": cur.get(slot)}
            if test: out["identity"] = "test"
            code = 200
        with open(os.path.join(D, "person"), "w") as f:
            json.dump(cur.get("person"), f)
        b = json.dumps(out).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
s = HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(D, "port.tmp"), "w") as f:
    f.write(str(s.server_address[1]))
os.replace(os.path.join(D, "port.tmp"), os.path.join(D, "port"))
s.serve_forever()
PY2
  ( python3 -u "$hub/hub.py" "$hub" "$((CAP + 10))" </dev/null >"$hub/out" 2>&1 & )
  until_ok 15 test -s "$hub/port" \
    || { WHY="the fake hub did not start: $(tr '\n' ' ' < "$hub/out" | tail -c 400)"; return 1; }
  port=$(cat "$hub/port")
  lease() {  # <env…> -- lease args
    local e=()
    while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
    env -u FLEET_WORKER_CRED -u FLEET_WORKER_ASSERT -u FLEET_SEAT -u FLEET_CLIENT_IDENTITY -u SSH_CONNECTION \
      HOME="$WORK/home" FLEET_CONF_DIR="$hub/conf" FLEET_HUB_URL="http://127.0.0.1:$port" FLEET_HUB_TOKEN=tok \
      FLEET_CLIENT_XTVERSION=0 ${e[@]+"${e[@]}"} python3 "$BIN/fleet-client-lease.py" "$@"
  }
  # the person, at their own terminal
  out=$(lease FLEET_CLIENT_DEVICE=MacBook -- acquire 2>&1) || { WHY="the person's acquire failed: $out"; return 1; }
  before=$(cat "$hub/person")
  grep -q '^/v1/fleet/client acquire worker=no identity=$' "$hub/log" \
    || { WHY="the person's acquire went out marked or as test: $(cat "$hub/log")"; return 1; }
  # a session's test, default identity
  out=$(lease FLEET_WORKER_CRED=fwc1.x FLEET_CLIENT_DEVICE=m4-drill -- acquire 2>&1); rc=$?
  after=$(cat "$hub/person")
  [ "$rc" = 0 ] && [ "$after" = "$before" ] \
    || { WHY="a session's acquire took the person's lease (rc $rc): $before → $after [$out]"; return 1; }
  grep -q '^/v1/fleet/client/test acquire worker=yes identity=test$' "$hub/log" \
    || { WHY="a session's acquire did not ask as the marked test identity: $(cat "$hub/log")"; return 1; }
  # a session asking for the person's lease outright: 403 + why
  out=$(lease FLEET_WORKER_CRED=fwc1.x FLEET_CLIENT_IDENTITY=person -- acquire 2>&1); rc=$?
  [ "$rc" = 1 ] || { WHY="FLEET_CLIENT_IDENTITY=person in a session was not refused (rc $rc): $out"; return 1; }
  case "$out" in *403*test\ identity*) ;; *) WHY="the refusal does not say why: [$out]"; return 1 ;; esac
  [ "$(cat "$hub/person")" = "$before" ] || { WHY="a refused acquire still moved the person's lease"; return 1; }
  # the guard: a session's client start must say --test-identity
  h=( env -u FLEET_HUB FLEET_WORKER_CRED=fwc1.x FLEET_HEAVY=0 FLEET_LIB=/nonexistent python3 "$ROOT/hooks/bash-guard.py" )
  for cmd in 'fleet' 'fleet m4' 'FLEET_HUB_URL=https://hub.example fleet' "$BIN/fleet-shell.sh" 'ssh m4 fleet' 'ssh -p 22022 m4 "fleet shell"'; do
    out=$(python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))' "$cmd" | "${h[@]}" 2>&1)
    [ $? = 2 ] || { WHY="bash-guard let a session's [$cmd] through"; return 1; }
    case "$out" in *--test-identity*FLEET_ALLOW_PERSON_CLIENT=1*) ;; *) WHY="bash-guard gave no way out for [$cmd]: [$out]"; return 1 ;; esac
  done
  for cmd in 'fleet --test-identity m4' 'FLEET_CLIENT_IDENTITY=test fleet' 'fleet doctor' 'ssh m4 fleet --test-identity' 'FLEET_ALLOW_PERSON_CLIENT=1 fleet'; do
    out=$(python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))' "$cmd" | "${h[@]}" 2>&1)
    [ $? = 0 ] || { WHY="bash-guard refused [$cmd]: [$out]"; return 1; }
  done
  out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"fleet m4"}}' \
        | env -u FLEET_WORKER_CRED -u FLEET_HUB FLEET_HEAVY=0 FLEET_LIB=/nonexistent python3 "$ROOT/hooks/bash-guard.py" 2>&1)
  [ $? = 0 ] || { WHY="bash-guard refused a person's own fleet: [$out]"; return 1; }
  SECS=$(since "$t0"); WHAT="执行会话的客户端只拿测试身份：运营者租约不变，要运营者租约被拒（403 + 原因），守卫拦没写 --test-identity 的启动"
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
