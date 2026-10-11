#!/bin/bash
# fleet-steward-selftest.sh — the steward (issue #2670, EPIC #2668 C2):
# bin/fleet-steward-tick.sh → bin/fleet_steward.py (the beat with no model). The
# resident window (bin/fleet-steward.sh), its attention count and the decide
# count's road to the client went with the seat (issue #3118).
#
# GitHub is a directory of comment files (fleet_decision.py's seams), the fleet's
# windows / ledgers / peer channel are seams too; the window legs run an isolated
# tmux server with a fake agent.
#
#   Every beat below is `beat --holder` with a holder (the seam FLEET_STEWARD_HOLDER_CMD).
#   A  a calm beat: delta empty, exit 1, NO turn for the model (0 calls)
#   B  three questions, one the charter answers: the beat wakes the model once
#      (the [steward] line printed to the holder's own loop, never sent);
#      `answer --by steward` closes one; `sheet` hands the orchestrator ONE
#      [decision] of 2 rows; the decide count stamped is 2; a second `sheet` with
#      the same rows sends nothing
#   C  a never:* row: `answer --by steward` refuses it
#   D  a due row is answered by its default at the beat (C1's apply_due) once
#   E  a write storm: past FLEET_STEWARD_WRITES the answers wait a beat — the card
#      says 延后 N, the next beat posts them, never more than the budget a beat
#   F  not due: the every-minute caller returns 4 with no lock and no read
#   W  a red base a worker filed (issue #2960): `breakage` spawns its fixer with
#      --origin steward while somebody holds the role; spawned or claimed ⇒ off the
#      queue, no room ⇒ kept; NOBODY holds it ⇒ nothing spawned, the person told
#      once, kept — the next holder's beat spawns it
#   O  nobody holds the steward role (EPIC #3111 C4, issue #3115): a due row is not
#      answered, no backstop / merge, no sheet, page, [decision] or state
#   G  the beat is the holder's: `beat --holder` with no holder and a bare `beat`
#      even with one are rc 3, no state file; bin/fleet-steward.sh is a quiet shell
#   J  no steward count rides the inventory or the client cache (issue #3118)
#   M  who closed a row (issue #2834): rows[id].by is steward · person · default,
#      today's counts carry the default too; a state file written before the field
#      (no `by` on any row) still beats
#   N  the decision sheet's panel (issue #2832): one ticket asked thrice = one
#      group; @sheet_pane 1 ⇒ one sentence, 0 / none ⇒ the whole sheet byte for
#      byte; a group answered id by id ⇒ one line in decision-<day>.md; v=0 rows group
#   L  the panels' change stamp: every State.save() moves global/steward.stamp
#      (`<seq> <epoch_ms>`, issue #2835) by exactly one
#   K  the health watch (bin/fleet_steward_health.py, fleet-doctor.sh --json,
#      issue #2674): the first doctor run is the baseline; PASS→WARN files ONE
#      issue; still WARN files nothing; gone and back is a 又出现 comment; an
#      unreadable run changes nothing; idle sessions with every sleep refused in
#      the window file ONE issue, once, a scan that accepts none; done:<dur>
#      sessions no idle reap closed file ONE more (a merged cleanup is not one),
#      a reaped-idle line none; a row new on one doctor run only
#      (FLEET_STEWARD_HEALTH_CONFIRM 2) files nothing
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
# who holds the steward role (take_role, EPIC #3111 C4): @9, unless $ST_GH/noholder
printf '#!/bin/sh\n[ -e "$ST_GH/noholder" ] || printf "@9\\n"\n' > "$WORK/bin/holder"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$ST_GH/alerts.log"\n' > "$WORK/bin/alert"
# the health watch (issue #2674): the doctor prints $ST_DOCTOR, the idle windows $ST_IDLE
printf '#!/bin/sh\ncat "$ST_DOCTOR" 2>/dev/null || printf "{\\"rows\\": []}\\n"\n' > "$WORK/bin/doctor"
printf '#!/bin/sh\ncat "$ST_IDLE" 2>/dev/null\n' > "$WORK/bin/idle"
chmod +x "$WORK/bin/"*
export ST_DOCTOR="$WORK/doctor.json" ST_IDLE="$WORK/idle.txt"
export ST_GH="$WORK/gh" ST_WINS="$WORK/wins.txt" \
  FLEET_DECISION_COMMENTS_CMD="$WORK/bin/gh-comments" FLEET_DECISION_POST_CMD="$WORK/bin/gh-post" \
  FLEET_DECISION_PARENT_CMD="$WORK/bin/gh-parent" FLEET_STEWARD_WINDOWS_CMD="$WORK/bin/wins" \
  FLEET_STEWARD_CHILDREN_CMD="$WORK/bin/children" FLEET_STEWARD_SEND_CMD="$WORK/bin/send" \
  FLEET_STEWARD_STAMP_CMD="$WORK/bin/stamp" FLEET_STEWARD_HOLDER_CMD="$WORK/bin/holder" \
  FLEET_STEWARD_ALERT_CMD="$WORK/bin/alert" \
  FLEET_STEWARD_DOCTOR_CMD="$WORK/bin/doctor" FLEET_STEWARD_IDLE_CMD="$WORK/bin/idle" \
  FLEET_STEWARD_SLEEP_LOG="$WORK/sleep.log" FLEET_STEWARD_CLEANUP_LOG="$WORK/cleanup.log" FLEET_SLEEP=observe
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
TICK beat --holder --force >/dev/null; rc=$?
TICK beat --holder --force >"$WORK/out" 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(sends)" = 0 ] && [ "$(calls)" = 0 ] && grep -q '平静' "$WORK/out" \
  && ok "A: a calm beat — exit 1, card 平静, no turn sent (0 model calls)" \
  || bad "A: calm beat rc=$rc sends=$(sends) calls=$(calls): $(cat "$WORK/out")"

