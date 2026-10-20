#!/bin/bash
# fleet-task-id-selftest.sh — a task's sessions all go by the task's own ID (EPIC
# T644 C2). On an isolated tmux server and a sandbox conf dir, with the hub's
# answers a seam (FLEET_ID_HUB_POST):
#   TAKE  fleet_id.py take: `first` while the hub's reservation is unpushed (seq 0)
#         or the hub has no row, `here` once this machine keeps the ledger,
#         `elsewhere` (rc 1) when another machine pushed it or the hub is silent
#   LIB   fleet_task_fid reads $FLEET_TASK_FID only for ITS record (`T<n>=<ID>`);
#         fleet_task_take answers `<ID>\there|first` rc 0, `<ID>\telsewhere` rc 2,
#         rc 1 with no ID
#   OPEN  the spawner's block: a task window takes the task's ID (TASK_FID), its
#         own redo drops a prev to itself; another machine's ⇒ the task's ID as prev
#   SEG   the recovery page's ↵ (@id_next_trigger reopen:<epoch>) on the SAME
#         conversation id is a new segment, trigger reopen; a compaction leaves the
#         mark for the next start; a stale mark is nothing
#   REDO  attempt: a ledger that ran a segment opens attempt 2 (a `reopened`
#         event — the close cleared), the next start is a `redo` segment of
#         attempt 2; the failed result of attempt 1 no longer counts (status
#         running, await waits); a merged result of attempt 2 is the task's;
#         get prints 第 2 次
#   TWO   two live windows carrying the task's ID are a conflict (status), and
#         both rows red on the panel (fleet_view.id_conflicts)
#   WIRE  both spawners take the task's ID; the dispatch hands it bound to its
#         record; the wrapper's ↵, restore and migrate mark the reopen
# tmux / python3 absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
REAL_TMUX=$(command -v tmux) || { echo 'fleet-task-id selftest: tmux absent — SKIP'; exit 0; }
st_need python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-task-id.XXXXXX")" || exit 2
L="ftid$$"
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1 FLEET_ID_PUSH=0
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_CODEX_LAUNCHER_PID CLAUDE_CODE_ENTRYPOINT FLEET_ID_HOOK FLEET_TASK_FID

