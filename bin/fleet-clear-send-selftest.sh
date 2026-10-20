#!/bin/bash
# fleet-clear-send-selftest.sh — /clear another session by its ID (T592):
# bin/fleet-clear-send.sh, its `fleet-id.sh clear` entry and the `clear` tool, on an
# isolated tmux server and a sandbox conf dir. Each window runs a fake agent TUI that
# reads lines off its tty and, on `/clear`, sends the SessionStart(source=clear) the
# real agent would — through `fleet-id.sh hook`, so the ledger is the real one.
#   A  Claude, idle (done): rc 0, one line `cleared …`, a new segment (trigger clear),
#      one audit line naming who and which ID
#   B  Codex, idle, addressed by its BARE code in UPPER case through `fleet-id.sh
#      clear` (C11's form): rc 0, a new codex segment (trigger clear)
#   C  busy — working / needs / looping / unset: rc 3, nothing typed, no segment
#   D  no such ID: rc 1; two windows carrying one ID, or a code two IDs share: rc 2
#   E  found without --socket (the login's fleet sockets); not an agent pane: rc 3
#   F  wired: the `clear` tool runs the script; bash-guard maps the script to it;
#      the send-keys refusal names it; fleet-id.sh documents `clear`
# tmux / python3 absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-repo-fixture.sh"
REAL_TMUX=$(command -v tmux) || { echo 'fleet-clear selftest: tmux absent — SKIP'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'fleet-clear selftest: python3 absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-clear.XXXXXX")" || exit 2
L="fclr592$$"
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1 FLEET_MOD=0 FLEET_ID_PUSH=0 FLEET_CLEAR_VERIFY_SECS=10
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
: > "$FLEET_CONF_DIR/fleets/$L/conf"
fx_repo "$FLEET_CONF_DIR" "$L" acme/app FLEET_MAIN="$WORK/main"
mkdir -p "$WORK/main"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_CODEX_LAUNCHER_PID CLAUDE_CODE_ENTRYPOINT FLEET_ID_HOOK

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { FLEET_ALLOW_TMUX_DESTROY=1 "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

tf -f /dev/null new-session -d -s "$L" -n home 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'fleet-clear selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }

# The fake TUI: a line ending in /clear (an Escape before it is part of the line) is
# a /clear — one SessionStart(source=clear) with a fresh native id.
cat > "$WORK/fake-tui.sh" <<EOF
#!/bin/bash
n=0
while IFS= read -r line; do
  case "\$line" in
    */clear) n=\$((n + 1))
      printf '{"hook_event_name":"SessionStart","source":"clear","session_id":"%s-%d"}' "\$1" "\$n" \\
        | bash "$BIN/fleet-id.sh" hook ;;
  esac
done
EOF
# agentwin <fid> <claude|codex> <native prefix> → `<window> <pane>`
agentwin() {
  local w p env=(-e "FLEET_CONF_DIR=$FLEET_CONF_DIR" -e FLEET_ID_PUSH=0)
  [ "$2" = codex ] && env+=(-e FLEET_CODEX_LAUNCHER_PID=4242)
  w=$(tf new-window -d -P -F '#{window_id}' "${env[@]}" -t "$L:" bash "$WORK/fake-tui.sh" "$3")
  tf set-window-option -t "$w" @fleet_id "$1"
  tf set-window-option -t "$w" @cc_agent "$2"
  [ "$2" = codex ] && tf set-window-option -t "$w" @cc_launcher_pid 4242
  tf set-window-option -t "$w" @claude_state 'done'
  p=$(tf display-message -p -t "$w" '#{pane_id}')
  printf '%s %s' "$w" "$p"
}
segs() { python3 "$BIN/fleet_id.py" get "$1" --json | python3 -c 'import json,sys
print(" ".join("%s:%s:%s" % (s["agent"], s["native"], s["trigger"]) for s in json.load(sys.stdin)["segments"]))'; }
mkfid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
run() { out=$(bash "$BIN/fleet-clear-send.sh" "$@" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err"); }
AUDIT="$FLEET_CONF_DIR/logs/clear-send.log"

# ---- A · Claude, idle ------------------------------------------------------------
F1=$(mkfid)
read -r W1 _ <<EOF
$(agentwin "$F1" claude cc)
EOF
S1=$(bash "$BIN/fleet-id.sh" open "$F1" --window "$W1" --socket "$L" --agent claude --title 'A work')
run "$S1" --socket "$L" --by tester
ok; [ "$rc" = 0 ] || fail "A: an idle Claude session is cleared (rc 0)" "rc=$rc $err"
ok; case "$out" in "cleared $S1 $F1 seg 1 (clear) via send-keys") ;; *) fail "A: one result line" "$out" ;; esac
ok; [ "$(segs "$F1")" = "claude:cc-1:clear" ] || fail "A: the ledger gains a clear segment" "$(segs "$F1")"
ok; grep -q "by=tester id=$F1 .*window=$W1 agent=claude cleared" "$AUDIT" 2>/dev/null \
  || fail "A: one audit line names who, which ID and the window" "$(cat "$AUDIT" 2>/dev/null)"
run "$F1" --socket "$L" --by tester
ok; [ "$rc" = 0 ] && [ "$(segs "$F1")" = "claude:cc-1:clear claude:cc-2:clear" ] \
  || fail "A: a full ID works too; a second clear is a second segment" "rc=$rc $(segs "$F1")"

# ---- B · Codex, the bare code in lower case, through fleet-id.sh clear -------------
F2=$(mkfid)
read -r W2 _ <<EOF
$(agentwin "$F2" codex cx)
EOF
S2=$(bash "$BIN/fleet-id.sh" open "$F2" --window "$W2" --socket "$L" --agent codex --title 'B work')
UP=$(printf '%s' "$S2" | tr '[:upper:]' '[:lower:]')   # any case (C11)
out=$(bash "$BIN/fleet-id.sh" clear "$UP" --socket "$L" 2>"$WORK/err"); rc=$?
ok; [ "$rc" = 0 ] || fail "B: an idle Codex session is cleared by its lower-case bare code" "rc=$rc $(cat "$WORK/err")"
ok; [ "$(segs "$F2")" = "codex:cx-1:clear" ] || fail "B: a codex clear segment" "$(segs "$F2")"

# ---- C · busy: refused, nothing typed ----------------------------------------------
for st in working needs looping ''; do
  if [ -n "$st" ]; then tf set-window-option -t "$W1" @claude_state "$st"
  else tf set-window-option -u -t "$W1" @claude_state; fi
  run "$S1" --socket "$L"
  ok; [ "$rc" = 3 ] || fail "C: @claude_state=${st:-unset} is refused (rc 3)" "rc=$rc $err"
done
sleep 1
ok; [ "$(segs "$F1" | wc -w | tr -d ' ')" = 2 ] || fail "C: a refusal adds no segment" "$(segs "$F1")"
tf set-window-option -t "$W1" @claude_state 'done'
ok; grep -q "id=$F1 .*refused rc=3" "$AUDIT" || fail "C: a refusal is audited too" "$(cat "$AUDIT")"

# ---- D · no such ID, ambiguous -----------------------------------------------------
run "$(mkfid)" --socket "$L"
ok; [ "$rc" = 1 ] || fail "D: an ID no window carries is refused (rc 1)" "rc=$rc $err"
run T-zzzzz --socket "$L"
ok; [ "$rc" = 1 ] || fail "D: a code nothing has is refused (rc 1)" "rc=$rc $err"
F3=$(mkfid)
agentwin "$F3" claude d1 >/dev/null; agentwin "$F3" claude d2 >/dev/null
run "$F3" --socket "$L"
ok; [ "$rc" = 2 ] || fail "D: two windows carrying one ID is refused (rc 2)" "rc=$rc $err"
A1=22222222-2222-4222-8222-222222222221 A2=22222222-2222-4222-8222-222222222222
agentwin "$A1" claude e1 >/dev/null; agentwin "$A2" claude e2 >/dev/null
run "$(python3 "$BIN/fleet_id.py" encode "$A1" | cut -c1-6)" --socket "$L"
ok; [ "$rc" = 2 ] && case "$err" in *"$A1"*"$A2"*|*"$A2"*"$A1"*) true ;; *) false ;; esac \
  || fail "D: a code two IDs share is refused (rc 2), both named" "rc=$rc $err"

