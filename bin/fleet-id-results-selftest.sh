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
#   CLEAR a child's report after its parent's /clear (a new native segment) still
#         names the parent's window — by its ID — and a parent closed with a
#         successor hands it there (fleet-report-parent.sh --dry-run)
#   AWAIT fleet-await.sh T-<code>: a result answers (rc 0 merged / 1 failed), a
#         close with none is EXITED (4), nothing is TIMEOUT (3)
#   KIDS  fleet-children.sh --ids lists the IDs whose parent it is
#   TASKPAR a task dispatch's child ID names its parent however the parent came
#         (a keyless parent's ID as --origin, a handed-over worker_id; the hub none),
#         children lists it, and `fleet-id.sh parents` backfills an older one from
#         its hub record's parent_session (dry, --apply, rc 3 with no hub) — C9
#   BACKFILL a live window opened before C1 (no opened, no segment) gets both off its
#         options (`fleet-id.sh backfill`: dry, --apply, idempotent; home untouched) — C17
#   WT    a worktree remembers its ID beside its T record (fleet_worktree_id)
#   WIRE  the spawners open with --parent / --from-native / --worktree; the reap,
#         cleanup, stop and exit closers pass a why; the accepted-task road writes
#         the result and routes by ID (no generation / native gate)
# tmux / python3 / git absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-repo-fixture.sh"
REAL_TMUX=$(command -v tmux) || { echo 'fleet-id-results selftest: tmux absent — SKIP'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'fleet-id-results selftest: python3 absent — SKIP'; exit 0; }
command -v git >/dev/null 2>&1 || { echo 'fleet-id-results selftest: git absent — SKIP'; exit 0; }

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

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
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
ok; [ "$(tf show-options -wqv -t "$W2" @fleet_id)" = "$F2" ] || fail "S2: the ID changed across /clear"
ok; [ "$(nres "$F2")" = 2 ] || fail "S2: two reports = two results on the ID" "$(nres "$F2") · $out"
ok; [ "$(st "$F2")" = "failed 失败" ] || fail "S2: the status is the newest result (失败)" "$(st "$F2")"
ok; python3 "$BIN/fleet_id.py" get "$F2" --json | grep -q '"agent": "claude"' || fail "S2: the result names its agent"

# ---- S7 · the fleet closes a window that never reported ---------------------------
F7=$(mkfid)
read -r W7 P7 <<EOF
$(newwin "$F7")
EOF
fid open "$F7" --window "$W7" --socket "$L" --agent codex >/dev/null
hook "$P7" startup cccc0001
ok; [ "$(st "$F7")" = "running 运行中" ] || fail "S7: a live window with no result runs" "$(st "$F7")"
lib fleet_win_retire "$W7" "$L"   # a move / migrate: no why
ok; [ "$(closed "$F7")" = no ] || fail "S7: a retire with no why (move, migrate) leaves the ID open"
lib fleet_win_retire "$W7" "$L" reaped
tf kill-window -t "$W7"
ok; [ "$(closed "$F7")" = yes ] || fail "S7: a reap ends the ID"
ok; [ "$(st "$F7")" = "exited 已退出" ] || fail "S7: closed with no result = 已退出" "$(st "$F7")"
ok; [ -e "$(lib fleet_retired_dir)/$F7" ] || fail "S7: the retired mark is still written"

