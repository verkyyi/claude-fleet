#!/bin/bash
# fleet-break-it-sidefx-selftest.sh — the docs/dev/BREAK-IT.md row of a teardown
# «sandboxed» by HOME alone (issue #4213): on 2026-10-14 an uninstaller run as
# `HOME=$d … --apply` kept its files in $d but SIGTERMed every process of the real
# uid whose argv named `/.claude/fleet/` — the fleet's tmux server among them —
# and booted out `gui/<real uid>/…`. The drill builds that sandbox (a fake fleet
# LaunchAgent under $d, a decoy of the real fleet's tmux server — argv naming the
# REAL home's ~/.claude/fleet/ — and one naming the sandbox's), runs the one rule
# (bin/fleet_sidefx.py stop --apply) on it, and passes when nothing of the real
# uid was signalled or booted out: the decoys live, the would-be actions are in
# the record ($FLEET_SIDEFX_LOG), a PATH launchctl never ran, and acting for
# another login falls back to nothing. Runner and timing helpers are
# bin/fleet-break-it-cred-selftest.sh's (BREAK_CRED_LIB=1);
# bin/fleet-break-it-selftest.sh's lockstep lint reads the drill names here too.
#
#   sandbox-home-real-uid   bin/fleet_sidefx.py (stop / run / decide), and its
#                           caller bin/fleet-node-leave.sh (dom)
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

drill_sandbox_home_real_uid() {
  CAP=10
  local d="$WORK/sfx" me rh a b rc t0 lc
  me=$(id -un); rh=$(python3 -c 'import os,pwd; print(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))')
  mkdir -p "$d/home/Library/LaunchAgents" "$d/shim"
  printf '<plist/>\n' > "$d/home/Library/LaunchAgents/com.claude-fleet.spinner.plist"
  lc="$d/launchctl.ran"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$lc" > "$d/shim/launchctl"; chmod +x "$d/shim/launchctl"
  # a: the real fleet's tmux server as the incident's regex saw it; b: the sandbox's own
  (exec -a "tmux -L sfxdecoy -f $rh/.claude/fleet/bin/../conf/tmux-fleet-server.conf" sleep 60) & a=$!
  (exec -a "$d/home/.claude/fleet/bin/fleet-spinner.sh" sleep 60) & b=$!
  printf '%s\n%s\n' "$a" "$b" >> "$WORK/cred-pids"
  sleep 0.2
  t0=$(now)
  HOME="$d/home" PATH="$d/shim:$PATH" FLEET_SIDEFX_LOG="$d/record" \
    python3 -I "$BIN/fleet_sidefx.py" stop --login "$me" --home "$d/home" --apply > "$d/out" 2>&1
  rc=$?
  SECS=$(since "$t0")
  sleep 0.2
  [ "$rc" = 3 ] || { WHY="stop on a sandbox home exited $rc, want 3 (recorded): $(cat "$d/out")"; return 1; }
  kill -0 "$a" 2>/dev/null || { WHY="the decoy of the real fleet's tmux server was signalled"; return 1; }
  kill -0 "$b" 2>/dev/null || { WHY="a sandbox home's --apply signalled a real process (pid $b)"; return 1; }
  [ ! -s "$lc" ] || { WHY="launchctl ran from a sandbox home: $(cat "$lc")"; return 1; }
  grep -qx "kill -15 $b" "$d/record" 2>/dev/null || { WHY="the sandbox's own process was not recorded: $(cat "$d/record" 2>/dev/null)"; return 1; }
  grep -q "kill -15 $a\$" "$d/record" 2>/dev/null && { WHY="the real home's tmux server was even a target"; return 1; }
  grep -qx "launchctl bootout gui/$(id -u)/com.claude-fleet.spinner" "$d/record" 2>/dev/null \
    || { WHY="the bootout was not recorded: $(cat "$d/record" 2>/dev/null)"; return 1; }
  # acting for another login never falls back to the caller's own uid
  if [ "$(id -u)" != 0 ]; then
    python3 -I "$BIN/fleet_sidefx.py" stop --login root --home "$d/home" --apply > "$d/out2" 2>&1; rc=$?
    [ "$rc" = 4 ] || { WHY="a non-root caller acting for root exited $rc, want 4 (refused): $(cat "$d/out2")"; return 1; }
    kill -0 "$b" 2>/dev/null || { WHY="the refused stop signalled the caller's own process"; return 1; }
  fi
  kill "$a" "$b" 2>/dev/null
  WHAT="HOME 换成临时目录 + --apply：真 uid 的进程一个没收到信号、gui 域没 bootout，要做的事只进了记录；代别的登录做直接拒绝"
}

cred_run_drills "$0"
