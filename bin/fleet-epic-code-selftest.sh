#!/bin/bash
# fleet-epic-code-selftest.sh — an EPIC batch by the task's code (EPIC T644 C5):
# bin/fleet-epic-tick.py names the parent, its members and the batches it waits on
# by their codes, and a member's redo keeps its code — the same record, the same ID,
# its next attempt (C2) — so the batch waiting on it is released as usual.
#   A. `status --task <code>` (and `#code`, T<n>) reads the batch; `parent` is the
#      code (`parent_task` keeps the T<n>), the line names no T<n>; each member's
#      `code` is its record's; a dependency on another batch written by its code
#      (`YRV3 C5`) or its T<n> (`T20 C6`) waits under that batch's CODE.
#   B. C1 fails (its ID's result, the record written failed): `retry`, and `next`
#      carries `respawn: fleet-task-record.sh respawn <C1's code> --redo` — never a
#      new task; retry_of is the code.
#   C. `fleet-task-record.sh respawn <code> --redo` reopens the failed record (the
#      spawner seam): --task T<n>, its words + 「这是重试」 naming the code; a record
#      that has not failed is refused with --redo, a failed one without it.
#   D. the redo runs (`fleet_id.py attempt`: the same ID's attempt 2) while the
#      record still says failed: C1 is running on the SAME code, one ID, attempt 2,
#      not sent again; C2 (依赖 C1) still waits.
#   E. attempt 2 merges: C1 succeeded on its code, C2 is due — released as usual.
#   F. a member whose second attempt fails too is blocked (one retry).
#   G. the other batch's members merge: the waiting members are due, `outside`
#      says done under the code.
#   H. a code naming two tasks exits 2, never a pick; an unknown --task form is usage.
#   I. the parser: a code prefix scopes the keys after it, `#code` too, this
#      batch's own code (or a prefix of it ≥ 4) is no prefix, a member key is never
#      a code.
# Hermetic: a stub hub (FLEET_HUB_CURL), a sandbox FLEET_CONF_DIR, no tmux, no network.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/epic-code.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT
st_tally count miss
bad() { st_count; st_miss "$1"; }
eq()  { if [ "$2" = "$3" ]; then st_count; else bad "$1: want [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) st_count ;; *) bad "$1: [$3] not in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$3] in [$2]" ;; *) st_count ;; esac; }

mkdir -p "$WORK/conf"
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fixture\n' > "$WORK/conf/node.env"
cat > "$WORK/hub" <<'PY'
#!/usr/bin/env python3
# A stub hub: the node task API resolving a code, a T<n> or a full ID (a prefix
# naming two tasks is the 409 AMBIGUOUS), children, and an empty ID mirror.
import json, os, sys
sys.stdin.read()
url = sys.argv[-1]
st = json.load(open(os.environ["STUB_STATE"]))
def out(obj, code=200):
    print(json.dumps(obj, separators=(",", ":"))); print(code); sys.exit(0)
if url.startswith("https://hub.test/v1/node/ids"):
    from urllib.parse import parse_qs, urlsplit
    out({"parent": parse_qs(urlsplit(url).query).get("parent", [""])[0], "ids": []})
path = url[len("https://hub.test/v1/node/tasks"):].strip("/")
def find(ref):
    if ref in st:
        return [st[ref]]
    up = ref.upper()
    return [t for t in st.values() if t.get("fid") == ref or (len(up) >= 2 and t.get("short", "").startswith(up))]
if path.endswith("/children"):
    got = find(path.split("/")[0])
    p = got[0]["id"] if len(got) == 1 else ""
    out(dict(parent=p, children=[t for t in st.values() if p and t.get("parent_task") == p]))
got = find(path)
if len(got) > 1:
    out({"code": "AMBIGUOUS", "candidates": [dict(short=t["short"], title=t["title"], state="accepted") for t in got]}, 409)
