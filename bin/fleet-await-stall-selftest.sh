#!/bin/bash
# fleet-await-stall-selftest.sh — fleet-await.sh's STALL LADDER (issue #1268).
#
# What is load-bearing, and therefore what is pinned (FLEET_AWAIT_STALL_SECS=2):
#   LADDER    a child that sits in `done` climbs all five rungs in order — wake,
#             wake, brief, parent, alert — ONE `wake` ledger row per rung, the
#             right recipient each time, and the fifth raises the stall alert,
#             which the child's landing clears.
#   RESET     a new report mid-ladder writes a level-0 `reset` row and the next
#             stall starts at rung 1 again.
#   UNKNOWN   a window with no @claude_state never climbs.
#   BUSY      `working` with the pane burning CPU never climbs.
#   RESUME    a wait killed at rung 2 and started again climbs on at rung 3.
#   READERS   wake rows stay out of the report readers (summary, dedup) and show
#             up as `fleet-children.sh --json`'s `wakes` list.
#
# Runs on a DEDICATED tmux server on its own -L label (never the live server,
# issue #159), from a sandbox bin/ whose fleet-peer-send.sh is a stub that logs
# (panes run `sleep`, not Claude); the ledger and the alert file are the real ones.
# The BUSY pane spins under a kernel alarm(2) — no trap, nothing to leak (#697).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-await.sh fleet-children.sh fleet-children.py fleet-children-lib.sh fleet-alerts.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }
done
command -v tmux >/dev/null 2>&1 || { printf 'fleet-await-stall selftest: tmux absent — skipped\n'; exit 0; }

CHECKS=0
fail() { printf 'fleet-await-stall selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()   { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1" "expected: [$2]"$'\n'"got:      [$3]"; }
has()  { CHECKS=$((CHECKS + 1)); case "$3" in *"$2"*) : ;; *) fail "$1" "$3" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-await-stall.XXXXXX")" || exit 2
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR" "$WORK/.claude-dash/global"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
export FLEET_AWAIT_STALL_SECS=2
unset TMUX TMUX_PANE

SB="$WORK/bin"; mkdir -p "$SB"
for f in "$BIN"/*; do ln -s "$f" "$SB/${f##*/}"; done
rm -f "$SB/fleet-peer-send.sh"
cat > "$SB/fleet-peer-send.sh" <<'STUB'
#!/bin/bash
while [ "$#" -gt 0 ]; do case "$1" in -L|--repo) shift 2 ;; *) break ;; esac; done
printf '%s\t%s\n' "$1" "$2" >> "$PEER_LOG"
printf 'sent → %s (stub)\n' "$1"
STUB
chmod +x "$SB/fleet-peer-send.sh"
export PEER_LOG="$WORK/peer"; : > "$PEER_LOG"
AW="$SB/fleet-await.sh"

LBL="fawstall-selftest-$$"
trap 'tmux -L "$LBL" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT
TM() { tmux -L "$LBL" "$@"; }
TM new-session -d -s "$LBL" -n dash -c "$WORK" "sleep 600" 2>/dev/null || fail "could not start the selftest tmux server"
mkdir -p "$WORK/repo-scratch-7"
P=$(TM new-window -d -P -F '#{window_id}' -n parent -c "$WORK" "sleep 600")
TM set-window-option -t "$P" @raw 1; TM set-window-option -t "$P" @worktree "$WORK/repo-scratch-7"
LEDGER="$FLEET_CONF_DIR/fleets/$LBL/children/scratch-7.ndjson"

