#!/bin/bash
# fleet-onboard-drill-selftest.sh — bin/fleet-onboard-drill.sh's refusals
# (issue #1901). The drill opens a real OS login and runs sudo, so this drives
# ONLY the paths that stop before anything is changed — usage, names, the hub,
# the sudo ticket, a login that already exists, a teardown with nothing to
# clean — against PATH shims: a shim sudo answers the ticket question and
# refuses everything else, so no run here can ever create a login.
# Issue #2010 adds --invite (the drill person): its refusals, and a teardown
# whose hub half runs against a curl shim — the drill person deletes ITSELF
# (DELETE /v1/self, the approve code on stdin, never an argv), no operator
# token in the environment, and the residue check reads the hub's 401.
# Issue #3472 adds step 8b's judge: the home's onboarding guide — onboard.stuck
# FAILs, onboarded or a pinned guide window PASSes, off / dismissed SKIPs.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
DRILL="$BIN/fleet-onboard-drill.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/onboard-drill-selftest.XXXXXX")
trap 'rm -rf "$T"' EXIT
FAILS=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

mkdir -p "$T/shim" "$T/conf" "$T/homes"
# sudo: `sudo -n true` is the ticket check — $SUDO_OK decides; anything else
# is refused, so a regression past the preflight cannot touch the machine
cat > "$T/shim/sudo" <<'EOF'
#!/bin/sh
[ "$1" = -n ] && [ "$2" = true ] && [ "${SUDO_OK:-0}" = 1 ] && exit 0
[ "$1" = -n ] && [ "$2" = -v ] && exit 0
echo "selftest sudo shim: refusing $*" >&2; exit 1
EOF
for t in tmux ssh ssh-keygen; do printf '#!/bin/sh\nexit 0\n' > "$T/shim/$t"; done
chmod +x "$T/shim/"*
printf 'export FLEET_HUB_URL="https://hub.example"\n' > "$T/conf/fleet.conf"

