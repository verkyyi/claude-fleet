#!/bin/bash
# fleet-compose-latency-selftest.sh — issue #2238 (EPIC #2230 C8): every send's
# segments, read back from the two halves that record them.
#
#   A. two sample logs — a client compose.ndjson and a node's control/state.sqlite3
#      — merge on the operation id: each segment's p50 / max and ↵ → 能打字 are right,
#      the client's t_ready wins over the node's, the node fills t_prompt
#   B. an older node (no timing) and an older client (no t_enter): 「—」, exit 0
#   C. --node keeps one machine's sends; --last the newest N; orchestrate is no send
#   D. --summary is fleet-doctor's one line; no log at all is n=0, exit 0
#   E. usage: a bad --last is exit 2
#   F. the node half (fleet_control.py): a finished start's result carries
#      timing; watch_ready stamps t_prompt at the first `working` and t_ready at
#      idle, an unseeded start is ready once its agent is up, a window that is gone
#      ends the watch with nothing stamped
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/compose-latency-selftest.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
row() { printf '%s\n' "$1" | grep -F -- "$2" | head -1 | tr -s ' '; }

export FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$FLEET_CONF_DIR/control"
LOG="$WORK/compose.ndjson"
cat > "$LOG" <<'EOF'
{"ev":"sent","id":"a","ts":1759800000,"how":"issue","repo":"acme/web","t_enter":1000000}
{"ev":"placed","id":"a","rc":0,"result":"REMOTE","machine":"m5","op":"op-a","t_accepted":1000400,"timing":{"t_accepted":1000400,"t_window":1005400}}
{"ev":"started","id":"a","session":"U/issue-1","state":"working"}
{"ev":"ready","id":"a","session":"U/issue-1","state":"done","t_ready":1006000}
{"ev":"sent","id":"b","ts":1759800100,"how":"scratch","repo":"acme/web","t_enter":2000000}
{"ev":"placed","id":"b","rc":0,"result":"REMOTE","machine":"m5","op":"op-b","t_accepted":2000200,"timing":{"t_accepted":2000200,"t_window":2002200}}
{"ev":"sent","id":"o","ts":1759800150,"how":"orchestrate","t_enter":2500000}
{"ev":"sent","id":"c","ts":1759800200,"how":"issue","repo":"acme/app"}
{"ev":"placed","id":"c","rc":0,"result":"REMOTE","machine":"m4","op":"op-c"}
not json
EOF
# the node's half: op-b's ready and first sentence came after the place answered;
# op-a's t_ready (9 s) loses to what the client saw (6 s)
python3 - "$FLEET_CONF_DIR/control/state.sqlite3" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE operations (id TEXT PRIMARY KEY, fleet_id TEXT, action TEXT, request TEXT, actor TEXT,"
           " status TEXT, created REAL, updated REAL, result TEXT)")
for op, t in (("op-a", {"t_accepted": 1000400, "t_window": 1005400, "t_ready": 1009000}),
              ("op-b", {"t_accepted": 2000200, "t_window": 2002200, "t_prompt": 2002700, "t_ready": 2003200})):
    db.execute("INSERT INTO operations VALUES (?,?,?,?,?,?,?,?,?)",
               (op, "f", "worker_start", "{}", "x", "succeeded", 0, 0, json.dumps({"window": "@1", "timing": t})))
db.commit()
PY

# A. both halves merged
out=$(bash "$BIN/fleet-compose-latency.sh" --log "$LOG"); rc=$?
eq 'A: exit 0' 0 "$rc"
has 'A: three sends, orchestrate is none' "$out" '最近 3 次发任务 · 全部机器'
eq 'A: ↵ → 受理 p50 0.20 max 0.40 (2 of 3)' '↵ → 入口受理 0.20s 0.40s 2/3' "$(row "$out" '入口受理')"
eq 'A: 受理 → 窗口 p50 2.00 max 5.00' '受理 → 窗口到手 2.00s 5.00s 2/3' "$(row "$out" '窗口到手')"
eq 'A: the node fills 第一句' '窗口 → 第一句送进去 0.50s 0.50s 1/3' "$(row "$out" '第一句')"
eq 'A: 窗口 → 能打字 (client 0.6 s wins over node 3.6 s)' '窗口 → 能打字 0.60s 1.00s 2/3' "$(row "$out" '窗口 → 能打字')"
eq 'A: ↵ → 能打字 total' '↵ → 能打字（总） 3.20s 6.00s 2/3' "$(row "$out" '能打字（总）')"
eq 'A: 单子 not recorded is —' '↵ → 单子建好 — — 0/3' "$(row "$out" '单子建好')"
has 'A: the slowest send named' "$(row "$out" '最慢一次')" 'm5 issue a ↵ → 能打字 6.00s'