# ---- S8 · continue from segment 2 of a closed ID ---------------------------------
F8=$(mkfid)
read -r W8 P8 <<EOF
$(newwin "$F8")
EOF
fid open "$F8" --window "$W8" --socket "$L" --agent claude --title 'S8 work' >/dev/null
hook "$P8" startup dddd0001
hook "$P8" clear dddd0002
hook "$P8" clear dddd0003
lib fleet_win_retire "$W8" "$L" exited; tf kill-window -t "$W8"
plan=$(fid continue "$F8" --seg 2)
ok; printf '%s' "$plan" | grep -q '"native": "dddd0002"' || fail "S8: segment 2's native id is the plan" "$plan"
cat > "$WORK/spawn.sh" <<'SP'
printf '%s\n' "$@" > "$FLEET_TEST_SPAWNED"
SP
FLEET_TEST_SPAWNED="$WORK/spawned" FLEET_ID_SPAWN="$WORK/spawn.sh" fid continue "$F8" --seg 2 --exec
ok; tr '\n' ' ' < "$WORK/spawned" | grep -q -- "--resume dddd0002 .*--no-repo.*--prev $F8" \
  || fail "S8: --exec opens a window resuming segment 2 with --prev <ID>" "$(tr '\n' ' ' < "$WORK/spawned" 2>/dev/null)"
ok; ! grep -q -- '--id-task' "$WORK/spawned" || fail "S8: an ID with no record carries none"
# C18: an EPIC driver's ID (its record T<n>, its parent) continued — the new
# window carries both: @task and the ledger's task / parent
F8T=$(mkfid) F8P=$(mkfid)
read -r W8T P8T <<EOF
$(newwin "$F8T")
EOF
fid open "$F8T" --window "$W8T" --socket "$L" --agent claude --title 'EPIC: driver' --task T580 --parent "$F8P" >/dev/null
hook "$P8T" startup dddd0101
lib fleet_win_retire "$W8T" "$L" exited; tf kill-window -t "$W8T"
FLEET_TEST_SPAWNED="$WORK/spawned-t" FLEET_ID_SPAWN="$WORK/spawn.sh" fid continue "$F8T" --exec
ok; tr '\n' ' ' < "$WORK/spawned-t" | grep -q -- "--id-task T580 --id-parent $F8P .*--prev $F8T" \
  || fail "S8: a driver's continue carries its record and parent (C18)" "$(tr '\n' ' ' < "$WORK/spawned-t" 2>/dev/null)"
G8=$(mkfid)
read -r WG8 PG8 <<EOF
$(newwin "$G8")
EOF
fid open "$G8" --window "$WG8" --socket "$L" --agent claude --from-native dddd0002 >/dev/null
hook "$PG8" resume dddd0002
ok; [ "$(openedf "$G8" prev)" = "$F8" ] || fail "S8: the new ID's prev is the old one" "$(openedf "$G8" prev)"
ok; [ "$G8" != "$F8" ] && [ "$(closed "$F8")" = yes ] || fail "S8: the old ID stays closed"
ok; [ "$(fid route "$F8")" = "$G8	successor" ] || fail "S8: what was meant for the closed ID goes to its successor" "$(fid route "$F8")"
FLEET_TEST_SPAWNED="$WORK/spawned2" FLEET_ID_SPAWN="$WORK/spawn.sh" fid reopen "$G8" --exec 2>/dev/null; rc=$?
ok; [ "$rc" != 0 ] && [ ! -e "$WORK/spawned2" ] || fail "S8: reopen refuses an ID still open in a window"

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
ok; [ "$(openedf "$G9" prev)" = "$F9" ] || fail "S9: the resuming window's ID points back (prev)" "$(openedf "$G9" prev)"
ok; [ "$(st "$F9")" = "conflict 等你" ] && [ "$(st "$G9")" = "conflict 等你" ] \
  || fail "S9: both live ⇒ both in conflict (等你)" "$(st "$F9") / $(st "$G9")"
lib fleet_win_retire "$WG9" "$L" closed; tf kill-window -t "$WG9"
ok; [ "$(st "$F9")" = "running 运行中" ] || fail "S9: closing one restores the other" "$(st "$F9")"