st_tally count miss
tf() { "$REAL_TMUX" -L "$L" "$@"; }
opt() { tf show-options -wqv -t "$1" "$2"; }
cleanup() { FLEET_ALLOW_TMUX_DESTROY=1 "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
tf -f /dev/null new-session -d -s "$L" -n home 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'fleet-task-id selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
SOCKP=$(tf display-message -p '#{socket_path}')
SPID=$(tf display-message -p '#{pid}')

# The hub, as fleet-id.sh _post answers: `<code>\n<body>` off $WORK/hub.<ID>
cat > "$WORK/hub.sh" <<'HUB'
#!/bin/bash
f="$HUBDIR/hub.${2##*/}"
[ -f "$f" ] || { printf '404\n{"error":"no ID"}\n'; exit 0; }
cat "$f"
HUB
chmod +x "$WORK/hub.sh"
export HUBDIR="$WORK" FLEET_ID_HUB_POST="$WORK/hub.sh"
hub() { printf '%s\n%s\n' "$2" "$3" > "$WORK/hub.$1"; }

newwin() {
  local w p
  w=$(tf new-window -d -P -F '#{window_id}' -t "$L:" 'while :; do sleep 300; done')
  [ -n "${1:-}" ] && tf set-window-option -t "$w" @fleet_id "$1"
  p=$(tf display-message -p -t "$w" '#{pane_id}')
  printf '%s %s' "$w" "$p"
}
hook() {
  local pane=$1 src=$2 sid=$3
  printf '{"hook_event_name":"SessionStart","source":"%s","session_id":"%s"}' "$src" "$sid" \
    | env TMUX="$SOCKP,$SPID,0" TMUX_PANE="$pane" bash "$BIN/fleet-id.sh" hook
}
segs() { python3 "$BIN/fleet_id.py" get "$1" --json | python3 -c 'import json,sys
d=json.load(sys.stdin); print(" ".join("%s:%s:%s" % (s["native"], s["trigger"], s.get("attempt", 1)) for s in d["segments"]))'; }
take() { python3 "$BIN/fleet_id.py" take "$1"; }
lib() { bash -c '. "$1/fleet-lib.sh"; shift; "$@"' _ "$BIN" "$@"; }
st_() { FLEET_ID_LIVE="$1" python3 "$BIN/fleet_id.py" status "$2" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["state"], " ".join(d.get("conflict") or []))'; }

TF=aaaaaaaa-0000-4000-8000-0000000000c2      # the task's ID, minted by the hub with T9
OTHER=bbbbbbbb-0000-4000-8000-0000000000c2

# ---- TAKE ---------------------------------------------------------------------
hub "$TF" 200 "{\"id\":\"$TF\",\"seq\":0,\"machine\":\"\"}"
st_eq "TAKE: the hub's unpushed reservation is this window's to take" "first" "$(take "$TF")"
rm -f "$WORK/hub.$TF"
st_eq "TAKE: a hub with no row of it — take it" "first" "$(take "$TF")"
hub "$OTHER" 200 "{\"id\":\"$OTHER\",\"seq\":4,\"machine\":\"mac-b\"}"
got=$(take "$OTHER"); rc=$?
st_eq "TAKE: another machine pushed it — not here" "elsewhere 1" "$got $rc"
hub "$OTHER" 0 ""
st_eq "TAKE: a hub that did not answer — not here" "elsewhere" "$(take "$OTHER")"
python3 "$BIN/fleet_id.py" open "$TF" --task T9 --agent claude >/dev/null
st_eq "TAKE: a ledger here — a redo, here" "here" "$(take "$TF")"

# ---- LIB ----------------------------------------------------------------------
st_eq "LIB: \$FLEET_TASK_FID names the ID of its record" "$TF" "$(FLEET_TASK_FID="T9=$TF" lib fleet_task_fid T9)"
got=$(FLEET_TASK_FID="T9=$TF" lib fleet_task_fid T91); rc=$?
st_eq "LIB: …and never another record's (no hub here: none)" " 1" "$got $rc"
got=$(FLEET_TASK_FID="T9=$TF" lib fleet_task_take T9); rc=$?
st_eq "LIB: take — the ID and how" "$TF	here 0" "$got $rc"
got=$(FLEET_TASK_FID="T5=$OTHER" lib fleet_task_take T5); rc=$?
st_eq "LIB: another machine's — the ID for a prev, rc 2" "$OTHER	elsewhere 2" "$got $rc"
got=$(lib fleet_task_take nope); rc=$?
st_eq "LIB: not a record — rc 1" " 1" "$got $rc"

# ---- OPEN: the spawner's block, as dash-raw-session.sh runs it -----------------
sed -n '/^# A task.s window goes by the task.s own ID/,/^fi$/p' "$BIN/dash-raw-session.sh" > "$WORK/open.sh"
st_count; [ -s "$WORK/open.sh" ] || st_miss "OPEN: dash-raw-session.sh has the task-ID block"
run_open() { FLEET_TASK_FID="$1" TASK_REF="$2" PREV_ID="$3" REOPEN_FID='' bash -c '. "$1/fleet-lib.sh"; . "$2"; printf "%s|%s|%s" "$TASK_FID" "$TASK_TAKE" "$PREV_ID"' _ "$BIN" "$WORK/open.sh"; }
st_eq "OPEN: a redo here goes by the task's ID, no prev to itself" "$TF|here|" "$(run_open "T9=$TF" T9 "$TF")"
st_eq "OPEN: another machine's ID — a new one after it" "||$OTHER" "$(run_open "T5=$OTHER" T5 '')"
st_eq "OPEN: no task — nothing" "||" "$(run_open '' '' '')"

# ---- SEG: the recovery page's ↵ -----------------------------------------------
read -r W1 P1 <<EOF
$(newwin "$TF")
EOF
hook "$P1" startup dddd0001
tf set-window-option -t "$W1" @id_next_trigger "reopen:$(date +%s)"
hook "$P1" compact dddd0001
st_eq "SEG: a compaction leaves the reopen mark for the next start" "reopen" "$(opt "$W1" @id_next_trigger | cut -d: -f1)"
hook "$P1" resume dddd0001
st_eq "SEG: ↵ on the same conversation — a new segment, reopen" "dddd0001:startup:1 dddd0001:reopen:1" "$(segs "$TF")"
st_eq "SEG: the hook takes the mark off" "" "$(opt "$W1" @id_next_trigger)"
hook "$P1" resume dddd0001
st_eq "SEG: a retried hook with no mark adds nothing" "2" "$(segs "$TF" | wc -w | tr -d ' ')"
tf set-window-option -t "$W1" @id_next_trigger "reopen:1000"
hook "$P1" resume dddd0001
st_eq "SEG: a stale mark is nothing" "2" "$(segs "$TF" | wc -w | tr -d ' ')"

# ---- REDO ---------------------------------------------------------------------
python3 "$BIN/fleet_id.py" result "$TF" --state failed --summary '门禁红'
python3 "$BIN/fleet_id.py" close "$TF" --reason reaped
FLEET_ALLOW_TMUX_DESTROY=1 tf kill-window -t "$W1"
st_eq "REDO: before — attempt 1 failed" "failed " "$(st_ '' "$TF")"
st_eq "REDO: attempt opens the second" "2" "$(python3 "$BIN/fleet_id.py" attempt "$TF")"
read -r _ P2 <<EOF
$(newwin "$TF")
EOF
hook "$P2" startup eeee0001
st_eq "REDO: its first segment is a redo of attempt 2, the same ID" \
  "dddd0001:startup:1 dddd0001:reopen:1 eeee0001:redo:2" "$(segs "$TF")"
st_eq "REDO: the close is cleared, attempt 1's failure no longer counts" "running " "$(st_ "$TF" "$TF")"
FLEET_ID_LIVE="$TF" python3 "$BIN/fleet_id.py" await "$TF" --timeout 1 --interval 1 >/dev/null; rc=$?
st_eq "REDO: await waits on the new attempt" "3" "$rc"
python3 "$BIN/fleet_id.py" result "$TF" --state merged --pr 12
st_eq "REDO: attempt 2's merge is the task's" "done " "$(st_ "$TF" "$TF")"
st_has "REDO: get says 第 2 次" "$(python3 "$BIN/fleet_id.py" get "$TF")" "第 2 次"
F3=$(python3 -c 'import uuid; print(uuid.uuid4())'); python3 "$BIN/fleet_id.py" open "$F3" >/dev/null
st_eq "REDO: an ID that never started is still its first attempt" "1 1" \
  "$(python3 "$BIN/fleet_id.py" attempt "$F3") $(python3 "$BIN/fleet_id.py" attempt "$F3")"

# ---- TWO: two live windows on one task's ID -------------------------------------
st_eq "TWO: two live windows carrying it — a conflict" "conflict $TF" "$(st_ "$TF
$TF" "$TF")"
got=$(cd "$BIN" && python3 -c '
import fleet_view as v
a = {"kind": "sess", "fid": "X", "id": "K5F9", "state": "working"}
b = {"kind": "sess", "fid": "X", "id": "K5F9", "state": "done"}
c = {"kind": "sess", "fid": "X", "id": "K5F9", "gone": True, "state": "landed"}
v.id_conflicts([a, b, c])
print(a.get("group"), b.get("group"), c.get("group"))' 2>&1)
st_eq "TWO: both live rows red on the panel, the closed one left alone" "ask ask None" "$got"
got=$(cd "$BIN" && python3 -c '
import fleet_view as v
e = {"kind": "sess", "text": "修 bug"}
v.id_record = lambda f: {"opened": {}, "segments": [], "results": [{"state": "failed", "attempt": 1}], "closed": None, "attempt": 2}
v.id_hub = lambda f: ""
v.id_apply(e, "aaaaaaaa-0000-4000-8000-0000000000c2", set())
print(e["text"] == v.say("view_id_attempt_fmt", "修 bug", 2), "|", e.get("sym", "-"))' 2>&1 | tail -1)
st_eq "TWO: the row says 第 2 次, attempt 1's failure not drawn" "True | -" "$got"

# ---- WIRE ---------------------------------------------------------------------
st_count; grep -q 'fleet_task_take "$TASK_REF"' "$BIN/dash-raw-session.sh" && grep -q 'fleet_task_take "$TASK_REF"' "$BIN/dash-issue-session.sh" \
  || st_miss "WIRE: both spawners take the task's ID"
st_count; grep -q 'fleet_win_stamp_cmd @fleet_id "$TASK_FID"' "$BIN/dash-raw-session.sh" \
  || st_miss "WIRE: dash-raw-session.sh stamps it before the agent starts"
st_count; grep -q 'FLEET_TASK_FID="$t=$tfid"' "$BIN/fleet-task-record.sh" || st_miss "WIRE: the dispatch hands its record's ID"
st_count; grep -q '@id_next_trigger "reopen:' "$BIN/fleet-session-wrap.sh" || st_miss "WIRE: the recovery page's ↵ marks the reopen"
st_count; grep -q '@id_next_trigger "reopen:' "$BIN/fleet-restore.sh" || st_miss "WIRE: restore marks the reopen"
st_count; grep -q '@id_next_trigger "reopen:' "$BIN/fleet-migrate.sh" || st_miss "WIRE: migrate marks the reopen"

st_done "fleet-task-id selftest"
