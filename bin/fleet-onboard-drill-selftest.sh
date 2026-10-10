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
if printf '%s' "$LS" | bash "$DRILL" --ls-row nope >/dev/null; then bad 'restart: ls_row found a row that is not there'; else ok 'restart: no such row is rc 1'; fi
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
# bash 3.2 in a UTF-8 locale reads 「$opening，」's full-width comma as part of
# the name — under set -u the drill died at scratch (C9 run 4): braces only
bad_vars=$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~[:space:]]' "$DRILL" | grep -vE '^[0-9]+:[[:space:]]*#')
if [ -z "$bad_vars" ]; then ok 'no $name directly before a non-ASCII byte (write ${name})'
else bad "a \$name runs into a non-ASCII byte (bash 3.2 reads it as the name): $bad_vars"; fi
[ "$FAILS" = 0 ] && { echo 'fleet-onboard-drill-selftest: PASS'; exit 0; }
echo "fleet-onboard-drill-selftest: FAIL ($FAILS)"; exit 1
