#!/bin/bash
# fleet-id-results-selftest.sh — results, parents and messages hang on the ID
# (EPIC T497 C4; the design page's §4.3–§4.6). On an isolated tmux server and a
# sandbox conf dir, windows carry @fleet_id, `fleet-id.sh hook` is fed their
# SessionStarts and bin/fleet_id.py's ledger is read back:
#   S2    a result, a /clear, another result (the session's own report through
#         fleet-report-parent.sh — no parent at all): the ID stays, two results,
#         the status is the newest (失败)
#   S7    a window the fleet closes (fleet_win_retire … <why>) without a result:
#         the ID has closed, its status 已退出; a retire with no why (a move, a
#         migrate) leaves the ID open
#   S8    a closed ID's segment 2, 「从这一段继续」 (fleet-id.sh continue --exec): a
#         new window through the spawner with --resume <segment 2> --prev <ID>; the
#         spawn's open (--from-native) records prev; the old ID stays closed and
#         what was meant for it routes to the new one (successor)
#   S9    a live ID's segment resumed in another window: the new ID's prev points
#         back, both are in conflict (等你) while both live, closing one restores
#         the other
#   ROUTE a closed ID with no successor goes up its parent; nobody ⇒ rc 1; an ID
#         this ledger does not know is `unknown` (the caller's old road)
#   CLEAR historical parent links and successors never receive a report; /clear
#         and the session identity remain recorded. Dry runs save nothing.
#   AWAIT old await aliases return RETIRED without consulting or changing history
#   KIDS  the old children entry returns RETIRED and preserves the historical ID
#   TASKPAR a task dispatch's child ID names its parent however the parent came
#         (a keyless parent's ID as --origin, a handed-over worker_id; the hub none),
#         children lists it, and `fleet-id.sh parents` backfills an older one from
#         its hub record's parent_session (dry, --apply, rc 3 with no hub) — C9
#   BACKFILL a live window opened before C1 (no opened, no segment) gets both off its
#         options (`fleet-id.sh backfill`: dry, --apply, idempotent; home untouched) — C17
#   WT    a worktree remembers its ID beside its T record (fleet_worktree_id)
#   WIRE  the spawners open with --parent / --from-native / --worktree; the reap,
#         cleanup, stop and exit closers pass a why; a report writes the ID's
#         result; the retired receive path cannot route a queued parent report
#   NAMES stable short codes and task tool aliases remain readable; result dry
#         runs create no child-report envelope, with or without a task code
# tmux / python3 / git absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-repo-fixture.sh"
REAL_TMUX=$(command -v tmux) || { echo 'fleet-id-results selftest: tmux absent — SKIP'; exit 0; }
st_need python3 git

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-idr.XXXXXX")" || exit 2
L="fidr$$"
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
: > "$FLEET_CONF_DIR/fleets/$L/conf"
fx_repo "$FLEET_CONF_DIR" "$L" acme/app FLEET_MAIN="$WORK/main"
mkdir -p "$WORK/main"; cd "$WORK" || exit 2
export FLEET_ID_PUSH=0 FLEET_ORPHAN_ALERT_CMD=/usr/bin/true
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_CODEX_LAUNCHER_PID CLAUDE_CODE_ENTRYPOINT FLEET_ID_HOOK

st_tally
tf() { FLEET_ALLOW_TMUX_DESTROY=1 "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { FLEET_ALLOW_TMUX_DESTROY=1 "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
lib() { bash -c '. "$1/fleet-lib.sh"; shift; "$@"' _ "$BIN" "$@"; }

tf -f /dev/null new-session -d -s "$L" -n home 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'fleet-id-results selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
SOCKP=$(tf display-message -p '#{socket_path}')
SPID=$(tf display-message -p '#{pid}')
INT="TMUX=$SOCKP,$SPID,0"

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
    | env "$INT" TMUX_PANE="$pane" bash "$BIN/fleet-id.sh" hook
}
# fid <args…> — fleet-id.sh inside this fleet's tmux (its live scan sees these windows)
fid() { env "$INT" bash "$BIN/fleet-id.sh" "$@"; }
st() { fid status "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["state"], d["label"])'; }
nres() { python3 "$BIN/fleet_id.py" get "$1" --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["results"]))'; }
closed() { python3 "$BIN/fleet_id.py" get "$1" --json | python3 -c 'import json,sys; print("yes" if json.load(sys.stdin)["closed"] else "no")'; }
openedf() { python3 "$BIN/fleet_id.py" get "$1" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["opened"].get(sys.argv[1],""))' "$2"; }
mkfid() { python3 -c 'import uuid; print(uuid.uuid4())'; }

