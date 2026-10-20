#!/bin/bash
# fleet-id-selftest.sh — one window, one ID, its native segments (EPIC T497 C1;
# the design page's §4.6 samples). On an isolated tmux server and a sandbox conf
# dir, `fleet-id.sh hook` is fed the SessionStart payloads the agents send and
# bin/fleet_id.py's ledger is read back:
#   S1   two /clear in a row: the ID (@fleet_id) and its short code (@task_short)
#        stay, two more segments (trigger clear), a result reported before them is
#        still there
#   S3   the handoff cycle's /clear (its @id_next_trigger mark — consumed — or
#        @handoff_cycle): a new segment, trigger handoff
#   S4   Claude→Codex (fleet-transfer.sh): the Codex launcher's first turn adds a
#        segment, agent codex, trigger transfer; a hook from a stale launcher pid
#        adds nothing
#   S5   /compact three times: no new segment, the current one counts 3
#   S6   a non-proxy account move (a NEW tmux window carrying the same @fleet_id,
#        `--resume`): same native id ⇒ nothing, another ⇒ one segment, resume
#   S11  a Codex window restored before its first turn: the ID answers with no
#        segment at all, the first turn adds segment 1 (startup)
#   CODE short codes (C11): 4 uppercase Crockford base32, the first a letter (never
#        a number), one longer when another known ID shares the prefix; `K3F9` /
#        `#k3f9` resolves (case-folded, I/L/O read as 1/1/0), a number never does;
#        a prefix two IDs share is refused with both named (rc 2); the old `T-` +
#        lowercase code still resolves (compat-1v) and an old `T-` short in a ledger
#        is read as nothing; fleet_win_for_addr takes a code, fleet-peer-send.sh a
#        code target (an ambiguous one refused, a unique one lands on that window,
#        its receipt naming `#CODE`), the MCP send tool lets a code through
#   HOOK never blocks: no tmux / a headless child / garbage stdin ⇒ exit 0, no
#        output, nothing written; a ledger it cannot write is kept on the window
#        (@id_retry) and flushed by the next hook
#   WIRE the SessionStart table runs `fleet-id.sh hook`; both spawners open the
#        ledger; the handoff cycle marks its /clear
# tmux / python3 absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-repo-fixture.sh"
REAL_TMUX=$(command -v tmux) || { echo 'fleet-id selftest: tmux absent — SKIP'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'fleet-id selftest: python3 absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-id.XXXXXX")" || exit 2
L="fid497$$"
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
: > "$FLEET_CONF_DIR/fleets/$L/conf"
fx_repo "$FLEET_CONF_DIR" "$L" acme/app FLEET_MAIN="$WORK/main"
mkdir -p "$WORK/main"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_CODEX_LAUNCHER_PID CLAUDE_CODE_ENTRYPOINT FLEET_ID_HOOK

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
tf() { "$REAL_TMUX" -L "$L" "$@"; }
opt() { tf show-options -wqv -t "$1" "$2"; }
cleanup() { FLEET_ALLOW_TMUX_DESTROY=1 "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
lib() { bash -c '. "$1/fleet-lib.sh"; shift; "$@"' _ "$BIN" "$@"; }

tf -f /dev/null new-session -d -s "$L" -n home 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'fleet-id selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
SOCKP=$(tf display-message -p '#{socket_path}')
SPID=$(tf display-message -p '#{pid}')

# newwin <fid> → a window carrying that @fleet_id, its pane id on stdout
newwin() {
  local w p
  w=$(tf new-window -d -P -F '#{window_id}' -t "$L:" 'while :; do sleep 300; done')
  [ -n "${1:-}" ] && tf set-window-option -t "$w" @fleet_id "$1"
  p=$(tf display-message -p -t "$w" '#{pane_id}')
  printf '%s %s' "$w" "$p"
}
# hook <pane> <source> <session_id> [env…] — one SessionStart, as the agent sends it
hook() {
  local pane=$1 src=$2 sid=$3; shift 3
  printf '{"hook_event_name":"SessionStart","source":"%s","session_id":"%s"}' "$src" "$sid" \
    | env TMUX="$SOCKP,$SPID,0" TMUX_PANE="$pane" "$@" bash "$BIN/fleet-id.sh" hook
}
segs() { python3 "$BIN/fleet_id.py" get "$1" --json | python3 -c 'import json,sys
d=json.load(sys.stdin); print(" ".join("%s:%s:%s:%d" % (s["agent"], s["native"], s["trigger"], s["compactions"]) for s in d["segments"]))'; }
results() { python3 "$BIN/fleet_id.py" get "$1" --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["results"]))'; }
mkfid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
U1=11111111-1111-4111-8111-111111111111

# ---- S1 · /clear twice ----------------------------------------------------------
F1=$(mkfid)
read -r W1 P1 <<EOF
$(newwin "$F1")
EOF
short=$(bash "$BIN/fleet-id.sh" open "$F1" --window "$W1" --socket "$L" --agent claude --repo acme/app --title 'S1 work')
ok; case "$short" in [A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z]) ;; *) fail "S1: open prints a 4-character code, letter first" "$short" ;; esac
ok; [ "$(opt "$W1" @task_short)" = "$short" ] || fail "S1: open stamps @task_short on --window" "$(opt "$W1" @task_short)"
hook "$P1" startup aaaa0001
python3 "$BIN/fleet_id.py" result "$F1" --state succeeded --summary 'first' --pr 7
hook "$P1" clear aaaa0002
hook "$P1" clear aaaa0003
ok; [ "$(segs "$F1")" = "claude:aaaa0001:startup:0 claude:aaaa0002:clear:0 claude:aaaa0003:clear:0" ] \
  || fail "S1: startup + two clears = three segments" "$(segs "$F1")"
