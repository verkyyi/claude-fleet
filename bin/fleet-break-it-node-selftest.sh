#!/bin/bash
# fleet-break-it-node-selftest.sh — docs/BREAK-IT.md row `node-supervisor-dead`
# (issue #2331, EPIC #2329 C3): the machine's one daemon dies. Its own file, like
# the cred-shared drill whose runner it sources (BREAK_CRED_LIB=1);
# bin/fleet-break-it-selftest.sh's lockstep lint reads the drill_* names here too.
#
#   node-supervisor-dead  bin/fleet-node-supervisor.py (install's KeepAlive +
#                         ThrottleInterval, run's adopt + state.json, status --check),
#                         bin/fleet-doctor.sh's `node` row
#   service-killed        bin/fleet-node-supervisor.py's login-level register (#2525):
#                         a registered service is kill -9'd / dies at start
#   service-login-moved   bin/fleet-node-supervisor.py `service move` + `account release`,
#                         bin/fleet-login-remove.sh (#2528): a login is moved to another
#                         one / retired while a registered task of it still runs
#   account-adopt-stuck   bin/fleet-node-supervisor.py `account adopt|release` (#2332):
#                         one of a login's services will not unload mid-migration
#   account-adopt-agent-left  bin/fleet-node-supervisor.py `account adopt|release` (#2387):
#                         the login's own node agent (com.ccquota.agent.<login>) moves
#                         with it — logins/<login>.env written, the old one in the attic
#   node-update-half      bin/fleet-node-update.py (#2334): an update killed half way,
#                         and a release whose new part fails the doctor
#   node-install-half     bin/fleet-node-install.sh (#2330): `fleet node install`
#                         killed half way through, then a part deleted afterwards
#   credsep-stale-after-switch  bin/fleet-node-update.py + fleet-credsep.py `machine
#                         refresh` + the supervisor's cred-proxy-shared `reload` (#2435):
#                         a switch / rollback left the shared credential proxy on old code
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

