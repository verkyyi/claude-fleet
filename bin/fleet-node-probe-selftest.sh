#!/bin/bash
# fleet-node-probe-selftest.sh — can this computer run sessions? (issue #1720,
# EPIC #1718 C2): bin/fleet-node-probe.sh and `fleet node compute` (bin/fleet →
# bin/fleet-node.sh), against a FAKE egress and FAKE provider answers — a curl
# stub that answers Cloudflare's trace, ipinfo and the two APIs from the
# environment, and a pmset stub. No network, HOME a sandbox.
#
# The hub's half — an unsupported region closes a login and raises the
# compute_region alert, fleet.compute_auto=on opens an ok one, --force is
# audited — is tokenledger's: TestComputeRegionClosesAndAlerts,
# TestComputeAutoOpensOnlyByPolicy, TestComputeUnreachableAndForce,
# TestDecideCompute (internal/api/fleet_compute_probe_test.go).
#
# What it pins:
#   A. ok          US + both APIs answer 401 → verdict ok, exit 0, the JSON's
#                  fields; a coordinate-only node gets the ONE hint
#                  「可以打开：fleet node compute on」, a node already on and a
#                  machine that is no node get none
#   B. 境内        egress CN → unsupported_region, exit 1; `fleet node compute on`
#                  is REFUSED (exit 1, node.env still 0) with the reason;
#                  --force opens it with CCQUOTA_FLEET_COMPUTE_FORCE=1
#   C. one source  Cloudflare US but ipinfo HK → unsupported_region
#   D. 403         a US egress the provider refuses (403) → unsupported_region
#   E. unreachable OpenAI does not answer → unreachable; compute on refused
#   F. compute     on (ok) writes CCQUOTA_FLEET_COMPUTE=1 and no FORCE line,
#                  keeps every other node.env line, 0600, nudges the agent;
#                  off writes 0; status says which; not a node → refused
#   G. laptop      a battery is noted, never refused (Darwin pmset, Linux BAT*)
#   H. --max-age   a fresh node-probe.json is reused: no request at all
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/fleet-probe-st.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

cat >"$SB/curl" <<'EOF'
#!/bin/sh
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -w|--max-time|-X|-H|-d) shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
echo "$url" >>"$FAKE_CURL_LOG"
code=""
case "$url" in
  *cdn-cgi/trace) [ "${FAKE_LOC1:-US}" = DOWN ] && exit 6; printf 'ip=192.0.2.1\nloc=%s\n' "${FAKE_LOC1:-US}" ;;
  *ipinfo.io*) [ "${FAKE_LOC2:-US}" = DOWN ] && exit 6; printf '%s\n' "${FAKE_LOC2:-US}" ;;
  *anthropic*) code="${FAKE_ANTH:-401}" ;;
  *openai*) code="${FAKE_OAI:-401}" ;;
esac
if [ -n "$code" ]; then
  if [ "$code" = 000 ]; then printf 000; exit 7; fi
  [ -n "$out" ] && echo '{"error":{"type":"x"}}' >"$out"
  printf '%s' "$code"
fi
exit 0
EOF
cat >"$SB/pmset" <<'EOF'
#!/bin/sh
if [ "$2" = batt ]; then
  [ "${FAKE_BATTERY:-0}" = 1 ] && echo " -InternalBattery-0 (id=1)	80%; discharging" || echo "Now drawing from 'AC Power'"
else
  printf ' standby 1\n sleep %s\n displaysleep 10\n' "${FAKE_SLEEP:-0}"
fi
EOF
chmod 755 "$SB/curl" "$SB/pmset"
mkdir -p "$SB/nobat"

# probe_in <home> [args…] — the probe with the fakes; out/rc in $SB.
probe_in() {
  local h="$SB/$1"; shift
  mkdir -p "$h/.config/claude-fleet"
  HOME="$h" FLEET_CONF_DIR="$h/.config/claude-fleet" FAKE_CURL_LOG="$SB/curl.log" \
    FLEET_PROBE_CURL="$SB/curl" FLEET_PROBE_PMSET="$SB/pmset" FLEET_PROBE_OS="${OS_:-Darwin}" \
    FLEET_PROBE_BATTERY_DIR="${BATDIR_:-$SB/nobat}" \
    "$BIN/fleet-node-probe.sh" "$@" >"$SB/out" 2>&1 </dev/null
  echo $? >"$SB/rc"
}
# fleet_in <home> [args…] — `fleet …` with the same fakes.
fleet_in() {
  local h="$SB/$1"; shift
  mkdir -p "$h/.config/claude-fleet"
  HOME="$h" FLEET_CONF_DIR="$h/.config/claude-fleet" XDG_CONFIG_HOME="$h/.config" FAKE_CURL_LOG="$SB/curl.log" \
    FLEET_PROBE_CURL="$SB/curl" FLEET_PROBE_PMSET="$SB/pmset" FLEET_PROBE_OS=Darwin FLEET_PROBE_BATTERY_DIR="$SB/nobat" \
    "$BIN/fleet" "$@" >"$SB/out" 2>&1 </dev/null
  echo $? >"$SB/rc"
}
node_env() { # <home> <compute line or ''> — a joined node's node.env
  mkdir -p "$SB/$1/.config/claude-fleet"
  { echo "CCQUOTA_HUB_URL=http://hub.test"; echo "CCQUOTA_TOKEN=ccq_testpass"; [ -z "$2" ] || echo "$2"; } >"$SB/$1/.config/claude-fleet/node.env"
  chmod 600 "$SB/$1/.config/claude-fleet/node.env"
}
J() { cat "$SB/$1/.config/claude-fleet/node-probe.json" 2>/dev/null; }
rc() { cat "$SB/rc"; }
out() { cat "$SB/out"; }