if got:
    out(dict(task=got[0], live=None, pr_state="none"))
out({"error": "no route"}, 404)
PY
chmod +x "$WORK/hub"
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_HUB_CURL="$WORK/hub" \
  STUB_STATE="$WORK/state.json" FLEET_ID_PUSH=0 BIN
unset TMUX TMUX_PANE FLEET_SESSION FLEET_ID_LIVE FLEET_ID_LIVE_CMD FLEET_ID_NOAGENT FLEET_TASK_FID

uid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
jq_() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
mem() { printf '%s' "$S" | jq_ "[m for m in d['members'] if m['key']=='$1'][0]$2"; }
nxt() { printf '%s' "$S" | jq_ '" ".join(n["key"] for n in d["next"])'; }
tick() { python3 "$BIN/fleet-epic-tick.py" status "$@"; }
# setrec <T<n>> <py field dict-expr> — change one record in the stub's table
setrec() { python3 -c 'import json,sys; st=json.load(open(sys.argv[3])); st[sys.argv[1]].update(eval(sys.argv[2])); json.dump(st, open(sys.argv[3],"w"))' "$1" "$2" "$STUB_STATE"; }
# seg <ID> — the ID runs a native segment (an agent came up on it)
seg() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_id
r = fleet_id.fold(fleet_id.read(sys.argv[2]))
fleet_id.append(sys.argv[2], {"ev": "native", "agent": "claude", "native": "S-%s-%d" % (sys.argv[2][:8], len(r["segments"]) + 1),
                              "trigger": "startup", "seg": len(r["segments"]) + 1, "attempt": r["attempt"]})' "$BIN" "$1"; }

PF=$(uid); F1=$(uid); F2=$(uid); F5=$(uid); OF=$(uid)
CHARTER='<!-- fleet:epic repo=o/r short=一号 cap=4 -->
- [ ] **C1** 第一
- [ ] **C2** 第二
- [ ] **C3** 第三
- [ ] **C4** 第四
- [ ] **C5** 第五
## 依赖顺序
| 成员 | 依赖 | 可并行 |
|---|---|---|
| C2 | C1 | |
| C3 | YRV3 C5 合并 | |
| C4 | T20 C6 合并；K5H0 C1 | |
'
python3 - "$STUB_STATE" "$CHARTER" "$PF" "$F1" "$F2" "$F5" "$OF" <<'PY'
import json, sys
path, charter, pf, f1, f2, f5, of = sys.argv[1:]
def t(n, title, **kw):
    return dict(dict(id=n, authority_version=1, generation=1, title=title, outcome="", state="accepted",
                     request_payload=json.dumps({"body": "做 " + title, "repo": "o/r"})), **kw)
st = {
    "T10": t("T10", "EPIC: 一个编号", fid=pf, short="K5H0", worker_id="fleet/" + pf,
             request_payload=json.dumps({"body": charter})),
    "T11": t("T11", "C1 · 第一", parent_task="T10", fid=f1, short="MQ3X", worker_id="fleet/" + f1),
    "T15": t("T15", "C5 · 第五", parent_task="T10", fid=f5, short="PZ4D", worker_id="fleet/" + f5),
    "T20": t("T20", "EPIC: 另一批", fid=of, short="YRV3"),
    "T21": t("T21", "C5 · 外五", parent_task="T20", short="HB2M"),
    "T22": t("T22", "C6 · 外六", parent_task="T20", short="HB3N"),
    "T30": t("T30", "近邻", short="K5ZZ"),
}
json.dump(st, open(path, "w"))
PY
# the ledgers this machine keeps: the driver's ID, C1's and C5's (each up and running)
python3 "$BIN/fleet_id.py" open "$PF" --task T10 --title "EPIC: 一个编号" >/dev/null
for x in "$F1:T11:C1 · 第一" "$F5:T15:C5 · 第五"; do
  IFS=: read -r f t ti <<< "$x"
  python3 "$BIN/fleet_id.py" open "$f" --task "$t" --parent "$PF" --title "$ti" >/dev/null
  seg "$f"
