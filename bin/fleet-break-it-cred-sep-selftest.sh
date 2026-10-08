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
#   cred-upstream-tenant-override  bin/fleet-credsep-launch.py (root's settings only),
#                              bin/fleet-cred-proxy.py (the upstream allow-list) — issue #2290
#   root-log-in-home           bin/fleet-credsep.py agent_log (issue #2296): the root agent's
#                              log is not in the home
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

# A separated login writes its own upstream and hub into fleet.conf: a listener
# of its own on loopback. Root's launcher must not hand those to the proxy — the
# listener never sees a request, an Authorization or the node token (#2290).
drill_cred_upstream_tenant_override() {
  CAP=30
  local me sb t0 evil good tok port i
  me=$(id -un); sb="$WORK/tenant"
  local c="$sb/home/.config/claude-fleet"
  mkdir -p "$c/accounts/a1.hub" "$sb/daemons" "$sb/home/.ccquota" "$sb/good" "$sb/evil"
  printf 'trusted\n' > "$sb/good/trust"; printf 'trusted\n' > "$sb/evil/trust"
  cred_fake "$sb/good" && cred_fake "$sb/evil" || { WHY="the fake listeners did not start"; return 1; }
  good="http://127.0.0.1:$(cat "$sb/good/fake.port")" evil="http://127.0.0.1:$(cat "$sb/evil/fake.port")"
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-TENANT","refreshToken":null}}' > "$c/accounts/a1.hub/.credentials.json"
  printf 'hub:a1\n' > "$c/accounts/a1"
  printf 'CCQUOTA_TOKEN=ccq_TENANT_NODE_SECRET\n' > "$c/node.env"      # its hub: FLEET_HUB_URL
  printf '{"anthropic":"reachable","openai":"reachable"}\n' > "$c/node-probe.json"
  t0=$(now)
  ( export HOME="$sb/home" FLEET_CONF_DIR="$c" FLEET_CREDSEP_ROOT_BASE="$sb/db" FLEET_CREDSEP_RUN_BASE="$sb/run" \
      FLEET_CREDSEP_LOG_BASE="$sb/log" FLEET_CREDSEP_LIB="$sb/lib" FLEET_CREDSEP_DAEMON_DIR="$sb/daemons" \
      FLEET_CREDSEP_ROLE="$me" FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_PREFLIGHT=0 FLEET_CREDSEP_SUDO=''
    bash "$BIN/fleet-credsep.sh" install >"$sb/install.out" 2>&1
    # root's settings: the real upstream; the login's own file: its listener
    printf 'FLEET_CRED_ANTHROPIC_URL=%s/direct-anthropic\n' "$good" >> "$sb/lib/$me.conf"
    printf 'FLEET_CRED_ANTHROPIC_URL=%s/direct-anthropic\nFLEET_CRED_CENTRAL_URL=%s/central\nFLEET_HUB_URL=%s\n' \
      "$evil" "$evil" "$evil" >> "$c/fleet.conf"
    exec python3 -I "$BIN/fleet-credsep-launch.py" proxy "$me" ) 2>"$sb/launch.err" &
  printf '%s\n' "$!" >> "$WORK/cred-pids"
  until_ok 30 test -s "$sb/run/$me/port" || { WHY="the proxy did not start: $(tail -3 "$sb/install.out" "$sb/launch.err" | tr '\n' ' ')"; return 1; }
  port=$(cat "$sb/run/$me/port")
  tok=$(HOME="$sb/home" FLEET_CONF_DIR="$c" bash "$BIN/fleet-cred-proxy.sh" mint --account a1 --sid t1 2>&1)
  for i in 1 2; do
    curl -s -m 20 -o "$sb/resp" -X POST -H "Authorization: Bearer $tok" -H 'content-type: application/json' \
      -d '{}' "http://127.0.0.1:$port/v1/messages" >/dev/null 2>&1
  done
  SECS=$(since "$t0")
  [ ! -s "$sb/evil/hits" ] || { WHY="the login's own listener was asked: $(sort -u "$sb/evil/hits" | tr '\n' ' ')"; return 1; }
  grep -q '^direct-anthropic ' "$sb/good/hits" 2>/dev/null \
    || { WHY="root's upstream never served the request: $(cat "$sb/resp" 2>/dev/null) $(tail -2 "$sb/launch.err" | tr '\n' ' ')"; return 1; }
  grep -q 'ignored FLEET_CRED_ANTHROPIC_URL' "$sb/launch.err" && grep -q 'ignored FLEET_HUB_URL' "$sb/launch.err" \
    || { WHY="the launcher did not say what it ignored: $(tr '\n' ' ' < "$sb/launch.err")"; return 1; }
  WHAT="登录往自己的 fleet.conf 写上游和 FLEET_HUB_URL：它的监听收不到任何请求、Authorization 或节点令牌，请求照走 root 配置的上游；启动器写明 ignored"
}

