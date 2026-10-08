#!/bin/bash
# fleet-break-it-cred-shared-selftest.sh — docs/BREAK-IT.md row `cred-shared-down`
# (issue #2217): the machine's ONE shared credential proxy dies, and every
# login's sessions come back. Split from bin/fleet-break-it-cred-selftest.sh
# (whose helpers it sources, BREAK_CRED_LIB=1) because that run sits at the
# macOS per-test cap; bin/fleet-break-it-selftest.sh's lockstep lint reads the
# drill_cred_* names here too.
#
#   cred-shared-down    bin/fleet-credsep.py machine (the shared service's KeepAlive +
#                       ThrottleInterval), bin/fleet-credsep-launch.py shared,
#                       bin/fleet-cred-proxy.py serve --shared, bin/fleet-cred-proxy.sh mint
#   cred-sep-pick-refused   bin/fleet-cred-proxy.py mint / rebind (issue #2412): a separated
#                       login names no account; only root pins; bin/fleet-session-cred.sh rebind
#   cred-sep-acct-full  bin/fleet-cred-proxy.py pick_account / repick / limit_until (issue
#                       #2412): a quota 429 moves the same request to the account with room
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT / CP are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

drill_cred_shared_down() {
  CAP=10   # kill -9 → both logins' sessions answered again: the service's own restart delay + a python start
  local sb me uid gid port ta tb pid1 t0 thr sup
  me=$(id -un); uid=$(id -u); gid=$(id -g); sb="$WORK/shared"
  mkdir -p "$sb/daemons"
  cred_rig shared trusted reachable || return 1
  for L in alpha beta; do
    mkdir -p "$sb/homes/$L/.config/claude-fleet/accounts/a1.hub" "$sb/homes/$L/.claude/fleet/bin"
    printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat-%s"}}' "$L" > "$sb/homes/$L/.config/claude-fleet/accounts/a1.hub/.credentials.json"
  done
  printf 'alpha:%s:%s:%s\nbeta:1999992:%s:%s\n' "$uid" "$gid" "$sb/homes/alpha" "$gid" "$sb/homes/beta" > "$sb/pw"
  port=$(cred_deadport)
  export FLEET_CREDSEP_ROOT_BASE="$sb/db" FLEET_CREDSEP_RUN_BASE="$sb/run" FLEET_CREDSEP_LOG_BASE="$sb/log" \
    FLEET_CREDSEP_LIB="$sb/lib" FLEET_CREDSEP_DAEMON_DIR="$sb/daemons" FLEET_CREDSEP_ROLE="$me" \
    FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_PREFLIGHT=0 FLEET_CREDSEP_SUDO='' FLEET_CREDSEP_PW="$sb/pw" \
    FLEET_CRED_SHARED_PORT="$port" FLEET_CRED_ANTHROPIC_URL="$CU/direct-anthropic"
  bash "$BIN/fleet-credsep.sh" machine install --logins alpha,beta >"$sb/install.out" 2>&1 \
    || { WHY="machine install failed: $(tail -2 "$sb/install.out" | tr '\n' ' ')"; return 1; }
  # the restart delay the shipped service carries (launchd ThrottleInterval / systemd RestartSec)
  thr=$(python3 -c 'import plistlib, re, sys
p = sys.argv[1]
try:
    print(plistlib.load(open(p, "rb")).get("ThrottleInterval", 10))
except Exception:
    m = re.search(r"RestartSec=(\d+)", open(p).read()); print(m.group(1) if m else 10)' "$(ls "$sb/daemons"/*cred-proxy-shared* | head -n 1)")
  # launchd / systemd's part, played here: start it, and again $thr s after it dies
  ( while :; do python3 -I "$sb/lib/fleet-credsep-launch.py" shared 2>>"$sb/launch.err"; sleep "$thr"; done ) 2>/dev/null &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  until_ok 30 test -S "$sb/run/.shared/ctl.sock" || { WHY="the shared proxy did not start: $(tail -2 "$sb/launch.err" | tr '\n' ' ')"; return 1; }
  until_ok 5 test -s "$sb/run/.shared/pid"; pid1=$(cat "$sb/run/.shared/pid"); CP="$port"
  ta=$(FLEET_CONF_DIR="$sb/homes/alpha/.config/claude-fleet" bash "$BIN/fleet-cred-proxy.sh" mint --account a1 --sid sa)
  tb=$(FLEET_CRED_TEST_PEER_UID=1999992 FLEET_CONF_DIR="$sb/homes/beta/.config/claude-fleet" bash "$BIN/fleet-cred-proxy.sh" mint --account a1 --sid sb)
  [ "$(cred_req "$ta" "$sb/ra")" = 200 ] && [ "$(cred_req "$tb" "$sb/rb")" = 200 ] \
    || { WHY="before the kill: $(cat "$sb/ra" "$sb/rb")"; return 1; }
  kill -9 "$pid1"; t0=$(now)
  [ "$(cred_req "$ta" "$sb/ra")" = 000 ] || { WHY="the kill did not take the proxy down"; return 1; }
  until_ok 60 sh -c '[ "$(curl -s -m 5 -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $1" -d "{}" "http://127.0.0.1:$3/v1/messages")" = 200 ] && [ "$(curl -s -m 5 -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $2" -d "{}" "http://127.0.0.1:$3/v1/messages")" = 200 ]' _ "$ta" "$tb" "$port" \
    || { WHY="the sessions never came back after the kill -9 (pid now: $(cat "$sb/run/.shared/pid" 2>/dev/null))"; return 1; }
  SECS=$(since "$t0")
  [ "$(cat "$sb/run/.shared/pid")" != "$pid1" ] || { WHY="the same pid answers — nothing was killed?"; return 1; }
  kill "$sup" 2>/dev/null; kill "$(cat "$sb/run/.shared/pid" 2>/dev/null)" 2>/dev/null
  unset FLEET_CREDSEP_ROOT_BASE FLEET_CREDSEP_RUN_BASE FLEET_CREDSEP_LOG_BASE FLEET_CREDSEP_LIB FLEET_CREDSEP_DAEMON_DIR \
    FLEET_CREDSEP_ROLE FLEET_CREDSEP_SVC FLEET_CREDSEP_TEST FLEET_CREDSEP_SUDO FLEET_CREDSEP_PW FLEET_CRED_SHARED_PORT
  WHAT="全机共享代理 kill -9：两个登录的会话一起断，服务按自带的 ${thr}s 重启间隔拉起（同一端口 ${port}、各自的钥匙），两边原凭据下一请求都 200"
}

# shared_up <name> — the machine's shared proxy for ONE separated login, alpha,
# holding two pool accounts a1 / a2 (tokens sk-ant-oat-a1 / -a2), in $WORK/<name>;
# sets SB, CA (alpha's conf), CP (the port). The fake far end answers each token
# by $CD/accts.json (cred_fake).
shared_up() {
  local me uid gid port
  me=$(id -un); uid=$(id -u); gid=$(id -g); SB="$WORK/$1"
  mkdir -p "$SB/daemons"
  cred_rig "$1" trusted reachable || return 1
  CA="$SB/homes/alpha/.config/claude-fleet"
  mkdir -p "$SB/homes/alpha/.claude/fleet/bin"
  for a in a1 a2; do
    mkdir -p "$CA/accounts/$a.hub"
    printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat-%s","expiresAt":4102444800000}}' "$a" > "$CA/accounts/$a.hub/.credentials.json"
    printf 'hub:%s\n' "$a" > "$CA/accounts/$a"
  done
  printf 'alpha:%s:%s:%s\n' "$uid" "$gid" "$SB/homes/alpha" > "$SB/pw"
  port=$(cred_deadport)
  export FLEET_CREDSEP_ROOT_BASE="$SB/db" FLEET_CREDSEP_RUN_BASE="$SB/run" FLEET_CREDSEP_LOG_BASE="$SB/log" \
    FLEET_CREDSEP_LIB="$SB/lib" FLEET_CREDSEP_DAEMON_DIR="$SB/daemons" FLEET_CREDSEP_ROLE="$me" \
    FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_PREFLIGHT=0 FLEET_CREDSEP_SUDO='' FLEET_CREDSEP_PW="$SB/pw" \
    FLEET_CRED_SHARED_PORT="$port" FLEET_CRED_ANTHROPIC_URL="$CU/direct-anthropic"
  bash "$BIN/fleet-credsep.sh" machine install --logins alpha >"$SB/install.out" 2>&1 \
    || { WHY="machine install failed: $(tail -2 "$SB/install.out" | tr '\n' ' ')"; return 1; }
  python3 -I "$SB/lib/fleet-credsep-launch.py" shared 2>>"$SB/launch.err" &
  printf '%s\n' "$!" >> "$WORK/cred-pids"
  until_ok 30 test -S "$SB/run/.shared/ctl.sock" || { WHY="the shared proxy did not start: $(tail -2 "$SB/launch.err" | tr '\n' ' ')"; return 1; }
  until_ok 5 test -s "$SB/run/.shared/pid"; printf '%s\n' "$(cat "$SB/run/.shared/pid")" >> "$WORK/cred-pids"
  CP="$port"
}
shared_down() {
  kill "$(cat "$SB/run/.shared/pid" 2>/dev/null)" 2>/dev/null
  unset FLEET_CREDSEP_ROOT_BASE FLEET_CREDSEP_RUN_BASE FLEET_CREDSEP_LOG_BASE FLEET_CREDSEP_LIB FLEET_CREDSEP_DAEMON_DIR \
    FLEET_CREDSEP_ROLE FLEET_CREDSEP_SVC FLEET_CREDSEP_TEST FLEET_CREDSEP_SUDO FLEET_CREDSEP_PW FLEET_CRED_SHARED_PORT
}
# acct_of <token> → the account a session credential names ("" = none)
acct_of() { python3 -c 'import base64, json, sys
p = sys.argv[1].split(".")[1]; print(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))).get("acct", ""))' "$1"; }

