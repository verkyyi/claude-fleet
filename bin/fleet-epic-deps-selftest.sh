#!/bin/bash
# fleet-epic-deps-selftest.sh — an EPIC's dependencies on ANOTHER batch (T583):
# bin/fleet-epic-tick.py reads `T542 C5` as T542's member C5, never this batch's.
#   A. the parser: bare keys are this batch's, a `T<n>` prefix scopes the keys
#      after it (`T542 C7、C8`, `T542 C5 / T497 C8`), `#<n>` is dropped, this
#      batch's own T<n> as a prefix is the same as none.
#   B. the charter that deadlocked T580 (C4 依赖 T542 C5, C5 依赖 C4 + T497 C8):
#      no C4↔C5 cycle — C4 waits on `T542 C5` only, C5 on C4 and `T497 C8`, and
#      neither is let through by the cycle rule.
#   C. the outside members succeed: C4 is due; C4 merges: C5 is due.
#   E. T580's wave table + section lines (C18): `C1 C4 + T542 C7 C8` holds C6 on
#      both outside members until each merges, then `outside` says they did.
#   F. both halves (T599): a member is due only when its in-batch deps all
#      succeeded AND its outside deps are all done; the cycle rule never lets
#      through one that waits on another batch through an in-batch member.
#   G. a redo, and the ID switch (T622): T542's C5 failed once, its redo merged —
#      the hub's `children` row still says accepted (only the record read projects
#      the window ID's result), so the newest baton's projected succeeded is done.
#   H. T662's shape (T692): the plan's `| 波次 | 成员 | 等谁 | 可并行 |` table — the
#      成员 cell lists several keys, the 等谁 cell several `X ← Y` pairs — holds
#      C3 C4 on C2, C6 on C3, C7 on C5, C8 on C1; a table that yields no key and a
#      section line naming `M1` (not a member key) each warn, in --line too.
#   I. in-flight PR gates (T843): GR5E's `C2 等 C1 + PR #5191 已合` and `C3 等 C2 +
#      PR #5182 #5189 #5192 全部已合` — a member is due only when its members merged
#      AND gh says every PR it names is MERGED (`waits_on` names `PR #5189`); a PR gh
#      cannot read, or closed unmerged, holds it and warns.
#   J. VTBH's table (T851): `| 波次 | 成员 | 等谁 | 可并行 |` whose 等谁 cell says
#      `C1 等操作者…；C2 不等` and `C6 等 C2 C3 C4；C8 等 C2 C3 C5`, and a reserve row
#      `核心全部合并（R2 若…，等 C4）` — no C1↔C2 cycle, wave 1 alone is due, C6 / C8
#      wait on exactly their own keys, the reserves on every core member, never a
#      same-row R; the 可并行 column and a card's 被依赖 are never read.
#   K. SGS6's charter (EDN1): `### 核心` lists C1–C5 AND B1–B4, `### 备选` R1 R2; the
#      wave row `B1 → B2 → B3 · B4 | B1 等 C1 C3 C4` — every B is core (counts, next),
#      B1 waits on C1 C3 C4, B2 on B1, B3 B4 on B2; a child titled `B1 · …` is B1's
#      (running, not unstarted), so C all merged with B open is NOT done; a member
#      whose repo the fleet does not host (moved owner) warns and is not in next.
#   D. the argv: `status --task T<n>`, `--task T<n> status`, and the ONE word
#      `--task T<n>` zsh makes of `${P:+--task "$P"}` all read the batch.
# Hermetic: a stub hub (FLEET_HUB_CURL), a sandbox FLEET_CONF_DIR, no network.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/epic-deps.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT
st_tally
bad() { st_count; st_miss "$1"; }
eq()  { if [ "$2" = "$3" ]; then st_count; else bad "$1: want [$2] got [$3]"; fi; }