drill_node_supervisor_dead() {
  CAP=15   # kill -9 → launchd's ThrottleInterval + a python start + the first pass
  local sb thr sup pid1 cpid t0
  sb="$WORK/node"; mkdir -p "$sb/LaunchDaemons" "$sb/rt/bin"
  cp "$BIN/fleet-node-supervisor.py" "$sb/rt/bin/"
  printf '#!/bin/bash\nexit 0\n' > "$sb/ok.sh"
  printf '{"children":[{"name":"c","cmd":["/bin/sleep","300"]}],"tasks":[{"name":"t","every":0.5,"cmd":["/bin/bash","%s"]}]}\n' "$sb/ok.sh" > "$sb/table.json"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_HEARTBEAT_STALE=5
  python3 "$sb/rt/bin/fleet-node-supervisor.py" install >"$sb/install.out" 2>&1 \
    || { WHY="install failed: $(tail -2 "$sb/install.out" | tr '\n' ' ')"; return 1; }
  thr=$(python3 -c 'import plistlib, sys; d = plistlib.load(open(sys.argv[1], "rb")); assert d["KeepAlive"] is True; print(d["ThrottleInterval"])' \
        "$sb/LaunchDaemons/com.claude-fleet.node.plist") || { WHY="the service is not KeepAlive"; return 1; }
  st() { python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$sb/db/state.json" "$1" 2>/dev/null; }
  # launchd's part, played here: start it, and again $thr s after it dies
  ( while :; do python3 -I "$sb/rt/bin/fleet-node-supervisor.py" run 2>>"$sb/sup.err"; sleep "$thr"; done ) 2>/dev/null &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  until_ok 15 sh -c '[ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[\"tasks\"][\"t\"].get(\"runs\",0))" "$1" 2>/dev/null)" -ge 2 ]' _ "$sb/db/state.json" \
    || { WHY="the supervisor never ran its task: $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; return 1; }
  pid1=$(st 's["supervisor"]["pid"]'); cpid=$(st 's["children"]["c"]["pid"]')
  python3 "$sb/rt/bin/fleet-node-supervisor.py" status --check >/dev/null || { WHY="status --check not ok while up"; return 1; }
  kill -9 "$pid1"; t0=$(now)
  python3 "$sb/rt/bin/fleet-node-supervisor.py" status --check >"$sb/down.out"
  [ $? = 1 ] && grep -q DOWN "$sb/down.out" || { WHY="status --check did not say DOWN in the gap: $(cat "$sb/down.out")"; return 1; }
  until_ok 30 sh -c '[ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[\"supervisor\"][\"starts\"])" "$1" 2>/dev/null)" = 2 ]' _ "$sb/db/state.json" \
    || { WHY="the supervisor was not brought back"; return 1; }
  until_ok 10 python3 "$sb/rt/bin/fleet-node-supervisor.py" status --check >/dev/null || { WHY="status --check not ok after the restart"; return 1; }
  SECS=$(since "$t0")
  [ "$(st 's["children"]["c"]["pid"]')" = "$cpid" ] || { WHY="the child was not adopted (was $cpid, now $(st 's["children"]["c"]["pid"]'))"; return 1; }
  [ "$(st 's["tasks"]["t"]["runs"]')" -ge 2 ] || { WHY="task history lost"; return 1; }
  grep -q '"$_nsup" status --check' "$BIN/fleet-doctor.sh" || { WHY="fleet-doctor.sh has no node row"; return 1; }
  kill "$sup" 2>/dev/null; kill "$(st 's["supervisor"]["pid"]')" 2>/dev/null; kill "$cpid" 2>/dev/null
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_HEARTBEAT_STALE
  WHAT="整机守护 kill -9：空档里 status --check 报 DOWN（体检 node 行报警），KeepAlive 按 ${thr}s 拉起，任务记录还在、子进程被认领不重起"
}

drill_service_killed() {
  CAP=30   # the issue's bar: a killed service is back within 30 s
  local sb sup p1 p2 t0
  sb="$WORK/svc"; mkdir -p "$sb/LaunchDaemons" "$sb/Users/alice"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  printf '#!/bin/bash\necho "up $(id -u) $USER"\nexec sleep 300\n' > "$sb/watch.sh"; chmod +x "$sb/watch.sh"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json"
  python3 "$BIN/fleet-node-supervisor.py" service add --login alice --name watch -- "$sb/watch.sh" >"$sb/add.out" 2>&1 \
    || { WHY="service add failed: $(tail -2 "$sb/add.out" | tr '\n' ' ')"; return 1; }
  python3 -I "$BIN/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  svc_pid() { python3 -c 'import json, sys; print((json.load(open(sys.argv[1]))["children"].get("svc:alice/watch") or {}).get("pid") or "")' "$sb/db/state.json" 2>/dev/null; }
  until_ok 15 sh -c 'grep -q "^up " "$1" 2>/dev/null' _ "$sb/log/logins/alice/watch.log" \
    || { WHY="the service never ran (no log): $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; return 1; }
  p1=$(svc_pid); [ -n "$p1" ] || { WHY="no pid recorded"; return 1; }
  kill -9 "$p1"; t0=$(now)
  until_ok 30 sh -c '[ -n "$2" ] && [ "$(python3 -c "import json,sys; print((json.load(open(sys.argv[1]))[\"children\"].get(\"svc:alice/watch\") or {}).get(\"pid\") or \"\")" "$1" 2>/dev/null)" != "$2" ] && [ "$(grep -c "^up " "$3")" -ge 2 ]' _ "$sb/db/state.json" "$p1" "$sb/log/logins/alice/watch.log" \
    || { WHY="the killed service was not brought back"; kill "$sup" 2>/dev/null; return 1; }
  SECS=$(since "$t0"); p2=$(svc_pid)
  python3 "$BIN/fleet-node-supervisor.py" status --json | python3 -c 'import json, sys; r = [x for x in json.load(sys.stdin)["services"] if x["name"] == "watch"][0]; assert r["status"] == "running" and r["restarts"] >= 1, r' 2>"$sb/st.err" \
    || { WHY="status --json .services did not show it running with a restart: $(tail -1 "$sb/st.err")"; kill "$sup" 2>/dev/null; return 1; }
  python3 "$BIN/fleet-node-supervisor.py" service rm --login alice --name watch >/dev/null
  until_ok 10 sh -c '! kill -0 "$1" 2>/dev/null' _ "$p2" || { WHY="rm left the service running"; kill "$sup" 2>/dev/null; return 1; }
  kill "$sup" 2>/dev/null; wait "$sup" 2>/dev/null
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_PASSWD
  WHAT="登记的服务 kill -9：守护按子进程退避在 30 秒内以原登录身份重起，日志续写在 logins/<登录>/，status --json 的 services[] 记重启次数；rm 后停掉"
}

drill_service_login_moved() {
  CAP=30   # the move → the first run under the new login
  local sb sup ha hb t0 r
  sb="$WORK/svcmove"; ha="$sb/Users/verkyyi"; hb="$sb/Users/verky"
  mkdir -p "$sb/LaunchDaemons" "$ha/daily-report/logs" "$ha/.claude/skills/daily-report" "$hb"
  printf '{"verkyyi": {"uid": %s, "gid": %s, "home": "%s"}, "verky": {"uid": %s, "gid": %s, "home": "%s"}}\n' \
    "$(id -u)" "$(id -g)" "$ha" "$(id -u)" "$(id -g)" "$hb" > "$sb/passwd.json"
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  printf 'skill\n' > "$ha/.claude/skills/daily-report/SKILL.md"
  # the 2026-10-08 case: the daily push gives up when its login's things are not there
  printf '#!/bin/bash\n[ -f "$HOME/.claude/skills/daily-report/SKILL.md" ] && [ -n "$BARK_KEY" ] || { echo "give up $USER"; exit 1; }\necho "pushed $USER" >> "$HOME/daily-report/logs/run.log"; echo "ok $USER"\nexec sleep 300\n' \
    > "$ha/daily-report/run.sh"; chmod +x "$ha/daily-report/run.sh"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json"
  printf 'k\n' | python3 "$BIN/fleet-node-supervisor.py" service cred set --login verkyyi --name BARK_KEY >/dev/null
  python3 "$BIN/fleet-node-supervisor.py" service add --login verkyyi --name daily-report --cred BARK_KEY \
    --path "$ha/daily-report" --path "$ha/.claude/skills/daily-report" -- "$ha/daily-report/run.sh" >"$sb/add.out" 2>&1 \
    || { WHY="service add failed: $(tail -2 "$sb/add.out" | tr '\n' ' ')"; return 1; }
  python3 -I "$BIN/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  until_ok 15 grep -q '^ok verkyyi' "$sb/log/logins/verkyyi/daily-report.log" \
    || { WHY="it never ran as the old login: $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; kill "$sup" 2>/dev/null; return 1; }
  python3 "$BIN/fleet-node-supervisor.py" account release verkyyi >"$sb/rel.out" 2>&1; r=$?
  [ "$r" = 6 ] && grep -q 'service move --login verkyyi --name daily-report' "$sb/rel.out" \
    || { WHY="releasing the old login with a task left was not refused 6 (rc $r)"; kill "$sup" 2>/dev/null; return 1; }
  grep -q 'exit 6' "$BIN/fleet-login-remove.sh" || { WHY="fleet-login-remove.sh has no exit 6 refusal"; kill "$sup" 2>/dev/null; return 1; }
  t0=$(now)
  python3 "$BIN/fleet-node-supervisor.py" service move --login verkyyi --name daily-report --to verky >"$sb/move.out" 2>&1 \
    || { WHY="service move failed: $(tail -2 "$sb/move.out" | tr '\n' ' ')"; kill "$sup" 2>/dev/null; return 1; }
  until_ok 30 grep -q '^ok verky$' "$sb/log/logins/verky/daily-report.log" \
    || { WHY="it did not run as the new login: $(tail -2 "$sb/log/logins/verky/daily-report.log" | tr '\n' ' ')"; kill "$sup" 2>/dev/null; return 1; }
  SECS=$(since "$t0")
  grep -q '^give up' "$sb/log/logins/verky/daily-report.log" && { WHY="it gave up under the new login"; kill "$sup" 2>/dev/null; return 1; }
  [ -z "$(ls "$sb/db/logins/verkyyi/services")" ] && [ ! -e "$ha/daily-report" ] && [ ! -e "$ha/.claude/skills/daily-report" ] \
    && [ ! -e "$sb/log/logins/verkyyi/daily-report.log" ] && [ ! -e "$sb/db/logins/verkyyi/creds/BARK_KEY" ] \
    || { WHY="something of it is left under the old login"; kill "$sup" 2>/dev/null; return 1; }
  grep -q 'pushed verky' "$hb/daily-report/logs/run.log" || { WHY="the job's own log is not in the new home"; kill "$sup" 2>/dev/null; return 1; }
  kill "$sup" 2>/dev/null; wait "$sup" 2>/dev/null
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_PASSWD
  WHAT="每日推送登记在旧登录下：退役旧登录（account release / fleet-login-remove）因有任务未迁走被拒（退 6，打印 move 命令）；service move 后条目、工作目录、技能目录、日志、凭据都到新登录下，旧登录下一样不剩，守护以新登录身份按时跑起来"
}

drill_account_adopt_stuck() {
  CAP=10
  local sb la t0 n
  sb="$WORK/acct"; la="$sb/Users/alice/Library/LaunchAgents"
  mkdir -p "$la" "$sb/lc/loaded" "$sb/lc/stuck" "$sb/LaunchDaemons" "$sb/Users/alice/.claude/fleet/bin"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  cat > "$sb/launchctl" <<'LC'
#!/bin/bash
d="$FAKE_LC"; echo "$*" >> "$d/log"
case "$1" in
  bootout) l="${2##*/}"; [ -e "$d/stuck/$l" ] && exit 5; rm -f "$d/loaded/$l" ;;
  bootstrap) touch "$d/loaded/$(basename "$3" .plist)" ;;
  print) [ -e "$d/loaded/${2##*/}" ] ;;