# L — the panels' change stamp (issue #2835): every State.save() moves
# global/steward.stamp `<seq> <epoch_ms>` by exactly one
STAMP="$FLEET_CONF_DIR/global/steward.stamp"
s0=$(cut -d' ' -f1 "$STAMP" 2>/dev/null || echo 0)
TICK beat --holder --force >/dev/null 2>&1
s1=$(cut -d' ' -f1 "$STAMP" 2>/dev/null || echo 0)
python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_steward as f; f.State().save()' "$BIN"
s2=$(cut -d' ' -f1 "$STAMP" 2>/dev/null || echo 0)
ms=$(cut -d' ' -f2 "$STAMP" 2>/dev/null)
[ "$s0" -gt 0 ] && [ "$s1" -gt "$s0" ] && [ "$s2" = $((s1 + 1)) ] && [ "${#ms}" = 13 ] \
  && ok "L: every State.save() moves steward.stamp by one (<seq> <epoch_ms>)" \
  || bad "L: stamp seq $s0 → $s1 → $s2, ms='$ms'"

# B — three questions, one the charter answers
ask 11 '先发 20 家还是 50 家？' --suggest '20 家' --due 4h
ask 12 '要不要拆成两个 PR？' --suggest '拆' --due 4h
ask 13 '用哪个颜色？' --suggest '蓝' --due 4h
needs 11; needs 12; needs 13
TICK beat --holder --force >"$WORK/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(sends)" = 0 ] && grep -q '^\[steward\].*新问题 3' "$WORK/out" && [ "$(calls)" = 1 ] \
  && ok "B: three new questions wake the model once — the [steward] line printed to the holder's loop, nothing sent" \
  || bad "B: beat rc=$rc sends=$(sends) calls=$(calls): $(cat "$WORK/out") / $(cat "$ST_GH/sends.log" 2>/dev/null)"
r11=$(rowid 先发)
TICK answer --row "$r11" --text '20 家（共同约定 2：先小后大）' --source 'https://github.com/o/r/issues/100' >/dev/null
grep -q "fleet:answer row=$r11 by=steward" "$ST_GH/o-r-11.json" && grep -q 'o/r#11 to-worker' "$ST_GH/posts.log" \
  && ok "B: answer --by steward goes to the worker (--to-worker) with its answer marker" \
  || bad "B: the self-answer was not posted as expected: $(cat "$ST_GH/posts.log")"
TICK sheet >"$WORK/out" 2>&1
n=$(grep -c '^>>> orchestrator' "$ST_GH/sends.log")
# the person's words, one line a thing (issue #2735): no table, no page link (#3118)
msg=$(awk '/^>>> orchestrator/{f=1;next} /^>>> /{f=0} f' "$ST_GH/sends.log")
rows=$(printf '%s\n' "$msg" | grep -c '〔row [A-Za-z0-9]')
[ "$n" = 1 ] && [ "$rows" = 2 ] && ! printf '%s\n' "$msg" | grep -q '^| ' \
  && ! printf '%s\n' "$msg" | grep -q 'page.html' && [ "$(cat "$ST_GH/decide")" = 2 ] && grep -q '\[decision\]' "$ST_GH/sends.log" \
  && ok "B: sheet → ONE [decision] of 2 rows to the orchestrator, decide=2 stamped" \
  || bad "B: sheet sends=$n rows=$rows decide=$(cat "$ST_GH/decide" 2>/dev/null): $(cat "$WORK/out")"
ls "$FLEET_CONF_DIR/fleets/st/steward/"decision-*.md >/dev/null 2>&1 && ok "B: the sheet is kept as decision-<date>.md" \
  || bad "B: no decision-<date>.md"
TICK sheet >/dev/null 2>&1
[ "$(grep -c '^>>> orchestrator' "$ST_GH/sends.log")" = 1 ] && ok "B: the same rows again — not sent twice" \
  || bad "B: an unchanged sheet was sent again"