mkdir -p "$WORK/conf"
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fixture\n' > "$WORK/conf/node.env"
cat > "$WORK/hub" <<'PY'
#!/usr/bin/env python3
# A stub hub: GET a task and its children off $STUB_STATE; no IDs (an empty family).
import json, os, sys
sys.stdin.read()
url = sys.argv[-1]
st = json.load(open(os.environ["STUB_STATE"]))
def out(obj, code=200):
    print(json.dumps(obj)); print(code); sys.exit(0)
if url.startswith("https://hub.test/v1/node/ids"):
    out({"ids": []})
path = url[len("https://hub.test/v1/node/tasks"):].strip("/")
if path.endswith("/children"):
    p = path.split("/")[0]
    out(dict(parent=p, children=[t for t in st.values() if t.get("parent_task") == p]))
if path in st:  # the record read projects an ID's result (`_got`); children never do
    out(dict(task=dict(st[path], **st[path].get("_got", {})), live=None, pr_state="none"))
out({"error": "no route"}, 404)
PY
chmod +x "$WORK/hub"
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_HUB_CURL="$WORK/hub" \
  STUB_STATE="$WORK/state.json" FLEET_ID_PUSH=0
unset TMUX TMUX_PANE FLEET_SESSION

# state <py dict-expr> — the stub hub's task table
state() { python3 -c 'import json,sys; json.dump(eval(sys.argv[1]), open(sys.argv[2],"w"))' "$1" "$STUB_STATE"; }
jq_() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
tick() { python3 "$BIN/fleet-epic-tick.py" status --task T580; }
mem() { printf '%s' "$S" | jq_ "[m for m in d['members'] if m['key']=='$1'][0]$2"; }

# --- A. the parser ---------------------------------------------------------------
refs() { python3 - "$1" <<'PY'
import importlib.util, os, sys
s = importlib.util.spec_from_file_location("t", os.path.join(os.environ["BIN"], "fleet-epic-tick.py"))
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(" ".join(("%s:%s" % (sc, k)) if sc else k for sc, k in m.dep_refs(sys.argv[1], "T580")))
PY
}
export BIN
eq "A: bare keys are this batch's, T<n> scopes the rest" "C1 C4 T542:C7 T542:C8" "$(refs '依赖 C1 C4 + T542 C7 C8 合并')"
eq "A: two outside batches" "T542:C5 T497:C8" "$(refs 'T542 C5 / T497 C8')"
eq "A: a range behind a prefix" "T542:C1 T542:C2 T542:C3" "$(refs 'T542 C1–C3')"
eq "A: other words end the scope" "T542:C5 C4" "$(refs '依赖 T542 C5；C4')"
eq "A: a ticket's keys are its own" "#12:C3" "$(refs '#12 C3')"
eq "A: this batch's own T<n> is no prefix" "C2" "$(refs 'T580 C2')"

# --- B. the charter that deadlocked ----------------------------------------------
CHARTER='<!-- fleet:epic repo=o/r short=同路 cap=4 -->
- [ ] **C4** 第四
- [ ] **C5** 第五
## 依赖顺序
| 成员 | 依赖 | 可并行 |
|---|---|---|
| C4 | T542 C5 合并 | |
| C5 | 依赖 C4 + T497 C8 合并 | |
'
PARENT=$(python3 -c 'import json,sys; print(json.dumps(dict(id="T580", authority_version=1, title="EPIC", request_payload=json.dumps({"body": sys.argv[1]}))))' "$CHARTER")
outside() { # outside <T542 C5 outcome> <T497 C8 outcome> [<C4 outcome>]
  state "({'T580': $PARENT,
   'T600': dict(id='T600', parent_task='T542', title='C5 · 外批五', outcome='$1'),
   'T601': dict(id='T601', parent_task='T497', title='C8 · 外批八', outcome='$2'),
   'T602': dict(id='T602', parent_task='T542', title='C4 · 外批四', outcome='succeeded')}
   | ({'T610': dict(id='T610', parent_task='T580', title='C4 · 第四', outcome='${3-}')} if '${3-}' else {}))"
}
outside "" ""
S=$(tick)
eq "B: C4 waits on T542's C5 only" "waiting ['T542 C5']" "$(mem C4 '["state"]') $(mem C4 '["waits_on"]')"
eq "B: C5 waits on C4 and T497's C8, not on itself" "waiting ['C4', 'T497 C8']" "$(mem C5 '["state"]') $(mem C5 '["waits_on"]')"
eq "B: no cycle let through — nothing due" "0 False" "$(printf '%s' "$S" | jq_ 'len(d["next"])') $(mem C4 '.get("cycle", False)')"
eq "B: another batch's C4 (T542) is not this batch's C4" "waiting" "$(mem C4 '["state"]')"