esac
LC
  chmod +x "$sb/launchctl"
  for u in cleanup dispatch spinner; do
    python3 -c 'import plistlib, sys; plistlib.dump({"Label": sys.argv[2], "ProgramArguments": ["/bin/true"]}, open(sys.argv[1], "wb"))' \
      "$la/com.claude-fleet.$u.plist" "com.claude-fleet.$u"
    : > "$sb/lc/loaded/com.claude-fleet.$u"
  done
  : > "$sb/lc/stuck/com.claude-fleet.dispatch"
  printf '{"account": []}\n' > "$sb/table.json"
  sup() { FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" \
          FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json" \
          FLEET_NODE_LAUNCHCTL="$sb/launchctl" FLEET_NODE_BOOTOUT_WAIT=1 FAKE_LC="$sb/lc" python3 "$BIN/fleet-node-supervisor.py" "$@"; }
  t0=$(now)
  sup account adopt alice >"$sb/adopt.out" 2>&1 && { WHY="adopt succeeded past a service that did not unload"; return 1; }
  n=$(ls "$la" | wc -l | tr -d ' ')
  [ "$n" = 3 ] || { WHY="a half migration: $n of 3 plists left in LaunchAgents"; return 1; }
  [ "$(ls "$sb/lc/loaded" | wc -l | tr -d ' ')" = 3 ] || { WHY="a booted-out service was not loaded back: $(ls "$sb/lc/loaded" | tr '\n' ' ')"; return 1; }
  sup account manages alice && { WHY="alice reads managed after a failed adopt"; return 1; }
  rm -f "$sb/lc/stuck/com.claude-fleet.dispatch"
  sup account adopt alice >/dev/null 2>&1 || { WHY="adopt failed once the service unloads"; return 1; }
  [ -z "$(ls "$la")" ] && [ -z "$(ls "$sb/lc/loaded")" ] || { WHY="adopt left a per-account service"; return 1; }
  sup account release alice >/dev/null 2>&1 || { WHY="release failed"; return 1; }
  [ "$(ls "$la" | wc -l | tr -d ' ')" = 3 ] && [ "$(ls "$sb/lc/loaded" | wc -l | tr -d ' ')" = 3 ] \
    || { WHY="release did not put every service back and loaded"; return 1; }
  SECS=$(since "$t0")
  WHAT="迁移中一个服务卸不掉：adopt 退 1，已卸的全部放回并重新加载、账号不算托管；卸得掉之后 adopt 成功，release 一条命令全部还原"
}

