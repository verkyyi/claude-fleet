#!/bin/bash
# orchestrator-parent-selftest.sh — the orchestrating session is a PARENT (issue
# #2129). It has no issue, no scratch and no repo (`@fleet_role orchestrator`,
# `@norepo 1`), so before this every reader that keys a parent — fleet_origin_key,
# fleet-children.sh, the spawn gate, fleet-report-parent.sh, fleet-peer-send.sh, the
# MCP `send` — found nothing and its children reported nowhere. Its key is the
# literal `orchestrator`, the one fleet_win_for_key answers to. On an isolated tmux
# server (`-L <label>`) and a sandbox conf dir, pins:
#   A  fleet_origin_key / fleet_window_okey / fleet_epic_parent_key in the
#      orchestrator's pane → `orchestrator`; fleet_origin_canon keeps it (explicit
#      or detected, never repo-qualified).
#   B  fleet_origin_gate: a live orchestrator passes; none → 4. fleet_worker_locate
#      places it `local`.
#   C  a spawn's stamp: fleet_stamp_origin_wid writes the orchestrator's @fleet_id
#      as the child's @origin_fid, and fleet_origin_win resolves it back.
#   D  a child with @origin orchestrator: fleet-report-parent.sh --dry-run names the
#      orchestrator's window; a real report lands in `orchestrator.ndjson`, and
#      fleet-children.sh run IN the orchestrator's pane lists it (no key argument).
#   E  fleet-peer-send.sh accepts `orchestrator` as an address (not a window name).
#   F  the MCP `send` accepts `to: orchestrator`; `parent_window` accepts it.
#   G  issue #2623: `--origin hub` from the orchestrator's pane is still its child
#      (canon → `orchestrator`; elsewhere still empty; the gate never refuses `hub`),
#      and a NO-REPO child (a batch driver) is booked by its @fleet_id and listed by
#      fleet-children.sh under its window name.
#   H  issue #3117: the role's HOLDER answers `orchestrator` — an ordinary window
#      marked `@fleet_role_def orchestrator` (C3's take_role) wins over the old seat's
#      @fleet_role; with no holder and no seat the report is the person's — one row in
#      global/orphan-reports.ndjson, the alert called once, a repeat files nothing,
#      a hub-spawned child files nothing.
# tmux absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { echo 'orchestrator-parent selftest: tmux absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/orch-parent.XXXXXX")" || exit 2
L="orp$$"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
export FLEET_UI_QUIET=1 TMPDIR="$WORK"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$FLEET_CONF_DIR/fleets/$L/conf"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_HUB_STATUS_CMD FLEET_HUB_CACHE_SECS

# gh shim: every PR merged, none open; nothing here reaches GitHub.
mkdir -p "$WORK/shim"
printf '#!/bin/sh\ncase "$*" in *pulls?state=open*) echo 0 ;; *pulls/*) echo "true closed false" ;; esac\nexit 0\n' > "$WORK/shim/gh"
chmod +x "$WORK/shim/gh"
export PATH="$WORK/shim:$PATH"

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

