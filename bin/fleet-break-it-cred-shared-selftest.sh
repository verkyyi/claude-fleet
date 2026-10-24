#!/bin/bash
# fleet-break-it-cred-shared-selftest.sh — docs/dev/BREAK-IT.md row `cred-shared-down`
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
#   cred-sep-codex-full bin/fleet-cred-proxy.py held / standing / limit_until + the default
#                       home unpinned (issue #4606), bin/fleet-session-cred.sh mint / standing:
#                       Codex forwards the original429 once; only future work skips a spent account
#   cred-pool-dup       bin/fleet-cred-proxy.py pool_held / pool_resolve / store, bin/fleet-credsep.py
#                       machine pooldup (issue #2849): a token held twice — the pool's and a
#                       login's own accounts/<label>.hub — is seen, and folds back to ONE
#   cred-pool-follows-hub   bin/fleet-credsep.py machine pool-sync + bin/fleet-cred-proxy.py
#                       pool-drop (issue #2850): the hub puts / revokes a pool token, the
#                       pool follows in one sync (bin/fleet-node-update.py sync_pool runs it)
#   cred-shared-restart-loop    bin/fleet-credsep.py machine refresh (shared_unserved / login_exists /
#                       unserved_tried, issue #4714): a deleted tenant no longer restarts the proxy every tick
#   cred-upstream-unseen    bin/fleet-cred-proxy.py UpstreamStats / up_err_class (T657): each upstream
#                       attempt's class, read by bin/fleet_upstream_stats.py (doctor 上游 row,
#                       banner) and bin/fleet-topbar.py's 「上游连不上」
#   cred-codex-path-open    bin/fleet-cred-proxy.py codex_refused / CODEX_ALLOW_SPEC (issue #4611):
#                       only the paths Codex CLI uses go on; every other path, spelling or
#                       method is a 403 that never reaches chatgpt.com (the hub's half:
#                       go test github.com/verkyyi/claude-fleet/tokenledger/shared/credproxy TestCodexPathAllowList)
#   cred-ctl-burst      bin/fleet_cred_ctl.py connect (T903): a burst of node-token asks past the
#                       control socket's backlog is retried, not read as «no node token»;
#                       bin/fleet-cred-proxy.py listens with a backlog of 128 (the agent's half:
#                       go test ./agent TestRepoAuthoritySyncsBounded)
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT / CP are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

drill_cred_codex_native_tool_result() {
  CAP=10
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-cred-capacity-selftest.py" \
    Capacity.test_native_context_shared_vectors Capacity.test_native_tool_result_affinity \
    Capacity.test_native_tool_result_http 2>&1) \
    || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT="工具结果本地 id 不作上游引用；call_id 仍回原账号，未知来源/显式 pin 冲突拒绝"
}

# Native Codex first inputs contain client IDs before any provider response.
drill_cred_codex_native_initial() {
  CAP=10
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-cred-capacity-selftest.py" \
    Capacity.test_native_context_shared_vectors Capacity.test_native_first_and_resume_through_http_proxy 2>&1) \
    || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT="原生首轮完整客户端消息/tools ID 可独立选订阅；assistant/opaque 续接仍回原源，未知源和身份复用在上游前拒绝"
}

# A long Codex session resends its whole history: past 4096 recorded references
# the table was wiped and every next turn refused as «continuation source unknown».
drill_cred_codex_refs_overflow() {
  CAP=10
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-cred-capacity-selftest.py" \
    Capacity.test_long_session_past_ref_cap_stays_on_its_only_subscription \
    Capacity.test_affinity_pin_encrypted_tool_and_unknown 2>&1) \
    || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT="超过 4096 条引用的长会话仍回它唯一的订阅；换过订阅、来源不一或没超限时查不到的引用照旧拒绝"
}

# Shared rollout must preserve native picks before root drops, or legacy
# launchd bootout kills the only in-memory source. Exercise the real uid-gated
# control handler without request peer_uid seams; socket and file I/O are real.
drill_cred_shared_picks_upgrade() {
  CAP=10
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-cred-capacity-selftest.py" SharedSnapshot 2>&1) \
    || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT="共享接替降权前、旧 launchd refresh 停服前由 root 快照；role-owned0600、空结果覆盖、失败保留旧 listener；service role 无新增 control 权限"
}

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
    FLEET_CRED_SHARED_PORT="$port" FLEET_CRED_ANTHROPIC_URL="$CU/direct-anthropic" FLEET_CRED_CODEX_URL="$CU/direct-codex"
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
    FLEET_CREDSEP_ROLE FLEET_CREDSEP_SVC FLEET_CREDSEP_TEST FLEET_CREDSEP_SUDO FLEET_CREDSEP_PW FLEET_CRED_SHARED_PORT \
    FLEET_CRED_CODEX_URL
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

