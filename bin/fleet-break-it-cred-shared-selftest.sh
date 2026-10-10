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
#   cred-own-to-shared  bin/fleet-credsep.py machine join / leave (issue #2432): a login on its
#                       own proxy joins the shared one with no gap, and goes back
#   cred-pool-dup       bin/fleet-cred-proxy.py pool_held / pool_resolve / store, bin/fleet-credsep.py
#                       machine pooldup (issue #2849): a token held twice — the pool's and a
#                       login's own accounts/<label>.hub — is seen, and folds back to ONE
#   cred-pool-follows-hub   bin/fleet-credsep.py machine pool-sync + bin/fleet-cred-proxy.py
#                       pool-drop (issue #2850): the hub puts / revokes a pool token, the
#                       pool follows in one sync (bin/fleet-node-update.py sync_pool runs it)
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

# cred-own-to-shared (issue #2432): a login separated on its OWN proxy
# (com.claude-fleet.credsep.<login>, before the machine had a shared one) is
# moved onto the shared proxy. Before: the only road was `machine install`,
# which booted the own proxy out FIRST, restarted the agent from a definition
# the node daemon had already moved to the attic (die), and the shared proxy took
# the tenant only after — every session of that login with no proxy meanwhile.
# Now `machine join`: the shared proxy answers for it first, the agent's leases
# follow (logins/<login>.env), then the own proxy goes and its old port is bound
# by the shared one; a join the shared proxy does not take leaves everything as
# it was; `machine leave` puts it back.
drill_cred_own_to_shared() {
  CAP=20   # join: the shared proxy's restart (loop delay + a python start) + the old port's handover
  local sb me uid gid port oport ta out rc t0 sup ca refused bad own_pid svc
  me=$(id -un); uid=$(id -u); gid=$(id -g); sb="$WORK/owntoshared"
  mkdir -p "$sb/daemons" "$sb/node/logins"
  cred_rig owntoshared trusted reachable || return 1
  for L in alpha beta; do
    mkdir -p "$sb/homes/$L/.config/claude-fleet/accounts/a1.hub" "$sb/homes/$L/.claude/fleet/bin"
    printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat-%s"}}' "$L" > "$sb/homes/$L/.config/claude-fleet/accounts/a1.hub/.credentials.json"
  done
  ca="$sb/homes/alpha/.config/claude-fleet"
  printf 'FLEET_CRED_ANTHROPIC_URL=%s/direct-anthropic\n' "$CU" > "$ca/fleet.conf"
  printf 'alpha:%s:%s:%s\nbeta:1999993:%s:%s\n' "$uid" "$gid" "$sb/homes/alpha" "$gid" "$sb/homes/beta" > "$sb/pw"
  port=$(cred_deadport)
  export FLEET_CREDSEP_ROOT_BASE="$sb/db" FLEET_CREDSEP_RUN_BASE="$sb/run" FLEET_CREDSEP_LOG_BASE="$sb/log" \
    FLEET_CREDSEP_LIB="$sb/lib" FLEET_CREDSEP_DAEMON_DIR="$sb/daemons" FLEET_CREDSEP_ROLE="$me" \
    FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_PREFLIGHT=0 FLEET_CREDSEP_SUDO='' FLEET_CREDSEP_PW="$sb/pw" \
    FLEET_CREDSEP_SANDBOX_KILL=1 FLEET_CREDSEP_JOIN_WAIT=15 FLEET_NODE_STATE="$sb/node" \
    FLEET_CRED_SHARED_PORT="$port" FLEET_CRED_ANTHROPIC_URL="$CU/direct-anthropic"
  own_down() {
    kill "$sup" 2>/dev/null; kill "$(cat "$sb/run/.shared/pid" 2>/dev/null)" "$(cat "$sb/run/alpha/pid" 2>/dev/null)" 2>/dev/null
    unset FLEET_CREDSEP_ROOT_BASE FLEET_CREDSEP_RUN_BASE FLEET_CREDSEP_LOG_BASE FLEET_CREDSEP_LIB FLEET_CREDSEP_DAEMON_DIR \
      FLEET_CREDSEP_ROLE FLEET_CREDSEP_SVC FLEET_CREDSEP_TEST FLEET_CREDSEP_SUDO FLEET_CREDSEP_PW FLEET_CRED_SHARED_PORT \
      FLEET_CREDSEP_SANDBOX_KILL FLEET_CREDSEP_JOIN_WAIT FLEET_NODE_STATE
  }
  own_up() {   # launchd's part for alpha's own proxy
    python3 -I "$sb/lib/fleet-credsep-launch.py" proxy alpha 2>>"$sb/own.err" &
    printf '%s\n' "$!" >> "$WORK/cred-pids"
    until_ok 30 sh -c '[ -s "$1/pid" ] && kill -0 "$(cat "$1/pid")" 2>/dev/null && [ -S "$1/ctl.sock" ]' _ "$sb/run/alpha"
  }
  # alpha: separated on its own proxy, the way m4's credsep.fleetu2 / credsep.verky are
  bash "$BIN/fleet-credsep.sh" install --login alpha >"$sb/install-alpha.out" 2>&1 \
    || { WHY="install alpha: $(tail -2 "$sb/install-alpha.out" | tr '\n' ' ')"; own_down; return 1; }
  svc=''
  for f in "$sb/daemons"/com.claude-fleet.credsep.alpha.plist "$sb/daemons"/claude-fleet-credsep-alpha.service; do
    [ -e "$f" ] && svc=$(basename "$f")
  done
  [ -n "$svc" ] || { WHY="alpha's own proxy service was not written: $(ls "$sb/daemons")"; own_down; return 1; }
  own_up || { WHY="alpha's own proxy did not start: $(tail -2 "$sb/own.err" | tr '\n' ' ')"; own_down; return 1; }
  oport=$(cat "$sb/run/alpha/port")
  # the node daemon's view of alpha's agent (issue #2387): its leases go to the own socket
  printf 'CCQUOTA_TOKEN=tok-alpha\nCCQUOTA_FLEET_CRED_STORE=%s\n' "$sb/run/alpha/ctl.sock" > "$sb/node/logins/alpha.env"
  # beta makes the machine's shared proxy; the loop plays its KeepAlive
  bash "$BIN/fleet-credsep.sh" machine install --logins beta >"$sb/install-beta.out" 2>&1 \
    || { WHY="machine install beta: $(tail -2 "$sb/install-beta.out" | tr '\n' ' ')"; own_down; return 1; }
  ( while :; do python3 -I "$sb/lib/fleet-credsep-launch.py" shared 2>>"$sb/shared.err"; sleep 1; done ) 2>/dev/null &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  until_ok 30 test -S "$sb/run/.shared/ctl.sock" || { WHY="the shared proxy did not start: $(tail -2 "$sb/shared.err" | tr '\n' ' ')"; own_down; return 1; }
  ta=$(FLEET_CONF_DIR="$ca" bash "$BIN/fleet-cred-proxy.sh" mint --account a1 --sid so 2>&1)
  case "$ta" in fcp1.*) ;; *) WHY="mint on the own proxy: $ta"; own_down; return 1 ;; esac
  CP=$oport
  [ "$(cred_req "$ta" "$sb/r")" = 200 ] || { WHY="before the join: $(cat "$sb/r")"; own_down; return 1; }

  # a join the shared proxy never takes: nothing moves, the own proxy keeps serving
  kill "$sup" 2>/dev/null; kill "$(cat "$sb/run/.shared/pid" 2>/dev/null)" 2>/dev/null; sleep 0.5
  out=$(FLEET_CREDSEP_JOIN_WAIT=2 bash "$BIN/fleet-credsep.sh" machine join --logins alpha 2>&1); rc=$?
  own_pid=$(cat "$sb/run/alpha/pid" 2>/dev/null)
  [ "$rc" != 0 ] && [ -e "$sb/daemons/$svc" ] && kill -0 "$own_pid" 2>/dev/null \
    && ! grep -q '"mode": "shared"' "$sb/db/alpha/meta.json" && [ "$(cred_req "$ta" "$sb/r")" = 200 ] \
    || { WHY="a join the shared proxy did not take moved something (rc $rc): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; own_down; return 1; }
  ( while :; do python3 -I "$sb/lib/fleet-credsep-launch.py" shared 2>>"$sb/shared.err"; sleep 1; done ) 2>/dev/null &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  until_ok 30 test -S "$sb/run/.shared/ctl.sock"

  # the join, with alpha's session asking all the while
  : > "$sb/codes"
  ( while [ ! -e "$sb/stop" ]; do cred_req "$ta" /dev/null >> "$sb/codes"; echo >> "$sb/codes"; sleep 0.2; done ) &
  local pinger=$!
  t0=$(now)
  out=$(bash "$BIN/fleet-credsep.sh" machine join --logins alpha 2>&1); rc=$?
  SECS=$(since "$t0")
  sleep 0.5; : > "$sb/stop"; wait "$pinger" 2>/dev/null
  [ "$rc" = 0 ] || { WHY="machine join failed (rc $rc): $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; own_down; return 1; }
  refused=$(grep -c '^000$' "$sb/codes"); bad=$(grep -v '^$' "$sb/codes" | grep -vc '^\(200\|000\)$')
  [ "$bad" = 0 ] || { WHY="during the join alpha's session got: $(sort "$sb/codes" | uniq -c | tr '\n' ' ')"; own_down; return 1; }
  [ "$refused" -le 5 ] || { WHY="alpha's session had no proxy for $refused pings (> 1 s): $(sort "$sb/codes" | uniq -c | tr '\n' ' ')"; own_down; return 1; }
  [ "$(cred_req "$ta" "$sb/r")" = 200 ] || { WHY="after the join, the old port: $(cat "$sb/r")"; own_down; return 1; }
  # a session minted after the join is the shared proxy's, on its own port
  local tn; tn=$(FLEET_CONF_DIR="$ca" bash "$BIN/fleet-cred-proxy.sh" mint --account a1 --sid sn 2>&1)
  CP=$port
  [ "$(cred_req "$tn" "$sb/r")" = 200 ] || { WHY="a session minted after the join, on the shared port: $(cat "$sb/r")"; own_down; return 1; }
  [ ! -e "$sb/daemons/$svc" ] && [ -f "$sb/db/alpha/backup/$svc" ] \
    || { WHY="the own proxy's service is not in the store's backup/: $(ls "$sb/daemons" "$sb/db/alpha/backup" 2>&1 | tr '\n' ' ')"; own_down; return 1; }
  grep -qx "CCQUOTA_FLEET_CRED_STORE=$sb/run/.shared/ctl.sock" "$sb/node/logins/alpha.env" && grep -qx 'CCQUOTA_TOKEN=tok-alpha' "$sb/node/logins/alpha.env" \
    || { WHY="the agent's leases were not repointed (logins/alpha.env)"; own_down; return 1; }
  grep -q '"shared": true' "$ca/credsep.json" || { WHY="credsep.json does not say shared"; own_down; return 1; }

  # the way back
  out=$(bash "$BIN/fleet-credsep.sh" machine leave --logins alpha 2>&1) \
    || { WHY="machine leave: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; own_down; return 1; }
  [ -e "$sb/daemons/$svc" ] && grep -qx "CCQUOTA_FLEET_CRED_STORE=$sb/run/alpha/ctl.sock" "$sb/node/logins/alpha.env" \
    && ! grep -q '"shared": true' "$ca/credsep.json" \
    || { WHY="leave did not put the own proxy back: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; own_down; return 1; }
  own_up || { WHY="the own proxy did not come back: $(tail -2 "$sb/own.err" | tr '\n' ' ')"; own_down; return 1; }
  CP=$oport
  [ "$(cat "$sb/run/alpha/port")" = "$oport" ] && [ "$(cred_req "$ta" "$sb/r")" = 200 ] \
    || { WHY="after leave, the own proxy on $(cat "$sb/run/alpha/port") (want $oport): $(cat "$sb/r")"; own_down; return 1; }
  own_down
  WHAT="own 模式登录 machine join：共享代理先答应接管、agent 改指共享 socket，才卸旧代理（进 backup/）；旧端口由共享代理接住，会话原凭据一路 200（拒连 ${refused} 次）；共享代理不接则原样不动；machine leave 一条放回"
}

# cred-pool-dup (issue #2849): `machine join` starts the shared proxy with the
# joining login's pool_hold (its own proxy still reads the store's files) and
# drops the hold in meta.json at the end — but the running proxy kept the hold
# it read at start, so every renewal went on writing accounts/<label>.hub while
# the pool held the same token for the other login: two copies of one token
# (2026-10-10 macmini · mini2, four pool accounts). Now the proxy re-reads a
# held tenant's meta.json, folds a leftover own copy into the pool on the next
# store or read, and `machine pooldup` (the machine doctor's credpool row) names
# a token held twice.
drill_cred_pool_dup() {
  CAP=10   # the hold dropped → one renewal and one request later, one copy
  local sb me uid gid port ta tb pid1 t0 sup out rc R
  me=$(id -un); uid=$(id -u); gid=$(id -g); sb="$WORK/pooldup"
  mkdir -p "$sb/daemons"
  cred_rig pooldup trusted reachable || return 1
  for L in alpha beta; do
    mkdir -p "$sb/homes/$L/.config/claude-fleet/accounts/a1.hub" "$sb/homes/$L/.claude/fleet/bin"
    printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat-SAME"}}' > "$sb/homes/$L/.config/claude-fleet/accounts/a1.hub/.credentials.json"
  done
  printf 'alpha:%s:%s:%s\nbeta:1999994:%s:%s\n' "$uid" "$gid" "$sb/homes/alpha" "$gid" "$sb/homes/beta" > "$sb/pw"
  port=$(cred_deadport); R="$sb/db/alpha"
  export FLEET_CREDSEP_ROOT_BASE="$sb/db" FLEET_CREDSEP_RUN_BASE="$sb/run" FLEET_CREDSEP_LOG_BASE="$sb/log" \
    FLEET_CREDSEP_LIB="$sb/lib" FLEET_CREDSEP_DAEMON_DIR="$sb/daemons" FLEET_CREDSEP_ROLE="$me" \
    FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_PREFLIGHT=0 FLEET_CREDSEP_SUDO='' FLEET_CREDSEP_PW="$sb/pw" \
    FLEET_CRED_SHARED_PORT="$port" FLEET_CRED_ANTHROPIC_URL="$CU/direct-anthropic"
  dup_down() {
    kill "$sup" 2>/dev/null; kill "$(cat "$sb/run/.shared/pid" 2>/dev/null)" 2>/dev/null
    unset FLEET_CREDSEP_ROOT_BASE FLEET_CREDSEP_RUN_BASE FLEET_CREDSEP_LOG_BASE FLEET_CREDSEP_LIB FLEET_CREDSEP_DAEMON_DIR \
      FLEET_CREDSEP_ROLE FLEET_CREDSEP_SVC FLEET_CREDSEP_TEST FLEET_CREDSEP_SUDO FLEET_CREDSEP_PW FLEET_CRED_SHARED_PORT
  }
  dup_store() {   # <login> <peer uid|-> — the node agent's renewal of a1, the same token
    printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat-SAME","refreshToken":null,"expiresAt":4102444800000}}' |
      if [ "$2" = - ]; then FLEET_CONF_DIR="$sb/homes/$1/.config/claude-fleet" bash "$BIN/fleet-cred-proxy.sh" store --kind claude --label a1
      else FLEET_CRED_TEST_PEER_UID=$2 FLEET_CONF_DIR="$sb/homes/$1/.config/claude-fleet" bash "$BIN/fleet-cred-proxy.sh" store --kind claude --label a1; fi
  }
  bash "$BIN/fleet-credsep.sh" machine install --logins alpha,beta >"$sb/install.out" 2>&1 \
    || { WHY="machine install failed: $(tail -2 "$sb/install.out" | tr '\n' ' ')"; dup_down; return 1; }
  ( while :; do python3 -I "$sb/lib/fleet-credsep-launch.py" shared 2>>"$sb/launch.err"; sleep 1; done ) 2>/dev/null &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  until_ok 30 test -S "$sb/run/.shared/ctl.sock" || { WHY="the shared proxy did not start: $(tail -2 "$sb/launch.err" | tr '\n' ' ')"; dup_down; return 1; }
  until_ok 5 test -s "$sb/run/.shared/pid"; CP="$port"
  # the join in progress: alpha held (its own proxy still reads the store) — the proxy restarts with the hold
  python3 -c 'import json, sys; p = sys.argv[1]; m = json.load(open(p)); m["pool_hold"] = True; json.dump(m, open(p, "w"))' "$R/meta.json"
  pid1=$(cat "$sb/run/.shared/pid"); kill "$pid1"
  until_ok 30 sh -c '[ -s "$1/pid" ] && [ "$(cat "$1/pid")" != "$2" ] && [ -S "$1/ctl.sock" ]' _ "$sb/run/.shared" "$pid1" \
    || { WHY="the shared proxy did not come back with alpha held"; dup_down; return 1; }
  until_ok 10 sh -c '[ -n "$(FLEET_CONF_DIR="$1" bash "$2/fleet-cred-proxy.sh" port 2>/dev/null)" ]' _ "$sb/homes/alpha/.config/claude-fleet" "$BIN"
  dup_store alpha - >/dev/null 2>&1; dup_store beta 1999994 >/dev/null 2>&1
  [ -f "$R/accounts/a1.hub/.credentials.json" ] && [ -n "$(find "$sb/db/.shared/pool/claude" -name .credentials.json 2>/dev/null)" ] \
    || { WHY="setup: no own copy beside the pool's ($(find "$sb/db" -name .credentials.json | tr '\n' ' '))"; dup_down; return 1; }
  # join's last step: the hold dropped in meta.json — no restart
  python3 -c 'import json, sys; p = sys.argv[1]; m = json.load(open(p)); m.pop("pool_hold", None); json.dump(m, open(p, "w"))' "$R/meta.json"
  t0=$(now)
  out=$(python3 -I "$BIN/fleet-credsep.py" machine pooldup 2>&1); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^pooldup: WARN — .*alpha:a1' && ! printf '%s' "$out" | grep -q 'sk-ant' \
    || { WHY="machine pooldup did not name the token held twice (rc $rc): $(printf '%s' "$out" | tail -1)"; dup_down; return 1; }
  # the agent's next renewal, then a session's request: one copy, the pool's
  dup_store alpha - >/dev/null 2>&1
  ta=$(FLEET_CONF_DIR="$sb/homes/alpha/.config/claude-fleet" bash "$BIN/fleet-cred-proxy.sh" mint --account a1 --sid pa 2>&1)
  tb=$(FLEET_CRED_TEST_PEER_UID=1999994 FLEET_CONF_DIR="$sb/homes/beta/.config/claude-fleet" bash "$BIN/fleet-cred-proxy.sh" mint --account a1 --sid pb 2>&1)
  [ "$(cred_req "$ta" "$sb/ra")" = 200 ] && [ "$(cred_req "$tb" "$sb/rb")" = 200 ] && grep -q oat-SA "$sb/ra" && grep -q oat-SA "$sb/rb" \
    || { WHY="after the hold: alpha $(head -c 200 "$sb/ra") · beta $(head -c 200 "$sb/rb")"; dup_down; return 1; }
  SECS=$(since "$t0")
  [ ! -e "$R/accounts/a1.hub" ] && [ "$(find "$sb/db" -name .credentials.json | wc -l | tr -d ' ')" = 1 ] \
    || { WHY="still two copies after the hold was dropped: $(find "$sb/db" -name .credentials.json | sed "s|$sb/||" | tr '\n' ' ')"; dup_down; return 1; }
  grep -q '"claude:a1"' "$R/cred-proxy/pool.json" \
    || { WHY="alpha's pool index does not name claude:a1: $(cat "$R/cred-proxy/pool.json" 2>&1)"; dup_down; return 1; }
  out=$(python3 -I "$BIN/fleet-credsep.py" machine pooldup 2>&1); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^pooldup: OK' \
    || { WHY="pooldup after the fold (rc $rc): $(printf '%s' "$out" | tail -1)"; dup_down; return 1; }
  dup_down
  WHAT="同一令牌两份（共享池一份 + alpha 按登录的 accounts/a1.hub 一份，machine join 的 pool_hold 没落到在跑的代理）：machine pooldup WARN 点名 alpha:a1；hold 一撤，下一次续租 + 请求就并回池里一份，两个登录都 200，pooldup OK"
}

# cred-pool-follows-hub (issue #2850): the hub's pool changes — a new one-year
# token put, an old one revoked. Before: the machine's shared pool stayed as it
# was at join (a new token waited for some login's lease, hours out; a revoked
# one stayed for good). Now each updater round runs `machine pool-sync`: the
# hub's manifest (fingerprint + expiry, no token) against the pool — the new
# one pulled through the login's own lease, the revoked one dropped from every
# index and from disk, a token near its end a WARN.
drill_cred_pool_follows_hub() {
  CAP=10   # put → in the pool, revoke → gone: one sync each (two HTTP calls + a ctl store / drop)
  local t0 out far hp
  shared_up poolsync || return 1
  far='2100-01-01T00:00:00Z'
  cat > "$SB/hub.py" <<'PY'
import hashlib, json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def ans(self, o):
        b = json.dumps(o).encode()
        self.send_response(200); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def any(self):
        n = int(self.headers.get("content-length") or 0)
        if n: self.rfile.read(n)
        pool = json.load(open(sys.argv[2]))
        if self.path == "/v1/node/pool":
            return self.ans({"pool": [{"provider": "claude", "account": a, "expires_at": e,
                "fingerprint": hashlib.sha256(("claude\0" + t).encode()).hexdigest()[:32]} for a, t, e in pool]})
        self.ans({"credentials": [{"provider": "claude", "account": a, "pool": True, "expires_at": e,
            "access": {"access_token": t}} for a, t, e in pool]})
    do_GET = do_POST = any
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
  printf '[["a1","sk-ant-oat-a1","%s"],["a2","sk-ant-oat-a2","%s"]]' "$far" "$far" > "$SB/hub.state"
  python3 "$SB/hub.py" "$SB/hub.port" "$SB/hub.state" 2>/dev/null &
  printf '%s\n' "$!" >> "$WORK/cred-pids"
  until_ok 10 test -s "$SB/hub.port" || { WHY="the fake hub did not start"; shared_down; return 1; }
  hp=$(cat "$SB/hub.port")
  mkdir -p "$SB/node/logins"
  printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=mtok\n' "$hp" > "$SB/node/machine.env"
  printf 'CCQUOTA_TOKEN=atok\n' > "$SB/node/logins/alpha.env"
  psync() { FLEET_NODE_STATE="$SB/node" python3 -I "$BIN/fleet-credsep.py" machine pool-sync 2>&1; }
  out=$(psync) || { WHY="pool-sync (the hub as joined): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; shared_down; return 1; }
  # the hub: a3 put (ten days left), a2 revoked
  printf '[["a1","sk-ant-oat-a1","%s"],["a3","sk-ant-oat-a3","%s"]]' "$far" \
    "$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()+10*86400)))')" > "$SB/hub.state"
  t0=$(now)
  out=$(psync) || { WHY="pool-sync after the hub changed: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; shared_down; return 1; }
  SECS=$(since "$t0")
  grep -rqs sk-ant-oat-a3 "$SB/db/.shared/pool/claude" && grep -qs '"claude:a3"' "$SB/db/alpha/cred-proxy/pool.json" \
    || { WHY="the token the hub put is not in the pool: $(printf '%s' "$out" | tr '\n' ' ')"; shared_down; return 1; }
  ! grep -rqs sk-ant-oat-a2 "$SB/db/.shared/pool/claude" && ! grep -qs '"claude:a2"' "$SB/db/alpha/cred-proxy/pool.json" \
    || { WHY="the token the hub revoked is still on the machine: $(printf '%s' "$out" | tr '\n' ' ')"; shared_down; return 1; }
  grep -rqs sk-ant-oat-a1 "$SB/db/.shared/pool/claude" || { WHY="a1 (unchanged) went too"; shared_down; return 1; }
  printf '%s' "$out" | grep -q '^WARN pool: a3 expires' || { WHY="no WARN for a3 (10 days left): $out"; shared_down; return 1; }
  case "$(bash "$BIN/fleet-credsep.sh" machine status 2>&1)" in *"pool synced "*) ;;
    *) WHY="machine status shows no pool sync time"; shared_down; return 1 ;; esac
  shared_down
  WHAT="入口 put a3、吊销 a2：一轮 pool-sync 内 a3 进池（经 alpha 自己的租约）、a2 从索引和磁盘一起删掉、a1 不动；a3 剩 10 天打 WARN，machine status 显示同步时间"
}

cred_run_drills "$0"
