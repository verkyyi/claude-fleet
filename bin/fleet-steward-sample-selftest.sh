#!/bin/bash
# fleet-steward-sample-selftest.sh — one member of each finished batch on the
# decision sheet (issue #2678, EPIC #2668 R2): bin/fleet_sample.py on the
# steward's beat (bin/fleet_steward.py → fleet-steward-tick.sh), the read-only
# `samples` area of bin/fleet_decision.py's render, fleet-evidence.sh export (a seam).
#
#   A  a batch closes: the next beat draws ONE sample (a member with an `after`),
#      posts the sheet itself (no open row needed, no model turn), the area
#      carries the member, its note and its capture; the decide count stays 0
#   B  later beats draw nothing more and send no second sheet; a sheet the same
#      day for a new row carries the day's sample again
#   C  a batch whose members left no `after`: the sample says so (无证据), never
#      a before passed off as an after
#   D  the draw is seeded by the batch: the same rows draw the same member
#   E  an export that cannot run is retried, then given up (FLEET_STEWARD_SAMPLE_TRIES)
#   F  no sample ⇒ render byte for byte as before
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sample-st.XXXXXX")
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
trap 'rm -rf "$WORK"' EXIT

export FLEET_UI_LANG=zh FLEET_DECISION_TZ=UTC FLEET_SKIP_GLOBAL_CONF=1 FLEET_STEWARD=1 FLEET_STEWARD_FOLLOWUP_SYNC=1
mkdir -p "$WORK/bin"
cat > "$WORK/bin/issue" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
repo, n = sys.argv[1:3]
st = os.path.join(os.environ["ST_GH"], "state-%s" % n)
print(json.dumps({"comments": [], "state": open(st).read().strip() if os.path.exists(st) else "OPEN"}))
EOF
# the fake fleet-evidence.sh export: $ST_GH/ev-<N>.tsv holds `member stage ts file note`;
# it copies nothing real — it writes the file into <dest>/evidence/<M>/ and prints the row
cat > "$WORK/bin/evidence" <<'EOF'
#!/bin/sh
echo "$*" >> "$ST_GH/evidence.log"
[ -f "$ST_GH/ev-fail" ] && { echo "boom" >&2; exit 1; }
n=$3; dest=$(eval echo "\${$#}")
printf '# member\tstage\tts\tpath\tnote\n'
[ -f "$ST_GH/ev-$n.tsv" ] || exit 0
while IFS="$(printf '\t')" read -r m st ts fn nt; do
  [ "$st" = none ] && { printf '%s\tnone\t\t\t\n' "$m"; continue; }
  mkdir -p "$dest/evidence/$m"; printf 'output of %s\nline two\n' "$m" > "$dest/evidence/$m/$fn"
  printf '%s\t%s\t%s\tevidence/%s/%s\t%s\n' "$m" "$st" "$ts" "$m" "$fn" "$nt"
done < "$ST_GH/ev-$n.tsv"
EOF
printf '#!/bin/sh\n{ printf ">>> %%s\\n" "$1"; cat; printf "\\n"; } >> "$ST_GH/sends.log"\n' > "$WORK/bin/send"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" > "$ST_GH/decide"\n' > "$WORK/bin/stamp"
printf '#!/bin/sh\n:\n' > "$WORK/bin/noop"
printf '#!/bin/sh\nprintf "{\\"seq\\": 0, \\"children\\": []}\\n"\n' > "$WORK/bin/children"
printf '#!/bin/sh\nprintf "{\\"comments\\": []}\\n"\n' > "$WORK/bin/gh-comments"
chmod +x "$WORK/bin/"*
export FLEET_DECISION_COMMENTS_CMD="$WORK/bin/gh-comments" FLEET_DECISION_POST_CMD="$WORK/bin/noop" \
  FLEET_DECISION_PARENT_CMD="$WORK/bin/noop" FLEET_STEWARD_WINDOWS_CMD="$WORK/bin/noop" \
  FLEET_STEWARD_CHILDREN_CMD="$WORK/bin/children" FLEET_STEWARD_SEND_CMD="$WORK/bin/send" \
  FLEET_STEWARD_STAMP_CMD="$WORK/bin/stamp" FLEET_STEWARD_STAMP_TODO_CMD="$WORK/bin/noop" \
  FLEET_STEWARD_ISSUE_CMD="$WORK/bin/issue" FLEET_STEWARD_STABLE_CMD="$WORK/bin/noop" \
  FLEET_STEWARD_TICKET_CMD="$WORK/bin/noop" FLEET_STEWARD_HOLD_CMD="$WORK/bin/noop" \
  FLEET_STEWARD_DOCTOR_CMD="$WORK/bin/noop" FLEET_STEWARD_IDLE_CMD="$WORK/bin/noop" \
  FLEET_STEWARD_EVIDENCE_CMD="$WORK/bin/evidence" FLEET_STEWARD_PARK=0