done

# --- A. by the parent's code -------------------------------------------------------
S=$(tick --task K5H0); eq "A: --task <code> reads the batch" 0 $?
eq "A: parent is the code, parent_task the T<n>" "K5H0 T10" "$(printf '%s' "$S" | jq_ 'd["parent"] + " " + d["parent_task"]')"
eq "A: the heartbeat's mark is the code" "K5H0" "$(printf '%s' "$S" | jq_ 'd["mark"]')"
eq "A: each member's code is its record's" "MQ3X PZ4D" "$(printf '%s' "$S" | jq_ '" ".join(m["code"] for m in d["members"] if m.get("code"))')"
eq "A: C1 runs on its code" "running MQ3X" "$(mem C1 '["state"]') $(mem C1 '["code"]')"
eq "A: C3 waits on the other batch by its code" "waiting ['YRV3 C5']" "$(mem C3 '["state"]') $(mem C3 '["waits_on"]')"
eq "A: … written as T<n>, said as the code; this batch's code is no prefix" "waiting ['C1', 'YRV3 C6']" \
  "$(mem C4 '["state"]') $(mem C4 '["waits_on"]')"
eq "A: #code and T<n> read the same batch" "K5H0 K5H0" "$(tick --task '#k5h0' | jq_ 'd["parent"]') $(tick --task T10 | jq_ 'd["parent"]')"
L=$(tick --task K5H0 --line)
has "A: the line names the code" "$L" "K5H0"
hasnt "A: … and no T<n>" "$L" "T1"

# --- B. C1 fails: retry on its own record -----------------------------------------
python3 "$BIN/fleet_id.py" result "$F1" --state failed --summary "门禁红" >/dev/null
setrec T11 '{"outcome": "failed", "state": "failed", "observation": "id_result:x#1"}'
S=$(tick --task K5H0)
eq "B: C1 is a retry" "retry" "$(mem C1 '["state"]')"
eq "B: … restarted on its record, keeping its code" "fleet-task-record.sh respawn MQ3X --redo" \
  "$(printf '%s' "$S" | jq_ '[n for n in d["next"] if n["key"]=="C1"][0]["respawn"]')"
eq "B: retry_of is the code" "MQ3X" "$(printf '%s' "$S" | jq_ '[n for n in d["next"] if n["key"]=="C1"][0]["retry_of"]')"
has "B: the line says the redo" "$(tick --task K5H0 --line)" "C1（MQ3X 重做）"

# --- C. respawn --redo -------------------------------------------------------------
printf '#!/bin/bash\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "%s/spawned"\nfor a in "$@"; do case "$a" in --prompt-file=*) cat "${a#--prompt-file=}" > "%s/prompt" ;; esac; done\n' \
  "$WORK" "$WORK" > "$WORK/spawn"
chmod +x "$WORK/spawn"
FLEET_TASK_RESPAWN="$WORK/spawn" bash "$BIN/fleet-task-record.sh" respawn MQ3X --redo; eq "C: respawn --redo runs" 0 $?
has "C: on the same record" "$(tr '\n' ' ' < "$WORK/spawned")" "--task T11"
has "C: its words" "$(cat "$WORK/prompt")" "做 C1 · 第一"
has "C: … and the redo said, by the code" "$(cat "$WORK/prompt")" "这是重试：同一个任务 MQ3X 的下一次"
FLEET_TASK_RESPAWN="$WORK/spawn" bash "$BIN/fleet-task-record.sh" respawn MQ3X 2>/dev/null
eq "C: a failed record without --redo is refused" 1 $?
FLEET_TASK_RESPAWN="$WORK/spawn" bash "$BIN/fleet-task-record.sh" respawn PZ4D --redo 2>/dev/null
eq "C: --redo on a record that has not failed is refused" 1 $?

