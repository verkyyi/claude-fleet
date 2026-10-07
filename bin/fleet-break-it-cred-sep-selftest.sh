#!/bin/bash
# fleet-break-it-cred-sep-selftest.sh — docs/BREAK-IT.md rows `cred-sep-by-agent`
# and `cred-sep-bootstrap-fails` (issue #2273): on 2026-10-07 a session on m4 ran
# `sudo -n bash …/fleet-credsep.sh machine install` itself (the login has
# password-less sudo), launchd refused the agent's new definition halfway, and
# the login's every session and its node agent were down until a person put the
# files back by hand. Split from bin/fleet-break-it-cred-selftest.sh (whose
# helpers it sources, BREAK_CRED_LIB=1) because that run sits at the macOS
# per-test cap; bin/fleet-break-it-selftest.sh's lockstep lint reads the
# drill_cred_* names here too.
#
#   cred-sep-by-agent          hooks/bash-guard.py (credsep: the one sudo is the person's)
#   cred-sep-bootstrap-fails   bin/fleet-credsep.py machine install (rollback from meta.json),
#                              bin/fleet-credsep.sh machine
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

# guard_rc <command> [env…] → the hook's exit code (2 = refused); its stderr in $WORK/guard.err
guard_rc() {
  local c="$1"; shift
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": "/"}))' "$c" \
    | env -u TMUX -u TMUX_PANE -u FLEET_MAIN -u FLEET_ALLOW_CREDSEP_SUDO FLEET_HEAVY=0 FLEET_DIRECT_SCRIPTS=log \
        FLEET_MCP_BYPASS_LOG="$WORK/bypass.log" FLEET_CONF_DIR="$WORK/guard-conf" "$@" \
        python3 "$BIN/../hooks/bash-guard.py" >/dev/null 2>"$WORK/guard.err"
}

drill_cred_sep_by_agent() {
  CAP=10
  local t0 c rc
  mkdir -p "$WORK/guard-conf"
  t0=$(now)
  # the very command of 2026-10-07, and its relatives: refused whatever the spelling
  for c in 'sudo -n bash ~/.claude/fleet/bin/fleet-credsep.sh machine install --logins verkyyi,minilinux' \
           'sudo bash /Users/x/.claude/fleet/bin/fleet-credsep.sh install --login x' \
           'sudo -n bash ~/.claude/fleet/bin/fleet-credsep.sh uninstall --login verkyyi' \
           'bash ~/.claude/fleet/bin/fleet-credsep.sh machine uninstall' \
           "bash -c 'sudo -n bash ~/.claude/fleet/bin/fleet-credsep.sh install'" \
           'sudo bash "$HOME/.claude/fleet/bin/fleet-credsep.sh" machine install' \
           '"$HOME/.claude/fleet/bin/fleet-credsep.sh" install' \
           'FLEET_ALLOW_CREDSEP_SUDO=1 sudo -n bash ~/.claude/fleet/bin/fleet-credsep.sh machine install'; do
    guard_rc "$c"; rc=$?
    [ "$rc" = 2 ] || { WHY="a session's \`$c\` was not refused (rc $rc)"; return 1; }
    grep -q '发起人' "$WORK/guard.err" || { WHY="refused without saying it is the person's step: $(head -2 "$WORK/guard.err")"; return 1; }
  done
  SECS=$(since "$t0")
  # what a session may run: the dry runs, the reads, the plan
  for c in 'bash ~/.claude/fleet/bin/fleet-credsep.sh machine install --logins a,b --dry-run' \
           'bash ~/.claude/fleet/bin/fleet-credsep.sh uninstall --dry-run' \
           'bash ~/.claude/fleet/bin/fleet-credsep.sh plan' \
           'bash ~/.claude/fleet/bin/fleet-credsep.sh machine status' \
           'grep -n "machine install" ~/.claude/fleet/bin/fleet-credsep.sh' \
           'grep -rn "fleet-credsep.sh machine install" docs/BREAK-IT.md' \
           'gh pr create --title x --body "the person types: sudo -n bash ~/.claude/fleet/bin/fleet-credsep.sh machine install"'; do
    guard_rc "$c"; rc=$?
    [ "$rc" = 0 ] || { WHY="\`$c\` changes nothing, yet it was refused (rc $rc): $(head -1 "$WORK/guard.err")"; return 1; }
  done
  # the hatch is the person's: in the session's own environment (set when it was started), never inline
  guard_rc 'sudo -n bash ~/.claude/fleet/bin/fleet-credsep.sh machine install --logins a' FLEET_ALLOW_CREDSEP_SUDO=1; rc=$?
  [ "$rc" = 0 ] || { WHY="FLEET_ALLOW_CREDSEP_SUDO=1 in the environment did not pass it (rc $rc)"; return 1; }
  WHAT="会话里 sudo（或经免密 sudo）跑 credsep install / machine install / uninstall 一律拒，说明这一步由发起人敲；--dry-run、plan、status 照常；FLEET_ALLOW_CREDSEP_SUDO=1 只认会话启动时的环境，不认命令里内联"
}