TICK beat --holder --force >"$WORK/out" 2>&1
[ "$(cat "$ST_GH/decide")" = 2 ] && [ "$(calls)" = 1 ] && ! grep -q '^\[steward\]' "$WORK/out" \
  && ok "B: the next beat keeps decide=2 and wakes no one (nothing new)" \
  || bad "B: next beat decide=$(cat "$ST_GH/decide") calls=$(calls): $(cat "$WORK/out")"
r12=$(rowid 要不要)
TICK answer --row "$r12" --text '拆' --by person >/dev/null
[ "$(cat "$ST_GH/decide")" = 1 ] && grep -q "fleet:answer row=$r12 by=person" "$ST_GH/o-r-12.json" \
  && ok "B: the person's answer written back — decide drops to 1" || bad "B: person answer: decide=$(cat "$ST_GH/decide")"

# C — never-default rows are not the steward's
ask 14 '要不要开一台云机器？' --suggest '不开' --due 4h
needs 14
TICK beat --holder --force >/dev/null 2>&1
r14=$(rowid 要不要开)
TICK answer --row "$r14" --text '不开' >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" = 1 ] && grep -q never "$WORK/err" && ! grep -q "row=$r14" "$ST_GH/o-r-14.json" \
  && ok "C: a never:money row — answer --by steward refuses it" || bad "C: rc=$rc $(cat "$WORK/err")"

# D — a due row is answered by its default, once
ask 15 '日志留几天？' --suggest '7 天' --due 2000-01-01T00:00:00Z
needs 15
TICK beat --holder --force >/dev/null 2>&1
TICK beat --holder --force >/dev/null 2>&1
nd=$(grep -c 'by=default' "$ST_GH/o-r-15.json")
[ "$nd" = 1 ] && grep -q 'fleet:default-decided' "$ST_GH/o-r-100.json" \
  && ok "D: a due row answered by its default once + 默认拍板 on the parent" || bad "D: defaults posted $nd times"

# M — who closed a row (issue #2834): the patrol panel's 自答 / 默认拍板 count
by_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rows"][sys.argv[2]].get("by", "-"))' "$STATE" "$1"; }
r15=$(rowid 日志)
ndef=$(python3 -c 'import json,sys,time; d=json.load(open(sys.argv[1])); print(d["counts"][time.strftime("%Y-%m-%d")].get("default", 0))' "$STATE")
[ "$(by_of "$r11")" = steward ] && [ "$(by_of "$r12")" = person ] && [ "$(by_of "$r15")" = default ] && [ "$ndef" = 1 ] \
  && ok "M: rows[id].by — steward · person · default, today's counts carry the default" \
  || bad "M: by r11=$(by_of "$r11") r12=$(by_of "$r12") r15=$(by_of "$r15") default count=$ndef"
python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for r in d["rows"].values(): r.pop("by", None)
json.dump(d, open(sys.argv[1], "w"))' "$STATE"
TICK beat --holder --force >"$WORK/out" 2>&1; rc=$?
case "$rc" in 0|1) ok "M: a state file with no \`by\` on any row still beats (rc $rc)" ;;
  *) bad "M: an old state file broke the beat rc=$rc: $(cat "$WORK/out")" ;; esac

# E — a write storm: budget 3, five answers
for i in 21 22 23 24 25; do ask "$i" "问题 ${i}？" --suggest 是 --due 4h; needs "$i"; done
TICK beat --holder --force >/dev/null 2>&1
before=$(posts)
for i in 21 22 23 24 25; do
  FLEET_STEWARD_WRITES=3 TICK answer --row "$(rowid "问题 ${i}")" --text 是 >/dev/null 2>&1
done
FLEET_STEWARD_WRITES=3 python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["deferred"]))' "$STATE" > "$WORK/def"
mid=$(( $(posts) - before ))
# the beat that wrote these spent nothing yet: the five land 3 now, 2 deferred
[ "$mid" = 3 ] && [ "$(cat "$WORK/def")" = 2 ] && ok "E: past the budget (3) the answers wait — 3 posted, 2 deferred" \
  || bad "E: posted $mid, deferred $(cat "$WORK/def")"
FLEET_STEWARD_WRITES=3 TICK beat --holder --force >"$WORK/out" 2>&1
[ $(( $(posts) - before )) = 5 ] && ok "E: the next beat posts the deferred two first" || bad "E: after the beat posted $(( $(posts) - before ))"
FLEET_STEWARD_WRITES=0 TICK answer --row "$r14" --text x --by person >/dev/null 2>&1
FLEET_STEWARD_WRITES=0 TICK beat --holder --force >"$WORK/out" 2>&1
grep -q '延后 1 条' "$WORK/out" && ok "E: the card says 延后 N 条" || bad "E: card: $(cat "$WORK/out")"