# root-log-in-home (issue #2296): launchd / systemd open a root job's stdout file
# AS ROOT and follow a symlink. credsep turns the agent into a root job (the
# launcher) and used to keep its log at ~/.ccquota/agent.log — so the login could
# `ln -sf <any file> ~/.ccquota/agent.log` and have root append to it. The drill
# plays root's open() on both definitions: the one credsep used to leave (kept in
# the store's backup/) writes through the link; the one it writes now does not.
drill_root_log_in_home() {
  CAP=20
  local sb="$WORK/rootlog" t0 agent eff old victim home
  sep_login "$sb"
  home="$sb/homes/alpha"
  printf '#!/bin/sh\nPATH="/usr/bin:/bin"\nexec /bin/sleep 1\n' > "$home/.ccquota/run-agent.sh"
  chmod +x "$home/.ccquota/run-agent.sh"
  if [ "$(uname)" = Darwin ]; then
    agent="$sb/daemons/com.ccquota.agent.alpha.plist"
    python3 -c 'import plistlib, sys
open(sys.argv[1], "wb").write(plistlib.dumps({"Label": "com.ccquota.agent.alpha", "UserName": "alpha",
    "ProgramArguments": [sys.argv[2]], "RunAtLoad": True, "KeepAlive": True,
    "StandardOutPath": sys.argv[3], "StandardErrorPath": sys.argv[3]}))' "$agent" "$home/.ccquota/run-agent.sh" "$home/.ccquota/agent.log"
  else
    agent="$sb/daemons/ccquota-agent-alpha.service"
    printf '[Service]\nUser=alpha\nExecStart=%s\nStandardOutput=append:%s\nStandardError=append:%s\n' \
      "$home/.ccquota/run-agent.sh" "$home/.ccquota/agent.log" "$home/.ccquota/agent.log" > "$agent"
  fi
  printf 'export FLEET_CRED_PROXY=1\n' >> "$C/fleet.conf"
  t0=$(now)
  FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_PREFLIGHT=0 sep_install "$sb"
  [ "$RC" = 0 ] || { WHY="machine install failed (rc $RC): $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"; return 1; }
  # root's log path: the plist's StandardOutPath, or the unit's last StandardOutput= (drop-ins after it)
  logpath() {
    python3 - "$1" <<'PY'
import glob, plistlib, re, sys
p = sys.argv[1]
if p.endswith(".plist"):
    print(plistlib.load(open(p, "rb")).get("StandardOutPath", ""))
else:
    v = ""
    for f in [p] + sorted(glob.glob(p + ".d/*.conf")):
        for l in open(f):
            m = re.match(r"StandardOutput=(?:file|append|truncate):(.*)$", l.strip())
            if m:
                v = m.group(1)
    print(v)
PY
  }
  root_writes() { python3 -c 'import sys; open(sys.argv[1], "a").write("ROOT WROTE THIS\n")' "$1"; }   # launchd's open(O_APPEND|O_CREAT)
  victim="$sb/etc-sudoers"; printf 'root ALL=(ALL) ALL\n' > "$victim"
  # the old way, as credsep left it: the agent's own log path, root's write through the login's link
  old=$(logpath "$sb/db/alpha/backup/$(basename "$agent")")
  mkdir -p "$(dirname "$old")"; ln -sf "$victim" "$old"
  root_writes "$old"
  grep -q 'ROOT WROTE' "$victim" || { WHY="the rig is wrong: root's write through the old path did not reach the link's target ($old)"; return 1; }
  printf 'root ALL=(ALL) ALL\n' > "$victim"
  eff=$(logpath "$agent")
  SECS=$(since "$t0")
  case "$eff" in
    ''|"$sb/homes/"*) WHY="the root agent still logs in the home: ${eff:-<none>} — the login's link sends root's write anywhere"; return 1 ;;
  esac
  root_writes "$eff" 2>/dev/null
  ! grep -q 'ROOT WROTE' "$victim" || { WHY="root's write reached the link's target through $eff"; return 1; }
  WHAT="credsep 把节点代理改成 root 启动时，日志从 ~/.ccquota/agent.log 移到 \$LOG_BASE/<登录>/agent.log：同一根软链，旧写法 root 写进目标文件，新写法写不到"
}

cred_run_drills "$0"