# ---- ROUTE · up the parent; nobody ------------------------------------------------
PP=$(mkfid); P=$(mkfid)
read -r WPP _ <<EOF
$(newwin "$PP")
EOF
fid open "$PP" --window "$WPP" --socket "$L" >/dev/null
python3 "$BIN/fleet_id.py" open "$P" --parent "$PP" >/dev/null
python3 "$BIN/fleet_id.py" close "$P" --reason reaped
ok; [ "$(fid route "$P")" = "$PP	parent" ] || fail "ROUTE: a closed ID with no successor goes up its parent" "$(fid route "$P")"
lib fleet_win_retire "$WPP" "$L" reaped; tf kill-window -t "$WPP"
fid route "$P" >/dev/null; rc=$?
ok; [ "$rc" = 1 ] || fail "ROUTE: nobody open up the chain ⇒ rc 1 (the person's reminder)" "$rc"
U=$(mkfid); r=$(fid route "$U")
ok; [ "${r#*	}" = unknown ] || fail "ROUTE: an ID with no ledger here is unknown (the old road)" "$r"

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
ok; printf '%s' "$out" | grep -q "($WPA" || fail "CLEAR: after the parent's /clear the report still names its window" "$out"
# the parent closes; a successor continues it — the report goes there
lib fleet_win_retire "$WPA" "$L" exited; tf kill-window -t "$WPA"
SU=$(mkfid)
read -r WSU _ <<EOF
$(newwin "$SU")
EOF
fid open "$SU" --window "$WSU" --socket "$L" --agent claude --prev "$PA" >/dev/null
out=$(env "$INT" TMUX_PANE="$PCH" bash "$BIN/fleet-report-parent.sh" --dry-run --state merged --summary 'kid done' 2>&1)
ok; printf '%s' "$out" | grep -q "($WSU" || fail "CLEAR: a closed parent's report goes to its successor's window" "$out"
lib fleet_win_retire "$WSU" "$L" exited; tf kill-window -t "$WSU"
out=$(env "$INT" TMUX_PANE="$PCH" bash "$BIN/fleet-report-parent.sh" --dry-run --state merged --summary 'kid done' 2>&1)
ok; printf '%s' "$out" | grep -q "would file MERGED for the person" || fail "CLEAR: nobody to take it ⇒ the person's reminder" "$out"
# the ledger fold: the parent ID's segments say clear, the ID did not change
ok; python3 "$BIN/fleet_id.py" get "$PA" --json | grep -q '"trigger": "clear"' || fail "CLEAR: the parent's /clear is a segment of the same ID"

# ---- AWAIT -------------------------------------------------------------------------
A1=$(mkfid); A2=$(mkfid); A3=$(mkfid)
python3 "$BIN/fleet_id.py" open "$A1" >/dev/null; python3 "$BIN/fleet_id.py" result "$A1" --state merged --pr 9 --summary ok
python3 "$BIN/fleet_id.py" open "$A2" >/dev/null; python3 "$BIN/fleet_id.py" close "$A2" --reason reaped
python3 "$BIN/fleet_id.py" open "$A3" >/dev/null; python3 "$BIN/fleet_id.py" result "$A3" --state waiting
c1=$(python3 "$BIN/fleet_id.py" short "$A1")
out=$(env "$INT" bash "$BIN/fleet-await.sh" "$c1" --timeout 5 --interval 1); rc=$?
ok; [ "$rc" = 0 ] && printf '%s' "$out" | head -1 | grep -qx MERGED && printf '%s' "$out" | grep -q 'pr: #9' \
  || fail "AWAIT: a merged result answers MERGED (0)" "$rc · $out"
out=$(env "$INT" bash "$BIN/fleet-await.sh" "fid:$A2" --timeout 5 --interval 1); rc=$?
ok; [ "$rc" = 4 ] && printf '%s' "$out" | head -1 | grep -qx EXITED || fail "AWAIT: closed with no result is EXITED (4)" "$rc · $out"
out=$(env "$INT" bash "$BIN/fleet-await.sh" "$A3" --timeout 2 --interval 1); rc=$?
ok; [ "$rc" = 3 ] || fail "AWAIT: a turn boundary (waiting) is no answer — TIMEOUT (3)" "$rc · $out"