# ── A. ok ────────────────────────────────────────────────────────────────
node_env a 'CCQUOTA_FLEET_COMPUTE=0'
probe_in a
if [ "$(rc)" = 0 ] && J a | grep -q '"loc":"US","anthropic":"reachable","openai":"reachable","laptop":false,' \
   && J a | grep -q '"verdict":"ok"' && J a | grep -Eq '"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z"'; then
  ok "A US + both APIs answer → verdict ok, exit 0, every field"
else bad "A rc=$(rc) json=$(J a) out=$(out)"; fi
[ "$(grep -c . "$SB/out")" = 2 ] && grep -q '^本机判断：合适 — 出口 US' "$SB/out" && grep -qx '可以打开：fleet node compute on' "$SB/out" \
  && ok "A a coordinate-only node gets exactly the one hint" || bad "A hint: $(out)"
node_env a2 'CCQUOTA_FLEET_COMPUTE=1'; probe_in a2
grep -q '可以打开' "$SB/out" && bad "A a node already on was told to open: $(out)" || ok "A no hint for a node already on"
probe_in a3
[ "$(rc)" = 0 ] && ! grep -q '可以打开' "$SB/out" && ok "A no hint on a machine that is no node" || bad "A no-node: $(out)"

# ── B. 境内 ──────────────────────────────────────────────────────────────
node_env b 'CCQUOTA_FLEET_COMPUTE=0'
export FAKE_LOC1=CN FAKE_LOC2=CN FAKE_ANTH=403 FAKE_OAI=000
probe_in b
[ "$(rc)" = 1 ] && J b | grep -q '"loc":"CN"' && J b | grep -q '"verdict":"unsupported_region"' \
  && grep -q '^本机判断：不合适 — 出口 CN' "$SB/out" && ! grep -q '可以打开' "$SB/out" \
  && ok "B egress CN → unsupported_region, exit 1, no hint" || bad "B rc=$(rc) json=$(J b) out=$(out)"
fleet_in b node compute on
if [ "$(rc)" = 1 ] && grep -q '^✗ 不打开' "$SB/out" && grep -q '出口 CN' "$SB/out" \
   && grep -qx 'CCQUOTA_FLEET_COMPUTE=0' "$SB/b/.config/claude-fleet/node.env"; then
  ok "B fleet node compute on is refused with the reason; node.env still 0"
else bad "B compute on rc=$(rc): $(out) / $(cat "$SB/b/.config/claude-fleet/node.env")"; fi
fleet_in b node compute on --force
E="$SB/b/.config/claude-fleet/node.env"
[ "$(rc)" = 0 ] && grep -qx 'CCQUOTA_FLEET_COMPUTE=1' "$E" && grep -qx 'CCQUOTA_FLEET_COMPUTE_FORCE=1' "$E" && grep -q '入口已记审计' "$SB/out" \
  && ok "B --force opens it, CCQUOTA_FLEET_COMPUTE_FORCE=1 (the hub audits it)" || bad "B --force rc=$(rc): $(out) / $(cat "$E")"
unset FAKE_LOC1 FAKE_LOC2 FAKE_ANTH FAKE_OAI

# ── C. one source ────────────────────────────────────────────────────────
FAKE_LOC2=HK probe_in c
[ "$(rc)" = 1 ] && J c | grep -q '"loc":"HK"' && J c | grep -q '"verdict":"unsupported_region"' \
  && ok "C Cloudflare US, ipinfo HK → unsupported_region" || bad "C $(J c)"

# ── D. 403 ───────────────────────────────────────────────────────────────
FAKE_OAI=403 probe_in d
[ "$(rc)" = 1 ] && J d | grep -q '"openai":"unsupported_region"' && J d | grep -q '"verdict":"unsupported_region"' \
  && ok "D a provider's 403 from a US egress → unsupported_region" || bad "D $(J d)"

# ── E. unreachable ───────────────────────────────────────────────────────
node_env e 'CCQUOTA_FLEET_COMPUTE=0'
FAKE_OAI=000 probe_in e
[ "$(rc)" = 1 ] && J e | grep -q '"openai":"unreachable"' && J e | grep -q '"verdict":"unreachable"' && grep -q '^本机判断：暂不合适' "$SB/out" \
  && ok "E OpenAI silent → unreachable" || bad "E $(J e) $(out)"