# cred-sep-codex-full (#4606, T972): Codex never replays current inference.
# A usage-limit429 is forwarded exactly once, byte for byte, retaining the
# current subscription. Only a later independent request can pick a healthy
# account. Claude's same-request replay remains in cred-sep-acct-full above.
drill_cred_sep_codex_full() {
  CAP=10
  local s0 s1 s2 code t0 n out rc full_hits
  shared_up codexfull || return 1
  for L in default JoyGao; do
    mkdir -p "$SB/db/alpha/codex/$L"
    printf '{"tokens":{"access_token":"tok-%s","refresh_token":"r","account_id":"acc-%s"}}' "$L" "$L" > "$SB/db/alpha/codex/$L/auth.json"
  done
  printf '{"tok-default":{"u7":100,"full":true,"back":518400},"tok-JoyGao":{"u7":80}}' > "$CD/accts.json"
  creq() { curl -s -m 30 -o "$2" -w '%{http_code}' -X POST -H "Authorization: Bearer $1" \
    -H 'content-type: application/json' -d '{"model":"gpt-5","input":[]}' "http://127.0.0.1:$CP/codex/responses" 2>/dev/null; }
  fail() { WHY="$1"; shared_down; return 1; }
  # s0 lands on JoyGao (unread accounts tie, the name breaks it) and reads it at 80 %
  # (under the 85 % ceiling), so the next pick goes to the UNREAD `default` — the
  # repro's account, at its limit, which a proxy just started knows nothing about
  s0=$(FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-proxy.sh" mint --provider codex --sid s0 2>&1)
  case "$s0" in fcp1.*) ;; *) fail "codex mint with no account was refused: $s0"; return 1 ;; esac
  [ -z "$(acct_of "$s0")" ] || { fail "the default home's credential names $(acct_of "$s0")"; return 1; }
  [ "$(creq "$s0" "$SB/r")" = 200 ] && grep -q tok-JoyGao "$SB/r" || { fail "s0: $(cat "$SB/r")"; return 1; }
  s1=$(FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-proxy.sh" mint --provider codex --sid s1 2>&1)
  n=$(wc -l < "$CD/codex-hits")
  t0=$(now)
  code=$(creq "$s1" "$SB/r")
  SECS=$(since "$t0")
  [ "$code" = 429 ] && [ $(( $(wc -l < "$CD/codex-hits") - n )) = 1 ] \
    || { fail "Codex must forward429 after one attempt, got $code after $(( $(wc -l < "$CD/codex-hits") - n )) asks"; return 1; }
  cmp -s "$SB/r" "$CD/codex-429-body" || { fail "Codex changed the original429 body"; return 1; }
  FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-proxy.sh" picks > "$SB/picks.json"
  python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); assert p["picks"]["codex:s1"] == "default"; assert not p["pinned"]' "$SB/picks.json" \
    || { fail "current request rebound after429: $(cat "$SB/picks.json")"; return 1; }
  if grep -q '"ev": "acct_switch"' "$SB/log/alpha.log"; then fail "Codex switched accounts within the current request"; return 1; fi
  full_hits=$(grep -c '^tok-default$' "$CD/codex-hits")
  n=$(wc -l < "$CD/codex-hits")
  [ "$(creq "$s1" "$SB/r")" = 200 ] && grep -q tok-JoyGao "$SB/r" \
    && [ $(( $(wc -l < "$CD/codex-hits") - n )) = 1 ] \
    && [ "$(grep -c '^tok-default$' "$CD/codex-hits")" = "$full_hits" ] \
    || { fail "later independent request did not choose the healthy account once: $(cat "$SB/r")"; return 1; }
  # a credential the old launcher minted for the default home: the proxy's to place too
  s2=$(FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-proxy.sh" mint --account default --sid s2 2>&1)
  full_hits=$(grep -c '^tok-default$' "$CD/codex-hits")
  [ "$(creq "$s2" "$SB/r")" = 200 ] && grep -q tok-JoyGao "$SB/r" || { fail "s2 (minted for default): $(cat "$SB/r")"; return 1; }
  [ "$(grep -c '^tok-default$' "$CD/codex-hits")" = "$full_hits" ] || { fail "a new session asked the spent account again"; return 1; }
  # the launcher's road: the default home's mint names no account, the record says proxy
  mkdir -p "$SB/homes/alpha/.codex"
  out=$(HOME="$SB/homes/alpha" FLEET_CONF_DIR="$CA" FLEET_CRED_PROXY=1 bash "$BIN/fleet-session-cred.sh" mint \
        --provider codex --sid s3 --codex-home "$SB/homes/alpha/.codex" 2>&1) || { fail "fleet-session-cred.sh mint: $out"; return 1; }
  [ "$(sed -n 's/^account=//p' "$CA/cred-proxy/sessions/s3")" = proxy ] && [ -z "$(acct_of "${out##*	}")" ] \
    || { fail "the default home was bound to an account: $(cat "$CA/cred-proxy/sessions/s3")"; return 1; }
  out=$(FLEET_CONF_DIR="$CA" FLEET_CRED_PROXY=1 bash "$BIN/fleet-session-cred.sh" standing --provider codex); rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] || { fail "standing with JoyGao free said rc $rc: $out"; return 1; }
  # Both spent: one original429, no resend/rebind; standing names each reset.
  printf '{"tok-default":{"u7":100,"full":true,"back":518400},"tok-JoyGao":{"u7":100,"full":true,"back":7200}}' > "$CD/accts.json"
  n=$(wc -l < "$CD/codex-hits")
  code=$(creq "$s0" "$SB/r")
  [ "$code" = 429 ] && [ $(( $(wc -l < "$CD/codex-hits") - n )) = 1 ] || { fail "all spent: $code after $(( $(wc -l < "$CD/codex-hits") - n )) asks"; return 1; }
  cmp -s "$SB/r" "$CD/codex-429-body" || { fail "all spent: original429 body changed"; return 1; }
  FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-proxy.sh" picks > "$SB/picks.json"
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["picks"]["codex:s0"] == "JoyGao"' "$SB/picks.json" \
    || { fail "all spent: current request rebound"; return 1; }
  out=$(FLEET_CONF_DIR="$CA" FLEET_CRED_PROXY=1 bash "$BIN/fleet-session-cred.sh" standing --provider codex); rc=$?
  [ "$rc" = 1 ] && case "$out" in *"default back "[0-9]*"JoyGao back "[0-9]*|*"JoyGao back "[0-9]*"default back "[0-9]*) true ;; *) false ;; esac \
    || { fail "all spent: standing rc $rc: $out"; return 1; }
  shared_down
  WHAT="Codex usage limit：原始429逐字节返回、仅一次上游请求、不当场换绑或重发；之后独立请求才选健康号；旧式 default 凭据也跳过已满号；全满仍一次429且 standing 说「${out}」；Claude 同请求重发另有演练"
}

