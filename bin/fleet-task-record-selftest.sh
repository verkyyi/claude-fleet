#!/bin/bash
# fleet-task-record-selftest.sh — bin/fleet-task-record.sh, the hub's task record
# from a machine (issue #3330, EPIC #3178 ⑦). No network, no tmux server: curl is
# FLEET_HUB_CURL (a stub that logs its argv, its -K stdin and its body, and answers
# what the test says), the filer and the spawner are stubs in a sandbox bin/.
#
#   A  no hub (no node token): every write exits 3, prints nothing, sends nothing —
#      callers stay byte for byte what they were.
#   B  new: POST /v1/node/tasks, the token in the -K header on stdin (never argv),
#      the JSON body (rule → the issue marker's `n=N v=…` words); `T<n>` on stdout;
#      a hub refusal → exit 1, said on stderr.
#   C  set / get: POST /v1/node/tasks/T<n> with asked / parked / clear; GET the record.
#   D  dispatch: the record first, then a repo task through fleet-issue-file.sh
#      --task T<n> (+ --spawn); a no-repo task opens a no-repo session with --task;
#      no hub ⇒ a repo task files exactly as before (no --task), a no-repo one exits 3.
#   E  epic-member: one record per member (token epic:<repo>#<N>, its issue on it).
#   F  fleet-issue-file.sh --task: the body says 「hub 任务 T<n>」, the issue is hung
#      on the record, the spawn carries --task; a bad --task is refused (exit 2).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
FAILS=0 CHECKS=0
ok()  { CHECKS=$((CHECKS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ftr.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
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
printf '%s\n%s' "$(cat "$ANS" 2>/dev/null || echo '{"id":"T5"}')" "$(cat "$CODE" 2>/dev/null || echo 200)"
EOF
chmod +x "$WORK/curl"
export FLEET_HUB_CURL="$WORK/curl" CURL_LOG="$WORK/curl.log" ANS="$WORK/ans" CODE="$WORK/code"
: > "$CURL_LOG"

# Stubs: the filer and the no-repo spawner log their argv (and the prompt file).
for s in fleet-issue-file.sh dash-raw-session.sh; do
  rm -f "$SB/$s"
  cat > "$SB/$s" <<EOF
#!/bin/bash
printf '%s %s\n' "$s" "\$*" >> "$WORK/calls"
for a in "\$@"; do case "\$a" in --prompt-file=*) cat "\${a#--prompt-file=}" >> "$WORK/calls" ;; esac; done
[ "$s" = fleet-issue-file.sh ] && echo https://github.com/o/r/issues/77
exit 0
EOF
  chmod +x "$SB/$s"
done

# --- A: no hub ---------------------------------------------------------------------
out=$(bash "$R" new --title t --token k 2>&1); rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && [ ! -s "$CURL_LOG" ] && ok "A no node token: new exits 3, silent, nothing sent" \
  || bad "A no hub: rc=$rc out=[$out] $(cat "$CURL_LOG")"
bash "$R" set T5 --asked q >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ ! -s "$CURL_LOG" ] && ok "A …set too" || bad "A set rc=$rc"
printf 'body\n' | bash "$R" dispatch --title '看看风扇' --body-file - >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" = 3 ] && grep -q 'no hub here' "$WORK/err" && [ ! -f "$WORK/calls" ] \
  && ok "A a no-repo dispatch with no hub exits 3, nothing opened" || bad "A no-repo dispatch rc=$rc $(cat "$WORK/err")"
printf 'body\n' | bash "$R" dispatch --title 'fix it' --body-file - --repo o/r --spawn >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$WORK/calls")" = "fleet-issue-file.sh --title fix it --body body --repo o/r --spawn" ] \
  && ok "A a repo dispatch with no hub files exactly as before (no --task)" || bad "A repo dispatch: rc=$rc $(cat "$WORK/calls")"
rm -f "$WORK/calls"

# --- B: new ------------------------------------------------------------------------
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=tok-SECRET\n' > "$FLEET_CONF_DIR/node.env"
t=$(bash "$R" new --title '看看风扇' --token orch:k1 --via 编排 --rule 1 2>"$WORK/err"); rc=$?
[ "$rc" = 0 ] && [ "$t" = T5 ] && ok "B new prints the record's number" || bad "B new: rc=$rc t=[$t] $(cat "$WORK/err")"
grep -q '^argv: .*-X POST .*https://hub.test/v1/node/tasks$' "$CURL_LOG" && ok "B POST /v1/node/tasks at node.env's hub" \
  || bad "B argv: $(cat "$CURL_LOG")"