# cred-sep-pick-refused (issue #2412): a separated login no longer chooses its
# subscription. Before, `mint --account` bound the session to whatever the login
# said and `rebind` moved it anywhere it liked — the login was the one picking,
# and picking blind (every account auth:no_credentials, no quota row) parked
# every new session on a 99% account. Now: the credential names no account, a
# rebind from the login is refused, and only root pins.
drill_cred_sep_pick_refused() {
  CAP=10
  local tok out rc t0
  shared_up pickrefused || return 1
  t0=$(now)
  tok=$(FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-proxy.sh" mint --provider claude --account a1 --sid s1 2>&1)
  case "$tok" in fcp1.*) ;; *) WHY="mint failed: $tok"; shared_down; return 1 ;; esac
  [ -z "$(acct_of "$tok")" ] || { WHY="the login's --account still bound the session: acct=$(acct_of "$tok")"; shared_down; return 1; }
  out=$(FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-proxy.sh" rebind --sid s1 --account a2 2>&1); rc=$?
  [ "$rc" != 0 ] && case "$out" in *"only root pins"*) true ;; *) false ;; esac \
    || { WHY="the login's rebind was taken (rc $rc): $out"; shared_down; return 1; }
  out=$(FLEET_CONF_DIR="$CA" FLEET_CRED_PROXY=1 bash "$BIN/fleet-session-cred.sh" rebind --sid s1 --account a2 2>&1); rc=$?
  [ "$rc" = 2 ] || { WHY="fleet-session-cred.sh rebind did not refuse (rc $rc): $out"; shared_down; return 1; }
  SECS=$(since "$t0")
  out=$(FLEET_CRED_TEST_PEER_UID=0 FLEET_CRED_AS=alpha FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-proxy.sh" rebind --sid s1 --account a2 2>&1) \
    || { WHY="root could not pin: $out"; shared_down; return 1; }
  [ "$(cred_req "$tok" "$SB/r")" = 200 ] && grep -q 'sk-ant-oat-a2' "$SB/r" \
    || { WHY="root's pin did not take: $(cat "$SB/r")"; shared_down; return 1; }
  grep -q '"ev": "mint_account_ignored"' "$SB/log/alpha.log" || { WHY="the ignored --account left no log line"; shared_down; return 1; }
  shared_down
  WHAT="隔离登录 mint --account a1：凭据里不带账号、记一行 mint_account_ignored；登录 rebind 被拒（代理与 fleet-session-cred.sh 都拒，exit 2）；root rebind 钉到 a2，下一请求就用 a2"
}