# F — not due: returns 4 at once
TICK beat --holder >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && ok "F: not due — the every-minute caller returns 4" || bad "F: rc=$rc"

# N — the decision sheet's panel (issue #2832, EPIC #2831 C1), in a book of its
# own: one ticket asked three times is ONE group (fleet_decision.group, kept as
# `groups` on every save); the steward holder's @sheet_pane 0 (or none at all) gets
# the whole sheet byte for byte as before, 1 gets one sentence and no table; an
# answer through the panel's road lands on the row and once in decision-<day>.md;
# old-format rows (v=0, no fields) group the same way
(
  export FLEET_CONF_DIR="$WORK/confM" ST_GH="$WORK/ghM" ST_WINS="$WORK/winsM.txt"
  STATE="$FLEET_CONF_DIR/global/steward.state.json"
  mkdir -p "$FLEET_CONF_DIR/fleets/st/repos" "$ST_GH"
  printf 'FLEET_REPO="o/r"\n' > "$FLEET_CONF_DIR/fleets/st/repos/o-r.conf"
  : > "$ST_WINS"
  ask 31 '真机演练第 1 次可以开始吗？' --suggest '开始' --due 4h
  ask 31 '真机演练第 2 次可以开始吗？' --suggest '开始' --due 4h
  ask 31 '真机演练第 3 次可以开始吗？' --suggest '开始' --due 4h
  ask 32 '小程序试点选哪家商户？' --suggest '甲' --due 4h
  needs 31; needs 32
  TICK beat --holder --force >/dev/null 2>&1
  g=$(python3 -c 'import json,sys; g=json.load(open(sys.argv[1]))["groups"]; o=[x for x in g if x["state"]=="open"]; print(len(o), len(o[0]["ids"]), "问了 3 次" in o[0]["from"], o[0]["item"])' "$STATE")
  n=$(python3 "$BIN/fleet_decision.py" group --rows "$STATE" | grep -c '"state": "open"')
  [ "$g" = "2 3 True 真机演练第 3 次可以开始吗？" ] && [ "$n" = 2 ] \
    && ok "N: one ticket asked 3 times + one more = 2 groups (the latest ask speaks), kept as groups; the CLI agrees" \
    || bad "N: groups '$g', CLI open groups $n"
  last() { awk '/^>>> orchestrator/{m=""; f=1; next} /^>>> /{f=0} f{m=m $0 "\n"} END{printf "%s", m}' "$ST_GH/sends.log" \
    | sed 's/id=[0-9a-f-]*/id=X/'; }
  printf '@9\tsteward\tidle\t\t\t\t\n' >> "$ST_WINS"
  TICK sheet --force >/dev/null 2>&1; none=$(last)
  sed -i.bak '/steward/d' "$ST_WINS"; printf '@9\tsteward\tidle\t\t\t\t\t0\n' >> "$ST_WINS"
  TICK sheet --force >/dev/null 2>&1; zero=$(last)
  full=$(python3 -c 'import json,sys,time; print(json.load(open(sys.argv[1])).get("sheets_full", {}).get(time.strftime("%Y-%m-%d", time.gmtime()), 0))' "$STATE")
  [ -n "$none" ] && [ "$none" = "$zero" ] && printf '%s\n' "$zero" | grep -q '〔row ' && [ "$full" = 2 ] \
    && ok "N: @sheet_pane 0 = no option at all, byte for byte: the whole sheet, counted in sheets_full (2)" \
    || bad "N: pane 0 vs none differ or not full (sheets_full=$full): [$none] vs [$zero]"
  sed -i.bak '/steward/d' "$ST_WINS"; printf '@9\tsteward\tidle\t\t\t\t\t1\n' >> "$ST_WINS"
  TICK sheet --force >/dev/null 2>&1; one=$(last)
  full=$(python3 -c 'import json,sys,time; print(json.load(open(sys.argv[1])).get("sheets_full", {}).get(time.strftime("%Y-%m-%d", time.gmtime()), 0))' "$STATE")
  [ "$(printf '%s\n' "$one" | grep -c .)" = 2 ] && printf '%s\n' "$one" | grep -q '决定单有 2 件新的，在右边' \
    && ! printf '%s\n' "$one" | grep -q '〔row \|^| ' && printf '%s\n' "$one" | grep -q 'fleet:decision' && [ "$full" = 2 ] \
    && ok "N: @sheet_pane 1 — one sentence (+ the marker), no table, not counted as a full sheet" \
    || bad "N: pane 1 sent [$one] (sheets_full=$full)"
  ids=$(python3 -c 'import json,sys; g=json.load(open(sys.argv[1]))["groups"]; print(" ".join([x for x in g if x["src"] == "gh:o/r#31"][0]["ids"]))' "$STATE")
  for id in $ids; do TICK answer --row "$id" --text '开始' --by person >/dev/null 2>&1; done
  md="$FLEET_CONF_DIR/fleets/st/steward/decision-$(TZ=UTC date +%Y-%m-%d).md"
  hits=$(grep -c '第 1 件：按建议（by person）' "$md" 2>/dev/null)
  marks=$(grep -o 'fleet:answer row=[^ ]* by=person' "$ST_GH/o-r-31.json" | sort -u | grep -c .)
  st=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=[d["rows"][i] for i in sys.argv[2].split()]; print(set((x["state"], x["by"], x["answer"]) for x in r))' "$STATE" "$ids")
  [ "$hits" = 1 ] && tail -n 1 "$md" | grep -q '按建议' && [ "$marks" = 3 ] && [ "$st" = "{('answered', 'person', '开始')}" ] \
    && ok "N: the group answered id by id — 3 answer marks, rows answered/by/answer, ONE line in decision-<day>.md" \
    || bad "N: answer log hits=$hits marks=$marks rows=$st ids=$ids: $(tail -n 3 "$md" 2>&1)"
  python3 - "$BIN" <<'PY' && ok "N: old-format rows (v=0, no fields) on one ticket group the same way" || bad "N: v=0 rows did not group"
import sys; sys.path.insert(0, sys.argv[1]); import fleet_decision as fd
rows = [{"id": "legacy-%d" % i, "v": "0", "src": "gh:o/r#9", "state": "open", "asked": "2026-10-09T0%d:00:00Z" % i,
         "item": "旧问题 %d" % i, "due": "", "default": "", "suggest": "", "kind": "normal"} for i in (1, 2)]
g = fd.group(rows + [{"id": "x", "src": "gh:o/r#8", "state": "open", "v": "0", "item": "另一件"}])
g9 = [x for x in g if x["src"] == "gh:o/r#9"]
assert len(g) == 2 and len(g9) == 1 and g9[0]["ids"] == ["legacy-1", "legacy-2"] and g9[0]["item"] == "旧问题 2" and g9[0]["default"]
assert fd.group([{"id": "a", "src": "gh:o/r#1", "state": "answered"}, {"id": "b", "src": "gh:o/r#1", "state": "answered"}])[1]["ids"] == ["b"]
PY
) | while IFS= read -r line; do printf '%s\n' "$line"; case "$line" in FAIL*) echo x >> "$WORK/failsN" ;; esac; done
[ -s "$WORK/failsN" ] && fails=$((fails + $(grep -c . "$WORK/failsN")))