# ---- S2 · result, /clear, result -------------------------------------------------
F2=$(mkfid)
read -r W2 P2 <<EOF
$(newwin "$F2")
EOF
fid open "$F2" --window "$W2" --socket "$L" --agent claude --title 'S2 work' >/dev/null
hook "$P2" startup bbbb0001
out=$(env "$INT" TMUX_PANE="$P2" bash "$BIN/fleet-report-parent.sh" --state merged --summary 'done' 2>&1)
hook "$P2" clear bbbb0002
out=$(env "$INT" TMUX_PANE="$P2" bash "$BIN/fleet-report-parent.sh" --state failed --summary 'redo failed' 2>&1)
st_count; [ "$(tf show-options -wqv -t "$W2" @fleet_id)" = "$F2" ] || st_miss "S2: the ID changed across /clear"
st_count; [ "$(nres "$F2")" = 2 ] || st_miss "S2: two reports = two results on the ID" "$(nres "$F2") · $out"
st_count; [ "$(st "$F2")" = "failed 失败" ] || st_miss "S2: the status is the newest result (失败)" "$(st "$F2")"
st_count; python3 "$BIN/fleet_id.py" get "$F2" --json | grep -q '"agent": "claude"' || st_miss "S2: the result names its agent"

# ---- S7 · the fleet closes a window that never reported ---------------------------
F7=$(mkfid)
read -r W7 P7 <<EOF
$(newwin "$F7")
EOF
fid open "$F7" --window "$W7" --socket "$L" --agent codex >/dev/null
hook "$P7" startup cccc0001
st_count; [ "$(st "$F7")" = "running 运行中" ] || st_miss "S7: a live window with no result runs" "$(st "$F7")"
lib fleet_win_retire "$W7" "$L"   # a move / migrate: no why
st_count; [ "$(closed "$F7")" = no ] || st_miss "S7: a retire with no why (move, migrate) leaves the ID open"
lib fleet_win_retire "$W7" "$L" reaped
tf kill-window -t "$W7"
st_count; [ "$(closed "$F7")" = yes ] || st_miss "S7: a reap ends the ID"
st_count; [ "$(st "$F7")" = "exited 已退出" ] || st_miss "S7: closed with no result = 已退出" "$(st "$F7")"
st_count; [ -e "$(lib fleet_retired_dir)/$F7" ] || st_miss "S7: the retired mark is still written"