tf -f /dev/null new-session -d -s "$L" -n home -c "$WORK" 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'orchestrator-parent selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
SOCKPATH=$(tf display-message -p '#{socket_path}')
INTMUX="$SOCKPATH,1,0"
wo=$(tf new-window -d -P -F '#{window_id}' -n orchestrator -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$wo" @fleet_role orchestrator
tf set-window-option -t "$wo" @norepo 1
po=$(tf display-message -p -t "$wo" '#{pane_id}')

# lib <TMUX> <TMUX_PANE> <shell…> → stdout of a fleet-lib call, rc kept
lib() { local t="$1" p="$2"; shift 2; TMUX="$t" TMUX_PANE="$p" bash -c '. "$1/fleet-lib.sh"; shift; eval "$*"' _ "$BIN" "$@"; }

# --- A: the key ------------------------------------------------------------------
r=$(lib "$INTMUX" "$po" fleet_origin_key);                ok; [ "$r" = orchestrator ] || fail "A: fleet_origin_key in the orchestrator pane" "$r"
r=$(lib "$INTMUX" "$po" fleet_window_okey "$L" "$wo");    ok; [ "$r" = orchestrator ] || fail "A: fleet_window_okey of the orchestrator window" "$r"
r=$(lib "$INTMUX" "$po" fleet_epic_parent_key "$L" acme/app 1949 2>/dev/null); ok; [ "$r" = orchestrator ] || fail "A: fleet_epic_parent_key in the orchestrator pane" "$r"
r=$(lib '' '' fleet_origin_canon orchestrator "''" "$L");  ok; [ "$r" = orchestrator ] || fail "A: canon keeps an explicit orchestrator" "$r"
r=$(lib '' '' fleet_origin_canon "''" orchestrator "$L");  ok; [ "$r" = orchestrator ] || fail "A: canon keeps a detected orchestrator" "$r"
r=$(lib '' '' fleet_origin_canon orchestrator acme-app:issue-7 "$L" 2>&1); ok; [ "$r" = orchestrator ] || fail "A: an explicit orchestrator is never swapped" "$r"
# A session that TOOK the role (issue #3114: `@fleet_role_def`, its @fleet_role a
# worker's) and has no key of its own answers to the role's name (issue #3439); a
# taken role in a scratch keeps the scratch key.
wt=$(tf new-window -d -P -F '#{window_id}' -n taken -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$wt" @fleet_role worker \; set-window-option -t "$wt" @fleet_role_def steward \; set-window-option -t "$wt" @norepo 1
pt=$(tf display-message -p -t "$wt" '#{pane_id}')
r=$(lib "$INTMUX" "$pt" fleet_origin_key);                ok; [ "$r" = steward ] || fail "A: a taken role with no key is the role's key" "$r"
tf set-window-option -t "$wt" @fleet_role_def '' \; set-window-option -u -t "$wt" @fleet_role_def
r=$(lib "$INTMUX" "$pt" fleet_origin_key);                ok; [ -z "$r" ] || fail "A: no role, no key ⇒ nothing (the hub)" "$r"
tf kill-window -t "$wt"

# --- B: the gate + locate --------------------------------------------------------
r=$(lib '' '' fleet_origin_gate "$L" orchestrator orchestrator); rc=$?; ok; [ "$rc:$r" = '0:' ] || fail "B: a live orchestrator passes the gate" "$rc:$r"
r=$(lib '' '' fleet_worker_locate orchestrator "$L");          ok; [ "$r" = "local $wo $L" ] || fail "B: locate places the orchestrator" "$r"
r=$(lib '' '' fleet_worker_locate wid:orchestrator "$L");      ok; [ "$r" = "local $wo $L" ] || fail "B: locate places wid:orchestrator" "$r"
tf set-window-option -t "$wo" -u @fleet_role
r=$(lib '' '' fleet_origin_gate "$L" orchestrator orchestrator); rc=$?; ok; [ "$rc" = 4 ] || fail "B: no orchestrator window → 4" "$rc:$r"
tf set-window-option -t "$wo" @fleet_role orchestrator

# --- C: a spawn's identity stamp -------------------------------------------------
wc=$(tf new-window -d -P -F '#{window_id}' -n kid -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$wc" @issue 101
tf set-window-option -t "$wc" @repo acme/app
tf set-window-option -t "$wc" @origin orchestrator
tf set-window-option -t "$wc" @claude_state 'done'
lib '' '' fleet_stamp_origin_wid "$L" "$wc" orchestrator "$L" >/dev/null 2>&1
ofid=$(tf display-message -p -t "$wo" '#{@fleet_id}'); cfid=$(tf display-message -p -t "$wc" '#{@origin_fid}')
ok; [ -n "$ofid" ] && [ "$ofid" = "$cfid" ] || fail "C: the child's @origin_fid is the orchestrator's @fleet_id" "orch=$ofid child=$cfid"
r=$(lib '' '' fleet_origin_win "$L" "$wc" "$L");               ok; [ "$r" = "$wo" ] || fail "C: fleet_origin_win resolves the orchestrator" "$r"

# --- D: the report + the children book -------------------------------------------
r=$(bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wc" --state merged --pr 501 --summary landed --dry-run 2>&1)
ok; case "$r" in *"for orchestrator ($wo)"*|*"to orchestrator ($wo"*) ;; *) fail "D: the dry run names the orchestrator's window" "$r" ;; esac
bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wc" --state merged --pr 501 --summary landed >/dev/null 2>&1
LEDGER="$FLEET_CONF_DIR/fleets/$L/children/orchestrator.ndjson"
ok; grep -q '"acme-app:issue-101"' "$LEDGER" 2>/dev/null || fail "D: the report is booked under orchestrator" "$(find "$FLEET_CONF_DIR" -name '*.ndjson' 2>/dev/null)"
r=$(TMUX="$INTMUX" TMUX_PANE="$po" bash "$BIN/fleet-children.sh" -L "$L" 2>&1); rc=$?
ok; [ "$rc" = 0 ] || fail "D: fleet-children.sh in the orchestrator pane needs no key" "$rc:$r"
ok; case "$r" in *acme-app:issue-101*MERGED*|*MERGED*acme-app:issue-101*) ;; *) fail "D: …and lists the child, merged" "$r" ;; esac

