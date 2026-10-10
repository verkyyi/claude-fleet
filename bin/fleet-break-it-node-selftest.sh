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
#   task-fail-silent      bin/fleet-node-supervisor.py's agent tasks + bin/fleet-task-run.sh
#                         (#2529): a scheduled agent task's session will not open, every try
#   service-failed-unseen bin/fleet-services.py (#2526): a registered service that
#                         keeps dying reads red in the doctor + the alert bar
#   service-handwritten   bin/fleet-node-supervisor.py's sweep + bin/fleet-services.py --doctor
#                         (#2530): a hand-written launchd plist runs as a login beside the
#                         register — the doctor WARNs until it is registered and archived
#   task-rerun-root-only  bin/fleet-session-cli.py `fleet task run --now` → the hub's
#                         service_control → the node's fixed supervisor argv (#2527):
#                         a missed daily push is run again from the client, no root
#   account-adopt-stuck   bin/fleet-node-supervisor.py `account adopt|release` (#2332):
#                         one of a login's services will not unload mid-migration
#   tenant-admin-adopted  bin/fleet-node-supervisor.py `account adopt` + `tenants --check`
#                         + bin/fleet-doctor.sh's `tenants` row (#2842): an admin login
#                         taken over, or a taken-over login put in the admin group
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
#   shift-enter-sends     conf/tmux-shell.conf, conf/tmux-shell-stage.conf, conf/tmux-attention.conf
#                         (extended keys, #2760): ⇧↵ through the client's three tmux servers
#   release-fetch-slow    tokenledger/internal/release fetch.go (Fetcher: Cache, Platforms,
#                         Stall; go test, when a toolchain is here) + bin/fleet-node-update.py
#                         stage (#2701): a 700 MB release at ~1 MB/s against a whole-fetch
#                         deadline never landed, each try from zero
#   managed-login-install-stale  bin/fleet-install-sync.sh's managed branch +
#                         bin/fleet-node-update.py's `install` doctor row (#2688): a
#                         managed login's own ~/.claude/fleet sat on its bootstrap copy
#   managed-login-install-predates  bin/fleet-node-update.py follow_installs (#2714):
#                         a login install from before #2688 never follows — its own
#                         install-sync still answers off · managed
#   managed-login-own-copy  bin/fleet-node-update.py link-tree + follow_installs
#                         (#2774): a managed login pointed back at an own old copy
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

