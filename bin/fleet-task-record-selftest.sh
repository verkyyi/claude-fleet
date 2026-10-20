#!/bin/bash
# fleet-task-record-selftest.sh — bin/fleet-task-record.sh, the hub's task record
# from a machine (issue #3330, EPIC #3178 ⑦). No network, no tmux server: curl is
# FLEET_HUB_CURL (a stub that logs its argv, its -K stdin and its body, and answers
# what the test says), the filer and the spawner are stubs in a sandbox bin/.
#
#   A  no hub (no node token): every write exits 3, prints nothing, sends nothing —
#      callers stay byte for byte what they were.
#   B  new: POST /v1/node/tasks, the token in the -K header on stdin (never argv),
#      the JSON body (no `rule` key since the rule table left, issue #4340);
#      `T<n>` on stdout; --rule is an unknown option (usage, 2);
#      a hub refusal → exit 1, said on stderr.
#   C  set / get: POST /v1/node/tasks/T<n> with asked / parked / clear; GET the record.
#   D  dispatch: the record first; a repo task is the record alone (issue #4897):
#      + --spawn, dash-raw-session.sh --repo --task T<n> --reap merged, no issue;
#      a no-repo task opens a no-repo session with --task; no hub ⇒ exit 3, nothing
#      opened, repo or not (issue #4898); --draft is an unknown option.
#   E  epic-member is gone (issue #4957): an EPIC member is a child task, dispatched.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
FAIL=0 CHECKS=0
ok()  { CHECKS=$((CHECKS + 1)); printf 'PASS  %s\n' "$1"; }

st_sandbox "${TMPDIR:-/tmp}/ftr.XXXXXX"
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1; mkdir -p "$FLEET_CONF_DIR"
unset TMUX TMUX_PANE CCQUOTA_TOKEN CCQUOTA_HUB_URL
SB="$WORK/bin"; mkdir -p "$SB"
for f in "$BIN"/*; do ln -s "$f" "$SB/${f##*/}"; done
R="$SB/fleet-task-record.sh"

# The hub: logs `argv`, then `stdin:` (the -K config) and `body:`; answers $ANS / $CODE.
cat > "$WORK/curl" <<'EOF'
#!/bin/bash
cfg=$(cat); body=''
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  [ "${args[$i]}" = --data-binary ] && body=${args[$((i + 1))]}
  i=$((i + 1))
done
{ printf 'argv: %s\n' "$*"; printf 'stdin: %s\n' "$cfg"; printf 'body: %s\n' "$body"; } >> "$CURL_LOG"
if [[ "$body" == *'"authority_version": 1'* ]]; then
  python3 - "$body" <<'JSON'
import json,sys
x=json.loads(sys.argv[1]); print(json.dumps(dict(x,id="T5",generation=1,attempt_id="task:T5:g1")))
JSON
  printf '200'
  exit 0
fi
fallback='{"id":"T5"}'
case " $* " in *' -X GET '*) fallback='{"task":{"id":"T5"}}' ;; esac
printf '%s\n%s' "$(cat "$ANS" 2>/dev/null || echo "$fallback")" "$(cat "$CODE" 2>/dev/null || echo 200)"
EOF
chmod +x "$WORK/curl"
export FLEET_HUB_CURL="$WORK/curl" CURL_LOG="$WORK/curl.log" ANS="$WORK/ans" CODE="$WORK/code"
: > "$CURL_LOG"

# Stub: the spawner logs its argv (and the prompt file).
s=dash-raw-session.sh
rm -f "$SB/$s"
cat > "$SB/$s" <<EOF
#!/bin/bash
printf '%s %s\n' "$s" "\$*" >> "$WORK/calls"
for a in "\$@"; do case "\$a" in --prompt-file=*) cat "\${a#--prompt-file=}" >> "$WORK/calls" ;; esac; done
exit 0
EOF
chmod +x "$SB/$s"