# run <expect-rc> <expect-stderr-ERE> <label> <args…>
run() {
  local want=$1 re=$2 label=$3 rc out; shift 3
  out=$(env PATH="$T/shim:$PATH" FLEET_CONF_DIR="$T/conf" FLEET_LOGIN_HOMES="$T/homes" \
        TMPDIR="$T" bash "$DRILL" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && printf '%s\n' "$out" | grep -Eq -- "$re"; then ok "$label (exit $rc)"
  else bad "$label: exit $rc (want $want), output: $(printf '%s' "$out" | head -n 3)"; fi
}

out=$(bash "$DRILL" --help 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '新同事\|new colleague'; then ok '--help prints the header (exit 0)'
else bad "--help: exit $rc"; fi

run 2 'unknown argument'            'an unknown argument'       --frobnicate
run 2 'bad login name'              'a bad login name'          --login 'Bad Name'
run 2 '--name: lowercase'           'a bad scratch name'        --login drilltest --name 'X Y'
run 2 'not a number'                'a non-numeric timeout'     --login drilltest --timeout soon
SUDO_OK=0 run 2 'no sudo ticket'    '需要管理员登录（有 sudo）'  --login drilltest
out=$(env PATH="$T/shim:$PATH" FLEET_CONF_DIR="$T/empty" FLEET_LOGIN_HOMES="$T/homes" bash "$DRILL" --login drilltest 2>&1); rc=$?
if [ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q 'no hub'; then ok 'no hub anywhere (exit 2)'; else bad "no hub: exit $rc: $out"; fi
# a login that exists (the one running this test) → 3, before anything is made
export SUDO_OK=1
run 3 'already exists'              'the login already exists'  --login "$(id -un | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')"
mkdir -p "$T/homes/drillghost"
run 3 'already exists'              'a home with no login'      --login drillghost
run 2 'nothing to clean'            'a teardown of nothing'     --teardown drillnone
run 2 'not an approve code'         '--invite: a malformed code' --login drillx --invite nope
run 2 '--invite: empty'             '--invite given empty (#2865), never a person scans' --login drillx --invite ''
run 2 'needs --login'               '--invite with no --login'  --invite fd_abcdefghijklmnopqrstuvwxyz
# a scratch name inside the login: the prompt line could show it (#2221)
run 2 'part of the login'           '--name inside the login'   --login drill1007b --name drill

# --- the scratch step's row match (issue #2221) ---------------------------------
# the #2221 screen: the shell prompt 「<login>@host % …」 above the split, the
# list 「No sessions」, the typed name on the input line — no row, so it FAILs
scr() { printf '%s\n' 'drill1007b@mini2 ~ % curl -fsSL https://hub.example/install | sh' \
          '  No sessions                 │ drill1007b@mini2 ~ %' "$@"; }
rowm() { bash "$DRILL" --row-named "$1"; }
if scr '› drill                       │' | rowm drill >/dev/null; then bad 'scratch: the prompt line / input line passed as a row'
else ok 'scratch: 「<login>@host %」 + 「No sessions」 is no row (FAIL)'; fi
if scr '› first                       │' | rowm first >/dev/null; then bad 'scratch: the typed name passed as a row'
else ok 'scratch: the input line 「› first」 is no row'; fi
if scr '  ● first-try  scratch        │' | rowm first >/dev/null; then bad 'scratch: first-try matched first'
else ok 'scratch: the name matches as a whole word only'; fi
r=$(scr '  ● first  scratch            │ claude' | rowm first)
if [ "$r" = '  ● first  scratch' ]; then ok 'scratch: a real row in the left column is found'
else bad "scratch: the real row: got '$r'"; fi

# --- the scan step's QR read (issue #2255) ---------------------------------------
# the installer prints 「能力:」 BEFORE its QR: 能力: alone must not read as
# 「no QR」, or scan SKIPs and client types fleet into the waiting QR screen
qrs() { bash "$DRILL" --login drill1007c --qr-state; }
P0='drill1007c@mini2 ~ % curl -fsSL https://hub.example/install | sh'
CAP='能力: 基础 · 承载 未开 · 入口 接'
st=$(printf '%s\n' "$P0" "$CAP" | qrs)
[ "$st" = wait ] && ok 'qr: 「能力:」 alone is wait, not no-QR' || bad "qr: 能力: alone read '$st'"
st=$(printf '%s\n' "$P0" "$CAP" 'fleet · 需要扫码登录' '█▀▀▀▀▀█' '验证码 VVKS-LCLT' | qrs)
[ "$st" = qr ] && ok 'qr: 能力: then the QR (the #2255 screen) reads qr — scan confirms, never SKIP' || bad "qr: the #2255 screen read '$st'"
st=$(printf '%s\n' "$P0" "$CAP" '  ● 新任务                 │ drill1007c@mini2 ~ %' | qrs)
[ "$st" = none ] && ok 'qr: 能力: then the client, no code, reads none (SKIP)' || bad "qr: known computer read '$st'"
st=$(printf '%s\n' "$P0" "$CAP" 'drill1007c@mini2 ~ % ' | qrs)
[ "$st" = none ] && ok 'qr: 能力: then back at the prompt, no code, reads none' || bad "qr: back at prompt read '$st'"
# the newcomer's install prints no 能力 line (issue #2347): 用时 is its end
st=$(printf '%s\n' "$P0" '用时 9 秒' '  ● 新任务                 │ drill1007c@mini2 ~ %' | qrs)
[ "$st" = none ] && ok 'qr: 用时 (no 能力:) then the client, no code, reads none' || bad "qr: newcomer end read '$st'"
st=$(printf '%s\n' "$P0" '用时 9 秒' | qrs)
[ "$st" = wait ] && ok 'qr: 「用时」 alone is wait, not no-QR' || bad "qr: 用时 alone read '$st'"
st=$(printf '%s\n' "$P0" | qrs)
[ "$st" = wait ] && ok 'qr: the typed curl line is no prompt' || bad "qr: the curl line read '$st'"

# --- attach-attachment (EPIC #2482 C9): the image and the session's screen ----
bash "$DRILL" --png "$T/shot.png"
if python3 -c 'import sys,zlib,struct; b=open(sys.argv[1],"rb").read(); assert b[:8]==b"\x89PNG\r\n\x1a\n"; w,h=struct.unpack(">II",b[16:24]); n=struct.unpack(">I",b[33:37])[0]; raw=zlib.decompress(b[41:41+n]); assert (w,h)==(64,64) and raw[1:4]==b"\xd0\x10\x10"' "$T/shot.png" 2>/dev/null
then ok 'attach: the test image is a 64×64 red PNG'; else bad 'attach: --png wrote no valid red PNG'; fi
ats() { bash "$DRILL" --attach-state; }
A0='  ● 看图 这张图是什么颜色  │ ❯ 看图 这张图是什么颜色？只回答一个颜色词'
st=$(printf '%s\n' "$A0" '  │ /Users/drillx/drill-shot.png' | ats)
[ "$st" = wait ] && ok 'attach: the client-side path alone is wait' || bad "attach: client path read '$st'"
st=$(printf '%s\n' "$A0" '  │ /Users/fd-drill/.config/claude-fleet/attachments/a1/drill-shot.png' | ats)
[ "$st" = path ] && ok "attach: the node's path, no answer yet, is path (drill-shot is no colour)" || bad "attach: node path read '$st'"
st=$(printf '%s\n' "$A0" '  │ /Users/fd-drill/.config/claude-fleet/attachments/a1/drill-shot.png' '  │ ⏺ 红色' | ats)
[ "$st" = answered ] && ok 'attach: the path then 红色 is answered' || bad "attach: answer read '$st'"
st=$(printf '%s\n' "$A0" '  │ …/attachments/a1/drill-shot.png' '  │ ⏺ Red.' | ats)
[ "$st" = answered ] && ok 'attach: an English 「Red.」 is answered' || bad "attach: Red read '$st'"
st=$(printf '%s\n' "$A0" '  │ ⏺ 红色' | ats)
[ "$st" = wait ] && ok 'attach: an answer with no file on the session machine is not a pass' || bad "attach: no-path answer read '$st'"
st=$(printf '%s\n' "$A0" '附件没带过去：drill-shot.png（入口还不收附件）' | ats)
[ "$st" = lost ] && ok 'attach: 「附件没带过去」 is lost' || bad "attach: lost read '$st'"
# --- node-restart-resume: the row's key off `fleet ls --json` -------------------
LS='[{"key":"@12","name":"first","node":"m4"},{"key":"wid:8f0c-uuid/5a1e-fid","name":"看图 这张图是什么颜色","node":"m4"}]'
r=$(printf '%s' "$LS" | bash "$DRILL" --ls-row 看图)
[ "$r" = "$(printf 'm4\twid:8f0c-uuid/5a1e-fid\t5a1e-fid')" ] && ok 'restart: ls_row gives node · key · @fleet_id' || bad "restart: ls_row got '$r'"
r=$(printf '%s' "$LS" | bash "$DRILL" --ls-row first)
[ "$(printf '%s' "$r" | cut -f3)" = - ] && ok 'restart: a local row has no @fleet_id (-)' || bad "restart: local row got '$r'"
# a thin client's list comes from its home (issue #3467): the session is the home's
# own row (`@7`), its identity the list's fleet_id field — locate finds it by that
LSO='[{"key":"@7","name":"我的会话 · first","title":"first","node":"mini2","worker_id":"U/f7","fleet_id":"f7"}]'
r=$(printf '%s' "$LSO" | bash "$DRILL" --ls-row first)
[ "$r" = "$(printf 'mini2\t@7\tf7')" ] && ok 'restart: an own row of the home gives its @fleet_id (#3467)' || bad "restart: own row got '$r'"
if printf '%s' "$LS" | bash "$DRILL" --ls-row nope >/dev/null; then bad 'restart: ls_row found a row that is not there'; else ok 'restart: no such row is rc 1'; fi
# found again by IDENTITY (issue #3489): once its agent answered, the session's
# name and title are no longer the words it was opened with — drill 37 lost
# 「first」 and 「看图」 that way. The row kept at step 8 / 9 answers by @fleet_id
# (the list's field or a wid: key's tail), else by key; never by name.
LSR='[{"key":"@7","name":"我的会话 · 颜色问答","title":"颜色问答","node":"mini2","fleet_id":"f7"},{"key":"wid:U/f9","name":"first","node":"m5"}]'
r=$(printf '%s' "$LSR" | bash "$DRILL" --ls-row-id @7 f7)
[ "$r" = "$(printf 'mini2\t@7\tf7')" ] && ok 'identity: a retitled own row is found by its @fleet_id' || bad "identity: own row got '$r'"
r=$(printf '%s' "$LSR" | bash "$DRILL" --ls-row-id @3 f7)
[ "$(printf '%s' "$r" | cut -f2)" = @7 ] && ok 'identity: a new window id (a restart) still finds it by @fleet_id' || bad "identity: restarted got '$r'"
r=$(printf '%s' "$LSR" | bash "$DRILL" --ls-row-id wid:U/f9 f9)
[ "$r" = "$(printf 'm5\twid:U/f9\tf9')" ] && ok 'identity: a hub row by its wid: tail' || bad "identity: wid row got '$r'"
r=$(printf '%s' "$LSR" | bash "$DRILL" --ls-row-id wid:U/f9 -)
[ "$(printf '%s' "$r" | cut -f2)" = wid:U/f9 ] && ok 'identity: no @fleet_id known — by key' || bad "identity: by key got '$r'"
if printf '%s' "$LSR" | bash "$DRILL" --ls-row-id @8 f8 >/dev/null; then bad 'identity: a session that is gone was found'; else ok 'identity: gone is rc 1, never another row by name'; fi
if printf '%s' "$LSR" | bash "$DRILL" --ls-row first >/dev/null && ! printf '%s' "$LSR" | bash "$DRILL" --ls-row 颜色问答x >/dev/null; then ok 'identity: (by name, 「first」 would be the OTHER session — why identity)'; else bad 'identity: name lookup changed'; fi
# step 8 by IDENTITY (issue #3464): the thin client's ⚡ session is 「我的会话」, its
# words the title — the new row is the key that was not in the list before ↵, never
# an older session sharing the words; its node is the home's (#me), never «-»
LS0='[{"key":"@4","name":"test-我的会话 · first","title":"first","node":"mini2"},{"key":"wid:U/old","name":"first","node":"m4"}]'
printf '%s' "$LS0" | bash "$DRILL" --ls-keys > "$T/before.keys"
[ "$(tr '\n' ' ' < "$T/before.keys")" = '@4 wid:U/old ' ] && ok 'step 8: --ls-keys lists the keys before ↵' || bad "step 8: ls-keys got '$(cat "$T/before.keys")'"
LS1='[{"key":"@4","name":"test-我的会话 · first","title":"first","node":"mini2"},{"key":"wid:U/old","name":"first","node":"m4"},{"key":"@7","name":"我的会话 · first","title":"first","node":"mini2"}]'
r=$(printf '%s' "$LS1" | bash "$DRILL" --ls-row first "$T/before.keys")
[ "$r" = "$(printf 'mini2\t@7\t-')" ] && ok 'step 8: the new row is found by key, not by an older row of the same words' || bad "step 8: by identity got '$r'"
r=$(printf '%s' "$LS1" | bash "$DRILL" --ls-row first)
[ "$(printf '%s' "$r" | cut -f2)" = @4 ] && ok 'step 8: by name alone an older row answers (why the before-set)' || bad "step 8: by name got '$r'"
LS2='[{"key":"@4","name":"test-我的会话","node":"mini2"},{"key":"wid:U/old","name":"first","node":"m4"},{"key":"@8","name":"我的会话","title":"","node":"mini2"}]'
r=$(printf '%s' "$LS2" | bash "$DRILL" --ls-row first "$T/before.keys")
[ "$r" = "$(printf 'mini2\t@8\t-')" ] && ok 'step 8: the only new row answers even with no title yet' || bad "step 8: only-new got '$r'"
if printf '%s' "$LS0" | bash "$DRILL" --ls-row first "$T/before.keys" >/dev/null; then bad 'step 8: nothing new still found a row'; else ok 'step 8: nothing new is rc 1'; fi
LS3='[{"key":"@4","name":"x","node":"mini2"},{"key":"wid:U/old","name":"first","node":"m4"},{"key":"@8","name":"a"},{"key":"@9","name":"b"}]'
if printf '%s' "$LS3" | bash "$DRILL" --ls-row first "$T/before.keys" >/dev/null; then bad 'step 8: two unnamed new rows were guessed'; else ok 'step 8: two new rows, neither named: rc 1, never a guess'; fi
if printf 'nope' | bash "$DRILL" --ls-keys >/dev/null; then bad 'step 8: a list that is not JSON gave keys'; else ok 'step 8: a list that is not JSON is rc 1 (then by name)'; fi
# the client's bar alone (C9 run 2: 「⌘N 编排」, no 新任务 row) is the client
st=$(printf '%s\n' "$P0" '用时 9 秒' '  drill1007c  │ ⌘N 编排 · ⌘P 会话与动作' | qrs)
[ "$st" = none ] && ok 'qr: the client by its bar keys (no 新任务) reads none' || bad "qr: bar-only client read '$st'"
# nothing past the preflight ran: no run dir was made
if ls -d "$T"/fleet-onboard-drill.* >/dev/null 2>&1; then bad 'a refused run left a run dir'; else ok 'no refused run made a run dir'; fi

# --- --teardown --invite: the drill person deletes itself on the hub -----------
# curl: logs method · url · stdin body, answers DELETE /v1/self 200 the first
# time and 401 after (the person is gone); argv must never hold the code
cat > "$T/shim/curl" <<'EOF'
#!/bin/bash
out='' m=GET url='' body='' argv="$*"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;; -X) m=$2; shift 2 ;; -w|-H|--max-time|-m) shift 2 ;;
    --data-binary) [ "$2" = @- ] && body=$(cat); shift 2 ;;
    http*) url=$1; shift ;; *) shift ;;
  esac