ok; [ "$(opt "$W1" @fleet_id)" = "$F1" ] && [ "$(opt "$W1" @task_short)" = "$short" ] \
  || fail "S1: the ID and its short code do not change across /clear" "$(opt "$W1" @fleet_id) $(opt "$W1" @task_short)"
ok; [ "$(results "$F1")" = 1 ] || fail "S1: the result reported before the clears is still there" "$(results "$F1")"
hook "$P1" clear aaaa0003
ok; [ "$(segs "$F1" | wc -w | tr -d ' ')" = 3 ] || fail "S1: a repeated hook for the same native id adds nothing" "$(segs "$F1")"

# ---- S3 · the handoff cycle's /clear --------------------------------------------
tf set-window-option -t "$W1" @id_next_trigger "handoff:$(date +%s)"
hook "$P1" clear aaaa0004
ok; [ "$(segs "$F1" | awk '{print $NF}')" = "claude:aaaa0004:handoff:0" ] || fail "S3: the marked /clear is a handoff segment" "$(segs "$F1")"
ok; [ -z "$(opt "$W1" @id_next_trigger)" ] || fail "S3: the hook takes the mark off the window"
tf set-window-option -t "$W1" @id_next_trigger "handoff:1000"
hook "$P1" clear aaaa0005
ok; [ "$(segs "$F1" | awk '{print $NF}')" = "claude:aaaa0005:clear:0" ] || fail "S3: a stale mark is no handoff" "$(segs "$F1")"
tf set-window-option -t "$W1" @handoff_cycle "$(date +%s):123"
hook "$P1" clear aaaa0006
tf set-window-option -u -t "$W1" @handoff_cycle
ok; [ "$(segs "$F1" | awk '{print $NF}')" = "claude:aaaa0006:handoff:0" ] || fail "S3: a /clear while the cycle owns the window is a handoff" "$(segs "$F1")"

# ---- S5 · /compact three times --------------------------------------------------
for _ in 1 2 3; do hook "$P1" compact aaaa0006; done
ok; [ "$(segs "$F1" | awk '{print $NF}')" = "claude:aaaa0006:handoff:3" ] || fail "S5: three compacts count on the current segment" "$(segs "$F1")"
ok; [ "$(segs "$F1" | wc -w | tr -d ' ')" = 6 ] || fail "S5: a compact opens no segment" "$(segs "$F1")"

# ---- S4 · Claude → Codex --------------------------------------------------------
tf set-window-option -t "$W1" @cc_agent codex
tf set-window-option -t "$W1" @cc_launcher_pid 4242
hook "$P1" startup bbbb0001 FLEET_CODEX_LAUNCHER_PID=9999
ok; [ "$(segs "$F1" | wc -w | tr -d ' ')" = 6 ] || fail "S4: a stale launcher's hook adds nothing" "$(segs "$F1")"
hook "$P1" startup bbbb0001 FLEET_CODEX_LAUNCHER_PID=4242
ok; [ "$(segs "$F1" | awk '{print $NF}')" = "codex:bbbb0001:transfer:0" ] || fail "S4: the Codex first turn is a transfer segment" "$(segs "$F1")"
ok; [ "$(opt "$W1" @fleet_id)" = "$F1" ] || fail "S4: the transfer keeps the ID"
ok; python3 "$BIN/fleet_id.py" get "$F1" | grep -q 'codex  bbbb0001' || fail "S4: get lists the codex segment" "$(python3 "$BIN/fleet_id.py" get "$F1")"
hook "$P1" startup bbbb0002 FLEET_CODEX_LAUNCHER_PID=4242
ok; [ "$(segs "$F1" | awk '{print $NF}')" = "codex:bbbb0002:new:0" ] || fail "S4: a new Codex thread in the window is a new segment" "$(segs "$F1")"