# K — the health watch (issue #2674): doctor rows that got worse, idle sessions
# nothing put down; one issue per fingerprint, a recurrence a comment
cat > "$WORK/bin/hfile" <<'EOF'
#!/bin/sh
n=$(( $(grep -c . "$ST_GH/hissues" 2>/dev/null || echo 0) + 500 ))
printf '%s\t%s\t%s\n' "$n" "$2" "$(tr '\n' ' ')" >> "$ST_GH/hissues"
printf 'https://github.com/%s/issues/%s\n' "$1" "$n"
EOF
printf '#!/bin/sh\ngrep -F -- "$2" "$ST_GH/hissues" 2>/dev/null | head -1 | cut -f1\n' > "$WORK/bin/hfind"
chmod +x "$WORK/bin/hfile" "$WORK/bin/hfind"
doc() { python3 -c 'import json,sys; print(json.dumps({"rows": [dict(zip(("level","row","msg"), r.split("|"))) for r in sys.argv[1:]]}))' "$@" > "$ST_DOCTOR"; }
HT() { FLEET_STEWARD_HEALTH_EVERY=0 FLEET_STEWARD_HEALTH_CONFIRM="${FLEET_STEWARD_HEALTH_CONFIRM:-1}" FLEET_STEWARD_HEALTH_REPO=o/f FLEET_STEWARD_HEALTH_FILE_CMD="$WORK/bin/hfile" \
         FLEET_STEWARD_HEALTH_FIND_CMD="$WORK/bin/hfind" FLEET_STEWARD_IDLE_SECS=60 TICK beat --holder --force; }
hn() { grep -c . "$ST_GH/hissues" 2>/dev/null || echo 0; }
# the beats above ran the doctor too (no rows): start this leg on a fresh watch
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("health", None); json.dump(d, open(sys.argv[1], "w"))' "$STATE"
doc 'PASS|tmux|tmux 3.4' 'WARN|labels|missing fleet labels: desk' 'PASS|quota|reading fresh'
HT >/dev/null 2>&1
[ "$(hn)" = 0 ] && ok "K: the first doctor run is the baseline — an old WARN files nothing" \
  || bad "K: the baseline filed $(hn): $(cat "$ST_GH/hissues")"