# ---- S8 · continue from segment 2 of a closed ID ---------------------------------
F8=$(mkfid)
read -r W8 P8 <<EOF
$(newwin "$F8")
EOF
fid open "$F8" --window "$W8" --socket "$L" --agent claude --title 'S8 work' >/dev/null
hook "$P8" startup dddd0001
hook "$P8" clear dddd0002-1111-4111-8111-111111111111
hook "$P8" clear dddd0003
lib fleet_win_retire "$W8" "$L" exited; tf kill-window -t "$W8"
plan=$(fid continue "$F8" --seg 2)
st_count; printf '%s' "$plan" | grep -q '"native": "dddd0002-1111-4111-8111-111111111111"' || st_miss "S8: segment 2's native id is the plan" "$plan"
cat > "$WORK/spawn.sh" <<'SP'
printf '%s\n' "$@" > "$FLEET_TEST_SPAWNED"
SP
# A resume must verify the exact native segment before opening a window.
export CLAUDE_PROJECTS_DIR="$WORK/claude-projects"
mkdir -p "$CLAUDE_PROJECTS_DIR/project"
printf '{"sessionId":"dddd0002-1111-4111-8111-111111111111"}\n' > "$CLAUDE_PROJECTS_DIR/project/dddd0002-1111-4111-8111-111111111111.jsonl"
printf '{"sessionId":"dddd0101-1111-4111-8111-111111111111"}\n' > "$CLAUDE_PROJECTS_DIR/project/dddd0101-1111-4111-8111-111111111111.jsonl"
FLEET_TEST_SPAWNED="$WORK/spawned" FLEET_ID_SPAWN="$WORK/spawn.sh" fid continue "$F8" --seg 2 --exec
st_count; tr '\n' ' ' < "$WORK/spawned" | grep -q -- "--resume dddd0002-1111-4111-8111-111111111111 .*--no-repo.*--prev $F8" \
  || st_miss "S8: --exec opens a window resuming segment 2 with --prev <ID>" "$(tr '\n' ' ' < "$WORK/spawned" 2>/dev/null)"
st_count; ! grep -q -- '--id-task' "$WORK/spawned" || st_miss "S8: an ID with no record carries none"
# C18: an EPIC driver's ID (its record T<n>, its parent) continued — the new
# window carries both: @task and the ledger's task / parent
F8T=$(mkfid) F8P=$(mkfid)
read -r W8T P8T <<EOF
$(newwin "$F8T")
EOF
fid open "$F8T" --window "$W8T" --socket "$L" --agent claude --title 'EPIC: driver' --task T580 --parent "$F8P" >/dev/null
hook "$P8T" startup dddd0101-1111-4111-8111-111111111111
lib fleet_win_retire "$W8T" "$L" exited; tf kill-window -t "$W8T"
FLEET_TEST_SPAWNED="$WORK/spawned-t" FLEET_ID_SPAWN="$WORK/spawn.sh" fid continue "$F8T" --exec
st_count; tr '\n' ' ' < "$WORK/spawned-t" | grep -q -- "--id-task T580 --id-parent $F8P .*--prev $F8T" \
  || st_miss "S8: a driver's continue carries its record and parent (C18)" "$(tr '\n' ' ' < "$WORK/spawned-t" 2>/dev/null)"
G8=$(mkfid)
read -r WG8 PG8 <<EOF
$(newwin "$G8")
EOF
fid open "$G8" --window "$WG8" --socket "$L" --agent claude --from-native dddd0002-1111-4111-8111-111111111111 >/dev/null
hook "$PG8" resume dddd0002-1111-4111-8111-111111111111
st_count; [ "$(openedf "$G8" prev)" = "$F8" ] || st_miss "S8: the new ID's prev is the old one" "$(openedf "$G8" prev)"
st_count; [ "$G8" != "$F8" ] && [ "$(closed "$F8")" = yes ] || st_miss "S8: the old ID stays closed"
st_count; [ "$(fid route "$F8")" = "$G8	successor" ] || st_miss "S8: what was meant for the closed ID goes to its successor" "$(fid route "$F8")"
FLEET_TEST_SPAWNED="$WORK/spawned2" FLEET_ID_SPAWN="$WORK/spawn.sh" fid reopen "$G8" --exec 2>/dev/null; rc=$?
st_count; [ "$rc" != 0 ] && [ ! -e "$WORK/spawned2" ] || st_miss "S8: reopen refuses an ID still open in a window"