grep -q '^stdin: header = "Authorization: Bearer tok-SECRET"' "$CURL_LOG" && ! grep '^argv:' "$CURL_LOG" | grep -q SECRET \
  && ok "B the token rides the -K stdin, never an argv" || bad "B token: $(cat "$CURL_LOG")"
python3 - "$CURL_LOG" <<'PY' && ok "B the body: token, title, via, the rule's marker words" || bad "B body: $(grep body: "$CURL_LOG")"
import json, re, sys
b = json.loads([l for l in open(sys.argv[1]) if l.startswith("body: ")][0][6:])
assert b["token"] == "orch:k1" and b["title"] == "看看风扇" and b["via"] == "编排", b
assert re.match(r"^n=1 v=[0-9a-f]+$", b["rule"]), b
assert "repo" not in b and "issue" not in b, b
PY
echo 409 > "$CODE"; : > "$CURL_LOG"
bash "$R" new --title t --token k >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" = 1 ] && grep -q 'refused (HTTP 409)' "$WORK/err" && ok "B a refusal exits 1 and says so" || bad "B refusal rc=$rc $(cat "$WORK/err")"
rm -f "$CODE"
bash "$R" new --title t >/dev/null 2>&1; [ "$?" = 2 ] && ok "B no token: usage (2)" || bad "B no --token accepted"
bash "$R" new --title t --token k --rule 9999 >/dev/null 2>&1; [ "$?" = 2 ] && ok "B an unknown rule: 2" || bad "B unknown rule accepted"

# --- C: set / get ------------------------------------------------------------------
: > "$CURL_LOG"
bash "$R" set T5 --asked '要合吗？' --parked '停放：等 #3' --clear note >/dev/null 2>&1 && \
python3 - "$CURL_LOG" <<'PY' && ok "C set: asked, parked, clear on /v1/node/tasks/T5" || bad "C set: $(cat "$CURL_LOG")"
import json, sys
L = open(sys.argv[1]).read().splitlines()
assert L[0].endswith("https://hub.test/v1/node/tasks/T5"), L[0]
b = json.loads([l for l in L if l.startswith("body: ")][0][6:])
assert b == {"asked": "要合吗？", "parked": "停放：等 #3", "clear": ["note"]}, b
PY
bash "$R" set T5 --clear title >/dev/null 2>&1; [ "$?" = 2 ] && ok "C clearing a title is usage" || bad "C --clear title accepted"
bash "$R" set 5 --asked q >/dev/null 2>&1; [ "$?" = 2 ] && ok "C a bare number is not a record" || bad "C bare 5 accepted"
: > "$CURL_LOG"; echo '{"task":{"id":"T5","issue":"o/r#77"}}' > "$ANS"
g=$(bash "$R" get T5); grep -q '^argv: .*-X GET .*/v1/node/tasks/T5$' "$CURL_LOG" && [ "$g" = '{"task":{"id":"T5","issue":"o/r#77"}}' ] \
  && ok "C get: GET the record, its JSON on stdout" || bad "C get: [$g] $(cat "$CURL_LOG")"
rm -f "$ANS"

# --- D: dispatch -------------------------------------------------------------------
: > "$CURL_LOG"; rm -f "$WORK/calls"
out=$(printf '为什么一直转\n' | bash "$R" dispatch --title '修风扇' --body-file - --repo o/r --rule 1 --spawn 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | head -1)" = T5 ] && printf '%s\n' "$out" | grep -q 'issues/77' \
  && ok "D a repo task: T<n> first, then the issue's URL" || bad "D repo: rc=$rc [$out]"
[ "$(head -1 "$WORK/calls")" = "fleet-issue-file.sh --title 修风扇 --body 为什么一直转 --repo o/r --rule 1 --task T5 --spawn" ] \
  && ok "D …filed through fleet-issue-file.sh --task T5 --spawn" || bad "D filer argv: $(cat "$WORK/calls")"
