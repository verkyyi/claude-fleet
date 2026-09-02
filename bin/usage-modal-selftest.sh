#!/bin/bash
# usage-modal-selftest.sh — hermetic unit test for the pure window-SELECTION
# predicate in bin/usage-modal.sh (issue #263; renamed from account-pick in the
# #289 usage/account consolidation). When the usage+account modal switches the
# active subscription account it also restarts this fleet's IDLE Claude
# windows so running sessions move onto the new account. WHICH windows get
# restarted is the one decision worth pinning: restart the wrong window and you
# interrupt a mid-turn worker or resume the wrong transcript; miss the right one
# and the session silently stays on the walled account.
#
# _ap_restart_eligible <name> <state> <raw> returns 0 iff a window is an idle,
# issue-bound Claude worker safe to restart in place:
#   • hub/backlog panels (dash/plan/backlog) are skipped by name — this also
#     leaves the operator hub alone (it lives in the `plan` window);
#   • @raw scratch sessions are skipped (shared FLEET_MAIN cwd → `--continue`
#     can't resolve their transcript, issue #214);
#   • non-Claude windows (no @claude_state) are skipped;
#   • only the idle states done/needs restart — working (mid-turn) and looping
#     (between /loop iterations) are left on their current account.
#
# Sourced (not run): usage-modal.sh guards its interactive body with
# `[ "${BASH_SOURCE[0]}" = "$0" ]`, so sourcing defines the helpers WITHOUT
# opening fzf or touching account state — hermetic, no tmux, no network.
#
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$BIN/usage-modal.sh"
[ -f "$SCRIPT" ] || { printf 'selftest: %s not found\n' "$SCRIPT" >&2; exit 2; }

# shellcheck source=/dev/null
. "$SCRIPT"

command -v _ap_restart_eligible >/dev/null 2>&1 \
  || { printf 'selftest: _ap_restart_eligible not defined after sourcing\n' >&2; exit 1; }

CHECKS=0
fail() { printf 'usage-modal selftest FAIL: %s\n' "$1" >&2; exit 1; }

# elig <desc> <name> <state> <raw> — assert the window IS eligible (rc 0).
elig() {
  CHECKS=$((CHECKS + 1))
  if ! _ap_restart_eligible "$2" "$3" "$4"; then
    fail "$1 — expected eligible (name=$2 state=$3 raw=$4), got skipped"
  fi
}
# skip <desc> <name> <state> <raw> — assert the window is SKIPPED (rc non-zero).
skip() {
  CHECKS=$((CHECKS + 1))
  if _ap_restart_eligible "$2" "$3" "$4"; then
    fail "$1 — expected skipped (name=$2 state=$3 raw=$4), got eligible"
  fi
}

# --- Eligible: idle, issue-bound worker windows (any non-panel name) ---
elig "done worker"            issue-263 "done"  ""
elig "needs worker"           issue-9   "needs" ""
elig "scratch-named but state-bound worker" fix-thing "done" ""

# --- Skipped by state: not idle ---
skip "working is mid-turn"    issue-263 "working" ""
skip "looping is /loop"       issue-263 "looping" ""
skip "empty state (non-Claude window)" issue-263 "" ""
skip "unknown state"          issue-263 "zombie"  ""

# --- Skipped by panel name (the hub/backlog; the operator pane lives in `plan`) ---
skip "dash panel"             dash    "done"  ""
skip "plan hub (operator)"    plan    "done"  ""
skip "backlog panel"          backlog "needs" ""

# --- Skipped: @raw scratch session (shared cwd, unresolvable transcript) ---
skip "raw scratch, done"      scratch   "done"  1
skip "raw scratch, needs"     scratch-2 "needs" 1
# raw flag empty/absent means NOT raw → a normal idle worker stays eligible.
elig "raw flag empty = normal worker" issue-1 "done" ""

# --- A panel that is somehow @raw is still skipped (name wins first) ---
skip "raw + panel name"       plan "done" 1

# --- issue #304: the account switch must BACKGROUND the idle-window restarts so the
# popup returns instantly (the ctrl-c + up-to-3s settle loop scales with # idle
# windows). Static wiring check: a run-shell -b dispatch to the --restart-idle bg
# subcommand, which must also exist as a handler. ---
CHECKS=$((CHECKS + 1))
grep -Eq 'run-shell -b .*--restart-idle' "$SCRIPT" \
  || fail "the account switch must dispatch restart_idle_claude_windows via run-shell -b (--restart-idle)"
