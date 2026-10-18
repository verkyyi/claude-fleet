#!/bin/bash
# fleet-debug-desk-selftest.sh — the node's half of the hub's debug reports
# (issue #2893, EPIC #2889 C4): bin/fleet-debug-desk.py behind the debugger's
# three fleet tools (debug_bundle · debug_publish · debug_propose). The hub is a fake
# (FLEET_DEBUG_DESK_HUB_CMD); the hub's own half is Go (fleet_debug_test.go).
#
#   A  fetch: the bundle unpacked under $TMPDIR/fleet-debug/<id>/bundle + hub.json;
#      a member naming a path outside it is refused, nothing written outside
#   B  publish: a missing section, more than 3 steps, a two-line command or a
#      credential-shaped command is refused HERE (exit 2, nothing sent); a good
#      result is POSTed as it is; a bad id never reaches the hub
#   C  propose: one line POSTed; a credential-shaped one refused
#   D  the steward's feed is gone (issue #4339): `feed` is a usage error
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
ans "GET /v1/node/debug/abcdefgh/hub.json" 200 <<<'{"who": "alice"}'
out=$(D fetch abcdefgh 2>&1); rc=$?
dst="$TMPDIR/fleet-debug/abcdefgh"
if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | head -1)" = "$dst" ] && [ -f "$dst/bundle/bundle/doctor.txt" ] \
   && [ -f "$dst/bundle/bundle/logs/connect.log" ] && grep -q alice "$dst/hub.json"; then
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

# --- D no feed (issue #4339) ---------------------------------------------------
D feed >/dev/null 2>&1; [ $? = 2 ] && ok "D feed is gone: a usage error (exit 2)" || bad "D feed still answers"

# --- E no hub --------------------------------------------------------------
unset FLEET_DEBUG_DESK_HUB_CMD
rm -rf "$FLEET_CONF_DIR/global"
FLEET_HUB_URL='' CCQUOTA_HUB_URL='' D propose abcdefgh '一处要改的' >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ ! -e "$FLEET_CONF_DIR/global" ] && ok "E no hub here: exit 3, nothing written" \
  || bad "E no hub: rc=$rc"

[ "$fails" = 0 ] && { echo "fleet-debug-desk selftest: all green"; exit 0; }
echo "fleet-debug-desk selftest: $fails failed"; exit 1