doc 'PASS|tmux|tmux 3.4' 'WARN|labels|missing fleet labels: desk' 'WARN|quota|ccquota read 401 for 3 accounts — check the hub'
HT >"$WORK/out" 2>&1
[ "$(hn)" = 1 ] && grep -q 'fleet:health key=quota:' "$ST_GH/hissues" && grep -q '体检变差：quota' "$ST_GH/hissues" \
  && grep -q '健康：新立 1' "$WORK/out" \
  && ok "K: a doctor row PASS→WARN files ONE issue, marked fleet:health key=quota:<fp>; the card says 新立 1" \
  || bad "K: PASS→WARN filed $(hn): $(cat "$ST_GH/hissues" 2>/dev/null) / $(cat "$WORK/out")"
doc 'PASS|tmux|tmux 3.4' 'WARN|labels|missing fleet labels: desk' 'WARN|quota|ccquota read 401 for 5 accounts — check the hub'
HT >/dev/null 2>&1
[ "$(hn)" = 1 ] && ok "K: still WARN next beat (its numbers changed) — nothing filed again" \
  || bad "K: a still-WARN row filed again: $(hn)"
doc 'PASS|tmux|tmux 3.4' 'WARN|labels|missing fleet labels: desk' 'PASS|quota|reading fresh'
HT >/dev/null 2>&1
before=$(posts)
doc 'PASS|tmux|tmux 3.4' 'WARN|labels|missing fleet labels: desk' 'WARN|quota|ccquota read 401 for 2 accounts — check the hub'
HT >/dev/null 2>&1
[ "$(hn)" = 1 ] && [ $(( $(posts) - before )) = 1 ] && grep -q 'fleet:health key=quota:' "$ST_GH/o-f-500.json" \
  && ok "K: gone and back — a 又出现 comment on the open issue, no second issue" \
  || bad "K: recurrence: issues $(hn), comments $(( $(posts) - before ))"
printf 'garbage\n' > "$ST_DOCTOR"
HT >/dev/null 2>&1
[ "$(hn)" = 1 ] && python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["health"]["active"]; sys.exit(0 if any(k.startswith("quota:") for k in a) else 1)' "$STATE" \
  && ok "K: an unreadable doctor run is not \"all good\" — the last rows stand, nothing filed" \
  || bad "K: an unreadable doctor changed the picture"
now=$(date +%s); old=$((now - 600)); at=$(date '+%Y-%m-%dT%H:%M:%S')
printf '@71\tworker\tdone\t%s\t\t\tissue-71\n@72\tworker\tdone\t%s\t\t\tscratch-3\n@73\tworker\tworking\t%s\t\t\tissue-73\n' \
  "$old" "$old" "$old" > "$ST_IDLE"
printf '{"session": "st", "window": "@71", "at": "%s", "skip": "wrong fleet"}\n{"session": "st", "window": "@72", "at": "%s", "eligible": true, "session_id": "x"}\n' \
  "$at" "$at" > "$WORK/sleep.log"
HT >/dev/null 2>&1
[ "$(hn)" = 1 ] && ok "K: idle sessions the sleep scan still accepts — no issue" || bad "K: an accepting scan filed: $(hn)"
printf '{"session": "st", "window": "@71", "at": "%s", "skip": "wrong fleet"}\n{"session": "st", "window": "@72", "at": "%s", "skip": "wrong fleet"}\n' \
  "$at" "$at" > "$WORK/sleep.log"
HT >/dev/null 2>&1
[ "$(hn)" = 2 ] && grep -q 'fleet:health key=idle-sleep:st' "$ST_GH/hissues" && grep -q 'wrong fleet × 2' "$ST_GH/hissues" \
  && grep -q '闲置会话 2 个' "$ST_GH/hissues" \
  && ok "K: 2 idle sessions, every sleep refused in the window — ONE issue naming the refusal" \
  || bad "K: sleep silence filed $(hn): $(tail -1 "$ST_GH/hissues" 2>/dev/null)"
HT >/dev/null 2>&1
[ "$(hn)" = 2 ] && ok "K: the same silence next beat — not filed twice" || bad "K: idle filed again: $(hn)"
# the reaper, judged apart: a merged PR's cleanup is no idle reap
printf '@71\tworker\tdone\t%s\tdone:2h\t\tissue-71\n@72\tworker\tdone\t%s\t\t\tscratch-3\n' "$old" "$old" > "$ST_IDLE"
printf '%s fleet-cleanup: st: cleaned:abc123  (PR #9, issue-9)  [slot 1/4]\n' "$(date +%H:%M:%S)" > "$WORK/cleanup.log"
HT >/dev/null 2>&1
[ "$(hn)" = 3 ] && grep -q 'fleet:health key=idle-reap:st' "$ST_GH/hissues" && grep -q '到点该回收的会话 1 个' "$ST_GH/hissues" \
  && ok "K: a done:2h session idle past the window, the idle reaper closed none (a merged cleanup ran) — ONE issue" \
  || bad "K: reap silence filed $(hn): $(tail -1 "$ST_GH/hissues" 2>/dev/null)"