# account-adopt-agent-left (#2387): adopt moved a login's fleet services but not
# its own node agent — the machine's one node program waited forever for
# logins/<login>.env and every login kept its old com.ccquota.agent.<login>.
drill_account_adopt_agent_left() {
  CAP=10
  local sb la dd conf t0 envf out
  sb="$WORK/acctag"; la="$sb/Users/alice/Library/LaunchAgents"; dd="$sb/LaunchDaemons"
  conf="$sb/Users/alice/.config/claude-fleet"
  mkdir -p "$la" "$sb/lc/loaded" "$sb/lc/stuck" "$dd" "$conf"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  cat > "$sb/launchctl" <<'LC'
#!/bin/bash
d="$FAKE_LC"; echo "$*" >> "$d/log"
case "$1" in
  bootout) l="${2##*/}"; [ -e "$d/stuck/$l" ] && exit 5; rm -f "$d/loaded/$l" ;;
  bootstrap) touch "$d/loaded/$(basename "$3" .plist)" ;;
  print) [ -e "$d/loaded/${2##*/}" ] ;;
esac
LC
  chmod +x "$sb/launchctl"
  python3 -c 'import plistlib, sys; plistlib.dump({"Label": "com.claude-fleet.dispatch", "ProgramArguments": ["/bin/true"]}, open(sys.argv[1], "wb"))' \
    "$la/com.claude-fleet.dispatch.plist"
  python3 -c 'import plistlib, sys; plistlib.dump({"Label": "com.ccquota.agent.alice", "ProgramArguments": ["/bin/true"],
    "EnvironmentVariables": {"CCQUOTA_HUB_URL": "https://hub.invalid", "CCQUOTA_FLEET": "1", "FLEET_CONF_DIR": sys.argv[2], "PATH": "/usr/bin"}},
    open(sys.argv[1], "wb"))' "$dd/com.ccquota.agent.alice.plist" "$conf"
  printf 'CCQUOTA_HUB_URL=https://hub.invalid\nCCQUOTA_TOKEN=drill-secret-alice\n' > "$conf/node.env"; chmod 600 "$conf/node.env"
  : > "$sb/lc/loaded/com.claude-fleet.dispatch"; : > "$sb/lc/loaded/com.ccquota.agent.alice"
  : > "$sb/lc/stuck/com.ccquota.agent.alice"
  printf '{"account": []}\n' > "$sb/table.json"
  envf="$sb/db/logins/alice.env"
  sup() { FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" FLEET_NODE_DAEMON_DIR="$dd" \
          FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json" \
          FLEET_NODE_LAUNCHCTL="$sb/launchctl" FLEET_NODE_BOOTOUT_WAIT=1 FAKE_LC="$sb/lc" FLEET_CREDSEP_ROOT_BASE="$sb/cred" \
          python3 "$BIN/fleet-node-supervisor.py" "$@"; }
  t0=$(now)
  # 1. the old agent will not unload: nothing half done, no env for the machine's agent
  sup account adopt alice >"$sb/adopt.out" 2>&1 && { WHY="adopt succeeded past an agent that did not unload"; return 1; }
  [ ! -e "$envf" ] || { WHY="a failed adopt left logins/alice.env — two agents would speak for alice"; return 1; }
  [ -f "$dd/com.ccquota.agent.alice.plist" ] && [ -f "$la/com.claude-fleet.dispatch.plist" ] \
    && [ -e "$sb/lc/loaded/com.claude-fleet.dispatch" ] || { WHY="a failed adopt did not put everything back"; return 1; }
  rm -f "$sb/lc/stuck/com.ccquota.agent.alice"
  # 2. adopt: the env for the machine's agent, the old agent in the attic, no token printed
  out=$(sup account adopt alice 2>&1) || { WHY="adopt failed once the agent unloads: $out"; return 1; }
  case "$out" in *drill-secret*) WHY="adopt printed the token"; return 1 ;; esac
  [ -f "$envf" ] && [ "$(ls -l "$envf" | cut -c1-10)" = "-rw-------" ] || { WHY="no logins/alice.env, or not 0600"; return 1; }
  grep -qx 'CCQUOTA_TOKEN=drill-secret-alice' "$envf" && grep -q '^FLEET_CONF_DIR=' "$envf" \
    || { WHY="logins/alice.env lacks the token or FLEET_CONF_DIR"; return 1; }
  [ ! -e "$dd/com.ccquota.agent.alice.plist" ] && [ ! -e "$sb/lc/loaded/com.ccquota.agent.alice" ] \
    || { WHY="the old agent still runs beside the machine's node program"; return 1; }
  # 3. release: the env goes, the old agent comes back loaded
  sup account release alice >/dev/null 2>&1 || { WHY="release failed"; return 1; }
  [ ! -e "$envf" ] || { WHY="release left logins/alice.env"; return 1; }
  [ -f "$dd/com.ccquota.agent.alice.plist" ] && [ -e "$sb/lc/loaded/com.ccquota.agent.alice" ] \
    || { WHY="release did not put the old agent back and loaded"; return 1; }
  SECS=$(since "$t0")
  WHAT="adopt 连账号自己的节点程序一起迁：旧 agent 卸不掉就全部放回、不写 logins/alice.env；卸得掉则写 600 的 env（含令牌、不打印）、旧 agent 进 attic；release 删 env、放回旧 agent"
}