# --- D. the redo runs: the same ID, its attempt 2 -----------------------------------
eq "D: the same ID's next attempt" 2 "$(python3 "$BIN/fleet_id.py" attempt "$F1")"
seg "$F1"
S=$(tick --task K5H0)
eq "D: C1 runs again on the SAME code, one ID, attempt 2" "running MQ3X 1 2" \
  "$(mem C1 '["state"]') $(mem C1 '["code"]') $(mem C1 '["ids"].__len__()') $(mem C1 '["attempt"]')"
eq "D: not sent again; C2 still waits on C1" "waiting" "$(mem C2 '["state"]')"
hasnt "D: … C1 not in next" " $(nxt) " " C1 "

# --- E. attempt 2 merges: C2 is released as usual ------------------------------------
python3 "$BIN/fleet_id.py" result "$F1" --state merged --pr 7 >/dev/null
setrec T11 '{"outcome": "succeeded", "state": "succeeded"}'
S=$(tick --task K5H0)
eq "E: C1 succeeded on its code" "succeeded MQ3X" "$(mem C1 '["state"]') $(mem C1 '["code"]')"
has "E: C2 is due" " $(nxt) " " C2 "

# --- F. a second failed attempt is blocked ---------------------------------------------
python3 "$BIN/fleet_id.py" result "$F5" --state failed >/dev/null
setrec T15 '{"outcome": "failed", "state": "failed", "observation": "id_result:y#1"}'
python3 "$BIN/fleet_id.py" attempt "$F5" >/dev/null; seg "$F5"
python3 "$BIN/fleet_id.py" result "$F5" --state failed >/dev/null
S=$(tick --task K5H0)
eq "F: two attempts failed — blocked, never a third" "blocked" "$(mem C5 '["state"]')"

# --- G. the other batch delivers ------------------------------------------------------
setrec T21 '{"outcome": "succeeded"}'; setrec T22 '{"outcome": "succeeded"}'
S=$(tick --task K5H0)
has "G: C3 is due" " $(nxt) " " C3 "
eq "G: outside says done, by the code" "[{'ref': 'YRV3 C5', 'done': True}]" "$(mem C3 '["outside"]')"
has "G: C4 is due (C1 merged, YRV3 C6 merged)" " $(nxt) " " C4 "

# --- H. ambiguity / usage --------------------------------------------------------------
tick --task K5 >/dev/null 2>"$WORK/err"; eq "H: a code naming two tasks exits 2" 2 $?
has "H: … and says so" "$(cat "$WORK/err")" "more than one task"
tick --task 'x y!' >/dev/null 2>&1; eq "H: not a task reference is usage" 2 $?

# --- I. the parser -----------------------------------------------------------------------
refs() { python3 - "$1" <<'PY'
import importlib.util, os, sys
s = importlib.util.spec_from_file_location("t", os.path.join(os.environ["BIN"], "fleet-epic-tick.py"))
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(" ".join(("%s:%s" % (sc, k)) if sc else k for sc, k in m.dep_refs(sys.argv[1], ("T10", "K5H0"))))
PY
}
eq "I: a code scopes the keys after it" "C1 YRV3:C7 YRV3:C8" "$(refs '依赖 C1 + YRV3 C7 C8 合并')"
eq "I: #code too" "YRV3:C5" "$(refs '#YRV3 C5')"
eq "I: this batch's own code is no prefix" "C2" "$(refs 'K5H0 C2')"
eq "I: … nor its T<n>" "C2" "$(refs 'T10 C2')"
eq "I: a member key is never a code" "C12 C3" "$(refs 'C12 C3')"
eq "I: codes and T<n> side by side" "YRV3:C5 T20:C6" "$(refs 'YRV3 C5 / T20 C6')"
eq "I: a word with I L O U is not a code" "C4" "$(refs 'DONE C4')"

st_done
