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
#   orchestrator-closed                             bin/fleet-orchestrator.sh ensure (fleet-up.sh,
#                                                   fleet-diskguard.sh home_watch)
#   orchestrator-two                                bin/fleet-orchestrator.sh ensure asks the hub
#                                                   (/v1/node/orchestrator) which machine holds it
#   break-pane                                      bin/fleet-window-carry.sh (conf/tmux-attention.conf hook)
#   install-sync-killed                             bin/fleet-install-sync.sh (the tick lock)
#   epic-mark-overwritten / epic-fresh-switched     bin/fleet-epic-heartbeat.sh (one mark per batch),
#                                                   fleet_epic_running_fresh, fleet-install-sync.sh (the EPIC gate)
#   epic-idle-held / epic-hold-uncapped             fleet_epic_holding (live/inflight), fleet-install-sync.sh
#                                                   (epic_gate: idle never holds, FLEET_EPIC_HOLD_CAP_SECS caps a hold)
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
#   tool-wait-idle                                  fleet_window_tool_busy / fleet_window_wait (fleet-lib.sh),
#                                                   fleet-state-reconcile.py, bin/set-claude-state.sh (Stop),
#                                                   fleet-wait-reeval.sh
#   cfg-reopen-loop                                 fleet_cfg_restart_why (fleet-lib.sh: the transcript backfill),
#                                                   bin/fleet-migrate.sh (cfg_update_nudge, the /loop rearm)
#   fleet-down-confirm                              bin/fleet-down.sh (confirm, --yes), fleet-up.sh --undo,
#                                                   fleet-restore.sh --undo
#   breakage-three-filers                           bin/fleet-issue-file.sh --breakage, fleet_breakage_probe /
#                                                   fleet_breakage_find (fleet-lib.sh)
#   breakage-no-flag                                bin/fleet-issue-file.sh (auto), fleet_breakage_pick /
#                                                   fleet_breakage_text_red_word (fleet-lib.sh), fleet-mcp.py file_issue
#   node-paused-still-placed                        bin/fleet-control-read.sh capacity (admit / admit_why / room),
#                                                   fleet_machine_admit, fleet_machine_headroom; the hub half is
#                                                   tokenledger/internal/api judge() (go test, when a toolchain is here)
#   dispatch-wrong-replica                          tokenledger/internal/api node_route.go (fleet_node_conns +
#                                                   /internal/v1/node-write; go test, when a toolchain is here)
#   oldcfg-deleted-hook                             bin/fleet-stable.sh move (the oldcfg gate), fleet-oldcfg-replay.py
#   macos-red-to-stable                             bin/fleet-macos-watch.sh (breakage filing), fleet-stable.sh move (macos gate)
#   two-hubs-double-refresh                         tokenledger/internal/leader (Leader / Lock), credvault Lease's
#                                                   CrossLock, the three gated loops (go test, when a toolchain is here)
#   hub-release-downtime                            .github/actions/hub-release/probe.sh (downtime_seconds),
#                                                   release.sh shape, deploy/k8s/base (2 replicas, rolling,
#                                                   /readyz, preStop, PDB), tokenledger /readyz + /v1/deploy-probe
#                                                   (go test, when a toolchain is here); the kind drill is
#                                                   .github/workflows/hub-rolling.yml
#   hub-disk-attach-stuck                           deploy/k8s/base (no PVC), components/sqlite-single
#   invite-expired                                  tokenledger/internal/api fleet_invites.go + github_auth.go
#                                                   (admitInvite, denyText; go test, when a toolchain is here)
#   login-browser-silent                            bin/fleet-login.py (scan: open_browser, KeyWatch, nudge, timeout)
#   login-sandbox-real-conf                         bin/fleet-login.py (conf_dir_env)
#   spare-login-empty                               tokenledger/internal/api fleet_spare.go + fleet_accounts.go
#                                                   (claimSpare, replenishSpares; go test, when a toolchain is here)
#   release-tampered                                tokenledger/internal/api fleet_release.go (ReleaseStore) +
#                                                   internal/release (Build, Fetch, Unpack; go test, when a toolchain is here)
#   trust-name-borrowed                             tokenledger/internal/api fleet_trust.go (nodeTrust) + fleet_node_desired.go
#                                                   (go test, when a toolchain is here)
#   lease-unseparated-user                          tokenledger/internal/api fleet_creds.go (credsepGated) + fleet_join.go
#                                                   (/v1/node/self credsep_gate), internal/agent node_credsep.go,
#                                                   bin/fleet-cred-proxy.py (Router.refresh); go test, when a toolchain is here
#   oldcfg-broken-unmarked                          bin/fleet-oldcfg-check.sh --sweep (fleet-oldcfg-replay.py --manifest),
#                                                   fleet_cfg_state / fleet_cfg_broken_load (fleet-lib.sh), fleet-ui-lang.sh
#   pool-stale-handed-out                           bin/scratch-pool.sh claim / reap (usable: fleet_cfg_state)
#   pretrust-norepo                                 bin/fleet-trust.sh (node, grant --home), bin/fleet-claude.sh
# Client half — the real client (bin/fleet → fleet-shell.sh) on isolated -L
# sockets, an ssh shim for the far end, a python pty as the person's terminal:
#   client-kill-keys / client-pane-killed / sidebar-ctrl-c / nested-drop
#                                                   conf/tmux-shell.conf, fleet-sidebar.py,
#                                                   fleet-remote-view.sh
#   client-kill-server                              bin/fleet (run again)
#   hub-unreachable                                 bin/fleet, fleet-client-badge.sh
#   hub-refused-cert                                fleet-client-lease.py where, fleet-client-where.sh,
#                                                   fleet-client-badge.sh
#   cert-expiry-keeper                              bin/fleet-shell.sh (keeper), fleet-login.py renew --if-under
#   offline-list-moves                              tmux-dashboard-rows.sh (lost rows stay put), fleet-sidebar.py
#   static-forward / proxy-orphan                   bin/fleet-remote-view.sh (run), fleet-shell.sh
#   reconnect-stale-view / reconnect-mouse          bin/fleet-remote-view.sh (run, open, select)
#   view-reconnect-shared                           bin/fleet-remote-view.sh (attach, rv_prune)
#   client-files-swapped                            bin/fleet-client-update.sh (tick), fleet-shell.sh reload
#   client-unversioned-drift                        bin/fleet-client-update.sh (tick, digest), fleet-shell.sh stamp_ver
#   client-sidebar-stale-after-update               bin/fleet-sidebar.py (VIEW_STAMP, sync), fleet-shell.sh reload
#   hub-restart-where                               bin/fleet-shell.sh (keeper renew), fleet-client-lease.py renew,
#                                                   fleet-client-where.sh
# Cred half — cred-* rows: bin/fleet-break-it-cred-selftest.sh runs them (its own
#   test; listed here only through the lockstep lint) — and cred-shared-down,
#   bin/fleet-break-it-cred-shared-selftest.sh (issue #2217) — and cred-sep-by-agent /
#   cred-sep-bootstrap-fails, bin/fleet-break-it-cred-sep-selftest.sh (issue #2273).
# Shell half — a sandbox fleet on -L kf (TMUX_TMPDIR under $WORK), the real wrapper:
#   shell-kill-fleet                                bin/tmux-shim/tmux, fleet-session-wrap.sh, hooks/bash-guard.py
#   zsh-guard-fleet-label                           shell/cw.zsh tmux()
# Machine half — a sandbox Homebrew prefix under a world-traversable tmp dir:
#   brew-keg-700                                    bin/fleet-diskguard.sh --brew-watch,
#                                                   bin/fleet-brew-perms.sh, shell/cw.zsh brew()
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
  for s in "$CSESS" "$CSESS-stage" "${CSESS}h" "${CSESS}h-stage" "${CSESS}o" "${CSESS}o-stage" "${CSESS}u" "${CSESS}u-stage" "${CSESS}w" "${CSESS}w-stage" "${CSESS}s" "${CSESS}s-stage"; do "$REAL_TMUX" -L "$s" kill-server 2>/dev/null; done
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
# The cred half lives in its own script (issue #1975: its own run, its own
# durations row) — its drills are listed rows like any other.
DRILLS=$(sed -n 's/^drill_\([a-z0-9_]*\)() *{.*/\1/p' "$0" "$BIN/fleet-break-it-cred-selftest.sh" "$BIN/fleet-break-it-cred-shared-selftest.sh" "$BIN/fleet-break-it-cred-sep-selftest.sh" "$BIN/fleet-break-it-node-selftest.sh" | tr _ -)
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

# orchestrator-closed (issue #1957): the fleet's one orchestrating session is
# closed — the tick's home_watch opens it again, in $HOME, on the same Claude
# conversation (its id kept in fleets/<sess>/orchestrator.sid, its transcript on
# disk), told by @fleet_role orchestrator whatever it was renamed to.
drill_orchestrator_closed() {
  CAP=5; BREAK_SOCK="$WORK/sock-or"; local t0 w w2 sid oa="$WORK/orch-argv" h="$WORK/ohome"
  grep -q 'fleet-orchestrator.sh" ensure' "$BIN/fleet-up.sh" || { WHY="fleet-up.sh no longer opens the orchestrator"; return 1; }
  sed -n '/^home_watch()/,/^}/p' "$BIN/fleet-diskguard.sh" | grep -q 'fleet-orchestrator.sh" ensure' \
    || { WHY="the diskguard tick's home_watch no longer reopens the orchestrator"; return 1; }
  mkdir -p "$h"; : > "$oa"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\nexec sleep 600\n' "$oa" > "$WORK/orch-agent"; chmod +x "$WORK/orch-agent"
  nt -f /dev/null new-session -d -s or -n home -x 100 -y 30 'exec sh' || { WHY="cannot start the isolated tmux server"; return 1; }
  oens() { env PATH="$WORK/tbin:$PATH" HOME="$h" FLEET_CONF_DIR="$WORK/oconf" FLEET_SKIP_GLOBAL_CONF=1 BREAK_SOCK="$BREAK_SOCK" \
             FLEET_ORCHESTRATOR=1 FLEET_AGENT=claude FLEET_WRAP_LAUNCH="$WORK/orch-agent" bash "$BIN/fleet-orchestrator.sh" ensure or 2>/dev/null; }
  w=$(oens) || { WHY="ensure did not open it"; return 1; }
  until_ok 5 grep -q . "$oa" || { WHY="the orchestrator's agent never started"; return 1; }
  grep -q -- '--model fable --effort high --session-id .* /fleet-orchestrate' "$oa" || { WHY="not the strongest model at high effort, seeded: $(cat "$oa")"; return 1; }
  [ "$(o "$w" @fleet_role)" = orchestrator ] || { WHY="no @fleet_role orchestrator on $w"; return 1; }
  [ "$(o "$w" pane_current_path)" = "$(cd "$h" && pwd -P)" ] || [ "$(o "$w" pane_current_path)" = "$h" ] || { WHY="not opened in \$HOME: $(o "$w" pane_current_path)"; return 1; }
  [ "$(oens)" = "$w" ] || { WHY="a second ensure opened a second one"; return 1; }
  sid=$(cat "$WORK/oconf/fleets/or/orchestrator.sid" 2>/dev/null)
  [ -n "$sid" ] || { WHY="no conversation id kept"; return 1; }
  mkdir -p "$h/.claude/projects/$(printf '%s' "$h" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
  : > "$h/.claude/projects/$(printf '%s' "$h" | LC_ALL=C tr -c 'A-Za-z0-9' '-')/$sid.jsonl"   # it talked
  nt rename-window -t "$w" 'my planner'
  nt kill-window -t "$w"                          # the break
  : > "$oa"; t0=$(now)
  w2=$(oens)                                      # the next tick's home_watch
  [ -n "$w2" ] && [ "$w2" != "$w" ] || { WHY="it did not come back"; return 1; }
  until_ok "$CAP" grep -q -- "--resume $sid" "$oa" || { WHY="it came back on a new conversation: $(cat "$oa")"; return 1; }
  SECS=$(since "$t0")
  [ "$(nt list-windows -t or -F '#{@fleet_role}' | grep -cx orchestrator)" = 1 ] || { WHY="more than one orchestrator"; return 1; }
  WHAT="下一拍在 \$HOME 重开，续上同一对话（节拍 60s 另计）"
}

