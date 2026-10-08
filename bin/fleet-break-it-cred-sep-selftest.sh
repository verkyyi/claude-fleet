#!/bin/bash
# fleet-break-it-cred-sep-selftest.sh — docs/BREAK-IT.md rows `cred-sep-proxy-off`
# and `cred-sep-bootstrap-fails` (issue #2273): on 2026-10-07 m4's
# `sudo -n bash …/fleet-credsep.sh machine install` moved the credentials before
# the login's proxy was on, launchd refused the agent's new definition halfway,
# and the login's every session and its node agent were down until a person put
# the files back by hand. Split from bin/fleet-break-it-cred-selftest.sh (whose
# helpers it sources, BREAK_CRED_LIB=1) because that run sits at the macOS
# per-test cap; bin/fleet-break-it-selftest.sh's lockstep lint reads the
# drill_cred_* names here too.
#
#   cred-sep-proxy-off         bin/fleet-credsep.py preflight (proxy on · sessions on it · no EPIC batch)
#   cred-sep-bootstrap-fails   bin/fleet-credsep.py machine install (rollback from meta.json),
#                              bin/fleet-credsep.sh machine
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

# sep_login <dir> — a login as a node leaves it, in <dir>/homes/alpha (the
# FLEET_CREDSEP_PW row in <dir>/pw); sets C (its conf dir)
sep_login() {
  local sb="$1"
  C="$sb/homes/alpha/.config/claude-fleet"
  mkdir -p "$C/accounts/a1.hub" "$sb/homes/alpha/.ccquota" "$sb/homes/alpha/.claude/fleet/bin" "$sb/daemons" "$sb/shim"
  printf 'alpha:%s:%s:%s\n' "$(id -u)" "$(id -g)" "$sb/homes/alpha" > "$sb/pw"
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-BOOT","refreshToken":null}}' > "$C/accounts/a1.hub/.credentials.json"
  printf 'CCQUOTA_HUB_URL=http://127.0.0.1:1\nCCQUOTA_TOKEN=ccq_BOOT_SECRET\n' > "$C/node.env"
  printf '# fleet.conf\nexport FLEET_HOST=1\n' > "$C/fleet.conf"
}
# sep_install <dir> <args…> — machine install for alpha in the sandbox <dir>; → OUT, RC
sep_install() {
  local sb="$1"; shift
  OUT=$(PATH="$sb/shim:$PATH" FAKE_SVC_LOG="$sb/svc.log" FAKE_DAEMONS="$sb/daemons" \
    FLEET_CREDSEP_ROOT_BASE="$sb/db" FLEET_CREDSEP_RUN_BASE="$sb/run" FLEET_CREDSEP_LOG_BASE="$sb/log" \
    FLEET_CREDSEP_LIB="$sb/lib" FLEET_CREDSEP_DAEMON_DIR="$sb/daemons" FLEET_CREDSEP_ROLE="$(id -un)" \
    FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_SUDO='' FLEET_CREDSEP_PW="$sb/pw" \
    FLEET_CRED_SHARED_PORT="$(cred_deadport)" HOME="$sb/homes/alpha" FLEET_CRED_ROLLOUT_WAIT=1 \
    bash "$BIN/fleet-credsep.sh" machine install --logins alpha "$@" 2>&1); RC=$?
}

# The very order of 2026-10-07: the credentials moved while the login's proxy was
# not on and its sessions read the files. The preflight refuses, nothing moves.
drill_cred_sep_proxy_off() {
  CAP=20
  local sb="$WORK/sepoff" t0
  sep_login "$sb"
  t0=$(now)
  FLEET_CREDSEP_SVC=0 sep_install "$sb"
  SECS=$(since "$t0")
  [ "$RC" = 6 ] || { WHY="the proxy is off, yet machine install went on (rc $RC): $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"; return 1; }
  printf '%s' "$OUT" | grep -q 'cred-proxy enable' || { WHY="refused without saying what to do first: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"; return 1; }
  [ ! -e "$sb/db/alpha" ] && [ -f "$C/accounts/a1.hub/.credentials.json" ] && [ ! -L "$C/node.env" ] \
    && ! grep -q FLEET_CRED_PROXY "$C/fleet.conf" || { WHY="refused, yet something moved: $(ls -a "$sb/db" "$C" 2>&1 | tr '\n' ' ')"; return 1; }
  # a running EPIC batch on the login: refused too, even with the proxy on
  printf 'export FLEET_CRED_PROXY=1\n' >> "$C/fleet.conf"
  mkdir -p "$C/global/epic-running.d"
  printf 'epoch: %s\nepic: 9\nsession: s\ntick: 1\n' "$(date +%s)" > "$C/global/epic-running.d/o-r-9"
  FLEET_CREDSEP_SVC=0 sep_install "$sb"
  [ "$RC" = 6 ] && printf '%s' "$OUT" | grep -q 'EPIC batch' \
    || { WHY="an EPIC batch runs on the login, yet no refusal naming it (rc $RC): $(printf '%s' "$OUT" | grep preflight | tr '\n' ' ')"; return 1; }
  # --force: the person's (or the agent's, on purpose) way past it
  FLEET_CREDSEP_SVC=0 sep_install "$sb" --force
  [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'preflight: --force' && [ -f "$sb/db/alpha/node.env" ] \
    || { WHY="--force did not go on (rc $RC): $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"; return 1; }
  WHAT="代理没开就 machine install：安装前自检拒绝（exit 6，什么都没搬），说先 fleet cred-proxy enable；本登录有 EPIC 批次在跑也拒；--force 才过"
}

# A login as a node leaves it: a leased credential, node.env, fleet.conf, the
# agent's service. The fake launchctl / systemctl refuse the agent's NEW
# definition (the launcher's) with exit 5 — the 2026-10-07 failure — and take
# the original back.
drill_cred_sep_bootstrap_fails() {
  CAP=30
  local sb="$WORK/sepboot" t0 out rc agent before after
  sep_login "$sb"
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
  FLEET_CREDSEP_SVC=1 FLEET_CREDSEP_PREFLIGHT=0 sep_install "$sb"; out=$OUT rc=$RC
  SECS=$(since "$t0")
  [ "$rc" != 0 ] || { WHY="the agent's bootstrap failed, yet machine install said 0: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 1; }
  grep -Eq 'bootstrap|enable .*ccquota-agent' "$sb/svc.log" 2>/dev/null || { WHY="the fake launchctl/systemctl was never asked: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 1; }
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