# ---- E · the login's sockets; not an agent ----------------------------------------
run "$S1"
ok; [ "$rc" = 0 ] && [ "$(segs "$F1" | wc -w | tr -d ' ')" = 3 ] \
  || fail "E: with no --socket the login's fleet sockets are searched" "rc=$rc $err $(segs "$F1")"
F4=$(mkfid)
W4=$(tf new-window -d -P -F '#{window_id}' -t "$L:" 'while :; do sleep 300; done')
tf set-window-option -t "$W4" @fleet_id "$F4"; tf set-window-option -t "$W4" @cc_agent shell
tf set-window-option -t "$W4" @claude_state 'done'
run "$F4" --socket "$L"
ok; [ "$rc" = 3 ] || fail "E: a window that is no agent session is refused (rc 3)" "rc=$rc $err"

# ---- F · wired ---------------------------------------------------------------------
ok; python3 "$BIN/fleet-mcp.py" --group orch --list | grep -qx clear || fail "F: fleet-orch lists clear"
ok; grep -q '"fleet-clear-send.sh"), args\["id"\]' "$BIN/fleet-mcp.py" || fail "F: the clear tool runs fleet-clear-send.sh"
ok; grep -q '"fleet-clear-send.sh": ("clear", None)' "$BIN/../hooks/bash-guard.py" || fail "F: bash-guard maps the script to its tool"
ok; grep -q 'a /clear goes' "$BIN/../hooks/bash-guard.py" || fail "F: the send-keys refusal names the clear road"
ok; bash "$BIN/fleet-id.sh" --help | grep -q 'fleet-id.sh clear' || fail "F: fleet-id.sh documents clear"

if [ "$FAIL" -eq 0 ]; then printf 'fleet-clear-send selftest: PASS (%d checks)\n' "$CHECKS"; exit 0; fi
printf 'fleet-clear-send selftest: %d FAIL of %d\n' "$FAIL" "$CHECKS" >&2
exit 1