drill_task_fail_silent() {
  CAP=30   # the batch's bar is ≤ 1 h from the first failure; with no retry delay it is seconds
  local sb sup t0 ap
  sb="$WORK/task"; mkdir -p "$sb/LaunchDaemons" "$sb/Users/alice"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  # the session never opens (the prompt names no skill / the fleet is full): the spawner refuses every time
  printf '#!/bin/bash\necho "$*" >> "%s/calls"\necho "dash-raw-session: at capacity" >&2\nexit 2\n' "$sb" > "$sb/spawn.sh"
  chmod +x "$sb/spawn.sh"
  python3 -c 'import calendar; print(calendar.timegm((2026, 10, 10, 6, 59, 0)))' > "$sb/clock"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json" \
    FLEET_NODE_CLOCK="$sb/clock"
  python3 "$BIN/fleet-node-supervisor.py" service add --kind task --login alice --name daily --at 07:00 --tz UTC \
    --fleet drill-sandbox --prompt '/no-such-skill' --retries 2 --retry-delay 0 --env FLEET_TASK_SPAWN="$sb/spawn.sh" \
    >"$sb/add.out" 2>&1 || { WHY="task add failed: $(tail -2 "$sb/add.out" | tr '\n' ' ')"; return 1; }
  python3 -I "$BIN/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  python3 -c 'import calendar; print(calendar.timegm((2026, 10, 10, 7, 0, 1)))' > "$sb/clock"
  until_ok 10 test -s "$sb/calls" || { WHY="the slot never ran: $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; kill "$sup" 2>/dev/null; return 1; }
  t0=$(now); ap="$sb/db/logins/alice/alerts/daily.json"
  until_ok 30 test -f "$ap" || { WHY="no alert after the last try ($(wc -l < "$sb/calls") calls)"; kill "$sup" 2>/dev/null; return 1; }
  SECS=$(since "$t0"); sleep 1
  [ "$(wc -l < "$sb/calls" | tr -d ' ')" = 3 ] || { WHY="$(wc -l < "$sb/calls") tries, not 1 + 2 retries"; kill "$sup" 2>/dev/null; return 1; }
  python3 "$BIN/fleet-node-supervisor.py" status --json | python3 -c 'import json, sys; r = [x for x in json.load(sys.stdin)["services"] if x["name"] == "daily"][0]; assert r["status"] == "failed" and r["alert"] and "did not open" in r["last_error"], r' 2>"$sb/st.err" \
    || { WHY="services[] does not say failed: $(tail -1 "$sb/st.err")"; kill "$sup" 2>/dev/null; return 1; }
  kill "$sup" 2>/dev/null; wait "$sup" 2>/dev/null
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_PASSWD FLEET_NODE_CLOCK
  WHAT="定时 agent 任务的会话一次也开不了：到点开一次、重试 2 次后不再试，状态 failed、告警文件落地，services[] 带 failed 与原因"
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

drill_service_failed_unseen() {
  CAP=30   # the EPIC's bar is ≤ 1 hour from the first failure to a red reading; here, seconds
  local sb sup t0 d a
  sb="$WORK/svcfail"; mkdir -p "$sb/LaunchDaemons" "$sb/Users/alice"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  printf '#!/bin/bash\necho "give up: skill not found"\nexit 1\n' > "$sb/report.sh"; chmod +x "$sb/report.sh"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json"
  python3 "$BIN/fleet-node-supervisor.py" service add --login alice --name daily-report -- "$sb/report.sh" >"$sb/add.out" 2>&1 \
    || { WHY="service add failed: $(tail -2 "$sb/add.out" | tr '\n' ' ')"; return 1; }
  # before the daemon runs it: registered, never started — not a failure yet
  d=$(FLEET_SERVICES_CACHE='' FLEET_SERVICES_STATE="$sb/db/state.json" FLEET_SERVICES_LOGIN=alice python3 "$BIN/fleet-services.py" --doctor)
  case "$d" in FAIL*) WHY="red before it ever ran: $d"; return 1 ;; esac
  t0=$(now)
  python3 -I "$BIN/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  until_ok 30 sh -c 'FLEET_SERVICES_CACHE="" FLEET_SERVICES_STATE="$1" FLEET_SERVICES_LOGIN=alice python3 "$2" --doctor | grep -q "^FAIL 1/1 failed: alice/daily-report@"' \
      _ "$sb/db/state.json" "$BIN/fleet-services.py" \
    || { WHY="the dying service never read red in the doctor: $(FLEET_SERVICES_CACHE='' FLEET_SERVICES_STATE="$sb/db/state.json" FLEET_SERVICES_LOGIN=alice python3 "$BIN/fleet-services.py" --doctor)"; kill "$sup" 2>/dev/null; return 1; }
  SECS=$(since "$t0")
  a=$(FLEET_SERVICES_CACHE='' FLEET_SERVICES_STATE="$sb/db/state.json" FLEET_SERVICES_LOGIN=alice python3 "$BIN/fleet-services.py" --alerts)
  case "$a" in service-*-alice-daily-report*) ;; *) WHY="no alert line for it: [$a]"; kill "$sup" 2>/dev/null; return 1 ;; esac
  python3 "$BIN/fleet-node-supervisor.py" service rm --login alice --name daily-report >/dev/null
  kill "$sup" 2>/dev/null; wait "$sup" 2>/dev/null
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_PASSWD
  WHAT="登记的服务一启动就退：几秒内体检 services 行 FAIL、告警栏多一条 ✖ service · failed（入口另有 service_failed），不再是 40 小时没人知道"
}