# orchestrator-two (issue #2117): two 承载 machines of one person each opened their
# own orchestrator (#1957's ensure ran per machine). Two machines, one fake hub
# (the holder file — fleet_orchestrator.go's answer): only the holder opens one;
# the hub names the other machine and the old one is closed on its next tick.
drill_orchestrator_two() {
  CAP=5; BREAK_SOCK="$WORK/sock-o5"; local t0 m hub="$WORK/ohub2"
  sed -n '/^home_watch()/,/^}/p' "$BIN/fleet-diskguard.sh" | grep -q 'fleet-orchestrator.sh" ensure "$s" 2>/dev/null)"; rc=' \
    || { WHY="home_watch no longer asks ensure on every tick — a machine the hub did not name never closes its own"; return 1; }
  mkdir -p "$hub"; printf 'm5' > "$hub/holder"
  cat > "$WORK/ocurl" <<'EOC'
#!/bin/sh
h=$(cat "$OHUB/holder"); here=false; [ "$h" = "$OME" ] && here=true
printf '{"machine":"%s","here":%s}\n200' "$h" "$here"
EOC
  chmod +x "$WORK/ocurl"
  printf '#!/bin/sh\nexec sleep 600\n' > "$WORK/o2-agent"; chmod +x "$WORK/o2-agent"
  for m in m4 m5; do
    mkdir -p "$WORK/o2$m/home"
    "$REAL_TMUX" -S "$WORK/sock-$m" -f /dev/null new-session -d -s or -n home -x 100 -y 30 'exec sh' || { WHY="cannot start the isolated tmux server"; return 1; }
  done
  o2() { env PATH="$WORK/tbin:$PATH" HOME="$WORK/o2$1/home" FLEET_CONF_DIR="$WORK/o2$1/conf" FLEET_SKIP_GLOBAL_CONF=1 \
           BREAK_SOCK="$WORK/sock-$1" OME="$1" OHUB="$hub" FLEET_HUB_CURL="$WORK/ocurl" CCQUOTA_FLEET=1 CCQUOTA_TOKEN=t \
           CCQUOTA_HUB_URL=http://hub.invalid FLEET_ORCHESTRATOR=1 FLEET_AGENT=claude FLEET_ORCH_MODEL='' \
           FLEET_WRAP_LAUNCH="$WORK/o2-agent" bash "$BIN/fleet-orchestrator.sh" ensure or 2>/dev/null; }
  oc() { "$REAL_TMUX" -S "$WORK/sock-$1" list-windows -t or -F '#{@fleet_role}' 2>/dev/null | grep -cx orchestrator; }
  o2 m4 >/dev/null; o2 m5 >/dev/null              # one tick on each machine
  [ "$(oc m4)+$(oc m5)" = 0+1 ] || { WHY="two machines ticked: m4+m5 = $(oc m4)+$(oc m5), want 0+1"; return 1; }
  printf 'm4' > "$hub/holder"; t0=$(now)          # the break: home moved to m4
  o2 m5 >/dev/null; o2 m4 >/dev/null              # the next tick
  SECS=$(since "$t0")
  [ "$(oc m4)+$(oc m5)" = 1+0 ] || { WHY="after the hub named m4: m4+m5 = $(oc m4)+$(oc m5), want 1+0"; return 1; }
  WHAT="入口只认一台：下一拍旧的那台收掉（标记 retired、对话 id 留着），新的那台开出（节拍 60s 另计）"
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

# epic_sandbox <dir> — a bare origin + a clone ONE commit behind stable, with
# stub apply / doctor / diskguard; the heartbeat and the state live under
# <dir>/conf. epic_tick runs one install-sync tick on it, epic_hb the heartbeat.
epic_sandbox() {
  local d="$1"
  mkdir -p "$d/conf" "$d/home"
  (
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/install" 2>/dev/null
    mkdir -p "$d/install/bin" "$d/install/logs"
    printf 'echo "apply: ok"\n' > "$d/install/bin/fleet-install-apply.sh"
    printf 'exit 0\n' > "$d/install/bin/fleet-doctor.sh"
    printf 'exit 0\n' > "$d/install/bin/fleet-diskguard.sh"; chmod +x "$d"/install/bin/*
    printf 'logs/\n' > "$d/install/.gitignore"
    git -C "$d/install" add -A && git -C "$d/install" commit -qm one && git -C "$d/install" push -q origin master
    echo two > "$d/install/f"; git -C "$d/install" add -A; git -C "$d/install" commit -qm two
    git -C "$d/install" push -q origin master; git -C "$d/install" reset -q --hard HEAD~1
    git --git-dir="$d/origin.git" update-ref refs/tags/stable master
  ) >/dev/null 2>&1
}
epic_tick() { HOME="$1/home" FLEET_CONF_DIR="$1/conf" FLEET_SKIP_GLOBAL_CONF=1 bash "$BIN/fleet-install-sync.sh" --root "$1/install"; }
epic_hb()   { local d="$1"; shift; HOME="$d/home" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 bash "$BIN/fleet-epic-heartbeat.sh" "$@"; }
epic_st()   { sed -n "s/^$2: //p" "$1/conf/global/install-sync.state" | head -1; }

# epic-mark-overwritten (issue #2062): two /fleet-epic-run loops on one login,
# each stamping its own batch. Before: one file, the second stamp replaced the
# first and the first loop's --clear took the second's protection with it. Now
# each batch has its own mark, --status shows both, --clear <N> takes one, and
# the other still holds the install (deferred).
drill_epic_mark_overwritten() {
  CAP=20; local t0 d="$WORK/epic1" st r
  epic_sandbox "$d" || { WHY="sandbox install did not build"; return 1; }
  epic_hb "$d" 1935 --tick 22 --repo o/r --session f1 >/dev/null 2>&1
  epic_hb "$d" 1982 --tick 10 --repo o/r --session f1 >/dev/null 2>&1
  t0=$(now)
  st=$(epic_hb "$d" --status 2>&1)
  case "$st" in *"epic=1935"*) ;; *) WHY="the second loop's heartbeat overwrote the first's: --status shows [$st]"; return 1 ;; esac
  case "$st" in *"epic=1982"*) ;; *) WHY="--status does not show the second batch: [$st]"; return 1 ;; esac
  epic_hb "$d" --clear 1935 >/dev/null 2>&1                   # the first batch ends
  st=$(epic_hb "$d" --status 2>&1)
  case "$st" in *"epic=1982"*) ;; *) WHY="--clear 1935 took #1982's mark too: [$st]"; return 1 ;; esac
  epic_tick "$d" >"$d/tick.out" 2>&1
  r=$(epic_st "$d" result)
  [ "$r" = deferred ] || { WHY="with #1982 still fresh the tick was $r: $(epic_st "$d" reason)"; return 1; }
  case "$(epic_st "$d" reason)" in *"epic=1982"*) ;; *) WHY="the deferral does not name #1982: $(epic_st "$d" reason)"; return 1 ;; esac
  SECS=$(since "$t0"); WHAT="两个批次各一份标记；#1935 收尾只清自己的，#1982 仍拦住 install-sync（deferred）"
}

# epic-fresh-switched (issue #2062): a batch is mid-run (its mark fresh) and
# stable moves. Before (#1894): the tick switched the version and only the
# node-agent step said deferred. Now the tick is deferred before the switch —
# no `switched` line, HEAD where it was — and follows once the batch clears.
drill_epic_fresh_switched() {
  CAP=20; local t0 d="$WORK/epic2" r head stable
  epic_sandbox "$d" || { WHY="sandbox install did not build"; return 1; }
  epic_hb "$d" 1935 --tick 22 --repo o/r --session f1 >/dev/null 2>&1
  t0=$(now)
  epic_tick "$d" >"$d/tick1.out" 2>&1
  r=$(epic_st "$d" result)
  head=$(git -C "$d/install" rev-parse HEAD); stable=$(git --git-dir="$d/origin.git" rev-parse stable)
  [ "$r" = deferred ] || { WHY="a fresh mark and the tick still ran: result=$r (install at $(printf '%.7s' "$head"), stable $(printf '%.7s' "$stable"))"; return 1; }
  grep -q ' switched ' "$d/install/logs/install-sync.log" 2>/dev/null && { WHY="the log has a switched line under a fresh mark"; return 1; }
  [ "$head" != "$stable" ] || { WHY="the install moved to stable under a fresh mark"; return 1; }
  epic_hb "$d" --clear 1935 >/dev/null 2>&1                   # the batch ends
  epic_tick "$d" >"$d/tick2.out" 2>&1
  [ "$(git -C "$d/install" rev-parse HEAD)" = "$stable" ] || { WHY="after the clear the tick did not switch: $(epic_st "$d" result) $(epic_st "$d" reason)"; return 1; }
  SECS=$(since "$t0"); WHAT="标记新鲜那一拍只 deferred、版本不动；批次清掉标记后下一拍 switched"
}

# epic-idle-held (issue #2247): a batch is idle — 0 member sessions, nothing in
# flight, the loop only waiting on the operator — and still stamps every tick.
# Before: any fresh mark held the switch, so an idle batch held the machine's
# upgrade for as long as it waited (EPIC #2140 held m4 for hours). Now a mark
# stamped --live 0 --inflight 0 does not hold: the tick switches under it.
drill_epic_idle_held() {
  CAP=20; local t0 d="$WORK/epic3" stable
  epic_sandbox "$d" || { WHY="sandbox install did not build"; return 1; }
  epic_hb "$d" 2140 --tick 18 --repo o/r --session f1 --live 0 --inflight 0 >/dev/null 2>&1
  stable=$(git --git-dir="$d/origin.git" rev-parse stable)
  t0=$(now)
  epic_tick "$d" >"$d/tick1.out" 2>&1
  [ "$(git -C "$d/install" rev-parse HEAD)" = "$stable" ] \
    || { WHY="an idle batch (live 0, nothing in flight) still held the switch: $(epic_st "$d" result) $(epic_st "$d" reason)"; return 1; }
  case "$(epic_st "$d" epic)" in *"idle (空转，不挡) epic=2140"*) ;;
    *) WHY="the state's epic: line does not say the batch was idle: [$(epic_st "$d" epic)]"; return 1 ;; esac
  SECS=$(since "$t0"); WHAT="空转批次（live 0、无在途）的新鲜标记不挡：那一拍照常 switched，state 的 epic: 行写 idle"
}

# epic-hold-uncapped (issue #2247): a batch with work that never finishes (or a
# loop stamping live 1 forever) held the install with no end. Now one mark holds
# the same stable at most FLEET_EPIC_HOLD_CAP_SECS: past it the tick switches and
# ONE record-only note goes on the EPIC.
drill_epic_hold_uncapped() {
  CAP=20; local t0 d="$WORK/epic4" stable
  epic_sandbox "$d" || { WHY="sandbox install did not build"; return 1; }
  epic_hb "$d" 2140 --tick 30 --repo o/r --session f1 --live 1 --inflight 1 >/dev/null 2>&1
  stable=$(git --git-dir="$d/origin.git" rev-parse stable)
  mkdir -p "$d/conf/global/epic-hold.d"
  printf 'since: %s\nstable: %s\nreleased: -\n' "$(( $(date +%s) - 7300 ))" "$stable" > "$d/conf/global/epic-hold.d/o-r-2140"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/notes.log"\n' "$d" > "$d/note.sh"
  t0=$(now)
  FLEET_EPIC_HOLD_NOTE_CMD="sh $d/note.sh" epic_tick "$d" >"$d/tick1.out" 2>&1
  [ "$(git -C "$d/install" rev-parse HEAD)" = "$stable" ] \
    || { WHY="a batch past the cap still held the switch: $(epic_st "$d" result) $(epic_st "$d" reason)"; return 1; }
  [ "$(grep -c '^2140 --repo o/r --note' "$d/notes.log" 2>/dev/null)" = 1 ] \
    || { WHY="the release was not noted once on the EPIC: [$(cat "$d/notes.log" 2>/dev/null)]"; return 1; }
  grep -q ' epic-released ' "$d/install/logs/install-sync.log" 2>/dev/null || { WHY="no epic-released log line"; return 1; }
  SECS=$(since "$t0"); WHAT="有活的批次挡同一 stable 满 2 小时：放行 switched，EPIC 上一条记录型说明，日志 epic-released"
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

# ---- a fleet tool call outliving the turn (issue #1880, EPIC #2074 C4) --------------
# Claude Code moves an MCP call past 120 s to a background task and the turn ends
# with the call in flight: the Stop wrote `done`, and every idle judge took the
# session (#1876, 2026-10-06: 2m44s). The fake server runs its one call as a child,
# as bin/fleet-mcp.py runs every tool; the Stop hook is the real one, on an
# isolated server. FLEET_TOOL_WAIT=0 is the red this drill was written against.
tw_env() {   # <args…> — the sandbox's hooks and lib, against sock-tw
  env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" BREAK_SOCK="$BREAK_SOCK" TMUX="$BREAK_SOCK,1,0" \
    FLEET_CONF_DIR="$WORK/tw/conf" FLEET_SKIP_GLOBAL_CONF=1 "$@"
}
drill_tool_wait_idle() {
  CAP=10; BREAK_SOCK="$WORK/sock-tw"; local d="$WORK/tw" w p t0 st why
  mkdir -p "$d/conf/global"
  cat > "$d/fleet-mcp.py" <<'PY'
import signal, subprocess, sys, time
child = subprocess.Popen(['sleep', '120'])                 # the call in flight
def bye(*_):
    if child.poll() is None: child.kill()
    sys.exit(0)
signal.signal(signal.SIGTERM, bye); signal.signal(signal.SIGHUP, bye)
with open(sys.argv[1], 'w') as fh: fh.write(str(child.pid))
child.wait()                                               # the call returned
time.sleep(120); bye()                                     # an idle server, no child
PY
  # The pane: Claude's empty input line (the call is running, nothing to type), the
  # fleet MCP server with its call, and an agent process (comm `claude`) under it.
  ln -sf "$(command -v sleep)" "$d/claude"
  nt -f /dev/null new-session -d -s tw -n issue-9 -x 100 -y 30 \
    "printf '\033[2J\033[H> '; python3 '$d/fleet-mcp.py' '$d/call.pid' & exec '$d/claude' 600" \
    || { WHY="cannot start the isolated tmux server"; return 1; }
  w=$(nt display-message -p -t tw:issue-9 '#{window_id}'); p=$(nt display-message -p -t "$w" '#{pane_id}')
  nt set-option -w -t "$w" @issue 9 \; set-option -w -t "$w" @cc_agent claude \; \
     set-option -w -t "$w" @claude_state working \; set-option -w -t "$w" @claude_state_ts "$(( $(date +%s) - 300 ))"
  until_ok 10 test -s "$d/call.pid" || { WHY="the fake server never started its call"; return 1; }
  # break ①: the sleep tick's state reconcile (#806) reads the call's empty input line
  # as an idle prompt — no hook has stamped `working` since the call began
  mkdir -p "$d/reg"
  tw_env python3 "$BIN/fleet-state-reconcile.py" --dry-run --registry "$d/reg" --cache-dir "$d/cache" \
    --log "$d/reconcile.log" --idle-secs 5 -- tw > "$d/reconcile.out" 2>&1
  grep -q "would demote.*:$w " "$d/reconcile.out" \
    && { WHY="the state reconcile would demote the window mid-call: $(grep ":$w " "$d/reconcile.out" | head -1)"; return 1; }
  grep -q ":$w .*kept working" "$d/reconcile.log" 2>/dev/null \
    || { WHY="the reconcile neither demoted nor kept $w: $(cat "$d/reconcile.out" "$d/reconcile.log" 2>/dev/null | tail -3 | tr '\n' ' ')"; return 1; }
  # break ②: the turn ends (the Stop hook runs) while the call is still running
  printf '' | tw_env TMUX_PANE="$p" sh "$BIN/set-claude-state.sh" 'done' >/dev/null 2>&1
  st="$(o "$w" @claude_state)/$(o "$w" @claude_wait)"
  [ "$st" = looping/tool ] \
    || { WHY="the Stop during a fleet tool call left @claude_state/@claude_wait=[$st], want looping/tool — reopen, reap, sleep and the backstop would all take the session mid-wait"; return 1; }
  # the one judge that reopens an idle session refuses it even when a writer that
  # never asked stamped it `done` long ago
  printf 'claude fp-new x\n' > "$d/conf/global/agent-cfg.expected"
  nt set-option -w -t "$w" @agent_cfg fp-old \; set-option -w -t "$w" @claude_state 'done' \; set-option -w -t "$w" @claude_state_ts 1
  why=$(tw_env bash -c '. "$1/fleet-lib.sh"; fleet_cfg_restart_why tw "$2"' _ "$BIN" "$w")
  [ "$why" = tool ] || { WHY="cfg-restart would reopen it: fleet_cfg_restart_why said [$why], want tool"; return 1; }
  # the call returns: the next re-ask (the sleep tick's fleet-wait-reeval.sh) reads done
  nt set-option -w -t "$w" @claude_state looping \; set-option -w -t "$w" @claude_wait tool
  kill "$(cat "$d/call.pid")"; t0=$(now)
  until_ok 10 sh -c '! kill -0 "$(cat "$1")" 2>/dev/null' _ "$d/call.pid"
  tw_env bash "$BIN/fleet-wait-reeval.sh" --window "$w" tw >/dev/null 2>&1
  st="$(o "$w" @claude_state)/$(o "$w" @claude_wait)"
  [ "$st" = done/ ] || { WHY="after the call returned the re-ask left [$st], want done/"; return 1; }
  SECS=$(since "$t0"); WHAT="等工具时状态核对不降级、Stop 记 looping·tool、cfg-restart 答 tool 不重开；调用返回后重判回 done"
}

# ---- a config reopen dropping a /loop and a ship (issue #2189) ---------------------
# 2026-10-07: a skill landed in ~/.claude/skills, every idle session was reopened
# onto the new configuration, and scratch-4's ScheduleWakeup (03:38) died with the
# old process — its @loop had never been stamped, so the judge read plain `done`;
# four workers with a green PR came back at a bare prompt and nobody merged. The
# judge is the real one on an isolated server, the transcript the session's own;
# the notice is the real migrate's.
drill_cfg_reopen_loop() {
  CAP=10; BREAK_SOCK="$WORK/sock-cl"; local d="$WORK/cl" w t0 why n sid=c1a00000-0000-4000-8000-000000002189
  mkdir -p "$d/conf/global" "$d/wt"
  printf 'claude fp-new x\n' > "$d/conf/global/agent-cfg.expected"
  loop_transcript "$d/wt" "$sid" 'check CI'
  nt -f /dev/null new-session -d -s cl -n issue-5 -x 100 -y 30 'exec sleep 600' \
    || { WHY="cannot start the isolated tmux server"; return 1; }
  w=$(nt display-message -p -t cl:issue-5 '#{window_id}')
  # the break: an idle worker on an old configuration, a Loop pending in its
  # transcript but no @loop (the hook never saw the ScheduleWakeup), a PR open
  nt set-option -w -t "$w" @agent_cfg fp-old \; set-option -w -t "$w" @claude_state 'done' \; \
     set-option -w -t "$w" @claude_state_ts 1 \; set-option -w -t "$w" @cc_session_id "$sid" \; \
     set-option -w -t "$w" @issue 5 \; set-option -w -t "$w" @pr_num '#55'
  t0=$(now)
  why=$(env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" BREAK_SOCK="$BREAK_SOCK" TMUX="$BREAK_SOCK,1,0" \
          FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 \
          bash -c '. "$1/fleet-lib.sh"; fleet_cfg_restart_why cl "$2"' _ "$BIN" "$w")
  [ "$why" = looping ] \
    || { WHY="cfg-restart would reopen it and drop the pending /loop: fleet_cfg_restart_why said [$why], want looping"; return 1; }
  case "$(o "$w" @loop)" in *kind=wakeup*) ;; *) WHY="the judge read the Loop but left no @loop: [$(o "$w" @loop)]"; return 1 ;; esac
  # the Loop over, the session is reopened: a worker with its PR still open is told
  # to carry the ship on, never "nothing to act on"
  n=$(bash -c 'set -u; . "$1/fleet-migrate.sh"; cfg_update_nudge "" "" cfg-stale "$2"' _ "$BIN" "$(o "$w" @pr_num)")
  case "$n" in *"Your PR #55 is still open"*"continue the /fleet-claim ship"*) ;;
    *) WHY="a worker mid-ship is reopened with [$n] — it would park at the prompt with its PR unmerged"; return 1 ;; esac
  SECS=$(since "$t0"); WHAT="没盖 @loop 的 /loop 会话：judge 读原对话答 looping、补上 @loop、不重开；有开着 PR 的 worker 重开提示是续 ship"
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
    # sidebar-ctrl-c: ⌃c / ⌃\ / ⌃z reaching the list — no key does since
    # issue #1950 (it takes none), so the bytes go to its pane directly, as a
    # client a running server still holds in its old key table would send them

    pump(0.8)   # the right-clicks above settled (the old prefix E's pause)
    lst, lpid = frame()[:2]
    t0 = time.time()
    for b in ("C-c", "C-\\", "C-z"):
        t("send-keys", "-t", lst, b); time.sleep(0.8)
    pump(1.0)
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

# The hub refuses this machine's certificate (issue #2112): a key id its roster
# no longer names (the 2026-10-04 move to gh:<id>), an expired certificate. The
# hub is UP — /healthz 200 — and answers 401; before, the bar said 入口连不上 and
# sent the person after the network. A fake hub answering 401 「names no one」,
# the REAL lease → where → badge chain.
# cert_hub <dir> <secs> — a fake hub: /v1/fleet/login/renew signs a fresh 12-hour
# certificate with <dir>/ca; /v1/fleet/client answers 401 「names no one」 while
# <dir>/orphan exists, else 404 (no lease door). Its port lands in <dir>/port.
cert_hub() {
  cat > "$1/hub.py" <<'PY'
import json, os, signal, subprocess, sys, tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer
D = sys.argv[1]; signal.alarm(int(sys.argv[2]))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        open(os.path.join(D, "log"), "a").write(self.path + "\n")
        if self.path == "/v1/fleet/login/renew":
            t = tempfile.mkdtemp(dir=D)
            open(os.path.join(t, "k.pub"), "w").write(body["public_key"] + "\n")
            subprocess.run(["ssh-keygen", "-q", "-s", os.path.join(D, "ca"), "-I", "person:gh:1", "-n", "verk",
                            "-V", "-1m:+12h", os.path.join(t, "k.pub")], check=True)
            return self.reply(200, {"certificate": open(os.path.join(t, "k-cert.pub")).read(), "principals": ["verk"],
                                    "valid_before": "", "ssh_config": "# test\n"})
        if self.path.startswith("/v1/fleet/client") and os.path.exists(os.path.join(D, "orphan")):
            return self.reply(401, {"error": "connection certificate refused: its key id names no one this hub knows"})
        self.reply(404, {})
    do_GET = lambda self: self.reply(404, {})
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(D, "port.tmp"), "w").write(str(srv.server_address[1])); os.replace(os.path.join(D, "port.tmp"), os.path.join(D, "port"))
srv.serve_forever()
PY
  [ -f "$1/ca" ] || ssh-keygen -q -t ed25519 -N '' -f "$1/ca"
  rm -f "$1/port"
  python3 "$1/hub.py" "$1" "$2" 2>"$1/hub.err" & CHUB_PID=$!
  for _ in $(seq 1 300); do [ -s "$1/port" ] && break; sleep 0.1; done
  [ -s "$1/port" ]
}
drill_hub_refused_cert() {
  CAP=15; local t0 sc="$WORK/hrc" port badge wj
  mkdir -p "$sc"; : > "$sc/orphan"
  cert_hub "$sc" 60 || { kill "$CHUB_PID" 2>/dev/null; WHY="the fake hub did not start: $(tail -2 "$sc/hub.err")"; return 1; }
  read -r port < "$sc/port"
  t0=$(now)
  wj=$( client_env; export FLEET_HUB_URL="http://127.0.0.1:$port" FLEET_HUB_TOKEN=tok FLEET_SHELL_SESSION="${CSESS}r"
        unset CCQUOTA_TOKEN CCQUOTA_HUB_URL; bash "$BIN/fleet-client-where.sh" --json 2>&1 )
  badge=$( client_env; export FLEET_HUB_URL="http://127.0.0.1:$port" FLEET_HUB_TOKEN=tok FLEET_SHELL_SESSION="${CSESS}r"
           unset CCQUOTA_TOKEN CCQUOTA_HUB_URL
           FLEET_CLIENT_BADGE_TTL=0 FLEET_CLIENT_BADGE_CACHE="$sc/badge" bash "$BIN/fleet-client-badge.sh" cw=120 )
  SECS=$(since "$t0")
  kill "$CHUB_PID" 2>/dev/null; wait "$CHUB_PID" 2>/dev/null
  case "$wj" in *'"hub": "refused"'*) ;; *) WHY="where --json does not say refused: [$wj]"; return 1 ;; esac
  case "$badge" in *入口连不上*) WHY="the bar still says 入口连不上 for a 401: [$badge]"; return 1 ;; esac
  case "$badge" in *'range=user|rescan'*请重新扫码*) ;; *) WHY="the bar does not offer the rescan: [$badge]"; return 1 ;; esac
  WHAT="入口回 401「names no one」：where 报 hub refused，状态栏橙色「入口不认这台电脑 · 请重新扫码」，可点"
}

# A shell left open past its certificate (issue #2112): 12 hours, and only a new
# connection (`fleet-connect.py --enter`) renewed it — a client left overnight
# went 401 at that minute. The real client (bin/fleet → keeper) with a
# certificate 30 minutes from its end and a fake hub that renews: the keeper
# renews it (fleet-login.py renew --if-under 3600); then the hub stops naming the
# key id, and the keeper's renew exit 3 is the one thing the person is told.
drill_cert_expiry_keeper() {
  CAP=20; local t0 s="${CSESS}k" sc="$WORK/cek" port left
  client_setup
  mkdir -p "$sc"; rm -f "$sc/orphan"
  cert_hub "$sc" $((CAP * 2 + 60)) || { kill "$CHUB_PID" 2>/dev/null; WHY="the fake hub did not start: $(tail -2 "$sc/hub.err")"; return 1; }
  read -r port < "$sc/port"
  ( client_env; rm -f "$HOME/.ssh/fleet-cert" "$HOME/.ssh/fleet-cert.pub" "$HOME/.ssh/fleet-cert-cert.pub"
    ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/fleet-cert"
    ssh-keygen -q -s "$sc/ca" -I person:gh:1 -n verk -V -1m:+30m "$HOME/.ssh/fleet-cert.pub" )
  left=$( client_env; python3 "$BIN/fleet-login.py" check )
  case "$left" in "valid "*) ;; *) kill "$CHUB_PID" 2>/dev/null; WHY="the 30-minute certificate did not take: [$left]"; return 1 ;; esac
  t0=$(now)
  if ! client_start "$s" FLEET_HUB_URL="http://127.0.0.1:$port" FLEET_CLIENT_IDENTITY=test \
       FLEET_CLIENT_LEASE_EVERY=1 FLEET_CLIENT_INPUT_EVERY=1 FLEET_CERT_CHECK_EVERY=1 FLEET_SHELL_CACHE="$sc/cache"; then
    kill "$CHUB_PID" 2>/dev/null; WHY="the client did not start: $(head -3 "$WORK/up-$s.err")"; return 1
  fi
  for _ in $(seq 1 $((CAP * 10))); do
    left=$( client_env; python3 "$BIN/fleet-login.py" check ); left=${left#valid }
    case "$left" in ''|*[!0-9.]*) ;; *) [ "${left%.*}" -gt 39600 ] && break ;; esac
    sleep 0.1
  done
  SECS=$(since "$t0")
  case "$left" in ''|*[!0-9.]*) left=0 ;; esac
  if [ "${left%.*}" -le 39600 ]; then
    "$REAL_TMUX" -L "$s" kill-server 2>/dev/null; kill "$CHUB_PID" 2>/dev/null
    WHY="the keeper did not renew a certificate 30 minutes from its end (left ${left}s; hub saw: $(tr '\n' ' ' < "$sc/log" 2>/dev/null))"; return 1
  fi
  # the hub stops naming the key id: renewing will never help — the person is told
  : > "$sc/orphan"
  ( client_env; ssh-keygen -q -s "$sc/ca" -I person:YiLiangHui -n verk -V -1m:+30m "$HOME/.ssh/fleet-cert.pub" )
  for _ in $(seq 1 $((CAP * 10))); do [ -f "$sc/cache/tmp/client.rescan" ] && break; sleep 0.1; done
  "$REAL_TMUX" -L "$s" kill-server 2>/dev/null
  kill "$CHUB_PID" 2>/dev/null; wait "$CHUB_PID" 2>/dev/null
  [ -f "$sc/cache/tmp/client.rescan" ] || { WHY="an orphaned key id: the keeper's renew exit 3 left no rescan mark"; return 1; }
  WHAT="证书剩 30 分钟：keeper 自己续成 12 小时；入口不认 key id 时只提示一次「请重新扫码」"
}

# The list does not move while a line is down (issue #1882): the real client on
# its own -L socket, a fake hub serving sessions in two repos on two machines.
# Before, a lost machine's rows moved into a `─ m4 失联 ─` group at the foot and
# came back when it answered again — the list reshuffled twice. The sidebar pane
# is captured before / during / after: during, the same lines in the same order,
# only the lost rows' state glyph `⊘` (issue #2305; the colour is the view's, never in a capture).
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
# a row's state glyph is masked (`?`): a lost machine's row says so in it — `⊘`
# (issue #2305) — and that is the one thing allowed to change in place
off_norm() { LC_ALL=C sed -e 's/^\([^ ]* \) *[^ ][^ ]* /\1? /' -e 's/!//g' -e 's/  */ /g'; }
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
  off_wait "$s" 20 '⊘ +app-m4' || { WHY="m4 lost never showed on its rows: $(off_rows "$s" | tr '\n' '|')"; return 1; }
  sleep 1; during=$(off_rows "$s")
  printf '%s\n' "$during" | grep -qE '⊘ +(app-root|tool-m5)' && { WHY="m4 lost dimmed m5's rows too (the hub went stale?): $(printf '%s' "$during" | tr '\n' '|')"; return 1; }
  case "$during" in *失联*) WHY="a 失联 heading came back: $(printf '%s' "$during" | tr '\n' '|')"; return 1 ;; esac
  [ "$(printf '%s\n' "$during" | off_norm)" = "$(printf '%s\n' "$before" | off_norm)" ] \
    || { WHY="m4 lost moved the list: before [$(printf '%s' "$before" | tr '\n' '|')] during [$(printf '%s' "$during" | tr '\n' '|')]"; return 1; }
  # 2. the hub unreachable: every row lost, still the same lines
  cp "$WORK/off/on.json" "$WORK/off/cur.json"
  off_wait "$s" 20 '⊘ +app-m4' v || { WHY="m4 never came back after its loss"; return 1; }
  : > "$WORK/off/down"
  off_wait "$s" 40 '⊘ +(app-root|tool-m5)' || { WHY="入口连不上 never dimmed the m5 rows: $(off_rows "$s" | tr '\n' '|')"; return 1; }
  sleep 1; during=$(off_rows "$s")
  [ "$(printf '%s\n' "$during" | off_norm)" = "$(printf '%s\n' "$before" | off_norm)" ] \
    || { WHY="入口连不上 moved the list: before [$(printf '%s' "$before" | tr '\n' '|')] during [$(printf '%s' "$during" | tr '\n' '|')]"; return 1; }
  # 3. back: the very lines of before, no `!` left
  t0=$(now); rm -f "$WORK/off/down"
  off_wait "$s" "$CAP" '⊘' v || { WHY="the rows stayed lost after the hub answered: $(off_rows "$s" | tr '\n' '|')"; return 1; }
  [ "$(off_rows "$s")" = "$before" ] || { WHY="back online, the list differs from before: [$(off_rows "$s" | tr '\n' '|')]"; return 1; }
  SECS=$(since "$t0"); : > "$WORK/off/stop"
  "$REAL_TMUX" -L "$s" kill-server 2>/dev/null; "$REAL_TMUX" -L "$s-stage" kill-server 2>/dev/null
  WHAT="m4 失联 / 入口连不上：行数、顺序、分组不变，只是状态图标变 ⊘；恢复后与断开前逐行一致"
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
  # update.state is written after the reload returns: a beat after the proxy
  until_ok 5 grep -q '"phase": "done"' "$WORK/ucache/update.state" || { WHY="no trace of the update: update.state is not done"; return 1; }
  WHAT="新文件载入正在跑的客户端，旧代理换掉，留下「已更新到」"
}

# (issue #2145) The same drift on a home with NO .client-version — a client the
# line put down before the mark existed, or one that lost it: every check above
# reads the mark, so the running server kept the conf it loaded, silently (the
# operator's MacBook ran a pre-#1951 tmux.conf: no key hints on the bar, the
# files on disk new). The break: the client starts on a conf without the hints,
# then the conf on disk is the new one. Self-heal: the keeper's tick sees the
# running @client_digest differ from the files' and reloads once idle.
drill_client_unversioned_drift() {
  CAP=15; local s="${CSESS}n" H="$WORK/nhome" t0 f
  client_setup
  mkdir -p "$H/bin" "$H/conf"
  cp -P "$WORK"/sbin/* "$H/bin/"
  for f in fleet-shell.sh fleet-client-update.sh; do rm -f "$H/bin/$f"; cp "$BIN/$f" "$H/bin/$f"; done
  for f in "$WORK"/conf/*; do cp -L "$f" "$H/conf/${f##*/}"; done
  grep -v fleet_hint "$ROOT/conf/tmux-shell.conf" > "$H/conf/tmux-shell.conf"   # the old conf: no key hints
  rm -f "$H/.client-version"
  ( client_env
    export FLEET_SHELL_SESSION="$s" FLEET_SHELL_CACHE="$WORK/ncache" FLEET_CLIENT_LEASE_CMD=false \
           FLEET_CLIENT_LEASE_EVERY=1 FLEET_CLIENT_IDLE_SECS=0 FLEET_CLIENT_CHECK_SECS=999999
    bash "$H/bin/fleet-shell.sh" >"$WORK/up-$s.out" 2>"$WORK/up-$s.err" )
  [ "$(cat "$WORK/up-$s.out" 2>/dev/null)" = "$s" ] || { WHY="the unversioned client did not start: $(head -3 "$WORK/up-$s.err")"; return 1; }
  [ -z "$("$REAL_TMUX" -L "$s" show-options -gqv @fleet_hint 2>/dev/null)" ] || { WHY="the old conf already carries @fleet_hint"; return 1; }
  t0=$(now)
  cp "$ROOT/conf/tmux-shell.conf" "$H/conf/tmux-shell.conf"   # the break: new files under the running client
  until_ok "$CAP" sh -c "[ -n \"\$(\"$REAL_TMUX\" -L $s show-options -gqv @fleet_hint 2>/dev/null)\" ]" \
    || { WHY="the running client still runs the conf it loaded (no @fleet_hint) ${CAP}s after the files changed"; return 1; }
  SECS=$(since "$t0")
  until_ok 5 grep -q '"phase": "reloaded"' "$WORK/ncache/update.state" || { WHY="no trace of the reload: update.state is not reloaded"; return 1; }
  WHAT="没有 .client-version 的客户端：按内容认出新文件，空闲时重新载入，留下「已重新载入新文件」"
}