printf '%s fleet-cleanup: st: reaped-idle:@70 policy=done:2h norepo stopped:@70\n' "$(date +%H:%M:%S)" >> "$WORK/cleanup.log"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["health"]["active"].pop("idle-reap:st", None); json.dump(d, open(sys.argv[1], "w"))' "$STATE"
before=$(posts)
HT >/dev/null 2>&1
[ "$(hn)" = 3 ] && [ "$(posts)" = "$before" ] \
  && ok "K: the idle reaper closed one in the window — it is alive, nothing noted" \
  || bad "K: a fresh idle reap still read as silence"
# a one-run hiccup: with the default 2 runs to confirm, a row new once files nothing
doc 'PASS|tmux|tmux 3.4' 'WARN|labels|missing fleet labels: desk' 'WARN|quota|ccquota read 401 for 2 accounts — check the hub' \
    'WARN|machine|could not read the load average'
FLEET_STEWARD_HEALTH_CONFIRM=2 HT >/dev/null 2>&1
doc 'PASS|tmux|tmux 3.4' 'WARN|labels|missing fleet labels: desk' 'WARN|quota|ccquota read 401 for 2 accounts — check the hub'
FLEET_STEWARD_HEALTH_CONFIRM=2 HT >/dev/null 2>&1
n1=$(hn)
doc 'PASS|tmux|tmux 3.4' 'WARN|labels|missing fleet labels: desk' 'WARN|quota|ccquota read 401 for 2 accounts — check the hub' \
    'WARN|machine|could not read the load average'
FLEET_STEWARD_HEALTH_CONFIRM=2 HT >/dev/null 2>&1
FLEET_STEWARD_HEALTH_CONFIRM=2 HT >/dev/null 2>&1
[ "$n1" = 3 ] && [ "$(hn)" = 4 ] && ok "K: a row new on one run only files nothing; new on two runs in a row files one" \
  || bad "K: confirm: after the hiccup $n1, after two runs $(hn)"
: > "$WORK/cleanup.log"; : > "$ST_IDLE"

# G — the beat is the holder's; the old seat's launcher is a quiet shell (issue #3118)
rm -f "$STATE"
touch "$ST_GH/noholder"
TICK beat --holder >/dev/null 2>&1; rc=$?
python3 "$BIN/fleet_steward.py" beat --session st >/dev/null 2>&1; rc2=$?
rm -f "$ST_GH/noholder"
python3 "$BIN/fleet_steward.py" beat --session st >/dev/null 2>&1; rc3=$?
[ "$rc" = 3 ] && [ "$rc2" = 3 ] && [ "$rc3" = 3 ] && [ ! -e "$STATE" ] \
  && ok "G: no holder ⇒ beat --holder is a no-op; a bare beat refuses even with one (rc 3, no state written)" \
  || bad "G: unheld beat rc=$rc, bare rc=$rc2/$rc3"
