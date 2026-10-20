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

# --- D. the argv ------------------------------------------------------------------
argv_ok() { python3 "$BIN/fleet-epic-tick.py" "$@" >/dev/null 2>&1; eq "D: argv [$*] reads the batch" 0 "$?"; }
argv_ok status --task T580
argv_ok --task T580 status
argv_ok status "--task T580" --line      # zsh: status ${P:+--task "$P"} --line
argv_ok status --task=T580

printf 'fleet-epic-deps-selftest: %d/%d passed\n' "$((CHECKS - FAIL))" "$CHECKS"
st_done