CHECKS=$((CHECKS + 1))
grep -Eq '= "--restart-idle"' "$SCRIPT" \
  || fail "usage-modal must expose the --restart-idle background subcommand"

# --- issue #495: auto-rotation must be able to move RUNNING sessions too. ---
# The collector dispatches --restart-after-rotate on a mark-limited rotation
# (exit 10); the mode must exist here, and the collector must actually wire it.
CHECKS=$((CHECKS + 1))
grep -Eq '= "--restart-after-rotate"' "$SCRIPT" \
  || fail "usage-modal must expose the --restart-after-rotate subcommand (issue #495)"
CHECKS=$((CHECKS + 1))
grep -Eq 'run-shell -b .*--restart-after-rotate' "$BIN/tmux-dash-collect.sh" \
  || fail "the collector must dispatch --restart-after-rotate via run-shell -b on a rotation (issue #495)"

# The per-window restart must clear-history BEFORE relaunching: the relaunch
# re-stamps @cc_account to the NEW label while scrollback may still hold the
# limit banner that benched the OLD one — leave it and the collector attributes
# the stale banner to the fresh account and benches that too (a false cascade).
CHECKS=$((CHECKS + 1))
command -v _ap_restart_window >/dev/null 2>&1 \
  || fail "_ap_restart_window not defined after sourcing (issue #495 refactor)"
CHECKS=$((CHECKS + 1))
grep -Eq 'clear-history' "$SCRIPT" \
  || fail "_ap_restart_window must clear-history before relaunching (stale-banner cascade guard, issue #495)"

# restart_idle_claude_windows must take the skip args the rotate pass relies on
# (skip the just-restarted banner window; skip windows already on the new label).
CHECKS=$((CHECKS + 1))
grep -Eq 'skip_wid' "$SCRIPT" && grep -Eq 'skip_acct' "$SCRIPT" \
  || fail "restart_idle_claude_windows must support skip_wid/skip_acct (issue #495)"

# --- _ap_restart_window must NEVER type into a live Claude (issue #511) ----------
# The relaunch line is typed into the pane, so it is only safe once Claude has
# actually exited. The old gate read `pane_current_command` — which on macOS is the
# `zsh -c` runner (`zsh`) for the whole life of the session, so it passed at once;
# when the two ctrl-c did not exit Claude (the "Usage limit reached · continuing
# automatically" wait swallows them) the relaunch landed in the prompt as an LLM
# turn. The gate has to be the PROCESS TREE: no `claude` descendant of pane_pid.
# Pinned against a real tmux on an isolated socket, with:
#   • a fake `claude` = a renamed sleep (comm is `claude`, like the real binary),
#   • a runner that ignores SIGINT (inherited across exec → the fake ignores ctrl-c),
#   • a fake login shell that RECORDS typed lines instead of executing them.
REAL_TMUX="$(command -v tmux 2>/dev/null)"
if [ -n "$REAL_TMUX" ]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/um-restart.XXXXXX")" || fail "mktemp"
  SOCK="$WORK/tmux.sock"; mkdir -p "$WORK/fakebin"
  cat > "$WORK/fakebin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
  # A process whose command name is `claude`: a SYMLINK to perl (comm follows the
  # invoked path on macOS and Linux alike — a shebang script would report its
  # interpreter, and a COPY of a system binary is refused by macOS). perl lets each
  # case pick its SIGINT behaviour, which is the whole point of the rig.
  ln -s "$(command -v perl)" "$WORK/fakebin/claude"
  # the "login shell" the runner execs after claude exits: records every typed
  # line instead of executing it. Ignores SIGINT like an interactive zsh would —
  # the SECOND ctrl-c of the pair lands here once claude is already gone.
  cat > "$WORK/fakebin/fakeshell" <<EOF
#!/bin/sh
trap '' INT
while IFS= read -r l; do printf '%s\n' "\$l" >> "$WORK/typed"; done
EOF
  # ignores ctrl-c: SIG_IGN survives exec, so the fake claude never dies on INT
  cat > "$WORK/fakebin/runner-stuck" <<EOF