# --- A: no hub ---------------------------------------------------------------------
out=$(bash "$R" new --title t --token k 2>&1); rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && [ ! -s "$CURL_LOG" ] && ok "A no node token: new exits 3, silent, nothing sent" \
  || st_miss "A no hub: rc=$rc out=[$out] $(cat "$CURL_LOG")"
bash "$R" set T5 --asked q >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ ! -s "$CURL_LOG" ] && ok "A …set too" || st_miss "A set rc=$rc"
printf 'body\n' | bash "$R" dispatch --title '看看风扇' --body-file - >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" = 3 ] && grep -q 'no hub here' "$WORK/err" && [ ! -f "$WORK/calls" ] \
  && ok "A a no-repo dispatch with no hub exits 3, nothing opened" || st_miss "A no-repo dispatch rc=$rc $(cat "$WORK/err")"
printf 'body\n' | bash "$R" dispatch --title 'fix it' --body-file - --repo o/r --spawn >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ ! -f "$WORK/calls" ] \
  && ok "A a repo dispatch with no hub exits 3 too: no issue filed (issue #4898)" || st_miss "A repo dispatch: rc=$rc $(cat "$WORK/calls" 2>&1)"
rm -f "$WORK/calls"

# --- B: new ------------------------------------------------------------------------
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=tok-SECRET\n' > "$FLEET_CONF_DIR/node.env"
t=$(bash "$R" new --title '看看风扇' --token orch:k1 --via 编排 2>"$WORK/err"); rc=$?
[ "$rc" = 0 ] && [ "$t" = T5 ] && ok "B new prints the record's number" || st_miss "B new: rc=$rc t=[$t] $(cat "$WORK/err")"
grep -q '^argv: .*-X POST .*https://hub.test/v1/node/tasks$' "$CURL_LOG" && ok "B POST /v1/node/tasks at node.env's hub" \
  || st_miss "B argv: $(cat "$CURL_LOG")"
grep -q '^stdin: header = "Authorization: Bearer tok-SECRET"' "$CURL_LOG" && ! grep '^argv:' "$CURL_LOG" | grep -q SECRET \
  && ok "B the token rides the -K stdin, never an argv" || st_miss "B token: $(cat "$CURL_LOG")"
python3 - "$CURL_LOG" <<'PY' && ok "B the body: token, title, via — no rule" || st_miss "B body: $(grep body: "$CURL_LOG")"
import json, re, sys
b = json.loads([l for l in open(sys.argv[1]) if l.startswith("body: ")][0][6:])
assert b["token"] == "orch:k1" and b["title"] == "看看风扇" and b["via"] == "编排", b
assert "rule" not in b, b
assert "repo" not in b and "issue" not in b, b
PY
# a hub with task_ids (EPIC T644 C1): the task's code first, T<n> after it
printf '{"id":"T5","task":"T5","fid":"3fa85f64-5717-4562-b3fc-2c963f66afa6","short":"FF1W"}' > "$ANS"
out=$(bash "$R" new --title t --token k 2>"$WORK/err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(printf 'FF1W\nT5')" ] && ok "B a task_ids hub: the code on the first line, then T<n>" \
  || st_miss "B code first: rc=$rc out=[$out] $(cat "$WORK/err")"
rm -f "$ANS"
echo 409 > "$CODE"; : > "$CURL_LOG"
bash "$R" new --title t --token k >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" = 1 ] && grep -q 'refused (HTTP 409)' "$WORK/err" && ok "B a refusal exits 1 and says so" || st_miss "B refusal rc=$rc $(cat "$WORK/err")"
printf '{"error":"task owner or generation does not match"}' > "$ANS"
bash "$R" new --title t --token k >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" = 1 ] && grep -q 'refused (HTTP 409): task owner or generation does not match' "$WORK/err" \
  && ok "B a refusal carries the hub's reason word for word (EPIC T497 C16)" || st_miss "B reason: rc=$rc $(cat "$WORK/err")"