o=$(FLEET_STEWARD=1 bash "$BIN/fleet-steward.sh" ensure st 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$o" ] && ok "G: fleet-steward.sh ensure is a quiet shell — nothing printed, rc 0, no window (issue #3118)" \
  || bad "G: the retired launcher said [$o] rc=$rc"

# J — no steward column rides the inventory (issue #3118): columns 31-37 are gone
grep -v '^ *#' "$BIN/fleet-control-read.sh" "$BIN/fleet-hub-sessions.sh" | grep -q 'orch_decide\|orch_park\|orchdec=\|orchpark=' \
  && bad "J: the node inventory / the client cache still carries a steward count" \
  || ok "J: no orchdec= / orchpark= on the inventory, no decide= / park= in the client cache (issue #3118)"

# W — a red base a WORKER filed (issue #2960): the drain spawns its fixer under the
# steward HOLDER; claimed ⇒ off the queue, no room ⇒ kept. Nobody holds the role
# (EPIC #3111 C4) ⇒ nothing spawned: the person told ONCE, the issue kept queued,
# and the next holder's beat spawns it.
BQ="$FLEET_CONF_DIR/fleets/st/breakage-spawn"; mkdir -p "$BQ"
printf 'o/r\t71\tmaster 红\t\n' > "$BQ/o-r-71"
printf 'o/r\t72\t又红\tcodex\n' > "$BQ/o-r-72"
cat > "$WORK/bin/bkspawn" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ST_GH/bkspawn.log"
case " $* " in *" 72 "*) exit "${BK_RC72:-0}" ;; esac
exit 0
EOF
chmod +x "$WORK/bin/bkspawn"
BK_RC72=2 FLEET_STEWARD_SPAWN_CMD="$WORK/bin/bkspawn" TICK breakage >/dev/null 2>&1
grep -qx '71 st --repo o/r --origin steward --title master 红' "$ST_GH/bkspawn.log" \
  && grep -qx '72 st --repo o/r --origin steward --title 又红 --agent codex' "$ST_GH/bkspawn.log" \
  && [ ! -f "$BQ/o-r-71" ] && [ -f "$BQ/o-r-72" ] \
  && ok "W: a worker's breakage — spawned under the steward holder; no room stays queued" \
  || bad "W: drain $(cat "$ST_GH/bkspawn.log" 2>&1) · left $(ls "$BQ")"
: > "$ST_GH/bkspawn.log"; : > "$ST_GH/alerts.log"; touch "$ST_GH/noholder"
FLEET_STEWARD_SPAWN_CMD="$WORK/bin/bkspawn" TICK breakage >/dev/null 2>&1
FLEET_STEWARD_SPAWN_CMD="$WORK/bin/bkspawn" TICK breakage >/dev/null 2>&1
[ ! -s "$ST_GH/bkspawn.log" ] && [ -f "$BQ/o-r-72" ] && [ "$(grep -c . "$ST_GH/alerts.log")" = 1 ] \
  && grep -q '^event breakage .*o/r#72.*没人接手管家' "$ST_GH/alerts.log" \
  && ok "W2: no holder ⇒ nothing spawned, the person told ONCE (two drains), the issue kept queued" \
  || bad "W2: spawned [$(cat "$ST_GH/bkspawn.log")] alerts [$(cat "$ST_GH/alerts.log")] left $(ls "$BQ")"
rm -f "$ST_GH/noholder"
[ -f "$STATE" ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("next_at", None); json.dump(d, open(sys.argv[1], "w"))' "$STATE"
FLEET_STEWARD_SPAWN_CMD="$WORK/bin/bkspawn" TICK beat --holder >/dev/null 2>&1
grep -qx '72 st --repo o/r --origin steward --title 又红 --agent codex' "$ST_GH/bkspawn.log" && [ ! -f "$BQ/o-r-72" ] \
  && [ ! -e "$BQ/.told-o-r-72" ] \
  && ok "W3: a holder took the role — its beat drains the queue (spawned ⇒ off it)" \
  || bad "W3: drain $(cat "$ST_GH/bkspawn.log" 2>&1) · left $(ls -a "$BQ")"

# O — nobody holds the steward role (EPIC #3111 C4): a due row is not answered,
# nothing spawned, no orphan PR merged, no sheet / page / [decision] written
(
  export FLEET_CONF_DIR="$WORK/confO" ST_GH="$WORK/ghO" ST_WINS="$WORK/winsO.txt"
  STATE="$FLEET_CONF_DIR/global/steward.state.json"
  mkdir -p "$FLEET_CONF_DIR/fleets/st/repos" "$ST_GH" "$FLEET_CONF_DIR/global/epic-running.d"
  printf 'FLEET_REPO="o/r"\n' > "$FLEET_CONF_DIR/fleets/st/repos/o-r.conf"
  : > "$ST_WINS"; touch "$ST_GH/noholder"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$ST_GH/backstop.log"\n' > "$WORK/bin/backstopO"; chmod +x "$WORK/bin/backstopO"
  printf 'o-r-300 %s\n' "$(( $(date +%s) - 86400 ))" > "$FLEET_CONF_DIR/global/epic-running.d/o-r-300"
  ask 41 '日志留几天？' --suggest '7 天' --due 2000-01-01T00:00:00Z
  needs 41
  p0=$(posts)
  FLEET_STEWARD_BACKSTOP_CMD="$WORK/bin/backstopO" TICK beat --holder --force >/dev/null 2>&1; rc=$?
  TICK sheet --force >"$WORK/outO" 2>&1; rc2=$?
  [ "$rc" = 3 ] && [ "$rc2" = 3 ] && [ "$(posts)" = "$p0" ] && ! grep -q 'by=default' "$ST_GH/o-r-41.json" \
    && [ ! -s "$ST_GH/backstop.log" ] && [ "$(sends)" = 0 ] && [ ! -e "$STATE" ] \
    && [ ! -e "$FLEET_CONF_DIR/fleets/st/steward" ] && grep -q '没人接手管家' "$WORK/outO" \
    && ok "O: no holder — the due row unanswered, no backstop / merge, no sheet, page or [decision], no state" \
    || bad "O: rc=$rc sheet rc=$rc2 posts ${p0}→$(posts) backstop [$(cat "$ST_GH/backstop.log" 2>/dev/null)] sends=$(sends) state=$(ls "$FLEET_CONF_DIR/global")"
) | while IFS= read -r line; do printf '%s\n' "$line"; case "$line" in FAIL*) echo x >> "$WORK/failsO" ;; esac; done
[ -s "$WORK/failsO" ] && fails=$((fails + $(grep -c . "$WORK/failsO")))

[ "$fails" = 0 ] && { echo "fleet-steward selftest PASS"; exit 0; }
echo "fleet-steward selftest: $fails FAILED"; exit 1
