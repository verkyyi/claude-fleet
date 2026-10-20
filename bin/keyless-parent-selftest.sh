#!/bin/bash
# keyless-parent-selftest.sh — a session with no key of its own is a PARENT by its
# IDENTITY (issue #4341, EPIC #4333 C8; before it, issue #2129's role literal). A
# session template opened bare, a person's own no-repo session: no issue, no
# scratch, no repo — its key is its @fleet_id, so its spawns name it as their parent
# and every child reports back to it. No session wears a role's name any more; the
# `agent:<name>` address reaches the session started from that agent file. On an
# isolated tmux server (`-L <label>`) and a sandbox conf dir, pins:
#   A  fleet_origin_key / fleet_window_okey / fleet_epic_parent_key in a keyless
#      pane → its @fleet_id; home → nothing; an old window's leftover
#      `@fleet_role_def orchestrator` / `@fleet_role orchestrator` changes nothing
#      (C7's condition 3: an ordinary session); canon keeps an identity, `hub` is
#      always empty (#896).
#   B  fleet_origin_gate passes an identity; fleet_worker_locate places it `local`.
#   C  a spawn's stamp: fleet_stamp_origin_wid writes that identity as @origin_fid,
#      and fleet_origin_win resolves it back.
#   D  a child of a parent with NO role mark at all reports to it (C7's condition
#      2): the dry run names the parent's window, the book is the parent's identity,
#      fleet-children.sh in the parent's pane lists it.
#   E  `agent:<name>` (C7's condition 1): a session started from that agent file
#      (@agent_def) answers; none ⇒ the SENDER's parent gets it, said on stderr; no
#      parent either ⇒ the person's reminder (one orphan-reports row, the alert once)
#      — never exit 0 with nobody holding it; two sessions ⇒ ambiguous, exit 1; a
#      leftover role mark or the bare word `orchestrator` is no address (#4790).
#   F  the MCP `send` accepts `to: agent:<name>` (the bare old word is refused,
#      #4790); `parent_window` accepts an identity; list_agents keys a keyless
#      row by it.
# tmux absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
REAL_TMUX=$(command -v tmux) || { echo 'keyless-parent selftest: tmux absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/keyless-parent.XXXXXX")" || exit 2
L="klp$$"
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
printf '#!/bin/sh\necho "$*" >> "%s/alerted"\n' "$WORK" > "$WORK/alert"; chmod +x "$WORK/alert"
export FLEET_ORPHAN_ALERT_CMD="$WORK/alert"

st_tally
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

tf -f /dev/null new-session -d -s "$L" -n home -c "$WORK" 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'keyless-parent selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
SOCKPATH=$(tf display-message -p '#{socket_path}')
INTMUX="$SOCKPATH,1,0"
wh=$(tf display-message -p -t "=$L:home" '#{window_id}'); ph=$(tf display-message -p -t "$wh" '#{pane_id}')
tf set-window-option -t "$wh" @fleet_role home \; set-window-option -t "$wh" @fleet_id 00000000-0000-4000-8000-0000000000aa
F=1f0e0000-0000-4000-8000-000000004341
wo=$(tf new-window -d -P -F '#{window_id}' -n 编排 -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$wo" @fleet_role worker \; set-window-option -t "$wo" @norepo 1 \; set-window-option -t "$wo" @fleet_id "$F"
po=$(tf display-message -p -t "$wo" '#{pane_id}')

# lib <TMUX> <TMUX_PANE> <shell…> → stdout of a fleet-lib call, rc kept
lib() { local t="$1" p="$2"; shift 2; TMUX="$t" TMUX_PANE="$p" bash -c '. "$1/fleet-lib.sh"; shift; eval "$*"' _ "$BIN" "$@"; }

# --- A: the key is the identity ---------------------------------------------------
r=$(lib "$INTMUX" "$po" fleet_origin_key);                st_count; [ "$r" = "$F" ] || st_miss "A: fleet_origin_key in a keyless pane is its @fleet_id" "$r"
r=$(lib "$INTMUX" "$po" fleet_window_okey "$L" "$wo");    st_count; [ "$r" = "$F" ] || st_miss "A: fleet_window_okey of a keyless window" "$r"
r=$(lib "$INTMUX" "$po" fleet_epic_parent_key "$L" acme/app 1949 2>/dev/null); st_count; [ "$r" = "$F" ] || st_miss "A: fleet_epic_parent_key in a keyless pane" "$r"
r=$(lib "$INTMUX" "$ph" fleet_origin_key);                st_count; [ -z "$r" ] || st_miss "A: home is no session (≡ the hub)" "$r"
tf set-window-option -t "$wo" @fleet_role_def orchestrator
r=$(lib "$INTMUX" "$po" fleet_origin_key);                st_count; [ "$r" = "$F" ] || st_miss "A: a leftover @fleet_role_def changes nothing" "$r"
tf set-window-option -t "$wo" -u @fleet_role_def \; set-window-option -t "$wo" @fleet_role orchestrator
r=$(lib "$INTMUX" "$po" fleet_window_okey "$L" "$wo");    st_count; [ "$r" = "$F" ] || st_miss "A: an old seat's @fleet_role changes nothing" "$r"
tf set-window-option -t "$wo" @fleet_role worker
r=$(lib '' '' fleet_origin_canon "$F" "''" "$L");          st_count; [ "$r" = "$F" ] || st_miss "A: canon keeps an explicit identity" "$r"
r=$(lib '' '' fleet_origin_canon "''" "$F" "$L");          st_count; [ "$r" = "$F" ] || st_miss "A: canon keeps a detected identity" "$r"
r=$(lib '' '' fleet_origin_canon hub "$F" "$L");           st_count; [ -z "$r" ] || st_miss "A: hub is the hub, whoever asks" "$r"
r=$(lib '' '' fleet_origin_canon orchestrator "$F" "$L" 2>/dev/null); st_count; [ "$r" = "$F" ] || st_miss "A: the old word is no key: the detected one is stamped" "$r"

# --- B: the gate + locate --------------------------------------------------------
r=$(lib '' '' fleet_origin_gate "$L" "''" "$F"); rc=$?;   st_count; [ "$rc:$r" = '0:' ] || st_miss "B: an identity passes the gate" "$rc:$r"
r=$(lib '' '' fleet_worker_locate "wid:$F" "$L");         st_count; [ "$r" = "local $wo $L" ] || st_miss "B: locate places the identity" "$r"

# --- C: a spawn's identity stamp -------------------------------------------------
wc=$(tf new-window -d -P -F '#{window_id}' -n kid -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$wc" @issue 101 \; set-window-option -t "$wc" @repo acme/app \; \
   set-window-option -t "$wc" @origin "$F" \; set-window-option -t "$wc" @claude_state 'done'
lib '' '' fleet_stamp_origin_wid "$L" "$wc" "$F" "$L" >/dev/null 2>&1
r=$(tf display-message -p -t "$wc" '#{@origin_fid}');      st_count; [ "$r" = "$F" ] || st_miss "C: the child's @origin_fid is the parent's identity" "$r"
r=$(lib '' '' fleet_origin_win "$L" "$wc" "$L");           st_count; [ "$r" = "$wo" ] || st_miss "C: fleet_origin_win resolves it" "$r"
tf set-window-option -t "$wc" -u @origin_fid
r=$(lib '' '' fleet_origin_win "$L" "$wc" "$L");           st_count; [ "$r" = "$wo" ] || st_miss "C: …and by @origin alone (an identity is an address)" "$r"
tf set-window-option -t "$wc" @origin_fid "$F"

# --- D: the report reaches a parent with no role mark (condition 2) ---------------
r=$(bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wc" --state merged --pr 501 --summary landed --dry-run 2>&1)
st_count; case "$r" in *"($wo"*) ;; *) st_miss "D: the dry run names the parent's window" "$r" ;; esac
bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wc" --state merged --pr 501 --summary landed >/dev/null 2>&1
LEDGER="$FLEET_CONF_DIR/fleets/$L/children/$F.ndjson"
st_count; grep -q '"acme-app:issue-101"' "$LEDGER" 2>/dev/null || st_miss "D: the report is booked under the parent's identity" "$(find "$FLEET_CONF_DIR" -name '*.ndjson' 2>/dev/null)"
r=$(TMUX="$INTMUX" TMUX_PANE="$po" bash "$BIN/fleet-children.sh" -L "$L" 2>&1); rc=$?
st_count; [ "$rc" = 0 ] || st_miss "D: fleet-children.sh in the parent's pane needs no key" "$rc:$r"
st_count; case "$r" in *acme-app:issue-101*MERGED*|*MERGED*acme-app:issue-101*) ;; *) st_miss "D: …and lists the child, merged" "$r" ;; esac