# --- C. the outside batches deliver ----------------------------------------------
outside succeeded ""
S=$(tick)
eq "C: T542 C5 merged — C4 is due" "C4" "$(printf '%s' "$S" | jq_ '" ".join(n["key"] for n in d["next"])')"
eq "C: C5 still waits on both" "['C4', 'T497 C8']" "$(mem C5 '["waits_on"]')"
outside succeeded succeeded succeeded
S=$(tick)
eq "C: C4 merged, T497 C8 merged — C5 is due" "succeeded C5" "$(mem C4 '["state"]') $(printf '%s' "$S" | jq_ '" ".join(n["key"] for n in d["next"])')"

# --- E. T580's own shape (C18): a 波次 table the parser cannot key, so each
# section's **依赖** line — `C1 C4 + T542 C7 C8` — puts both outside members in
# waits_on until T542's C7 and C8 merge; once merged they leave waits_on and the
# member's `outside` says so (never silently gone)
CHARTER='<!-- fleet:epic repo=o/r short=同路 cap=4 -->
- [ ] **C4** 第四
- [ ] **C6** 第六
## 依赖顺序
| 波次 | 成员 | 等谁 |
|---|---|---|
| 3 | C5 · C6（并行） | C6←C4 + **T542 C7 C8 合并** |
## C4 · 第四
**依赖** 依赖 无 · 被依赖 C6
## C6 · 第六
**依赖** 依赖 C4 + T542 C7 C8 合并 · 被依赖 C7
'
PARENT=$(python3 -c 'import json,sys; print(json.dumps(dict(id="T580", authority_version=1, title="EPIC", request_payload=json.dumps({"body": sys.argv[1]}))))' "$CHARTER")
far() { state "({'T580': $PARENT,
   'T545': dict(id='T545', parent_task='T542', title='C7 · 外批七', outcome='$1'),
   'T548': dict(id='T548', parent_task='T542', title='C8 · 外批八', outcome='$2')})"; }
far "" ""
S=$(tick)
eq "E: C6 waits on C4 and T542's C7 C8" "waiting ['C4', 'T542 C7', 'T542 C8']" "$(mem C6 '["state"]') $(mem C6 '["waits_on"]')"
far succeeded ""
S=$(tick)
eq "E: C7 merged — only C8 of T542 still held" "['C4', 'T542 C8']" "$(mem C6 '["waits_on"]')"
far succeeded succeeded
S=$(tick)
eq "E: both merged — waits_on is C4 alone" "['C4']" "$(mem C6 '["waits_on"]')"
eq "E: and outside says they merged" "T542 C7:True T542 C8:True" "$(mem C6 '["outside"]' | python3 -c 'import ast,sys; print(" ".join("%s:%s" % (o["ref"], o["done"]) for o in ast.literal_eval(sys.stdin.read())))')"