# cred-pool-dup (issue #2849): a login's own accounts/<label>.hub beside the
# pool's copy of the same token — two copies, each renewed on its own
# (2026-10-10 mac-c · mac-d, four pool accounts, left by `machine join`'s
# pool_hold, which T600 removed with the per-login proxies). The proxy folds a
# leftover own copy into the pool on the next store or read, and `machine
# pooldup` (the machine doctor's credpool row) names a token held twice.
drill_cred_pool_dup() {
  CAP=10   # the own copy found → one renewal and one request later, one copy
  local sb me uid gid port ta tb pid1 pid2 t0 sup out rc R
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
  until_ok 10 sh -c '[ -n "$(FLEET_CONF_DIR="$1" bash "$2/fleet-cred-proxy.sh" port 2>/dev/null)" ]' _ "$sb/homes/alpha/.config/claude-fleet" "$BIN"
  dup_store beta 1999994 >/dev/null 2>&1
  # alpha's own copy of the same token, left beside the pool's (what an old join wrote)
  mkdir -p "$R/accounts/a1.hub"
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat-SAME","refreshToken":null,"expiresAt":4102444800000}}' > "$R/accounts/a1.hub/.credentials.json"
  [ -f "$R/accounts/a1.hub/.credentials.json" ] && [ -n "$(find "$sb/db/.shared/pool/claude" -name .credentials.json 2>/dev/null)" ] \
    || { WHY="setup: no own copy beside the pool's ($(find "$sb/db" -name .credentials.json | tr '\n' ' '))"; dup_down; return 1; }
  t0=$(now)
  out=$(python3 -I "$BIN/fleet-credsep.py" machine pooldup 2>&1); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^pooldup: WARN — .*alpha:a1' && ! printf '%s' "$out" | grep -q 'sk-ant' \
    || { WHY="machine pooldup did not name the token held twice (rc $rc): $(printf '%s' "$out" | tail -1)"; dup_down; return 1; }
  # the agent's next renewal, then a session's request: one copy, the pool's
  dup_store alpha - >/dev/null 2>&1
  ta=$(FLEET_CONF_DIR="$sb/homes/alpha/.config/claude-fleet" bash "$BIN/fleet-cred-proxy.sh" mint --account a1 --sid pa 2>&1)
  tb=$(FLEET_CRED_TEST_PEER_UID=1999994 FLEET_CONF_DIR="$sb/homes/beta/.config/claude-fleet" bash "$BIN/fleet-cred-proxy.sh" mint --account a1 --sid pb 2>&1)
  [ "$(cred_req "$ta" "$sb/ra")" = 200 ] && [ "$(cred_req "$tb" "$sb/rb")" = 200 ] && grep -q oat-SA "$sb/ra" && grep -q oat-SA "$sb/rb" \
    || { WHY="after the fold: alpha $(head -c 200 "$sb/ra") · beta $(head -c 200 "$sb/rb")"; dup_down; return 1; }
  SECS=$(since "$t0")
  [ ! -e "$R/accounts/a1.hub" ] && [ "$(find "$sb/db" -name .credentials.json | wc -l | tr -d ' ')" = 1 ] \
    || { WHY="still two copies after a renewal and a request: $(find "$sb/db" -name .credentials.json | sed "s|$sb/||" | tr '\n' ' ')"; dup_down; return 1; }
  grep -q '"claude:a1"' "$R/cred-proxy/pool.json" \
    || { WHY="alpha's pool index does not name claude:a1: $(cat "$R/cred-proxy/pool.json" 2>&1)"; dup_down; return 1; }
  out=$(python3 -I "$BIN/fleet-credsep.py" machine pooldup 2>&1); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^pooldup: OK' \
    || { WHY="pooldup after the fold (rc $rc): $(printf '%s' "$out" | tail -1)"; dup_down; return 1; }
  dup_down
  WHAT="同一令牌两份（共享池一份 + alpha 按登录的 accounts/a1.hub 一份）：machine pooldup WARN 点名 alpha:a1；下一次续租 + 请求就并回池里一份，两个登录都 200，pooldup OK"
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

# cred-shared-restart-loop (issue #4714): a login deleted under its store (its
# meta.json still says `mode: shared`) is skipped by the launcher, so the shared
# proxy never serves it — and `machine refresh` read that as «not served» (#4245)
# and restarted the proxy on every updater tick (5 min), cutting every session's
# stream mid-response («API Error: Connection lost mid-response», a managed Mac, 3 times in
# a day). Now a login with no passwd entry is never «not served», and a login that
# exists but a restart did not serve is restarted for ONCE, not every tick.
drill_cred_shared_restart_loop() {
  CAP=10
  local sb me uid gid port t0 out
  me=$(id -un); uid=$(id -u); gid=$(id -g); sb="$WORK/rloop"; port=$(cred_deadport)
  mkdir -p "$sb/daemons"
  for L in alpha ghost beta; do
    mkdir -p "$sb/homes/$L/.config/claude-fleet" "$sb/homes/$L/.claude/fleet/bin"
  done
  printf 'alpha:%s:%s:%s\nghost:1999995:%s:%s\nbeta:1999996:%s:%s\n' "$uid" "$gid" "$sb/homes/alpha" \
    "$gid" "$sb/homes/ghost" "$gid" "$sb/homes/beta" > "$sb/pw"
  export FLEET_CREDSEP_ROOT_BASE="$sb/db" FLEET_CREDSEP_RUN_BASE="$sb/run" FLEET_CREDSEP_LOG_BASE="$sb/log" \
    FLEET_CREDSEP_LIB="$sb/lib" FLEET_CREDSEP_DAEMON_DIR="$sb/daemons" FLEET_CREDSEP_ROLE="$me" \
    FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_PREFLIGHT=0 FLEET_CREDSEP_SUDO='' FLEET_CREDSEP_PW="$sb/pw" \
    FLEET_CRED_SHARED_PORT="$port"
  rloop_down() {
    unset FLEET_CREDSEP_ROOT_BASE FLEET_CREDSEP_RUN_BASE FLEET_CREDSEP_LOG_BASE FLEET_CREDSEP_LIB FLEET_CREDSEP_DAEMON_DIR \
      FLEET_CREDSEP_ROLE FLEET_CREDSEP_SVC FLEET_CREDSEP_TEST FLEET_CREDSEP_PREFLIGHT FLEET_CREDSEP_SUDO FLEET_CREDSEP_PW FLEET_CRED_SHARED_PORT
  }
  bash "$BIN/fleet-credsep.sh" machine install --logins alpha,ghost >"$sb/install.out" 2>&1 \
    || { WHY="machine install: $(tail -2 "$sb/install.out" | tr '\n' ' ')"; rloop_down; return 1; }
  # the account goes; its store stays. The running proxy serves alpha (it skipped ghost).
  printf 'alpha:%s:%s:%s\nbeta:1999996:%s:%s\n' "$uid" "$gid" "$sb/homes/alpha" "$gid" "$sb/homes/beta" > "$sb/pw"
  mkdir -p "$sb/run/.shared"; printf '%s\n' "$$" > "$sb/run/.shared/pid"; printf 'alpha\n' > "$sb/run/.shared/logins"
  t0=$(now)
  for i in 1 2 3; do
    out=$(bash "$BIN/fleet-credsep.sh" machine refresh 2>&1)
    case "$out" in *"shared: current"*) ;;
      *) WHY="tick $i with a deleted login: $(printf '%s' "$out" | grep 'shared:' | tail -1) — the proxy restarts every tick"; rloop_down; return 1 ;; esac
  done
  # a login that exists and still is not served after a restart: restarted ONCE
  bash "$BIN/fleet-credsep.sh" machine install --logins beta >"$sb/install-b.out" 2>&1 \
    || { WHY="machine install beta: $(tail -2 "$sb/install-b.out" | tr '\n' ' ')"; rloop_down; return 1; }
  printf 'alpha\n' > "$sb/run/.shared/logins"
  out=$(bash "$BIN/fleet-credsep.sh" machine refresh 2>&1)
  case "$out" in *"refreshed, restarted"*"not served: beta)"*) ;;
    *) WHY="beta not served did not restart it once: $(printf '%s' "$out" | grep 'shared:' | tail -1)"; rloop_down; return 1 ;; esac
  for i in 1 2; do
    out=$(bash "$BIN/fleet-credsep.sh" machine refresh 2>&1)
    case "$out" in *"shared: current"*"not served: beta — restarted once already"*) ;;
      *) WHY="beta still unserved, tick $i restarted again: $(printf '%s' "$out" | grep 'shared:' | tail -1)"; rloop_down; return 1 ;; esac
  done
  case "$(bash "$BIN/fleet-credsep.sh" machine status 2>&1)" in *"NOT SERVED: beta"*) ;;
    *) WHY="machine status no longer says beta is not served"; rloop_down; return 1 ;; esac
  # served at last: the mark clears, a later unserved set restarts once again
  printf 'alpha\nbeta\n' > "$sb/run/.shared/logins"
  bash "$BIN/fleet-credsep.sh" machine refresh >/dev/null 2>&1
  [ ! -e "$sb/db/.shared.json.unserved" ] || { WHY="the once-mark outlived beta being served"; rloop_down; return 1; }
  SECS=$(since "$t0")
  rloop_down
  WHAT="登录被删、存储留着：machine refresh 三个 tick 都答 current、不再重启共享代理；存在却没被服务的 beta 只重启一次，之后答「restarted once already」，machine status 仍报 NOT SERVED；服务上之后标记清掉"
}

