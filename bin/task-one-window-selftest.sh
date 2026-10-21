#!/bin/bash
# task-one-window-selftest.sh — one record, one window (T847).
#
# 2026-10-21: an orchestrator re-opened windows for records that still had one
# (the reclaim retried on an unclear receipt). Each copy took the record's ID as
# its @fleet_id; reaping a copy closed that ID — and the hub ended the record
# (cancelled, 「结束·没交回结果（reaped）」) while the first window still worked.
# Pinned here on a REAL isolated tmux server (-L <label>, killed at exit), a
# sandbox FLEET_CONF_DIR and a stub hub (FLEET_HUB_CURL):
#
#   A  the readers: fleet_task_windows / fleet_task_running / fleet_fid_shared
#      find a record's windows by @task or @fleet_id, skip an exited one as
#      running, and name the OTHER window carrying an ID
#   B  ② fleet_win_retire <copy> … reaped while another window carries the ID:
#      the ID stays open and nothing is marked retired; the last window's
#      retire ends it (and marks it)
#   C  ② fleet-cleanup-idle.py's shared(): the same answer from the reaper
#   D  ① dash-raw-session.sh --task T5 while T5 runs here: no second window,
#      stderr 「已在 <sock>:<win> 跑」, --print answers with the RUNNING window
#   E  ① fleet-task-record.sh respawn: refused for a record a window here runs
#      and for one the hub sees live elsewhere (the spawner never called);
#      a record with no session is opened with --origin-wid <its parent_session>
#      (the hub's 「parent differs」 409), and --force opens one anyway
#   F  ③ fleet-task-record.sh revive: a record its ID's close ended, with a
#      window here still carrying the ID ⇒ the ledger's `reopened` (naming that
#      window) is pushed and the hub's record comes back; a record ended by its
#      result is refused (1); an open record is left (0); no window ⇒ refused
#
# tmux / python3 absent → SKIP (exit 0).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'task-one-window: python3 absent — SKIP\n'; exit 0; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'task-one-window: tmux absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/t1win.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
L="t1win-$$"
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { tf kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
N=0
fail() { printf 'task-one-window FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }
eq()  { N=$((N + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
has() { N=$((N + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — [$3] not in [$2]" ;; esac; }
hasnt() { N=$((N + 1)); case "$2" in *"$3"*) fail "$1 — [$3] in [$2]" ;; esac; }

export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_ID_PUSH=0 FLEET_MCP=0
unset TMUX TMUX_PANE FLEET_SESSION FLEET_TASK_FID FLEET_TASK_DUP_OK FLEET_ID_LIVE FLEET_ID_LIVE_CMD
mkdir -p "$FLEET_CONF_DIR/fleets/$L" "$FLEET_CONF_DIR/logs"
printf 'FLEET_SESSION=%s\n' "$L" > "$FLEET_CONF_DIR/fleets/$L/conf"
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fixture\n' > "$FLEET_CONF_DIR/node.env"

uid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
F=$(uid); G=$(uid); F8=$(uid); PS="c7d372cf-903b-5229-8e55-3e286e9c026d/$(uid)"
tf new-session -d -s "$L" -n home 'sleep 600' || fail "cannot start the isolated tmux server"
mkwin() {  # <name> <@task> <@fleet_id> <@claude_state> → its window id
  local w
  w=$(tf new-window -d -P -F '#{window_id}' -t "$L:" -n "$1" 'sleep 600') || fail "cannot open window $1"
  tf set-option -w -t "$w" @task "$2"
  tf set-option -w -t "$w" @fleet_id "$3"
  tf set-option -w -t "$w" @claude_state "$4"
  printf '%s' "$w"
}
lib() { bash -c '. "$1/fleet-lib.sh" && shift && "$@"' _ "$BIN" "$@"; }

# ------------------------------------------------------------- A: the readers ----
W1=$(mkwin orig T5 "$F" working)
W2=$(mkwin copy T5 "$F" exited)
W3=$(mkwin other T6 "$G" working)
has "A1: both windows of T5 found" "$(lib fleet_task_windows T5)" "$W2"
eq "A2: the running one is the first that has not exited" "$L	$W1" "$(lib fleet_task_running T5)"
eq "A3: by its ID alone" "$L	$W1" "$(lib fleet_task_running '' "$F")"
eq "A4: the other window carrying F (from the original)" "$L	$W2" "$(lib fleet_fid_shared "$F" "$L" "$W1")"
eq "A5: the other window carrying F (from the copy)" "$L	$W1" "$(lib fleet_fid_shared "$F" "$L" "$W2")"
lib fleet_fid_shared "$G" "$L" "$W3" >/dev/null && fail "A6: an ID one window carries is not shared"
N=$((N + 1))
lib fleet_task_running T99 >/dev/null && fail "A7: a record no window runs"
N=$((N + 1))

# ------------------------------------------- B: a copy's reap keeps the ID ----
python3 "$BIN/fleet_id.py" open "$F" --task T5 --title t5 >/dev/null || fail "cannot open the ledger"
closed() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_id
print("closed" if fleet_id.fold(fleet_id.read(sys.argv[2]))["closed"] else "open")' "$BIN" "$1"; }
err=$(lib fleet_win_retire "$W2" "$L" reaped 2>&1)
has "B1: the copy's retire says why it keeps the ID" "$err" "$W1"
eq "B2: the ID stays open while the original runs" open "$(closed "$F")"
[ -e "$FLEET_CONF_DIR/global/retired/$F" ] && fail "B3: the shared ID was marked retired"
N=$((N + 1))
tf kill-window -t "$W2"
lib fleet_win_retire "$W1" "$L" reaped 2>/dev/null
eq "B4: the last window's retire ends the ID" closed "$(closed "$F")"
[ -e "$FLEET_CONF_DIR/global/retired/$F" ] || fail "B5: the last window is marked retired"
N=$((N + 1))
# put T5's ID back for the legs below (the original still runs)
python3 "$BIN/fleet_id.py" revive "$F" --window "$W1" >/dev/null
rm -f "$FLEET_CONF_DIR/global/retired/$F"

# ------------------------------------------------- C: the idle reaper agrees ----
W2=$(mkwin copy T5 "$F" "done")
got=$(python3 - "$BIN" "$L" "$W2" "$F" <<'PY'
import importlib.util, sys, types
b, sock, win, fid = sys.argv[1:]
sys.path.insert(0, b)
spec = importlib.util.spec_from_file_location("ci", b + "/fleet-cleanup-idle.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
c = m.Cleaner.__new__(m.Cleaner)
c.args = types.SimpleNamespace(socket_name=sock)
print(c.shared(win, fid))
PY
)
eq "C1: the reaper sees the original carrying the copy's ID" "$L	$W1" "$got"
tf kill-window -t "$W2"

# --------------------------------------- D: no second window on a running record ----
nwin() { tf list-windows -t "$L" -F x | grep -c .; }
before=$(nwin)
out=$(bash "$BIN/dash-raw-session.sh" --task T5 --repo o/r --name dup --print --origin hub "$L" 2>"$WORK/d.err"); rc=$?
eq "D1: exit 0" 0 "$rc"
has "D2: stderr names where it runs" "$(cat "$WORK/d.err")" "T5 已在 $L:$W1 跑"
has "D3: --print answers with the running window" "$out" "$W1"
has "D4: its ID" "$out" "$F"
eq "D5: no window opened" "$before" "$(nwin)"

# -------------------------------------------------------- E: respawn ----
cat > "$WORK/hub" <<'PY'
#!/usr/bin/env python3
# A stub hub: the records in $STUB_STATE; a pushed `reopened` puts back what an
# ID's close ended (the hub's reopenTasksOnID).
import json, os, sys
sys.stdin.read()
args = sys.argv[1:]
url = args[-1]
body = args[args.index("--data-binary") + 1] if "--data-binary" in args else ""
p = os.environ["STUB_STATE"]
st = json.load(open(p))
def out(obj, code=200):
    print(json.dumps(obj)); print(code); sys.exit(0)
if url.startswith("https://hub.test/v1/node/ids"):
    if '"reopened"' in body:
        for t in st["tasks"].values():
            obs = t.get("observation") or ""
            if obs.startswith("id_closed:") and obs.split(":")[1] in body and t["state"] == "cancelled":
                t["state"], t["outcome"], t["observation"] = obs.split(":")[2], "", ""
        json.dump(st, open(p, "w"))
    out({"seq": 99})
path = url[len("https://hub.test/v1/node/tasks"):].strip("/")
if path in st["tasks"]:
    out(dict(task=st["tasks"][path], live=st.get("live", {}).get(path), pr_state="none"))
out({"error": "no route"}, 404)
PY
chmod +x "$WORK/hub"
python3 - "$WORK/state.json" "$F" "$F8" "$PS" <<'PY'
import json, sys
path, f, f8, ps = sys.argv[1:]
def rec(n, fid, **kw):
    r = dict(id=n, short="S" + n[1:], fid=fid, authority_version=1, title="rec " + n, repo="o/r", outcome="",
             state="accepted", generation=1, attempt_id="task:%s:g1" % n, resolved_agent="claude", parent_session=ps,
             request_payload=json.dumps({"body": "do " + n, "repo": "o/r", "reap": "merged", "dispatch": {"request_id": n}}))
    r.update(kw); return r
tasks = {"T5": rec("T5", f), "T4": rec("T4", ""), "T7": rec("T7", "")}
tasks["T8"] = rec("T8", f8, state="cancelled", outcome="cancelled", observation="id_closed:%s:accepted" % f8,
                  evidence="结束·没交回结果（reaped）")
tasks["T9"] = rec("T9", f8, state="failed", outcome="failed", observation="")
live = {"T7": {"key": "scratch-62", "state": "working", "stale": False}}
json.dump({"tasks": tasks, "live": live}, open(path, "w"))
PY
cat > "$WORK/spawn" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/spawned"
EOF
chmod +x "$WORK/spawn"
henv() { env FLEET_HUB_CURL="$WORK/hub" STUB_STATE="$WORK/state.json" FLEET_TASK_RESPAWN="$WORK/spawn" "$@"; }
henv bash "$BIN/fleet-task-record.sh" respawn T5 2>"$WORK/e.err"; rc=$?
eq "E1: a record a window here runs: exit 0" 0 "$rc"
has "E2: says where" "$(cat "$WORK/e.err")" "T5 已在 $L:$W1 跑"
[ -e "$WORK/spawned" ] && fail "E3: the spawner was called for a running record"
N=$((N + 1))
henv bash "$BIN/fleet-task-record.sh" respawn T7 2>"$WORK/e.err"; rc=$?
eq "E4: a record the hub sees live elsewhere: exit 0" 0 "$rc"
has "E5: says where" "$(cat "$WORK/e.err")" "scratch-62"
[ -e "$WORK/spawned" ] && fail "E6: the spawner was called for a record live elsewhere"
N=$((N + 1))
henv bash "$BIN/fleet-task-record.sh" respawn T4 2>"$WORK/e.err" || fail "E7: respawn of a session-less record refused" "$(cat "$WORK/e.err")"
sp=$(cat "$WORK/spawned" 2>/dev/null)
has "E8: on the same record" "$sp" "--task T4"
has "E9: for the record's own parent" "$sp" "--origin-wid $PS"
rm -f "$WORK/spawned"
henv bash "$BIN/fleet-task-record.sh" respawn T5 --force 2>/dev/null || fail "E10: --force refused"
has "E11: --force opens one anyway" "$(cat "$WORK/spawned" 2>/dev/null)" "--task T5"
rm -f "$WORK/spawned"
henv bash "$BIN/fleet-task-record.sh" respawn T4 --origin scratch-3 2>/dev/null
sp=$(cat "$WORK/spawned" 2>/dev/null)
has "E12: --origin wins" "$sp" "--origin scratch-3"
hasnt "E13: … and no --origin-wid beside it" "$sp" "--origin-wid"

# -------------------------------------------------------- F: revive ----
python3 "$BIN/fleet_id.py" open "$F8" --task T8 --title t8 >/dev/null
python3 "$BIN/fleet_id.py" close "$F8" --reason reaped >/dev/null
henv bash "$BIN/fleet-task-record.sh" revive T8 2>"$WORK/f.err"; rc=$?
eq "F1: no window carries T8's ID: refused" 1 "$rc"
has "F2: says so" "$(cat "$WORK/f.err")" "no window here carries"
W8=$(mkwin t8 T8 "$F8" working)
out=$(henv bash "$BIN/fleet-task-record.sh" revive T8 2>"$WORK/f.err"); rc=$?
eq "F3: revived" 0 "$rc"
has "F4: its code" "$out" "S8"
has "F5: says which window" "$(cat "$WORK/f.err")" "$W8"
eq "F6: the ledger is open again" open "$(closed "$F8")"
last=$(tail -n 1 "$FLEET_CONF_DIR/ids/$F8.ndjson")
has "F7: a reopened event" "$last" '"reopened"'
has "F8: naming the window" "$last" "\"$W8\""
eq "F9: the hub's record is back" accepted "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"]["T8"]["state"])' "$WORK/state.json")"
henv bash "$BIN/fleet-task-record.sh" revive T8 >/dev/null 2>"$WORK/f.err"; rc=$?
eq "F10: an open record: left, exit 0" 0 "$rc"
has "F11: says so" "$(cat "$WORK/f.err")" "still open"
henv bash "$BIN/fleet-task-record.sh" revive T9 2>"$WORK/f.err"; rc=$?
eq "F12: ended by its result: refused" 1 "$rc"
has "F13: says why" "$(cat "$WORK/f.err")" "only an end its ID's close made"

printf 'task-one-window selftest: OK (%d checks)\n' "$N"
