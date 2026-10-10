#!/bin/bash
# fleet-debug-desk-selftest.sh — the node's half of the hub's debug reports
# (issue #2893, EPIC #2889 C4): bin/fleet-debug-desk.py behind the debugger's
# three fleet tools (debug_bundle · debug_publish · debug_propose) and the feed
# bin/fleet_steward.py's beat tells the orchestrator from. The hub is a fake
# (FLEET_DEBUG_DESK_HUB_CMD); the hub's own half is Go (fleet_debug_test.go).
#
#   A  fetch: the bundle unpacked under $TMPDIR/fleet-debug/<id>/bundle + hub.json;
#      a member naming a path outside it is refused, nothing written outside
#   B  publish: a missing section, more than 3 steps, a two-line command or a
#      credential-shaped command is refused HERE (exit 2, nothing sent); a good
#      result is POSTed as it is; a bad id never reaches the hub
#   C  propose: one line POSTed; a credential-shaped one refused
#   D  feed: one line per report change for the orchestrator (concluded · cause ·
#      link, 要我们改的), the cursor kept, a report seen again unchanged says
#      nothing; the steward's debug_step sends each line to `orchestrator`, only
#      when an orchestrator window is there, and backs off an hour on a refusal
#   E  no hub / no node token: exit 3, nothing written
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/debug-desk-st.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

export FLEET_CONF_DIR="$WORK/conf" TMPDIR="$WORK/tmp" HOME="$WORK/home"
mkdir -p "$FLEET_CONF_DIR" "$TMPDIR" "$HOME"
D() { python3 "$BIN/fleet-debug-desk.py" "$@"; }

# the fake hub: logs `<method> <path>` + the body, answers from $WORK/answers/<key>
mkdir -p "$WORK/answers"
cat > "$WORK/hub" <<'EOF'
#!/bin/bash
w=$(dirname "$0")
body=$(cat)
printf '%s %s\t%s\n' "$1" "$2" "$body" >> "$w/hub.log"
key=$(printf '%s %s' "$1" "${2%%\?*}" | tr '/ ' '__')
if [ -f "$w/answers/$key" ]; then cat "$w/answers/$key"; else printf '404\nno such\n'; fi
EOF
chmod +x "$WORK/hub"
export FLEET_DEBUG_DESK_HUB_CMD="$WORK/hub"
ans() { printf '%s\n' "$2" > "$WORK/answers/$(printf '%s' "$1" | tr '/ ' '__')"; cat >> "$WORK/answers/$(printf '%s' "$1" | tr '/ ' '__')"; }

# --- A fetch ---------------------------------------------------------------
mkdir -p "$WORK/b/bundle/logs"
printf 'FAIL tls\n' > "$WORK/b/bundle/doctor.txt"; printf 'closed by client\n' > "$WORK/b/bundle/logs/connect.log"
printf '{"v":1}\n' > "$WORK/b/bundle/manifest.json"
(cd "$WORK/b" && tar czf "$WORK/good.tgz" bundle)
ans "GET /v1/node/debug/abcdefgh/bundle" 200 < "$WORK/good.tgz"
ans "GET /v1/node/debug/abcdefgh/hub.json" 200 <<<'{"who": "arvin"}'
out=$(D fetch abcdefgh 2>&1); rc=$?
dst="$TMPDIR/fleet-debug/abcdefgh"
if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | head -1)" = "$dst" ] && [ -f "$dst/bundle/bundle/doctor.txt" ] \
   && [ -f "$dst/bundle/bundle/logs/connect.log" ] && grep -q arvin "$dst/hub.json"; then
  ok "A fetch: the bundle under \$TMPDIR/fleet-debug/<id>/bundle, hub.json beside it, the list printed"
else bad "A fetch rc=$rc out=$out"; fi
python3 - "$WORK/evil.tgz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tf:
    data = b"pwned\n"
    ti = tarfile.TarInfo("../../escape.txt"); ti.size = len(data); tf.addfile(ti, io.BytesIO(data))
PY
ans "GET /v1/node/debug/bbbbbbbb/bundle" 200 < "$WORK/evil.tgz"
ans "GET /v1/node/debug/bbbbbbbb/hub.json" 200 <<<'{}'
D fetch bbbbbbbb >/dev/null 2>&1; rc=$?
if [ "$rc" = 4 ] && [ ! -e "$TMPDIR/fleet-debug/escape.txt" ] && [ ! -e "$TMPDIR/escape.txt" ]; then
  ok "A fetch: a member naming a path outside the bundle is refused (exit 4), nothing written outside"