drill_node_update_half() {
  CAP=20
  local sb t0 u tk cl out
  sb="$WORK/upd"; mkdir -p "$sb/root" "$sb/rel" "$sb/db" "$sb/Users/alice" "$sb/LaunchDaemons"
  mkdir -p "$sb/bin"; cp "$BIN/fleet-node-update.py" "$BIN/fleet-node-supervisor.py" "$sb/bin/"
  u="$sb/bin/fleet-node-update.py"; tk="$BIN/fleet-node-update-selftest.py"
  python3 "$tk" --fake-ccquota "$sb/ccquota" || { WHY="no fake ccquota"; return 1; }
  V1=$(printf '%040d' 0 | tr 0 1); V2=$(printf '%040d' 0 | tr 0 2); V3=$(printf '%040d' 0 | tr 0 3)
  python3 "$tk" --make-release "$sb/rel" "$V1" '{"claude":"2.1.1"}' \
    && python3 "$tk" --make-release "$sb/rel" "$V2" '{"claude":"2.1.2"}' \
    && python3 "$tk" --make-release "$sb/rel" "$V3" '{"claude":"2.1.3","broken":["claude-"]}' \
    || { WHY="fixtures not built"; return 1; }
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  printf '{"alice":{"uid":%s,"gid":%s,"home":"%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '{"alice":{"managed":true}}\n' > "$sb/db/accounts.json"
  printf 'CCQUOTA_HUB_URL=https://hub.invalid\n' > "$sb/db/machine.env"; printf 'ed25519 AAAA\n' > "$sb/db/release.pub"
  upd() { env FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/root/current" \
      FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_TABLE="$sb/table.json" FLEET_NODE_PASSWD="$sb/passwd.json" \
      FLEET_NODE_TEST=1 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_CCQUOTA="$sb/ccquota" FAKE_REL="$sb/rel" \
      FLEET_NODE_UPDATE_PLATFORM=darwin-arm64 FLEET_NODE_UPDATE_SETTLE=0 FLEET_NODE_UPDATE_LIB=/nonexistent "$@"; }
  # launchd's part: the daemon comes back on whatever `current` names
  daemon() { python3 -c 'import json,os,sys,time; json.dump({"supervisor":{"pid":os.getppid(),"heartbeat":time.time(),"runtime":sys.argv[2]}},open(sys.argv[1],"w"))' "$sb/db/state.json" "$(basename "$(readlink "$sb/root/current")")"; }
  on() { cl=$("$sb/root/current/tools/bin/claude" 2>/dev/null); [ "$(basename "$(readlink "$sb/root/current")")" = "$1" ] && [ "$cl" = "$2 (Claude Code)" ] \
      && [ "$("$sb/Users/alice/.local/bin/claude" 2>/dev/null)" = "$2 (Claude Code)" ] \
      && [ "$(cat "$sb/root/cache/claude/current" 2>/dev/null)" = "$2" ] \
      && [ "$("$sb/root/current/bin/ccquota")" = "ccquota prod-$(printf '%s' "$1" | cut -c1-7)" ]; }
  upd FLEET_NODE_UPDATE_TARGET="$V1" python3 "$u" tick >/dev/null && daemon && upd FLEET_NODE_UPDATE_TARGET="$V1" python3 "$u" tick >/dev/null
  on "$V1" 2.1.1 || { WHY="v1 never landed whole"; return 1; }
  # 1. killed half way through fetching v2: nothing moved, nothing half
  upd FLEET_NODE_UPDATE_TARGET="$V2" FAKE_SLOW=5 python3 "$u" tick >/dev/null 2>&1 &
  out=$!; until_ok 5 test -d "$sb/root/$V2.partial" || { WHY="the fetch never started"; return 1; }
  pkill -9 -f "$u tick"; pkill -9 -f "$sb/ccquota" 2>/dev/null; wait "$out" 2>/dev/null; t0=$(now)
  ! pgrep -f "$u tick" >/dev/null || { WHY="the tick survived kill -9"; return 1; }
  on "$V1" 2.1.1 || { WHY="a killed fetch left the machine half new"; return 1; }
  # 2. the next tick finishes it, whole
  upd FLEET_NODE_UPDATE_TARGET="$V2" python3 "$u" tick >/dev/null && daemon && upd FLEET_NODE_UPDATE_TARGET="$V2" python3 "$u" tick >/dev/null
  on "$V2" 2.1.2 || { WHY="the resumed update did not land every part"; return 1; }
  [ ! -e "$sb/root/$V2.partial" ] || { WHY="the cut-short fetch left $V2.partial"; return 1; }
  # 3. v3's Claude Code fails the doctor: every part back to v2, v3 skipped
  upd FLEET_NODE_UPDATE_TARGET="$V3" python3 "$u" tick >/dev/null && daemon
  out=$(upd FLEET_NODE_UPDATE_TARGET="$V3" python3 "$u" tick 2>&1)
  case "$out" in *rolled-back*claude*) ;; *) WHY="no rollback on a new FAIL: $out"; return 1 ;; esac
  on "$V2" 2.1.2 || { WHY="the rollback left a part on v3"; return 1; }
  daemon; out=$(upd FLEET_NODE_UPDATE_TARGET="$V3" python3 "$u" tick 2>&1)
  case "$out" in *skipped*) ;; *) WHY="the rejected release was tried again: $out"; return 1 ;; esac
  SECS=$(since "$t0")
  WHAT="更新取包时被 kill -9：整台机器原样不动；下一轮从头取完、所有部件一起换上；新版体检多出 FAIL（Claude Code 起不来）→ 运行时、ccquota、Claude、开号缓存、账号链接全部回到上一版，这一版不再重试"
}