# --- E: the peer channel ---------------------------------------------------------
r=$(printf 'hi\n' | bash "$BIN/fleet-peer-send.sh" -L "$L" orchestrator - 2>&1); rc=$?
ok; case "$rc" in 0|3) ;; *) fail "E: fleet-peer-send.sh orchestrator is an address" "$rc:$r" ;; esac
ok; case "$r" in *'window name'*|*'no live window'*) fail "E: …resolved to the orchestrator's window" "$r" ;; esac

# --- F: the MCP tool's address grammar -------------------------------------------
r=$(python3 - "$BIN" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fleet_mcp", sys.argv[1] + "/fleet-mcp.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
calls = []
m.run = lambda argv, **kw: (calls.append(argv), type("R", (), {"returncode": 0, "stdout": "sent\n", "stderr": ""})())[1]
m.hub_env = lambda *a, **k: None
out = m.send_message("orchestrator", "hi")
assert out["delivered"] and calls and calls[0][2] == "orchestrator", (out, calls)
m.origin_option = lambda: "orchestrator"
m.current_session = lambda: "s"
m.lib = lambda *a, **k: type("R", (), {"returncode": 0, "stdout": "@9", "stderr": ""})()
assert m.parent_window() == "@9"
print("ok")
PY
)
ok; [ "$r" = ok ] || fail "F: the MCP send / parent accept orchestrator" "$r"