# --- F. both halves (T599): in-batch deps must all succeed AND outside deps all
# be done. T580's regression: C4 waits on T542 C5, C6 on C4 + T542 C7 C8 (done)
# — nothing live, and the cycle rule let C6 through while C4 had not started.
CHARTER='<!-- fleet:epic repo=o/r short=同路 cap=4 -->
- [ ] **C4** 第四
- [ ] **C6** 第六
- [ ] **C7** 第七
- [ ] **C8** 第八
## C4 · 第四
**依赖** 依赖 T542 C5 合并 · 被依赖 C6
## C6 · 第六
**依赖** 依赖 C4 + T542 C7 C8 合并
## C7 · 第七
**依赖** 依赖 T542 C9 合并
## C8 · 第八
**依赖** 依赖 C4
'
PARENT=$(python3 -c 'import json,sys; print(json.dumps(dict(id="T580", authority_version=1, title="EPIC", request_payload=json.dumps({"body": sys.argv[1]}))))' "$CHARTER")
both() { # both <T542 C5> <T542 C9> [<C4 outcome>]
  state "({'T580': $PARENT,
   'T600': dict(id='T600', parent_task='T542', title='C5 · 外批五', outcome='$1'),
   'T605': dict(id='T605', parent_task='T542', title='C7 · 外批七', outcome='succeeded'),
   'T606': dict(id='T606', parent_task='T542', title='C8 · 外批八', outcome='succeeded'),
   'T609': dict(id='T609', parent_task='T542', title='C9 · 外批九', outcome='$2')}
   | ({'T610': dict(id='T610', parent_task='T580', title='C4 · 第四', outcome='${3-}')} if '${3-}' else {}))"
}
due() { printf '%s' "$S" | jq_ '" ".join(n["key"] for n in d["next"])'; }
both "" ""
S=$(tick)
eq "F: in-batch C4 not succeeded + outside done ⇒ C6 waits on C4" "waiting ['C4'] False" "$(mem C6 '["state"]') $(mem C6 '["waits_on"]') $(mem C6 '.get("cycle", False)')"
eq "F: outside only, not done ⇒ C7 waits" "waiting ['T542 C9']" "$(mem C7 '["state"]') $(mem C7 '["waits_on"]')"
eq "F: in-batch only, C4 not succeeded ⇒ C8 waits" "waiting ['C4']" "$(mem C8 '["state"]') $(mem C8 '["waits_on"]')"
eq "F: nothing due while every member is held" "" "$(due)"
both succeeded succeeded
S=$(tick)
eq "F: outside done ⇒ C4 and C7 due; C6 C8 still wait on C4" "C4 C7 waiting waiting" "$(due) $(mem C6 '["state"]') $(mem C8 '["state"]')"
both succeeded "" running
S=$(tick)
eq "F: C4 running ⇒ C6 not due" "waiting ['C4']" "$(mem C6 '["state"]') $(mem C6 '["waits_on"]')"
both succeeded succeeded succeeded
S=$(tick)
eq "F: inside and outside both met ⇒ C6 and C8 due" "C6 C8" "$(due | tr ' ' '\n' | grep -E '^C[68]$' | tr '\n' ' ' | sed 's/ $//')"

# --- G. a redo the ID switch closed (T622) ------------------------------------------
redo() { # redo <T542 C5 redo's projected outcome>
  state "({'T580': $PARENT,
   'T600': dict(id='T600', parent_task='T542', title='C5 · 外批五', outcome='failed', state='failed'),
   'T603': dict(id='T603', parent_task='T542', title='C5 · 外批五', outcome='', state='accepted',
                _got=dict(outcome='$1', state='$1' or 'accepted')),
   'T605': dict(id='T605', parent_task='T542', title='C7 · 外批七', outcome='succeeded'),
   'T606': dict(id='T606', parent_task='T542', title='C8 · 外批八', outcome='succeeded'),
   'T609': dict(id='T609', parent_task='T542', title='C9 · 外批九', outcome='succeeded')})"
}
redo ""
S=$(tick)
eq "G: redo still open ⇒ T542 C5 not done, C4 waits" "waiting T542 C5:False" "$(mem C4 '["state"]') $(mem C4 '["outside"]' | python3 -c 'import ast,sys; print(" ".join("%s:%s" % (o["ref"], o["done"]) for o in ast.literal_eval(sys.stdin.read())))')"
redo succeeded
S=$(tick)
eq "G: redo succeeded (record read only) ⇒ T542 C5 done, C4 due" "T542 C5:True C4 C7" "$(mem C4 '["outside"]' | python3 -c 'import ast,sys; print(" ".join("%s:%s" % (o["ref"], o["done"]) for o in ast.literal_eval(sys.stdin.read())))') $(due)"