# (issue #2345) The client updated, the list kept drawing the old code: sync
# reused a list pane whose @sidebar_version matched VIEW_VERSION — a constant
# bumped by hand — so a version whose fleet-sidebar.py changed without the bump
# left the old process running (the operator's MacBook, 5 hours of 「合并后回收」
# after #2305 landed). The drill: an installed client with its keeper on a 1 s
# beat and a client attached, so the list is drawn; the break is new files in
# its home — fleet-sidebar.py changed, VIEW_VERSION as it was, a new
# .client-version; the recovery is the keeper's reload drawing the list again
# from the new code (a new list process).
drill_client_sidebar_stale_after_update() {
  CAP=20; local s="${CSESS}s" H="$WORK/shome" t0 lp f rc=0
  client_setup
  mkdir -p "$H/bin"
  cp -P "$WORK"/sbin/* "$H/bin/"
  for f in fleet-shell.sh fleet-client-update.sh fleet-sidebar.py; do rm -f "$H/bin/$f"; cp "$BIN/$f" "$H/bin/$f"; done
  ln -s "$WORK/conf" "$H/conf"
  printf 'version=v1\ncompat=1\ncommit=c0ffee1\nhub=https://hub.example\n' > "$H/.client-version"
  ( client_env
    export FLEET_SHELL_SESSION="$s" FLEET_SHELL_CACHE="$WORK/scache" FLEET_CLIENT_LEASE_CMD=false \
           FLEET_CLIENT_LEASE_EVERY=1 FLEET_CLIENT_IDLE_SECS=0 FLEET_CLIENT_CHECK_SECS=999999
    mkdir -p "$XDG_CACHE_HOME/claude-fleet/client"; date +%s > "$XDG_CACHE_HOME/claude-fleet/client/checked"
    bash "$H/bin/fleet-shell.sh" >"$WORK/up-$s.out" 2>"$WORK/up-$s.err" )
  [ "$(cat "$WORK/up-$s.out" 2>/dev/null)" = "$s" ] || { WHY="the installed client did not start: $(head -3 "$WORK/up-$s.err")"; return 1; }
  # a client attached for the whole drill (control mode, fed by a fifo): the list
  # is drawn only for an attached session, and a reload's sync takes it away otherwise
  mkfifo "$WORK/sclient.fifo"
  "$REAL_TMUX" -L "$s" -C attach-session -t "=$s" < "$WORK/sclient.fifo" >/dev/null 2>&1 &
  local cpid=$!
  exec 8> "$WORK/sclient.fifo"
  slist() { "$REAL_TMUX" -L "$s" list-panes -s -t "=$s" -F '#{@sidebar} #{pane_pid}' 2>/dev/null | awk '$1 == "1" { print $2; exit }'; }
  until_ok 5 sh -c "[ -n \"\$(\"$REAL_TMUX\" -L $s list-clients -F x 2>/dev/null)\" ]" || { WHY="no client attached"; rc=1; }
  if [ "$rc" = 0 ]; then
    "$REAL_TMUX" -L "$s" resize-window -t "=$s:" -x 200 -y 50 2>/dev/null
    "$REAL_TMUX" -L "$s" run-shell -t "=$s:" "bash '$WORK/scache/bin/fleet-sidebar.sh' sync '#{session_id}' >/dev/null 2>&1 || :"
    until_ok 10 sh -c "[ -n \"\$(\"$REAL_TMUX\" -L $s list-panes -s -t =$s -F '#{@sidebar}' 2>/dev/null | grep -x 1)\" ]" \
      || { WHY="no list drawn on the installed client"; rc=1; }
  fi
  if [ "$rc" = 0 ]; then
    lp=$(slist)
    t0=$(now)
    printf '\n# v2: the list moved, VIEW_VERSION as it was\n' >> "$H/bin/fleet-sidebar.py"   # the break
    printf 'version=v2\ncompat=1\ncommit=beef002\nhub=https://hub.example\n' > "$H/.client-version"
    until_ok "$CAP" sh -c "[ \"\$(\"$REAL_TMUX\" -L $s show-options -gqv @client_version 2>/dev/null)\" = v2 ]" \
      || { WHY="the client never reloaded the new files (@client_version=$("$REAL_TMUX" -L "$s" show-options -gqv @client_version 2>/dev/null))"; rc=1; }
  fi
  if [ "$rc" = 0 ]; then
    until_ok 5 sh -c "p=\$(\"$REAL_TMUX\" -L $s list-panes -s -t =$s -F '#{@sidebar} #{pane_pid}' 2>/dev/null | awk '\$1 == \"1\" { print \$2; exit }'); [ -n \"\$p\" ] && [ \"\$p\" != $lp ]" \
      || { WHY="the list process ($lp) still draws the old code after the reload: $(slist)"; rc=1; }
    SECS=$(since "$t0")
  fi
  exec 8>&-; kill "$cpid" 2>/dev/null
  [ "$rc" = 0 ] || return 1
  WHAT="客户端换了新文件：侧栏按内容认出不是自己启动时的代码，重画成新进程"
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
  # not a recovery race: the bound only catches a hang (a macOS runner starts a
  # python in ~1s, and this drill starts ~15)
  CAP=120; local t0 hub out rc h
  t0=$(now)
  hub="$WORK/fakehub-$$"; mkdir -p "$hub/conf"
  # one process: the hub in a thread, the client as its child — nothing left
  # running in the background, and the alarm bounds it all
  cat > "$hub/drive.py" <<'PY2'
import json, os, signal, subprocess, sys, threading, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
signal.alarm(int(sys.argv[3]))
LEASE, HOME, CONF = sys.argv[1], sys.argv[2], sys.argv[4]
cur, log = {}, []
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        worker = (self.headers.get("X-Fleet-Worker") or "").strip()
        test = self.path == "/v1/fleet/client/test" or body.get("identity") == "test"
        log.append("%s %s worker=%s identity=%s" % (self.path, body.get("action"), "yes" if worker else "no", body.get("identity", "")))
        if self.path not in ("/v1/fleet/client", "/v1/fleet/client/test"):
            self.send_response(404); self.end_headers(); return
        if worker and not test:
            out, code = {"error": "a session may not take the person's client lease — run as the test identity"}, 403
        else:
            slot = "test" if test else "person"
            if body.get("action") == "acquire":
                cur[slot] = {"id": uuid.uuid4().hex[:12], "device": body.get("device", "")}
            out, code = {"state": "active" if cur.get(slot) else "none", "lease": cur.get(slot)}, 200
            if test: out["identity"] = "test"
        b = json.dumps(out).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
srv = HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
def lease(extra, *args):
    env = {k: v for k, v in os.environ.items() if k not in
           ("FLEET_WORKER_CRED", "FLEET_WORKER_ASSERT", "FLEET_SEAT", "FLEET_CLIENT_IDENTITY", "SSH_CONNECTION")}
    env.update(HOME=HOME, FLEET_CONF_DIR=CONF, FLEET_HUB_URL="http://127.0.0.1:%d" % srv.server_address[1],
               FLEET_HUB_TOKEN="tok", FLEET_CLIENT_XTVERSION="0", **extra)
    r = subprocess.run([sys.executable, LEASE] + list(args), env=env, capture_output=True, text=True, timeout=20)
    return r.returncode, (r.stdout + r.stderr).strip()
def die(why):
    print("WHY=" + why + " | hub saw: " + " ; ".join(log)); sys.exit(1)
rc, out = lease({"FLEET_CLIENT_DEVICE": "MacBook"}, "acquire")
before = json.dumps(cur.get("person"))
if rc or log[-1:] != ["/v1/fleet/client acquire worker=no identity="]:
    die("the person's acquire (rc %d): %s" % (rc, out))
rc, out = lease({"FLEET_WORKER_CRED": "fwc1.x", "FLEET_CLIENT_DEVICE": "m4-drill"}, "acquire")
if rc or json.dumps(cur.get("person")) != before:
    die("a session's acquire took the person's lease (rc %d): %s → %s [%s]" % (rc, before, json.dumps(cur.get("person")), out))
if log[-1] != "/v1/fleet/client/test acquire worker=yes identity=test":
    die("a session's acquire did not ask as the marked test identity")
rc, out = lease({"FLEET_WORKER_CRED": "fwc1.x", "FLEET_CLIENT_IDENTITY": "person"}, "acquire")
if rc != 1 or "403" not in out or "test identity" not in out:
    die("FLEET_CLIENT_IDENTITY=person in a session: rc %d, no 403 + why: [%s]" % (rc, out))
if json.dumps(cur.get("person")) != before:
    die("a refused acquire still moved the person's lease")
print("OK")
PY2
  out=$(python3 "$hub/drive.py" "$BIN/fleet-client-lease.py" "$WORK/home" "$((CAP + 10))" "$hub/conf" 2>&1)
  [ "$out" = OK ] || { WHY=${out#WHY=}; WHY="${WHY:-the drive died}"; return 1; }
  # the guard: a session's client start must say --test-identity
  h=( env -u FLEET_HUB FLEET_WORKER_CRED=fwc1.x FLEET_HEAVY=0 FLEET_LIB=/nonexistent python3 "$ROOT/hooks/bash-guard.py" )
  for cmd in 'fleet' 'fleet m4' 'FLEET_HUB_URL=https://hub.example fleet' "$BIN/fleet-shell.sh" 'ssh m4 fleet' 'ssh -p 22022 m4 "fleet shell"' \
             'fleet codex hi' 'fleet claude --node m4' "$BIN/fleet-home-session.sh claude"; do
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(printf '%s' "$cmd" | sed 's/["\\]/\\&/g')" | "${h[@]}" 2>&1)
    [ $? = 2 ] || { WHY="bash-guard let a session's [$cmd] through"; return 1; }
    case "$out" in *--test-identity*FLEET_ALLOW_PERSON_CLIENT=1*) ;; *) WHY="bash-guard gave no way out for [$cmd]: [$out]"; return 1 ;; esac
  done
  for cmd in 'fleet --test-identity m4' 'FLEET_CLIENT_IDENTITY=test fleet' 'fleet doctor' 'ssh m4 fleet --test-identity' 'FLEET_ALLOW_PERSON_CLIENT=1 fleet' \
             'fleet claude --here' 'fleet --test-identity codex hi'; do
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(printf '%s' "$cmd" | sed 's/["\\]/\\&/g')" | "${h[@]}" 2>&1)
    [ $? = 0 ] || { WHY="bash-guard refused [$cmd]: [$out]"; return 1; }
  done
  out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"fleet m4"}}' \
        | env -u FLEET_WORKER_CRED -u FLEET_HUB FLEET_HEAVY=0 FLEET_LIB=/nonexistent python3 "$ROOT/hooks/bash-guard.py" 2>&1)
  [ $? = 0 ] || { WHY="bash-guard refused a person's own fleet: [$out]"; return 1; }
  SECS=$(since "$t0"); WHAT="执行会话的客户端只拿测试身份：运营者租约不变，要运营者租约被拒（403 + 原因），守卫拦没写 --test-identity 的启动"
}

# The drill's scan confirmed as the operator (issue #2010, EPIC #1906 C16): on
# 2026-10-06 (#1901) the QR's confirm page opened in the operator's browser and
# confirmed the drill's login AS HIM — the run walked "his second computer",
# never a new colleague's first time. Now the drill confirms with the approve
# code `fleet drill invite` minted (bin/fleet-drill.sh approve): a fake hub
# keeping the real one's rule (a request carrying a session / token / cert is
# the signed-in admin; POST /fleet/login/approve with the code is the drill
# person — TestDrillApproveIsTheDrillPerson pins the hub's own), the operator's
# token AND a certificate sitting right there: the confirmer must be the drill
# person, and a used code must not confirm a second time.
drill_drill_confirms_as_operator() {
  CAP=60; local t0 hub out
  t0=$(now)
  hub="$WORK/drillhub-$$"; mkdir -p "$hub/home/.ssh"
  printf 'k\n' > "$hub/home/.ssh/fleet-cert"; printf 'ssh-ed25519-cert-v01@openssh.com AAAA admin\n' > "$hub/home/.ssh/fleet-cert-cert.pub"
  cat > "$hub/drive.py" <<'PY2'
import json, os, signal, subprocess, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
signal.alarm(int(sys.argv[2]))
DRILL, HOME = sys.argv[1], sys.argv[3]
CODE = "fd_abcdefghijklmnopqrstuvwxyz"
used, confirmed, log = [False], {}, []
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        admin = bool(self.headers.get("Authorization") or self.headers.get("Cookie") or body.get("cert"))
        log.append("%s admin=%s code=%s" % (self.path, admin, "yes" if body.get("approve_code") else "no"))
        out, st = {"error": "no such door"}, 404
        if self.path in ("/fleet/login", "/fleet/login/approve"):
            if body.get("approve_code"):
                if body["approve_code"] != CODE or used[0]:
                    out, st = {"error": "approve code unknown, already used or expired"}, 403
                else:
                    used[0] = True
                    confirmed[body.get("code")] = "drill-person"
                    out, st = {"status": "approved", "person_id": "drill-1", "kind": "drill"}, 200
            elif admin:
                confirmed[body.get("code")] = "admin"
                out, st = {"status": "approved", "person_id": "admin"}, 200
            else:
                out, st = {"error": "nothing to confirm"}, 400
        b = json.dumps(out).encode()
        self.send_response(st); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
srv = HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
def approve(ucode):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("FLEET_", "CCQUOTA_"))}
    env.update(HOME=HOME, FLEET_HUB_URL="http://127.0.0.1:%d" % srv.server_address[1],
               CCQUOTA_VIEWER_TOKEN="admin-token", FLEET_DRILL_INVITE=CODE)
    r = subprocess.run(["bash", DRILL, "approve", ucode], env=env, capture_output=True, text=True, timeout=20)
    return r.returncode, (r.stdout + r.stderr).strip()
def die(why):
    print("WHY=" + why + " | hub saw: " + " ; ".join(log)); sys.exit(1)
rc, out = approve("ABCD-EFGH")
if rc or confirmed.get("ABCD-EFGH") != "drill-person":
    die("the drill's login was confirmed as %s (rc %d): %s" % (confirmed.get("ABCD-EFGH"), rc, out))
if any("admin=True" in l for l in log):
    die("the approve carried the operator's token / cookie / certificate")
rc, out = approve("WXYZ-WXYZ")
if rc != 1 or "WXYZ-WXYZ" in confirmed:
    die("a used approve code confirmed a second login (rc %d): %s" % (rc, out))
print("OK")
PY2
  out=$(python3 "$hub/drive.py" "$BIN/fleet-drill.sh" "$((CAP + 10))" "$hub/home" 2>&1)
  [ "$out" = OK ] || { WHY=${out#WHY=}; WHY="${WHY:-the drive died}"; return 1; }
  SECS=$(since "$t0"); WHAT="演练的扫码以演练同事确认：入口上确认人是 drill person，不带运营者的 token / 证书，确认码只能用一次"
}

# A login's wait with no answer (issue #2262, EPIC #2259 约定 5/8): the browser
# will not open, or opens and nobody confirms (a company network blocking
# GitHub). Before, the terminal drew a QR and waited out the code's ten minutes
# without a word. A fake hub that never confirms, a fake opener that fails, then
# one that works: it says the browser would not open and draws the QR; it says
# every few seconds what it waits for; it stops with the reason and what to do.
login_pending_hub() {
  cat > "$1/hub.py" <<'PY2'
import json, os, signal, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
signal.alarm(int(sys.argv[2]))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/v1/fleet/login/start":
            st, out = 200, {"device_code": "d" * 64, "user_code": "BCDF-GHJK", "expires_in": 600, "interval": 1,
                            "verification_uri": "http://127.0.0.1/fleet/login?code=BCDF-GHJK",
                            "key_fingerprint": "SHA256:x", "qr": ["#.#", ".#.", "#.#"]}
        elif self.path == "/v1/fleet/login/poll":
            st, out = 202, {"status": "authorization_pending"}
        else:
            st, out = 404, {}
        b = json.dumps(out).encode()
        self.send_response(st); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(sys.argv[1], "port"), "w").write(str(srv.server_port))
srv.serve_forever()
PY2
  rm -f "$1/port"
  python3 "$1/hub.py" "$1" "$2" 2>"$1/hub.err" & LHUB_PID=$!
  for _ in $(seq 1 300); do [ -s "$1/port" ] && break; sleep 0.1; done
  [ -s "$1/port" ]
}
login_sandbox_run() {   # <dir> <env…> — fleet-login.py in a sandbox HOME (killed at 20 s), its output printed
  local d="$1"; shift
  env -i PATH="$d/fakebin:$PATH" HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" "$@" \
    python3 -c 'import subprocess, sys
try: sys.exit(subprocess.run(sys.argv[1:], stdin=subprocess.DEVNULL, stderr=subprocess.STDOUT, timeout=20).returncode)
except subprocess.TimeoutExpired: print("(still waiting after 20 s — killed)"); sys.exit(124)' \
    python3 "$BIN/fleet-login.py" --hub "http://127.0.0.1:$(cat "$d/port")" 2>&1
}
drill_login_browser_silent() {
  CAP=10; local t0 d="$WORK/lbs" out
  mkdir -p "$d/home/.ssh" "$d/fakebin"
  for o in open xdg-open; do printf '#!/bin/sh\nexit "$(cat %s/open.rc)"\n' "$d" > "$d/fakebin/$o"; chmod +x "$d/fakebin/$o"; done
  login_pending_hub "$d" $((CAP * 3)) || { kill "$LHUB_PID" 2>/dev/null; WHY="the fake hub did not start: $(tail -2 "$d/hub.err")"; return 1; }
  echo 1 > "$d/open.rc"
  out=$(login_sandbox_run "$d" FLEET_LOGIN_BROWSER=1 FLEET_LOGIN_NUDGE_SECS=1 FLEET_LOGIN_TIMEOUT_SECS=2)
  case "$out" in *浏览器打不开*'█'*) ;; *) kill "$LHUB_PID" 2>/dev/null; WHY="an opener that fails: no 「浏览器打不开」 + QR: [$out]"; return 1 ;; esac
  echo 0 > "$d/open.rc"
  t0=$(now)
  out=$(login_sandbox_run "$d" FLEET_LOGIN_BROWSER=1 FLEET_LOGIN_NUDGE_SECS=1 FLEET_LOGIN_TIMEOUT_SECS=3)
  SECS=$(since "$t0")
  kill "$LHUB_PID" 2>/dev/null; wait "$LHUB_PID" 2>/dev/null
  case "$out" in *还在等浏览器里授权*按\ q\ 改用二维码*) ;; *) WHY="no 「还在等浏览器里授权…（按 q 改用二维码）」 while waiting: [$out]"; return 1 ;; esac
  case "$out" in *秒内浏览器里没有完成授权，已停下*'fleet login --qr'*) ;; *) WHY="the wait did not stop with the reason + next step: [$out]"; return 1 ;; esac
  [ -e "$d/home/.ssh/fleet-cert-cert.pub" ] && { WHY="a certificate appeared with nothing confirmed"; return 1; }
  WHAT="浏览器打不开就说并画码；等着时每拍一句「还在等浏览器里授权…（按 q 改用二维码）」，到点停下给原因和下一步"
}

# A sandbox login that writes the REAL config (issue #2262): 2026-10-07 a
# worker took its 上线证据 with HOME pointed at a temp dir but its session's
# FLEET_CONF_DIR still set — `fleet login` remembered the fake hub in the
# machine's real fleet.conf and m5 lost its hub. The real home is a seam here
# ($d/real); the guard must keep both writes (the address, node.env's dir for
# `fleet node ensure`) in the sandbox.
drill_login_sandbox_real_conf() {
  CAP=10; local t0 d="$WORK/lsr" out
  mkdir -p "$d/home/.ssh" "$d/real/.config/claude-fleet" "$d/fakebin"
  printf 'export FLEET_HUB_URL="https://hub.real"\n' > "$d/real/.config/claude-fleet/fleet.conf"
  login_pending_hub "$d" $((CAP * 3)) || { kill "$LHUB_PID" 2>/dev/null; WHY="the fake hub did not start: $(tail -2 "$d/hub.err")"; return 1; }
  t0=$(now)
  out=$(login_sandbox_run "$d" FLEET_LOGIN_BROWSER=0 FLEET_LOGIN_TIMEOUT_SECS=1 \
        FLEET_LOGIN_REAL_HOME="$d/real" FLEET_CONF_DIR="$d/real/.config/claude-fleet")
  SECS=$(since "$t0")
  kill "$LHUB_PID" 2>/dev/null; wait "$LHUB_PID" 2>/dev/null
  grep -q 'hub.real' "$d/real/.config/claude-fleet/fleet.conf" && ! grep -q '127.0.0.1' "$d/real/.config/claude-fleet/fleet.conf" \
    || { WHY="the sandbox login wrote the real fleet.conf: $(cat "$d/real/.config/claude-fleet/fleet.conf")"; return 1; }
  grep -q '127.0.0.1' "$d/home/.config/claude-fleet/fleet.conf" 2>/dev/null \
    || { WHY="the sandbox's own fleet.conf did not get the address: [$out]"; return 1; }
  case "$out" in *'belongs to'*) ;; *) WHY="it did not say it ignored the carried FLEET_CONF_DIR: [$out]"; return 1 ;; esac
  WHAT="沙箱 HOME 下带着真的 FLEET_CONF_DIR 登录：真 fleet.conf 一字不动，地址写进沙箱，并说一句为什么"
}

# `fleet drill invite` on a client-only computer (issue #2024, EPIC #1906 C17):
# the MacBook keeps its hub in fleet.conf's guarded [client] section, which a
# column-0 sed never saw ("no hub"); and macOS's own /usr/bin/python3 is 3.9,
# whose datetime.fromisoformat rejects the hub's nanosecond `…Z` — the invite was
# made on the hub and its one-time code died in a ValueError before it printed.
# The drill: a client HOME (hub only in [client]), a hub answering a nanosecond
# expires_at, PATH=/usr/bin:/bin — or a python3 that refuses what 3.9 refuses
# when this box's /usr/bin/python3 is newer.
drill_hub_time_py39() {
  CAP=90; local t0 d py out rc   # a macOS runner's cold /usr/bin/python3 took 36s once
  t0=$(now)
  d="$WORK/py39-$$"; mkdir -p "$d/home/.config/claude-fleet" "$d/pybin" "$d/strict"
  py=/usr/bin/python3
  if ! "$py" -c 'import sys; sys.exit(0 if sys.version_info < (3, 11) else 1)' 2>/dev/null; then
    # a python3 whose fromisoformat takes only what 3.9's does
    cat > "$d/strict/sitecustomize.py" <<'PY2'
import datetime as _d, re as _re
class _D(_d.datetime):
    @classmethod
    def fromisoformat(cls, s):
        if not isinstance(s, str) or s.endswith(("Z", "z")) or _re.search(r"\.(\d{1,2}|\d{4,5}|\d{7,})(?!\d)", s):
            raise ValueError("Invalid isoformat string: %r" % (s,))
        return super().fromisoformat(s)
_d.datetime = _D
PY2
    printf '#!/bin/sh\nPYTHONPATH="%s" exec "%s" "$@"\n' "$d/strict" "$(command -v python3)" > "$d/pybin/python3"
    chmod +x "$d/pybin/python3"
  else
    ln -s "$py" "$d/pybin/python3"
  fi
  cat > "$d/drive.py" <<'PY2'
import json, os, signal, subprocess, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
signal.alarm(int(sys.argv[2]))
DRILL, HOME, PYBIN = sys.argv[1], sys.argv[3], sys.argv[4]
CODE = "fd_abcdefghijklmnopqrstuvwxyz"
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        out, st = {"error": "no such door"}, 404
        if self.path == "/v1/admin/drill" and self.headers.get("Authorization"):
            out, st = {"person_id": "drill-7", "kind": "drill", "login": "drill10070547", "host": "mbp",
                       "approve_code": CODE, "expires_at": "2026-10-07T05:47:35.272044642Z"}, 200
        b = json.dumps(out).encode()
        self.send_response(st); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
srv = HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
conf = os.path.join(HOME, ".config", "claude-fleet", "fleet.conf")
with open(conf, "w") as f:
    f.write('# ---- [common] ----\nFLEET_HOST=0\n\n# ---- [client] ----\n'
            'if [ "${FLEET_SHELL:-0}" = 1 ]; then\n  CCQUOTA_HUB_URL="http://127.0.0.1:%d"\nfi\n'
            '\n# ---- [node] ----\nif [ "${FLEET_SHELL:-0}" != 1 ]; then\n:\nfi\n' % srv.server_address[1])
env = {k: v for k, v in os.environ.items() if not k.startswith(("FLEET_", "CCQUOTA_", "XDG_", "PYTHON"))}
env.update(HOME=HOME, PATH=PYBIN + ":/usr/bin:/bin", TZ="UTC", CCQUOTA_VIEWER_TOKEN="admin-token")
r = subprocess.run(["bash", DRILL, "invite", "--ttl", "5m"], env=env, capture_output=True, text=True, timeout=80)
out = (r.stdout + r.stderr).strip()
if r.returncode != 0 or CODE not in r.stdout:
    print("WHY=no code printed (rc %d): %s" % (r.returncode, out.replace("\n", " | ")[:300])); sys.exit(1)
if not any(l.startswith("到期") and "10-07 05:47" in l for l in r.stdout.splitlines()):
    print("WHY=no expiry printed: %s" % out.replace("\n", " | ")[:300]); sys.exit(1)
print("OK")
PY2
  out=$(python3 "$d/drive.py" "$BIN/fleet-drill.sh" "$((CAP + 10))" "$d/home" "$d/pybin" 2>&1); rc=$?
  [ "$rc" = 0 ] && [ "$out" = OK ] || { WHY=${out#WHY=}; WHY="${WHY:-the drive died}"; return 1; }
  SECS=$(since "$t0"); WHAT="客户端（入口只写在 [client] 段）用 python 3.9 跑 fleet drill invite：找到入口，纳秒时间照样打出确认码和到期"
}

# A second client pushes the first off (issue #1932, EPIC #1906 C13): until
# 2026-10-06 a person held ONE client lease — the iPhone opening took it over and
# the MacBook fell to its standby screen; on one machine a second `fleet` popped
# the standby screen on the client already attached. The real client on its own
# -L socket, its lease a fake keeping the hub's rules (a lease per client, the
# primary = the latest input — TestClientLeaseTableSeveral pins the hub's own):
# two terminals attached to the machine, then another device opening its own
# lease — nobody on standby, this server still renewing — and typing here makes
# it the primary again.
drill_second_client() {
  CAP=45; local t0 s="${CSESS}2" sc="$WORK/sc" out
  client_setup
  mkdir -p "$sc/cur"; : > "$sc/log"
  cat > "$sc/lease" <<EOF
#!/bin/bash
h="$sc"; act=\$1; shift; lease=''; dev=''
while [ \$# -gt 0 ]; do case "\$1" in --lease) lease=\$2; shift 2 ;; --device) dev=\$2; shift 2 ;; *) shift ;; esac; done
[ "\$act" = device ] && { printf 'MacBook\tFakeTerm\n'; exit 0; }
echo "\$act \$lease \$dev" >> "\$h/log"
case "\$act" in
  acquire) if [ -n "\$lease" ] && [ -f "\$h/cur/\$lease" ]; then n=\$lease; else n=L\$RANDOM\$\$; fi
           echo "\$dev" > "\$h/cur/\$n"; printf 'active\t%s\t%s\t\t\n' "\$n" "\$dev" ;;
  renew|input) if [ -f "\$h/cur/\$lease" ]; then
             [ "\$act" = input ] && echo "\$lease" > "\$h/primary"
             printf 'active\t%s\t\t\t\n' "\$lease"
           else printf 'taken_over\t\tiPhone\t\t\n'; fi ;;
  release) rm -f "\$h/cur/\$lease"; printf 'released\t\t\t\t\n' ;;
  *) printf 'none\t\t\t\t\n' ;;
esac
EOF
  chmod +x "$sc/lease"
  # `fleet` again on this machine, as the person types it (the drive runs it
  # while the first terminal is attached)
  { printf '#!/bin/bash\n'; declare -f client_env client_start; printf 'WORK=%q\n' "$WORK"
    # its own cache: the other client drills' keepers live in $WORK/ccache, and
    # one keeper per cache is the rule
    printf 'client_start %q FLEET_CLIENT_LEASE_CMD=%q FLEET_CLIENT_LEASE_EVERY=1 FLEET_CLIENT_INPUT_EVERY=1 FLEET_SHELL_CACHE=%q\n' \
      "$s" "$sc/lease" "$sc/cache"
  } > "$sc/fleet"; chmod +x "$sc/fleet"
  t0=$(now)
  "$sc/fleet" || { WHY="the client did not start: $(head -3 "$WORK/up-$s.err")"; return 1; }
  out=$(python3 - "$REAL_TMUX" "$s" "$sc/cache/tmp" "$sc" <<'PY' 2>&1
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time
tmux, sess, cl, h = sys.argv[1:5]
signal.alarm(60)
kids = []
def attach():
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(TERM="xterm-256color", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
        os.environ.pop("TMUX", None)
        os.execvp(tmux, [tmux, "-L", sess, "attach-session", "-t", "=" + sess])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
    kids.append((pid, fd)); seen.append(b"")
seen = []
def pump(secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd for _, fd in kids], [], [], 0.1)
        for i, (_, fd) in enumerate(kids):
            if fd in r:
                try: seen[i] += os.read(fd, 65536)
                except OSError: pass
def until(secs, ok):   # pump while waiting: a slow runner's keeper ticks late
    end = time.time() + secs
    while time.time() < end:
        if ok(): return True
        pump(0.3)
    return ok()
def popped(i):   # the standby screen drawn on that terminal
    return "按回车".encode() in seen[i]
def standby():
    return os.path.exists(os.path.join(cl, "client.standby"))
def lease():
    try: return open(os.path.join(cl, "client.lease")).read().strip()
    except OSError: return ""
def log():
    return open(os.path.join(h, "log")).read()
def die(why):
    print("WHY=" + why); sys.exit(1)
try:
    attach(); pump(2.0)
    subprocess.run([os.path.join(h, "fleet")], capture_output=True, timeout=20)   # `fleet` again
    attach(); pump(3.0)
    n = subprocess.run([tmux, "-L", sess, "list-clients", "-F", "x"], capture_output=True, text=True).stdout.count("x")
    if n != 2: die("two terminals: %d attached" % n)
    if standby() or popped(0): die("the second terminal sent the first to standby")
    me = lease()
    if not me: die("this server holds no lease")
    # another device opens its own lease, and is the primary
    r = subprocess.run([os.path.join(h, "lease"), "acquire", "--device", "iPhone"], capture_output=True, text=True).stdout
    open(os.path.join(h, "primary"), "w").write(r.split("\t")[1] + "\n")
    # a renewal, or an input (which renews too: tmux may bump a client's
    # activity on its own, e.g. on attach)
    held = lambda: log().count("renew " + me) + log().count("input " + me)
    renews = held()
    renewed = until(10, lambda: held() > renews)
    if standby() or popped(0) or popped(1) or lease() != me: die("another device opening its lease put this one on standby")
    if not renewed: die("this server stopped renewing (lease %s; hub saw: %s)" % (me, " ; ".join(log().splitlines()[-4:])))
    # typing here (F12, a key nothing binds to an action): the input goes out
    os.write(kids[0][1], b"\x1b[24~")
    if not until(10, lambda: open(os.path.join(h, "primary")).read().strip() == me):
        die("typing here sent no input (the iPhone still primary)")
    print("OK")
finally:
    for pid, _ in kids:
        try: os.kill(pid, signal.SIGTERM)
        except OSError: pass
PY
)
  "$REAL_TMUX" -L "$s" kill-server 2>/dev/null
  [ "$(printf '%s\n' "$out" | tail -n 1)" = OK ] || { WHY=$(printf '%s\n' "$out" | sed -n 's/^WHY=//p' | tail -n 1)
    WHY="${WHY:-the drive died: $(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ')}"; return 1; }
  SECS=$(since "$t0"); WHAT="同一台两个终端 + 另一台设备各自的租约，谁也不进待机；在这里打字它又是主客户端"
}

# ---- phone-squeezes-window (#1933): two clients of one fleet, 160 and 50 columns,
# each through its own view session (#1489) on the same window, under the node
# conf's own window-size lines. Typing on one sizes the window to it; a view's
# `select` (fleet-remote-view.sh: switch-client -c) does the same for a window
# it moves to. Red on `window-size smallest`: the phone held every window at 50.
drill_phone_squeezes_window() {
  CAP=20; local t0 out conf="$ROOT/conf/tmux-attention.conf"
  out=$(grep -E '^set -g (window-size|aggressive-resize) ' "$conf")
  [ -n "$out" ] || { WHY="conf/tmux-attention.conf sets no window-size"; return 1; }
  printf '%s\n' "$out" > "$WORK/ws.conf"
  t0=$(now)
  out=$(python3 - "$REAL_TMUX" "$WORK/sock-ws" "$WORK/ws.conf" <<'PY' 2>&1
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time
tmux, sock, conf = sys.argv[1:4]
signal.alarm(30)
def T(*a): return subprocess.run([tmux, "-S", sock] + list(a), capture_output=True, text=True).stdout.strip()
def die(m): print("WHY=" + m); sys.exit(1)
T("-f", "/dev/null", "new-session", "-d", "-s", "fl", "-x", "120", "-y", "30", "sleep 600")
T("source-file", conf)
w = T("display", "-p", "-t", "=fl:", "#{window_id}")
kids, fds = [], []
def attach(view, cols, rows):
    T("new-session", "-d", "-t", "=fl", "-s", view); T("set", "-t", view, "status", "off")
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.pop("TMUX", None); os.environ["TERM"] = "xterm-256color"
        os.execvp(tmux, [tmux, "-S", sock, "attach-session", "-t", "=" + view])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    kids.append(pid); fds.append(fd); return fd
def pump(secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select(fds, [], [], 0.05)
        for fd in r:
            try: os.read(fd, 65536)
            except OSError: pass
def width(win):
    return T("display", "-p", "-t", win, "#{window_width}")
def until(want, win, what):
    end = time.time() + 5
    while time.time() < end:
        if width(win) == want: return
        pump(0.1)
    die("%s: the window is %s columns, not %s" % (what, width(win), want))
try:
    mac = attach("fl@view-mac", 160, 40); pump(0.5)
    phone = attach("fl@view-phone", 50, 30); pump(0.5)
    if T("list-clients", "-F", "#{client_tty}").count("\n") != 1: die("two clients did not attach")
    os.write(mac, b"x"); until("160", w, "typed on the Mac (160 columns)")
    os.write(phone, b"y"); until("50", w, "typed on the phone (50 columns)")
    os.write(mac, b"z"); until("160", w, "typed on the Mac again")
    # the phone moves to a second window, then the Mac's view selects it the way
    # fleet-remote-view.sh does: by its client
    w2 = T("new-window", "-d", "-P", "-F", "#{window_id}", "-t", "fl:", "sleep 600")
    T("select-window", "-t", "=fl@view-phone:" + w2); os.write(phone, b"y"); until("50", w2, "the phone on window 2")
    tty = T("list-clients", "-t", "=fl@view-mac", "-F", "#{client_tty}")
    T("switch-client", "-c", tty, "-t", "=fl@view-mac:" + w2); until("160", w2, "the Mac's view selected window 2")
    print("OK")
finally:
    for pid in kids:
        try: os.kill(pid, signal.SIGTERM)
        except OSError: pass
PY
)
  "$REAL_TMUX" -S "$WORK/sock-ws" kill-server 2>/dev/null
  [ "$(printf '%s\n' "$out" | tail -n 1)" = OK ] || { WHY=$(printf '%s\n' "$out" | sed -n 's/^WHY=//p' | tail -n 1)
    WHY="${WHY:-the drive died: $(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ')}"; return 1; }
  grep -q 'switch-client -c "$c"' "$BIN/fleet-remote-view.sh" \
    || { WHY="fleet-remote-view.sh select no longer switches the view's own client"; return 1; }
  SECS=$(since "$t0"); WHAT="160 列与 50 列两个客户端看同一窗口：谁打字跟谁；视图切窗口也按自己的宽度"
}

# ---- hub-restart-where (#1995): the hub keeps the client leases in memory, so a
# deploy forgets them; each live client's next renewal re-adopts its own id — but
# until 2026-10-06 a renewal carried only the lease id, so the re-adopted lease
# had no device, terminal or caps and fleet-client-where.sh said 未知设备 until
# the client was opened again. The real client (bin/fleet → fleet-shell.sh's
# keeper → fleet-client-lease.py) against a fake hub keeping the hub's rules (a
# renewal of an unknown id is adopted and filled from its body — Go's
# TestClientLeaseRenewRefillsAfterRestart pins the hub's own): where before, the
# hub's memory wiped, where after ONE renewal.
drill_hub_restart_where() {
  CAP=20; local t0 s="${CSESS}w" sc="$WORK/hrw" out port='' _ hpid
  client_setup
  mkdir -p "$sc"
  cat > "$sc/hub.py" <<'PY'
import json, signal, sys, threading, time, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
signal.alarm(int(sys.argv[2]))
cur, log = {}, open(sys.argv[3], "a", buffering=1)
def fill(l, b):
    for k in ("device", "terminal", "os", "via", "host", "version"):
        if (b.get(k) or "").strip(): l[k] = b[k].strip()
    if b.get("caps") is not None: l["caps"] = b["caps"]
    l.setdefault("device", "未知设备")
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        if self.path == "/_restart":
            cur.clear(); log.write("RESTART\n"); out = {}
        elif self.path in ("/v1/fleet/client", "/v1/fleet/client/test"):
            act, lid = b.get("action") or "get", b.get("lease") or ""
            log.write("%s %s %s\n" % (act, lid, json.dumps({k: v for k, v in b.items() if k not in ("action", "lease")}, ensure_ascii=False)))
            if act == "acquire":
                lid = lid if lid in cur else uuid.uuid4().hex[:12]
                cur.setdefault(lid, {"id": lid})
            elif act in ("renew", "input"):
                cur.setdefault(lid, {"id": lid})   # a restart: the same id, adopted
            if act in ("acquire", "renew", "input"):
                fill(cur[lid], b); cur[lid]["at"] = time.time()
                out = {"state": "active", "lease": cur[lid]}
            elif act == "release":
                cur.pop(lid, None); out = {"state": "released"}
            else:
                p = max(cur.values(), key=lambda l: l["at"], default=None)
                out = {"state": "active", "lease": p, "clients": [p], "primary": p["id"]} if p else {"state": "none"}
            if "/test" in self.path: out["identity"] = "test"
        else:
            self.send_response(404); self.end_headers(); return
        d = json.dumps(out).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
    do_GET = lambda self: (self.send_response(404), self.end_headers())
srv = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1] + ".tmp", "w").write(str(srv.server_address[1])); __import__("os").replace(sys.argv[1] + ".tmp", sys.argv[1])
srv.serve_forever()
PY
  : > "$sc/log"
  # a busy macOS runner takes seconds to start a python: the start is not timed
  python3 "$sc/hub.py" "$sc/port" "$((CAP + 90))" "$sc/log" 2>"$sc/hub.err" & hpid=$!
  for _ in $(seq 1 300); do [ -s "$sc/port" ] && break; sleep 0.1; done
  { read -r port < "$sc/port"; } 2>/dev/null
  [ -n "$port" ] || { kill "$hpid" 2>/dev/null; WHY="the fake hub did not start in 30s: $(tail -2 "$sc/hub.err" | tr '\n' ' ')"; return 1; }
  local hub="http://127.0.0.1:$port" before
  # where, as a session on this machine reads it
  hw() { ( client_env; export FLEET_HUB_URL="$hub" FLEET_HUB_TOKEN=tok FLEET_SHELL_SESSION="$s" FLEET_SHELL_CACHE="$sc/cache"
           unset CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_WORKER_CRED FLEET_WORKER_ASSERT FLEET_SEAT FLEET_CLIENT_IDENTITY
           bash "$BIN/fleet-client-where.sh" 2>&1 ); }
  if ! client_start "$s" FLEET_HUB_URL="$hub" FLEET_HUB_TOKEN=tok FLEET_CLIENT_DEVICE="Verky's Mac" \
       LC_TERMINAL=iTerm2 LC_TERMINAL_VERSION=3.6 FLEET_CLIENT_XTVERSION=0 FLEET_CLIENT_IDENTITY=person \
       FLEET_CLIENT_LEASE_EVERY=1 FLEET_CLIENT_INPUT_EVERY=1 FLEET_SHELL_CACHE="$sc/cache"; then
    kill "$hpid" 2>/dev/null; WHY="the client did not start: $(head -3 "$WORK/up-$s.err")"; return 1
  fi
  out=''
  for _ in $(seq 1 100); do out=$(hw); case "$out" in *"Verky's Mac"*iTerm2*) break ;; esac; sleep 0.1; done
  before=$out
  printf '入口重启前：%s\n' "$out" > "$sc/where.txt"
  case "$out" in *"Verky's Mac"*iTerm2*) ;; *)
    kill "$hpid" 2>/dev/null; "$REAL_TMUX" -L "$s" kill-server 2>/dev/null
    WHY="before the restart where said [$out] (hub saw: $(tail -3 "$sc/log" | tr '\n' ' '))"; return 1 ;; esac
  # the hub restarts: every lease forgotten
  curl -s -X POST -d '{}' "$hub/_restart" >/dev/null
  t0=$(now)
  printf '入口重启后：%s\n' "$(hw)" >> "$sc/where.txt"
  for _ in $(seq 1 $((CAP * 10))); do
    grep -q '^RESTART' "$sc/log" && sed -n '/^RESTART/,$p' "$sc/log" | grep -q '^renew ' && { out=$(hw); [ "$out" = "$before" ] && break; }
    sleep 0.1
  done
  SECS=$(since "$t0")
  printf '一次续租后：%s\n' "$out" >> "$sc/where.txt"
  [ -n "${BREAK_WHERE_OUT:-}" ] && cp "$sc/where.txt" "$BREAK_WHERE_OUT"
  "$REAL_TMUX" -L "$s" kill-server 2>/dev/null
  sleep 0.3; kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
  case "$out" in "$before") ;; *)
    WHY="after the hub restarted and the client renewed, where said [$out] (renewal sent: $(sed -n '/^RESTART/,$p' "$sc/log" | grep -m1 '^renew '))"; return 1 ;; esac
  WHAT="入口重启（清空租约）后，客户端下一次续租补上设备 / 终端 / 能力：where 回到 Verky's Mac · iTerm2"
}

drill_hub_deploy_lost_config() {
  # A hub release whose overlay lost its config (#2060): /healthz 200 and the
  # right commit, while /install and `fleet login` are 404 and /version has no
  # stable. The release's own health check (hub-release/release.sh, which the
  # workflow rolls back on) must call that unhealthy — and a whole entry healthy.
  CAP=20; local t0 sc="$WORK/hdl" rel="$ROOT/.github/actions/hub-release/release.sh" port='' _ hpid out rc
  mkdir -p "$sc"
  cat > "$sc/hub.py" <<'PY2'
import json, signal, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
signal.alarm(int(sys.argv[2]))
mode = lambda: open(sys.argv[3]).read().strip()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body, ctype="application/json"):
        d = body.encode(); self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
    def do_GET(self):
        whole = mode() == "whole"
        if self.path == "/healthz": return self.reply(200, "ok", "text/plain")
        if self.path == "/version":
            v = {"commit": "abc1234", "version": "prod-abc1234", "client_version": "c3e295c85d66"}
            if whole: v["stable"] = "644641e0c0d2d12fdbba3c7b3d8d7e517062fa1a"
            return self.reply(200, json.dumps(v))
        if self.path == "/install" and whole: return self.reply(200, "#!/bin/sh\necho fleet\n", "text/x-shellscript")
        self.reply(404, "404 page not found\n", "text/plain")
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/v1/fleet/login/start" and mode() == "whole": return self.reply(400, '{"error":"no public key"}')
        self.reply(404, "404 page not found\n", "text/plain")
srv = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1] + ".tmp", "w").write(str(srv.server_address[1])); __import__("os").replace(sys.argv[1] + ".tmp", sys.argv[1])
srv.serve_forever()
PY2
  echo lost > "$sc/mode"
  python3 "$sc/hub.py" "$sc/port" "$((CAP + 60))" "$sc/mode" 2>"$sc/hub.err" & hpid=$!
  for _ in $(seq 1 300); do [ -s "$sc/port" ] && break; sleep 0.1; done
  { read -r port < "$sc/port"; } 2>/dev/null
  [ -n "$port" ] || { kill "$hpid" 2>/dev/null; WHY="the fake hub did not start in 30s: $(tail -2 "$sc/hub.err" | tr '\n' ' ')"; return 1; }
  t0=$(now)
  out=$(HUB_URLS="http://127.0.0.1:$port" HEALTH_SECS=0 HUB_DEPLOY_SIMULATE_UNHEALTHY=false bash "$rel" health abc1234 2>&1); rc=$?
  SECS=$(since "$t0")
  if [ "$rc" = 0 ]; then
    kill "$hpid" 2>/dev/null; WHY="a release with /install 404, no stable, login 404 passed the health check: $out"; return 1
  fi
  case "$out" in *'/install=404'*'no stable'*'login/start=404'*) ;; *)
    kill "$hpid" 2>/dev/null; WHY="the health check failed without naming the three faults: $(printf '%s' "$out" | tr '\n' ' ')"; return 1 ;; esac
  echo whole > "$sc/mode"
  out=$(HUB_URLS="http://127.0.0.1:$port" HEALTH_SECS=0 HUB_DEPLOY_SIMULATE_UNHEALTHY=false bash "$rel" health abc1234 2>&1); rc=$?
  kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
  [ "$rc" = 0 ] || { WHY="a whole entry failed the health check: $(printf '%s' "$out" | tr '\n' ' ')"; return 1; }
  WHAT="入口部署丢了配置（/install 404、/version 无 stable、login/start 404）：健康检查判不健康 → hub-deploy 回退"
}

# A machine config stranded as fleet `fleet` (issue #2059): before #1887 the layout
# migrator moved fleet.conf — the machine's ONE file, which carried the fleet's
# FLEET_ISSUE_BRIDGE=1 since #1623 folded the fleet conf into it — to
# fleets/fleet/conf, and the next migrate wrote an empty fleet.conf. The phantom
# fleet `fleet` (its trailing FLEET_REPO moved to repos/ by #1937) went on bridging
# o/a; the real fleet `two` (o/a + o/b) bridged nothing, and `--to-worker` to an
# o/b worker said 「将转达」 for an hour. The sandbox is that estate, with a real
# isolated tmux server for `two` and a gh that logs every listing. Asserts:
# before the sync the bridge does not cover o/b (so fleet-comment falls back to the
# peer channel); one sync pass (`fleet-conf.sh migrate`) carries the stranded keys
# back and retires the phantom; then the next ticks list o/b's comments — the
# examined line on the second (the first seeds the watermark).
drill_multirepo_bridge_second_repo() {
  CAP=15; local d="$WORK/mb" t0 out r
  mkdir -p "$d/conf/fleets/fleet/repos" "$d/conf/fleets/two/repos" "$d/home" "$d/tt" "$d/fp" "$d/tmp" "$d/main"
  { printf "# claude-fleet — this machine's ONE config file (issue #1623). Assignments only.\n"
    printf '# Migrated by fleet-conf.sh 2026-10-05 03:14:55 from: ~/.claude/fleet/fleet.conf fleets/two/conf\n'
    printf '\n# ---- [common] ----\nFLEET_ROLE="node"\nexport FLEET_HUB_URL="https://hub.example"\nFLEET_UI_LANG="zh"\n'
    printf '\n# ---- [client] — only the shell ----\nif [ "${FLEET_SHELL:-0}" = 1 ]; then\n:\nfi  # ---- [client] end ----\n'
    printf '\n# ---- [node] ----\nif [ "${FLEET_SHELL:-0}" != 1 ]; then\n:\n# ---- was fleets/two/conf (fleet two) ----\n'
    printf 'FLEET_ISSUE_BRIDGE=1\nFLEET_MAX_SESSIONS=36\nfi  # ---- [node] end ----\n'
  } > "$d/conf/fleets/fleet/conf"
  printf 'FLEET_REPO="o/a"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="main"\n' "$d/main" > "$d/conf/fleets/fleet/repos/o-a.conf"
  printf 'o-a\n' > "$d/conf/fleets/fleet/repos/.order"
  { printf "# claude-fleet — this machine's ONE config file (issue #1623). Assignments only.\n"
    printf '# Migrated by fleet-conf.sh 2026-10-06 12:09:29 from: nothing — a new file\n'
    printf '\n# ---- [common] ----\nFLEET_HOST=1\nexport FLEET_HUB_URL="https://hub.example"\n'
    printf '\n# ---- [client] — only the shell ----\nif [ "${FLEET_SHELL:-0}" = 1 ]; then\n:\nfi  # ---- [client] end ----\n'
    printf '\n# ---- [node] ----\nif [ "${FLEET_SHELL:-0}" != 1 ]; then\n:\nfi  # ---- [node] end ----\n'
  } > "$d/conf/fleet.conf"
  printf "# claude-fleet: fleet 'two' — written by fleet-up.sh\n" > "$d/conf/fleets/two/conf"
  for r in a b; do
    printf 'FLEET_REPO="o/%s"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="main"\n' "$r" "$d/main" > "$d/conf/fleets/two/repos/o-$r.conf"
  done
  printf 'o-a\no-b\n' > "$d/conf/fleets/two/repos/.order"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/gh.log"\nexit 0\n' "$d" > "$d/fp/gh"; chmod +x "$d/fp/gh"
  mb() { env -u TMUX -u TMUX_PANE -u FLEET_SKIP_GLOBAL_CONF HOME="$d/home" FLEET_CONF_DIR="$d/conf" TMUX_TMPDIR="$d/tt" TMPDIR="$d/tmp" \
           PATH="$d/fp:$PATH" FLEET_ISSUE_BRIDGE_STATE_DIR="$d/state" FLEET_DISPATCH_LEASE_DIR="$d/leases" "$@"; }
  covers() { mb bash -c '. "$1/fleet-lib.sh"; fleet_bridge_covers "$2"' _ "$BIN" "$1"; }
  mb "$REAL_TMUX" -f /dev/null -L two new-session -d -s two -n home 'exec sleep 60' \
    || { WHY="cannot start the isolated tmux server"; return 1; }
  covers o/b && { mb "$REAL_TMUX" -L two kill-server; WHY="before the sync o/b already reads as bridged — the sandbox is not the broken estate"; return 1; }
  t0=$(now)
  out=$(mb bash "$BIN/fleet-conf.sh" migrate 2>&1) || { mb "$REAL_TMUX" -L two kill-server; WHY="the sync pass failed: $out"; return 1; }
  [ -e "$d/conf/fleets/fleet" ] && { mb "$REAL_TMUX" -L two kill-server; WHY="the phantom fleets/fleet/ is still there after the sync: $out"; return 1; }
  grep -q '^FLEET_ISSUE_BRIDGE=1$' "$d/conf/fleet.conf" || { mb "$REAL_TMUX" -L two kill-server; WHY="fleet.conf did not get FLEET_ISSUE_BRIDGE=1 back: $out"; return 1; }
  covers o/b || { mb "$REAL_TMUX" -L two kill-server; WHY="after the sync the bridge still does not cover o/b"; return 1; }
  mb bash "$BIN/fleet-issue-bridge.sh" --poll > "$d/poll1.err" 2>&1
  mb bash "$BIN/fleet-issue-bridge.sh" --poll > "$d/poll2.err" 2>&1
  SECS=$(since "$t0")
  mb "$REAL_TMUX" -L two kill-server 2>/dev/null
  grep -q 'repos/o/b/issues/comments' "$d/gh.log" 2>/dev/null \
    || { WHY="the second tick never listed o/b's comments (gh: $(tr '\n' ' ' < "$d/gh.log" 2>/dev/null); log: $(tail -2 "$d/poll2.err" | tr '\n' ' '))"; return 1; }
  grep -q 'repos/o/a/issues/comments' "$d/gh.log" || { WHY="o/a stopped being listed"; return 1; }
  WHAT="一次同步把被困的机器配置并回 fleet.conf、退役幽灵 fleet；下一拍起两个仓库都被 bridge 轮询"
}

drill_breakage_three_filers() {
  CAP=25; local d="$WORK/bk" t0 i c n0 created zeros=0 fives=0
  mkdir -p "$d/fp" "$d/conf" "$d/store" "$d/home" "$d/tmp"
  # The fake GitHub: REST paths only (a red master tends to come with a spent
  # GraphQL budget), a store on disk, and a 0.4 s pause inside `issue create` so
  # three filers that start together all reach it before any number exists.
  cat > "$d/fp/gh" <<'EOF'
#!/bin/bash
S="$BK_STORE"; printf '%s\n' "$*" >> "$S/gh.log"
case "$1" in
  issue)
    case "$2" in
      create)
        sleep 0.4
        n=$(( $(ls "$S"/issue-* 2>/dev/null | wc -l) + 101 ))
        shift 2; b=''; while [ $# -gt 0 ]; do case "$1" in --body) shift; b="$1";; esac; shift; done
        printf '%s' "$b" > "$S/issue-$n"; printf 'https://github.com/o/w/issues/%s\n' "$n" ;;
      comment)
        shift 2; n="$1"; b=''; while [ $# -gt 0 ]; do case "$1" in --body) shift; b="$1";; esac; shift; done
        printf '%s' "$b" | tr '\n' ' ' >> "$S/comments-$n"; printf '\n' >> "$S/comments-$n"
        printf 'https://github.com/o/w/issues/%s#issuecomment-1\n' "$n" ;;
    esac ;;
  api)
    p=''; for a in "$@"; do case "$a" in repos/*) p="$a";; esac; done
    case "$p" in
      repos/o/w)                    printf 'main\n' ;;
      */actions/runs\?*)            printf '77\t9003\t%s\tfailure\t2026-10-07T04:35:00Z\tselftests\t60\n77\t9002\t%s\tfailure\t2026-10-07T04:10:00Z\tselftests\t1600\n77\t9001\t%s\tsuccess\t2026-10-07T04:00:00Z\tselftests\t2200\n' "$BK_HEAD" "$BK_RED" "$BK_GREEN" ;;
      */actions/runs/9002/jobs*)    printf '501\tselftests / shard 3\n' ;;
      repos/o/w/issues\?*)          for f in "$S"/issue-*; do [ -e "$f" ] || continue; printf '%s\t%s\n' "${f##*-}" "$(tr '\n' ' ' < "$f")"; done ;;
    esac ;;
  run) cat "$BK_LOG" ;;