# B. no node db, an old node + old client: — and no error
out=$(FLEET_CONF_DIR="$WORK/none" bash "$BIN/fleet-compose-latency.sh" --log "$LOG" --node m4 2>&1); rc=$?
eq 'B: exit 0' 0 "$rc"
eq 'B: old node: 受理 —' '↵ → 入口受理 — — 0/1' "$(row "$out" '入口受理')"
eq 'B: total —' '↵ → 能打字（总） — — 0/1' "$(row "$out" '能打字（总）')"
has 'B: no slowest yet' "$out" '最慢一次：—'
has 'B: no Traceback' "${out:-x}" '最近 1 次发任务 · m4'

# C. --node m5 / --last 1
out=$(bash "$BIN/fleet-compose-latency.sh" --log "$LOG" --node m5)
has 'C: --node m5 keeps two' "$out" '最近 2 次发任务 · m5'
out=$(bash "$BIN/fleet-compose-latency.sh" --log "$LOG" --last 1)
has 'C: --last 1 is the newest' "$out" '最近 1 次发任务'
eq 'C: …which is c (m4, no timing)' '↵ → 入口受理 — — 0/1' "$(row "$out" '入口受理')"

# D. --summary; no log at all
eq 'D: summary' 'n=3 ready=2 p50=3200 max=6000' "$(bash "$BIN/fleet-compose-latency.sh" --log "$LOG" --summary)"
eq 'D: no log → n=0' 'n=0 ready=0 p50=- max=-' "$(FLEET_COMPOSE_LOG="$WORK/nope.ndjson" bash "$BIN/fleet-compose-latency.sh" --summary)"
out=$(FLEET_COMPOSE_LOG="$WORK/nope.ndjson" bash "$BIN/fleet-compose-latency.sh"); rc=$?
eq 'D: no log → exit 0' 0 "$rc"
has 'D: …says so' "$out" '最近没有发任务的记录'

# E. usage
bash "$BIN/fleet-compose-latency.sh" --last x >/dev/null 2>&1
eq 'E: bad --last is exit 2' 2 "$?"

# F. the node half, fleet_control.py with a scripted adapter
out=$(PYTHONDONTWRITEBYTECODE=1 python3 - "$BIN" "$WORK/node" <<'PY' 2>&1
import json, sys
sys.path.insert(0, sys.argv[1])
import fleet_control as fc
c = fc.Control(conf_dir=sys.argv[2])

IDS = {}

def op(op_id, timing):
    op_id = IDS.setdefault(op_id, "00000000-0000-4000-8000-00000000000" + op_id)
    with c.store.connect() as db:
        db.execute("INSERT INTO operations VALUES (?,?,?,?,?,?,?,?,?)",
                   (op_id, "f", "worker_start", "{}", "x", "succeeded", 1.0, 1.0,
                    fc.canonical({"window": "@3", "timing": timing})))

def timing(op_id):
    return c.get_operation(IDS[op_id])["result"]["timing"]

def script(states):
    seq = list(states)
    def adapter(mode, *args, **kw):
        assert mode == "wstate" and args == ("demo", "@3"), (mode, args)
        if not seq:
            return 5, b"", b""
        s = seq.pop(0)
        return (5, b"", b"") if s is None else (0, s.encode() + b"\n", b"")
    c.adapter = adapter

fc.time.sleep = lambda s: None
fleet = {"name": "demo"}
op("1", {"t_accepted": 1000, "t_window": 2000})
script(["\t", "\tsid", "working\tsid", "working\tsid", "done\tsid"])
c.watch_ready(IDS["1"], fleet, "@3", True)
t = timing("1")
print("seeded", sorted(t), t["t_accepted"], t["t_prompt"] <= t["t_ready"])
op("2", {"t_window": 2000})
script(["\t", "\tsid"])
c.watch_ready(IDS["2"], fleet, "@3", False)
print("unseeded", sorted(timing("2")))
op("3", {"t_window": 2000})
script(["\t", None])
c.watch_ready(IDS["3"], fleet, "@3", False)
print("gone", sorted(timing("3")), c.get_operation(IDS["3"])["status"])
print("ms", fc.ms(1.2345))
PY
)
eq 'F: node half' $'seeded [\'t_accepted\', \'t_prompt\', \'t_ready\', \'t_window\'] 1000 True\nunseeded [\'t_ready\', \'t_window\']\ngone [\'t_window\'] succeeded\nms 1234' "$out"
has 'F: a start result carries timing' "$(grep -n '"timing": {"t_accepted": ms(row\["created"\]), "t_window": ms(now())}' "$BIN/fleet_control.py")" 't_window'

if [ "$FAIL" -gt 0 ]; then
  printf 'fleet-compose-latency-selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2
  exit 1
fi
printf 'fleet-compose-latency-selftest: all %d checks passed\n' "$CHECKS"