# ---- S6 · a non-proxy move: a new window, the same ID, --resume --------------------
F6=$(mkfid)
read -r W6 P6 <<EOF
$(newwin "$F6")
EOF
bash "$BIN/fleet-id.sh" open "$F6" --window "$W6" --socket "$L" --agent claude >/dev/null
hook "$P6" startup cccc0001
FLEET_ALLOW_TMUX_DESTROY=1 tf kill-window -t "$W6"
read -r W6b P6b <<EOF
$(newwin "$F6")
EOF
ok; [ "$W6b" != "$W6" ] || fail "S6: the new tmux window has another @window_id"
hook "$P6b" resume cccc0001
ok; [ "$(segs "$F6")" = "claude:cccc0001:startup:0" ] || fail "S6: the same native id after the move opens no segment" "$(segs "$F6")"
hook "$P6b" resume cccc0002
ok; [ "$(segs "$F6")" = "claude:cccc0001:startup:0 claude:cccc0002:resume:0" ] || fail "S6: another native id is one resume segment" "$(segs "$F6")"
ok; [ "$(opt "$W6b" @task_short)" = "$(python3 "$BIN/fleet_id.py" short "$F6")" ] || fail "S6: the hook stamps the moved window's short code"

# ---- S11 · Codex restored before its first turn ----------------------------------
F11=$(mkfid)
read -r W11 P11 <<EOF
$(newwin "$F11")
EOF
s11=$(bash "$BIN/fleet-id.sh" open "$F11" --window "$W11" --socket "$L" --agent codex)
FLEET_ALLOW_TMUX_DESTROY=1 tf kill-window -t "$W11"
read -r W11 P11 <<EOF
$(newwin "$F11")
EOF
tf set-window-option -t "$W11" @cc_agent codex; tf set-window-option -t "$W11" @cc_launcher_pid 77
ok; [ -z "$(segs "$F11")" ] || fail "S11: no segment before the first turn" "$(segs "$F11")"
ok; [ "$(lib fleet_win_for_addr "$s11" "$L")" = "$W11" ] || fail "S11: the ID answers with no segment" "$(lib fleet_win_for_addr "$s11" "$L" 2>&1)"
hook "$P11" startup dddd0001 FLEET_CODEX_LAUNCHER_PID=77
ok; [ "$(segs "$F11")" = "codex:dddd0001:startup:0" ] || fail "S11: the first turn adds segment 1" "$(segs "$F11")"

# ---- CODE · short codes and addressing ------------------------------------------
enc=$(python3 "$BIN/fleet_id.py" encode "$U1")
ok; [ "${#enc}" = 26 ] && [ "$(printf '%s' "$enc" | tr -d '0-9ABCDEFGHJKMNPQRSTVWXYZ')" = '' ] \
  && case "$enc" in [A-Z]*) true ;; *) false ;; esac \
  || fail "CODE: the full code is 26 uppercase Crockford characters, a letter first" "$enc"
# every ID's code starts with a letter — the lowest and highest IDs included
for u in 00000000-0000-4000-8000-000000000000 ffffffff-ffff-4fff-bfff-ffffffffffff; do
  e=$(python3 "$BIN/fleet_id.py" encode "$u")
  ok; case "$e" in [A-HJKMNP-TV-Z]*) ;; *) fail "CODE: a code's first character is a letter" "$u → $e" ;; esac