esac
exit 0
EOF
  chmod +x "$d/fp/gh"
  # The failed job's log, the way `gh run view --log-failed` prints it.
  printf 'selftests / shard 3\tRun tests\t2026-10-07T04:20:11.1234567Z ##[group]Run bash bin/run-selftests.sh\nselftests / shard 3\tRun tests\t2026-10-07T04:20:12.0000000Z FAIL  lint: internal/api/roles.go:88:2: duplicate key "/v1/admin/drill" in map literal\n' > "$d/log-a"
  sed 's/:88:2:/:91:4:/' "$d/log-a" > "$d/log-a2"   # the same breakage after a half-fix moved the lines
  printf 'selftests / shard 3\tRun tests\t2026-10-07T04:30:00.0000000Z FAIL  bash32-array-selftest: bin/x.sh:12: bare array on an empty array\n' > "$d/log-b"
  bk() { env -u TMUX -u TMUX_PANE HOME="$d/home" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$d/tmp" PATH="$d/fp:$PATH" \
           FLEET_GH_WRITE_GAP=0 BK_STORE="$d/store" BK_HEAD=aaaa111aaaa111 BK_RED=bbbb222bbbb222 BK_GREEN=cccc333cccc333 \
           BK_LOG="${LOG:-$d/log-a}" "$@"; }
  t0=$(now)
  for i in 1 2 3; do
    ( bk bash "$BIN/fleet-issue-file.sh" --title "master 红：routes 重复" --breakage --repo o/w --from "w$i" > "$d/out$i" 2> "$d/err$i"; echo $? > "$d/rc$i" ) &
  done
  wait
  SECS=$(since "$t0")
  created=$(ls "$d/store"/issue-* 2>/dev/null | wc -l | tr -d ' ')
  [ "$created" = 1 ] || { WHY="3 filers of one breakage made $created issues (want 1): $(cat "$d"/err? 2>/dev/null | tr '\n' ' ' | cut -c1-300)"; return 1; }
  n0=$(ls "$d/store"/issue-* | head -1); n0=${n0##*-}
  grep -q '<!-- fleet:breakage key=' "$d/store/issue-$n0" || { WHY="the issue body carries no fleet:breakage marker"; return 1; }
  for i in 1 2 3; do
    case "$(cat "$d/rc$i")" in
      0) zeros=$((zeros + 1)) ;;
      5) fives=$((fives + 1))
         grep -qx "https://github.com/o/w/issues/$n0" "$d/out$i" || { WHY="filer $i exited 5 but printed [$(cat "$d/out$i")], not #$n0"; return 1; } ;;
      *) WHY="filer $i exited $(cat "$d/rc$i"): $(tr '\n' ' ' < "$d/err$i" | cut -c1-200)"; return 1 ;;
    esac
  done
  [ "$zeros" = 1 ] && [ "$fives" = 2 ] || { WHY="exit codes: $zeros × 0, $fives × 5 (want 1 and 2)"; return 1; }
  c=$(grep -c '同一故障' "$d/store/comments-$n0" 2>/dev/null)
  [ "$c" = 2 ] || { WHY="issue #$n0 got $c 「同一故障」 comments, want 2"; return 1; }
  # A later sighting with the lock gone (another machine, or two minutes on) and
  # the lines moved: found on GitHub by the marker, same number.
  rm -rf "$d/conf/global/breakage"
  LOG="$d/log-a2" bk bash "$BIN/fleet-issue-file.sh" --title "又红了" --breakage --repo o/w --from w4 > "$d/out4" 2> "$d/err4"; c=$?
  [ "$c" = 5 ] && grep -qx "https://github.com/o/w/issues/$n0" "$d/out4" \
    || { WHY="a later sighting (lines :88→:91, lock gone) exited $c with [$(cat "$d/out4")]: $(tr '\n' ' ' < "$d/err4" | cut -c1-200)"; return 1; }
  # A different breakage on the same head files its own issue.
  LOG="$d/log-b" bk bash "$BIN/fleet-issue-file.sh" --title "另一个故障" --breakage --repo o/w --from w5 > "$d/out5" 2> "$d/err5"; c=$?
  created=$(ls "$d/store"/issue-* | wc -l | tr -d ' ')
  [ "$c" = 0 ] && [ "$created" = 2 ] || { WHY="a different breakage exited $c, issues now $created (want 0 and 2): $(tr '\n' ' ' < "$d/err5" | cut -c1-200)"; return 1; }
  # The degenerate: an ordinary filing reads none of it and leaves no lock.
  : > "$d/store/gh.log"; rm -rf "$d/conf/global/breakage"
  bk bash "$BIN/fleet-issue-file.sh" --title "普通单" --repo o/w > "$d/out6" 2> "$d/err6"; c=$?
  [ "$c" = 0 ] || { WHY="an ordinary filing exited $c: $(tr '\n' ' ' < "$d/err6" | cut -c1-200)"; return 1; }
  grep -q 'issues?state=open\|actions/runs' "$d/store/gh.log" && { WHY="an ordinary filing read a breakage path: $(grep 'issues?state=open\|actions/runs' "$d/store/gh.log" | head -1)"; return 1; }
  [ -e "$d/conf/global/breakage" ] && { WHY="an ordinary filing created the breakage lock dir"; return 1; }
  WHAT="3 个并发开单：1 张单 + 2 个退出码 5 + 2 条「同一故障」；行号变了仍认得，换故障照常开新单，普通开单不碰"
}