# ---- S9 · one native segment live in two windows ---------------------------------
F9=$(mkfid); G9=$(mkfid)
read -r W9 P9 <<EOF
$(newwin "$F9")
EOF
read -r WG9 PG9 <<EOF
$(newwin "$G9")
EOF
fid open "$F9" --window "$W9" --socket "$L" --agent claude >/dev/null
hook "$P9" startup eeee0001
fid open "$G9" --window "$WG9" --socket "$L" --agent claude >/dev/null
hook "$PG9" resume eeee0001        # a hand `claude --resume` in another window
st_count; [ "$(openedf "$G9" prev)" = "$F9" ] || st_miss "S9: the resuming window's ID points back (prev)" "$(openedf "$G9" prev)"
st_count; [ "$(st "$F9")" = "conflict 等你" ] && [ "$(st "$G9")" = "conflict 等你" ] \
  || st_miss "S9: both live ⇒ both in conflict (等你)" "$(st "$F9") / $(st "$G9")"
lib fleet_win_retire "$WG9" "$L" closed; tf kill-window -t "$WG9"
st_count; [ "$(st "$F9")" = "running 运行中" ] || st_miss "S9: closing one restores the other" "$(st "$F9")"

# ---- ROUTE · up the parent; nobody ------------------------------------------------
PP=$(mkfid); P=$(mkfid)
read -r WPP _ <<EOF
$(newwin "$PP")
EOF
fid open "$PP" --window "$WPP" --socket "$L" >/dev/null
python3 "$BIN/fleet_id.py" open "$P" --parent "$PP" >/dev/null
python3 "$BIN/fleet_id.py" close "$P" --reason reaped
st_count; [ "$(fid route "$P")" = "$PP	parent" ] || st_miss "ROUTE: a closed ID with no successor goes up its parent" "$(fid route "$P")"
lib fleet_win_retire "$WPP" "$L" reaped; tf kill-window -t "$WPP"
fid route "$P" >/dev/null; rc=$?
st_count; [ "$rc" = 1 ] || st_miss "ROUTE: nobody open up the chain ⇒ rc 1 (the person's reminder)" "$rc"
U=$(mkfid); r=$(fid route "$U")
st_count; [ "${r#*	}" = unknown ] || st_miss "ROUTE: an ID with no ledger here is unknown (the old road)" "$r"

# ---- CLEAR · a child's report after the parent's /clear --------------------------
PA=$(mkfid); CH=$(mkfid)
read -r WPA PPA <<EOF
$(newwin "$PA")
EOF
read -r WCH PCH <<EOF
$(newwin "$CH")
EOF
fid open "$PA" --window "$WPA" --socket "$L" --agent claude >/dev/null
hook "$PPA" startup ffff0001
fid open "$CH" --window "$WCH" --socket "$L" --agent claude --parent "$PA" >/dev/null
tf set-window-option -t "$WCH" @origin "$PA"
tf set-window-option -t "$WCH" @origin_fid "$PA"
hook "$PPA" clear ffff0002       # the parent clears its conversation
out=$(env "$INT" TMUX_PANE="$PCH" bash "$BIN/fleet-report-parent.sh" --dry-run --state merged --summary 'kid done' 2>&1)
st_count; case "$out" in *'RETIRED: Parent reports are disabled; would save own result '*) true ;; *) false ;; esac \
  && ! printf '%s' "$out" | grep -Fq "$WPA" || st_miss "CLEAR: parent /clear does not enable report delivery" "$out"
# NAMES: ID and task codes remain usable independently of retired report envelopes.
chc=$(fid short "$CH")
st_count; [ -n "$chc" ] && [ "$(fid short "$CH")" = "$chc" ] && ! printf '%s' "$out" | grep -q '^\[child-report\]' \
  || st_miss "NAMES: stable ID code remains, report envelope is retired" "$out"
tf set-window-option -t "$WCH" @task T777
out=$(env "$INT" TMUX_PANE="$PCH" bash "$BIN/fleet-report-parent.sh" --dry-run --state merged --summary 'kid done' 2>&1)
st_count; printf '%s' "$out" | grep -q 'RETIRED: Parent reports are disabled' \
  && ! printf '%s' "$out" | grep -q '^\[child-report\]' && [ "$(fid short "$CH")" = "$chc" ] \
  || st_miss "NAMES: task without a known code cannot produce a parent report" "$out"