# --- E: the agent address (condition 1) ------------------------------------------
send() { printf '%s\n' "$2" | TMUX="${3:-}" TMUX_PANE="${4:-}" bash "$BIN/fleet-peer-send.sh" -L "$L" "$1" - 2>"$WORK/send.err"; }
r=$(lib '' '' fleet_win_for_key agent:orchestrator "$L"); rc=$?; st_count; [ "$rc" = 1 ] || st_miss "E: nobody runs the template ⇒ not found" "$rc:$r"
tf set-window-option -t "$wo" @agent_def orchestrator
r=$(lib '' '' fleet_win_for_key agent:orchestrator "$L"); st_count; [ "$r" = "$wo" ] || st_miss "E: @agent_def answers agent:<name>" "$r"
r=$(lib '' '' fleet_win_for_key orchestrator "$L"); rc=$?; st_count; [ "$rc" = 1 ] || st_miss "E: the bare word is no address" "$rc:$r"
r=$(send agent:orchestrator hi); rc=$?
st_count; case "$rc" in 0|3) ;; *) st_miss "E: a running template session takes it" "$rc:$r $(cat "$WORK/send.err")" ;; esac
st_count; case "$r$(cat "$WORK/send.err")" in *rerouted*|*'parent instead'*) st_miss "E: …itself, not a fallback" "$r" ;; esac
w2=$(tf new-window -d -P -F '#{window_id}' -n 编排2 -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$w2" @agent_def orchestrator
r=$(send agent:orchestrator hi); rc=$?;                   st_count; [ "$rc" = 1 ] || st_miss "E: two sessions ⇒ ambiguous, refused" "$rc:$r"
tf kill-window -t "$w2"; tf set-window-option -t "$wo" -u @agent_def
# a leftover role mark answers nothing
tf set-window-option -t "$wo" @fleet_role_def orchestrator
r=$(lib '' '' fleet_win_for_agent orchestrator "$L"); rc=$?; st_count; [ "$rc" = 1 ] || st_miss "E: a leftover role mark is no address" "$rc:$r"
tf set-window-option -t "$wo" -u @fleet_role_def
# none running: the sender's parent (the child wc, whose parent is wo) gets it
pc=$(tf display-message -p -t "$wc" '#{pane_id}')
r=$(send agent:steward 'need a call' "$INTMUX" "$pc"); rc=$?
st_count; case "$rc" in 0|3) ;; *) st_miss "E: none running ⇒ the sender's parent takes it" "$rc:$r $(cat "$WORK/send.err")" ;; esac
st_count; grep -q 'parent instead' "$WORK/send.err" || st_miss "E: …said on stderr" "$(cat "$WORK/send.err")"
ORPH="$FLEET_CONF_DIR/global/orphan-reports.ndjson"
st_count; [ ! -s "$ORPH" ] || st_miss "E: …and no reminder filed" "$(cat "$ORPH")"
# no parent either: the person's reminder, the alert once, exit 0
r=$(send agent:steward 'anyone?'); rc=$?
st_count; [ "$rc" = 0 ] || st_miss "E: no parent ⇒ the person's reminder, exit 0" "$rc:$r $(cat "$WORK/send.err")"
st_count; case "$r" in rerouted*) ;; *) st_miss "E: …says rerouted" "$r" ;; esac
st_count; python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; assert len(r)==1 and r[0]["parent"]=="agent:steward" and r[0]["summary"]=="anyone?" and r[0]["state"]=="MESSAGE", r' "$ORPH" 2>/dev/null \
  || st_miss "E: one reminder row naming agent:steward" "$(cat "$ORPH" 2>/dev/null)"
