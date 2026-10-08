#!/bin/bash
# fleet-onboard-clock-selftest.sh — the 60-second drill's own rules, with no hub
# and no terminal (issue #2267). The whole road runs in bin/newcomer-e2e.sh's
# clock step against a hub built from the checkout (CI's client-e2e); here:
#
#   A  refusals: no hub, a bad --runs / --gate, a malformed approve code, one
#      approve code for several runs, an approve code with no --login — all
#      exit 2 before anything is made
#   B  the concept scan (--concepts-of): every word of EPIC #2259's list found
#      on a screen, each once, none on a newcomer's screen without them — and
#      four CJK words stay four (a UTF-8 `sort -u` collates them as one)
#   C  the scrub (--scrub-of): an invite in the /i/ line, an approve code, a
#      验证码 in a link — none survives into a saved screen
#   D  fleet-onboard-drill.sh --runs forwards to the clock (its refusal answers)
#   E  fleet-login.py's device name follows FLEET_DEVICE_NAME, sanitized
set -u
BIN="$(cd "$(dirname "$0")" && pwd -P)"
C="$BIN/fleet-onboard-clock.sh"
fails=0 n=0
ok() { n=$((n + 1)); printf 'ok   %s\n' "$1"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); printf 'FAIL %s\n     got: %s\n' "$1" "$2"; }
eq() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3 (want $2)"; }
T=$(mktemp -d "${TMPDIR:-/tmp}/clock-st.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
export FLEET_CONF_DIR="$T/conf"   # no fleet.conf: --hub prod finds no address

# --- A refusals ------------------------------------------------------------------
rc_of() { "$@" >"$T/out" 2>&1; echo $?; }
eq 'A1 no hub → 2' 2 "$(rc_of bash "$C" --hub prod)"
grep -q 'no hub' "$T/out" && ok 'A1 says no hub' || bad 'A1 says no hub' "$(cat "$T/out")"
eq 'A2 --runs 0 → 2' 2 "$(rc_of bash "$C" --hub http://127.0.0.1:9 --runs 0)"
eq 'A3 --runs x → 2' 2 "$(rc_of bash "$C" --hub http://127.0.0.1:9 --runs x)"
eq 'A4 --gate nope → 2' 2 "$(rc_of bash "$C" --hub http://127.0.0.1:9 --gate nope)"
eq 'A5 malformed approve code → 2' 2 "$(FLEET_DRILL_INVITE=nope rc_of bash "$C" --hub http://127.0.0.1:9 --login drillx)"
eq 'A6 one approve code, 3 runs → 2' 2 \
  "$(FLEET_DRILL_INVITE=fd_abcdefghijklmnopqrstuvwxyz rc_of bash "$C" --hub http://127.0.0.1:9 --runs 3 --login drillx)"
eq 'A7 approve code, no --login → 2' 2 "$(FLEET_DRILL_INVITE=fd_abcdefghijklmnopqrstuvwxyz rc_of bash "$C" --hub http://127.0.0.1:9)"
eq 'A8 malformed invite code → 2' 2 "$(FLEET_DRILL_INSTALL_INVITE='a b' rc_of bash "$C" --hub http://127.0.0.1:9)"
eq 'A9 unknown argument → 2' 2 "$(rc_of bash "$C" --hub http://127.0.0.1:9 --frobnicate)"

# --- B concepts ------------------------------------------------------------------
got=$(printf '%s\n' '能力: 基础 · 承载 未开 · 入口 接' '入口: 登录（扫一次码）时自动登记为只协调的节点' \
        '或按 q 改用手机扫码' '用前缀键 ⌃b 切到右侧' '选仓库，再选开在哪' '记成 issue 还是草稿会话' \
      | LANG=en_US.UTF-8 bash "$C" --concepts-of)
for w in 入口 承载 只协调 扫码 前缀键 右侧 选仓库 开在哪 '记成 issue' 草稿会话; do
  case " $got " in *"$w"*) ok "B1 found $w" ;; *) bad "B1 found $w" "$got" ;; esac
done
eq 'B2 a newcomer screen with none' '' "$(printf '%s\n' '✓ 已安装 fleet' '这里和本地运行 claude 一样；要在某个仓库里做，直接告诉我仓库名' '❯ ' \
                                          | bash "$C" --concepts-of)"
# the run's total is deduped in the C locale: a UTF-8 `sort -u` collates CJK
# words as equal and kept one of four
grep -q '^CONCEPTS_ALL=.*LC_ALL=C sort -u' "$C" && ok 'B3 the total dedupes with LC_ALL=C' \
  || bad 'B3 the total dedupes with LC_ALL=C' "$(grep '^CONCEPTS_ALL=' "$C")"

# --- C scrub ---------------------------------------------------------------------
got=$(printf '%s\n' 'newcomer% curl -fsSL https://hub.example/i/Ab_Cd-EfGhIjKlMnOp12 | sh' \
        'approve fd_abcdefghijklmnopqrstuvwxyz' '没看到？打开 https://hub.example/fleet/login?code=WXYZ-ABCD ，或按 q' \
      | bash "$C" --scrub-of)
case "$got" in *Ab_Cd-EfGh*|*fd_abcdefgh*|*WXYZ-ABCD*) bad 'C1 no code survives' "$got" ;; *) ok 'C1 no code survives' ;; esac
case "$got" in *'/i/… | sh'*) ok 'C2 the line keeps its shape' ;; *) bad 'C2 the line keeps its shape' "$got" ;; esac

# --- D the drill forwards --runs ---------------------------------------------------
eq 'D1 fleet-onboard-drill.sh --runs 0 → the clock refuses' 2 "$(rc_of bash "$BIN/fleet-onboard-drill.sh" --hub http://127.0.0.1:9 --runs 0)"
grep -q 'fleet-onboard-clock: --runs' "$T/out" && ok 'D2 it is the clock that answers' || bad 'D2 it is the clock that answers' "$(cat "$T/out")"

# --- E the device name -------------------------------------------------------------
dn() { env "$@" python3 -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("fl", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.device_name())' "$BIN/fleet-login.py" 2>/dev/null; }
eq 'E1 FLEET_DEVICE_NAME names the device' newcomer-1-42 "$(dn FLEET_DEVICE_NAME=newcomer-1-42)"
eq 'E2 sanitized' 'abc' "$(dn FLEET_DEVICE_NAME='a b/c;')"
eq 'E3 unset → the hostname' "$(python3 -c 'import socket; print(socket.gethostname().split(".")[0][:64])')" "$(dn FLEET_DEVICE_NAME=)"

printf '\nfleet-onboard-clock-selftest: %d checks, %d failed\n' "$n" "$fails"
[ "$fails" = 0 ]