# ---- KIDS --------------------------------------------------------------------------
out=$(env "$INT" bash "$BIN/fleet-children.sh" --ids "$PA")
ok; printf '%s' "$out" | grep -q '^1 children' || fail "KIDS: the parent ID lists its one child" "$out"

# ---- WT ----------------------------------------------------------------------------
git init -q "$WORK/wt" 2>/dev/null
lib fleet_worktree_id_mark "$WORK/wt" "$F2"
ok; [ "$(lib fleet_worktree_id "$WORK/wt")" = "$F2" ] || fail "WT: a worktree remembers its ID"
ok; ! lib fleet_worktree_id_mark "$WORK/wt" T12 || fail "WT: a non-ID is refused"

# ---- TASKPAR · a task dispatch's child ID names its parent (C9) --------------------
# A keyless parent (an orchestrator, a driver) dispatches with ITS ID as --origin;
# a hub-placed start hands a worker_id over; the hub itself names none.
TP=$(mkfid); TC=$(mkfid)
read -r WTP _ <<EOF
$(newwin "$TP")
EOF
fid open "$TP" --window "$WTP" --socket "$L" >/dev/null
ok; [ "$(lib fleet_spawn_parent_id "$L" "$TP" '' "$L")" = "$TP" ] || fail "TASKPAR: a keyless parent's ID as --origin is the parent"
ok; [ "$(lib fleet_spawn_parent_id "$L" '' "u-u-i-d/$TP" "$L")" = "$TP" ] || fail "TASKPAR: a handed-over worker_id's ID is the parent"
ok; ! lib fleet_spawn_parent_id "$L" issue-3 "u-u-i-d/issue-3" "$L" >/dev/null || fail "TASKPAR: a worker_id naming only a key is no parent here"
ok; ! lib fleet_spawn_parent_id "$L" hub '' "$L" >/dev/null && ! lib fleet_spawn_parent_id "$L" '' '' "$L" >/dev/null \
  || fail "TASKPAR: the hub names no parent"
fid open "$TC" --task T77 --parent "$(lib fleet_spawn_parent_id "$L" "$TP" '' "$L")" >/dev/null
ok; fid children "$TP" | grep -q '^1 children' || fail "TASKPAR: children lists the dispatched ID" "$(fid children "$TP")"
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
ok; printf '%s' "$out" | grep -q "T78  → $TP  (dry)" && [ -z "$(openedf "$TB" parent)" ] \
  || fail "TASKPAR: the backfill is dry by default" "$out"
out=$(FLEET_ID_TASK_GET="$WORK/taskget" fid parents --apply 2>&1)
ok; [ "$(openedf "$TB" parent)" = "$TP" ] || fail "TASKPAR: --apply fills the record's parent" "$out"
ok; [ "$(openedf "$TB" task)" = T78 ] && [ "$(openedf "$TB" agent)" = codex ] || fail "TASKPAR: the fill keeps what opened said"
ok; fid children "$TP" | grep -q '^2 children' || fail "TASKPAR: the filled ID is a child" "$(fid children "$TP")"
out=$(FLEET_ID_TASK_GET="$WORK/taskget" fid parents 2>&1)
ok; printf '%s' "$out" | grep -q '^0 without a parent' || fail "TASKPAR: a second pass finds nothing" "$out"
printf '#!/bin/sh\nexit 3\n' > "$WORK/taskget3"; chmod +x "$WORK/taskget3"
python3 "$BIN/fleet_id.py" open "$(mkfid)" --task T79 >/dev/null
FLEET_ID_TASK_GET="$WORK/taskget3" fid parents >/dev/null 2>&1; rc=$?
ok; [ "$rc" = 3 ] || fail "TASKPAR: no hub here ⇒ rc 3" "$rc"

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
ok; printf '%s' "$out" | grep -q '@70  codex  opened + 段 1 migrated  (dry)' && printf '%s' "$out" | grep -q '^1 to backfill' \
  && [ -z "$(openedf "$BF" agent)" ] || fail "BACKFILL: dry by default, only the pre-C1 window" "$out"
