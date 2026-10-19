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
#      fleet-children.sh in the parent's pane lists it; an OLD child whose @origin is
#      the word `orchestrator` but whose @origin_fid names the parent reaches it too,
#      by identity — and its @origin follows to the identity.
#   E  `agent:<name>` (C7's condition 1): a session started from that agent file
#      (@agent_def) answers; none ⇒ the SENDER's parent gets it, said on stderr; no
#      parent either ⇒ the person's reminder (one orphan-reports row, the alert once)
#      — never exit 0 with nobody holding it; two sessions ⇒ ambiguous, exit 1; the
#      older bare word `orchestrator` is that address for one version.
#   F  the MCP `send` accepts `to: agent:<name>` (the bare old word is passed on as
#      it is, #4790); `parent_window` accepts an identity; list_agents keys a keyless
#      row by it.
# tmux absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
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

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
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
r=$(lib "$INTMUX" "$po" fleet_origin_key);                ok; [ "$r" = "$F" ] || fail "A: fleet_origin_key in a keyless pane is its @fleet_id" "$r"
r=$(lib "$INTMUX" "$po" fleet_window_okey "$L" "$wo");    ok; [ "$r" = "$F" ] || fail "A: fleet_window_okey of a keyless window" "$r"
r=$(lib "$INTMUX" "$po" fleet_epic_parent_key "$L" acme/app 1949 2>/dev/null); ok; [ "$r" = "$F" ] || fail "A: fleet_epic_parent_key in a keyless pane" "$r"
r=$(lib "$INTMUX" "$ph" fleet_origin_key);                ok; [ -z "$r" ] || fail "A: home is no session (≡ the hub)" "$r"
tf set-window-option -t "$wo" @fleet_role_def orchestrator
r=$(lib "$INTMUX" "$po" fleet_origin_key);                ok; [ "$r" = "$F" ] || fail "A: a leftover @fleet_role_def changes nothing" "$r"
tf set-window-option -t "$wo" -u @fleet_role_def \; set-window-option -t "$wo" @fleet_role orchestrator
r=$(lib "$INTMUX" "$po" fleet_window_okey "$L" "$wo");    ok; [ "$r" = "$F" ] || fail "A: an old seat's @fleet_role changes nothing" "$r"
tf set-window-option -t "$wo" @fleet_role worker
r=$(lib '' '' fleet_origin_canon "$F" "''" "$L");          ok; [ "$r" = "$F" ] || fail "A: canon keeps an explicit identity" "$r"
r=$(lib '' '' fleet_origin_canon "''" "$F" "$L");          ok; [ "$r" = "$F" ] || fail "A: canon keeps a detected identity" "$r"
r=$(lib '' '' fleet_origin_canon hub "$F" "$L");           ok; [ -z "$r" ] || fail "A: hub is the hub, whoever asks" "$r"
r=$(lib '' '' fleet_origin_canon orchestrator "$F" "$L" 2>/dev/null); ok; [ "$r" = "$F" ] || fail "A: the old word is no key: the detected one is stamped" "$r"

# --- B: the gate + locate --------------------------------------------------------
r=$(lib '' '' fleet_origin_gate "$L" "''" "$F"); rc=$?;   ok; [ "$rc:$r" = '0:' ] || fail "B: an identity passes the gate" "$rc:$r"
r=$(lib '' '' fleet_worker_locate "wid:$F" "$L");         ok; [ "$r" = "local $wo $L" ] || fail "B: locate places the identity" "$r"

# --- C: a spawn's identity stamp -------------------------------------------------
wc=$(tf new-window -d -P -F '#{window_id}' -n kid -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$wc" @issue 101 \; set-window-option -t "$wc" @repo acme/app \; \
   set-window-option -t "$wc" @origin "$F" \; set-window-option -t "$wc" @claude_state 'done'
lib '' '' fleet_stamp_origin_wid "$L" "$wc" "$F" "$L" >/dev/null 2>&1
r=$(tf display-message -p -t "$wc" '#{@origin_fid}');      ok; [ "$r" = "$F" ] || fail "C: the child's @origin_fid is the parent's identity" "$r"
r=$(lib '' '' fleet_origin_win "$L" "$wc" "$L");           ok; [ "$r" = "$wo" ] || fail "C: fleet_origin_win resolves it" "$r"
tf set-window-option -t "$wc" -u @origin_fid
r=$(lib '' '' fleet_origin_win "$L" "$wc" "$L");           ok; [ "$r" = "$wo" ] || fail "C: …and by @origin alone (an identity is an address)" "$r"
tf set-window-option -t "$wc" @origin_fid "$F"

# --- D: the report reaches a parent with no role mark (condition 2) ---------------
r=$(bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wc" --state merged --pr 501 --summary landed --dry-run 2>&1)
ok; case "$r" in *"($wo"*) ;; *) fail "D: the dry run names the parent's window" "$r" ;; esac
bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wc" --state merged --pr 501 --summary landed >/dev/null 2>&1
LEDGER="$FLEET_CONF_DIR/fleets/$L/children/$F.ndjson"
ok; grep -q '"acme-app:issue-101"' "$LEDGER" 2>/dev/null || fail "D: the report is booked under the parent's identity" "$(find "$FLEET_CONF_DIR" -name '*.ndjson' 2>/dev/null)"
r=$(TMUX="$INTMUX" TMUX_PANE="$po" bash "$BIN/fleet-children.sh" -L "$L" 2>&1); rc=$?
ok; [ "$rc" = 0 ] || fail "D: fleet-children.sh in the parent's pane needs no key" "$rc:$r"
ok; case "$r" in *acme-app:issue-101*MERGED*|*MERGED*acme-app:issue-101*) ;; *) fail "D: …and lists the child, merged" "$r" ;; esac
wd=$(tf new-window -d -P -F '#{window_id}' -n old-kid -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$wd" @issue 102 \; set-window-option -t "$wd" @repo acme/app \; \
   set-window-option -t "$wd" @origin orchestrator \; set-window-option -t "$wd" @origin_fid "$F" \; \
   set-window-option -t "$wd" @claude_state 'done'
r=$(bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wd" --state merged --pr 502 --summary landed --dry-run 2>&1)
ok; case "$r" in *"($wo"*) ;; *) fail "D: an old child (@origin orchestrator) reaches its parent by identity" "$r" ;; esac
bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wd" --state merged --pr 502 --summary landed >/dev/null 2>&1
r=$(tf display-message -p -t "$wd" '#{@origin}');          ok; [ "$r" = "$F" ] || fail "D: …and its @origin follows to the identity" "$r"
ok; grep -q '"acme-app:issue-102"' "$LEDGER" 2>/dev/null || fail "D: …booked in the parent's book" "$(cat "$LEDGER" 2>/dev/null)"