# Three sessions see master red and file its fix — and none passes --breakage
# (issue #2175). On 2026-10-07 11:18–11:29Z #2159 #2163 #2170 were filed that
# way for one red tokenledger-pg: the dedup lived in a skill's prose, so it ran
# only for a caller that remembered it. Now the filer itself notices: a red
# word in the text, a red base branch (per workflow, its last FINISHED run — the
# head then was a commit the workflow never ran on), and the text naming the
# base branch or the red check ⇒ --breakage all the same. Each filer words it
# differently, like the real three (one names only the Go test, in its title).
drill_breakage_no_flag() {
  CAP=25; local d="$WORK/bkn" t0 i c n0 created fives=0
  mkdir -p "$d/fp" "$d/conf" "$d/store" "$d/home" "$d/tmp"
  cat > "$d/fp/gh" <<'EOF'
#!/bin/bash
S="$BK_STORE"; printf '%s\n' "$*" >> "$S/gh.log"
case "$1" in
  issue)
    case "$2" in
      create)
        sleep 0.4
        n=$(( $(ls "$S"/issue-* 2>/dev/null | wc -l) + 2159 ))
        shift 2; b=''; while [ $# -gt 0 ]; do case "$1" in --body) shift; b="$1";; esac; shift; done
        printf '%s' "$b" > "$S/issue-$n"; printf 'https://github.com/o/w/issues/%s\n' "$n" ;;
      comment)
        shift 2; n="$1"; b=''; while [ $# -gt 0 ]; do case "$1" in --body) shift; b="$1";; esac; shift; done
        printf '%s' "$b" | tr '\n' ' ' >> "$S/comments-$n"; printf '\n' >> "$S/comments-$n" ;;
    esac ;;
  api)
    p=''; for a in "$@"; do case "$a" in repos/*) p="$a";; esac; done
    case "$p" in
      # master: tokenledger red since c902bf83 (a cancelled run before it, then
      # green); the head a6dd7c9b only ran selftests, green.
      */actions/runs\?*)  printf '200\t3002\ta6dd7c9b\tsuccess\t2026-10-07T11:07:45Z\tselftests\t900\n100\t3001\tc902bf83\tfailure\t2026-10-07T11:07:06Z\ttokenledger\t900\n100\t3000\t6ff6f385\tcancelled\t2026-10-07T11:06:33Z\ttokenledger\t960\n100\t2999\t38ae532a\tsuccess\t2026-10-07T11:05:50Z\ttokenledger\t1000\n' ;;
      */actions/runs/3001/jobs*) printf '7741\ttokenledger-pg\n' ;;
      repos/o/w/issues\?*) for f in "$S"/issue-*; do [ -e "$f" ] || continue; printf '%s\t%s\n' "${f##*-}" "$(tr '\n' ' ' < "$f")"; done ;;
    esac ;;
  run) printf 'tokenledger-pg\tstore + api tests on Postgres\t2026-10-07T11:22:21.7565667Z --- FAIL: TestFleetUsers_MachineLoginTakesOverAnOldIdentitysKey (1.12s)\n' ;;