# credsep-stale-after-switch (#2435): the updater moved `current` but credsep's
# root code copy and the shared proxy stayed on the old release.
drill_credsep_stale_after_switch() {
  CAP=60
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-credsep 2>&1) \
    || { WHY="the proxy did not follow the release: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="换版两次再回退一次：每次 credsep 副本的 sha = 发布版，守护的共享代理子进程用新副本重启（pid 换了），回退时副本和代理一起回旧版，不另写 plist"
}

drill_node_install_half() {
  CAP=30
  # its own subshell: the sandbox exports FLEET_NODE_* for every step it drives
  (
    TMPDIR="$WORK" FNI_LIB=1 . "$BIN/fleet-node-install-selftest.sh"
    sandbox
    res() { printf '%s\n%s\n%s\n' "${1:-}" "${2:-}" "${3:-}" > "$WORK/fni.res"; exit 0; }
    # 1. killed while the runtime is being fetched (a slow hub)
    FAKE_SLOW=5 bash "$INST" --hub https://hub.test --join "$CODE1" >/dev/null 2>&1 &
    p=$!
    until_ok 10 test -d "$SB/root/$V1.partial" || res "" "the fetch never started"
    pkill -9 -f "$INST" 2>/dev/null; pkill -9 -f "$BIN/fleet-node-update.py tick" 2>/dev/null
    pkill -9 -f "$SB/db/bin/ccquota" 2>/dev/null; wait "$p" 2>/dev/null
    t0=$(now)
    [ ! -e "$SB/root/current" ] || res "" "a killed install left a current"
    # 2. the same command, no code (the token is already the machine's): converged
    run
    [ "$RC" = 0 ] && line 已收敛 || res "" "the rerun did not converge: $(printf '%s' "$OUT" | grep '^✗' | head -n 1)"
    [ "$(basename "$(readlink "$SB/root/current")")" = "$V1" ] && [ -f "$SB/root/current/.release/staged.json" ] \
      || res "" "the rerun left a half release"
    [ "$(cat "$HUBD/joins")" = 1 ] || res "" "the rerun spent a second join"
    # 3. a part deleted later (the LaunchDaemon): only it comes back
    rm -f "$SB/LaunchDaemons/com.claude-fleet.node.plist" "$SB/loaded"
    run
    [ "$RC" = 0 ] && [ "$(shape)" = "+检查 -加入 -发布公钥 -期望状态 -ccquota -运行时 -角色用户 -ssh +守护 " ] \
      || res "" "a deleted daemon was not the only thing redone: $(shape)"
    clean || res "" "something half written was left: $(find "$SB" -name '*.partial' -o -name '*.tmp-*' | grep -v /rel/ | head -n 1)"
    res "$(since "$t0")" ""
  )
  { read -r SECS; read -r WHY; } < "$WORK/fni.res"
  WHAT="装到一半（取运行时时）被 kill -9：没有 current、没有半个发布版；同一条命令不带码重跑，从断处做完、不再花加入码；之后删掉守护的服务定义，重跑只补它一件"
}

cred_run_drills "$0"