# --- H. T662's wave table (T692) ---------------------------------------------------
CHARTER='<!-- fleet:epic repo=o/r short=减法 cap=8 -->
- [ ] **C1** 一
- [ ] **C2** 二
- [ ] **C3** 三
- [ ] **C4** 四
- [ ] **C5** 五
- [ ] **C6** 六
- [ ] **C7** 七
- [ ] **C8** 八
## 依赖顺序
| 波次 | 成员 | 等谁 | 可并行 |
|---|---|---|---|
| 1 | C1 C2 C5 | — | 三个并行 |
| 2 | C3 C4 C7 C8 | C3 ← C2；C4 ← C2；C7 ← C5；C8 ← C1 | 四个并行 |
| 3 | C6 | C3 | 单独 |
## C3 · 三
**依赖** 依赖 M2 · 被依赖 M6
'
PARENT=$(python3 -c 'import json,sys; print(json.dumps(dict(id="T580", authority_version=1, title="EPIC", request_payload=json.dumps({"body": sys.argv[1]}))))' "$CHARTER")
state "({'T580': $PARENT})"
S=$(tick)
eq "H: wave 1 is due, nothing else" "C1 C2 C5" "$(due)"
eq "H: C3 C4 wait on C2" "['C2'] ['C2']" "$(mem C3 '["waits_on"]') $(mem C4 '["waits_on"]')"
eq "H: C6 on C3, C7 on C5, C8 on C1" "['C3'] ['C5'] ['C1']" "$(mem C6 '["waits_on"]') $(mem C7 '["waits_on"]') $(mem C8 '["waits_on"]')"
eq "H: a table that reads warns nothing" "[]" "$(printf '%s' "$S" | jq_ 'd["warnings"]')"
CHARTER='<!-- fleet:epic repo=o/r short=减法 cap=8 -->
- [ ] **C1** 一
- [ ] **C2** 二
## 依赖顺序
| 波次 | 成员 | 等谁 |
|---|---|---|
| 1 | M1 | — |
| 2 | M2 | M1 |
## C2 · 二
**依赖** 依赖 M1 · 被依赖 无
'
PARENT=$(python3 -c 'import json,sys; print(json.dumps(dict(id="T580", authority_version=1, title="EPIC", request_payload=json.dumps({"body": sys.argv[1]}))))' "$CHARTER")
state "({'T580': $PARENT})"
S=$(tick)
eq "H: an unreadable table and an M-line each warn" "2" "$(printf '%s' "$S" | jq_ 'len(d["warnings"])')"
eq "H: the M-line warning names C2" "True" "$(printf '%s' "$S" | jq_ 'any(w.startswith("C2 ") for w in d["warnings"])')"
L=$(python3 "$BIN/fleet-epic-tick.py" status --task T580 --line)
case "$L" in *"⚠ 依赖顺序表有 2 行"*) st_count ;; *) bad "H: --line carries the warning: $L" ;; esac