esac
exit 0
EOF
  chmod +x "$d/fp/gh"
  bk() { env -u TMUX -u TMUX_PANE HOME="$d/home" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$d/tmp" PATH="$d/fp:$PATH" \
           FLEET_GH_WRITE_GAP=0 FLEET_BASE_BRANCH=master BK_STORE="$d/store" "$@"; }
  t0=$(now)
  ( bk bash "$BIN/fleet-issue-file.sh" --repo o/w --from w1 --title 'tokenledger-pg 红：hub_settings_legacy 两个测试在 Postgres 上报 collation "nocase" 不存在' > "$d/out1" 2> "$d/err1"; echo $? > "$d/rc1" ) &
  ( bk bash "$BIN/fleet-issue-file.sh" --repo o/w --from w2 --title 'master 红：tokenledger-pg 上 TestDropLegacyMachineLogins / TestFleetUsers_MachineLoginTakesOverAnOldIdentitysKey 失败' > "$d/out2" 2> "$d/err2"; echo $? > "$d/rc2" ) &
  ( bk bash "$BIN/fleet-issue-file.sh" --repo o/w --from w3 --title 'TestFleetUsers_MachineLoginTakesOverAnOldIdentitysKey 失败' --body 'master 的 tokenledger 工作流在 c902bf83 起红' > "$d/out3" 2> "$d/err3"; echo $? > "$d/rc3" ) &
  wait
  SECS=$(since "$t0")
  created=$(ls "$d/store"/issue-* 2>/dev/null | wc -l | tr -d ' ')
  [ "$created" = 1 ] || { WHY="3 filers with NO --breakage made $created issues (want 1): $(cat "$d"/err? 2>/dev/null | tr '\n' ' ' | cut -c1-300)"; return 1; }
  n0=$(ls "$d/store"/issue-* | head -1); n0=${n0##*-}
  grep -q '<!-- fleet:breakage key=c902bf8-' "$d/store/issue-$n0" || { WHY="the one issue carries no fleet:breakage marker at c902bf8: $(tr '\n' ' ' < "$d/store/issue-$n0" | cut -c1-200)"; return 1; }
  for i in 1 2 3; do [ "$(cat "$d/rc$i")" = 5 ] && fives=$((fives + 1)); done
  [ "$fives" = 2 ] || { WHY="want 2 × exit 5, got $fives: $(cat "$d"/rc? | tr '\n' ' ')"; return 1; }
  # The way out: --no-breakage files a second one plain, and so does a filing
  # that has nothing to do with the red.
  bk bash "$BIN/fleet-issue-file.sh" --repo o/w --title 'master 红：另一个问题' --no-breakage > "$d/out4" 2> "$d/err4"; c=$?
  bk bash "$BIN/fleet-issue-file.sh" --repo o/w --title '登录页报错 undefined' > "$d/out5" 2> "$d/err5"; i=$?
  created=$(ls "$d/store"/issue-* | wc -l | tr -d ' ')
  [ "$c" = 0 ] && [ "$i" = 0 ] && [ "$created" = 3 ] || { WHY="--no-breakage exited $c, an unrelated filing $i, issues now $created (want 0, 0, 3)"; return 1; }
  WHAT="3 个都不带 --breakage 的并发开单（措辞各异）：只建 1 张单 + 2 个退出码 5；--no-breakage 与无关的单照常开"
}

# A machine whose own gate is holding new sessions (fleet_machine_admit: memory
# tight / load high) while its heartbeat says nothing of it (issue #1836, EPIC
# #2074 C5). Since #1831 FLEET_GLOBAL_MAX_SESSIONS defaults to 0, so the beat's
# capacity read `max_sessions:0` = never full, and the hub kept placing starts
# on a machine that refused each one on arrival (RC_CAP). Node half, for real:
# `fleet-control-read.sh capacity` under stubbed readings — critical memory
# pressure, then a load over the bound, then a healthy machine, then the gate
# switched off — must say admit:false + the reason + room, admit:true + room,
# and with FLEET_ADMIT=0 admit:true and no room (nothing for the hub to hold
# on). Hub half: the Go tests that pin judge() (`TestNodePlace{SkipsPausedNode,
# AllPausedRefuses,WithoutCapFieldsFiltersNothing}`), run here when a toolchain
# and the module cache are present — GOPROXY=off, a drill never downloads;
# otherwise the Go gate (tokenledger.yml) is where they run and WHAT says so.
drill_node_paused_still_placed() {
  CAP=120; local t0 d="$WORK/np" out gohalf rc
  mkdir -p "$d/conf" "$d/tmp"
  # cap <mem-stub> <load-stub> [VAR=val …] → the capacity object. 16000 MB of RAM,
  # one agent of 400 MB (×3 growth ⇒ 1200 MB a session) — never this box's own ps.
  # The gate is switched ON here explicitly: run-selftests.sh exports FLEET_ADMIT=0
  # for the whole gate (so no selftest's spawn is held by the runner's memory),
  # and with it off capacity says admit:true and no room — the drill's last leg,
  # which passes its own FLEET_ADMIT=0 after the 1.
  cap() {
    local m="$1" l="$2"; shift 2
    env FLEET_ADMIT=1 "$@" FLEET_CONF_DIR="$d/conf" TMPDIR="$d/tmp" HOME="$d" FLEET_MEM_TOTAL_MB=16000 \
      FLEET_MEM_PS_CMD="printf '101 1 $(id -u) 409600 01:00 claude\\n'" \
      FLEET_MEM_PROBE_CMD="$m" FLEET_LOAD_PROBE_CMD="$l" \
      bash "$BIN/fleet-control-read.sh" capacity 2>&1
  }
  t0=$(now)
  out=$(cap 'echo 4 5 97 0' 'echo 0.5')
  case "$out" in *'"admit":false'*'"admit_why":"内存紧张"'*'"room":0'*) ;; *)
    WHY="capacity under critical memory pressure does not say admit:false, admit_why 内存紧张, room 0: $out"; return 1 ;; esac
  out=$(cap 'echo 1 66 5 6' 'echo 1.9')
  case "$out" in *'"admit":false'*'"admit_why":"负载过高"'*'"room":'[1-9]*) ;; *)
    WHY="capacity under load 1.9/core does not say admit:false, admit_why 负载过高 with its room: $out"; return 1 ;; esac
  out=$(cap 'echo 1 66 5 6' 'echo 0.5')
  case "$out" in *'"max_sessions":0'*'"admit":true'*'"room":'[1-9]*) ;; *)
    WHY="a healthy machine's capacity does not say admit:true with room ≥ 1: $out"; return 1 ;; esac
  case "$out" in *admit_why*) WHY="a healthy machine carries an admit_why: $out"; return 1 ;; esac
  out=$(cap 'echo 4 5 97 0' 'echo 9' FLEET_ADMIT=0)
  case "$out" in *'"admit":true'*) ;; *) WHY="FLEET_ADMIT=0 (the gate off) must say admit:true: $out"; return 1 ;; esac
  case "$out" in *'"room"'*) WHY="with FLEET_ADMIT=0 the beat still carries room — the hub would hold on it: $out"; return 1 ;; esac
  gohalf='hub half: the Go gate (tokenledger.yml) runs judge()'"'"'s tests'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run 'TestNodePlace(SkipsPausedNode|AllPausedRefuses|WithoutCapFieldsFiltersNothing)$' ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) gohalf='hub half: go test TestNodePlace{SkipsPausedNode,AllPausedRefuses,WithoutCapFieldsFiltersNothing} ok' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        gohalf='hub half: no go module cache / toolchain here — the Go gate (tokenledger.yml) runs judge()'"'"'s tests' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
  WHAT="机器暂停接新时心跳带 admit:false（内存紧张 / 负载过高）+ room，健康时 admit:true + room，FLEET_ADMIT=0 不带 room；$gohalf"
}

# A release that deletes a hook script an old session's table still calls: the
# move must refuse BEFORE the tag moves, naming the script; --force moves it and
# leaves one line (issue #2075, EPIC #2074 C2).
drill_oldcfg_deleted_hook() {
  CAP=30; local t0 d out rc c1 c2
  d="$WORK/oldcfg"; mkdir -p "$d/shim" "$d/seed"
  printf '#!/bin/sh\nprintf "completed success ci\\n"\n' > "$d/shim/gh"; chmod +x "$d/shim/gh"
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/seed" 2>/dev/null || exit 1
    mkdir -p "$d/seed/hooks" "$d/seed/bin"
    printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/h.sh"}]}]}}\n' > "$d/seed/hooks/settings-hooks.json"
    printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$d/seed/bin/h.sh"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm hooked && git -C "$d/seed" push -q origin HEAD:master || exit 1
    git -C "$d/seed" rev-parse HEAD > "$d/c1"
    git -C "$d/seed" rm -q bin/h.sh && git -C "$d/seed" commit -qm 'drop h.sh' && git -C "$d/seed" push -q origin HEAD:master || exit 1
    git -C "$d/seed" rev-parse HEAD > "$d/c2"
    git --git-dir="$d/origin.git" update-ref refs/tags/stable "$(cat "$d/c1")" && git clone -q "$d/origin.git" "$d/co" 2>/dev/null
  ) || { WHY="could not build the rig repo"; return 1; }
  c1=$(cat "$d/c1"); c2=$(cat "$d/c2")
  t0=$(now)
  out=$(PATH="$d/shim:$PATH" FLEET_STABLE_LOG="$d/stable-move.log" sh "$BIN/fleet-stable.sh" move "$c2" --dir "$d/co" --repo o/r 2>&1); rc=$?
  SECS=$(since "$t0")
  [ "$rc" = 3 ] || { WHY="move exited $rc, want 3 (refused): $(printf '%s' "$out" | tail -3 | tr '\n' '|')"; return 1; }
  case "$out" in *'REFUSED — oldcfg:'*) ;; *) WHY="the refusal is not prefixed oldcfg: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1 ;; esac
  case "$out" in *'bin/h.sh not in the new tree'*) ;; *) WHY="the refusal does not name bin/h.sh: $(printf '%s' "$out" | tr '\n' '|')"; return 1 ;; esac
  [ "$(git --git-dir="$d/origin.git" rev-parse refs/tags/stable)" = "$c1" ] || { WHY="stable moved despite the red replay"; return 1; }
  out=$(PATH="$d/shim:$PATH" FLEET_STABLE_LOG="$d/stable-move.log" sh "$BIN/fleet-stable.sh" move "$c2" --force --dir "$d/co" --repo o/r 2>&1) \
    || { WHY="--force did not move: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1; }
  [ "$(git --git-dir="$d/origin.git" rev-parse refs/tags/stable)" = "$c2" ] || { WHY="--force left stable at the old commit"; return 1; }
  grep -q "	forced	" "$d/stable-move.log" 2>/dev/null || { WHY="--force left no line in stable-move.log"; return 1; }
  WHAT="删了 h.sh 的发版被拒（oldcfg: 点名 bin/h.sh，stable 没动）；--force 才挪并记一行"
}

# ---- macos-red-to-stable (#2286): the macOS selftests left the PR and run on
# master after the merge. A BSD-only red there must (1) be filed once as a breakage
# by the watcher and (2) stop `fleet-stable.sh move` with `macos:`; once the run on
# the target goes green the same move goes through. Fake gh (the runs / check
# runs), fake filer; a real bare repo + tag.
drill_macos_red_to_stable() {
  CAP=30; local t0 d out rc c1 c2
  d="$WORK/macosred"; mkdir -p "$d/shim" "$d/seed" "$d/conf"
  cat > "$d/shim/gh" <<SH
#!/bin/sh
case "\$*" in
  *actions/workflows/*status=completed*) cat "$d/runs.watch" ;;
  *actions/workflows/*) cat "$d/runs.stable" ;;
  *actions/runs/*/jobs*) printf '7\tmacOS shard 1\n' ;;
  'run view'*) printf 'FAIL  bsd-only-selftest.sh  1s\n' ;;
  *) printf 'completed success shard 1\n' ;;
esac
SH
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/filed"\necho https://github.com/o/r/issues/77\n' "$d" > "$d/filer"
  chmod +x "$d/shim/gh" "$d/filer"
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/seed" 2>/dev/null || exit 1
    mkdir -p "$d/seed/.github/workflows"; echo 'name: selftests (macOS)' > "$d/seed/.github/workflows/selftests-macos.yml"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm bsd && git -C "$d/seed" push -q origin HEAD:master || exit 1
    git -C "$d/seed" rev-parse HEAD > "$d/c1"
    echo x > "$d/seed/f"; git -C "$d/seed" add -A && git -C "$d/seed" commit -qm 'bsd-only break' && git -C "$d/seed" push -q origin HEAD:master || exit 1
    git -C "$d/seed" rev-parse HEAD > "$d/c2"
    git --git-dir="$d/origin.git" update-ref refs/tags/stable "$(cat "$d/c1")" && git clone -q "$d/origin.git" "$d/co" 2>/dev/null
  ) || { WHY="could not build the rig repo"; return 1; }
  c1=$(cat "$d/c1"); c2=$(cat "$d/c2")
  # The watcher reads id/sha/conclusion/event; the stable gate head_sha/status/
  # conclusion/event/id/title.
  printf '9\t%s\tfailure\tpush\n8\t%s\tsuccess\tpush\n' "$c2" "$c1" > "$d/runs.watch"
  printf '%s\tcompleted\tfailure\tpush\t9\tselftests (macOS)\n' "$c2" > "$d/runs.stable"
  t0=$(now)
  # red: the watcher files it as a breakage …
  out=$(PATH="$d/shim:$PATH" FLEET_CONF_DIR="$d/conf" FLEET_MACOS_FILE_CMD="$d/filer" \
          bash "$BIN/fleet-macos-watch.sh" --repo o/r --now 2>&1) || { WHY="the watcher failed: $out"; return 1; }
  grep -q -- '--breakage' "$d/filed" 2>/dev/null || { WHY="the red run was not filed with --breakage: $out"; return 1; }
  grep -q 'bsd-only-selftest.sh' "$d/filed" || { WHY="the filing does not name the red test"; return 1; }
  # … and stable refuses to move onto it.
  out=$(PATH="$d/shim:$PATH" sh "$BIN/fleet-stable.sh" move "$c2" --dir "$d/co" --repo o/r 2>&1); rc=$?
  [ "$rc" = 3 ] || { WHY="move onto the red commit exited $rc, want 3: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1; }
  case "$out" in *'REFUSED — macos:'*) ;; *) WHY="the refusal is not prefixed macos: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1 ;; esac
  [ "$(git --git-dir="$d/origin.git" rev-parse refs/tags/stable)" = "$c1" ] || { WHY="stable moved onto a red macOS run"; return 1; }
  # green: the fix's run on the same target is green → the move goes through.
  printf '%s\tcompleted\tsuccess\tworkflow_dispatch\t10\tselftests (macOS) @ %s\n%s\tcompleted\tfailure\tpush\t9\tselftests (macOS)\n' \
    "$c1" "$c2" "$c2" > "$d/runs.stable"
  out=$(PATH="$d/shim:$PATH" sh "$BIN/fleet-stable.sh" move "$c2" --dir "$d/co" --repo o/r 2>&1) \
    || { WHY="the move after a green run failed: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1; }
  SECS=$(since "$t0")
  [ "$(git --git-dir="$d/origin.git" rev-parse refs/tags/stable)" = "$c2" ] || { WHY="stable did not move after the run went green"; return 1; }
  WHAT="master 上 macOS 红：开出带指纹的修复单、stable 拒挪（macos:）；同一提交跑绿后照常挪"
}

# ---- burst-lands-on-one (#2077, EPIC #2074 C6): the hub counts the starts it just
# sent and spreads a burst. The whole change is the hub's (judge + the journal), so
# the drill is its Go tests, run for real where a toolchain is: four starts at two
# machines reading the same land two and two; a noted start ages out at 90 s; the
# node's beat showing the sessions clears them once; a reported room is theirs
# first; a refused start is forgotten. Without go the tests must at least exist by
# name, so the row cannot stay green on a deleted test.
drill_burst_lands_on_one() {
  CAP=120; local t0 out rc tests f
  tests='TestPlacementBurstSpreads TestPlacementRecentExpires TestPlacementRecentReflectedByBeat TestPlacementRecentScoredUntilTheBeatShowsIt TestPlacementRecentTakesTheRoom TestPlacementRecentForgottenOnRefusal TestRecentScore'
  f="$ROOT/tokenledger/internal/api/fleet_recent_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'recent' "$ROOT/tokenledger/internal/api/fleet_write.go" || { WHY="judge() does not read the recent table"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='入口连续派 4 个 → 两台各 2（go test 七条：分摊、90 秒过期、心跳抵消一次、room 先扣、拒掉即忘）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；七条测试按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：七条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- dispatch-wrong-replica (#2124, EPIC #2119 C5): with two hub replicas a node's
# link ends in one of them; a write that lands on the other is handed across
# (fleet_node_conns + /internal/v1/node-write). The whole change is the hub's, so
# the drill is its Go tests, run for real where a toolchain is: two replicas × two
# nodes × 100 starts all delivered, a reconnect to the other replica keeps them
# coming, a dead holder is failed (not unknown), the route admits only the
# replicas' token, a single hub never forwards. Without go the tests must at
# least exist by name.
drill_dispatch_wrong_replica() {
  CAP=120; local t0 out rc tests f
  tests='TestNodeRouteTwoReplicas TestNodeRouteHolderGone TestNodeRouteNeedsReplicaToken TestNodeRouteSingleNeverForwards TestParseReplica'
  f="$ROOT/tokenledger/internal/api/node_route_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'peerOf' "$ROOT/tokenledger/internal/api/fleet_write.go" || { WHY="the write path does not look for the replica holding the link"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='两份入口 × 两台机器 × 100 次派活全送达，重连到另一份照样送达（go test 五条：转发、持有方不在、令牌、单份不转发、配置）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；六条测试按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：六条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- two-hubs-double-refresh (#2123, EPIC #2119 C4): two hub replicas on one
# Postgres run every background loop once and refresh an account once. The change
# is the hub's, so the drill is its Go tests where a toolchain is: two vaults on one
# database refresh one account once with CrossLock (and twice without — the
# hazard, shown); a single hub leads everything. The two-process Postgres legs
# (one runner per job for an hour of ticks, handover ≤ 15 s) run in the Go gate's
# tokenledger-pg job. Without go the tests and the loop gates must exist by name.
drill_two_hubs_double_refresh() {
  CAP=120; local t0 out rc f tl
  t0=$(now)
  f="$ROOT/tokenledger/internal/leader/leader_test.go"
  for tl in TestSingleHubAlwaysLeads TestTwoReplicasOneRunner TestCloseHandsOver TestLockAcrossReplicas; do
    grep -q "^func $tl(" "$f" 2>/dev/null || { WHY="the leader test $tl is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q '^func TestTwoReplicasRefreshOnce(' "$ROOT/tokenledger/internal/credvault/credvault_test.go" 2>/dev/null \
    || { WHY="credvault has no TestTwoReplicasRefreshOnce"; return 1; }
  grep -q 'v.CrossLock(' "$ROOT/tokenledger/internal/credvault/credvault.go" || { WHY="Lease takes no cross-replica lock"; return 1; }
  grep -q 'Leader(ctx, "alerts")' "$ROOT/tokenledger/internal/api/fleet_alerts.go" || { WHY="node alerts are not gated on the leader"; return 1; }
  grep -q 'Leader(ctx, "spot")' "$ROOT/tokenledger/internal/api/fleet_spot.go" || { WHY="the SPOT controller is not gated on the leader"; return 1; }
  grep -q 'Leader(ctx, "prune")' "$ROOT/tokenledger/cmd/ccquota/hub.go" || { WHY="the daily prune is not gated on the leader"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run '^(TestTwoReplicasRefreshOnce|TestSingleHubAlwaysLeads)$' ./internal/credvault ./internal/leader 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='两份保险箱同时租一个账号 → 只刷新一次（无跨副本锁时两次）；单份恒为 leader（go test）；两进程 Postgres 一小时只一份在干、交接 ≤15 s 在 Go 门 tokenledger-pg' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；测试与三处 Leader 门按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：测试与三处 Leader 门按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- hub-release-downtime (#2125, EPIC #2119 C6): a hub release used to be
# 30–60 s of the whole site down (Recreate on one SQLite disk), and nobody
# measured it. Now every release is measured — probe.sh, once a second, /healthz
# + a write; a fake hub that goes down for ~3 s must read downtime_seconds ≥ 2,
# one that stays up must read 0 — and the base is the rolling shape that makes
# it 0 (two replicas, maxUnavailable 0, /readyz, preStop, a PDB), whose hub half
# is go-tested here when a toolchain is. The real thing (kind, two replicas +
# Postgres, three releases, a deleted pod, a broken release + rollback) is CI's
# hub-rolling.yml; this checks it is there and runs drill.sh.
drill_hub_release_downtime() {
  CAP=60; local t0 sc="$WORK/hrd" probe="$ROOT/.github/actions/hub-release/probe.sh" port='' hpid out out2 down1 rc f
  f="$ROOT/deploy/k8s/base/deployment.yaml"
  [ -f "$probe" ] || { WHY="no availability probe (${probe#$ROOT/})"; return 1; }
  grep -q '^  replicas: 2$' "$f" || { WHY="the base is not two replicas"; return 1; }
  grep -q '^    type: RollingUpdate$' "$f" && grep -q '^      maxUnavailable: 0$' "$f" || { WHY="the base does not roll with maxUnavailable 0"; return 1; }
  grep -q 'path: /readyz' "$f" || { WHY="the base's readiness is not /readyz"; return 1; }
  grep -q 'preStop:' "$f" || { WHY="the base has no preStop"; return 1; }
  grep -q 'minAvailable: 1' "$ROOT/deploy/k8s/base/pdb.yaml" 2>/dev/null || { WHY="the base has no PodDisruptionBudget"; return 1; }
  grep -q 'downtime_seconds' "$ROOT/.github/workflows/hub-deploy.yml" || { WHY="hub-deploy's summary has no downtime_seconds"; return 1; }
  grep -q 'overlays/kind/drill.sh' "$ROOT/.github/workflows/hub-rolling.yml" 2>/dev/null || { WHY="no kind drill in CI (hub-rolling.yml → drill.sh)"; return 1; }
  mkdir -p "$sc"
  cat > "$sc/hub.py" <<'PY2'
import os, signal, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
signal.alarm(int(sys.argv[2]))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self):
        up = open(sys.argv[3]).read().strip() == "up"
        self.send_response(200 if up else 503); self.send_header("Content-Length", "0"); self.end_headers()
    def do_GET(self): self.reply()
    def do_POST(self): self.reply()
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1] + ".tmp", "w").write(str(srv.server_address[1])); os.replace(sys.argv[1] + ".tmp", sys.argv[1])
srv.serve_forever()
PY2
  echo up > "$sc/mode"
  python3 "$sc/hub.py" "$sc/port" "$((CAP + 30))" "$sc/mode" 2>"$sc/hub.err" & hpid=$!
  for _ in $(seq 1 300); do [ -s "$sc/port" ] && break; sleep 0.1; done
  { read -r port < "$sc/port"; } 2>/dev/null
  [ -n "$port" ] || { kill "$hpid" 2>/dev/null; WHY="the fake hub did not start: $(tail -2 "$sc/hub.err" | tr '\n' ' ')"; return 1; }
  t0=$(now)
  # a Recreate release: up, ~3 s of 503, up again
  sh "$probe" "http://127.0.0.1:$port" "$sc/stop1" 30 > "$sc/p1.log" 2>&1 &
  sleep 2; echo down > "$sc/mode"; sleep 3; echo up > "$sc/mode"; sleep 2; touch "$sc/stop1"
  for _ in $(seq 1 50); do tail -1 "$sc/p1.log" | grep -q '^probes=' && break; sleep 0.1; done
  out=$(tail -1 "$sc/p1.log")
  case "$out" in "probes="*" downtime_seconds="[2-6]" write_unsupported=0") ;; *)
    kill "$hpid" 2>/dev/null; WHY="~3 s of 503 read as [$out], want downtime_seconds 2–6"; return 1 ;; esac
  down1=${out#*downtime_seconds=}; down1=${down1%% *}
  grep -q '^DOWN .* healthz=503 write=503' "$sc/p1.log" || { kill "$hpid" 2>/dev/null; WHY="the probe named no DOWN second"; return 1; }
  # a rolling release: up throughout
  sh "$probe" "http://127.0.0.1:$port" "$sc/stop2" 30 > "$sc/p2.log" 2>&1 &
  sleep 3; touch "$sc/stop2"
  for _ in $(seq 1 50); do tail -1 "$sc/p2.log" | grep -q '^probes=' && break; sleep 0.1; done
  kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
  out2=$(tail -1 "$sc/p2.log")
  case "$out2" in "probes="[1-9]*" downtime_seconds=0 write_unsupported=0") ;; *) WHY="a hub up throughout read as [$out2]"; return 1 ;; esac
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run '^(TestReadyzAndDeployProbe|TestReadyFollowsTheMigrations|TestShutdownGrace)$' ./internal/api ./internal/store ./cmd/ccquota 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT="停 ~3 秒的发布读出 downtime_seconds=${down1}；一直在的读 0；base 两份滚动 + /readyz + preStop + PDB；/readyz 与写探测、关停宽限 go test 绿；真两份 + Postgres 的三次发布 / 删 pod / 回退在 CI hub-rolling" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='探测读数对（停 ~3 秒 ≥2、一直在 0）；base 是滚动形态；入口的 Go 测试在这台没有模块缓存——Go 门跑它们' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='探测读数对（停 ~3 秒 ≥2、一直在 0）；base 是滚动形态；没有 go：Go 门跑 /readyz 测试'
  fi
  SECS=$(since "$t0")
}