drill_service_handwritten() {
  CAP=20   # two sweeps + three doctor reads
  local sb t0 d w
  sb="$WORK/svchand"; mkdir -p "$sb/LaunchDaemons" "$sb/Users/alice/bin" "$sb/Users/alice/Library/LaunchAgents"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  printf '#!/bin/bash\nsleep 300\n' > "$sb/Users/alice/bin/sms-watch"; chmod +x "$sb/Users/alice/bin/sms-watch"
  pl() {   # pl <file> <label> <user or ""> <program>
    python3 -c 'import plistlib, sys
d = {"Label": sys.argv[2], "ProgramArguments": [sys.argv[4]], "KeepAlive": True}
if sys.argv[3]: d["UserName"] = sys.argv[3]
plistlib.dump(d, open(sys.argv[1], "wb"))' "$@"
  }
  # the two hand-written ones (mini2, 2026-10-09: com.verkyyi.sms-watch, com.verky.daily-report) ...
  pl "$sb/LaunchDaemons/com.alice.sms-watch.plist" com.alice.sms-watch alice "$sb/Users/alice/bin/sms-watch"
  pl "$sb/Users/alice/Library/LaunchAgents/com.alice.daily-report.plist" com.alice.daily-report "" "$sb/Users/alice/bin/sms-watch"
  # ... and what is not a person's background task: a root daemon, a system account's, an app's own agent
  pl "$sb/LaunchDaemons/com.alice.net-tuning.plist" com.alice.net-tuning "" /usr/sbin/sysctl
  pl "$sb/LaunchDaemons/sh.brew.thing.plist" sh.brew.thing _brew /opt/homebrew/bin/thing
  pl "$sb/Users/alice/Library/LaunchAgents/com.vendor.updater.plist" com.vendor.updater "" "$sb/Users/alice/Library/Application Support/Vendor/updater"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json"
  # the sweep looks only at the logins the daemon took over (#2702)
  mkdir -p "$sb/db/logins"; : > "$sb/db/logins/alice.env"
  doc() { FLEET_SERVICES_CACHE='' FLEET_SERVICES_STATE="$sb/db/state.json" FLEET_SERVICES_LOGIN=alice python3 "$BIN/fleet-services.py" --doctor; }
  t0=$(now)
  python3 "$BIN/fleet-node-supervisor.py" sweep >"$sb/sweep1.out" 2>&1 \
    || { WHY="sweep failed: $(tail -2 "$sb/sweep1.out" | tr '\n' ' ')"; return 1; }
  d=$(doc)
  case "$d" in "WARN 2 个手写启动项"*com.alice.sms-watch*) ;; *) WHY="the two hand-written plists did not read WARN 2: [$d] (sweep: $(tr '\n' ' ' < "$sb/sweep1.out"))"; return 1 ;; esac
  case "$d" in *net-tuning*|*brew*|*vendor*) WHY="counted what is not a person's task: [$d]"; return 1 ;; esac
  w=$(python3 "$BIN/fleet-node-supervisor.py" status | grep -c '^handwritten ')
  [ "$w" = 2 ] || { WHY="status names $w hand-written plists, not 2"; return 1; }
  # 收编: register it, then archive the plist — the next sweep has nothing left
  python3 "$BIN/fleet-node-supervisor.py" service add --login alice --name sms-watch -- "$sb/Users/alice/bin/sms-watch" >"$sb/add.out" 2>&1 \
    || { WHY="service add failed: $(tail -2 "$sb/add.out" | tr '\n' ' ')"; return 1; }
  d=$(doc)
  case "$d" in WARN*) ;; *) WHY="registered but the plist still loaded, yet no WARN: [$d]"; return 1 ;; esac
  mkdir -p "$sb/attic"; mv "$sb/LaunchDaemons/com.alice.sms-watch.plist" "$sb/Users/alice/Library/LaunchAgents/com.alice.daily-report.plist" "$sb/attic/"
  python3 "$BIN/fleet-node-supervisor.py" sweep >/dev/null 2>&1
  d=$(doc)
  case "$d" in WARN*|FAIL*) WHY="still not green once archived: [$d]"; return 1 ;; esac
  SECS=$(since "$t0")
  python3 "$BIN/fleet-node-supervisor.py" service rm --login alice --name sms-watch >/dev/null 2>&1
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_PASSWD
  WHAT="手写的 plist 以某个登录跑、登记表里没有：整机守护的清扫点名、体检 services 行 WARN；登记并归档后转绿（root 的、系统账号的、应用自带的不算）"
}