# --- I. in-flight PR gates (T843) --------------------------------------------------
cat > "$WORK/gh" <<'SH'
#!/bin/sh
# a stub gh: `gh pr view <n> -R <repo> --json state -q .state` off $STUB_PRS (n=STATE lines)
[ "$1 $2" = "pr view" ] || exit 1
echo "$*" >> "$STUB_PRS.calls"
st=$(sed -n "s/^$3=//p" "$STUB_PRS")
[ -n "$st" ] || { echo "no such PR" >&2; exit 1; }
echo "$st"
SH
chmod +x "$WORK/gh"
export FLEET_EPIC_TICK_GH="$WORK/gh" STUB_PRS="$WORK/prs"
CHARTER='<!-- fleet:epic repo=o/r short=网页 cap=4 -->
- [ ] **C1** 一
- [ ] **C2** 二
- [ ] **C3** 三
- [ ] **C4** 四
## 依赖顺序
| 成员 | 依赖 |
|---|---|
| C2 | C1 + PR #5191 已合 |
| C3 | C2 + PR #5182 #5189、#5192 全部已合 |
## C4 · 四
**依赖** 依赖 PR #77 已合
'
PARENT=$(python3 -c 'import json,sys; print(json.dumps(dict(id="T580", authority_version=1, title="EPIC", request_payload=json.dumps({"body": sys.argv[1]}))))' "$CHARTER")
gates() { # gates <C1 outcome> <C2 outcome>
  state "({'T580': $PARENT}
   | ({'T611': dict(id='T611', parent_task='T580', title='C1 · 一', outcome='$1')} if '$1' else {})
   | ({'T612': dict(id='T612', parent_task='T580', title='C2 · 二', outcome='$2')} if '$2' else {}))"
}
prs() { python3 -c '
import importlib.util, os, sys
s = importlib.util.spec_from_file_location("t", os.path.join(os.environ["BIN"], "fleet-epic-tick.py"))
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.pr_refs(sys.argv[1]))' "$1"; }
eq "I: every #<n> right after PR" "[5182, 5189, 5192]" "$(prs 'C2 + PR #5182 #5189、#5192 全部已合')"
eq "I: a bare ticket is no PR gate" "[]" "$(prs '依赖 #12 C3')"
eq "I: PR#77 glued" "[77]" "$(prs '依赖 PR#77')"
in_due() { due | tr ' ' '\n' | grep -x "$1"; }
printf '5191=OPEN\n5182=MERGED\n5189=OPEN\n5192=MERGED\n77=MERGED\n' > "$STUB_PRS"
gates "" ""
S=$(tick)
eq "I: C1 and C4 (its PR merged) due" "C1 C4" "$(due)"
eq "I: C2 waits on C1 and PR #5191" "waiting ['C1', 'PR #5191']" "$(mem C2 '["state"]') $(mem C2 '["waits_on"]')"
eq "I: every PR reads, no warning" "[]" "$(printf '%s' "$S" | jq_ 'd["warnings"]')"
grep -q -- '-R o/r' "$STUB_PRS.calls"; eq "I: gh asked in the charter's repo" 0 "$?"
gates succeeded ""
S=$(tick)
eq "I: C1 merged, PR #5191 open ⇒ C2 waits on the PR alone" "waiting ['PR #5191']" "$(mem C2 '["state"]') $(mem C2 '["waits_on"]')"
printf '5191=MERGED\n5182=MERGED\n5189=OPEN\n5192=MERGED\n77=MERGED\n' > "$STUB_PRS"
gates succeeded succeeded
S=$(tick)
eq "I: C2 merged, #5189 open ⇒ C3 waits on PR #5189 (GR5E's case)" "waiting ['PR #5189'] False" "$(mem C3 '["state"]') $(mem C3 '["waits_on"]') $(mem C3 '.get("cycle", False)')"
eq "I: the cycle rule never lets a PR gate through" "" "$(in_due C3)"
printf '5191=MERGED\n5182=MERGED\n5189=MERGED\n5192=MERGED\n77=MERGED\n' > "$STUB_PRS"
S=$(tick)
eq "I: every PR merged ⇒ C3 due" "C3" "$(in_due C3)"
printf '5182=MERGED\n5189=CLOSED\n5192=MERGED\n' > "$STUB_PRS"
S=$(tick)
eq "I: closed unmerged and unreadable both hold" "waiting ['PR #5189'] waiting ['PR #77']" "$(mem C3 '["state"]') $(mem C3 '["waits_on"]') $(mem C4 '["state"]') $(mem C4 '["waits_on"]')"
eq "I: and both warn" "True True" "$(printf '%s' "$S" | jq_ 'str(any("PR #5189 已关闭" in w for w in d["warnings"])) + " " + str(any("PR #77 读不出" in w for w in d["warnings"]))')"
L=$(python3 "$BIN/fleet-epic-tick.py" status --task T580 --line)
case "$L" in *"⚠ C4 等的 PR #77 读不出状态"*) st_count ;; *) bad "I: --line carries the PR warning: $L" ;; esac
unset FLEET_EPIC_TICK_GH