# ---- hub-disk-attach-stuck (#2125): a release or a rebuilt pod stuck in
# ContainerCreating on the cloud disk's detach/attach (RUNBOOK, 2026-09-13).
# The rolling shape mounts no disk at all; the disk lives only in the single
# SQLite shape's component, which production dropped at the switch (#2215).
drill_hub_disk_attach_stuck() {
  CAP=30; local t0 b="$ROOT/deploy/k8s/base" c="$ROOT/deploy/k8s/components/sqlite-single" r
  t0=$(now)
  if grep -l 'persistentVolumeClaim\|kind: PersistentVolumeClaim' "$b"/*.yaml >/dev/null 2>&1; then
    WHY="the base still has a disk: $(grep -l 'persistentVolumeClaim\|kind: PersistentVolumeClaim' "$b"/*.yaml | tr '\n' ' ')"; return 1
  fi
  grep -q 'kind: PersistentVolumeClaim' "$c/pvc.yaml" 2>/dev/null || { WHY="the single SQLite shape lost its disk (${c#$ROOT/}/pvc.yaml)"; return 1; }
  if command -v kubectl >/dev/null 2>&1 && r=$(kubectl kustomize "$b" 2>/dev/null); then
    case "$r" in *PersistentVolumeClaim*|*claimName*) WHY="the base render mounts a disk"; return 1 ;; esac
    r=$(kubectl kustomize "$ROOT/deploy/k8s/overlays/prod" 2>/dev/null) || { WHY="the prod overlay does not render"; return 1; }
    case "$r" in *PersistentVolumeClaim*|*claimName*) WHY="prod still mounts a disk after the switch"; return 1 ;; esac
    WHAT='base 与生产的渲染都没有盘（库在 Postgres），盘只在单份形态的组件里（回滚用）'
  else
    WHAT='base 没有盘（按文件核对；没有 kubectl 不渲染），盘只在单份形态的组件里'
  fi
  SECS=$(since "$t0")
}

# A release that deletes what an OPEN session's start still names (a hook script,
# a mod tool's handler): the list must tell that session — red 会坏·需重开 — from
# one that merely lacks a new hook (yellow 配置旧, as before) and from one with no
# manifest at all (yellow too), name the broken one and the looping stale one with
# window · repo · issue · state, and reopen none of them (issue #2076, EPIC #2074 C3).
drill_oldcfg_broken_unmarked() {
  CAP=20; BREAK_SOCK="$WORK/sock-oc3"; local d="$WORK/oc3" t0 out rc st wb wl wn word
  mkdir -p "$d/conf/global" "$d/new/bin" "$d/new/hooks" "$d/new/mod/fleet/hooks" "$d/new/conf"
  # the new install: h.sh kept, new.sh added, the mod's `await` dropped from TOOL_RE
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/h.sh"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/new.sh"}]}]}}\n' > "$d/new/hooks/settings-hooks.json"
  : > "$d/new/bin/h.sh"; : > "$d/new/bin/new.sh"; : > "$d/new/bin/fleet-mcp.py"
  printf "export const FALLBACK = ['status', 'spawn'] as const\nexport const TOOL_RE = /^mcp__fleet__fleet_(status|spawn)\$/\n" > "$d/new/mod/fleet/hooks/tools.ts"
  printf '{"mcpServers":{"fleet":{"command":"bash","args":["-c","exec python3 $HOME/.claude/fleet/bin/fleet-mcp.py"]}}}\n' > "$d/new/conf/mcp-worker.json"
  # two old sessions' starts: one named gone.sh and the dropped tool, one only lacks new.sh
  printf '{"agent":"claude","fp":"OLD","hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/gone.sh"}]}]},"tools":["mcp__fleet__fleet_status","mcp__fleet__fleet_await"],"mcp":{}}\n' > "$d/m-broken.json"
  printf '{"agent":"claude","fp":"OLD","hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/h.sh"}]}]},"tools":["mcp__fleet__fleet_status","mcp__fleet__fleet_spawn"],"mcp":{}}\n' > "$d/m-stale.json"
  printf 'claude NEW x\nver v2\n' > "$d/conf/global/agent-cfg.expected"
  nt -f /dev/null new-session -d -s oc3 -n home -x 100 -y 30 'exec sleep 600' || { WHY="cannot start the isolated tmux server"; return 1; }
  ocw() {   # <name> <state> <manifest> → window id: a Claude session on the OLD fingerprint
    local id; id=$(nt new-window -d -t oc3: -n "$1" -P -F '#{window_id}' 'exec sleep 600')
    nt set-option -w -t "$id" @claude_state "$2"; nt set-option -w -t "$id" @agent_cfg OLD; nt set-option -w -t "$id" @agent_ver v2
    nt set-option -w -t "$id" @issue 7; nt set-option -w -t "$id" @repo acme/app
    [ -n "$3" ] && nt set-option -w -t "$id" @agent_cfg_manifest "$3"
    printf '%s' "$id"
  }
  wb=$(ocw w-broken 'done' "$d/m-broken.json"); wl=$(ocw w-loop looping "$d/m-stale.json"); wn=$(ocw w-old 'done' '')
  t0=$(now)
  out=$(PATH="$WORK/tbin:$PATH" BREAK_SOCK="$BREAK_SOCK" FLEET_CONF_DIR="$d/conf" bash "$BIN/fleet-oldcfg-check.sh" --sweep --list --new-dir "$d/new" -- oc3 2>&1); rc=$?
  SECS=$(since "$t0")
  [ "$rc" = 2 ] || { WHY="the sweep exited $rc, want 2 (something is broken): $(printf '%s' "$out" | tr '\n' '|')"; return 1; }
  case "$out" in *"broken	oc3	w-broken	acme/app	#7	done	"*) ;; *) WHY="the list does not name w-broken as broken with window · repo · issue · state: $(printf '%s' "$out" | tr '\n' '|')"; return 1 ;; esac
  case "$out" in *"looping	oc3	w-loop	acme/app	#7	looping	"*) ;; *) WHY="the list does not name the looping stale one: $(printf '%s' "$out" | tr '\n' '|')"; return 1 ;; esac
  case "$out" in *"stale	oc3	w-old	"*) ;; *) WHY="a window with no manifest is not listed stale (the degenerate): $(printf '%s' "$out" | tr '\n' '|')"; return 1 ;; esac
  case "$out" in *"broken	oc3	w-loop"*|*"broken	oc3	w-old"*) WHY="a session that only lacks a new hook, or has no manifest, is marked broken"; return 1 ;; esac
  [ "$(grep -c . "$d/conf/global/agent-cfg.broken")" = 1 ] || { WHY="agent-cfg.broken holds $(grep -c . "$d/conf/global/agent-cfg.broken" 2>/dev/null) row(s), want 1"; return 1; }
  for w in "$wb" "$wl" "$wn"; do
    [ "$(nt display-message -p -t "$w" '#{window_id}')" = "$w" ] || { WHY="window $w was closed — nothing here may reopen a session"; return 1; }
  done
  # the rows producer's judge (fleet_cfg_state) and the word the sidebar draws
  st=$(FLEET_CONF_DIR="$d/conf" bash -c '. "$1/fleet-lib.sh"; fleet_cfg_expected_load; fleet_cfg_broken_load
         for w in "$2" "$3" "$4"; do fleet_cfg_state claude OLD v2 oc3 "$w"; printf "%s " "$FCFG_STATE"; done' _ "$BIN" "$wb" "$wl" "$wn")
  [ "$st" = "broken stale stale " ] || { WHY="fleet_cfg_state says [$st], want [broken stale stale ]"; return 1; }
  word=$(FLEET_UI_LANG=zh bash -c '. "$1/fleet-ui-lang.sh"; fleet_ui_t sidebar_cfg_broken' _ "$BIN")
  [ "$word" = '会坏·需重开' ] || { WHY="the broken row's word is [$word], not 会坏·需重开"; return 1; }
  WHAT="删了 gone.sh / await 的发版后：w-broken 红「会坏·需重开」并点名（窗口·仓库·单号·状态），只缺 new.sh 的 w-loop 黄且列为循环中，没 manifest 的 w-old 照旧黄；三个都没被重开"
}

# A warm-pool entry started before an upgrade (its @agent_cfg / @agent_ver no longer
# the expected ones) must never be handed out — the node's claim says 3 and the
# caller opens a cold session — and the next pass retires it (issue #2233).
drill_pool_stale_handed_out() {
  CAP=10; BREAK_SOCK="$WORK/sock-psh"; local d="$WORK/psh" t0 out rc w acct kv
  mkdir -p "$d/conf/fleets/ps" "$d/conf/global" "$d/home"
  printf 'FLEET_REPO="acme/app"\nFLEET_MAIN="%s/nomain"\nFLEET_BASE_BRANCH="main"\nFLEET_SCRATCH_POOL=1\n' "$d" > "$d/conf/fleets/ps/conf"
  printf 'claude NEW x\nver v2\n' > "$d/conf/global/agent-cfg.expected"
  nt -f /dev/null new-session -d -s ps -n home -x 100 -y 30 'exec sleep 600' || { WHY="cannot start the isolated tmux server"; return 1; }
  nt new-session -d -s ps-pool -n warm-1 -x 100 -y 30 'exec sleep 600'
  w=$(nt list-windows -t ps-pool -F '#{window_id}' | head -1)
  acct=$(env HOME="$d/home" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 bash "$BIN/fleet-account.sh" active 2>/dev/null)
  for kv in "@pool 1" "@pool_ready 1" "@pool_slug scratch-1" "@pool_born $(date +%s)" "@pool_agent claude" \
            "@repo acme/app" "@worktree $d/wt" "@agent_cfg OLD" "@agent_ver v1"; do
    nt set-option -w -t "$w" ${kv%% *} "${kv#* }"
  done
  nt set-option -w -t "$w" @pool_account "$acct"
  pool() { env PATH="$WORK/tbin:$PATH" HOME="$d/home" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 \
             BREAK_SOCK="$BREAK_SOCK" FLEET_LOAD_PROBE_CMD='echo 0.10' FLEET_POOL_DISK_PROBE_CMD='echo 500' \
             FLEET_POOL_CLAIM_REFILL_DELAY=600 bash "$BIN/scratch-pool.sh" "$@"; }
  t0=$(now)
  out=$(pool claim ps --repo acme/app --agent claude 2>&1); rc=$?
  [ "$rc" = 3 ] && [ -z "$out" ] || { WHY="an entry warmed before the upgrade was handed out (rc=$rc, out=[$out])"; return 1; }
  [ "$(o "$w" session_name)" = ps-pool ] || { WHY="the old-config entry left the pool"; return 1; }
  pool reap ps --repo acme/app >/dev/null 2>&1
  nt list-windows -a -F '#{window_id}' | grep -qx "$w" && { WHY="the next pass did not retire the old-config entry"; return 1; }
  SECS=$(since "$t0"); WHAT="升级前开好的池里会话：领用返回 3、不交出，下一拍收掉（随后按新配置重开）"
}

# 发出即开 with nothing to hand out (issue #2234, EPIC #2230 C4): a ↵ while the
# repo × agent slot of the warm pool is empty (the pool off, just claimed, still
# warming) must open the task the old way — file it, spawn it, byte for byte what
# the start printed before the pool — and the warm attempt must leave nothing
# behind: no window, no worktree, no first turn typed anywhere.
drill_pool_empty_compose() {
  CAP=20; BREAK_SOCK="$WORK/sock-pec"; local d="$WORK/pec" t0 out rc wins f
  mkdir -p "$d/conf/fleets/pe" "$d/sb" "$d/log" "$d/home"
  git init -q -b master "$d/main" 2>/dev/null || git init -q "$d/main"
  ( cd "$d/main" && git config user.email t@t && git config user.name t && echo x > f && git add f && git commit -qm i ) \
    || { WHY="cannot build the repo"; return 1; }
  printf 'FLEET_REPO="acme/app"\nFLEET_MAIN="%s/main"\nFLEET_BASE_BRANCH="master"\nFLEET_SCRATCH_POOL=1\nFLEET_MAX_SESSIONS=20\n' "$d" \
    > "$d/conf/fleets/pe/conf"
  for f in "$BIN"/*; do ln -s "$f" "$d/sb/${f##*/}"; done
  rm -f "$d/sb/fleet-issue-file.sh" "$d/sb/dash-issue-session.sh"
  printf '#!/bin/sh\necho filed >> "%s/log/file"\necho https://github.com/acme/app/issues/9\n' "$d" > "$d/sb/fleet-issue-file.sh"
  printf '#!/bin/sh\necho "$*" >> "%s/log/spawn"\necho @999\n' "$d" > "$d/sb/dash-issue-session.sh"
  chmod +x "$d/sb/fleet-issue-file.sh" "$d/sb/dash-issue-session.sh"
  nt -f /dev/null new-session -d -s pe -n home -x 100 -y 30 'exec sleep 600' || { WHY="cannot start the isolated tmux server"; return 1; }
  run() { env -u TMUX -u TMUX_PANE -u CCQUOTA_FLEET PATH="$WORK/tbin:$PATH" HOME="$d/home" FLEET_CONF_DIR="$d/conf" \
            FLEET_SKIP_GLOBAL_CONF=1 FLEET_ADMIT=0 FLEET_ORIGIN_GATE=0 BREAK_SOCK="$BREAK_SOCK" "$@"; }
  t0=$(now)
  out=$(printf 'the text' | run bash "$d/sb/dash-raw-session.sh" pe --origin hub --print --warm-only --agent claude \
          --repo acme/app --prompt 'the text' 2>/dev/null); rc=$?
  [ "$rc" = 3 ] && [ -z "$out" ] || { WHY="--warm-only on an empty slot answered rc=$rc out=[$out], want exit 3 and nothing"; return 1; }
  out=$(printf 'the text' | run bash "$d/sb/fleet-control-read.sh" start pe new claude acme/app '' '' 'a title' 2>/dev/null); rc=$?
  SECS=$(since "$t0")
  [ "$rc" = 0 ] && [ "$out" = $'https://github.com/acme/app/issues/9\n@999' ] \
    || { WHY="the start on an empty slot was not the cold path (rc=$rc, out=[$out])"; return 1; }
  [ "$(grep -c . "$d/log/file")" = 1 ] && [ "$(grep -c . "$d/log/spawn")" = 1 ] || { WHY="filed / spawned not exactly once"; return 1; }
  wins=$(nt list-windows -t pe -F '#{window_name}' | tr '\n' ' ')
  [ "$wins" = 'home ' ] || { WHY="the warm attempt left a window behind: $wins"; return 1; }
  [ "$(git -C "$d/main" worktree list | grep -c .)" = 1 ] || { WHY="the warm attempt left a worktree behind"; return 1; }
  WHAT="池子空时发任务：--warm-only 答 3、什么都不开；start new 走冷路径（建单 + 开会话各一次），输出与开池前逐字节相同"
}

drill_cold_fill_fails() {
  # issue #2237: the cold start opens the agent's window before the tree is
  # checked out; a checkout that fails must take that window (and the worktree)
  # with it, and the spawn must say so — never a session on half a tree.
  CAP=10; local d="$WORK/cf" lbl="brkcf-$$" t0 rc
  mkdir -p "$d/o.git" "$d/main" "$d/conf" "$d/tmp" "$d/fb"
  git init -q --bare "$d/o.git"
  ( cd "$d/main" && git init -q -b master . && git config user.email t@t && git config user.name t \
      && printf 'x\n' > CLAUDE.md && git add -A && git commit -qm i && git remote add origin "$d/o.git" \
      && git push -q origin master ) || { WHY="cannot build the repo"; return 1; }
  printf '#!/bin/sh\nexit 0\n' > "$d/fb/gh"; printf '#!/bin/sh\nexec sleep 60\n' > "$d/fb/agent"; chmod +x "$d/fb/gh" "$d/fb/agent"
  env PATH="$d/fb:$PATH" FLEET_WRAP_LAUNCH="$d/fb/agent" "$REAL_TMUX" -L "$lbl" -f /dev/null new-session -d -s "$lbl" -n home \
    || { WHY="cannot start the isolated tmux server"; return 1; }
  t0=$(now)
  env -u TMUX -u TMUX_PANE -u CCQUOTA_FLEET PATH="$d/fb:$PATH" FLEET_CONF_DIR="$d/conf" TMPDIR="$d/tmp" \
    FLEET_ORIGIN_GATE=0 FLEET_PRESPAWN_DEDUP=0 FLEET_REPO=acme/w FLEET_MAIN="$d/main" FLEET_BASE_BRANCH=master \
    FLEET_WORKTREE_ROOT="$d/wt" FLEET_SPAWN_FILL_CMD='sleep 1; exit 1' \
    bash "$BIN/dash-issue-session.sh" 5 "$lbl" --title t --origin hub --print > "$d/out" 2> "$d/err"; rc=$?
  SECS=$(since "$t0")
  local wins; wins=$("$REAL_TMUX" -L "$lbl" list-windows -t "$lbl" -F '#{@issue}' 2>/dev/null)
  "$REAL_TMUX" -L "$lbl" kill-server >/dev/null 2>&1
  [ "$rc" = 1 ] || { WHY="the spawn exited $rc, want 1"; return 1; }
  grep -q 'worktree checkout' "$d/err" || { WHY="the spawn did not say the checkout failed: $(tr '\n' '|' < "$d/err")"; return 1; }
  case " $(printf '%s ' $wins)" in *" 5 "*) WHY="the window of the failed checkout is still open"; return 1 ;; esac
  [ -z "$(ls -d "$d"/wt/*issue-5 2>/dev/null)" ] || { WHY="the half worktree is still there"; return 1; }
  WHAT="检出失败：会话窗口和半截 worktree 都收走，派发方得到 exit 1「worktree checkout」"
}