st_count; [ "$(grep -c child-report "$WORK/alerted" 2>/dev/null)" = 1 ] || st_miss "E: the alert once" "$(cat "$WORK/alerted" 2>/dev/null)"

# --- F: the MCP tool's address grammar -------------------------------------------
r=$(python3 - "$BIN" "$F" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fleet_mcp", sys.argv[1] + "/fleet-mcp.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
calls = []
m.run = lambda argv, **kw: (calls.append(argv), type("R", (), {"returncode": 0, "stdout": "sent\n", "stderr": ""})())[1]
m.hub_env = lambda *a, **k: None
out = m.send_message("agent:orchestrator", "hi")
assert out["delivered"] and calls[-1][2] == "agent:orchestrator", (out, calls)
try:
    m.send_message("orchestrator", "hi"); raise SystemExit("the bare old word accepted")
except m.Refused:
    pass
try:
    m.send_message("agent:", "hi"); raise SystemExit("agent: with no name accepted")
except m.Refused:
    pass
m.current_session = lambda: "s"
m.lib = lambda *a, **k: type("R", (), {"returncode": 0, "stdout": "@9", "stderr": ""})()
m.parent_remote = lambda: ""
m.origin_option = lambda: sys.argv[2]
assert m.parent_window() == "@9"
row = {"issue": "", "worktree": "", "path": "/home/x", "repo": "", "norepo": "1", "role": "worker", "fleet_id": sys.argv[2]}
assert m.window_key(row, "acme/app") == sys.argv[2]
assert m.window_key(dict(row, role="home"), "acme/app") == ""
print("ok")
PY
)
st_count; [ "$r" = ok ] || st_miss "F: the MCP send / parent / key" "$r"

st_done