# A login as a node leaves it: a leased credential, node.env, fleet.conf, the
# agent's service. The fake launchctl / systemctl refuse the agent's NEW
# definition (the launcher's) with exit 5 — the 2026-10-07 failure — and take
# the original back.
drill_cred_sep_bootstrap_fails() {
  CAP=30
  local me uid gid sb C t0 out rc agent before after
  me=$(id -un); uid=$(id -u); gid=$(id -g); sb="$WORK/sepboot"
  C="$sb/homes/alpha/.config/claude-fleet"
  mkdir -p "$C/accounts/a1.hub" "$sb/homes/alpha/.ccquota" "$sb/homes/alpha/.claude/fleet/bin" "$sb/daemons" "$sb/shim"
  printf 'alpha:%s:%s:%s\n' "$uid" "$gid" "$sb/homes/alpha" > "$sb/pw"
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-BOOT","refreshToken":null}}' > "$C/accounts/a1.hub/.credentials.json"
  printf 'CCQUOTA_HUB_URL=http://127.0.0.1:1\nCCQUOTA_TOKEN=ccq_BOOT_SECRET\n' > "$C/node.env"
  printf '# fleet.conf\nexport FLEET_HOST=1\n' > "$C/fleet.conf"
  printf '#!/bin/sh\nPATH="/usr/bin:/bin"\nexec /bin/sleep 1\n' > "$sb/homes/alpha/.ccquota/run-agent.sh"
  chmod +x "$sb/homes/alpha/.ccquota/run-agent.sh"
  if [ "$(uname)" = Darwin ]; then
    agent="$sb/daemons/com.ccquota.agent.alpha.plist"
    python3 -c 'import plistlib, sys
open(sys.argv[1], "wb").write(plistlib.dumps({"Label": "com.ccquota.agent.alpha", "UserName": "alpha",
    "ProgramArguments": [sys.argv[2]], "RunAtLoad": True, "KeepAlive": True}))' "$agent" "$sb/homes/alpha/.ccquota/run-agent.sh"
  else
    agent="$sb/daemons/ccquota-agent-alpha.service"
    printf '[Service]\nUser=alpha\nExecStart=%s\n' "$sb/homes/alpha/.ccquota/run-agent.sh" > "$agent"
  fi
  # launchd's half: bootstrap of a definition that starts the launcher fails 5 (#2273)
  cat > "$sb/shim/launchctl" <<'EOF'
#!/bin/sh
echo "launchctl $*" >> "$FAKE_SVC_LOG"
case "$1" in
  print) exit 113 ;;
  bootstrap) grep -q fleet-credsep-launch "$3" 2>/dev/null && { echo "Bootstrap failed: 5: Input/output error"; exit 5; } ;;
esac
exit 0
EOF
  cat > "$sb/shim/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$FAKE_SVC_LOG"
for a in "$@"; do
  case "$a" in ccquota-agent-*.service)
    [ -f "$FAKE_DAEMONS/$a.d/credsep.conf" ] && { echo "Job for $a failed"; exit 5; } ;;
  esac
done
exit 0
EOF
  chmod +x "$sb/shim/launchctl" "$sb/shim/systemctl"
  before=$(cd "$sb/homes" && find . -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done
           cksum < "$agent")
  t0=$(now)
  out=$(PATH="$sb/shim:$PATH" FAKE_SVC_LOG="$sb/svc.log" FAKE_DAEMONS="$sb/daemons" \
    FLEET_CREDSEP_ROOT_BASE="$sb/db" FLEET_CREDSEP_RUN_BASE="$sb/run" FLEET_CREDSEP_LOG_BASE="$sb/log" \
    FLEET_CREDSEP_LIB="$sb/lib" FLEET_CREDSEP_DAEMON_DIR="$sb/daemons" FLEET_CREDSEP_ROLE="$me" \
    FLEET_CREDSEP_SVC=1 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_SUDO='' FLEET_CREDSEP_PW="$sb/pw" \
    FLEET_CRED_SHARED_PORT="$(cred_deadport)" HOME="$sb/homes/alpha" \
    bash "$BIN/fleet-credsep.sh" machine install --logins alpha 2>&1); rc=$?
  SECS=$(since "$t0")
  [ "$rc" != 0 ] || { WHY="the agent's bootstrap failed, yet machine install said 0: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 1; }
  grep -q 'bootstrap' "$sb/svc.log" 2>/dev/null || { WHY="the fake launchctl/systemctl was never asked: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 1; }
  [ -f "$C/accounts/a1.hub/.credentials.json" ] && [ ! -L "$C/node.env" ] && [ -f "$C/node.env" ] \
    || { WHY="half installed and left so: the credential / node.env are not back where the sessions read them — $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; return 1; }
  after=$(cd "$sb/homes" && find . -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done
          cksum < "$agent")
  [ "$after" = "$before" ] || { WHY="not back byte for byte: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | tr '\n' ' ')"; return 1; }
  [ ! -e "$C/credsep.json" ] && [ ! -e "$sb/db/alpha" ] && [ ! -e "$sb/db/.shared.json" ] \
    || { WHY="leftovers after the rollback: $(ls -a "$sb/db" "$C" 2>&1 | tr '\n' ' ')"; return 1; }
  printf '%s' "$out" | grep -q 'rolled back' || { WHY="the output does not say it rolled back: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 1; }
  WHAT="machine install 半途 bootstrap 返回 5：自动按 meta.json 退回（凭据、node.env、fleet.conf、agent 定义逐字节原样），退出码 ${rc}"
}

cred_run_drills "$0"
