#!/bin/bash
# fleet-children-selftest.sh — the child-report ledger + `fleet-children.sh`
# (issue #937, EPIC #935 C3).
#
# What is load-bearing, and therefore what is pinned:
#   RECORD    every report fleet-report-parent.sh resolves a parent for is written
#             to $FLEET_STATE/children/<parent-key>.ndjson — whether or not it is
#             DELIVERED (the parent here runs no Claude, so nothing is delivered).
#   DEDUP     a repeat of a child's latest (state, pr) adds no line; a real
#             transition does, with the next seq.
#   AGREE     fleet-children.sh's summary line is BYTE-EQUAL to the dash parent
#             row's badge (`2/3 ✓ · 1!`) — same attribution walk (chain_v), same
#             state ranks. The dash is run for real, on a fixture built from the
#             same server.
#   SURVIVE   a parent migrated onto a new window id (same key) reads the same
#             ledger; a reaped child stays in the book, counted by its report.
#   DEFAULT   with no argument the key is the calling pane's own (fleet_origin_key).
#
# Runs on a DEDICATED tmux server on its own -L label (never the live server,
# issue #159). The dash half replays that server's window list through a PATH shim,
# because tmux ≤3.4 vis-escapes the 0x1f separator the dash producer asks for.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CLI="$BIN/fleet-children.sh"; RP="$BIN/fleet-report-parent.sh"; ROWS="$BIN/tmux-dashboard-rows.sh"
for f in "$CLI" "$RP" "$ROWS" "$BIN/fleet-children.py" "$BIN/fleet-children-lib.sh"; do
  [ -f "$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }
done

CHECKS=0
fail() { printf 'fleet-children selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()   { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1" "expected: [$2]"$'\n'"got:      [$3]"; }
has()  { CHECKS=$((CHECKS + 1)); case "$3" in *"$2"*) : ;; *) fail "$1" "$3" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-children.XXXXXX")" || exit 2
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR" "$WORK/.claude-dash/global"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
unset TMUX TMUX_PANE

# --- 1. usage + the pure append layer (no server) ------------------------------
out=$(bash "$CLI" --bogus 2>&1); eq "an unknown flag exits 2" 2 "$?"
out=$(bash "$CLI" --since x issue-1 2>&1); eq "a non-numeric --since exits 2" 2 "$?"
out=$(bash "$CLI" 2>&1); eq "no key and no pane exits 2" 2 "$?"
has "…and says why" 'no parent key' "$out"

F="$WORK/pure.ndjson"
ap() { printf '%s' "$1" | python3 "$BIN/fleet-children.py" append --file "$F"; }
ap '{"child":"issue-1","state":"merged","pr":"#7","summary":"a <b> \"c\""}' >/dev/null
eq "append writes one line" 1 "$(wc -l < "$F" | tr -d ' ')"
python3 - "$F" <<'PY' || fail "append must normalise state/pr and scrub <>\" (see above)"
import json, sys
e = json.loads(open(sys.argv[1]).readline())
assert e["seq"] == 1 and e["state"] == "MERGED" and e["pr"] == "7", e
assert e["summary"] == "a b c", e
assert set(e) >= {"seq", "ts", "child", "state", "pr", "verdict", "summary", "title"}, e
PY
CHECKS=$((CHECKS + 1))
ap '{"child":"issue-1","state":"MERGED","pr":"7"}' >/dev/null
eq "a repeat of the latest (child,state,pr) adds nothing" 1 "$(wc -l < "$F" | tr -d ' ')"
printf '%s' '{"child":"issue-1","state":"SHIPPED"}' | python3 "$BIN/fleet-children.py" append --file "$F" >/dev/null 2>&1
eq "an unknown state is refused" 2 "$?"

# --- TIER (issue #938): report_tier is the ONE place the bands are decided -------
# Every state → its band, plus the three modifiers (a fixing FAILED, an unlanded
# reap, a child in `needs`). C5's digest and R1's wait read this same function.
( . "$BIN/fleet-lib.sh"; . "$BIN/fleet-children-lib.sh"
  t() { printf '%s=%s ' "$1" "$(report_tier "$@")"; }
  t BLOCKED; t FAILED 'tests red'; t FAILED 'RED: CI failure or merge conflict; fixing it'
  t FAILED 'CI 挂了，正在修'; t REAPED '' unmerged; t REAPED '' dirty; t REAPED '' merged
  t REAPED '' keep; t STOPPED; t MERGED; t merged; t WAITING '' pr-open; t IDLE '' pr-unknown
  t MERGED '' '' needs; t WAITING '' bg needs; t SHIPPED ) > "$WORK/tiers"
eq "report_tier bands every state" \
  'BLOCKED=loud FAILED=loud FAILED=quiet FAILED=quiet REAPED=loud REAPED=loud REAPED=quiet REAPED=quiet STOPPED=loud MERGED=quiet merged=quiet WAITING=silent IDLE=silent MERGED=loud WAITING=loud SHIPPED=loud ' \
  "$(cat "$WORK/tiers")"
modes=$( . "$BIN/fleet-lib.sh"; . "$BIN/fleet-children-lib.sh"
  for v in '' 1 immediate batch 0 off bogus; do printf '%s ' "$(FLEET_CHILD_REPORT="$v" children_report_mode)"; done )
eq "children_report_mode: legacy 1/unset/unknown ⇒ immediate" \
  'immediate immediate immediate batch 0 0 immediate ' "$modes"
F2="$WORK/tier.ndjson"
printf '%s' '{"child":"issue-2","state":"WAITING","tier":"silent"}' | python3 "$BIN/fleet-children.py" append --file "$F2" >/dev/null
printf '%s' '{"child":"issue-3","state":"MERGED","tier":"LOUDER"}' | python3 "$BIN/fleet-children.py" append --file "$F2" >/dev/null
eq "append keeps a valid tier and blanks an invalid one" 'silent|' \
  "$(python3 -c 'import json,sys; print("|".join(json.loads(l)["tier"] for l in open(sys.argv[1])))' "$F2")"

command -v tmux >/dev/null 2>&1 || { printf 'fleet-children selftest: tmux absent — pure layer only (%d checks)\n' "$CHECKS"; rm -rf "$WORK"; exit 0; }

# --- 2. end to end on a dedicated server ----------------------------------------
LBL="fch-selftest-$$"
trap 'tmux -L "$LBL" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT
TM() { tmux -L "$LBL" "$@"; }
TM new-session -d -s "$LBL" -n dash -c "$WORK" "sleep 600" 2>/dev/null || fail "could not start the selftest tmux server"
WID=''
new_win() { WID=$(TM new-window -d -P -F '#{window_id}' -n "$1" -c "$WORK" "sleep 600" 2>/dev/null); [ -n "$WID" ] || fail "could not create window $1"; }
opt() { TM set-window-option -t "$1" "$2" "$3" 2>/dev/null; }

mkdir -p "$WORK/repo-scratch-7"
new_win '分拆方案'; PARENT="$WID"; opt "$PARENT" @raw 1; opt "$PARENT" @worktree "$WORK/repo-scratch-7"; opt "$PARENT" @claude_state idle
new_win kid-merged; K1="$WID"; opt "$K1" @issue 101; opt "$K1" @origin scratch-7; opt "$K1" @claude_state 'done'
new_win kid-failed; K2="$WID"; opt "$K2" @issue 102; opt "$K2" @origin scratch-7; opt "$K2" @claude_state needs
new_win kid-stopped; K3="$WID"; opt "$K3" @issue 103; opt "$K3" @origin scratch-7; opt "$K3" @claude_state 'done'
new_win stranger; opt "$WID" @issue 900; opt "$WID" @claude_state 'done'      # hub-spawned: nobody's child

LEDGER="$FLEET_CONF_DIR/fleets/$LBL/children/scratch-7.ndjson"
RUN() { bash "$RP" -L "$LBL" "$@" >/dev/null 2>&1; }
RUN --win "$K1" --state merged --pr 501 --summary 'landed'
RUN --win "$K2" --state failed --pr 502 --summary 'CI red'
RUN --win "$K3" --state stopped
[ -f "$LEDGER" ] || fail "no ledger written at $LEDGER" "$(find "$FLEET_CONF_DIR" 2>/dev/null)"
eq "three reports ⇒ three ledger lines (recorded though the parent runs no Claude)" 3 "$(wc -l < "$LEDGER" | tr -d ' ')"
RUN --win "$K1" --state merged --pr 501 --summary 'landed, again'
RUN --win "$K3" --state stopped
eq "repeat reports add no lines" 3 "$(wc -l < "$LEDGER" | tr -d ' ')"
python3 - "$LEDGER" <<'PY' || fail "ledger events are not what was reported (see above)"
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1])]
got = [(e["seq"], e["child"], e["state"], e["pr"]) for e in ev]
assert got == [(1, "issue-101", "MERGED", "501"), (2, "issue-102", "FAILED", "502"),
               (3, "issue-103", "STOPPED", "")], got