# cred-sep-acct-full (issue #2412): the account a separated session runs on hits
# its weekly limit. Before, the session sat on the 429 until the login rotated
# (and a separated login could not tell — it never saw a quota row). Now the
# proxy takes the 429, marks the account limited until its reset, and sends the
# SAME request on the account with room: the session's credential, process and
# window never change.
drill_cred_sep_acct_full() {
  CAP=10
  local tok code t0 first other
  shared_up acctfull || return 1
  printf '{"sk-ant-oat-a1":{"u7":40},"sk-ant-oat-a2":{"u7":40}}' > "$CD/accts.json"
  tok=$(FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-proxy.sh" mint --provider claude --sid s1 2>&1)
  case "$tok" in fcp1.*) ;; *) WHY="mint failed: $tok"; shared_down; return 1 ;; esac
  [ "$(cred_req "$tok" "$SB/r")" = 200 ] || { WHY="the first request: $(cat "$SB/r")"; shared_down; return 1; }
  first=$(sed -n 's/.*sk-ant-oat-\(a[12]\).*/\1/p' "$SB/r"); [ "$first" = a1 ] && other=a2 || other=a1
  [ "$(cred_req "$tok" "$SB/r")" = 200 ] && grep -q "sk-ant-oat-$first" "$SB/r" \
    || { WHY="the session did not keep its account: $(cat "$SB/r")"; shared_down; return 1; }
  printf '{"sk-ant-oat-%s":{"u7":100,"full":true},"sk-ant-oat-%s":{"u7":30}}' "$first" "$other" > "$CD/accts.json"
  t0=$(now)
  code=$(cred_req "$tok" "$SB/r")
  SECS=$(since "$t0")
  [ "$code" = 200 ] && grep -q "sk-ant-oat-$other" "$SB/r" \
    || { WHY="the full account's 429 reached the session ($code): $(cat "$SB/r")"; shared_down; return 1; }
  [ "$(cred_req "$tok" "$SB/r")" = 200 ] && grep -q "sk-ant-oat-$other" "$SB/r" \
    || { WHY="the next request went back to the full account: $(cat "$SB/r")"; shared_down; return 1; }
  grep -q '"ev": "acct_switch"' "$SB/log/alpha.log" || { WHY="no acct_switch in the log"; shared_down; return 1; }
  shared_down
  WHAT="会话所在的 $first 周限满（429）：代理把它标到重置、同一请求改走 $other 直接 200，会话凭据不变、不退出不续；后续请求留在 $other"
}

cred_run_drills "$0"