# --- G: a driver the orchestrator starts with --origin hub (issue #2623) -----------
r=$(lib '' '' fleet_origin_canon hub orchestrator "$L");       ok; [ "$r" = orchestrator ] || fail "G: hub from the orchestrator's pane → orchestrator" "$r"
r=$(lib '' '' fleet_origin_canon hub acme-app:issue-7 "$L");   ok; [ -z "$r" ] || fail "G: hub from a worker's pane stays empty (#896)" "$r"
tf set-window-option -t "$wo" -u @fleet_role
r=$(lib '' '' fleet_origin_gate "$L" hub orchestrator); rc=$?; ok; [ "$rc" = 0 ] || fail "G: the gate never refuses an explicit hub" "$rc:$r"
tf set-window-option -t "$wo" @fleet_role orchestrator
wd=$(tf new-window -d -P -F '#{window_id}' -n '批次·驱动' -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$wd" @norepo 1
tf set-window-option -t "$wd" @origin orchestrator
tf set-window-option -t "$wd" @claude_state 'done'
dfid=11111111-2222-4333-8444-555555555555
tf set-window-option -t "$wd" @fleet_id "$dfid"
bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wd" --state merged --summary 'batch closed' >/dev/null 2>&1
ok; grep -q "\"child\": *\"$dfid\"" "$LEDGER" 2>/dev/null || fail "G: the no-repo child's report is booked under its fleet_id" "$(cat "$LEDGER" 2>/dev/null)"
r=$(TMUX="$INTMUX" TMUX_PANE="$po" bash "$BIN/fleet-children.sh" -L "$L" --json 2>&1)
ok; printf '%s' "$r" | python3 -c '
import json, sys
kids = {k["child"]: k for k in json.load(sys.stdin)["children"]}
k = kids[sys.argv[1]]
assert k["live"] and k["title"] == "批次·驱动" and (k.get("settled") or k["last"])["state"] == "MERGED", k
' "$dfid" 2>/dev/null || fail "G: fleet-children.sh --json lists the no-repo child by name, merged" "$r"

# --- H: the holder, and nobody to take it (issue #3117) ---------------------------
wt=$(tf new-window -d -P -F '#{window_id}' -n taker -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$wt" @fleet_role_def orchestrator
r=$(lib '' '' fleet_win_for_key orchestrator "$L");       ok; [ "$r" = "$wt" ] || fail "H: the take_role holder answers orchestrator" "$r"
tf set-window-option -t "$wt" -u @fleet_role_def
r=$(lib '' '' fleet_win_for_key orchestrator "$L");       ok; [ "$r" = "$wo" ] || fail "H: no holder → the old seat (compat)" "$r"
tf kill-window -t "$wo"
wk=$(tf new-window -d -P -F '#{window_id}' -n kid2 -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$wk" @issue 102
tf set-window-option -t "$wk" @repo acme/app
tf set-window-option -t "$wk" @origin orchestrator
tf set-window-option -t "$wk" @claude_state 'done'
printf '#!/bin/sh\necho "$*" >> "%s/alerted"\n' "$WORK" > "$WORK/alert"; chmod +x "$WORK/alert"
ORPH="$FLEET_CONF_DIR/global/orphan-reports.ndjson"
r=$(FLEET_ORPHAN_ALERT_CMD="$WORK/alert" bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wk" --state blocked --summary 'needs a token' 2>&1)
ok; case "$r" in orphaned*) ;; *) fail "H: the orchestrator gone → orphaned" "$r" ;; esac
ok; python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; assert len(r)==1 and r[0]["child_key"]=="acme-app:issue-102" and r[0]["state"]=="BLOCKED" and r[0]["summary"]=="needs a token", r' "$ORPH" 2>/dev/null \
  || fail "H: one BLOCKED row in orphan-reports.ndjson" "$(cat "$ORPH" 2>/dev/null)"
FLEET_ORPHAN_ALERT_CMD="$WORK/alert" bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wk" --state blocked --summary 'needs a token' >/dev/null 2>&1
ok; [ "$(grep -c . "$ORPH"):$(grep -c child-report "$WORK/alerted" 2>/dev/null)" = 1:1 ] || fail "H: a repeat files nothing, alerts once" "$(cat "$ORPH" "$WORK/alerted" 2>/dev/null)"
wn=$(tf new-window -d -P -F '#{window_id}' -n kid3 -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$wn" @issue 103
tf set-window-option -t "$wn" @repo acme/app
FLEET_ORPHAN_ALERT_CMD="$WORK/alert" bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wn" --state blocked --summary x >/dev/null 2>&1
ok; [ "$(grep -c . "$ORPH")" = 1 ] || fail "H: a hub-spawned child files nothing" "$(cat "$ORPH")"

if [ "$FAIL" -gt 0 ]; then
  printf 'orchestrator-parent selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2
  exit 1
fi
printf 'orchestrator-parent selftest: PASS (%d checks)\n' "$CHECKS"