assert ev[0]["title"] == "kid-merged" and ev[0]["summary"] == "landed", ev[0]
PY
CHECKS=$((CHECKS + 1))
# --dry-run sends nothing, so it records nothing either.
bash "$RP" -L "$LBL" --win "$K2" --state blocked --dry-run >/dev/null 2>&1
eq "--dry-run writes no ledger line" 3 "$(wc -l < "$LEDGER" | tr -d ' ')"

# --- AGREE: the dash's own badge for the parent row, off the same server --------
US=$(printf '\037')
dash_badge() {
  mkdir -p "$WORK/shim"
  TM list-windows -a -F "#{session_name}|#{window_index}|#{window_name}|#{pane_current_path}|#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}|#{@claude_state_ts}|#{window_id}|#{@issue}|#{@origin}|#{@worktree}|#{@cc_agent}|#{@wid}|#{@claude_needs}|#{@expand}|#{@pin}||||||" \
    | tr '|' "$US" > "$WORK/wlist"
  cat > "$WORK/shim/tmux" <<'SHIM'
#!/bin/sh
US=$(printf '\037'); lw=0; fmt=0
for a in "$@"; do [ "$a" = list-windows ] && lw=1; case "$a" in *"$US"*) fmt=1 ;; esac; done
[ "$lw" = 1 ] && [ "$fmt" = 1 ] && cat "$WLIST_FILE"
exit 0
SHIM
  chmod +x "$WORK/shim/tmux"
  WLIST_FILE="$WORK/wlist" PATH="$WORK/shim:$PATH" FLEET_SESSION="$LBL" FZF_COLUMNS=140 bash "$ROWS" 2>/dev/null \
    | grep -F "$LBL:$(TM display-message -p -t "$PARENT" '#{window_index}')$US" \
    | perl -pe 's/\e\[[0-9;]*m//g' | grep -oE '[0-9]+/[0-9]+ ✓( · [0-9]+!)?'
}
summ() { bash "$CLI" -L "$LBL" "$@" 2>&1 | tail -1; }

