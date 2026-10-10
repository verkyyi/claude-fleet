#!/bin/bash
# newcomer-cn-selftest.sh — the 国内 newcomer run's pieces (issue #2888):
#   A  fleet-onboard-judge.sh's agent_state / curl_noise on captured screens
#   B  fleet-onboard-drill.sh still reads its screens through the shared judge
#      (the --qr-state / --row-named seams answer as before)
#   C  newcomer-cn.sh: --help, bad arguments and a missing admin token stop at
#      the preflight (exit 2) with nothing changed — no login made
#   D  newcomer-cn.yml (.github/workflows, else staged in extras/workflows) runs bin/newcomer-cn.sh, only where
#      vars.NEWCOMER_CN_RUNNER names a runner, with the admin token from a Secret
set -u
BIN="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$BIN/.." && pwd -P)"
fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# shellcheck source=fleet-onboard-judge.sh
. "$BIN/fleet-onboard-judge.sh"

# --- A ---------------------------------------------------------------------------
is 'A1 placement still going reads wait' "$(printf '正在为你开机器…\n' | agent_state 好)" wait
is 'A2 the agent box reads up' "$(printf '╭──────────╮\n│ ✻ Welcome to Claude Code │\n╰──────────╯\n' | agent_state 好)" up
is 'A3 the prompt line alone reads up' "$(printf '│ ❯ \n' | agent_state 好)" up
is 'A4 the asked sentence is no answer' "$(printf '> 只回一个字：好\n' | agent_state 好)" up
is 'A5 a ⏺ reply carrying the word reads answered' "$(printf '> 只回一个字：好\n\n⏺ 好\n\n❯ \n' | agent_state 好)" answered
is 'A6 a ⏺ reply without it is not' "$(printf '> 只回一个字：好\n⏺ Thinking about it\n' | agent_state 好)" up
is 'A7 the sentinel reads exited' "$(printf 'fleet · 入口不肯开会话\n__NCCN_EXIT=3\n' | agent_state 好)" exited
is 'A8 exited wins over a stale answer' "$(printf '⏺ 好\n__NCCN_EXIT=0\n' | agent_state 好)" exited
is 'A9 curl_noise counts curl: ( lines' "$(printf 'x\ncurl: (6) Could not resolve\ny\ncurl: (28) timeout\n' | curl_noise)" 2
is 'A10 curl_noise on a clean screen is 0' "$(printf 'all good\n' | curl_noise)" 0

# --- B ---------------------------------------------------------------------------
is 'B1 onboard-drill --qr-state through the shared judge' \
  "$(printf '验证码 ABCD-EFGH\n' | bash "$BIN/fleet-onboard-drill.sh" --qr-state)" qr
r=$(printf ' first          │ home\n › first\n' | bash "$BIN/fleet-onboard-drill.sh" --row-named first)
is 'B2 onboard-drill --row-named through the shared judge' "$r" ' first'
grep -q '^\. "\$BIN/fleet-onboard-judge.sh"' "$BIN/fleet-onboard-drill.sh" && ok 'B3 onboard-drill sources the judge' || bad 'B3 onboard-drill sources the judge'
grep -q '^list_row_named()\|^qr_state()' "$BIN/fleet-onboard-drill.sh" && bad 'B4 a judge function is still copied in onboard-drill' || ok 'B4 no copy left in onboard-drill'

# --- C ---------------------------------------------------------------------------
out=$(bash "$BIN/newcomer-cn.sh" --help 2>&1); rc=$?
is 'C1 --help exits 0' "$rc" 0
case "$out" in *'≤ 60 s'*'fleet connect'*) ok 'C2 --help names the steps and budgets' ;; *) bad 'C2 --help names the steps and budgets' ;; esac
out=$(env -u CCQUOTA_VIEWER_TOKEN bash "$BIN/newcomer-cn.sh" --login nobody 2>&1); rc=$?
is 'C3 a login that is no drill name exits 2' "$rc" 2
out=$(env -u CCQUOTA_VIEWER_TOKEN bash "$BIN/newcomer-cn.sh" --login drillcnself 2>&1); rc=$?
is 'C4 no admin token (or not Linux / no root) exits 2' "$rc" 2
case "$out" in *'Linux only'*|*'CCQUOTA_VIEWER_TOKEN'*|*'needs root'*|*'not found'*) ok 'C5 the preflight says why' ;; *) bad "C5 the preflight says why ($out)" ;; esac
id drillcnself >/dev/null 2>&1 && bad 'C6 the preflight made a login' || ok 'C6 nothing changed (no login)'
out=$(bash "$BIN/newcomer-cn.sh" --proxy ftp://x 2>&1); rc=$?
is 'C7 a proxy that is no proxy URL exits 2' "$rc" 2

# --- D ---------------------------------------------------------------------------
# staged under extras/workflows/ until a push with `workflow` scope moves it in
WF="$ROOT/.github/workflows/newcomer-cn.yml"
[ -f "$WF" ] || WF="$ROOT/extras/workflows/newcomer-cn.yml"
if [ -f "$WF" ]; then
  grep -q 'bin/newcomer-cn.sh' "$WF" && ok 'D1 the workflow runs bin/newcomer-cn.sh' || bad 'D1 the workflow runs bin/newcomer-cn.sh'
  grep -q "vars.NEWCOMER_CN_RUNNER != ''" "$WF" && ok 'D2 off until a runner is named' || bad 'D2 off until a runner is named'
  grep -q 'secrets.FLEET_HUB_ADMIN_TOKEN' "$WF" && ok 'D3 the admin token comes from a Secret' || bad 'D3 the admin token comes from a Secret'
  grep -Eq "^ *workflows: \['stable publish'\]" "$WF" && ok 'D4 it walks again after a stable publish' || bad 'D4 it walks again after a stable publish'
else
  bad 'D0 no newcomer-cn.yml (.github/workflows or extras/workflows)'
fi

[ "$fails" = 0 ] && { echo 'newcomer-cn-selftest: PASS'; exit 0; }
echo "newcomer-cn-selftest: $fails failure(s)"; exit 1
