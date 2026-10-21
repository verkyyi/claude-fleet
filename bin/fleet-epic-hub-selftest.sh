#!/bin/bash
# fleet-epic-hub-selftest.sh — an EPIC runs on hub tasks alone (issue #4957):
# plan → run (two members: one lands, one fails twice) → report, with every
# GitHub road denied.
#
# What /fleet-epic-plan, /fleet-epic-run and /fleet-epic-report call, end to end,
# against a stub hub (FLEET_HUB_CURL — the node's one HTTP road) that keeps its
# task records in a file:
#   A. plan: the charter goes out as the parent task's body (fleet-task-record.sh
#      dispatch — the `task` tool's script); fleet-epic-tick.py reads it back:
#      two core members, a reserve that is never dispatched, both core members
#      due, the cap honoured.
#   B. run: each `next` item is dispatched as a child task (`C<k> · <title>`, its
#      repo, the hub binding parent_task); the next tick has nothing to send and
#      two running.
#   C. C1 succeeds with its PR, C2 fails: the tick sends C2 once more (the retry
#      rule), and a member added within scope (a `C9 · …` child) counts.
#   D. C2's retry fails too: C2 is blocked, the batch is done; the report's read
#      carries C1's PR and C2's state; the heartbeat stamps and clears `T<n>`.
#   E. gh and curl were never run; every request went to the stub hub.
#   F. the local files a charter names (~/fleet-drafts/…) ride the parent's
#      record and reach each member's body on another machine (T793,
#      fleet_local_refs.py); one nobody carried is warned.
# Hermetic: a sandbox FLEET_CONF_DIR, no tmux, no network.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/epic-hub.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT
N=0 BAD=0
ok()  { N=$((N + 1)); }
bad() { N=$((N + 1)); BAD=$((BAD + 1)); printf 'FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$3] not in [$2]" ;; esac; }

mkdir -p "$WORK/conf" "$WORK/path"
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fixture\n' > "$WORK/conf/node.env"
for tool in gh curl; do
  printf '#!/bin/sh\necho "$0 $*" >> "%s/denied"\nexit 91\n' "$WORK" > "$WORK/path/$tool"
  chmod +x "$WORK/path/$tool"
done
cat > "$WORK/hub" <<'PY'
#!/usr/bin/env python3
# A stub hub: the node task API's few roads, records in $STUB_STATE.
import json, os, sys
sys.stdin.read()
args = sys.argv[1:]
url = args[-1]
meth = args[args.index("-X") + 1] if "-X" in args else "GET"
body = args[args.index("--data-binary") + 1] if "--data-binary" in args else ""
with open(os.environ["CALL_LOG"], "a") as f:
    f.write("%s %s\n" % (meth, url))
if not url.startswith("https://hub.test/v1/node/tasks"):
    print("{}"); print("404"); sys.exit(0)
path = url[len("https://hub.test/v1/node/tasks"):].strip("/")
st = json.load(open(os.environ["STUB_STATE"])) if os.path.exists(os.environ["STUB_STATE"]) else {"tasks": {}}
def save():
    json.dump(st, open(os.environ["STUB_STATE"], "w"))
def out(obj, code=200):
    print(json.dumps(obj)); print(code); sys.exit(0)
if meth == "POST" and path == "":
    req = json.loads(body)
    for t in st["tasks"].values():
        if t["_token"] == req["token"]:
            out(t)
    n = "T%d" % (len(st["tasks"]) + 1)
    parent = req.get("parent_task") or os.environ.get("STUB_PARENT", "")
    t = dict(id=n, authority_version=1, generation=1, attempt_id="a-" + n, title=req["title"], repo=req.get("repo", ""),
             requested_agent=req["requested_agent"], resolved_agent=req["resolved_agent"], parent_task=parent,
             execution_owner="fleet/" + n, outcome="", state="running",
             request_payload=json.dumps(req.get("request_payload") or {}), _token=req["token"])
    st["tasks"][n] = t; save(); out(t)
if meth == "GET" and path.endswith("/children"):
    p = path.split("/")[0]
    kids = [t for t in st["tasks"].values() if t.get("parent_task") == p]
    out(dict(parent=p, parent_session="fleet/" + p, parent_generation=1, children=kids))
if meth == "GET" and path in st["tasks"]:
    t = st["tasks"][path]
    out(dict(task=t, live=None, pr_state="none", **({"progress": t["_progress"]} if t.get("_progress") else {})))
out({"error": "no route"}, 404)
PY
chmod +x "$WORK/hub"
export PATH="$WORK/path:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_HUB_CURL="$WORK/hub" \
  CALL_LOG="$WORK/calls" STUB_STATE="$WORK/state.json" FLEET_AGENT=claude
unset TMUX TMUX_PANE FLEET_SESSION FLEET_LAUNCH_CONTEXT STUB_PARENT

# set_outcome T<n> <outcome> [pr] — the child's session reported (its report tool).
set_outcome() {
  python3 - "$1" "$2" "${3:-}" <<'PY'
import json, os, sys
st = json.load(open(os.environ["STUB_STATE"]))
t = st["tasks"][sys.argv[1]]
t.update(outcome=sys.argv[2], state=sys.argv[2], evidence=json.dumps(dict(pr=sys.argv[3], work_result=sys.argv[2])))
json.dump(st, open(os.environ["STUB_STATE"], "w"))
PY
}
tick() { python3 "$BIN/fleet-epic-tick.py" status --task "$P" "$@"; }
jq_() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
# dispatch_next — what the driver does with each `next` item: the task tool.
dispatch_next() {
  local js="$1" i n
  n=$(printf '%s' "$js" | jq_ 'len(d["next"])')
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '%s' "$js" | jq_ "d['next'][$i]['body']" > "$WORK/body"
    STUB_PARENT="$P" bash "$BIN/fleet-task-record.sh" dispatch --title "$(printf '%s' "$js" | jq_ "d['next'][$i]['title']")" \
      --repo "$(printf '%s' "$js" | jq_ "d['next'][$i]['repo']")" --body-file "$WORK/body" >/dev/null || bad "dispatch item $i"
    i=$((i + 1))
  done
}

# --- A. plan: the charter is the parent task's body -------------------------------
cat > "$WORK/charter" <<'EOF'
/fleet-epic-run

<!-- fleet:epic repo=o/r short=演示 cap=4 -->
# EPIC: 演示批次

## 成员
- [ ] **C1** 加一个开关
- [ ] **C2** o/other — 改一处文案 (codex)
- [ ] **R1** 备选：顺手清理

## C1 · 加一个开关
开关叫 demo，默认关。
EOF
P=$(bash "$BIN/fleet-task-record.sh" dispatch --title "EPIC: 演示批次" --body-file "$WORK/charter"); RC=$?
eq "A: the parent task is accepted" 0 "$RC"
eq "A: it is T1" T1 "$P"
S=$(tick); RC=$?
eq "A: the tick reads the batch" 0 "$RC"
eq "A: two core members" 2 "$(printf '%s' "$S" | jq_ 'd["counts"]["core"]')"
eq "A: both core members are due, never the reserve" "C1 C2" "$(printf '%s' "$S" | jq_ '" ".join(n["key"] for n in d["next"])')"
eq "A: the member's own repo and agent" "o/other codex" "$(printf '%s' "$S" | jq_ 'd["next"][1]["repo"]+" "+d["next"][1]["agent"]')"
has "A: the member's detail travels in its body" "$(printf '%s' "$S" | jq_ 'd["next"][0]["body"]')" "开关叫 demo"
eq "A: the cap limits the dispatch" "C1" "$(tick --cap 1 | jq_ '" ".join(n["key"] for n in d["next"])')"
eq "A: the short name" "演示" "$(printf '%s' "$S" | jq_ 'd["short"]')"

# --- B. run: dispatch the children ------------------------------------------------
dispatch_next "$S"
S=$(tick)
eq "B: two children running" 2 "$(printf '%s' "$S" | jq_ 'd["running"]')"
eq "B: nothing more to send" 0 "$(printf '%s' "$S" | jq_ 'len(d["next"])')"
eq "B: C1 is T2, C2 is T3" "T2 T3" "$(printf '%s' "$S" | jq_ '" ".join(m["task"] for m in d["members"] if m["layer"]=="core")')"
eq "B: the child is titled with its key" "C2 · 改一处文案" "$(python3 -c 'import json,os; print(json.load(open(os.environ["STUB_STATE"]))["tasks"]["T3"]["title"])')"
has "B: the line says it" "$(tick --line)" "在跑 2"

# --- C. one lands, one fails: the retry rule ----------------------------------------
set_outcome T2 succeeded 101
set_outcome T3 failed
S=$(tick)
eq "C: C1 succeeded with its PR" "succeeded 101" "$(printf '%s' "$S" | jq_ 'd["members"][0]["state"]+" "+d["members"][0]["pr"]')"
eq "C: C2 is sent once more" "C2 T3" "$(printf '%s' "$S" | jq_ 'd["next"][0]["key"]+" "+d["next"][0]["retry_of"]')"
has "C: the retry says so" "$(printf '%s' "$S" | jq_ 'd["next"][0]["body"]')" "这是重试"
eq "C: not done yet" False "$(printf '%s' "$S" | jq_ 'd["done"]')"
dispatch_next "$S"
STUB_PARENT="$P" bash "$BIN/fleet-task-record.sh" dispatch --title "C9 · 范围内补的一项" --repo o/r >/dev/null
S=$(tick)
eq "C: an added member counts" "added running" "$(printf '%s' "$S" | jq_ '[m["layer"]+" "+m["state"] for m in d["members"] if m["key"]=="C9"][0]')"
set_outcome T5 succeeded 103

# --- D. the retry fails too: blocked, done, the report's read ---------------------
set_outcome T4 failed
S=$(tick)
eq "D: C2 is blocked after its retry" "blocked" "$(printf '%s' "$S" | jq_ '[m["state"] for m in d["members"] if m["key"]=="C2"][0]')"
eq "D: the batch is done" True "$(printf '%s' "$S" | jq_ 'd["done"]')"
eq "D: counts" "2 1" "$(printf '%s' "$S" | jq_ 'str(d["counts"]["succeeded"])+" "+str(d["counts"]["blocked"])')"
eq "D: the reserve stays unstarted" "unstarted" "$(printf '%s' "$S" | jq_ '[m["state"] for m in d["members"] if m["key"]=="R1"][0]')"
eq "D: C2 kept both tries" "T3 T4" "$(printf '%s' "$S" | jq_ '" ".join(t["task"] for m in d["members"] if m["key"]=="C2" for t in m["tasks"])')"
has "D: the line says write the report" "$(tick --line)" "该写报告"
H=$(bash "$BIN/fleet-epic-heartbeat.sh" "$P" --tick 3 --title "EPIC: 演示批次" --live 0 --inflight 0)
has "D: the heartbeat stamps the parent task" "$H" "stamped epic=T1"
has "D: and clears it" "$(bash "$BIN/fleet-epic-heartbeat.sh" --clear "$P")" "cleared"
python3 "$BIN/fleet-epic-tick.py" status --task T99 >/dev/null 2>&1; RC=$?
eq "D: an unknown parent is not a batch" 1 "$RC"

# --- F. the plan's local drafts travel with the batch (T793) -----------------------
# The plan names ~/fleet-drafts/… files; the parent's dispatch carries them, and a
# driver on ANOTHER machine (the drafts gone) still hands each member its own file
# and the 共同约定 — and says a file nobody carried.
mkdir -p "$WORK/mini2/fleet-drafts/t696/members" "$WORK/macmini"
printf '约定：不改 conf 格式。\n' > "$WORK/mini2/fleet-drafts/t696/sections.md"
printf 'C1 细节：开关叫 drafts。\n' > "$WORK/mini2/fleet-drafts/t696/members/C1.md"
cat > "$WORK/charter2" <<'EOF2'
<!-- fleet:epic repo=o/r short=草稿 cap=4 -->
# EPIC: 草稿批次

## 共同约定
全文见 ~/fleet-drafts/t696/sections.md

## 成员
- [ ] **C1** 带细节的一项
- [ ] **C2** 细节没带上的一项

## C1 · 带细节的一项
细节（必读）~/fleet-drafts/t696/members/C1.md

## C2 · 细节没带上的一项
细节（必读）~/fleet-drafts/t696/members/C2.md
EOF2
P=$(HOME="$WORK/mini2" bash "$BIN/fleet-task-record.sh" dispatch --title "EPIC: 草稿批次" --body-file "$WORK/charter2" 2>"$WORK/perr" | head -1)
has "F: the plan's dispatch says the file it could not carry" "$(cat "$WORK/perr")" "members/C2.md · 不在这台机器"
S=$(HOME="$WORK/macmini" tick)
B1=$(printf '%s' "$S" | jq_ '[n["body"] for n in d["next"] if n["key"]=="C1"][0]')
has "F: on another machine, C1 still gets its own file" "$B1" "C1 细节：开关叫 drafts。"
has "F: and the 共同约定, file and all" "$B1" "约定：不改 conf 格式。"
has "F: the line warns about C2's file" "$(HOME="$WORK/macmini" tick --line)" "C2 的本机文件没能随单带上"

# --- E. no GitHub ---------------------------------------------------------------------
[ -e "$WORK/denied" ] && bad "E: a GitHub road ran: $(cat "$WORK/denied")" || ok
if grep -qv '^[A-Z]* https://hub.test/v1/node/tasks' "$WORK/calls"; then bad "E: a request left the hub: $(grep -v 'hub.test/v1/node/tasks' "$WORK/calls")"; else ok; fi

[ "$BAD" = 0 ] && { printf 'fleet-epic-hub-selftest: %d checks OK (plan → run → report on hub tasks, gh=0)\n' "$N"; exit 0; }
printf 'fleet-epic-hub-selftest: %d of %d FAILED\n' "$BAD" "$N"; exit 1