want=$(dash_badge)
eq "the dash parent row shows the expected badge" "2/3 ✓ · 1!" "$want"
eq "fleet-children's summary == the dash parent row's badge" "$want" "$(summ scratch-7)"
out=$(bash "$CLI" -L "$LBL" scratch-7 2>&1)
has "a row per child: the FAILED one is loud" '! issue-102' "$out"
has "…the MERGED one is done, with its PR"   'MERGED #501' "$out"
case "$out" in *issue-900*) fail "a hub-spawned window is nobody's child" "$out" ;; esac
CHECKS=$((CHECKS + 1))

# --json: the stable machine shape.
bash "$CLI" -L "$LBL" scratch-7 --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["parent"] == "scratch-7" and d["seq"] == 3, d
s = d["summary"]
assert (s["total"], s["done"], s["needs"], s["text"]) == (3, 2, 1, "2/3 ✓ · 1!"), s
k = {c["child"]: c for c in d["children"]}
assert k["issue-101"]["last"]["state"] == "MERGED" and k["issue-101"]["live"], k
' || fail "--json shape"
CHECKS=$((CHECKS + 1))
bash "$CLI" -L "$LBL" scratch-7 --json --since 2 | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert [c["child"] for c in d["children"]] == ["issue-103"], d["children"]
assert [e["seq"] for e in d["events"]] == [3], d["events"]
assert d["summary"]["total"] == 3, d["summary"]
' || fail "--since filters children + lists events, summary stays whole"
CHECKS=$((CHECKS + 1))

# --- SURVIVE: migrate the parent (new window id, same key) ----------------------
old="$PARENT"
TM kill-window -t "$PARENT"
new_win '分拆方案'; PARENT="$WID"; opt "$PARENT" @raw 1; opt "$PARENT" @worktree "$WORK/repo-scratch-7"; opt "$PARENT" @claude_state idle
[ "$PARENT" != "$old" ] || fail "the migrated parent must carry a NEW window id"
CHECKS=$((CHECKS + 1))
eq "after migration the summary is unchanged" "2/3 ✓ · 1!" "$(summ scratch-7)"
eq "…and still equals the dash badge"          "$(dash_badge)" "$(summ scratch-7)"

# DEFAULT key: run from inside the parent's pane (bare tmux → the test socket).
mkdir -p "$WORK/pshim"
printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$(command -v tmux)" "$LBL" > "$WORK/pshim/tmux"; chmod +x "$WORK/pshim/tmux"
pane=$(TM display-message -p -t "$PARENT" '#{pane_id}')
eq "no argument ⇒ the calling pane's own key" "2/3 ✓ · 1!" \
  "$(TMUX="/tmp/x,1,0" TMUX_PANE="$pane" PATH="$WORK/pshim:$PATH" bash "$CLI" 2>&1 | tail -1)"

# A REAPED child stays in the book: its MERGED report keeps it counted as done.
TM kill-window -t "$K1"
out=$(bash "$CLI" -L "$LBL" scratch-7 2>&1)
eq "a reaped merged child still counts" "2/3 ✓ · 1!" "$(printf '%s\n' "$out" | tail -1)"
has "…shown as gone" 'issue-101        gone' "$out"

printf 'fleet-children selftest: OK (%d checks)\n' "$CHECKS"