else bad "A fetch of an escaping bundle rc=$rc"; fi

# --- B publish -------------------------------------------------------------
: > "$WORK/hub.log"
good='{"cause":"python3 没装证书库","evidence":["doctor.txt: tls FAIL"],"steps":[{"why":"装证书","cmd":"fleet login"}],"ours":[]}'
for c in \
  'no cause|{"cause":"","evidence":["x"],"steps":[{"why":"a","cmd":"b"}],"ours":[]}|缺「是什么问题」' \
  'no evidence|{"cause":"c","evidence":[],"steps":[{"why":"a","cmd":"b"}],"ours":[]}|缺「证据」' \
  'four steps|{"cause":"c","evidence":["e"],"steps":[{"why":"a","cmd":"a"},{"why":"b","cmd":"b"},{"why":"c","cmd":"c"},{"why":"d","cmd":"d"}],"ours":[]}|最多 3 步' \
  'no ours|{"cause":"c","evidence":["e"],"steps":[{"why":"a","cmd":"b"}]}|缺「要我们改的」' \
  'two lines|{"cause":"c","evidence":["e"],"steps":[{"why":"a","cmd":"b\nc"}],"ours":[]}|要是一行' \
  'a token|{"cause":"c","evidence":["e"],"steps":[{"why":"a","cmd":"export GH_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123"}],"ours":[]}|steps[0].cmd 里有像'; do
  name=${c%%|*}; rest=${c#*|}; json=${rest%|*}; want=${rest##*|}
  err=$(printf '%s' "$json" | D publish abcdefgh - 2>&1 >/dev/null); rc=$?
  if [ "$rc" = 2 ] && printf '%s' "$err" | grep -qF -- "$want"; then ok "B publish refuses: $name"
  else bad "B publish $name: rc=$rc err=$err"; fi
done
[ -s "$WORK/hub.log" ] && bad "B a refused result reached the hub: $(cat "$WORK/hub.log")" || ok "B a refused result never reaches the hub"
ans "POST /v1/node/debug/abcdefgh/page" 200 <<<'{"id":"abcdefgh","state":"concluded","url":"https://hub/s/abcdefgh"}'
out=$(printf '%s' "$good" | D publish abcdefgh - 2>&1); rc=$?
sent=$(cut -f2- "$WORK/hub.log")
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '已出结论 · https://hub/s/abcdefgh' \
   && python3 -c 'import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); sys.exit(a!=b)' "$sent" "$good"; then
  ok "B publish: a good result is POSTed as it is, the link printed"
else bad "B publish good: rc=$rc out=$out sent=$sent"; fi
D publish 'ABC;rm' - <<<"$good" >/dev/null 2>&1; [ $? = 2 ] && ok "B a bad report id is refused before the hub" || bad "B a bad id passed"

# --- C propose -------------------------------------------------------------
: > "$WORK/hub.log"
ans "POST /v1/node/debug/abcdefgh/propose" 200 <<<'{"id":"abcdefgh"}'
out=$(D propose abcdefgh '客户端连续失败三次时  主动提示' 2>&1); rc=$?
if [ "$rc" = 0 ] && grep -q '"text": "客户端连续失败三次时 主动提示"' "$WORK/hub.log"; then
  ok "C propose: one line POSTed (spaces folded)"
else bad "C propose rc=$rc out=$out log=$(cat "$WORK/hub.log")"; fi
D propose abcdefgh 'use sk-ant-abcdefghijklmnop' >/dev/null 2>&1; [ $? = 2 ] && ok "C a credential-shaped proposal is refused" || bad "C a credential-shaped proposal passed"

# --- D feed + the steward's line ---------------------------------------------
ans "GET /v1/node/debug/feed" 200 <<'EOF'
{"reports":[{"id":"abcdefgh","state":"concluded","who":"arvin","cause":"python3 没装证书库","url":"https://hub/s/abcdefgh","ours":["安装时查证书库"],"updated_at":"2026-10-10T07:00:00Z"},
{"id":"cccccccc","state":"diagnosing","who":"fp 12345678","url":"https://hub/s/cccccccc","updated_at":"2026-10-10T07:01:00Z"},
{"id":"dddddddd","state":"unfinished","who":"fp 12345678","why":"诊断员 15 分钟没交页 — 已转给管理员","url":"https://hub/s/dddddddd","updated_at":"2026-10-10T07:02:00Z"}]}
EOF
: > "$WORK/hub.log"
out=$(D feed); rc=$?
if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | grep -c '^〔诊断〕')" = 2 ] \
   && printf '%s\n' "$out" | grep -qx '〔诊断〕arvin · python3 没装证书库 · https://hub/s/abcdefgh' \
   && printf '%s\n' "$out" | grep -q '要我们改的（你点头才立单，file_issue）：安装时查证书库' \
   && printf '%s\n' "$out" | grep -q '〔诊断〕fp 12345678 · 没看完（诊断员 15 分钟没交页 — 已转给管理员）· https://hub/s/dddddddd'; then
  ok "D feed: concluded and unfinished say one line each (cause · link · 要我们改的); diagnosing says nothing"