out=$(bfill --apply)
ok; [ "$(openedf "$BF" agent)" = codex ] && [ "$(openedf "$BF" window)" = @70 ] && [ "$(openedf "$BF" task)" = T88 ] \
  && [ "$(openedf "$BF" repo)" = acme/app ] && [ "$(openedf "$BF" worktree)" = "$WORK/wt-70" ] \
  || fail "BACKFILL: opened takes the window's options" "$(python3 "$BIN/fleet_id.py" get "$BF" --json)"
got=$(fid get "$BF")
ok; printf '%s' "$got" | grep -q 'agent codex' && printf '%s' "$got" | grep -Eq '段 1  codex +cx-thread-70 .* migrated' \
  && ! printf '%s' "$got" | grep -q 'opened ?' || fail "BACKFILL: get lists opened and segment 1 migrated" "$got"
ok; [ "$(python3 "$BIN/fleet_id.py" get "$BC" --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["segments"]), d["segments"][0]["trigger"])')" = "1 startup" ] \
  && [ ! -f "$FLEET_CONF_DIR/ids/$BH.ndjson" ] || fail "BACKFILL: a full ledger and home are left alone"
n1=$(wc -l < "$FLEET_CONF_DIR/ids/$BF.ndjson"); out=$(bfill --apply)
ok; printf '%s' "$out" | grep -q '^0 to backfill' && [ "$(wc -l < "$FLEET_CONF_DIR/ids/$BF.ndjson")" = "$n1" ] \
  || fail "BACKFILL: a second pass writes nothing" "$out"

# ---- WIRE --------------------------------------------------------------------------
ok; grep -q -- '--parent "\$_idpar"' "$BIN/dash-raw-session.sh" && grep -q -- '--parent "\$_idpar"' "$BIN/dash-issue-session.sh" \
  || fail "WIRE: both spawners open the ID with its parent"
ok; [ "$(grep -c '_idpar=$(fleet_spawn_parent_id "$SESS" "$ORIGIN" "$ORIGIN_WID" "$SOCK")' "$BIN/dash-raw-session.sh" "$BIN/dash-issue-session.sh" | grep -c ':1$')" = 2 ] \
  || fail "WIRE: both spawners take the parent from --origin too, not only a handed-over worker_id (C9)"
ok; grep -q -- '--from-native "\$RESUME_SID"' "$BIN/dash-raw-session.sh" || fail "WIRE: a --resume spawn records prev"
ok; grep -q 'fleet_win_retire "\$target" "" reaped' "$BIN/dash-reap.sh" \
  && grep -q 'fleet_win_retire "\$WIN" "\$(fleet_socket "\$FLEET_SESSION")" landed' "$BIN/fleet-cleanup.sh" \
  && grep -q 'fleet_win_retire "\$wid" "\$SOCK" stopped' "$BIN/fleet-worker-stop.sh" \
  && grep -q 'fleet_win_retire "\$win" "" exited' "$BIN/session-end-hook.sh" \
  || fail "WIRE: the reap / cleanup / stop / exit closers end the ID"
ok; grep -q 'id_result(c,' "$BIN/fleet_task_control.py" && grep -q 'fleet_id_take' "$BIN/fleet_task_control.py" \
  || fail "WIRE: the accepted-task road writes the ID result and routes by ID, no generation gate"
ok; grep -q 'trap id_result EXIT' "$BIN/fleet-report-parent.sh" || fail "WIRE: a session's own report writes its result"

if [ "$FAIL" -eq 0 ]; then echo "fleet-id-results selftest: PASS ($CHECKS checks)"; exit 0; fi
echo "fleet-id-results selftest: FAIL ($FAIL of $CHECKS)"; exit 1