#!/bin/sh
trap '' INT
"$WORK/fakebin/claude" -e 'sleep 30'
exec "$WORK/fakebin/fakeshell"
EOF
  # CATCHES ctrl-c and exits normally on the SECOND one (exactly what the real TUI
  # does — both ^C are consumed by claude, none reaches the shell that follows),
  # then drops to the (fake) login shell — the happy path. A child that DIED of
  # SIGINT would take a non-interactive sh down with it (cooperative exit) and
  # close the window; `set -m` additionally keeps the runner out of the tty's
  # foreground pgrp so the SIGINT never reaches it at all.
  cat > "$WORK/fakebin/runner-exits" <<EOF
#!/bin/sh
set -m
"$WORK/fakebin/claude" -e '\$n = 0; \$SIG{INT} = sub { exit 0 if \$n++ }; sleep 30 while 1'
exec "$WORK/fakebin/fakeshell"
EOF
  chmod +x "$WORK/fakebin"/*
  export PATH="$WORK/fakebin:$PATH"
  um_cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
  trap um_cleanup EXIT
  trap 'exit 130' INT TERM HUP

  # 1. Claude survives ctrl-c → must NOT type, must return non-zero.
  tmux new-session -d -s t -n stuck "$WORK/fakebin/runner-stuck" || fail "isolated server"
  wid=$(tmux display-message -p -t t:stuck '#{window_id}')
  sleep 0.5
  CHECKS=$((CHECKS + 1))
  if _ap_restart_window "$wid" "nudge"; then
    fail "_ap_restart_window returned 0 while the fake claude was still running"
  fi
  CHECKS=$((CHECKS + 1))
  pgrep -f "$WORK/fakebin/claude" >/dev/null || fail "test rig: the fake claude should have survived ctrl-c"
  CHECKS=$((CHECKS + 1))
  if tmux capture-pane -p -t "$wid" | grep -q 'fleet-claude.sh'; then
    fail "the relaunch line was typed into a pane whose claude was still alive"
  fi
  [ ! -f "$WORK/typed" ] || fail "the relaunch line reached the shell of a still-live claude"

  # 2. Claude exits on ctrl-c → the relaunch IS typed (into the fake shell), rc 0.
  tmux new-window -d -t t: -n exits "$WORK/fakebin/runner-exits" || fail "new-window"
  wid2=$(tmux display-message -p -t t:exits '#{window_id}')
  sleep 0.5
  # on failure, show the rig: is the window still there, what runs under it, screen
  um_diag() {
    printf 'wid=%s exists=%s cmd=%s\n' "$1" \
      "$(tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null || echo NO)" \
      "$(tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)"
    pp=$(tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null)
    [ -n "$pp" ] && ps -axo pid=,ppid=,comm= | awk -v r="$pp" 'BEGIN{keep[r]=1} {if($2 in keep){keep[$1]=1} if($1 in keep) print "  "$0}'
    printf 'screen: %s\n' "$(tmux capture-pane -p -t "$1" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -2 | tr '\n' '|')"
    printf 'typed: %s\n' "$(cat "$WORK/typed" 2>/dev/null)"
    printf 'server: %s\n' "$(tmux list-panes -a -F '#{session_name}:#{window_id}/#{pane_id} #{window_name} dead=#{pane_dead} pid=#{pane_pid} cmd=#{pane_current_command}' 2>&1 | tr '\n' '|')"
  }
  CHECKS=$((CHECKS + 1))
  _ap_restart_window "$wid2" "nudge" \
    || fail "_ap_restart_window must relaunch once claude has exited — $(um_diag "$wid2")"
  for _ in $(seq 1 20); do [ -f "$WORK/typed" ] && break; sleep 0.2; done
  CHECKS=$((CHECKS + 1))
  grep -q "fleet-claude.sh' --continue 'nudge'" "$WORK/typed" 2>/dev/null \
    || fail "the relaunch line did not reach the shell after claude exited (typed: $(cat "$WORK/typed" 2>/dev/null))"

  # 3. The window vanishes on exit (the SessionEnd hook's kill-window) → non-zero, no crash.
  tmux new-window -d -t t: -n gone "$WORK/fakebin/claude -e 'sleep 30'" || fail "new-window"
  wid3=$(tmux display-message -p -t t:gone '#{window_id}')
  sleep 0.5
  CHECKS=$((CHECKS + 1))
  if _ap_restart_window "$wid3" "nudge"; then
    fail "_ap_restart_window returned 0 for a window that closed on exit"
  fi
  um_cleanup; trap - EXIT
else
  printf 'usage-modal selftest: tmux not installed — restart-window checks skipped\n' >&2
fi

printf 'usage-modal selftest: OK (%d checks)\n' "$CHECKS"
exit 0