# brew-keg-700 (issue #2283): brew pours with the caller's umask, so an owner on
# 077 leaves kegs (and opt links) only it can read — every other login on the
# machine loses python ssl / tmux. The diskguard tick's brew pass repairs them to
# go+rX, as the prefix's owner, on a machine with 2+ logins; one login, or not
# the owner ⇒ nothing changes (the doctor names the owner). etc/*/private stays
# private. Another uid reads the repaired file when sudo -n can show it.
drill_brew_keg_700() {
  CAP=5; local d p t0 out x
  d="$(mktemp -d /tmp/brk-brew.XXXXXX)" || { WHY="no tmp dir"; return 1; }
  chmod 755 "$d"; p="$d/brew"
  mkdir -p "$p/Cellar/ok/1/bin" "$p/opt" "$p/etc/x"; chmod -R 755 "$p"
  ( umask 077
    mkdir -p "$p/Cellar/tmux/3.7c/lib" "$p/etc/x/private"
    printf 'x\n' > "$p/Cellar/tmux/3.7c/lib/libjemalloc.2.dylib"
    ln -s ../Cellar/tmux/3.7c "$p/opt/tmux" )
  bw() { env FLEET_BREW_PREFIX="$p" FLEET_BREW_PERMS_EVERY=0 FLEET_CONF_DIR="$d/conf" "$@" \
         bash "$BIN/fleet-diskguard.sh" --brew-watch >/dev/null 2>&1; }
  mode() { ls -ld "$1" | cut -c1-10; }
  bw FLEET_BREW_LOGINS=1
  [ "$(mode "$p/Cellar/tmux/3.7c")" = drwx------ ] || { WHY="one login: the keg was changed ($(mode "$p/Cellar/tmux/3.7c"))"; rm -rf "$d"; return 1; }
  bw FLEET_BREW_LOGINS=2 FLEET_BREW_ME=someone-else
  [ "$(mode "$p/Cellar/tmux/3.7c")" = drwx------ ] || { WHY="not the owner: the keg was changed"; rm -rf "$d"; return 1; }
  out="$(FLEET_BREW_PREFIX="$p" FLEET_BREW_LOGINS=2 FLEET_BREW_ME=someone-else bash "$BIN/fleet-brew-perms.sh" --doctor)"
  case "$out" in warn*"owned by $(id -un)"*"chmod -R go+rX"*) ;; *) WHY="non-owner doctor line: [$out]"; rm -rf "$d"; return 1 ;; esac
  t0=$(now)
  bw FLEET_BREW_LOGINS=2
  SECS=$(since "$t0")
  for x in "$p/Cellar/tmux" "$p/Cellar/tmux/3.7c" "$p/Cellar/tmux/3.7c/lib"; do
    [ "$(mode "$x")" = drwxr-xr-x ] || { WHY="$x is $(mode "$x") after the tick"; rm -rf "$d"; return 1; }
  done
  [ "$(mode "$p/Cellar/tmux/3.7c/lib/libjemalloc.2.dylib")" = -rw-r--r-- ] || { WHY="the dylib is $(mode "$p/Cellar/tmux/3.7c/lib/libjemalloc.2.dylib")"; rm -rf "$d"; return 1; }
  [ "$(uname -s)" = Darwin ] && { [ "$(mode "$p/opt/tmux")" = lrwxr-xr-x ] || { WHY="opt/tmux is $(mode "$p/opt/tmux")"; rm -rf "$d"; return 1; }; }
  [ "$(mode "$p/etc/x/private")" = drwx------ ] || { WHY="etc/x/private was opened"; rm -rf "$d"; return 1; }
  [ -z "$(FLEET_BREW_PREFIX="$p" bash "$BIN/fleet-brew-perms.sh" --scan)" ] || { WHY="--scan still lists paths"; rm -rf "$d"; return 1; }
  grep -q "keg $p/Cellar/tmux/3.7c fixed" "$d/conf/diskguard/brew-perms.log" 2>/dev/null || { WHY="no log line for the keg"; rm -rf "$d"; return 1; }
  if sudo -n -u nobody true 2>/dev/null; then
    sudo -n -u nobody cat "$p/opt/tmux/lib/libjemalloc.2.dylib" >/dev/null 2>&1 || { WHY="nobody still cannot read the dylib"; rm -rf "$d"; return 1; }
    WHAT="一个登录 / 不是属主都不动；属主那一拍把 700 的 keg、opt 链接改回 go+rX，另一个 uid（nobody）读得到，etc/*/private 不碰"
  else
    WHAT="一个登录 / 不是属主都不动；属主那一拍把 700 的 keg、opt 链接改回 go+rX（无 sudo，按权限位判），etc/*/private 不碰"
  fi
  rm -rf "$d"
}

# ---- invite-expired (#2261, EPIC #2259 C2): a newcomer signs in with an invite
# that cannot be used — expired, used, revoked, someone else's, never minted. The
# whole change is the hub's, so the drill is its Go tests, run for real where a
# toolchain is: each bad code is refused with its own reason and puts nobody on
# the list; a good one lets the person in once and audits 「邀请已使用」; no code
# is the list as before, saying the line to send an admin; the waiting
# `fleet login` hears the refusal instead of waiting ten minutes. Without go the
# tests must at least exist by name.
drill_invite_expired() {
  CAP=120; local t0 out rc tests f
  tests='TestInviteRefusals TestInviteLetsANewcomerIn TestInviteNoCodeIsTheListAsBefore TestInviteRefusalReachesTheTerminal TestInviteOpensTheLoginWithAutoAssignOff'
  f="$ROOT/tokenledger/internal/api/fleet_invites_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'denyInvitePrefix + reason' "$ROOT/tokenledger/internal/api/fleet_invites.go" \
    || { WHY="admitInvite no longer refuses a bad invite with its reason"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='过期 / 已用 / 撤销 / 别人的 / 没发过的码各被拒且说清原因、名单不变；好码进名单一次、审计「邀请已使用」；终端立刻听到拒绝（go test 五条）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；六条测试按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：六条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

drill_pretrust_norepo() {
  # issue #2282: on a trusted node a fleet-opened @norepo session in $HOME must
  # not park on Claude Code's "trust this folder?" dialog; on an untrusted node the
  # same launch leaves ~/.claude.json byte for byte. The fake claude does what
  # Claude Code does: an exact-key lookup of its cwd in ~/.claude.json.
  CAP=10; local d="$WORK/ptn" sock="$WORK/sock-ptn" t0 w go verdict
  mkdir -p "$d/home" "$d/conf/fleets/ptn" "$d/conf/cred-proxy" "$d/fb"
  printf 'FLEET_SESSION=ptn\n' > "$d/conf/fleets/ptn/conf"
  printf '{"numStartups": 7, "projects": {"/elsewhere": {"hasTrustDialogAccepted": true}}}\n' > "$d/home/.claude.json"
  cp "$d/home/.claude.json" "$d/before.json"
  cat > "$d/fb/claude" <<'FAKE'
#!/bin/sh
python3 -c 'import json, os, sys
d = json.load(open(os.path.join(os.environ["HOME"], ".claude.json")))
ok = d.get("projects", {}).get(os.getcwd(), {}).get("hasTrustDialogAccepted") is True
open(sys.argv[1], "w").write("no-dialog" if ok else "dialog")' "$PTN_OUT"
FAKE
  chmod +x "$d/fb/claude"
  "$REAL_TMUX" -S "$sock" -f /dev/null new-session -d -s ptn -n home || { WHY="cannot start the isolated tmux server"; return 1; }
  ptn_launch() { # <word in trust.json> → the fake claude's verdict in $d/out.<word>
    printf '{"trust": "%s", "why": "hub: %s", "ts": %s}\n' "$1" "$1" "$(date +%s)" > "$d/conf/cred-proxy/trust.json"
    go="$d/go.$1"
    w=$("$REAL_TMUX" -S "$sock" new-window -d -P -F '#{window_id}' -t ptn -c "$d/home" \
        "while [ ! -f '$go' ]; do sleep 0.05; done; exec env -i HOME='$d/home' PATH='$d/fb:/usr/bin:/bin:$(dirname "$REAL_TMUX")' TMUX=\"\$TMUX\" TMUX_PANE=\"\$TMUX_PANE\" FLEET_CONF_DIR='$d/conf' FLEET_MOD=0 FLEET_AGENT_CFG=0 FLEET_CLAUDE_BIN='$d/fb/claude' PTN_OUT='$d/out.$1' bash '$BIN/fleet-claude.sh' >'$go.log' 2>&1")
    "$REAL_TMUX" -S "$sock" set-option -w -t "$w" @norepo 1
    : > "$go"
    until_ok 8 test -s "$d/out.$1"
  }
  ptn_launch untrusted || { WHY="the untrusted launch never reached claude: $(cat "$d/go.untrusted.log" 2>/dev/null)"; return 1; }
  cmp -s "$d/home/.claude.json" "$d/before.json" || { WHY="untrusted node: ~/.claude.json changed: $(cat "$d/home/.claude.json")"; return 1; }
  [ "$(cat "$d/out.untrusted")" = dialog ] || { WHY="untrusted node: the folder was trusted anyway"; return 1; }
  t0=$(now)
  ptn_launch trusted || { WHY="the trusted launch never reached claude: $(cat "$d/go.trusted.log" 2>/dev/null)"; return 1; }
  SECS=$(since "$t0")
  verdict=$(cat "$d/out.trusted")
  "$REAL_TMUX" -S "$sock" kill-server >/dev/null 2>&1
  [ "$verdict" = no-dialog ] || { WHY="trusted node: the @norepo session in \$HOME still meets the trust dialog: $(cat "$d/go.trusted.log")"; return 1; }
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("numStartups") == 7 and "/elsewhere" in d["projects"] and len(d["projects"]) == 2 else 1)' "$d/home/.claude.json" \
    || { WHY="trusted node: wrote more than \$HOME, or lost a key: $(cat "$d/home/.claude.json")"; return 1; }
  WHAT="可信节点上 @norepo 会话开在 \$HOME 不再停在信任框（只多写 \$HOME 一项）；不可信节点同样开，~/.claude.json 一字不差"
}

# ---- spare-login-empty (#2263, EPIC #2259 C4): a newcomer signs in while no
# spare login is ready (all taken, still being made, or one failed). Only an
# active spare is ever handed over; otherwise the person's own login is opened
# as before and every door says 「正在开」 with its ETA; the taken one is
# refilled, a spare not credential-separated is never handed out, and a
# failed spare is not retried on every beat.
drill_spare_login_empty() {
  CAP=120; local t0 out rc tests f
  tests='TestSpareEmptyFallsBackToOpening TestSpareHandedToANewcomerAndRefilled TestSpareUnseparatedIsNeverHandedOut TestSpareCountFollowsTheMachinesRoom TestSpareIsInNoPeopleView TestSpareOffAddsNothing'
  f="$ROOT/tokenledger/internal/api/fleet_spare_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'state = ? AND op = .create.' "$ROOT/tokenledger/internal/store/fleet_spare.go" \
    || { WHY="ClaimSpare no longer takes only a ready (active) spare"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='没有现成备用时照旧现开、入口说「正在开」带 ETA；有隔离好的备用时 3 秒内拿到、用掉即补；没隔离的不发不补；按上限−已用备足、多了就缩；备用不进人员视图；关着时一字不变（go test 六条）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；六条测试按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：六条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- lease-unseparated-user (#2295, EPIC #2293 C2): a user's login whose
# credential separation did not happen (or an agent too old to say) must not be
# leased a real token — the hub refuses 「拒发：未隔离」 and tells the node's
# proxy to route every session central, so they still work. Admin / operator
# logins lease as before.
drill_lease_unseparated_user() {
  CAP=120; local t0 out rc api agent fa fg
  api='TestLeaseCredsepGate TestLeaseCredsepGateOnlyForUsers TestNodeSelfCarriesCredsepGate'
  agent='TestCredsepJudge TestCredsepProbeCaches'
  fa="$ROOT/tokenledger/internal/api/fleet_credsep_test.go"
  fg="$ROOT/tokenledger/internal/agent/node_credsep_test.go"
  t0=$(now)
  for out in $api; do
    grep -q "^func $out(" "$fa" 2>/dev/null || { WHY="the hub half's test $out is not in ${fa#$ROOT/}"; return 1; }
  done
  for out in $agent; do
    grep -q "^func $out(" "$fg" 2>/dev/null || { WHY="the node half's test $out is not in ${fg#$ROOT/}"; return 1; }
  done
  grep -q 'credsep_gate' "$BIN/fleet-cred-proxy.py" \
    || { WHY="fleet-cred-proxy.py no longer routes a credsep-gated login central"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s %s' "$api" "$agent" | tr ' ' '|'))\$" ./internal/api ./internal/agent 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='普通用户未隔离 / 不报字段 → 403「拒发：未隔离」、/self 带 credsep_gate（代理走 central）；隔离后 200；管理员与非 GitHub 用户不受影响；节点按 status+check 判定并 5 分钟缓存（go test 五条）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；五条测试按名核对在' ;;
      *) WHY="the Go half is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：五条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- home-pool-claim-unkeyed (#2339): `fleet claude` opens a HOME session — a
# no-repo window, claimed from the pool's HOME slot or opened cold — that has no
# @raw and so no key. The start's result check looked for the receipt's window
# among `scratch` rows only: UNKNOWN every time, the client said 开不了, and the
# window stayed open with nobody holding it. Now the receipt's @fleet_id is
# matched first (identity before key, #1646) and the result names window_id; a
# start whose window still matches nothing is closed by `stop fid:<id>`.
drill_home_pool_claim_unkeyed() {
  CAP=10; local t0 out
  t0=$(now)
  out=$(python3 - "$BIN" <<'PY' 2>&1
import json, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import fleet_control as fc
FID = "c63813a3-3f3f-4cea-bec6-c12705d98fc3"
def run(rows):
    tmp = tempfile.mkdtemp()
    c = fc.Control.__new__(fc.Control)
    class Store:
        root = __import__("pathlib").Path(tmp)
        def connect(self):
            import sqlite3
            db = sqlite3.connect(os.path.join(tmp, "s.db")); db.row_factory = sqlite3.Row
            return db
    c.store = Store()
    with c.store.connect() as db:
        db.execute("CREATE TABLE operations (id TEXT, action TEXT, request TEXT, status TEXT, result TEXT, created REAL, updated REAL)")
        req = {"fleet_id": "f", "action": "worker_start", "params": {"kind": "scratch", "no_repo": True, "agent": "claude"}}
        db.execute("INSERT INTO operations VALUES ('0f0e0d0c-0b0a-4908-8706-050403020100','worker_start',?,'accepted','',?,?)", (json.dumps(req), fc.now() - 0.2, fc.now()))
    c.fleet = lambda fid: {"name": "s", "fleet_id": "f"}
    stops = []
    def adapter(*a, **k):
        if a[0] == "stop":
            stops.append(a[2])
        if a[0] == "start":
            return 0, ("@694\tnorepo\t/home\t%s\t1000\t\t\n" % FID).encode(), b""
        return 0, b"", b""
    c.adapter = adapter
    c.workers = lambda fl, w="": {"observed_at": 1, "workers": rows}
    c.watch_ready = lambda *a: None
    c.execute("0f0e0d0c-0b0a-4908-8706-050403020100")
    with c.store.connect() as db:
        row = db.execute("SELECT status, result FROM operations").fetchone()
    return row["status"], json.loads(row["result"]), stops
row = {"window_id": "@694", "scratch": False, "issue": None, "key": None, "repo": None, "identity": FID}
st, r, stops = run([row])
if st != "succeeded" or r.get("window_id") != "@694":
    sys.exit("the HOME window was not recognised: %s %s" % (st, json.dumps(r)))
st, r, stops = run([])
if st != "unknown" or stops != ["fid:" + FID]:
    sys.exit("an unmatched HOME window was left open: %s stops=%s" % (st, stops))
PY
) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='从池领（或冷开）的 HOME 会话没有 key：按回执的 @fleet_id 认出、结果带 window_id；仍认不出就 stop fid: 关掉，不留孤儿'
}

# new-login-unseparated (issue #2294, EPIC #2293 C1): a login opened the old way
# had the team pool copied into its own accounts/ and FLEET_CRED_SEPARATE=0 —
# its first session could read every subscription token. Now fleet-login-new.sh
# plans step 7b (credsep install --fresh) before the login's services and its
# first session, and the pool lands in the store: the login holds markers only.
drill_new_login_unseparated() {
  CAP=20
  local d="$WORK/newlogin" t0 out rc C R st
  mkdir -p "$d/pool" "$d/homes" "$d/homes2" "$d/db" "$d/run" "$d/daemons" "$d/inst"
  printf 'tok-POOL-1\n' > "$d/pool/p1"; printf 'CCQUOTA_ACCOUNT=p1\n' > "$d/pool/p1.conf"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBRK brk@t\n' > "$d/key.pub"
  printf 'brkfresh:%s:%s:%s\n' "$(id -u)" "$(id -g)" "$d/homes/brkfresh" > "$d/pw"
  t0=$(now)
  # 1. the plan the hub's account op runs (its fixed argv: --share-pool)
  out=$(FLEET_LOGIN_HOMES="$d/homes2" bash "$BIN/fleet-login-new.sh" brkfresh --full-name B --pubkey "$d/key.pub" \
        --share-pool --pool-src "$d/pool" 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="the dry run failed (rc $rc): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 1; }
  # case, not `printf | grep -q`: under pipefail a grep that quits early can SIGPIPE the printf
  case "$out" in *"fleet-credsep.sh install --login brkfresh --fresh"*) ;;
    *) WHY="the plan opens the login with no credsep step: the pool lands where its sessions read it"; return 1 ;; esac
  case "$out" in *"sudo cp -p $d/pool/p1"*) WHY="the plan still copies the pool into the login's own dir"; return 1 ;; esac
  case "$out" in *"background services as system"*"--fresh"*) WHY="the services start before the credentials are separated (先代理、后搬凭据、再开会话)"; return 1 ;; esac
  # 2. the separation itself (root's half, sandboxed): nothing for a session to read
  C="$d/homes/brkfresh/.config/claude-fleet" R="$d/db/brkfresh"
  mkdir -p "$C"
  out=$(FLEET_CREDSEP_ROOT_BASE="$d/db" FLEET_CREDSEP_RUN_BASE="$d/run" FLEET_CREDSEP_LOG_BASE="$d/log" \
        FLEET_CREDSEP_LIB="$d/lib" FLEET_CREDSEP_DAEMON_DIR="$d/daemons" FLEET_CREDSEP_ROLE="$(id -un)" \
        FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_PREFLIGHT=0 FLEET_CREDSEP_SUDO='' FLEET_CREDSEP_PW="$d/pw" \
        bash "$BIN/fleet-credsep.sh" install --login brkfresh --fresh --pool-src "$d/pool" --install-dir "$d/inst" 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="install --fresh failed (rc $rc): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 1; }
  grep -rq 'tok-POOL' "$d/homes/brkfresh" && { WHY="a pool token is readable in the new login's home: $(grep -rl tok-POOL "$d/homes/brkfresh")"; return 1; }
  [ -z "$(find "$d/homes/brkfresh" \( -name .credentials.json -o -name auth.json -o -name node.env \) -print)" ] \
    || { WHY="a credential file in the new login's home"; return 1; }
  [ "$(cat "$R/accounts/p1" 2>/dev/null)" = tok-POOL-1 ] && [ "$(cat "$C/accounts/p1")" = store:p1 ] \
    || { WHY="the pool is not in the store / the login has no marker: $(ls -a "$R/accounts" "$C/accounts" 2>&1 | tr '\n' ' ')"; return 1; }
  st=$(FLEET_CONF_DIR="$C" bash "$BIN/fleet-credsep.sh" status 2>&1)
  SECS=$(since "$t0")
  case "$st" in separated*) ;; *) WHY="status after the open: $st"; return 1 ;; esac
  WHAT="新账号开号：计划里第 7b 步 credsep install --fresh 排在服务和第一个会话之前；订阅池只进 store（账号里只有 store:<label> 标记），status=separated"
}

# ---- trust-name-borrowed (#2214, EPIC #2329 C2): an untrusted node reports a
# trusted machine's hostname. Trust rides the endpoint (the join code, the
# operator), the old name rule holds only for the endpoint that enrolled under
# that name, so the impostor's lease and relay credential are refused and its
# hello is audited; a managed join code trusts the identity, once, for an hour.
drill_trust_name_borrowed() {
  CAP=120; local t0 out rc tests f
  tests='TestTrustBorrowedNameGetsNothing TestTrustOldNodeKeepsItsName TestManagedJoinCodeTrustsTheIdentity TestDesiredStateOperatorWrites TestDesiredAbsentAddsNothing'
  f="$ROOT/tokenledger/internal/api/fleet_node_identity_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'sameName(et.EnrolledHost, host)' "$ROOT/tokenledger/internal/api/fleet_trust.go" \
    || { WHY="nodeTrust no longer holds the name rule to the name the endpoint enrolled under"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='冒名节点领凭据 / 中继凭据被拒、名册读 name_borrowed、hello 记审计；真机照领；托管加入码一次、一小时、信任记在身份上；期望状态只有操作者能写（go test 五条）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；五条测试按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：五条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- release-tampered (#2335, EPIC #2329 C7): a machine takes a release from
# the hub only, and a tampered byte anywhere — a tree file, an artifact, the
# manifest, the signature, a different key — installs nothing; GitHub out of
# reach (and a restarted hub) still hands out what it stored. The hub half is
# Go; this drill pins its tests by name and runs them when go is here.
drill_release_tampered() {
  CAP=120; local t0 out rc tests f
  tests='TestReleaseBuiltOnStableAndFetched TestReleaseFetchWithGitHubDown TestReleaseTamperRefused TestReleaseVerifyDirCatchesEdit TestReleaseOffIs404'
  f="$ROOT/tokenledger/internal/api/fleet_release_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'digest does not match the manifest' "$ROOT/tokenledger/internal/release/release.go" \
    || { WHY="Unpack no longer checks each file against the signed manifest"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='stable 一动入口就打包签名；机器从入口取到全部文件与二进制；GitHub 断了、入口重启也照样取；树 / 二进制 / 清单 / 签名 / 钥匙任一处被改都整个不换、不留半成品（go test 五条）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；五条测试按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：五条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
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