else bad "D feed rc=$rc out=$out"; fi
out2=$(D feed); after=$(sed -n 's/.*after=\([^	]*\).*/\1/p' "$WORK/hub.log" | tail -1)
if [ -z "$out2" ] && [ "$after" = "2026-10-10T07%3A02%3A00Z" ]; then
  ok "D feed: the cursor kept (after=the last change); a report seen again unchanged says nothing"
else bad "D feed again: out=$out2 after=$after log=$(cat "$WORK/hub.log")"; fi

# the steward's beat: debug_step → send(orchestrator, line)
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s/sent"; cat >> "%s/sent"; printf "\\n--\\n" >> "%s/sent"\n' "$WORK" "$WORK" "$WORK" > "$WORK/send"
printf '#!/bin/sh\nprintf "{\\"lines\\": [\\"〔诊断〕arvin · 证书 · https://hub/s/abcdefgh\\"]}"\nexit ${DBG_RC:-0}\n' > "$WORK/feed"
printf '#!/bin/sh\nprintf "@1\\torchestrator\\tidle\\t\\t\\t\\t\\t\\n"\n' > "$WORK/wins-orch"
printf '#!/bin/sh\nprintf "@1\\tworker\\tidle\\t7\\to/r\\t\\t\\t\\n"\n' > "$WORK/wins-none"
chmod +x "$WORK/send" "$WORK/feed" "$WORK/wins-orch" "$WORK/wins-none"
step() {  # step <windows cmd> <now>
  FLEET_STEWARD_WINDOWS_CMD="$WORK/$1" FLEET_STEWARD_DEBUG_CMD="$WORK/feed" FLEET_STEWARD_SEND_CMD="$WORK/send" \
    python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_steward as s; print(s.debug_step("fleet", int(sys.argv[2])))' "$BIN" "$2"
}
rm -f "$WORK/sent" "$FLEET_CONF_DIR/global/debug-feed.step"
n0=$(step wins-none 1000)
n1=$(step wins-orch 1000)
n2=$(step wins-orch 1030)
n3=$(step wins-orch 1061)
if [ "$n0" = 0 ] && [ "$n1" = 1 ] && [ "$n2" = 0 ] && [ "$n3" = 1 ] && [ "$(grep -c '^orchestrator$' "$WORK/sent")" = 2 ] \
   && grep -q '〔诊断〕arvin · 证书 · https://hub/s/abcdefgh' "$WORK/sent"; then
  ok "D steward: each line to the orchestrator; none read without an orchestrator window; at most once a minute"
else bad "D steward: n=$n0/$n1/$n2/$n3 sent=$(cat "$WORK/sent" 2>/dev/null)"; fi
rm -f "$FLEET_CONF_DIR/global/debug-feed.step"
nr=$(DBG_RC=4 step wins-orch 5000); next=$(cat "$FLEET_CONF_DIR/global/debug-feed.step")
[ "$nr" = 0 ] && [ "$next" = 8600 ] && ok "D steward: a refused feed (not the orchestrator's login) asks again in an hour" \
  || bad "D steward refused: n=$nr next=$next"

# --- E no hub --------------------------------------------------------------
unset FLEET_DEBUG_DESK_HUB_CMD
rm -rf "$FLEET_CONF_DIR/global"
FLEET_HUB_URL='' CCQUOTA_HUB_URL='' D feed >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ ! -e "$FLEET_CONF_DIR/global/debug-feed.json" ] && ok "E no hub here: exit 3, nothing written" \
  || bad "E no hub: rc=$rc"

[ "$fails" = 0 ] && { echo "fleet-debug-desk selftest: all green"; exit 0; }
echo "fleet-debug-desk selftest: $fails failed"; exit 1