fresh() {
  export FLEET_CONF_DIR="$WORK/$1/conf" ST_GH="$WORK/$1/gh"
  mkdir -p "$FLEET_CONF_DIR/fleets/st/repos" "$ST_GH"
  printf 'FLEET_REPO="o/r"\n' > "$FLEET_CONF_DIR/fleets/st/repos/o-r.conf"
  STATE="$FLEET_CONF_DIR/global/steward.state.json"
}
TICK() { python3 "$BIN/fleet_steward.py" "$@" --session st; }
closed() { echo CLOSED > "$ST_GH/state-$1"; TICK followups --watch "o/r#$1" >/dev/null; }
sends() { [ -f "$ST_GH/sends.log" ] || { echo 0; return; }; grep -c "^>>> $1" "$ST_GH/sends.log"; }
nsamp() { python3 -c 'import json,sys; print(len((json.load(open(sys.argv[1])).get("samples") or {}).get("items") or []))' "$STATE"; }
T=$(printf '\t')

# A — a batch closes: one sample on the next beat's sheet
fresh A
printf '11%sbefore%s2026-10-08T01:00:00Z%sb.txt%s前\n11%safter%s2026-10-09T01:00:00Z%sa.txt%s卡片变绿\n12%snone%s%s%s\n' \
  "$T" "$T" "$T" "$T" "$T" "$T" "$T" "$T" "$T" "$T" "$T" "$T" > "$ST_GH/ev-100.tsv"
TICK beat --force >/dev/null 2>&1
[ "$(sends orchestrator)" = 0 ] && ok "A: an open batch draws nothing" || bad "A: open batch sent $(sends orchestrator)"
closed 100
TICK beat --force >"$WORK/out" 2>&1
sheet=$(ls "$FLEET_CONF_DIR"/fleets/st/steward/decision-*.md 2>/dev/null | head -1)
[ "$(nsamp)" = 1 ] && [ "$(sends orchestrator)" = 1 ] && [ "$(sends steward)" = 0 ] \
  && grep -q '抽样 1 个批次' "$WORK/out" \
  && ok "A: the batch closed → ONE sample, the sheet sent by the beat, no model turn; the card says so" \
  || bad "A: samples=$(nsamp) orch=$(sends orchestrator) steward=$(sends steward) / $(cat "$WORK/out")"
grep -q '### 抽样' "$sheet" && grep -q 'o/r#100 → #11 · 卡片变绿 · 2026-10-09T01:00:00Z' "$sheet" \
  && grep -q 'samples/o-r.100/evidence/11/a.txt' "$sheet" && grep -q 'output of 11' "$sheet" \
  && grep -q '<!-- fleet:sample epic=o/r#100 member=11 -->' "$sheet" && ! grep -q '| # |' "$sheet" \
  && ok "A: the area: member, note, the copied capture and its first lines; no empty table" \
  || bad "A: sheet: $(cat "$sheet" 2>/dev/null)"