BOOK="${FLEET_ID_DIR:-$FLEET_CONF_DIR/ids}/task-codes.tsv"; mkdir -p "${BOOK%/*}"
printf 'T777\tK7W0\t%s\n' "$CH" > "$BOOK"
out=$(env "$INT" TMUX_PANE="$PCH" bash "$BIN/fleet-report-parent.sh" --dry-run --state merged --summary 'kid done' 2>&1)
st_count; printf '%s' "$out" | grep -q 'RETIRED: Parent reports are disabled' \
  && ! printf '%s' "$out" | grep -q '^\[child-report\]' \
  || st_miss "NAMES: known task code cannot restore a report envelope" "$out"
st_count; ! printf '%s' "$out" | grep -q "^\[child-report\].*T777" || st_miss "NAMES: T<n> never on the header" "$out"
tf set-window-option -u -t "$WCH" @task
# Historical labels and the task tool still name sessions by code, with the
# record retained as an alias. This formatting cannot deliver a parent report.
r=$(python3 - "$BIN" "$CH" "$chc" <<'PY' 2>&1
import importlib.util, sys
sys.path.insert(0, sys.argv[1])
import fleet_task_control as tc
assert tc.child_label({"task": "T777", "worker_id": "u/" + sys.argv[2]}) == "#K7W0", tc.child_label({"task": "T777", "worker_id": "u/" + sys.argv[2]})
assert tc.child_label({"task": "T776", "worker_id": "u/" + sys.argv[2]}) == "#" + sys.argv[3]
assert tc.child_label({"task": "T776", "worker_id": "u/issue-4"}) == "T776"
spec = importlib.util.spec_from_file_location("fleet_mcp", sys.argv[1] + "/fleet-mcp.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.run = lambda argv, **kw: type("R", (), {"returncode": 0, "stdout": "T777\nwindow @5\n", "stderr": ""})()
m.hub_env = lambda *a, **k: None
m.tmux = lambda *a: "T776\tx\nT777\t" + sys.argv[2]
out = m.tool_task({"title": "t", "repo": "o/r", "spawn": True})
assert out["id"] == sys.argv[3] and out["alias"] == "T777" and out["session_id"] == sys.argv[2], out
# a hub with task codes (EPIC T644 C3): `id` is the task's code, T<n> only the alias
m.run = lambda argv, **kw: type("R", (), {"returncode": 0, "stdout": "K7W0\nT777\nwindow @5\n", "stderr": ""})()
out = m.tool_task({"title": "t", "repo": "o/r", "spawn": True})
assert out["id"] == "K7W0" and out["short"] == "K7W0" and out["alias"] == "T777" and out["task"] == "T777" \
    and out["session_id"] == sys.argv[2], out
out = m.tool_task({"title": "t", "repo": "o/r"})
assert out["id"] == "K7W0" and "session_id" not in out, out
print("ok")
PY
)
st_count; [ "$r" = ok ] || st_miss "NAMES: receive's header and the task tool's answer lead with the code" "$r"
rm -f "$BOOK"
# A historical parent closes and a successor continues it; neither gets reports.
lib fleet_win_retire "$WPA" "$L" exited; tf kill-window -t "$WPA"
SU=$(mkfid)
read -r WSU _ <<EOF
$(newwin "$SU")
EOF
fid open "$SU" --window "$WSU" --socket "$L" --agent claude --prev "$PA" >/dev/null
out=$(env "$INT" TMUX_PANE="$PCH" bash "$BIN/fleet-report-parent.sh" --dry-run --state merged --summary 'kid done' 2>&1)
st_count; printf '%s' "$out" | grep -q 'RETIRED: Parent reports are disabled' \
  && ! printf '%s' "$out" | grep -Fq "$WSU" || st_miss "CLEAR: historical successor receives no report" "$out"
lib fleet_win_retire "$WSU" "$L" exited; tf kill-window -t "$WSU"
out=$(env "$INT" TMUX_PANE="$PCH" bash "$BIN/fleet-report-parent.sh" --dry-run --state merged --summary 'kid done' 2>&1)
st_count; printf '%s' "$out" | grep -q 'RETIRED: Parent reports are disabled' \
  && ! printf '%s' "$out" | grep -q 'would file' && [ "$(nres "$CH")" = 0 ] \
  || st_miss "CLEAR: no parent creates neither a reminder nor a dry-run result" "$out"
# the ledger fold: the parent ID's segments say clear, the ID did not change
st_count; python3 "$BIN/fleet_id.py" get "$PA" --json | grep -q '"trigger": "clear"' || st_miss "CLEAR: the parent's /clear is a segment of the same ID"

# ---- AWAIT -------------------------------------------------------------------------
A1=$(mkfid); A2=$(mkfid); A3=$(mkfid)
python3 "$BIN/fleet_id.py" open "$A1" >/dev/null; python3 "$BIN/fleet_id.py" result "$A1" --state merged --pr 9 --summary ok
python3 "$BIN/fleet_id.py" open "$A2" >/dev/null; python3 "$BIN/fleet_id.py" close "$A2" --reason reaped
python3 "$BIN/fleet_id.py" open "$A3" >/dev/null; python3 "$BIN/fleet_id.py" result "$A3" --state waiting
c1=$(python3 "$BIN/fleet_id.py" short "$A1")
for ref in "$c1" "#$(printf '%s' "$c1" | tr 'A-Z' 'a-z')" "fid:$A2" "$A3"; do
  out=$(env "$INT" bash "$BIN/fleet-await.sh" "$ref" --timeout 5 --interval 1); rc=$?
  st_count; [ "$rc" = 2 ] && case "$out" in RETIRED:*) true ;; *) false ;; esac \
    || st_miss "AWAIT: historical ID/code alias returns retirement immediately" "$rc · $out"