done
printf '%s %s %s\n' "$m" "$url" "$body" >> "$CURL_LOG"
printf 'ARGV %s\n' "$argv" >> "$CURL_LOG"
n=$(grep -c '^DELETE ' "$CURL_LOG")
if [ "$m" = DELETE ] && [ "$n" -le "${CURL_202:-0}" ]; then
  printf '{"logins":["drillx@m5"],"status":"removing"}' > "$out"; printf 202
elif [ -n "${CURL_ACCOUNTS:-}" ] && [ "${url%/v1/fleet/accounts}" != "$url" ]; then
  # the operator's roster (issue #3471): GET answers the fixture, POST is logged
  if [ "$m" = GET ]; then cat "$CURL_ACCOUNTS" > "$out"; else printf '{}' > "$out"; fi; printf 200
elif [ "$m" = DELETE ] && [ "$n" = $(( ${CURL_202:-0} + 1 )) ]; then
  printf '{"person_id":"drill-1","devices":1,"accounts":1,"nodes":["ep_9"]}' > "$out"; printf 200
else
  printf '{"error":"approve code unknown or expired"}' > "$out"; printf 401
fi
EOF
cat > "$T/shim/remove" <<'EOF'
#!/bin/sh
# the login-remove seam: removes the sandbox home only
rm -rf "$FLEET_LOGIN_HOMES/$1"; echo "removed $1"
EOF
chmod +x "$T/shim/curl" "$T/shim/remove"
mkdir -p "$T/homes/drillx"
CODE=fd_abcdefghijklmnopqrstuvwxyz
out=$(env PATH="$T/shim:$PATH" FLEET_CONF_DIR="$T/conf" FLEET_LOGIN_HOMES="$T/homes" TMPDIR="$T" \
      CURL_LOG="$T/curl.log" FLEET_DRILL_LOGIN_REMOVE="$T/shim/remove" CCQUOTA_VIEWER_TOKEN='' FLEET_HUB_TOKEN='' \
      bash "$DRILL" --teardown drillx --invite "$CODE" 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q 'drill person deleted itself on the hub by the approve code' \
   && printf '%s\n' "$out" | grep -q 'no drill person on the hub'; then ok 'teardown --invite: the drill person deletes itself, residue reads the hub (exit 0)'
else bad "teardown --invite: exit $rc: $(printf '%s' "$out" | tail -n 6)"; fi
if grep -qF "DELETE https://hub.example/v1/self {\"approve_code\":\"$CODE\"}" "$T/curl.log" 2>/dev/null; then ok 'the self-delete went to DELETE /v1/self with the code in the body'
else bad "no DELETE /v1/self with the code: $(cat "$T/curl.log" 2>/dev/null)"; fi
if grep '^ARGV' "$T/curl.log" | grep -q "$CODE"; then bad "the approve code reached curl's argv"; else ok 'the approve code never reached an argv'; fi
if grep -q 'devices/revoke' "$T/curl.log"; then bad 'a drill-person teardown still asked the operator-token revoke'; else ok 'no operator-token revoke on the drill-person path'; fi
r=$(ls "$T"/fleet-onboard-drill.drillx.*/hub-residue.txt 2>/dev/null | head -n 1)
if [ -n "$r" ] && grep -q 'HTTP 401' "$r"; then ok "the hub's 401 is kept as evidence (hub-residue.txt)"; else bad "no hub-residue.txt with the 401 (${r:-none})"; fi

# --- 202 removing (C9 run 2): the hub closes the drill person's login first ---
mkdir -p "$T/homes/drilly"; : > "$T/curl.log"
out=$(env PATH="$T/shim:$PATH" FLEET_CONF_DIR="$T/conf" FLEET_LOGIN_HOMES="$T/homes" TMPDIR="$T" \
      CURL_LOG="$T/curl.log" CURL_202=2 FLEET_DRILL_POLL_SECS=0 FLEET_DRILL_LOGIN_REMOVE="$T/shim/remove" \
      CCQUOTA_VIEWER_TOKEN='' FLEET_HUB_TOKEN='' bash "$DRILL" --teardown drilly --invite "$CODE" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(grep -c '^DELETE ' "$T/curl.log")" = 4 ] && printf '%s\n' "$out" | grep -q 'no drill person on the hub'
then ok 'teardown --invite: 202 removing is waited out, then the person is gone (exit 0)'
else bad "202 removing: exit $rc, $(grep -c '^DELETE ' "$T/curl.log") DELETEs: $(printf '%s' "$out" | tail -n 4)"; fi
# --- the home machine (issue #3471): steps 11–12 look THERE, never here alone ----
# drill 33's login stayed on mini2 (its --home) under offboard PASS + residue
# PASS. The seam stands in for ssh: <dir>/<machine> = what is left there, <dir>/
# <machine>.down = unreachable, neither = the real probe run on this machine
# (where no such login exists — a clean home)
mkdir -p "$T/far"
cat > "$T/shim/homessh" <<'EOF'
#!/bin/sh
m=$1; shift
printf '%s %s\n' "$m" "$*" >> "$T_FAR/calls"
[ ! -f "$T_FAR/$m.down" ] || { echo "ssh: connect to host $m port 22: Operation timed out" >&2; exit 255; }
[ ! -f "$T_FAR/$m" ] || { cat >/dev/null; sed 's/^/left: /' "$T_FAR/$m"; echo probe-ok; exit 0; }
exec "$@"
EOF
chmod +x "$T/shim/homessh"
# far <login> [args…]: a teardown with the seams, no operator token
far() {
  local l=$1; shift
  env PATH="$T/shim:$PATH" FLEET_CONF_DIR="$T/conf" FLEET_LOGIN_HOMES="$T/homes" TMPDIR="$T" T_FAR="$T/far" \
    CURL_LOG="$T/curl.log" FLEET_DRILL_POLL_SECS=0 FLEET_DRILL_REMOVE_SECS=0 FLEET_DRILL_LOGIN_REMOVE="$T/shim/remove" \
    FLEET_DRILL_HOME_SSH="$T/shim/homessh" CCQUOTA_VIEWER_TOKEN="${VIEWER_T:-}" FLEET_HUB_TOKEN='' \
    bash "$DRILL" --teardown "$l" "$@" 2>&1
}
mkdir -p "$T/homes/drillw"; printf 'login record (uid 506)\nhome /Users/drillw\n3 process(es) of drillw\n' > "$T/far/mini2"
out=$(far drillw --home mini2); rc=$?
if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -Eq '^FAIL +residue .*on mini2: login record' \
   && printf '%s\n' "$out" | grep -q 'on mini2: 3 process' && ! printf '%s\n' "$out" | grep -q ': PASS '
then ok 'teardown --home: the login still on the home machine is a residue FAIL naming it (exit 1)'
else bad "teardown --home, login left there: exit $rc: $(printf '%s' "$out" | tail -n 4)"; fi
if grep -q '^mini2 sh -s -- drillw$' "$T/far/calls" 2>/dev/null; then ok 'the residue probe ran ON the home machine, for that login'
else bad "no probe on mini2: $(cat "$T/far/calls" 2>/dev/null)"; fi
r=$(ls "$T"/fleet-onboard-drill.drillw.*/residue-mini2.txt 2>/dev/null | head -n 1)
if [ -n "$r" ] && grep -q 'login record' "$r"; then ok "the home machine's answer is kept (residue-mini2.txt)"; else bad "no residue-mini2.txt (${r:-none})"; fi
# its local login already gone: the teardown still runs, for the home machine
out=$(far drillq --home mini2); rc=$?
if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -Eq '^FAIL +residue .*on mini2'; then ok 'teardown --home with no login here: still checks the home machine (exit 1)'
else bad "teardown --home, nothing here: exit $rc: $(printf '%s' "$out" | tail -n 4)"; fi
# the home machine clean: PASS, and it says it looked there
rm -f "$T/far/mini2"; mkdir -p "$T/homes/drillw"
out=$(far drillw --home mini2); rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -Eq '^PASS +residue +none on .* mini2:'; then ok 'teardown --home, the home machine clean: residue PASS names it (exit 0)'
else bad "teardown --home, clean: exit $rc: $(printf '%s' "$out" | tail -n 4)"; fi
# unreachable: never read as clean
mkdir -p "$T/homes/drillw"; : > "$T/far/mini2.down"
out=$(far drillw --home mini2); rc=$?
if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -Eq '^FAIL +residue .*could not read mini2'; then ok 'a home machine that cannot be read is a FAIL, never clean'
else bad "home machine down: exit $rc: $(printf '%s' "$out" | tail -n 4)"; fi
rm -f "$T/far/mini2.down"
# the hub's roster names the machine (no --home): asked to close it, and a login
# the node could not remove (#3167's eDSPermissionError) is an offboard FAIL with its words
cat > "$T/accounts.json" <<'EOF'
{"accounts":[{"principal_id":"drill-7","hostname":"mini2.local","login":"drillr","state":"failed","op":"create","detail":"login drillr is still on this machine (eDSPermissionError)"},
 {"principal_id":"p-other","hostname":"m4","login":"someone","state":"active","op":"create"}]}
EOF
mkdir -p "$T/homes/drillr"; : > "$T/curl.log"
out=$(VIEWER_T=tok CURL_ACCOUNTS="$T/accounts.json" far drillr); rc=$?
if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q 'asked the hub to close drillr@mini2.local (failed)' \
   && printf '%s\n' "$out" | grep -Eq '^FAIL +offboard .*drillr@mini2.local still failed: .*eDSPermissionError'
then ok "the roster's machine: the hub is asked to close it, a failed remove is an offboard FAIL with the node's words"
else bad "roster close: exit $rc: $(printf '%s' "$out" | tail -n 5)"; fi
if grep -q '^POST https://hub.example/v1/fleet/accounts {"action": "remove", "principal_id": "drill-7", "hostname": "mini2.local"}' "$T/curl.log"
then ok 'the remove went to POST /v1/fleet/accounts for that row only'
else bad "no remove POST for drill-7@mini2.local: $(grep '^POST' "$T/curl.log")"; fi
if grep -q '^mini2.local sh -s -- drillr$' "$T/far/calls"; then ok "the residue probe reached the roster's machine with no --home"
else bad "the roster's machine was not probed: $(cat "$T/far/calls")"; fi

# --- a SIGTERM mid-run is ABORTED, never PASS (#2865) ----------------------------
# the remove seam signals the drill while its teardown runs: the run still
# finishes tearing down, then says ABORTED and exits 143 — no PASS line
cat > "$T/shim/remove-term" <<'EOF2'
#!/bin/sh
p=$PPID d=''   # the OUTERMOST drill process (its subshells carry the same argv)
while [ "${p:-1}" -gt 1 ]; do
  ps -o command= -p "$p" | grep -Eq '^bash [^ ]*/fleet-onboard-drill\.sh --teardown drillz$' && d=$p
  p=$(ps -o ppid= -p "$p" | tr -d ' ')
done
[ -n "$d" ] && kill -TERM "$d"
rm -rf "$FLEET_LOGIN_HOMES/$1"; echo "removed $1"
EOF2
chmod +x "$T/shim/remove-term"
mkdir -p "$T/homes/drillz"
out=$(env PATH="$T/shim:$PATH" FLEET_CONF_DIR="$T/conf" FLEET_LOGIN_HOMES="$T/homes" TMPDIR="$T" \
      FLEET_DRILL_LOGIN_REMOVE="$T/shim/remove-term" CCQUOTA_VIEWER_TOKEN='' FLEET_HUB_TOKEN='' \
      bash "$DRILL" --teardown drillz 2>&1); rc=$?
if [ "$rc" = 143 ] && printf '%s\n' "$out" | grep -q 'ABORTED (interrupted by SIGTERM)' \
   && ! printf '%s\n' "$out" | grep -q ': PASS '; then ok 'a SIGTERM mid-run reads ABORTED, exit 143, no PASS'
else bad "SIGTERM mid-run: exit $rc: $(printf '%s' "$out" | tail -n 4)"; fi
# --- the client step on the thin client's first-session road (issue #3062) -------
# its progress is the client starting, not 「back at the prompt」 (run 17 typed
# `fleet` over 「opening a machine for you」)
for say in 'fleet · opening a machine for you (mini2), about 45s — your first session opens once it is ready' \
           'fleet · 机器 mini2 上的登录开好了，等它的 fleet 报上来（最多再等 590 秒）' \
           'fleet · your first session did not open'; do
  printf '%s\n' "$say" | bash "$DRILL" --thin-first-says && ok "client: the thin road's line counts: ${say#fleet · }" \
    || bad "client: not recognised: $say"
done
printf '%s\n' 'drill@m5 ~ % ' | bash "$DRILL" --thin-first-says && bad 'client: a bare prompt read as the thin road' \
  || ok 'client: a bare prompt is not the thin road'
# the 看台 on screen is the landing too (issue #3276, C9 run 22: the view drawn,
# thin.log never said so — no home sent the OSC 7502 cur its `drawn` waits for before #3489)
printf '%s\n' ' ‹ 2/2 ›  ● 在干活  scratch-1  first session …… @mini2' | bash "$DRILL" --thin-view-up \
  && ok 'client: the drawn 看台 (‹ 2/2 › … @mini2) reads as up' || bad 'client: the drawn 看台 not recognised'
printf '%s\n' 'fleet · 第一个会话开在 mini2' 'drill@m5 ~ % ' | bash "$DRILL" --thin-view-up \
  && bad 'client: the road / a prompt read as the drawn 看台' || ok 'client: the road is not the drawn 看台'
# its outcome, off the newcomer's thin.log: placed + a connection that drew the view
tl() { printf '%s\t%s\t%s\t\t\t\t%s\t%s\t%s\n' "2026-10-11T03:45:50Z" "$@"; }
st=$( { tl first m5 '' '' 'no fleet session is live on m5'; tl first mini2 '' 0 'REMOTE mini2'; tl connect mini2 120 '' ''; } | bash "$DRILL" --thin-first)
[ "$st" = landed ] && ok 'client: placed + drawn = landed' || bad "client: landed read as '$st'"
# the view drawn while the connection is still open (#3155): the `drawn` line,
# no `connect` line yet (that one is written when the connection ends)
st=$( { tl first m5 '' '' x; tl first mini2 '' 0 'REMOTE mini2'; tl drawn mini2 340 '' ''; } | bash "$DRILL" --thin-first)
[ "$st" = landed ] && ok 'client: placed + drawn (connection still open) = landed' || bad "client: drawn-while-open read as '$st'"
st=$( { tl first m5 '' '' x; tl first mini2 '' 0 'REMOTE mini2'; } | bash "$DRILL" --thin-first)
[ "$st" = placed ] && ok 'client: placed, not drawn yet' || bad "client: placed read as '$st'"
st=$( { tl first m5 '' '' x; tl first - '' 1 'No fleet on any of your machines'; tl quit m5 '' 1 'no first session'; } | bash "$DRILL" --thin-first)
[ "$st" = failed ] && ok 'client: no first session = failed' || bad "client: failed read as '$st'"
st=$(tl first m5 '' '' 'no fleet session is live on m5' | bash "$DRILL" --thin-first)
[ "$st" = wait ] && ok 'client: still on the road = wait' || bad "client: wait read as '$st'"
# --- the scratch step's wait while the hub opens the login (issue #2908) -----------
# the ETA on the visible screen: the smallest of the pane's and the bar's, none
# when the screen says no opening
e=$(printf '%s\n' '  first   │ 正在为你开机器（mini2），约 412 秒。' \
      '正在为你开机器（mini2），约 480 秒 — 开好后自动接着开' | bash "$DRILL" --opening-eta)
[ "$e" = 412 ] && ok 'opening: the ETA read off the screen (the smaller one)' || bad "opening: ETA got '$e'"
e=$(printf '%s\n' 'opening a machine for you (mini2), about 95s.' | bash "$DRILL" --opening-eta)
[ "$e" = 95 ] && ok 'opening: the English ETA' || bad "opening: English ETA got '$e'"
e=$(printf '%s\n' '  first  scratch  │ 约 30 秒' | bash "$DRILL" --opening-eta)
[ -z "$e" ] && ok 'opening: a number with no 正在为你开机器 is no ETA' || bad "opening: ETA off a non-opening screen: '$e'"
# an ETA only goes down (#2731): the #2728 run's 313 → 858 is a rise
r=$(printf '480\n412\n412\n5\n' | bash "$DRILL" --eta-rises)
[ -z "$r" ] && ok 'eta: going down (or level) is no rise' || bad "eta: a fall read as a rise: $r"
r=$(printf '313\n858\n100\n' | bash "$DRILL" --eta-rises)
[ "$r" = '313→858' ] && ok 'eta: 313 → 858 is a rise' || bad "eta: the rise got '$r'"
# the wait outlasts the hub's own give-up: never again a cap shorter than a
# real create (360 s judged a login still opening a FAIL, #2908)
GIVEUP=$(sed -n 's/^[[:space:]]*openingGiveUp[[:space:]]*=[[:space:]]*\([0-9]*\) \* time\.Minute.*/\1/p' \
           "$(dirname "$DRILL")/../tokenledger/internal/api/fleet_opening.go")
CAP=$(sed -n 's/^OPENING_CAP=\${FLEET_DRILL_OPENING_SECS:-\([0-9]*\)}$/\1/p' "$DRILL")
if [ -n "$GIVEUP" ] && [ -n "$CAP" ] && [ "$CAP" -gt $((GIVEUP * 60)) ]; then
  ok "opening: the drill waits ${CAP}s, past the hub's ${GIVEUP} min give-up"
else bad "opening: the drill's cap '${CAP}'s is not past the hub's give-up '${GIVEUP}' min"; fi
# while the screen says opening the deadline is the cap, read off the VISIBLE
# screen — the scrollback keeps the words after the login is up
if grep -q 'deadline=\$open_end' "$DRILL" && grep -q '^screen() { tmux_own capture-pane -p -J -t ' "$DRILL"; then
  ok 'opening: waits to the cap while the visible screen says so'
else bad 'opening: the wait is not held by the visible screen'; fi
# ssh's host-key question on the way to the opened machine is named, never
# read as 「没开好」 (#2139 run 13)
if grep -q 'PW_K=hostkey; break' "$DRILL" && grep -q '^    hostkey)$' "$DRILL" \
   && printf '%s\n' "Are you sure you want to continue connecting (yes/no/[fingerprint])?" \
      | grep -Eq "$(sed -n "s/^SCRATCH_HOSTKEY='\(.*\)'$/\1/p" "$DRILL")"; then
  ok 'scratch: the ssh host-key question is its own failure'
else bad 'scratch: the ssh host-key question is not caught'; fi
# bash 3.2 in a UTF-8 locale reads 「$opening，」's full-width comma as part of
# the name — under set -u the drill died at scratch (C9 run 4): braces only
bad_vars=$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~[:space:]]' "$DRILL" | grep -vE '^[0-9]+:[[:space:]]*#')
if [ -z "$bad_vars" ]; then ok 'no $name directly before a non-ASCII byte (write ${name})'
else bad "a \$name runs into a non-ASCII byte (bash 3.2 reads it as the name): $bad_vars"; fi
# step 8b onboard-guide (issue #3472): drill 34 passed while the home's
# onboard.stuck said the guide never opened — the probe reads the home's
# global/ as the login, guide_state judges it, and the run reaches the step
G="$T/guide"; mkdir -p "$G/c/global" "$G/c/fleets"
gstate() { env HOME="$G" FLEET_CONF_DIR="$G/c" bash "$DRILL" --guide-probe 2>/dev/null | bash "$DRILL" --guide-state; }
[ "$(gstate)" = 'skip onboarding off on the home (no onboard.pending)' ] || bad "guide: no pending marker must SKIP (got '$(gstate)')"
: > "$G/c/global/onboard.pending"
[ "$(gstate)" = 'wait pending' ] || bad "guide: pending must wait (got '$(gstate)')"
printf '引导窗口没能打开：dash-raw-session: machine memory tight — 暂停开新：内存紧张 · 连续 3 次没开口 · 2026-10-11 09:00\n' > "$G/c/global/onboard.stuck"
case "$(gstate)" in 'fail 引导窗口没能打开：dash-raw-session: machine memory tight'*'连续 3 次没开口'*) ok 'guide: onboard.stuck FAILs quoting its line' ;;
  *) bad "guide: onboard.stuck must FAIL quoting it (got '$(gstate)')" ;; esac