# --- J. VTBH's table (T851) -------------------------------------------------------
CHARTER='<!-- fleet:epic repo=o/r short=域名 cap=8 -->
- [ ] **C1** 一
- [ ] **C2** 二
- [ ] **C3** 三
- [ ] **C4** 四
- [ ] **C5** 五
- [ ] **C6** 六
- [ ] **C7** 七
- [ ] **C8** 八
  - [ ] **R1** 甲
  - [ ] **R2** 乙
  - [ ] **R3** 丙
  - [ ] **R4** 丁
## 依赖顺序
| 波次 | 成员 | 等谁 | 可并行 |
|---|---|---|---|
| 1 | C1 C2 | C1 等操作者给测试网址（ask 挂起）；C2 不等 | 两个并行；C1 不通即停，回报 |
| 2 | C3 C4 C5 | C1 C2 | 三个并行 |
| 3 | C6 C8 | C6 等 C2 C3 C4；C8 等 C2 C3 C5 | 两个并行 |
| 4 | C7 | C2 C5 C6 | 单独 |
| 储备 | R1 R2 R3 R4 | 核心全部合并（R2 若拍板第 2 条改选「海外跳转」则升为核心，等 C4） | 互相独立 |

## C1 · 一
**依赖** 依赖 无（要操作者给测试网址：开工即 ask 挂起）· 被依赖 C3 C4 C5（C2 补状态映射）
## C3 · 三
**依赖** 依赖 C1 C2 · 被依赖 C6 C8
'
PARENT=$(python3 -c 'import json,sys; print(json.dumps(dict(id="T580", authority_version=1, title="EPIC", request_payload=json.dumps({"body": sys.argv[1]}))))' "$CHARTER")
state "({'T580': $PARENT})"
S=$(tick)
eq "J: wave 1 alone is due (no C1↔C2 cycle)" "C1 C2" "$(due)"
eq "J: C1 C2 wait on nothing" "None None" "$(mem C1 '.get("waits_on")') $(mem C2 '.get("waits_on")')"
eq "J: C3 C4 C5 on C1 C2" "['C1', 'C2'] ['C1', 'C2'] ['C1', 'C2']" "$(mem C3 '["waits_on"]') $(mem C4 '["waits_on"]') $(mem C5 '["waits_on"]')"
eq "J: C6 on C2 C3 C4, C8 on C2 C3 C5" "['C2', 'C3', 'C4'] ['C2', 'C3', 'C5']" "$(mem C6 '["waits_on"]') $(mem C8 '["waits_on"]')"
eq "J: C7 on C2 C5 C6" "['C2', 'C5', 'C6']" "$(mem C7 '["waits_on"]')"
for r in R1 R3 R4; do
  eq "J: $r on every core member, never R2" "['C1', 'C2', 'C3', 'C4', 'C5', 'C6', 'C7', 'C8']" "$(mem $r '["waits_on"]')"