# cred-codex-path-open (issue #4611): a session asks its proxy for /codex/<anything>.
# Before, any suffix was glued onto chatgpt.com/backend-api/codex and sent with the
# shared subscription's token. Now only the list goes on; the rest is a 403 with
# ev=deny and nothing reaches the far end. The Claude half is untouched.
drill_cred_codex_path_open() {
  CAP=10
  local tok code t0 n0 c m p
  cred_rig codexpath trusted reachable || return 1
  mkdir -p "$CD/.codex-accounts/a1"
  printf '{"tokens":{"access_token":"cx-REAL-a1","account_id":"acct-a1"}}' > "$CD/.codex-accounts/a1/auth.json"
  cred_serve || return 1
  tok=$(cred_ctl mint --account a1 --sid s-cx) || { WHY="mint failed"; return 1; }
  cx() {   # <method> <path as sent> → the status
    curl -s -m 10 --path-as-is -o "$CD/cx.out" -w '%{http_code}' -X "$1" -H "Authorization: Bearer $tok" \
      -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$CP$2" 2>/dev/null
  }
  t0=$(now)
  for c in 'POST /codex/responses' 'POST /codex/responses/compact' 'GET /codex/models?client_version=0.162.1'; do
    m=${c%% *}; p=${c#* }
    code=$(cx "$m" "$p"); [ "$code" = 200 ] || { WHY="$c → $code, want 200: $(cat "$CD/cx.out")"; return 1; }
  done
  grep -q '^direct-codex /direct-codex/models?client_version=0.162.1$' "$CD/hits" \
    || { WHY="models did not reach the far end with its query: $(grep codex "$CD/hits" | tr '\n' ' ')"; return 1; }
  n0=$(grep -c '^direct-codex ' "$CD/hits")
  for c in 'GET /codex/wham/usage' 'POST /codex/tasks/list' 'POST /codex/../v1/messages' 'POST /codex/%2e%2e/wham/usage' \
           'POST /codex/responses%2Fcompact' 'POST /codex//responses' 'POST /codex/./responses' 'POST /codex/responses/' \
           'POST /codex/responses\x' 'GET /codex/responses' 'DELETE /codex/responses' 'PUT /codex/models'; do
    m=${c%% *}; p=${c#* }
    code=$(cx "$m" "$p"); [ "$code" = 403 ] || { WHY="$c → $code, want 403: $(cat "$CD/cx.out")"; return 1; }
  done
  SECS=$(since "$t0")
  [ "$(grep -c '^direct-codex ' "$CD/hits")" = "$n0" ] \
    || { WHY="a refused path reached chatgpt.com: $(grep '^direct-codex ' "$CD/hits" | tail -n +"$((n0 + 1))" | tr '\n' ' ')"; return 1; }
  [ "$(grep -c '"ev": "deny".*"/codex/' "$CD/proxy.log")" -ge 12 ] \
    || { WHY="the refusals left $(grep -c '"ev": "deny"' "$CD/proxy.log") ev=deny lines, want 12"; return 1; }
  [ "$(cred_req "$tok" "$CD/r")" = 200 ] || { WHY="the Claude half broke: $(cat "$CD/r")"; return 1; }
  WHAT="/codex/ 只放行 POST responses · POST responses/compact · GET models（查询串照带）；wham/usage、tasks/list、..、%2e%2e、//、./、尾斜杠、反斜杠、清单外方法共 12 种一律 403、记 ev=deny、chatgpt.com 一个没收到；Claude 照常 200"
}


# cred-upstream-unseen (T657): the provider's road resets, times out, answers 529 —
# and nobody could say which: the proxy's log is _fleetcred's 0600, a session
# keeps no retry reason. Now every attempt is a class in stats every login reads,
# the doctor's 上游 row WARNs, the 看台's top line says 「上游连不上」. A raw fake
# upstream on 127.0.0.1 answers by its mode file: reset (RST after the request),
# hang (no answer past the proxy's timeout), 529, ok.
up_fake() {   # <dir> → <dir>/up.port; <dir>/mode picks the answer
  cat > "$1/up.py" <<'PY'
import os, signal, socket, struct, sys, threading, time
signal.alarm(120)
D = sys.argv[1]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(16)
open(os.path.join(D, "up.port.tmp"), "w").write(str(s.getsockname()[1]))
os.replace(os.path.join(D, "up.port.tmp"), os.path.join(D, "up.port"))
def one(c):
    c.settimeout(5)
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = c.recv(65536)
        if not d:
            return c.close()
        buf += d
    mode = open(os.path.join(D, "mode")).read().strip()
    if mode == "reset":
        c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        return c.close()
    if mode == "hang":
        time.sleep(4); return c.close()
    code, word = (529, "Overloaded") if mode == "529" else (200, "OK")
    b = b'{"type":"error","error":{"type":"overloaded_error"}}' if code == 529 else b'{"ok":true}'
    c.sendall(b"HTTP/1.1 %d %s\r\ncontent-type: application/json\r\ncontent-length: %d\r\nconnection: close\r\n\r\n%s"
              % (code, word.encode(), len(b), b))
    c.close()
while True:
    c, _ = s.accept()
    threading.Thread(target=one, args=(c,), daemon=True).start()
PY
  python3 -I "$1/up.py" "$1" 2>"$1/up.err" &
  printf '%s\n' "$!" >> "$WORK/cred-pids"
  until_ok 10 test -s "$1/up.port"
}

drill_cred_upstream_unseen() {
  CAP=20   # 3 resets + 1 hang (the proxy's 1 s timeout) + 2 × 529 + 32 ok, then the readers
  cred_rig up trusted reachable || return 1
  # Deterministic minute rollover: the small archive's FIRST line is whole,
  # not a truncated tail. It must still contribute the three resets.
  python3 - "$BIN" "$CD/small-stats" <<'PYTEST' || { WHY='the banner dropped a complete first minute'; return 1; }
import json, os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import fleet_upstream_stats as stats
root = Path(sys.argv[2]); root.mkdir()
os.environ['FLEET_UPSTREAM_STATS_DIR'] = str(root)
(root / stats.FILE).write_text(json.dumps(dict(m=60, n=3, c={'reset':3})) + '\n')
(root / stats.NOW).write_text(json.dumps(dict(m=120, n=5, c={'timeout':1, '529':2, 'ok':2})))
assert stats.banner(now=125) == ('reset', 3), stats.banner(now=125)
print('PASS small archive keeps the complete first minute across rollover')
PYTEST
  up_fake "$CD" || { WHY="the fake upstream did not start: $(tail -2 "$CD/up.err" | tr '\n' ' ')"; return 1; }
  local up tok t0 m c js us="$CD/cred-proxy"
  up="http://127.0.0.1:$(cat "$CD/up.port")"
  CRED_DIRECT="$up" CRED_RELAY="$up/relay" CRED_TIMEOUT=1
  cred_serve || { unset CRED_DIRECT CRED_RELAY CRED_TIMEOUT; return 1; }
  unset CRED_DIRECT CRED_RELAY CRED_TIMEOUT
  tok=$(cred_ctl mint --account a1 --sid s-up) || { WHY="mint failed"; return 1; }
  t0=$(now)
  for m in reset reset reset hang 529 529 ok ok; do
    printf '%s\n' "$m" > "$CD/mode"
    c=$(cred_req "$tok" "$CD/r")
    case "$m:$c" in reset:502|hang:502|529:529|ok:200) ;; *) WHY="mode $m answered $c, want the road's own: $(cat "$CD/r")"; return 1 ;; esac
  done
  # the tick writes the open minute within a second
  up_n() { FLEET_UPSTREAM_STATS_DIR="$us" python3 -I "$BIN/fleet_upstream_stats.py" show --since 1h --json \
    | python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin)["n"] >= int(sys.argv[1]) else 1)' "$1"; }
  until_ok 5 up_n 8
  js=$(FLEET_UPSTREAM_STATS_DIR="$us" python3 -I "$BIN/fleet_upstream_stats.py" show --since 1h --json)
  printf '%s' "$js" | python3 -c '
import json, sys
s = json.load(sys.stdin); c = s["c"]
want = {"reset": 3, "timeout": 1, "529": 2, "ok": 2}
assert {k: c.get(k, 0) for k in want} == want, c
assert s["a"].get("a1", {}).get("reset") == 3, s["a"]
f = [e for e in s["f"] if e["c"] == "reset"]
assert len(f) == 3 and all(e["sid"] == "s-up" and e["acct"] == "a1" and e["route"] for e in f), s["f"]
' 2>"$CD/chk.err" || { WHY="the stats do not hold the classes: $(tail -1 "$CD/chk.err") — $js"; return 1; }
  ! grep -rq 'sk-ant\|REAL-a1\|Bearer' "$us"/upstream-* || { WHY="a token or header reached the stats"; return 1; }
  [ "$(python3 -c 'import os, sys; print("%o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$us/upstream-now.json")" = 644 ] \
    || { WHY="upstream-now.json is not 0644: every login must read it"; return 1; }
  c=$(FLEET_UPSTREAM_STATS_DIR="$us" python3 -I "$BIN/fleet_upstream_stats.py" doctor)
  case "$c" in WARN*连接被重置\ 3*) ;; *) WHY="the doctor's 上游 row did not WARN naming the resets: $c"; return 1 ;; esac
  c=$(FLEET_UPSTREAM_STATS_DIR="$us" python3 -I "$BIN/fleet_upstream_stats.py" banner)
  [ "$c" = "$(printf 'reset\t3')" ] || { WHY="the top line's banner: [$c], want reset 3"; return 1; }
  printf '{"state":"working","key":"#1","title":"t","node":"m"}\n' > "$CD/rec.json"
  c=$(FLEET_UPSTREAM_STATS_DIR="$us" FLEET_UI_LANG=zh python3 "$BIN/fleet-topbar.py" fit 120 "$CD/rec.json" ups=1)
  case "$c" in *'上游连不上：连接被重置（3 次）'*) ;; *) WHY="the top line does not say it: $c"; return 1 ;; esac
  # recovered: the road answers again — once failures fall under 20 % the line is gone
  printf 'ok\n' > "$CD/mode"
  for m in $(seq 1 30); do [ "$(cred_req "$tok" "$CD/r")" = 200 ] || { WHY="ok #$m did not answer 200"; return 1; }; done
  until_ok 5 sh -c '! FLEET_UPSTREAM_STATS_DIR="$1" python3 -I "$2" banner >/dev/null' _ "$us" "$BIN/fleet_upstream_stats.py" \
    || { WHY="the banner outlived the recovery: $(FLEET_UPSTREAM_STATS_DIR="$us" python3 -I "$BIN/fleet_upstream_stats.py" banner)"; return 1; }
  SECS=$(since "$t0")
  WHAT="上游重置 3 次、超时 1 次、529 两次：统计（0644、无凭据）按类别记下账号 a1 与会话 s-up；doctor 上游行 WARN 写明「连接被重置 3」，看台顶行「上游连不上：连接被重置（3 次）」；再 30 次成功后顶行消失"
}