FAKE_OAI=000 fleet_in e node compute on
[ "$(rc)" = 1 ] && grep -qx 'CCQUOTA_FLEET_COMPUTE=0' "$SB/e/.config/claude-fleet/node.env" \
  && ok "E compute on refused while unreachable" || bad "E compute on rc=$(rc): $(out)"

# ── F. compute ───────────────────────────────────────────────────────────
node_env f 'CCQUOTA_FLEET_COMPUTE=0'
E="$SB/f/.config/claude-fleet/node.env"
echo 'CCQUOTA_FLEET_COMPUTE_FORCE=1' >>"$E"
fleet_in f node compute on
mode=$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$E" 2>/dev/null)
if [ "$(rc)" = 0 ] && grep -qx 'CCQUOTA_FLEET_COMPUTE=1' "$E" && ! grep -q FORCE "$E" && grep -qx 'CCQUOTA_TOKEN=ccq_testpass' "$E" \
   && grep -qx 'CCQUOTA_HUB_URL=http://hub.test' "$E" && [ "$mode" = 600 ] && [ -e "$SB/f/.config/claude-fleet/global/hub-nudge" ] \
   && grep -q '^✓ 已打开' "$SB/out" && ! grep -q '可以打开' "$SB/out"; then
  ok "F compute on (ok): COMPUTE=1, no FORCE, other lines kept, 0600, agent nudged"
else bad "F on rc=$(rc) mode=$mode: $(out) / $(cat "$E")"; fi
fleet_in f node compute status
[ "$(rc)" = 0 ] && grep -q '^已打开' "$SB/out" && ok "F status: on" || bad "F status: $(out)"
fleet_in f node compute off
[ "$(rc)" = 0 ] && grep -qx 'CCQUOTA_FLEET_COMPUTE=0' "$E" && [ "$(grep -c '^CCQUOTA_FLEET_COMPUTE=' "$E")" = 1 ] && grep -q '^✓ 已关闭：只协调' "$SB/out" \
  && ok "F compute off: COMPUTE=0 (one line)" || bad "F off rc=$(rc): $(out) / $(cat "$E")"
fleet_in f node compute status
grep -q '^只协调' "$SB/out" && ok "F status: 只协调" || bad "F status off: $(out)"
fleet_in f0 node compute on
[ "$(rc)" = 1 ] && grep -q '还不是节点' "$SB/out" && [ ! -e "$SB/f0/.config/claude-fleet/node.env" ] \
  && ok "F not a node: refused, nothing written" || bad "F no node rc=$(rc): $(out)"
fleet_in f node compute sideways
[ "$(rc)" = 2 ] && ok "F an unknown verb is usage (exit 2)" || bad "F usage rc=$(rc)"

# ── G. laptop ────────────────────────────────────────────────────────────
FAKE_BATTERY=1 FAKE_SLEEP=10 probe_in g
[ "$(rc)" = 0 ] && J g | grep -q '"laptop":true,"sleep_min":10,' && grep -q '笔记本：合盖或睡眠时会话会停下（睡眠设置 10 分钟）' "$SB/out" \
  && ok "G a Mac on battery: noted, still ok" || bad "G $(J g) $(out)"
mkdir -p "$SB/linbat/BAT0"
OS_=Linux BATDIR_="$SB/linbat" probe_in g2
[ "$(rc)" = 0 ] && J g2 | grep -q '"laptop":true' && ok "G Linux BAT0: laptop" || bad "G linux $(J g2)"
OS_=Linux probe_in g3
J g3 | grep -q '"laptop":false' && ok "G Linux, no battery: not a laptop" || bad "G linux nobat $(J g3)"

# ── H. --max-age ─────────────────────────────────────────────────────────
: >"$SB/curl.log"
probe_in a --max-age 3600
[ "$(rc)" = 0 ] && [ ! -s "$SB/curl.log" ] && grep -q '^本机判断：合适' "$SB/out" \
  && ok "H a fresh probe is reused: no request" || bad "H requests: $(cat "$SB/curl.log") out=$(out)"
probe_in a --max-age 0
[ -s "$SB/curl.log" ] && ok "H --max-age 0 measures again" || bad "H --max-age 0 made no request"
probe_in a --json
[ "$(rc)" = 0 ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["verdict"]=="ok" else 1)' "$SB/out" \
  && ok "H --json prints the JSON" || bad "H --json: $(out)"
probe_in a --bogus
[ "$(rc)" = 2 ] && ok "H an unknown option is usage (exit 2)" || bad "H usage rc=$(rc)"

[ "$fail" = 0 ] && echo "PASS fleet-node-probe-selftest" || echo "FAIL fleet-node-probe-selftest"
exit "$fail"