done
eq "J: nothing marked a cycle" "False" "$(printf '%s' "$S" | jq_ 'any(m.get("cycle") for m in d["members"])')"
eq "J: the table reads, no warning" "[]" "$(printf '%s' "$S" | jq_ 'd["warnings"]')"
row_c3() { python3 -c '
import importlib.util, os, sys
s = importlib.util.spec_from_file_location("t", os.path.join(os.environ["BIN"], "fleet-epic-tick.py"))
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
out = {}
m.dep_table_row(["3", "C3", sys.argv[1]], (1, 2), {"C1", "C2", "C3"}, lambda k, c: out.setdefault(k, c))
print([k for sc, k in m.dep_refs(out["C3"])])' "$1"; }
eq "J: \`C1 C2 等全部合并\` in another row is a whole-cell wait" "['C1', 'C2']" "$(row_c3 'C1 C2 等全部合并')"

# --- K. SGS6's B<k> members (EDN1) ----------------------------------------------
CHARTER='<!-- fleet:epic repo=o/r short=官网 cap=8 -->
## 成员
### 核心 — definition of done
- [ ] **C1** 一
- [ ] **C3** 三
- [ ] **C4** 四
- [ ] **C5** old/mono — 五
- [ ] **B1** 改名一
- [ ] **B2** 改名二
- [ ] **B3** 改名三
- [ ] **B4** old/mono — 改名四
### 备选 — dispatched only when added
- [ ] **R1** 甲
## 依赖顺序
| 波次 | 成员 | 等谁 | 可并行 |
|---|---|---|---|
| 1 | C1 C4 C5 | — | 三个并行 |
| 2 | C3 | C1 | — |
| 改名 | B1 → B2 → B3 · B4 | B1 等 C1 C3 C4 | B3 B4 并行 |
| 储备 | R1 | R1 等 C1 C3 | — |
'
PARENT=$(python3 -c 'import json,sys; print(json.dumps(dict(id="T580", authority_version=1, title="EPIC", request_payload=json.dumps({"body": sys.argv[1]}))))' "$CHARTER")
kids() { # kids <py dict-expr of extra children>
  state "({'T580': $PARENT} | $1)"; }
export FLEET_EPIC_TICK_REPOS="o/r new/mono"
kids "{}"
S=$(tick)
eq "K: B1–B4 are core (counts.core 8)" "8" "$(printf '%s' "$S" | jq_ 'd["counts"]["core"]')"
eq "K: layers off the headings" "core core reserve" "$(mem B1 '["layer"]') $(mem C1 '["layer"]') $(mem R1 '["layer"]')"
eq "K: B1 waits on C1 C3 C4" "['C1', 'C3', 'C4']" "$(mem B1 '["waits_on"]')"
eq "K: B2 on B1, B3 B4 on B2" "['B1'] ['B2'] ['B2']" "$(mem B2 '["waits_on"]') $(mem B3 '["waits_on"]') $(mem B4 '["waits_on"]')"
eq "K: C5 in a repo not hosted is not due" "C1 C4" "$(due)"
eq "K: and says so, naming the hosted one" "True" "$(printf '%s' "$S" | jq_ 'any(w.startswith("C5 的仓库 old/mono") and "new/mono" in w for w in d["warnings"])')"
eq "K: unhosted lists it" "{'C5': 'old/mono', 'B4': 'old/mono'}" "$(printf '%s' "$S" | jq_ 'd["unhosted"]')"
done_kids="{'T611': dict(id='T611', parent_task='T580', title='C1 · 一', outcome='succeeded'),
  'T612': dict(id='T612', parent_task='T580', title='C3 · 三', outcome='succeeded'),
  'T613': dict(id='T613', parent_task='T580', title='C4 · 四', outcome='succeeded'),
  'T614': dict(id='T614', parent_task='T580', title='C5 · 五', outcome='succeeded')}"
kids "$done_kids"
S=$(tick)
eq "K: C all merged ⇒ B1 due, batch not done" "B1 False" "$(due) $(printf '%s' "$S" | jq_ 'd["done"]')"
kids "$done_kids | {'T615': dict(id='T615', parent_task='T580', title='B1 · 改名一', outcome='')}"
S=$(tick)
eq "K: a child titled B1 · … is B1's, running" "running 1" "$(mem B1 '["state"]') $(printf '%s' "$S" | jq_ 'd["counts"]["running"]')"
eq "K: nothing due while B1 runs" "" "$(due)"
eq "K: --line never says 核心空了" "" "$(python3 "$BIN/fleet-epic-tick.py" status --task T580 --line | grep -o '核心空了')"
unset FLEET_EPIC_TICK_REPOS

# --- D. the argv ------------------------------------------------------------------
argv_ok() { python3 "$BIN/fleet-epic-tick.py" "$@" >/dev/null 2>&1; eq "D: argv [$*] reads the batch" 0 "$?"; }
argv_ok status --task T580
argv_ok --task T580 status
argv_ok status "--task T580" --line      # zsh: status ${P:+--task "$P"} --line
argv_ok status --task=T580

printf 'fleet-epic-deps-selftest: %d/%d passed\n' "$((CHECKS - FAIL))" "$CHECKS"
st_done