rm -f "$CODE" "$ANS"
bash "$R" new --title t >/dev/null 2>&1; [ "$?" = 2 ] && ok "B no token: usage (2)" || st_miss "B no --token accepted"
bash "$R" new --title t --token k --rule 9999 >/dev/null 2>&1; [ "$?" = 2 ] && ok "B --rule is gone: usage (issue #4790)" || st_miss "B --rule 9999 accepted"

# --- S: settle (issue #4867) -----------------------------------------------------------
: > "$CURL_LOG"
bash "$R" settle --repo o/r >/dev/null 2>&1 && \
python3 - "$CURL_LOG" <<'PY' && ok "S settle: POST /v1/node/tasks/settle, dry unless --apply" || st_miss "S settle: $(cat "$CURL_LOG")"
import json, sys
L = open(sys.argv[1]).read().splitlines()
assert L[0].endswith("https://hub.test/v1/node/tasks/settle"), L[0]
b = json.loads([l for l in L if l.startswith("body: ")][0][6:])
assert b == {"repo": "o/r", "apply": False}, b
assert "--max-time 90" in L[0], L[0]   # issue #4881: outlasts the hub's 60 s GitHub budget
PY
: > "$CURL_LOG"
bash "$R" settle --repo o/r --apply >/dev/null 2>&1 && grep -q '^body: {"repo": "o/r", "apply": true}' "$CURL_LOG" \
  && ok "S settle --apply sends apply" || st_miss "S --apply: $(cat "$CURL_LOG")"
bash "$R" settle --repo o/r --drained --apply >/dev/null 2>&1 && grep -q '^body: {"repo": "o/r", "apply": true, "drained": true}' "$CURL_LOG" \
  && ok "S settle --drained sends drained (T479)" || st_miss "S --drained: $(cat "$CURL_LOG")"
bash "$R" settle >/dev/null 2>&1; [ "$?" = 2 ] && ok "S settle without --repo is usage" || st_miss "S no --repo accepted"
: > "$CURL_LOG"
bash "$R" settle --no-repo --apply >/dev/null 2>&1 && grep -q '^body: {"repo": "", "apply": true, "no_repo": true}' "$CURL_LOG" \
  && ok "S settle --no-repo sends no_repo (#4963)" || st_miss "S --no-repo: $(cat "$CURL_LOG")"
bash "$R" settle --no-repo --repo o/r >/dev/null 2>&1; [ "$?" = 2 ] && ok "S settle --no-repo with --repo is usage" || st_miss "S --no-repo + --repo accepted"

# --- C: set / get ------------------------------------------------------------------
: > "$CURL_LOG"
bash "$R" set T5 --asked '要合吗？' --parked '停放：等 #3' --clear note >/dev/null 2>&1 && \
python3 - "$CURL_LOG" <<'PY' && ok "C set: asked, parked, clear on /v1/node/tasks/T5" || st_miss "C set: $(cat "$CURL_LOG")"
import json, sys
L = open(sys.argv[1]).read().splitlines()
assert L[0].endswith("https://hub.test/v1/node/tasks/T5"), L[0]
b = json.loads([l for l in L if l.startswith("body: ")][0][6:])
assert b == {"asked": "要合吗？", "parked": "停放：等 #3", "clear": ["note"]}, b
PY
bash "$R" set T5 --clear title >/dev/null 2>&1; [ "$?" = 2 ] && ok "C clearing a title is usage" || st_miss "C --clear title accepted"
bash "$R" set 5 --asked q >/dev/null 2>&1; [ "$?" = 2 ] && ok "C a bare number is not a record" || st_miss "C bare 5 accepted"
: > "$CURL_LOG"; echo '{"task":{"id":"T5","issue":"o/r#77"}}' > "$ANS"
g=$(bash "$R" get T5); grep -q '^argv: .*-X GET .*/v1/node/tasks/T5$' "$CURL_LOG" && [ "$g" = '{"task":{"id":"T5","issue":"o/r#77"}}' ] \
  && ok "C get: GET the record, its JSON on stdout" || st_miss "C get: [$g] $(cat "$CURL_LOG")"