drill_task_rerun_root_only() {
  CAP=60   # the issue's bar: the session is there within a minute of `fleet task run --now`
  local sb sup t0 out
  sb="$WORK/rerun"; mkdir -p "$sb/LaunchDaemons" "$sb/Users/alice"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  printf '#!/bin/bash\necho "$*" >> "%s/calls"\nprintf "@7\\tdaily\\t\\tfid\\n"\n' "$sb" > "$sb/spawn.sh"
  chmod +x "$sb/spawn.sh"
  # noon: today's 07:00 slot is long past and was never this entry's — nothing runs on its own
  python3 -c 'import calendar; print(calendar.timegm((2026, 10, 10, 12, 0, 0)))' > "$sb/clock"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json" \
    FLEET_NODE_CLOCK="$sb/clock"
  python3 "$BIN/fleet-node-supervisor.py" service add --kind task --login alice --name daily --at 07:00 --tz UTC \
    --fleet drill-sandbox --prompt '/daily-report' --env FLEET_TASK_SPAWN="$sb/spawn.sh" \
    >"$sb/add.out" 2>&1 || { WHY="task add failed: $(tail -2 "$sb/add.out" | tr '\n' ' ')"; return 1; }
  python3 -I "$BIN/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  sleep 1
  [ ! -s "$sb/calls" ] || { WHY="a past slot ran by itself"; kill "$sup" 2>/dev/null; return 1; }
  # the client's table says where the entry lives; the "hub" stands in for the
  # node half the agent runs for service_control (node_service_ctl.go): its
  # fixed supervisor argv, on the lane's own login
  printf '{"ts": 1, "machines": [{"hostname": "m4.drill", "label": "m4", "services": [{"name": "daily", "kind": "task", "login": "alice", "state": "scheduled"}]}]}\n' > "$sb/hub_services"
  {
    printf '#!/bin/bash\n[ "$1" = service_control ] || exit 9\n'
    printf 'if python3 -I %q service run --login alice --name daily >/dev/null 2>%q; then\n' "$BIN/fleet-node-supervisor.py" "$sb/hub.err"
    printf '  echo %q\nelse\n  echo %q\nfi\n' '{"operation_id":"op","status":"succeeded","result":{"how":"service run"}}' \
      '{"operation_id":"op","status":"failed","result":{"error":{"code":"REFUSED","message":"supervisor refused"}}}'
  } > "$sb/hub.sh"
  chmod +x "$sb/hub.sh"
  t0=$(now)
  out=$(FLEET_SERVICES_CACHE="$sb/hub_services" FLEET_SERVICES_STATE='' FLEET_SESSION_CLI_WRITE="$sb/hub.sh" \
        python3 "$BIN/fleet-session-cli.py" task run daily --now 2>&1) \
    || { WHY="fleet task run --now: $out $(cat "$sb/hub.err" 2>/dev/null)"; kill "$sup" 2>/dev/null; return 1; }
  until_ok 60 test -s "$sb/calls" || { WHY="no session opened: $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; kill "$sup" 2>/dev/null; return 1; }
  SECS=$(since "$t0")
  grep -q -- '--name daily-2026-10-10-now1200' "$sb/calls" \
    || { WHY="the run took the slot's window: $(cat "$sb/calls")"; kill "$sup" 2>/dev/null; return 1; }
  kill "$sup" 2>/dev/null; wait "$sup" 2>/dev/null
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_PASSWD FLEET_NODE_CLOCK
  WHAT="漏了一次的定时任务从客户端补跑：fleet task run --now → service_control → 节点固定 argv 的 service run，几秒内会话打开（自己的窗口名 …-now<时分>），不再要 root 上机器 kickstart"
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

# tenant-admin-adopted (#2842): what a session may destroy is its login's ability,
# so a taken-over login that can sudo is the whole guarantee gone. adopt refuses an
# admin (5, nothing moved); a tenant that LATER joins admin reads FAIL on the
# doctor's row, and PASS again once it is out.
drill_tenant_admin_adopted() {
  CAP=10
  local sb t0 rc
  sb="$WORK/tenant-admin"; mkdir -p "$sb/LaunchDaemons" "$sb/db/logins" "$sb/Users/alice" "$sb/Users/bob/Library/LaunchAgents"
  python3 -c 'import plistlib, sys; plistlib.dump({"Label": "com.claude-fleet.cleanup", "ProgramArguments": ["/bin/true"]}, open(sys.argv[1], "wb"))' \
    "$sb/Users/bob/Library/LaunchAgents/com.claude-fleet.cleanup.plist"
  pw() { printf '{"alice": {"uid": %s, "gid": %s, "home": "%s", "groups": [%s]}, "bob": {"uid": %s, "gid": %s, "home": "%s", "groups": ["staff", "admin"], "sudo": "(ALL) NOPASSWD: ALL"}}\n' \
         "$(id -u)" "$(id -g)" "$sb/Users/alice" "$1" "$(id -u)" "$(id -g)" "$sb/Users/bob" > "$sb/passwd.json"; }
  sup() { FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" \
          FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json" FLEET_NODE_LAUNCHCTL='' \
          python3 "$BIN/fleet-node-supervisor.py" "$@"; }
  grep -q 'tenants --check' "$BIN/fleet-doctor.sh" && grep -q 'fail tenants' "$BIN/fleet-doctor.sh" \
    || { WHY="fleet-doctor.sh has no tenants row"; return 1; }
  t0=$(now)
  pw '"staff"'
  sup account adopt bob >"$sb/adopt.out" 2>&1; rc=$?
  [ "$rc" = 5 ] || { WHY="adopt of an admin login exited $rc, not 5: $(head -c 200 "$sb/adopt.out")"; return 1; }
  [ -e "$sb/Users/bob/Library/LaunchAgents/com.claude-fleet.cleanup.plist" ] || { WHY="a refused adopt moved bob's service"; return 1; }
  : > "$sb/db/logins/alice.env"
  sup tenants --check >/dev/null 2>&1 || { WHY="a clean tenant does not PASS"; return 1; }
  pw '"staff", "admin"'
  sup tenants --check >"$sb/fail.out" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q 'alice: admin' "$sb/fail.out" || { WHY="a tenant in the admin group reads rc $rc: $(head -c 200 "$sb/fail.out")"; return 1; }
  pw '"staff"'
  sup tenants --check >/dev/null 2>&1 || { WHY="still FAIL once alice left the admin group"; return 1; }
  SECS=$(since "$t0")
  WHAT="接管管理员登录被拒（退 5、什么没挪）；已接管的登录进了 admin 组 → tenants FAIL 写明是谁，撤出后回到 PASS"
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

# ---- release-fetch-slow (#2701): a new managed machine's release fetch at ~1 MB/s.
# Before: ccquota's 10-minute whole-body deadline cut a 700 MB fetch (every artifact
# the hub carries, every platform and old version), dest.partial was deleted and
# the next try began at zero, after an hour's backoff. Now: only release.json's
# pins for this machine, each artifact resumed from <root>/.fetch, cut only after
# 30 s without a byte, no backoff when the fetch moved. The updater half is its
# Python case (L_ResumableFetch); the ccquota half its Go tests, run where a
# toolchain is.
drill_release_fetch_slow() {
  CAP=120; local t0 out rc tests f
  tests='TestFetchResumesAfterStall TestFetchResumesAcrossRuns TestFetchPinnedOnly TestFetchCachedNotRefetched TestFetchSlowButSteady'
  f="$ROOT/tokenledger/internal/release/fetch_test.go"
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the ccquota half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-fetch 2>&1) \
    || { WHY="the updater half: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  WHAT='更新器：只取本机钉住的制品、缓存先填已有的、断了不退避下一轮接着取'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/release 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the ccquota half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT="${WHAT}；ccquota：静默 30 秒才断、同一次和下一次都从断点续传、慢而不停不超时、已缓存不重下（go test 五条）" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT="${WHAT}；ccquota 的 Go 测试这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们" ;;
      *) WHY="the ccquota half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT="${WHAT}；没有 go：五条测试按名核对在，Go 门（tokenledger.yml）跑它们"
  fi
  SECS=$(since "$t0")
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

# managed-login-install-stale (#2688): the machine moved to a release, a managed
# login's ~/.claude/fleet (what every account task runs) stayed on its old commit
# — its install-sync tick answered `off · managed` and the updater never moved it.
# Since #2774 the updater links it to the runtime and moves it with the machine;
# the login's own tick says so (off · managed · 跟随 <root>/current, no fetch) and
# the machine doctor's install row WARNs until it is linked.
drill_managed_login_install_stale() {
  CAP=60
  local sb seed co c1 c2 t0 out g
  sb="$WORK/mlis"; seed="$sb/seed"; co="$sb/home/.claude/fleet"
  mkdir -p "$sb/home/.claude" "$sb/conf" "$sb/db" "$sb/noderoot" "$sb/tmp"
  : > "$sb/gitconfig"
  g() { GIT_CONFIG_GLOBAL="$sb/gitconfig" GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
        GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git "$@"; }
  g init -q --bare -b master "$sb/origin.git" && g clone -q "$sb/origin.git" "$seed" 2>/dev/null \
    || { WHY="no sandbox repo"; return 1; }
  echo 1 > "$seed/f"; g -C "$seed" add -A; g -C "$seed" commit -qm one; c1=$(g -C "$seed" rev-parse HEAD)
  echo 2 > "$seed/f"; g -C "$seed" commit -qam two; c2=$(g -C "$seed" rev-parse HEAD)
  g -C "$seed" push -q origin master && g --git-dir="$sb/origin.git" update-ref refs/tags/stable "$c2"
  g clone -q "$sb/origin.git" "$co" 2>/dev/null && g -C "$co" reset -q --hard "$c1"
  printf '{"%s": {"managed": true}}\n' "$(id -un)" > "$sb/db/accounts.json"
  ln -s "$sb/noderoot/$c2" "$sb/noderoot/current"     # the machine is on c2
  t0=$(now)
  out=$(env -i PATH="$PATH" HOME="$sb/home" FLEET_CONF_DIR="$sb/conf" TMPDIR="$sb/tmp" FLEET_SKIP_GLOBAL_CONF=1 \
        FLEET_NODE_STATE="$sb/db" FLEET_NODE_ROOT="$sb/noderoot" GIT_CONFIG_GLOBAL="$sb/gitconfig" GIT_CONFIG_SYSTEM=/dev/null \
        bash "$BIN/fleet-install-sync.sh" --root "$co" 2>&1) || { WHY="the tick failed: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 1; }
  grep -q "^reason: managed · 跟随 $sb/noderoot/current" "$sb/conf/global/install-sync.state" \
    || { WHY="the managed login's tick does not name what it follows: $(sed -n 's/^reason: //p' "$sb/conf/global/install-sync.state")"; return 1; }
  [ "$(g -C "$co" rev-parse HEAD)" = "$c1" ] || { WHY="the login's own tick moved its copy (the updater's, #2774)"; return 1; }
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-login-install 2>&1) \
    || { WHY="the machine doctor does not name a stale login install: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="整机在新发布版、托管登录的 ~/.claude/fleet 还在旧提交：登录自己的一拍答 off · managed · 跟随 <root>/current（不再自己去取），fleet doctor --machine 的 install 行未链接到发布版时 WARN、链接到位 PASS"
}

# managed-login-install-predates (#2714): the login's own install is older than
# #2688, so its install-sync — the code that would move it — still answers
# `off · managed`. The updater (root, always the release's code) moves it: since
# #2774 by linking it to the runtime (link-tree), at the switch, the rollback and
# every tick at the release.
drill_managed_login_install_predates() {
  CAP=60
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-login-follow 2>&1) \
    || { WHY="the updater did not move a login install behind the release: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="登录安装早于 #2688（自己的 install-sync 仍答 off · managed）：更新器在换版那一拍把每个托管登录的 ~/.claude/fleet 换成链接到 <root>/<sha> 的目录树并跑新版 apply（两目录模式），退回时一起退回，接管时当场做；放手时换回独立副本；钉在版本目录的客户端壳镜像改走登录链接"
}

# managed-login-own-copy (#2774): a managed login's ~/.claude/fleet pointed back
# by hand at an own old copy (or left on its bootstrap copy) no longer moves with
# the machine. The machine doctor WARNs (never FAIL), and the next update tick
# links it to the release again — unless an EPIC batch with work holds it.
drill_managed_login_own_copy() {
  CAP=60
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-login-own-copy 2>&1) \
    || { WHY="a login pointed at an own copy was not linked back: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="托管登录被手动指回一份独立旧副本：fleet doctor --machine 的 install 行 WARN（不 FAIL、不回退整机），下一拍更新器把它重新链接到发布版；有活的批次在跑时先等（同 2 小时封顶）；换版一次两个登录一起链接、体检 FAIL 一起退回、每个登录目录 < 1 MB"
}

# shift-enter-sends (issue #2760): ⇧↵ typed into the client went through three tmux
# servers (the client, its stage, the machine's fleet session) none of which asked
# for extended keys, so it reached Claude as a bare ↵ and sent half a sentence. The
# drill renders the three real confs as fleet-shell.sh fills them, nests them on
# sockets of its own, types ⇧↵ (CSI 13;2u) into an outer pty and reads what the
# session's pane — asking for keys the way Claude Code does — received: ⇧↵ itself;
# FLEET_KEYS_PARITY=0 (the client's two confs without it) is not ⇧↵, as
# before. Here, not in fleet-break-it-selftest.sh: that run sits at the gate's cap.
drill_shift_enter_sends() {
  CAP=30; local d t0 got par s ROOT REAL_TMUX
  ROOT="$(cd "$BIN/.." && pwd)"; REAL_TMUX=$(command -v tmux 2>/dev/null)
  [ -n "$REAL_TMUX" ] || { WHY="no tmux"; return 1; }
  d=$(mktemp -d /tmp/brk-keys.XXXXXX) || { WHY="mktemp"; return 1; }   # AF_UNIX: a short path
  cat > "$d/rec.py" <<'PY'
import os, sys, tty
tty.setraw(0)
os.write(1, b"\x1b[>4;2m\x1b[>5u\x1b[?2004hREADY\r\n")
with open(sys.argv[1], "ab", buffering=0) as f:
    while True:
        d = os.read(0, 1024)
        if not d:
            break
        f.write(d.hex().encode() + b"\n")
PY
  cat > "$d/term.py" <<'PY'
import fcntl, os, pty, re, select, struct, subprocess, sys, termios, time
tm, d = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM="xterm-256color", HOME=d); os.environ.pop("TMUX", None)
    os.execvp(tm, [tm, "-S", d + "/s", "attach", "-t", "shell"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
ANS = ((rb"\x1b\[>0?q", b"\x1bP>|iTerm2 3.6.6\x1b\\"), (rb"\x1b\[>0?c", b"\x1b[>0;95;0c"),
       (rb"\x1b\[0?c", b"\x1b[?62;22c"), (rb"\x1b\[\?996n", b"\x1b[?997;1n"),
       (rb"\x1b\]10;\?", b"\x1b]10;rgb:c0c0/caca/f5f5\x1b\\"), (rb"\x1b\]11;\?", b"\x1b]11;rgb:1a1a/1b1b/2626\x1b\\"))
def pump(secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.03)
        if r:
            try: b = os.read(fd, 65536)
            except OSError: return
            for q, a in ANS:
                if re.search(q, b): os.write(fd, a)
for _ in range(150):
    pump(0.1)
    if "READY" in subprocess.run([tm, "-S", d + "/n", "capture-pane", "-p", "-t", "node"], capture_output=True, text=True).stdout:
        break
pump(0.8)
open(d + "/rec.out", "w").close()
os.write(fd, b"\x1b[13;2u")
end = time.time() + 4
while time.time() < end and not os.path.getsize(d + "/rec.out"):
    pump(0.02)
pump(0.3)
print("".join(open(d + "/rec.out").read().split()))
os.kill(pid, 9)
PY
  t0=$(now)
  for par in 1 0; do
    mkdir -p "$d/conf"
    for s in tmux-shell tmux-shell-stage tmux-attention fleet-palette tmux-bar tmux-node-human; do
      sed -e "s#__BIN__#$BIN#g" -e "s#__PARITY__#$par#g" -e 's#__PREFIX__#C-b#g' -e 's#__STAGE__#kst#g' \
          -e 's#__SESS__#ks#g' -e 's#__PASTE__#0#g' -e '/^set-hook -g /d' -e '/^run-shell /d' \
          "$ROOT/conf/$s.conf" > "$d/conf/$s.conf"
    done
    HOME="$d" "$REAL_TMUX" -S "$d/n" -f "$d/conf/tmux-attention.conf" new-session -d -s node -x 96 -y 24 \
      "python3 $d/rec.py $d/rec.out"
    HOME="$d" "$REAL_TMUX" -S "$d/n" set -t node prefix None
    HOME="$d" "$REAL_TMUX" -S "$d/st" -f "$d/conf/tmux-shell-stage.conf" new-session -d -s stage -x 98 -y 26 \
      "TMUX= exec $REAL_TMUX -S $d/n attach -t node"
    HOME="$d" "$REAL_TMUX" -S "$d/s" -f "$d/conf/tmux-shell.conf" new-session -d -s shell -x 100 -y 28 \
      "TMUX= exec $REAL_TMUX -S $d/st attach -t stage"
    got=$(python3 "$d/term.py" "$REAL_TMUX" "$d" 2>/dev/null)
    for s in s st n; do "$REAL_TMUX" -S "$d/$s" kill-server 2>/dev/null; done
    if [ "$par" = 1 ] && [ "$got" != 1b5b31333b3275 ]; then
      rm -rf "$d"; WHY="⇧↵ reached the session as [$got] — not ⇧↵ (1b5b31333b3275; 0d = ↵, it sends)"; return 1
    fi
    # off: not ⇧↵ — as before (a bare ↵ here; an older tmux drops the key)
    if [ "$par" = 0 ] && [ "$got" = 1b5b31333b3275 ]; then
      rm -rf "$d"; WHY="FLEET_KEYS_PARITY=0 still hands ⇧↵ on — not as before"; return 1
    fi
  done
  rm -rf "$d"
  SECS=$(since "$t0"); WHAT="⇧↵ 穿过客户端、stage、节点三层 tmux 到会话还是 ⇧↵（扩展键）；关掉开关就不再是 ⇧↵，如今天"
}

cred_run_drills "$0"