# cred-ctl-burst (T903): a reconnect re-pushes every repo to every login of a
# managed machine, each re-read asks the shared proxy's control socket for its
# broker pair at once. Past the backlog the connect is refused at once, which
# read as «no node token here» until the next beat. A fake control socket with a
# backlog of 1 that answers one ask at a time: 24 asks at once all get the pair.
drill_cred_ctl_burst() {
  CAP=20
  local d t0 i bad=0 srv pids=''
  d="$WORK/ctlburst"; mkdir -p "$d/conf" "$d/run"
  printf '{"separated": true, "run": "%s"}\n' "$d/run" > "$d/conf/credsep.json"
  python3 - "$d/run/ctl.sock" <<'PY' &
import json, os, socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sys.argv[1]); s.listen(1)
s.settimeout(30)
while True:
    try:
        c, _ = s.accept()
    except OSError:
        break
    c.recv(4096); time.sleep(0.02)
    c.sendall((json.dumps({"ok": True, "url": "http://127.0.0.1:1/hub", "token": "fcpn1.drill"}) + "\n").encode())
    c.close()
PY
  srv=$!
  until_ok 5 test -S "$d/run/ctl.sock" || { WHY="the fake control socket never listened"; kill "$srv" 2>/dev/null; return 1; }
  t0=$(now)
  for i in $(seq 1 24); do
    ( FLEET_CONF_DIR="$d/conf" python3 -I "$BIN/fleet_cred_ctl.py" node-token > "$d/out.$i" 2>&1; echo $? > "$d/rc.$i" ) &
    pids="$pids $!"
  done
  for i in $pids; do wait "$i"; done
  for i in $(seq 1 24); do
    [ "$(cat "$d/rc.$i" 2>/dev/null)" = 0 ] && grep -q 'fcpn1.drill' "$d/out.$i" || bad=$((bad + 1))
  done
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
  [ "$bad" = 0 ] || { WHY="$bad of 24 asks at once got no broker pair: a full backlog read as no node token"; return 1; }
  grep -q 'ctl.listen(128)' "$BIN/fleet-cred-proxy.py" || { WHY="the proxy's control socket no longer listens with a backlog of 128"; return 1; }
  SECS=$(since "$t0")
  WHAT="控制口 backlog 1、一次答一个：24 个 node-token 同时问，全部拿到 broker 对（被拒的连接退避重试，不再读成「没有节点令牌」）；共享代理的控制口 backlog 128"
}

cred_run_drills "$0"