rm -f "$ANS"
: > "$CURL_LOG"
for ref in FF1W '#ff1w' 3fa85f64-5717-4562-b3fc-2c963f66afa6; do
  bash "$R" get "$ref" >/dev/null 2>&1 || st_miss "C get $ref refused"
done
[ "$(grep -c -- '-X GET ' "$CURL_LOG")" = 3 ] && grep -q '/v1/node/tasks/ff1w$' "$CURL_LOG" \
  && grep -q '/v1/node/tasks/3fa85f64-5717-4562-b3fc-2c963f66afa6$' "$CURL_LOG" \
  && ok "C get by the task's code or ID too (EPIC T644 C1: the hub resolves it)" || st_miss "C get by code: $(cat "$CURL_LOG")"
bash "$R" get 'K5;x' >/dev/null 2>&1; [ "$?" = 2 ] && ok "C get: not a reference is usage" || st_miss "C get K5;x accepted"

# --- D: dispatch -------------------------------------------------------------------
: > "$CURL_LOG"; rm -f "$WORK/calls"
out=$(printf '为什么一直转\n' | bash "$R" dispatch --title '修风扇' --body-file - --repo o/r --spawn 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = T5 ] \
  && ok "D a repo task: T<n> only — no issue filed, no URL (issue #4897)" || st_miss "D repo: rc=$rc [$out]"
grep -Eq '^dash-raw-session\.sh --repo o/r --task T5 --name 修风扇 --reap merged (--as fleet-worker )?--prompt-file=' "$WORK/calls" \
  && grep -qx '修风扇' "$WORK/calls" && grep -qx '为什么一直转' "$WORK/calls" \
  && ok "D …its session opens in a repo worktree bound to T5 (reap merged), title + words its first turn" \
  || st_miss "D repo spawner argv: $(cat "$WORK/calls")"
grep -q '"repo": "o/r"' "$CURL_LOG" && grep -q '"token": "orch:hub:' "$CURL_LOG" \
  && ok "D the record names the repo; the token is the caller's + the words'" || st_miss "D record body: $(grep body: "$CURL_LOG")"
rm -f "$WORK/calls"
out=$(printf 'x\n' | bash "$R" dispatch --title '修风扇' --body-file - --repo o/r 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = T5 ] && [ ! -f "$WORK/calls" ] \
  && ok "D a repo task with no --spawn: the record alone (await names it)" || st_miss "D repo record-only: rc=$rc [$out] $(cat "$WORK/calls" 2>&1)"
rm -f "$WORK/calls"
out=$(printf 'x\n' | bash "$R" dispatch --title '修风扇' --body-file - --repo o/r --spawn --draft 2>&1); rc=$?
[ "$rc" = 2 ] && [ ! -f "$WORK/calls" ] \
  && ok "D --draft is gone (issue #4898): usage, nothing opened" || st_miss "D draft: rc=$rc $(cat "$WORK/calls" 2>&1)"
rm -f "$WORK/calls"
out=$(printf '风扇为什么一直转\n' | bash "$R" dispatch --title '看看风扇' --body-file - --spawn --reap done:2h 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = T5 ] && grep -q '^dash-raw-session.sh --no-repo --task T5 --name 看看风扇 --reap done:2h --prompt-file=' "$WORK/calls" \
  && grep -qx '风扇为什么一直转' "$WORK/calls" && ok "D a no-repo task opens a no-repo session with --task, the words its first turn" \
  || st_miss "D no-repo: rc=$rc [$out] $(cat "$WORK/calls" 2>&1)"
rm -f "$WORK/calls"
printf 'x\n' | bash "$R" dispatch --title r --body-file - >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -f "$WORK/calls" ] && ok "D no spawn, no repo: the record alone" || st_miss "D record-only rc=$rc"

# --- E: epic-member is gone (issue #4957): an EPIC's members are child tasks ------
bash "$R" epic-member 3178 o/r 3330 x >/dev/null 2>&1; [ "$?" = 2 ] && ok "E epic-member is usage now" || st_miss "E epic-member still answers"

printf '%d checks, %d failed\n' "$CHECKS" "$FAIL"
st_done