# child <N> <state|-> [cmd] — a live worker window parented on scratch-7.
child() {
  local w; w=$(TM new-window -d -P -F '#{window_id}' -n "issue-$1" "${3:-sleep 600}")
  TM set-window-option -t "$w" @issue "$1"; TM set-window-option -t "$w" @origin scratch-7
  [ "$2" = - ] || TM set-window-option -t "$w" @claude_state "$2"
  printf '%s' "$w"
}
# wakes <N> → the child's wake rows as `level:action` (space separated)
wakes() {
  python3 -c 'import json,sys
out = []
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e.get("type") == "wake" and e.get("child") == "issue-" + sys.argv[2]:
        out.append("%s:%s" % (e["level"], e["action"]))
print(" ".join(out))' "$LEDGER" "$1" 2>/dev/null
}
# until_wakes <N> <count> — bounded wait for that many wake rows.
until_wakes() {
  local i=0
  while [ "$(wakes "$1" | wc -w | tr -d ' ')" -lt "$2" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
}
await() { bash "$AW" "$@" -L "$LBL" --parent scratch-7 --interval 1 --no-spawn > "$WORK/out" 2> "$WORK/err" & AWAIT_PID=$!; }
collect() { wait "$AWAIT_PID"; RC=$?; OUT=$(cat "$WORK/out"); }
report() { bash "$SB/fleet-report-parent.sh" -L "$LBL" "$@" >/dev/null 2>&1; }
STALLF="$WORK/.claude-dash/global/alerts.stall/$LBL-issue-301"

# --- LADDER: five rungs, in order, one row each --------------------------------------
W=$(child 301 'done')
await 301 --timeout 40
until_wakes 301 5
eq "five rungs, in order, one ledger row each" \
   "1:nudge 2:nudge 3:brief 4:parent 5:alert" "$(wakes 301)"
eq "rungs 1-3 go to the child, rung 4 to the parent" \
   "issue:301 issue:301 issue:301 $P" "$(cut -f1 "$PEER_LOG" | tr '\n' ' ' | sed 's/ $//')"
has "rung 3 re-sends the task (claim brief)" 'fleet-claim-brief.sh' "$(sed -n 3p "$PEER_LOG")"
has "rung 4 names the stuck child" '#301' "$(sed -n 4p "$PEER_LOG")"
[ -f "$STALLF" ] || fail "rung 5 raised no stall alert" "$(cat "$WORK/err")"
CHECKS=$((CHECKS + 1))
alerts=$(bash "$SB/fleet-alerts.sh" write >/dev/null 2>&1; cat "$WORK/.claude-dash/global/alerts.ndjson")
has "…and it is a needs row: #301 · stalled" '"severity":"needs","subject":"#301","condition":"stalled"' "$alerts"
has "every rung is on stderr" 'wake 5/5 (alert)' "$(cat "$WORK/err")"
sleep 3
eq "nothing climbs past rung 5" 5 "$(wakes 301 | wc -w | tr -d ' ')"
report --win "$W" --state merged --pr 601
collect
eq "the child lands: MERGED" "0 MERGED" "$RC $(head -1 <<< "$OUT")"
[ ! -f "$STALLF" ] || fail "the landing did not clear the stall alert"
CHECKS=$((CHECKS + 1))

# READERS: wake rows are not reports.
J=$(bash "$SB/fleet-children.sh" scratch-7 --json -L "$LBL")
eq "the summary still reads the report, not a wake row" "1/1 ✓" \
   "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["summary"]["text"])' <<< "$J")"
eq "…and --json lists the wakes" "1 2 3 4 5" \
   "$(python3 -c 'import json,sys; print(" ".join(str(w["level"]) for w in json.load(sys.stdin)["wakes"]))' <<< "$J")"
[ -n "${FLEET_STALL_EVIDENCE:-}" ] && python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["wakes"], ensure_ascii=False, indent=1))' <<< "$J" > "$FLEET_STALL_EVIDENCE"

# --- RESET: progress mid-ladder ------------------------------------------------------
: > "$PEER_LOG"
W=$(child 302 'done')
await 302 --timeout 40
until_wakes 302 2
report --win "$W" --state waiting --pr 602
until_wakes 302 4
eq "a report mid-ladder resets it; the next stall starts at rung 1" \
   "1:nudge 2:nudge 0:reset 1:nudge" "$(wakes 302 | cut -d' ' -f1-4)"
has "…said on stderr" 'stall ladder reset' "$(cat "$WORK/err")"
report --win "$W" --state merged --pr 602; collect

# --- UNKNOWN and BUSY never climb ----------------------------------------------------
W=$(child 303 -)
await 303 --timeout 7; collect
eq "no @claude_state: no wake rows" "" "$(wakes 303)"
eq "…the wait just times out" 3 "$RC"
W=$(child 304 working "perl -e 'alarm 20; 1 while 1'")
FLEET_AWAIT_STALL_SECS=3 bash "$AW" 304 -L "$LBL" --parent scratch-7 --interval 2 --no-spawn --timeout 9 \
  > "$WORK/out" 2> "$WORK/err"
eq "a busy pane stays live for the whole wait (TIMEOUT)" 3 "$?"
eq "working with a busy pane: no wake rows" "" "$(wakes 304)"
TM kill-window -t "$W"
W=$(child 305 working)
await 305 --timeout 30
until_wakes 305 1
eq "working with an IDLE pane is a stall" "1:nudge" "$(wakes 305 | cut -d' ' -f1)"
report --win "$W" --state merged --pr 605; collect

# --- RESUME: a restarted wait climbs on ----------------------------------------------
W=$(child 306 'done')
await 306 --timeout 40
until_wakes 306 2
kill "$AWAIT_PID" 2>/dev/null; wait "$AWAIT_PID" 2>/dev/null
eq "killed at rung 2" "1:nudge 2:nudge" "$(wakes 306)"
await 306 --timeout 40
until_wakes 306 3
eq "the restarted wait goes on at rung 3, not 1" "1:nudge 2:nudge 3:brief" "$(wakes 306 | cut -d' ' -f1-3)"
has "…and says so" 'resumes at wake 2/5' "$(cat "$WORK/err")"
report --win "$W" --state merged --pr 606; collect

printf 'fleet-await-stall selftest: OK (%d checks)\n' "$CHECKS"