# --- E: the agent address (condition 1) ------------------------------------------
send() { printf '%s\n' "$2" | TMUX="${3:-}" TMUX_PANE="${4:-}" bash "$BIN/fleet-peer-send.sh" -L "$L" "$1" - 2>"$WORK/send.err"; }
r=$(lib '' '' fleet_win_for_key agent:orchestrator "$L"); rc=$?; ok; [ "$rc" = 1 ] || fail "E: nobody runs the template ⇒ not found" "$rc:$r"
tf set-window-option -t "$wo" @agent_def orchestrator
r=$(lib '' '' fleet_win_for_key agent:orchestrator "$L"); ok; [ "$r" = "$wo" ] || fail "E: @agent_def answers agent:<name>" "$r"
r=$(lib '' '' fleet_win_for_key orchestrator "$L");       ok; [ "$r" = "$wo" ] || fail "E: the old word reads as agent:orchestrator (one version)" "$r"
r=$(send agent:orchestrator hi); rc=$?
ok; case "$rc" in 0|3) ;; *) fail "E: a running template session takes it" "$rc:$r $(cat "$WORK/send.err")" ;; esac
ok; case "$r$(cat "$WORK/send.err")" in *rerouted*|*'parent instead'*) fail "E: …itself, not a fallback" "$r" ;; esac
w2=$(tf new-window -d -P -F '#{window_id}' -n 编排2 -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$w2" @agent_def orchestrator
r=$(send agent:orchestrator hi); rc=$?;                   ok; [ "$rc" = 1 ] || fail "E: two sessions ⇒ ambiguous, refused" "$rc:$r"
tf kill-window -t "$w2"; tf set-window-option -t "$wo" -u @agent_def
# the old role mark on a leftover window still answers for one version
tf set-window-option -t "$wo" @fleet_role_def orchestrator
r=$(lib '' '' fleet_win_for_agent orchestrator "$L");     ok; [ "$r" = "$wo" ] || fail "E: a leftover role mark answers for one version" "$r"
tf set-window-option -t "$wo" -u @fleet_role_def
# none running: the sender's parent (the child wc, whose parent is wo) gets it
pc=$(tf display-message -p -t "$wc" '#{pane_id}')
r=$(send agent:steward 'need a call' "$INTMUX" "$pc"); rc=$?
ok; case "$rc" in 0|3) ;; *) fail "E: none running ⇒ the sender's parent takes it" "$rc:$r $(cat "$WORK/send.err")" ;; esac
ok; grep -q 'parent instead' "$WORK/send.err" || fail "E: …said on stderr" "$(cat "$WORK/send.err")"
ORPH="$FLEET_CONF_DIR/global/orphan-reports.ndjson"
ok; [ ! -s "$ORPH" ] || fail "E: …and no reminder filed" "$(cat "$ORPH")"
# no parent either: the person's reminder, the alert once, exit 0
r=$(send steward 'anyone?'); rc=$?
ok; [ "$rc" = 0 ] || fail "E: no parent ⇒ the person's reminder, exit 0" "$rc:$r $(cat "$WORK/send.err")"
ok; case "$r" in rerouted*) ;; *) fail "E: …says rerouted" "$r" ;; esac
ok; python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; assert len(r)==1 and r[0]["parent"]=="agent:steward" and r[0]["summary"]=="anyone?" and r[0]["state"]=="MESSAGE", r' "$ORPH" 2>/dev/null \
  || fail "E: one reminder row naming agent:steward" "$(cat "$ORPH" 2>/dev/null)"
ok; [ "$(grep -c child-report "$WORK/alerted" 2>/dev/null)" = 1 ] || fail "E: the alert once" "$(cat "$WORK/alerted" 2>/dev/null)"

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
out = m.send_message("orchestrator", "hi")
assert calls[-1][2] == "orchestrator", calls
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
ok; [ "$r" = ok ] || fail "F: the MCP send / parent / key" "$r"

if [ "$FAIL" -gt 0 ]; then
  printf 'keyless-parent selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2
  exit 1
fi
printf 'keyless-parent selftest: PASS (%d checks)\n' "$CHECKS"