done
st_count; [ "$(nres "$A1")" = 1 ] && [ "$(closed "$A2")" = yes ] && [ "$(nres "$A3")" = 1 ] \
  || st_miss "AWAIT: completed, closed and waiting historical records remain"

# ---- KIDS --------------------------------------------------------------------------
out=$(env "$INT" bash "$BIN/fleet-children.sh" --ids "$PA"); rc=$?
st_count; [ "$rc" = 2 ] && case "$out" in RETIRED:*) true ;; *) false ;; esac \
  && [ "$(openedf "$CH" parent)" = "$PA" ] || st_miss "KIDS: retired command leaves historical parent metadata intact" "$rc · $out"

# ---- WT ----------------------------------------------------------------------------
git init -q "$WORK/wt" 2>/dev/null
lib fleet_worktree_id_mark "$WORK/wt" "$F2"
st_count; [ "$(lib fleet_worktree_id "$WORK/wt")" = "$F2" ] || st_miss "WT: a worktree remembers its ID"
st_count; ! lib fleet_worktree_id_mark "$WORK/wt" T12 || st_miss "WT: a non-ID is refused"

# ---- TASKPAR · a task dispatch's child ID names its parent (C9) --------------------
# A keyless parent (an orchestrator, a driver) dispatches with ITS ID as --origin;
# a hub-placed start hands a worker_id over; the hub itself names none.
TP=$(mkfid); TC=$(mkfid)
read -r WTP _ <<EOF
$(newwin "$TP")
EOF
fid open "$TP" --window "$WTP" --socket "$L" >/dev/null
st_count; [ "$(lib fleet_spawn_parent_id "$L" "$TP" '' "$L")" = "$TP" ] || st_miss "TASKPAR: a keyless parent's ID as --origin is the parent"
st_count; [ "$(lib fleet_spawn_parent_id "$L" '' "u-u-i-d/$TP" "$L")" = "$TP" ] || st_miss "TASKPAR: a handed-over worker_id's ID is the parent"
st_count; ! lib fleet_spawn_parent_id "$L" issue-3 "u-u-i-d/issue-3" "$L" >/dev/null || st_miss "TASKPAR: a worker_id naming only a key is no parent here"
st_count; ! lib fleet_spawn_parent_id "$L" hub '' "$L" >/dev/null && ! lib fleet_spawn_parent_id "$L" '' '' "$L" >/dev/null \
  || st_miss "TASKPAR: the hub names no parent"
