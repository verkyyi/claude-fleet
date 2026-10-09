#!/bin/bash
# fleet-steward-selftest.sh — the steward (issue #2670, EPIC #2668 C2):
# bin/fleet-steward.sh (the window), bin/fleet-steward-tick.sh → bin/fleet_steward.py
# (the beat with no model), bin/fleet-steward-stats.sh (the count), and the
# decide count's road to the client (fleet-control-read.sh `orchdec=` →
# fleet_hub_common.inventory_row → fleet-hub-sessions.sh `decide=N` →
# fleet-sidebar.py orch_decide).
#
# GitHub is a directory of comment files (fleet_decision.py's seams), the fleet's
# windows / ledgers / peer channel are seams too; the window legs run an isolated
# tmux server with a fake agent.
#
#   A  a calm beat: delta empty, exit 1, NO turn sent to the model (0 calls)
#   B  three questions, one the charter answers: the beat wakes the model once;
#      `answer --by steward` closes one; `sheet` hands the orchestrator ONE
#      [decision] of 2 rows; the decide count stamped is 2; a second `sheet` with
#      the same rows sends nothing
#   C  a never:* row: `answer --by steward` refuses it
#   D  a due row is answered by its default at the beat (C1's apply_due) once
#   E  a write storm: past FLEET_STEWARD_WRITES the answers wait a beat — the card
#      says 延后 N, the next beat posts them, never more than the budget a beat
#   F  not due: the every-minute caller returns 4 with no lock and no read
#   G  the switch: FLEET_STEWARD=0 ⇒ ensure rc 3, no window, no @attention_log,
#      the beat rc 3 and no state file; unset + FLEET_HOST=1 ⇒ `count`: the
#      attention flag on, no window
#   H  the window: opens (@fleet_role steward, @norepo 1, on /fleet-steward with
#      the role file); killed ⇒ the next ensure opens it on the SAME conversation
#      with the resume seed; `fleet_win_for_key steward` answers it
#   I  the attention count: `note` logs a client's move once, `attention` counts
#      a worker window once a day
#   J  the decide count travels: orchdec=2 → orch_decide 2 → `decide=2` → red;
#      the park count beside it (issue #2671): @orch_park → orchpark= (the last
#      tag) → orch_park → `park=N`
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/steward-st.XXXXXX")
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
REAL_TMUX=''
for t in $(type -ap tmux); do case "$t" in */tmux-shim/*) ;; *) REAL_TMUX=$t; break ;; esac; done
cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -S "$WORK/t.sock" kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

export FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh FLEET_DECISION_TZ=UTC FLEET_SKIP_GLOBAL_CONF=1
mkdir -p "$FLEET_CONF_DIR/fleets/st/repos" "$WORK/gh" "$WORK/bin"
printf 'FLEET_REPO="o/r"\n' > "$FLEET_CONF_DIR/fleets/st/repos/o-r.conf"

# --- the fake GitHub: one JSON file of comments per issue ---------------------
cat > "$WORK/bin/gh-comments" <<'EOF'
#!/bin/sh
f="$ST_GH/$(printf '%s' "$1" | tr / -)-$2.json"
[ -f "$f" ] && cat "$f" || printf '{"comments":[]}\n'
EOF
cat > "$WORK/bin/gh-post" <<'EOF'
#!/usr/bin/env python3
import json, os, sys, time
repo, n, mode = sys.argv[1:4]
body = sys.stdin.read()
f = os.path.join(os.environ["ST_GH"], "%s-%s.json" % (repo.replace("/", "-"), n))
d = json.load(open(f)) if os.path.exists(f) else {"comments": []}
k = len(d["comments"]) + 1
d["comments"].append({"body": body, "url": "https://github.com/%s/issues/%s#issuecomment-%d" % (repo, n, 900 + k),
                      "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
json.dump(d, open(f, "w"))
open(os.path.join(os.environ["ST_GH"], "posts.log"), "a").write("%s#%s %s\n" % (repo, n, mode))
print("https://github.com/%s/issues/%s#issuecomment-%d" % (repo, n, 900 + k))
EOF
printf '#!/bin/sh\nprintf "o/r#100\\n"\n' > "$WORK/bin/gh-parent"
printf '#!/bin/sh\ncat "$ST_WINS" 2>/dev/null\n' > "$WORK/bin/wins"
printf '#!/bin/sh\nprintf "{\\"seq\\": 0, \\"children\\": []}\\n"\n' > "$WORK/bin/children"
cat > "$WORK/bin/send" <<'EOF'
#!/bin/sh
{ printf '>>> %s\n' "$1"; cat; printf '\n'; } >> "$ST_GH/sends.log"
EOF
printf '#!/bin/sh\nprintf "%%s\\n" "$1" > "$ST_GH/decide"\n' > "$WORK/bin/stamp"
chmod +x "$WORK/bin/"*
export ST_GH="$WORK/gh" ST_WINS="$WORK/wins.txt" \
  FLEET_DECISION_COMMENTS_CMD="$WORK/bin/gh-comments" FLEET_DECISION_POST_CMD="$WORK/bin/gh-post" \
  FLEET_DECISION_PARENT_CMD="$WORK/bin/gh-parent" FLEET_STEWARD_WINDOWS_CMD="$WORK/bin/wins" \
  FLEET_STEWARD_CHILDREN_CMD="$WORK/bin/children" FLEET_STEWARD_SEND_CMD="$WORK/bin/send" \
  FLEET_STEWARD_STAMP_CMD="$WORK/bin/stamp" FLEET_STEWARD=1
: > "$ST_WINS"
TICK() { python3 "$BIN/fleet_steward.py" "$@" --session st; }
STATE="$FLEET_CONF_DIR/global/steward.state.json"
sends() { grep -c '^>>> ' "$ST_GH/sends.log" 2>/dev/null || echo 0; }
posts() { grep -c . "$ST_GH/posts.log" 2>/dev/null || echo 0; }
# ask <N> <question> [fleet_decision ask-body args…] — a worker's ⛔ ask on o/r#N
ask() {
  local n=$1; shift
  python3 "$BIN/fleet_decision.py" ask-body --question "$@" | "$WORK/bin/gh-post" o/r "$n" ask >/dev/null
}
needs() { printf '@%s\tworker\tneeds\t%s\to/r\t\t\n' "$1" "$1" >> "$ST_WINS"; }
rowid() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([k for k,r in d["rows"].items() if r["item"].startswith(sys.argv[2])][0])' "$STATE" "$1"; }
calls() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("model_calls", 0))' "$STATE"; }

# A — calm
TICK beat --force >/dev/null; rc=$?
TICK beat --force >"$WORK/out" 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(sends)" = 0 ] && [ "$(calls)" = 0 ] && grep -q '平静' "$WORK/out" \
  && ok "A: a calm beat — exit 1, card 平静, no turn sent (0 model calls)" \
  || bad "A: calm beat rc=$rc sends=$(sends) calls=$(calls): $(cat "$WORK/out")"

# B — three questions, one the charter answers
ask 11 '先发 20 家还是 50 家？' --suggest '20 家' --due 4h
ask 12 '要不要拆成两个 PR？' --suggest '拆' --due 4h
ask 13 '用哪个颜色？' --suggest '蓝' --due 4h
needs 11; needs 12; needs 13
TICK beat --force >"$WORK/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(sends)" = 1 ] && grep -q '>>> steward' "$ST_GH/sends.log" && grep -q '新问题 3' "$ST_GH/sends.log" \
  && ok "B: three new questions wake the model once ([steward] · 新问题 3)" \
  || bad "B: beat rc=$rc sends=$(sends): $(cat "$WORK/out") / $(cat "$ST_GH/sends.log" 2>/dev/null)"
r11=$(rowid 先发)
TICK answer --row "$r11" --text '20 家（共同约定 2：先小后大）' --source 'https://github.com/o/r/issues/100' >/dev/null
grep -q "fleet:answer row=$r11 by=steward" "$ST_GH/o-r-11.json" && grep -q 'o/r#11 to-worker' "$ST_GH/posts.log" \
  && ok "B: answer --by steward goes to the worker (--to-worker) with its answer marker" \
  || bad "B: the self-answer was not posted as expected: $(cat "$ST_GH/posts.log")"
TICK sheet >"$WORK/out" 2>&1
n=$(grep -c '^>>> orchestrator' "$ST_GH/sends.log")
rows=$(awk '/^>>> orchestrator/{f=1;next} /^>>> /{f=0} f' "$ST_GH/sends.log" | grep -c '^| [0-9]')
[ "$n" = 1 ] && [ "$rows" = 2 ] && [ "$(cat "$ST_GH/decide")" = 2 ] && grep -q '\[decision\]' "$ST_GH/sends.log" \
  && ok "B: sheet → ONE [decision] of 2 rows to the orchestrator, decide=2 stamped" \
  || bad "B: sheet sends=$n rows=$rows decide=$(cat "$ST_GH/decide" 2>/dev/null): $(cat "$WORK/out")"
ls "$FLEET_CONF_DIR/fleets/st/steward/"decision-*.md >/dev/null 2>&1 && ok "B: the sheet is kept as decision-<date>.md" \
  || bad "B: no decision-<date>.md"
TICK sheet >/dev/null 2>&1
[ "$(grep -c '^>>> orchestrator' "$ST_GH/sends.log")" = 1 ] && ok "B: the same rows again — not sent twice" \
  || bad "B: an unchanged sheet was sent again"
TICK beat --force >/dev/null 2>&1
[ "$(cat "$ST_GH/decide")" = 2 ] && [ "$(grep -c '^>>> steward' "$ST_GH/sends.log")" = 1 ] \
  && ok "B: the next beat keeps decide=2 and wakes no one (nothing new)" \
  || bad "B: next beat decide=$(cat "$ST_GH/decide") steward sends=$(grep -c '^>>> steward' "$ST_GH/sends.log")"
r12=$(rowid 要不要)
TICK answer --row "$r12" --text '拆' --by person >/dev/null
[ "$(cat "$ST_GH/decide")" = 1 ] && grep -q "fleet:answer row=$r12 by=person" "$ST_GH/o-r-12.json" \
  && ok "B: the person's answer written back — decide drops to 1" || bad "B: person answer: decide=$(cat "$ST_GH/decide")"

# C — never-default rows are not the steward's
ask 14 '要不要开一台云机器？' --suggest '不开' --due 4h
needs 14
TICK beat --force >/dev/null 2>&1
r14=$(rowid 要不要开)
TICK answer --row "$r14" --text '不开' >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" = 1 ] && grep -q never "$WORK/err" && ! grep -q "row=$r14" "$ST_GH/o-r-14.json" \
  && ok "C: a never:money row — answer --by steward refuses it" || bad "C: rc=$rc $(cat "$WORK/err")"

# D — a due row is answered by its default, once
ask 15 '日志留几天？' --suggest '7 天' --due 2000-01-01T00:00:00Z
needs 15
TICK beat --force >/dev/null 2>&1
TICK beat --force >/dev/null 2>&1
nd=$(grep -c 'by=default' "$ST_GH/o-r-15.json")
[ "$nd" = 1 ] && grep -q 'fleet:default-decided' "$ST_GH/o-r-100.json" \
  && ok "D: a due row answered by its default once + 默认拍板 on the parent" || bad "D: defaults posted $nd times"

# E — a write storm: budget 3, five answers
for i in 21 22 23 24 25; do ask "$i" "问题 ${i}？" --suggest 是 --due 4h; needs "$i"; done
TICK beat --force >/dev/null 2>&1
before=$(posts)
for i in 21 22 23 24 25; do
  FLEET_STEWARD_WRITES=3 TICK answer --row "$(rowid "问题 ${i}")" --text 是 >/dev/null 2>&1
done
FLEET_STEWARD_WRITES=3 python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["deferred"]))' "$STATE" > "$WORK/def"
mid=$(( $(posts) - before ))
# the beat that wrote these spent nothing yet: the five land 3 now, 2 deferred
[ "$mid" = 3 ] && [ "$(cat "$WORK/def")" = 2 ] && ok "E: past the budget (3) the answers wait — 3 posted, 2 deferred" \
  || bad "E: posted $mid, deferred $(cat "$WORK/def")"
FLEET_STEWARD_WRITES=3 TICK beat --force >"$WORK/out" 2>&1
[ $(( $(posts) - before )) = 5 ] && ok "E: the next beat posts the deferred two first" || bad "E: after the beat posted $(( $(posts) - before ))"
FLEET_STEWARD_WRITES=0 TICK answer --row "$r14" --text x --by person >/dev/null 2>&1
FLEET_STEWARD_WRITES=0 TICK beat --force >"$WORK/out" 2>&1
grep -q '延后 1 条' "$WORK/out" && ok "E: the card says 延后 N 条" || bad "E: card: $(cat "$WORK/out")"

# F — not due: returns 4 at once
TICK beat >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && ok "F: not due — the every-minute caller returns 4" || bad "F: rc=$rc"

# G/H/I need a tmux
if [ -z "$REAL_TMUX" ]; then
  echo "SKIP  G/H/I: no tmux"
else
  mkdir -p "$WORK/tbin" "$WORK/home"
  cat > "$WORK/tbin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$WORK/t.sock" "\$@"
EOF
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/args"\nexec sleep 600\n' "$WORK" > "$WORK/agent"
  chmod +x "$WORK/tbin/tmux" "$WORK/agent"
  "$REAL_TMUX" -S "$WORK/t.sock" -f /dev/null new-session -d -s st -n home -x 100 -y 30 'exec sh'
  TT() { "$REAL_TMUX" -S "$WORK/t.sock" "$@"; }
  ens() {
    env -u FLEET_STEWARD PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_AGENT=claude FLEET_STEWARD_MODEL='' \
      FLEET_WRAP_LAUNCH="$WORK/agent" "$@" bash "$BIN/fleet-steward.sh" ensure st 2>/dev/null
    printf 'rc=%s\n' "$?"
  }
  count() { TT list-windows -t st -F '#{@fleet_role}' | grep -cx steward; }
  # G — off and count
  o=$(ens FLEET_STEWARD=0)
  [ "${o##*rc=}" = 3 ] && [ "$(count)" = 0 ] && [ -z "$(TT show-option -gqv @attention_log)" ] \
    && ok "G: FLEET_STEWARD=0 — rc 3, no window, no attention flag" || bad "G: off: $o"
  rm -f "$STATE"
  FLEET_STEWARD=0 TICK beat >/dev/null 2>&1; rc=$?
  [ "$rc" = 3 ] && [ ! -e "$STATE" ] && ok "G: FLEET_STEWARD=0 — the beat is a no-op (rc 3, no state written)" || bad "G: off beat rc=$rc"
  o=$(ens FLEET_HOST=1)
  [ "${o##*rc=}" = 3 ] && [ "$(count)" = 0 ] && [ "$(TT show-option -gqv @attention_log)" = 1 ] \
    && ok "G: unset + 承载 ⇒ count — the attention flag on, no window" || bad "G: count: $o"
  # H — the window, and back on the same conversation
  : > "$WORK/args"
  o=$(ens FLEET_STEWARD=1); w=${o%%$'\n'*}
  i=0; while [ ! -s "$WORK/args" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  sid=$(cat "$FLEET_CONF_DIR/fleets/st/steward.sid" 2>/dev/null)
  [ "$(TT display-message -p -t "$w" '#{@fleet_role}|#{@norepo}')" = 'steward|1' ] \
    && grep -q -- "--session-id $sid" "$WORK/args" && grep -q 'fleet-steward/role.md' "$WORK/args" && grep -q '/fleet-steward' "$WORK/args" \
    && ok "H: the window opens — @fleet_role steward, @norepo 1, its role file, /fleet-steward" \
    || bad "H: open: $o / $(cat "$WORK/args")"
  k=$(PATH="$WORK/tbin:$PATH" bash -c '. "$1/fleet-lib.sh"; fleet_win_for_key steward' _ "$BIN" 2>/dev/null)
  [ "$k" = "$w" ] && ok "H: fleet_win_for_key steward answers it" || bad "H: resolver said '$k' (want $w)"
  proj="$WORK/home/.claude/projects/$(printf '%s' "$WORK/home" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$proj"; : > "$proj/$sid.jsonl"
  TT kill-window -t "$w"
  : > "$WORK/args"
  o=$(ens FLEET_STEWARD=1)
  i=0; while [ ! -s "$WORK/args" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$(count)" = 1 ] && grep -q -- "--resume $sid" "$WORK/args" && grep -q '会话刚被 fleet 接回' "$WORK/args" \
    && ok "H: killed — the next ensure brings it back on the same conversation" || bad "H: back: $o / $(cat "$WORK/args")"
  # I — the attention count
  TT new-window -d -t st -n issue-7 'exec sleep 600'
  TT set-option -wq -t st:issue-7 @issue 7
  TT set-option -wq -t st:issue-7 @repo o/r
  rm -f "$FLEET_CONF_DIR/logs/attention.ndjson" "$FLEET_CONF_DIR/logs/attention.last"
  # a client, as the hooks see one: list-clients' answer is the seam
  mkdir -p "$WORK/cbin"
  cat > "$WORK/cbin/tmux" <<EOF
#!/bin/sh
[ "\$1" = list-clients ] && { cat "$WORK/clients"; exit 0; }
exec "$REAL_TMUX" -S "$WORK/t.sock" "\$@"
EOF
  chmod +x "$WORK/cbin/tmux"
  printf '/dev/ttys9\t0\tst\t@77\t\t7\to/r\tissue-7\n' > "$WORK/clients"
  PATH="$WORK/cbin:$PATH" bash "$BIN/fleet-steward-stats.sh" note
  PATH="$WORK/cbin:$PATH" bash "$BIN/fleet-steward-stats.sh" note
  printf '/dev/ttys9\t0\tst\t@1\thome\t\t\thome\n' > "$WORK/clients"
  PATH="$WORK/cbin:$PATH" bash "$BIN/fleet-steward-stats.sh" note
  printf '/dev/ttys9\t0\tst\t@77\t\t7\to/r\tissue-7\n' > "$WORK/clients"
  PATH="$WORK/cbin:$PATH" bash "$BIN/fleet-steward-stats.sh" note
  nl=$(grep -c . "$FLEET_CONF_DIR/logs/attention.ndjson")
  cnt=$(bash "$BIN/fleet-steward-stats.sh" attention --days 1 | awk -F'\t' 'NR==1 { print $2 }')
  [ "$nl" = 3 ] && [ "$cnt" = 1 ] && ok "I: note logs each move once (3 lines); attention counts the worker window once a day" \
    || bad "I: lines=$nl count=$cnt"
  grep -q 'set-hook -g session-window-changed\[76\].*@attention_log.*fleet-steward-stats.sh note' "$BIN/../conf/tmux-attention.conf" \
    && ok "I: the node conf's [76] hooks run note only under @attention_log" || bad "I: no [76] hook in tmux-attention.conf"
fi

# J — the decide count's road to the client: the node's inventory (a real
# fleet-control-read.sh over an isolated server) → inventory_row → orch_<sess>
if [ -n "$REAL_TMUX" ]; then
  jt="$WORK/jt"; js="stj$$"; mkdir -p "$jt" "$WORK/jconf/fleets/$js"
  printf 'FLEET_REPO=o/r\n' > "$WORK/jconf/fleets/$js/conf"
  jq() { TMUX_TMPDIR="$jt" "$REAL_TMUX" -L "$js" "$@"; }
  jq -f /dev/null new-session -d -s "$js" -n home 'sleep 600'
  jq new-window -d -t "=$js:" -n orchestrator 'sleep 600'
  jq set-option -w -t "=$js:orchestrator" @fleet_role orchestrator
  jq set-option -w -t "=$js:orchestrator" @norepo 1
  jinv() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$jt" TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/jconf" \
             bash "$BIN/fleet-control-read.sh" workers "$js" 2>/dev/null | awk -F'\t' '$10 == "orchestrator"'; }
  plain=$(jinv)
  jq set-option -w -t "=$js:orchestrator" @orch_decide 2
  out=$(jinv)
  jq set-option -w -t "=$js:orchestrator" @orch_park 1
  both=$(jinv)
  jq set-option -w -u -t "=$js:orchestrator" @orch_decide
  parkonly=$(jinv)
  jq kill-server 2>/dev/null
  d=$(printf '%s' "$out" | python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from fleet_hub_common import inventory_row; r = inventory_row(sys.stdin.read().rstrip("\n").split("\t")); print((r[1] if r else {}).get("orch_decide", ""))' "$BIN")
  case "$plain" in *orchdec=*) bad "J: no sheet, yet the inventory carries orchdec: [$plain]" ;; *)
    [ -n "$plain" ] && [ "$out" = "$plain"$'\t'"orchdec=2" ] && [ "$d" = 2 ] \
      && ok "J: @orch_decide 2 → the inventory's orchdec=2 → orch_decide 2; none ⇒ the row byte for byte" \
      || bad "J: inventory [$out] (plain [$plain]) → orch_decide [$d]" ;; esac
  jrow() { printf '%s' "$1" | python3 -c 'import sys, json; sys.path.insert(0, sys.argv[1]); from fleet_hub_common import inventory_row; r = inventory_row(sys.stdin.read().rstrip("\n").split("\t")); r = r[1] if r else {}; print(r.get("orch_decide", "-"), r.get("orch_park", "-"))' "$BIN"; }
  [ "$both" = "$plain"$'\t'"orchdec=2"$'\t'"orchpark=1" ] && [ "$(jrow "$both")" = "2 1" ] \
    && [ "$parkonly" = "$plain"$'\t'"orchpark=1" ] && [ "$(jrow "$parkonly")" = "- 1" ] \
    && ok "J: @orch_park 1 → orchpark=1 (the last tag, alone or after orchdec=) → orch_park 1" \
    || bad "J: park road: both [$both] → $(jrow "$both"); park only [$parkonly] → $(jrow "$parkonly")"
fi
grep -q '"park=" + r\["park"\]' "$BIN/fleet-hub-sessions.sh" && ok "J: park=N rides orch_<sess> (the sidebar's 停放 N)" \
  || bad "J: hub-sessions does not carry park"
grep -q 'decide=" + r\["decide"\]' "$BIN/fleet-hub-sessions.sh" && grep -q 'orch_decide(line) > 0' "$BIN/fleet-sidebar.py" \
  && ok "J: decide=N rides orch_<sess>, and 「新任务」 turns red on it" || bad "J: hub-sessions / sidebar do not carry decide"
python3 - "$BIN" <<'EOF' && ok "J: orch_decide reads decide=N wherever it sits, 0 without" || bad "J: orch_decide"
import importlib.util, sys
src = open(sys.argv[1] + "/fleet-sidebar.py", encoding="utf-8").read()
start = src.index("def orch_decide(p):"); end = src.index("\ndef ", start + 10)
ns = {}; exec(src[start:end], ns)
f = ns["orch_decide"]
assert f(["w", "n", "online", "done", "", "", "", "decide=2"]) == 2
assert f(["w", "n", "online", "done", "", "", "3"]) == 0
assert f(None) == 0
EOF

[ "$fails" = 0 ] && { echo "fleet-steward selftest PASS"; exit 0; }
echo "fleet-steward selftest: $fails FAILED"; exit 1
