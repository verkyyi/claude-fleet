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
#   D. the argv: `status --task T<n>`, `--task T<n> status`, and the ONE word
#      `--task T<n>` zsh makes of `${P:+--task "$P"}` all read the batch.
# Hermetic: a stub hub (FLEET_HUB_CURL), a sandbox FLEET_CONF_DIR, no network.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/epic-deps.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT
N=0 BAD=0
ok()  { N=$((N + 1)); }
bad() { N=$((N + 1)); BAD=$((BAD + 1)); printf 'FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }

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
if path in st:
    out(dict(task=st[path], live=None, pr_state="none"))
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

# --- D. the argv ------------------------------------------------------------------
argv_ok() { python3 "$BIN/fleet-epic-tick.py" "$@" >/dev/null 2>&1; eq "D: argv [$*] reads the batch" 0 "$?"; }
argv_ok status --task T580
argv_ok --task T580 status
argv_ok status "--task T580" --line      # zsh: status ${P:+--task "$P"} --line
argv_ok status --task=T580

printf 'fleet-epic-deps-selftest: %d/%d passed\n' "$((N - BAD))" "$N"
[ "$BAD" -eq 0 ]