fid open "$TC" --task T77 --parent "$(lib fleet_spawn_parent_id "$L" "$TP" '' "$L")" >/dev/null
st_count; fid children "$TP" | grep -q '^1 children' || st_miss "TASKPAR: children lists the dispatched ID" "$(fid children "$TP")"
# backfill: an ID opened for T78 before C9, no parent; its record names one
TB=$(mkfid)
python3 "$BIN/fleet_id.py" open "$TB" --task T78 --agent codex >/dev/null
cat > "$WORK/taskget" <<EOS
#!/bin/sh
[ "\$1" = T78 ] && printf '{"task":{"id":"T78","parent_session":"u-u-i-d/$TP"}}\n' && exit 0
printf '{"task":{"id":"\$1"}}\n'
EOS
chmod +x "$WORK/taskget"
out=$(FLEET_ID_TASK_GET="$WORK/taskget" fid parents 2>&1)
st_count; printf '%s' "$out" | grep -q "T78  → $TP  (dry)" && [ -z "$(openedf "$TB" parent)" ] \
  || st_miss "TASKPAR: the backfill is dry by default" "$out"
out=$(FLEET_ID_TASK_GET="$WORK/taskget" fid parents --apply 2>&1)
st_count; [ "$(openedf "$TB" parent)" = "$TP" ] || st_miss "TASKPAR: --apply fills the record's parent" "$out"
st_count; [ "$(openedf "$TB" task)" = T78 ] && [ "$(openedf "$TB" agent)" = codex ] || st_miss "TASKPAR: the fill keeps what opened said"
st_count; fid children "$TP" | grep -q '^2 children' || st_miss "TASKPAR: the filled ID is a child" "$(fid children "$TP")"
out=$(FLEET_ID_TASK_GET="$WORK/taskget" fid parents 2>&1)
st_count; printf '%s' "$out" | grep -q '^0 without a parent' || st_miss "TASKPAR: a second pass finds nothing" "$out"
printf '#!/bin/sh\nexit 3\n' > "$WORK/taskget3"; chmod +x "$WORK/taskget3"
python3 "$BIN/fleet_id.py" open "$(mkfid)" --task T79 >/dev/null
FLEET_ID_TASK_GET="$WORK/taskget3" fid parents >/dev/null 2>&1; rc=$?
st_count; [ "$rc" = 3 ] || st_miss "TASKPAR: no hub here ⇒ rc 3" "$rc"

# ---- BACKFILL (C17) ---------------------------------------------------------------
# A live window opened before C1: its ledger has only a progress word (no opened, no
# segment). backfill (dry, then --apply) writes opened off the window's options and
# its current native session as segment 1 migrated; a second pass writes nothing; a
# window with a full ledger and home are left alone.
BF=$(mkfid); BC=$(mkfid); BH=$(mkfid)
python3 "$BIN/fleet_id.py" progress "$BF" --summary tick >/dev/null
python3 "$BIN/fleet_id.py" open "$BC" --agent claude --window @71 >/dev/null
python3 "$BIN/fleet_id.py" native "$BC" --agent claude --native nat-full --source startup >/dev/null
printf 'L\t%s\t@70\tcodex\tacme/app\t%s/wt-70\tT88\t\tcx-thread-70\t\tworker\n' "$BF" "$WORK" > "$WORK/bfrows"
printf 'L\t%s\t@71\tclaude\tacme/app\t\t\tnat-full\t\t\tworker\n' "$BC" >> "$WORK/bfrows"
printf 'L\t%s\t@72\t\t\t\t\tnat-home\t\t\thome\n' "$BH" >> "$WORK/bfrows"
bfill() { FLEET_ID_BACKFILL_CMD="cat '$WORK/bfrows'" fid backfill "$@" 2>&1; }
out=$(bfill)
st_count; printf '%s' "$out" | grep -q '@70  codex  opened + 段 1 migrated  (dry)' && printf '%s' "$out" | grep -q '^1 to backfill' \
  && [ -z "$(openedf "$BF" agent)" ] || st_miss "BACKFILL: dry by default, only the pre-C1 window" "$out"