rm -f "$G/c/global/onboard.stuck"
TMUXR=''
for d in $(printf '%s' "$PATH" | tr ':' ' '); do case "$d" in *tmux-shim*) continue ;; esac; [ -x "$d/tmux" ] && { TMUXR="$d/tmux"; break; }; done
if [ -n "$TMUXR" ]; then
  GL="odguide$$"; mkdir -p "$G/c/fleets/$GL" "$G/tb"; ln -sf "$TMUXR" "$G/tb/tmux"
  TMUX='' "$TMUXR" -L "$GL" new-session -d -s "$GL" -n home 'sleep 60' 2>/dev/null
  TMUX='' "$TMUXR" -L "$GL" new-window -d -t "$GL" -n guide 'sleep 60' 2>/dev/null
  TMUX='' "$TMUXR" -L "$GL" set-option -w -t "$GL:guide" @pin 1 2>/dev/null
  r=$(env PATH="$G/tb:$PATH" HOME="$G" FLEET_CONF_DIR="$G/c" bash "$DRILL" --guide-probe 2>/dev/null | bash "$DRILL" --guide-state)
  TMUX='' "$TMUXR" -L "$GL" kill-server >/dev/null 2>&1
  [ "$r" = 'pass guide window up' ] && ok 'guide: a pinned guide window on the home PASSes' || bad "guide: a pinned guide window must PASS (got '$r')"
fi
: > "$G/c/global/onboarded"
[ "$(gstate)" = 'pass onboarded' ] || bad "guide: onboarded must PASS (got '$(gstate)')"
[ "$(printf 'garbage\n' | bash "$DRILL" --guide-state)" = 'wait no answer from the home: garbage ' ] || bad 'guide: an unreadable answer waits'
if grep -q 'step_scratch && { step_answer || :; step_guide || :; step_attach' "$DRILL" \
   && grep -q 'failstep onboard-guide "the home.s onboarding guide stopped' "$DRILL"; then ok 'guide: the run reaches step 8b, onboard.stuck is a FAIL'
else bad 'guide: the main run does not reach step_guide'; fi
[ "$FAILS" = 0 ] && { echo 'fleet-onboard-drill-selftest: PASS'; exit 0; }
echo "fleet-onboard-drill-selftest: FAIL ($FAILS)"; exit 1