grep -q '"repo": "o/r"' "$CURL_LOG" && grep -q '"token": "orch:hub:' "$CURL_LOG" \
  && ok "D the record names the repo; the token is the caller's + the words'" || bad "D record body: $(grep body: "$CURL_LOG")"
rm -f "$WORK/calls"
out=$(printf '风扇为什么一直转\n' | bash "$R" dispatch --title '看看风扇' --body-file - --spawn --reap done:2h 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = T5 ] && grep -q '^dash-raw-session.sh --no-repo --task T5 --name 看看风扇 --reap done:2h --prompt-file=' "$WORK/calls" \
  && grep -qx '风扇为什么一直转' "$WORK/calls" && ok "D a no-repo task opens a no-repo session with --task, the words its first turn" \
  || bad "D no-repo: rc=$rc [$out] $(cat "$WORK/calls" 2>&1)"
rm -f "$WORK/calls"
printf 'x\n' | bash "$R" dispatch --title r --body-file - >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -f "$WORK/calls" ] && ok "D no spawn, no repo: the record alone" || bad "D record-only rc=$rc"

# --- E: epic-member ----------------------------------------------------------------
: > "$CURL_LOG"
t=$(bash "$R" epic-member 3178 o/r 3330 '编排改用记录' 2>/dev/null)
[ "$t" = T5 ] && python3 - "$CURL_LOG" <<'PY' && ok "E one read-only record per member: its issue, EPIC #N, open" || bad "E: [$t] $(cat "$CURL_LOG")"
import json, sys
b = json.loads([l for l in open(sys.argv[1]) if l.startswith("body: ")][0][6:])
assert b == {"token": "epic:o/r#3330", "title": "编排改用记录", "via": "EPIC #3178", "repo": "o/r",
             "issue": "o/r#3330", "state": "open"}, b
PY
bash "$R" epic-member 3178 nope 1 >/dev/null 2>&1; [ "$?" = 2 ] && ok "E a bad repo is usage" || bad "E bad repo accepted"

# --- F: fleet-issue-file.sh --task -------------------------------------------------
rm -f "$SB/fleet-issue-file.sh"; ln -s "$BIN/fleet-issue-file.sh" "$SB/fleet-issue-file.sh"
mkdir -p "$WORK/fake"
cat > "$WORK/fake/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/gh.log"
case "\$1 \$2" in "issue create") echo https://github.com/o/r/issues/88 ;; esac
exit 0
EOF
cat > "$WORK/fake/tmux" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$WORK/fake/gh" "$WORK/fake/tmux"
rm -f "$SB/dash-issue-session.sh"
printf '#!/bin/bash\nprintf "spawn %%s\\n" "$*" >> "%s/calls"\n' "$WORK" > "$SB/dash-issue-session.sh"; chmod +x "$SB/dash-issue-session.sh"
: > "$CURL_LOG"; rm -f "$WORK/calls"
PATH="$WORK/fake:$PATH" FLEET_GH_WRITE_DIRECT=1 bash "$SB/fleet-issue-file.sh" --title '修风扇' --body 'b' --repo o/r --task T5 --spawn \
  > "$WORK/out" 2> "$WORK/err"; rc=$?
[ "$rc" = 0 ] && grep -q 'hub 任务 T5' "$WORK/gh.log" && ok "F the body says 「hub 任务 T5」" || bad "F body: rc=$rc $(cat "$WORK/gh.log" "$WORK/err")"
grep -q '"issue": "o/r#88"' "$CURL_LOG" && grep -q '/v1/node/tasks/T5$' "$CURL_LOG" \
  && ok "F the issue is hung on the record" || bad "F record: $(cat "$CURL_LOG")"
grep -q '^spawn 88 --title 修风扇 --repo o/r --task T5' "$WORK/calls" && ok "F the spawn carries --task" || bad "F spawn: $(cat "$WORK/calls" 2>&1)"
PATH="$WORK/fake:$PATH" bash "$SB/fleet-issue-file.sh" --title t --task 5 >/dev/null 2>&1; [ "$?" = 2 ] \
  && ok "F a bad --task is refused (2)" || bad "F --task 5 accepted"

printf '%d checks, %d failed\n' "$CHECKS" "$FAILS"
[ "$FAILS" = 0 ]