out=$(bfill --apply)
st_count; [ "$(openedf "$BF" agent)" = codex ] && [ "$(openedf "$BF" window)" = @70 ] && [ "$(openedf "$BF" task)" = T88 ] \
  && [ "$(openedf "$BF" repo)" = acme/app ] && [ "$(openedf "$BF" worktree)" = "$WORK/wt-70" ] \
  || st_miss "BACKFILL: opened takes the window's options" "$(python3 "$BIN/fleet_id.py" get "$BF" --json)"
got=$(fid get "$BF")
st_count; printf '%s' "$got" | grep -q 'agent codex' && printf '%s' "$got" | grep -Eq '段 1  codex +cx-thread-70 .* migrated' \
  && ! printf '%s' "$got" | grep -q 'opened ?' || st_miss "BACKFILL: get lists opened and segment 1 migrated" "$got"
st_count; [ "$(python3 "$BIN/fleet_id.py" get "$BC" --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["segments"]), d["segments"][0]["trigger"])')" = "1 startup" ] \
  && [ ! -f "$FLEET_CONF_DIR/ids/$BH.ndjson" ] || st_miss "BACKFILL: a full ledger and home are left alone"
n1=$(wc -l < "$FLEET_CONF_DIR/ids/$BF.ndjson"); out=$(bfill --apply)
st_count; printf '%s' "$out" | grep -q '^0 to backfill' && [ "$(wc -l < "$FLEET_CONF_DIR/ids/$BF.ndjson")" = "$n1" ] \
  || st_miss "BACKFILL: a second pass writes nothing" "$out"

# ---- WIRE --------------------------------------------------------------------------
st_count; grep -q -- '--parent "\$_idpar"' "$BIN/dash-raw-session.sh" && grep -q -- '--parent "\$_idpar"' "$BIN/dash-issue-session.sh" \
  || st_miss "WIRE: both spawners open the ID with its parent"
st_count; [ "$(grep -c '_idpar=$(fleet_spawn_parent_id "$SESS" "$ORIGIN" "$ORIGIN_WID" "$SOCK")' "$BIN/dash-raw-session.sh" "$BIN/dash-issue-session.sh" | grep -c ':1$')" = 2 ] \
  || st_miss "WIRE: both spawners take the parent from --origin too, not only a handed-over worker_id (C9)"
st_count; grep -q -- '--from-native "\$RESUME_SID"' "$BIN/dash-raw-session.sh" || st_miss "WIRE: a --resume spawn records prev"
st_count; grep -q 'fleet_win_retire "\$target" "" reaped' "$BIN/dash-reap.sh" \
  && grep -q 'fleet_win_retire "\$WIN" "\$(fleet_socket "\$FLEET_SESSION")" landed' "$BIN/fleet-cleanup.sh" \
  && grep -q 'fleet_win_retire "\$wid" "\$SOCK" stopped' "$BIN/fleet-worker-stop.sh" \
  && grep -q 'fleet_win_retire "\$win" "" exited' "$BIN/session-end-hook.sh" \
  || st_miss "WIRE: the reap / cleanup / stop / exit closers end the ID"
st_count; grep -q 'fleet_reap_policy.py" report-finish "\$selffid"' "$BIN/fleet-report-parent.sh" \
  && grep -q 'fleet_id.append(fid, ev)' "$BIN/fleet_reap_policy.py" \
  && ! grep -q 'fleet_id_take' "$BIN/fleet_task_control.py" \
  || st_miss "WIRE: own result remains recorded; retired receive cannot route by ID"
st_count; grep -q 'trap id_result EXIT' "$BIN/fleet-report-parent.sh" || st_miss "WIRE: a session's own report writes its result"

st_done
