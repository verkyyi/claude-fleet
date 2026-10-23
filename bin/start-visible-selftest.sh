#!/bin/bash
# start-visible-selftest.sh — a task session that never came up is SEEN, at once,
# and nobody takes it for running (T642). Both halves, by the names they ship as:
#
#   A  bin/fleet-session-wrap.sh on a REAL isolated tmux server (-S socket, killed
#      at exit) with a fake launcher, its window bound to a record (@task T7) and an
#      ID whose ledger is here:
#      A1 the first launch dies in its first seconds ("task authority unavailable",
#         C1 / R8's road) → the caller's bare shell as before, AND the ID's progress
#         word reads 「未起来：启动 N 秒就退出（rc 3）：…」 (state not_started), one
#         line in logs/start-fail.log, no Parent delivery
#      A2 the same cause again (another seconds count) → SAME: no second word, no
#         Parent report
#      A3 the agent's first SessionStart (fleet_id.py hook) answers 「起来了」
#      A4 a record's agent that ran and went down → 「已掉」 on its ID, no report
#      A5 a window with no record and no issue → the log line only
#   B  bin/fleet-epic-tick.py / fleet_task_control.py against a stub hub
#      (FLEET_HUB_CURL) and a sandbox ledger — the ONE reader, fleet_id.start_word:
#      B1 the record `accepted`, its window here holding only a shell
#         (FLEET_ID_NOAGENT) → the member is `stalled` (not_started), never
#         running; its hint restarts it on the SAME record
#         (fleet-task-record.sh respawn T2 --prev <ID>); it keeps its slot; not done
#      B2 no window here, no native segment past FLEET_START_GRACE → stalled
#      B3 the hub's read says it started → running
#      B4 the wrapper's word on the ID → stalled, with its words
#      B5 `await --task` answers RETIRED at once (exit 2), without delivery
#      B6 `fleet-task-record.sh respawn` reopens it on the same record: --task T2,
#         --repo, --prev <ID>, the record's words as the prompt (FLEET_TASK_RESPAWN)
#
# tmux / python3 absent → SKIP (exit 0).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'start-visible: python3 absent — SKIP\n'; exit 0; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'start-visible: tmux absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/startvis.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/s"
tf() { "$REAL_TMUX" -S "$SOCK" "$@"; }
cleanup() { tf kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
N=0
fail() { printf 'start-visible FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }
eq()  { N=$((N + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
has() { N=$((N + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — [$3] not in [$2]" ;; esac; }
waitfor() {  # <what> <command…> — up to 15 s
  local what="$1"; shift
  for _ in $(seq 1 150); do "$@" && { N=$((N + 1)); return 0; }; sleep 0.1; done
  fail "timed out: $what"
}

mkdir -p "$WORK/conf/logs" "$WORK/wbin"
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_ID_PUSH=0 FLEET_MCP=0 FLEET_CRED_PROXY=0
unset TMUX TMUX_PANE FLEET_SESSION FLEET_ID_LIVE FLEET_ID_LIVE_CMD FLEET_ID_NOAGENT FLEET_ID_NOAGENT_CMD
unset FLEET_CODEX_LAUNCHER_PID CLAUDE_CODE_ENTRYPOINT FLEET_ID_HOOK
for f in "$BIN"/*; do ln -s "$f" "$WORK/wbin/${f##*/}"; done
rm -f "$WORK/wbin/fleet-report-parent.sh"
cat > "$WORK/wbin/fleet-report-parent.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/reported"
EOF
chmod +x "$WORK/wbin/fleet-report-parent.sh"

uid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
FID=$(uid); PFID=$(uid)
python3 "$BIN/fleet_id.py" open "$FID" --task T7 --parent "$PFID" --title 'C1 · a' >/dev/null || fail "cannot open the ledger"
prog() {  # <ID> <field> — the ID's newest progress word's field
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_id
p = fleet_id.fold(fleet_id.read(sys.argv[2]))["progress"] or {}
print(p.get(sys.argv[3], ""))' "$BIN" "$1" "$2"
}
nwords() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_id
print(sum(1 for e in fleet_id.read(sys.argv[2]) if e.get("ev") == "progress"))' "$BIN" "$1"; }

# The agent: binds its window as a spawner would, then leaves the way $CTL/mode says.
cat > "$WORK/fake-launch" <<'EOF'
#!/bin/bash
[ -n "${BIND_TASK:-}" ] && tmux set-option -w -t "$TMUX_PANE" @task "$BIND_TASK"
[ -n "${BIND_FID:-}" ] && tmux set-option -w -t "$TMUX_PANE" @fleet_id "$BIND_FID"
case "$(cat "$CTL/mode" 2>/dev/null)" in
  fast) echo 'fleet-launch: task authority unavailable/refused — not starting' >&2; exit 3 ;;
  run)  sleep "${RUN_SECS:-3}"; exit 1 ;;
esac
EOF
chmod +x "$WORK/fake-launch"

win() {  # <name> <mode> [env…] — a window running the wrapper as the spawners do
  local n=$1 m=$2; shift 2
  mkdir -p "$WORK/$n"; printf '%s' "$m" > "$WORK/$n/mode"
  local cmd="env CTL='$WORK/$n' FLEET_WRAP_LAUNCH='$WORK/fake-launch' FLEET_WRAP_FAST_FAIL=2 FLEET_EXIT_CLOSE_SECS=0 $*"
  cmd="$cmd '$WORK/wbin/fleet-session-wrap.sh' --agent claude 'the seed'; echo WRAP_RC=\$?; exec sleep 600"
  if tf has-session -t sv 2>/dev/null; then tf new-window -d -t sv: -n "$n" "$cmd"
  else tf -f /dev/null new-session -d -s sv -n "$n" -x 120 -y 30 "$cmd" || fail "cannot start the isolated tmux server"; fi
}
state_is() { [ "$(tf display-message -p -t "sv:$1" '#{@claude_state}' 2>/dev/null)" = "$2" ]; }
screen_has() { tf capture-pane -p -t "sv:$1" | grep -qF -- "$2"; }
word_is() { [ "$(prog "$1" state)" = "$2" ]; }
reports() { if [ -f "$WORK/reported" ]; then grep -c -- '--state failed' "$WORK/reported" || true; else printf '0\n'; fi; }

# A1 — the first launch dies at once: the caller's shell, and the miss is SAID.
win a1 fast "BIND_TASK=T7 BIND_FID=$FID FLEET_CONF_DIR='$WORK/conf'"
waitfor "A1: the wrapper returned the launch's status" screen_has a1 'WRAP_RC=3'
waitfor "A1: the ID says 未起来" word_is "$FID" not_started
has "A1: the word names the cause" "$(prog "$FID" summary)" '未起来：启动'
has "A1: … and what the launcher said" "$(prog "$FID" summary)" 'task authority unavailable'
eq "A1: no Parent report" 0 "$(reports)"
has "A1: the local log" "$(cat "$WORK/conf/logs/start-fail.log")" 'task=T7'

# A2 — the same cause again is not said twice.
win a2 fast "BIND_TASK=T7 BIND_FID=$FID FLEET_CONF_DIR='$WORK/conf'"
waitfor "A2: the wrapper returned" screen_has a2 'WRAP_RC=3'
sleep 1.5
eq "A2: one word for one cause" 1 "$(nwords "$FID")"
eq "A2: no report for repeated cause" 0 "$(reports)"
eq "A2: … but each miss is in the local log" 2 "$(grep -c 'task=T7' "$WORK/conf/logs/start-fail.log")"

# A3 — the agent comes up: its first SessionStart answers 「起来了」.
pane=$(tf display-message -p -t sv:a2 '#{pane_id}')
printf '{"session_id":"S-1","source":"startup"}' | \
  TMUX="$SOCK,1,0" TMUX_PANE="$pane" PATH="$(dirname "$REAL_TMUX"):$PATH" python3 "$BIN/fleet_id.py" hook
eq "A3: SessionStart answers the word" started "$(prog "$FID" state)"
eq "A3: … and the ID has its first segment" 1 \
  "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_id; print(len(fleet_id.fold(fleet_id.read(sys.argv[2]))["segments"]))' "$BIN" "$FID")"

# A4 — a record's agent that ran, then went down: 「已掉」, no report.
win a4 run "BIND_TASK=T7 BIND_FID=$FID RUN_SECS=3 FLEET_CONF_DIR='$WORK/conf'"
waitfor "A4: on the page" state_is a4 exited
waitfor "A4: the ID says 已掉" word_is "$FID" dropped
has "A4: the word" "$(prog "$FID" summary)" '已掉：agent 退出（rc 1'
sleep 1
eq "A4: a drop tells no parent" 0 "$(reports)"

# A5 — no record, no issue: the log only.
FID5=$(uid)
python3 "$BIN/fleet_id.py" open "$FID5" --title loose >/dev/null
win a5 fast "BIND_FID=$FID5 FLEET_CONF_DIR='$WORK/conf'"
waitfor "A5: the wrapper returned" screen_has a5 'WRAP_RC=3'
waitfor "A5: the local log" grep -sq "id=$FID5 task=- issue=-" "$WORK/conf/logs/start-fail.log"
sleep 1
eq "A5: no word on an ID with no record" "" "$(prog "$FID5" state)"
eq "A5: nobody told" 0 "$(reports)"
tf kill-server 2>/dev/null

# ------------------------------------------------------------ B: the readers ----
mkdir -p "$WORK/b/conf/logs" "$WORK/path"
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fixture\n' > "$WORK/b/conf/node.env"
cat > "$WORK/hub" <<'PY'
#!/usr/bin/env python3
# A stub hub: the parent T1 (its charter), its child T2 (unclaimed, accepted), the
# ID mirror's family read.
import json, os, sys
sys.stdin.read()
url = sys.argv[-1]
st = json.load(open(os.environ["STUB_STATE"]))
def out(obj, code=200):
    print(json.dumps(obj)); print(code); sys.exit(0)
if url.startswith("https://hub.test/v1/node/ids?"):
    from urllib.parse import parse_qs, urlsplit
    out({"parent": parse_qs(urlsplit(url).query)["parent"][0], "ids": []})
path = url[len("https://hub.test/v1/node/tasks"):].strip("/")
if path.endswith("/children"):
    out(dict(parent="T1", children=[t for t in st["tasks"].values() if t.get("parent_task") == "T1"]))
if path in st["tasks"]:
    got = dict(task=st["tasks"][path], live=None, pr_state="none")
    if path in st.get("started", {}):
        got["started"] = st["started"][path]
    out(got)
out({"error": "no route"}, 404)
PY
chmod +x "$WORK/hub"
BFID=$(uid); DRV=$(uid)
old=$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(minutes=12)).strftime("%Y-%m-%dT%H:%M:%S.000000000Z"))')
python3 - "$WORK/b/state.json" "$DRV" "$old" <<'PY'
import json, sys
path, drv, old = sys.argv[1:]
charter = "<!-- fleet:epic repo=o/r short=t cap=2 -->\n- [ ] **C1** a\n- [ ] **C2** b\n"
tasks = {
  "T1": dict(id="T1", authority_version=1, title="EPIC", worker_id="fleet/" + drv, outcome="", state="accepted",
             request_payload=json.dumps({"body": charter})),
  "T2": dict(id="T2", authority_version=1, title="C1 · a", parent_task="T1", repo="o/r", worker_id="", outcome="",
             state="accepted", created_at=old, generation=1, attempt_id="task:T2:g1", resolved_agent="claude",
             request_payload=json.dumps({"body": "do a", "repo": "o/r", "reap": "merged", "template": "fleet-worker",
                                         "dispatch": {"request_id": "r1"}})),
}
json.dump({"tasks": tasks}, open(path, "w"))
PY
benv() { env FLEET_CONF_DIR="$WORK/b/conf" FLEET_HUB_CURL="$WORK/hub" STUB_STATE="$WORK/b/state.json" \
  FLEET_ID_LIVE_CMD="${LIVE:-:}" FLEET_ID_NOAGENT_CMD="${NOAG:-:}" PATH="$WORK/path:$PATH" "$@"; }
FLEET_CONF_DIR="$WORK/b/conf" python3 "$BIN/fleet_id.py" open "$BFID" --task T2 --parent "$DRV" --title 'C1 · a' >/dev/null
# the ledger was opened 12 minutes ago, like the record
python3 - "$WORK/b/conf/ids/$BFID.ndjson" <<'PY'
import json, sys, time
p = sys.argv[1]; evs = [json.loads(l) for l in open(p)]
evs[0]["ts"] = int(time.time()) - 720
open(p, "w").write("".join(json.dumps(e) + "\n" for e in evs))
PY
tickj() { benv python3 "$BIN/fleet-epic-tick.py" status --task T1; }
jq_() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
c1() { printf '%s' "$S" | jq_ "[m for m in d['members'] if m['key']=='C1'][0]$1"; }

# B1 — accepted, its window here a bare shell → stalled, never running.
S=$(LIVE="echo $BFID" NOAG="echo $BFID" tickj) || fail "B1: the tick failed" "$S"
eq "B1: the member is stalled" stalled "$(c1 "['state']")"
eq "B1: … not started" not_started "$(c1 "['stall']['word']")"
has "B1: the why" "$(c1 "['stall']['why']")" '窗口还在，里面没有 agent'
has "B1: the hint restarts it on its record" "$(c1 "['stall']['hint']")" "fleet-task-record.sh respawn T2 --prev $BFID"
eq "B1: nobody counted running" 0 "$(printf '%s' "$S" | jq_ "d['counts']['running']")"
eq "B1: it keeps its slot" 1 "$(printf '%s' "$S" | jq_ "d['free']")"
eq "B1: not done" False "$(printf '%s' "$S" | jq_ "d['done']")"
has "B1: the line says it" "$(LIVE="echo $BFID" NOAG="echo $BFID" benv python3 "$BIN/fleet-epic-tick.py" status --task T1 --line)" 'C1 未起来'

# B2 — its window gone (the ID open, no result), past the grace → stalled, never
# a failure that dispatches a new T; and the hub's read alone (another machine's
# session: no native segment FLEET_START_GRACE after the record opened) the same.
S=$(tickj) || fail "B2: the tick failed" "$S"
eq "B2: window gone → stalled" stalled "$(c1 "['state']")"
has "B2: the why" "$(c1 "['stall']['why']")" '窗口已经不在了'
eq "B2: nothing re-dispatched" "[]" "$(printf '%s' "$S" | jq_ "[n['key'] for n in d['next'] if n['key']=='C1']")"
has "B2: the hub's read alone" "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_id
print(fleet_id.start_word(view={"task": {"created_at": sys.argv[2]}}))' "$BIN" "$old")" 'agent 还没起来'
eq "B2: … inside the grace, nothing" "{}" "$(python3 -c 'import sys, time; sys.path.insert(0, sys.argv[1]); import fleet_id
print(fleet_id.start_word(view={"task": {"created_at": "2999-01-01T00:00:00Z"}}))' "$BIN")"

# B3 — the hub's read says it started → running.
python3 - "$WORK/b/state.json" <<'PY'
import json, sys
st = json.load(open(sys.argv[1])); st["started"] = {"T2": {"id": "ABCD", "agent": "claude", "segments": 1}}
json.dump(st, open(sys.argv[1], "w"))
PY
S=$(LIVE="echo $BFID" tickj) || fail "B3: the tick failed" "$S"
eq "B3: up ⇒ running" running "$(c1 "['state']")"

# B4 — the wrapper's word on the ID wins over a stale `started`.
FLEET_CONF_DIR="$WORK/b/conf" python3 "$BIN/fleet_id.py" start-word "$BFID" --word not_started \
  --why '启动 1 秒就退出（rc 3）：task authority unavailable' >/dev/null
S=$(LIVE="echo $BFID" tickj) || fail "B4: the tick failed" "$S"
eq "B4: the word ⇒ stalled" stalled "$(c1 "['state']")"
has "B4: with its words" "$(c1 "['stall']['why']")" 'task authority unavailable'

# B5 — await answers at once.
t0=$SECONDS
out=$(LIVE="echo $BFID" benv python3 "$BIN/fleet_task_control.py" await --task T2 --timeout 60 --interval 5); rc=$?
eq "B5: await retired" 2 "$rc"
has "B5: the verdict" "$out" 'RETIRED'
has "B5: independent Task hint" "$out" 'view each Task directly'
N=$((N + 1)); [ $((SECONDS - t0)) -lt 30 ] || fail "B5: await waited $((SECONDS - t0)) s on a session that never came up"

# B6 — respawn: the same record, its words, the next baton.
cat > "$WORK/spawn" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/spawned"
for a in "\$@"; do case "\$a" in --prompt-file=*) cat "\${a#--prompt-file=}" > "$WORK/prompt" ;; esac; done
EOF
chmod +x "$WORK/spawn"
benv FLEET_TASK_RESPAWN="$WORK/spawn" bash "$BIN/fleet-task-record.sh" respawn T2 --prev "$BFID" \
  || fail "B6: respawn refused"
sp=$(tr '\n' ' ' < "$WORK/spawned")
has "B6: on the same record" "$sp" '--task T2'
has "B6: in its repo" "$sp" '--repo o/r'
has "B6: the next baton" "$sp" "--prev $BFID"
has "B6: as its agent file" "$sp" '--as fleet-worker'
has "B6: its words" "$(cat "$WORK/prompt")" 'do a'

printf 'start-visible selftest: OK (%d checks)\n' "$N"