[ "$(cat "$ST_GH/decide" 2>/dev/null)" = 0 ] && ok "A: a sample is no decision row (decide 0)" \
  || bad "A: decide=$(cat "$ST_GH/decide" 2>/dev/null)"
grep -q 'export --epic 100 --repo o/r --session st' "$ST_GH/evidence.log" && ok "A: read through fleet-evidence.sh export" \
  || bad "A: evidence argv: $(cat "$ST_GH/evidence.log")"

# B — no second draw, no second sheet; the day's sample rides a new row's sheet
TICK beat --force >/dev/null 2>&1; TICK beat --force >/dev/null 2>&1
[ "$(nsamp)" = 1 ] && [ "$(sends orchestrator)" = 1 ] && [ "$(grep -c . "$ST_GH/evidence.log")" = 1 ] \
  && ok "B: two more beats — no second draw, no second sheet" \
  || bad "B: samples=$(nsamp) orch=$(sends orchestrator) exports=$(grep -c . "$ST_GH/evidence.log")"
python3 - "$STATE" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["rows"]["r1"] = {"id": "r1", "state": "open", "item": "先发哪个？", "src": "gh:o/r#5", "kind": "normal"}
json.dump(d, open(sys.argv[1], "w"))
EOF
TICK sheet >/dev/null 2>&1
[ "$(grep -c '### 抽样' "$sheet")" = 2 ] && [ "$(sends orchestrator)" = 2 ] && grep -q '| 1 | 先发哪个？' "$sheet" \
  && ok "B: the day's next sheet (a new row) carries the sample again" || bad "B: sheet: $(cat "$sheet")"

# C — no after anywhere: an honest gap
fresh C
printf '21%sbefore%s2026-10-08T01:00:00Z%sb.txt%s前\n22%snone%s%s%s\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T" "$T" > "$ST_GH/ev-200.tsv"
closed 200
TICK beat --force >/dev/null 2>&1
sheet=$(ls "$FLEET_CONF_DIR"/fleets/st/steward/decision-*.md 2>/dev/null | head -1)
grep -q 'o/r#200：2 个成员里没有一个留了改动后证据' "$sheet" && ! grep -q 'b.txt' "$sheet" \
  && ok "C: no after → the sample says so; a before is never shown as one" || bad "C: sheet: $(cat "$sheet" 2>/dev/null)"

# D — seeded by the batch
d1=$(cd "$BIN" && python3 -c 'import fleet_sample as s; r=[(str(m),"after","t","/p%d"%m,"") for m in range(1,9)]; print(s.draw("o/r#7",r)["member"], s.draw("o/r#7",r)["member"])')
set -- $d1
[ "$1" = "$2" ] && ok "D: the same batch draws the same member ($1)" || bad "D: $d1"

# E — an export that cannot run: retried, then given up
fresh E
touch "$ST_GH/ev-fail"; closed 300
for _ in 1 2 3 4; do TICK beat --force >/dev/null 2>&1; done
st=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["samples"]["epics"]["o/r#300"]["state"])' "$STATE")
[ "$(grep -c . "$ST_GH/evidence.log")" = 3 ] && [ "$st" = failed ] && [ "$(sends orchestrator)" = 0 ] \
  && ok "E: three tries, then given up; nothing sent" || bad "E: tries=$(grep -c . "$ST_GH/evidence.log") state=$st"

# F — no sample ⇒ render as before
a=$(cd "$BIN" && python3 fleet_decision.py render --demo)
b=$(cd "$BIN" && python3 -c 'import fleet_decision as fd; print(fd.render(fd.demo_rows(), "demo", None))')
[ "$a" = "$b" ] && case "$a" in *'抽样'*) false ;; *) true ;; esac && ok "F: no samples ⇒ render unchanged" || bad "F: $a"

[ "$fails" = 0 ] && { echo "fleet-steward-sample selftest PASS"; exit 0; }
echo "fleet-steward-sample selftest: $fails FAILED"; exit 1
