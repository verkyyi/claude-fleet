#!/bin/bash
# fleet-break-it-sshprompt-selftest.sh — the docs/dev/BREAK-IT.md row of an ssh
# question landing on a session's pane: on 2026-10-23 mini2's LAN address changed,
# a login's `phone` MCP server (`ssh m4 …`, started by every Claude launch) met an
# unknown host, and ssh — which opens /dev/tty for its yes/no whatever its stdio —
# painted the question over several sessions and ate the person's keys. The drill
# runs that ssh for real (a REAL sshd as `sshd -i` behind a ProxyCommand, a
# known_hosts that never heard of it, stdio all redirected) from a session opened
# through bin/fleet-session-wrap.sh in an isolated tmux pane, and passes when the
# pane stays clean and ssh fails on its own: «Host key verification failed.».
# Runner and timing helpers are bin/fleet-break-it-cred-selftest.sh's
# (BREAK_CRED_LIB=1); bin/fleet-break-it-selftest.sh's lockstep lint reads the
# drill names here too.
#
#   ssh-prompt-on-pane   bin/fleet-session-wrap.sh (SSH_ASKPASS_REQUIRE=force) and
#                        bin/fleet-ssh-askpass.sh
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

drill_ssh_prompt_on_pane() {
  CAP=15
  local d tx t0 f i
  d=$(mktemp -d /tmp/skp.XXXXXX) || { WHY="no /tmp dir"; return 1; }
  tx() { tmux -S "$d/s" "$@"; }
  if [ ! -x /usr/sbin/sshd ] || ! command -v ssh >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
    WHAT="SKIP — no sshd / ssh / tmux here"; SECS=0; rm -rf "$d"; return 0
  fi
  ssh-keygen -q -t ed25519 -N '' -f "$d/host" </dev/null >/dev/null 2>&1 || { WHY="ssh-keygen failed"; rm -rf "$d"; return 1; }
  printf 'HostKey %s\nPidFile none\nStrictModes no\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' "$d/host" > "$d/sshd_config"
  /usr/sbin/sshd -t -f "$d/sshd_config" >/dev/null 2>&1 || { WHAT="SKIP — sshd refuses a sandbox config here"; SECS=0; rm -rf "$d"; return 0; }
  # the machine is reached by a name its known_hosts has never seen (a new DHCP address)
  printf 'Host m4\n  ProxyCommand /usr/sbin/sshd -i -f %s\n  GlobalKnownHostsFile /dev/null\n  UserKnownHostsFile %s\n  StrictHostKeyChecking ask\n' \
    "$d/sshd_config" "$d/known_hosts" > "$d/ssh_config"
  : > "$d/known_hosts"
  # what the MCP server did: ssh with every stdio away from the pane
  printf '#!/bin/bash\nssh -F %s -T m4 true </dev/null >/dev/null 2>%s; echo "rc=$?" >> %s\nwhile [ ! -e %s ]; do sleep 0.1; done\n' \
    "$d/ssh_config" "$d/err" "$d/err" "$d/go" > "$d/launch"
  chmod +x "$d/launch"
  mkdir -p "$d/bin" "$d/conf"
  for f in fleet_repo_authority.py fleet-session-wrap.sh fleet_notice.py fleet-session-page.py fleet-ssh-askpass.sh; do
    ln -s "$BIN/$f" "$d/bin/$f"
  done
  t0=$(now)
  tx -f /dev/null new-session -d -s skp -x 160 -y 30 \
    "env -u SSH_ASKPASS -u SSH_ASKPASS_REQUIRE FLEET_WRAP_LAUNCH='$d/launch' FLEET_WRAP_FAST_FAIL=0 FLEET_CONF_DIR='$d/conf' FLEET_EXIT_CLOSE_SECS=0 FLEET_MCP=0 FLEET_CRED_PROXY=0 '$d/bin/fleet-session-wrap.sh' --agent claude; exec sleep 60"
  for i in $(seq 1 100); do
    grep -q '^rc=' "$d/err" 2>/dev/null && break
    tx capture-pane -p -t skp 2>/dev/null | grep -q 'continue connecting' && break
    sleep 0.1
  done
  SECS=$(since "$t0")
  tx capture-pane -p -t skp > "$d/pane" 2>/dev/null
  tx kill-server 2>/dev/null
  if grep -q -e 'continue connecting' -e 'authenticity of host' "$d/pane"; then
    WHY="ssh asked on the session's pane: $(grep -m1 -e 'continue connecting' -e 'authenticity' "$d/pane")"; rm -rf "$d"; return 1
  fi
  grep -qx 'rc=255' "$d/err" || { WHY="ssh did not fail on its own: $(tr '\n' ' ' < "$d/err" 2>/dev/null)"; rm -rf "$d"; return 1; }
  grep -q 'Host key verification failed' "$d/err" || { WHY="ssh's stderr lacks its own error: $(tr '\n' ' ' < "$d/err")"; rm -rf "$d"; return 1; }
  grep -q '^fleet: ssh asked ' "$d/err" || { WHY="the askpass did not say what ssh asked: $(tr '\n' ' ' < "$d/err")"; rm -rf "$d"; return 1; }
  rm -rf "$d"
  WHAT="会话里的 ssh 碰到陌生主机（stdio 全重定向、真 sshd -i）：窗口里一个字没出现，问题进了 fleet 的 askpass 被答 no，ssh 自己报 Host key verification failed"
}

cred_run_drills "$0"