done
# two IDs whose codes share 5 characters: the second one's code is 6 long
CA=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_id, uuid
a = uuid.UUID(int=(0x12345 << 108) | (4 << 76) | (2 << 62) | 1); print(a)' "$BIN")
CB=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_id, uuid
b = uuid.UUID(int=(0x12345 << 108) | (1 << 100) | (4 << 76) | (2 << 62) | 2); print(b)' "$BIN")
sa=$(bash "$BIN/fleet-id.sh" open "$CA" --agent claude)
sb=$(bash "$BIN/fleet-id.sh" open "$CB" --agent claude)
ok; [ "${#sa}" = 4 ] && [ "${#sb}" -gt 4 ] && [ "${sb:0:4}" = "$sa" ] \
  || fail "CODE: the first takes 4 characters, the one sharing them more" "$sa $sb"
out=$(bash "$BIN/fleet-id.sh" resolve "$sa" 2>&1); rc=$?
ok; [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "$CA" && printf '%s' "$out" | grep -q "$CB" \
  || fail "CODE: the shared 4-character prefix is refused, both IDs named (rc 2)" "rc=$rc $out"
ok; [ "$(bash "$BIN/fleet-id.sh" resolve "$sb")" = "$CB" ] || fail "CODE: the 6-character code names one ID"
lower="#$(printf '%s' "$short" | tr 'A-Z' 'a-z')"
ok; [ "$(bash "$BIN/fleet-id.sh" resolve "$lower")" = "$F1" ] || fail "CODE: a code resolves case-folded, # or not" "$lower"
bash "$BIN/fleet-id.sh" resolve 4539 >/dev/null 2>&1; rc=$?
ok; [ "$rc" = 1 ] || fail "CODE: a number is never a code" "$rc"
# the old code (`T-` + 5 lowercase) still resolves for one version (compat-1v)
old5=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_id; print("T-" + fleet_id.legacy_encode(sys.argv[2])[:5])' "$BIN" "$F1")
ok; [ "$(bash "$BIN/fleet-id.sh" resolve "$old5")" = "$F1" ] || fail "CODE: the old T- code still resolves" "$old5"
bash "$BIN/fleet-id.sh" resolve "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_id; print("T-" + fleet_id.legacy_encode(sys.argv[2])[:5])' "$BIN" "$CA")" >/dev/null 2>&1; rc=$?
ok; [ "$rc" = 2 ] || fail "CODE: an old T- code two IDs share is refused (rc 2)" "$rc"
# a ledger written before C11 (its `short` is `T-…`) reads as today's code
FO=$(mkfid)
printf '{"ev":"opened","agent":"claude","short":"T-abcde","id":"%s","seq":1,"ts":1}\n' "$FO" > "$FLEET_CONF_DIR/ids/$FO.ndjson"
so=$(bash "$BIN/fleet-id.sh" short "$FO")
ok; [ "$so" = "$(python3 "$BIN/fleet_id.py" encode "$FO" | cut -c1-4)" ] || fail "CODE: an old T- short in a ledger is recomputed" "$so"
ok; [ "$(bash "$BIN/fleet-id.sh" resolve "$F1")" = "$F1" ] || fail "CODE: a full ID resolves to itself"
bash "$BIN/fleet-id.sh" resolve ZZZZZZ >/dev/null 2>&1; rc=$?
ok; [ "$rc" = 1 ] || fail "CODE: a code nobody has is rc 1" "$rc"
# a live window with no ledger is still an ID a code names
FL=$(mkfid); read -r WL PL <<EOF
$(newwin "$FL")
EOF
cl=$(python3 "$BIN/fleet_id.py" short "$FL")
ok; [ "$(lib fleet_win_for_addr "$cl" "$L")" = "$WL" ] || fail "CODE: a live window with no ledger answers to its code" "$(lib fleet_win_for_addr "$cl" "$L" 2>&1)"
ok; [ "$(lib fleet_win_for_addr "$short" "$L")" = "$W1" ] || fail "CODE: fleet_win_for_addr takes a code"
ok; [ "$(lib fleet_win_for_addr "#$short" "$L")" = "$W1" ] || fail "CODE: fleet_win_for_addr takes a #code"
ok; [ "$(lib fleet_win_for_addr "$old5" "$L")" = "$W1" ] || fail "CODE: fleet_win_for_addr takes the old T- code"
lib fleet_win_for_addr "$sa" "$L" >/dev/null 2>&1; rc=$?
ok; [ "$rc" = 2 ] || fail "CODE: fleet_win_for_addr refuses an ambiguous code (rc 2)" "$rc"
# fleet-peer-send.sh: an ambiguous code refused with the candidates; a unique one
# lands on its window (no Claude there: it is queued for that window's identity)
out=$(bash "$BIN/fleet-peer-send.sh" "$sa" hello 2>&1); rc=$?
ok; [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'ambiguous' && printf '%s' "$out" | grep -q "$CB" \
  || fail "CODE: peer-send refuses an ambiguous code target, naming the candidates" "rc=$rc $out"
s6=$(python3 "$BIN/fleet_id.py" short "$F6")
out=$(bash "$BIN/fleet-peer-send.sh" "$s6" hello 2>&1); rc=$?
ok; { [ "$rc" = 3 ] || [ "$rc" = 0 ]; } && printf '%s' "$out" | grep -q "#$s6" \
  || fail "CODE: peer-send takes a code target to its window, the receipt naming #CODE" "rc=$rc $out"
ok; grep -qF '|#[A-Za-z][0-9A-Za-z]{3,25}|[A-Z][0-9A-Z]{3,25}' "$BIN/fleet-mcp.py" || fail "CODE: the MCP send tool lets a code through"

# ---- HOOK · never blocks, never speaks ------------------------------------------
n0=$(ls "$FLEET_CONF_DIR/ids" | wc -l | tr -d ' ')
out=$(printf '{"source":"startup","session_id":"x"}' | env -u TMUX bash "$BIN/fleet-id.sh" hook 2>&1); rc=$?
ok; [ "$rc" = 0 ] && [ -z "$out" ] || fail "HOOK: outside tmux it exits 0 silently" "rc=$rc $out"
out=$(printf 'not json' | env TMUX="$SOCKP,$SPID,0" TMUX_PANE="$PL" bash "$BIN/fleet-id.sh" hook 2>&1); rc=$?
ok; [ "$rc" = 0 ] && [ -z "$out" ] || fail "HOOK: garbage stdin exits 0 silently" "rc=$rc $out"
hook "$PL" startup eeee0001 CLAUDE_CODE_ENTRYPOINT=sdk-cli
ok; [ "$(ls "$FLEET_CONF_DIR/ids" | wc -l | tr -d ' ')" = "$n0" ] || fail "HOOK: a headless child (claude -p) writes nothing"
# an unwritable ledger dir: kept on the window, flushed by the next hook
FR=$(mkfid); read -r WR PR <<EOF
$(newwin "$FR")
EOF
mkdir -p "$WORK/ro"; chmod 500 "$WORK/ro"
out=$(printf '{"source":"startup","session_id":"ffff0001"}' | env TMUX="$SOCKP,$SPID,0" TMUX_PANE="$PR" \
  FLEET_ID_DIR="$WORK/ro/ids" bash "$BIN/fleet-id.sh" hook 2>&1); rc=$?
chmod 700 "$WORK/ro"
ok; [ "$rc" = 0 ] && [ -z "$out" ] && opt "$WR" @id_retry | grep -q ffff0001 \
  || fail "HOOK: a write that fails is kept on the window (@id_retry)" "rc=$rc out=$out retry=$(opt "$WR" @id_retry)"
hook "$PR" compact ffff0001
ok; [ "$(segs "$FR")" = "claude:ffff0001:startup:1" ] && [ -z "$(opt "$WR" @id_retry)" ] \
  || fail "HOOK: the next hook flushes the kept segment first" "$(segs "$FR") retry=$(opt "$WR" @id_retry)"
ok; python3 "$BIN/fleet_id.py" get "$FR" --json | grep -q '"lazy": true' || fail "HOOK: a window no spawn recorded gets a lazy opened"

# ---- WIRE --------------------------------------------------------------------------
ok; python3 - "$BIN/../hooks/settings-hooks.json" <<'PY' || fail "WIRE: the SessionStart table runs fleet-id.sh hook (no matcher: every source)"
import json, sys
d = json.load(open(sys.argv[1]))
h = d.get("hooks", d)["SessionStart"]
assert any("matcher" not in g and any(x["command"].endswith("bin/fleet-id.sh hook") for x in g["hooks"]) for g in h)
PY
ok; grep -q 'fleet-id.sh" open' "$BIN/dash-issue-session.sh" && grep -q 'fleet-id.sh" open' "$BIN/dash-raw-session.sh" \
  || fail "WIRE: both spawners open the ledger"
ok; grep -q '@id_next_trigger "handoff:' "$BIN/fleet-handoff-cycle.sh" || fail "WIRE: the handoff cycle marks its /clear"

[ "$FAIL" -eq 0 ] || { printf 'fleet-id selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2; exit 1; }
printf 'fleet-id selftest: all %d checks pass\n' "$CHECKS"
