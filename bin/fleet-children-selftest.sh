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
#   JOIN      one row per child (issue #1351): a bare-key report, the qualified live
#             window and a placement are one child; two repos' same number are two.
#   ONE BOOK  (issue #1939, #982) a ONE-repo fleet keys `acme-app:scratch-7` too; a
#             parent's old bare book (`scratch-7.ndjson`) and a child's bare
#             @origin are read as that repo's — one book, each child once — and
#             fleet_origin_heal rewrites the bare @origin so the dash agrees.
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
# A ONE-repo fleet (issue #1939): every key carries `acme-app:`, a bare key is its alias.
LBL="fch-selftest-$$"
mkdir -p "$FLEET_CONF_DIR/fleets/$LBL"; printf 'FLEET_REPO=acme/app\n' > "$FLEET_CONF_DIR/fleets/$LBL/conf"
P=acme-app:
# …so a merged report is checked against GitHub's `.merged` (issue #1247) and a
# stopped one for an open PR (#864): a gh shim says every PR merged and none is
# open, and nothing here reaches the network.
mkdir -p "$WORK/ghshim"
printf '#!/bin/sh\ncase "$*" in *pulls?state=open*) echo 0 ;; *pulls/*) echo "true closed false" ;; esac\nexit 0\n' > "$WORK/ghshim/gh"
chmod +x "$WORK/ghshim/gh"; export PATH="$WORK/ghshim:$PATH"
trap 'tmux -L "$LBL" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT
TM() { tmux -L "$LBL" "$@"; }
TM new-session -d -s "$LBL" -n dash -c "$WORK" "sleep 600" 2>/dev/null || fail "could not start the selftest tmux server"
WID=''
new_win() { WID=$(TM new-window -d -P -F '#{window_id}' -n "$1" -c "$WORK" "sleep 600" 2>/dev/null); [ -n "$WID" ] || fail "could not create window $1"; }
opt() { TM set-window-option -t "$1" "$2" "$3" 2>/dev/null; }

mkdir -p "$WORK/repo-scratch-7"
new_win '分拆方案'; PARENT="$WID"; opt "$PARENT" @raw 1; opt "$PARENT" @worktree "$WORK/repo-scratch-7"; opt "$PARENT" @claude_state idle
new_win kid-merged; K1="$WID"; opt "$K1" @issue 101; opt "$K1" @origin "${P}scratch-7"; opt "$K1" @claude_state 'done'
new_win kid-failed; K2="$WID"; opt "$K2" @issue 102; opt "$K2" @origin "${P}scratch-7"; opt "$K2" @claude_state needs
new_win kid-stopped; K3="$WID"; opt "$K3" @issue 103; opt "$K3" @origin "${P}scratch-7"; opt "$K3" @claude_state 'done'
new_win stranger; opt "$WID" @issue 900; opt "$WID" @claude_state 'done'      # hub-spawned: nobody's child

LEDGER="$FLEET_CONF_DIR/fleets/$LBL/children/${P}scratch-7.ndjson"
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
assert got == [(1, "acme-app:issue-101", "MERGED", "501"), (2, "acme-app:issue-102", "FAILED", "502"),
               (3, "acme-app:issue-103", "STOPPED", "")], got
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
  TM list-windows -a -F "#{session_name}|#{window_index}|#{window_name}|#{pane_current_path}|#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}|#{@claude_state_ts}|#{window_id}|#{@issue}|#{@origin}|#{@worktree}|#{@cc_agent}|#{@wid}|#{@claude_needs}|#{@expand}|#{@pin}|||||||||#{@loop}" \
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
    | grep -F "$LBL:$(TM display-message -p -t "${1:-$PARENT}" '#{window_index}')$US" \
    | perl -pe 's/\e\[[0-9;]*m//g' | grep -oE '[0-9]+/[0-9]+' | head -1
}
dash_badge_of() { dash_badge "$1"; }
# The dash badge is the bare `k/N` since issue #1328 (no ✓, no `· n!` — a child
# that needs you is red on its own row); this CLI's summary keeps both, so the
# two AGREE on the count they share: the summary's leading `k/N`.
kn() { printf '%s' "${1%% *}"; }
summ() { bash "$CLI" -L "$LBL" "$@" 2>&1 | tail -1; }

want=$(dash_badge)
eq "the dash parent row shows the expected badge" "2/3" "$want"
eq "fleet-children's summary == the dash parent row's badge" "$want" "$(kn "$(summ scratch-7)")"
out=$(bash "$CLI" -L "$LBL" scratch-7 2>&1)
has "a row per child: the FAILED one is loud" '! acme-app:issue-102' "$out"
has "…the MERGED one is done, with its PR"   'MERGED #501' "$out"
case "$out" in *issue-900*) fail "a hub-spawned window is nobody's child" "$out" ;; esac
CHECKS=$((CHECKS + 1))

# --json: the stable machine shape.
bash "$CLI" -L "$LBL" scratch-7 --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["parent"] == "acme-app:scratch-7" and d["seq"] == 3, d
s = d["summary"]
assert (s["total"], s["done"], s["needs"], s["text"]) == (3, 2, 1, "2/3 ✓ · 1!"), s
k = {c["child"]: c for c in d["children"]}
assert k["acme-app:issue-101"]["last"]["state"] == "MERGED" and k["acme-app:issue-101"]["live"], k
' || fail "--json shape"
CHECKS=$((CHECKS + 1))
bash "$CLI" -L "$LBL" scratch-7 --json --since 2 | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert [c["child"] for c in d["children"]] == ["acme-app:issue-103"], d["children"]
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
eq "…and still equals the dash badge"          "$(dash_badge)" "$(kn "$(summ scratch-7)")"

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
has "…shown as gone" 'acme-app:issue-101 gone' "$out"

# QUIET IS NOT FINISHED (issue #1331): the stopped child K3 now has a /loop
# between rounds (a live @loop on a `done` window) — not a ✓ any more; a sleeper
# is not either. The dash's live-only badge agrees (K1 is gone from the server).
opt "$K3" @loop "kind=wakeup next=$(( $(date +%s) + 1800 )) ttl=1800"
eq "a done child with a live @loop is not counted done" "1/3 ✓ · 1!" "$(summ scratch-7)"
has "…it is reported as looping" 'looping' "$(bash "$CLI" -L "$LBL" scratch-7 2>&1)"
eq "…and the dash badge does not count it either" "0/2" "$(dash_badge)"
opt "$K3" @loop "kind=wakeup next=$(( $(date +%s) - 7200 )) ttl=600"
eq "a lapsed @loop (never renewed) is done again" "2/3 ✓ · 1!" "$(summ scratch-7)"
eq "…on the dash too" "1/2" "$(dash_badge)"
TM set-option -wu -t "$K3" @loop; opt "$K3" @worker_lifecycle sleeping
eq "a sleeping child is not counted done" "1/3 ✓ · 1!" "$(summ scratch-7)"
eq "…nor on the dash" "0/2" "$(dash_badge)"

# --- 3. GENERATIONS (issue #1538): a recycled scratch number starts empty --------
# fleet_scratch_alloc with the fleet's session mints the number's next generation:
# the last holder's book is retired to `<key>.ndjson.<gen>` (still readable), the
# new holder's `fleet-children.sh` is empty, and a child of the last holder that
# is still running has its @origin moved to @origin_retired, so nothing nests or
# counts it under the new one. Without a session: nothing minted (as before).
GR="$WORK/gen/repo"; mkdir -p "$GR"
git -C "$GR" init -q -b master 2>/dev/null || { git -C "$GR" init -q && git -C "$GR" checkout -q -b master; }
git -C "$GR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init || fail "gen: could not seed a repo"
CD="$FLEET_CONF_DIR/fleets/$LBL/children"
printf '%s' '{"child":"issue-501","state":"MERGED","pr":"51"}' \
  | python3 "$BIN/fleet-children.py" append --file "$CD/scratch-1.ndjson" >/dev/null \
  || fail "gen: could not seed the last holder's book"
new_win gen-oldkid; GK="$WID"; opt "$GK" @issue 502; opt "$GK" @origin scratch-1; opt "$GK" @origin_wid "u/scratch-1"
eq "gen: before re-allocation scratch-1 has the old book's child + the live one" 2 \
  "$(bash "$CLI" -L "$LBL" scratch-1 --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["children"]))')"
alloc=$( . "$BIN/fleet-lib.sh"; fleet_scratch_alloc "$GR" master "$LBL" )
eq "gen: the free number is allocated" scratch-1 "${alloc%%$'\t'*}"
eq "gen: the last holder's book is moved aside" no "$([ -e "$CD/scratch-1.ndjson" ] && echo yes || echo no)"
has "gen: …and kept, readable, in its retired book" '"child": "issue-501"' "$(cat "$CD/scratch-1.ndjson.0" 2>/dev/null)"
G1=$(awk -F'\t' -v k="${P}scratch-1" '$1 == k { g = $2 } END { print g }' "$CD/.gen" 2>/dev/null)
case "$G1" in [0-9]*.[0-9]*) CHECKS=$((CHECKS + 1)) ;; *) fail "gen: no generation minted for scratch-1" "$(cat "$CD/.gen" 2>/dev/null)" ;; esac
NEWOUT=$(bash "$CLI" -L "$LBL" scratch-1 --json 2>&1)
eq "gen: the new scratch-1 has no children" 0 \
  "$(printf '%s' "$NEWOUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["children"]))')"
eq "gen: a running child of the last holder no longer names scratch-1" "|${P}scratch-1#0|" \
  "$(TM display-message -p -t "$GK" '#{@origin}|#{@origin_retired}|#{@origin_wid}')"
# Evidence (issue #1538 上线证据): fleet-children.sh on the recycled number + the archive.
if [ -n "${GEN_EVIDENCE:-}" ]; then
  { printf '$ fleet-children.sh scratch-1   # after re-allocation\n'; bash "$CLI" -L "$LBL" scratch-1 2>&1
    printf '\n$ ls children/\n'; ls -a "$CD"; printf '\n$ cat children/.gen\n'; cat "$CD/.gen"; } > "$GEN_EVIDENCE"
fi
# Recycled AGAIN: the generation-1 book retires under its own generation.
printf '%s' '{"child":"issue-503","state":"BLOCKED"}' \
  | python3 "$BIN/fleet-children.py" append --file "$CD/scratch-1.ndjson" >/dev/null
( . "$BIN/fleet-lib.sh"; fleet_scratch_free "$GR" scratch-1 "${alloc#*$'\t'}" )
alloc=$( . "$BIN/fleet-lib.sh"; fleet_scratch_alloc "$GR" master "$LBL" )
eq "gen: recycled again" scratch-1 "${alloc%%$'\t'*}"
has "gen: generation $G1's book retires under $G1" '"child": "issue-503"' "$(cat "$CD/scratch-1.ndjson.$G1" 2>/dev/null)"
eq "gen: two generations minted" 2 "$(grep -c "^${P}scratch-1	" "$CD/.gen")"
# Degenerate: no session ⇒ nothing minted, nothing moved.
printf '%s' '{"child":"issue-504","state":"MERGED"}' \
  | python3 "$BIN/fleet-children.py" append --file "$CD/scratch-2.ndjson" >/dev/null
alloc=$( . "$BIN/fleet-lib.sh"; fleet_scratch_alloc "$GR" master )
eq "gen: (no session) scratch-2 allocated" scratch-2 "${alloc%%$'\t'*}"
eq "gen: (no session) its book is untouched" 1 "$(wc -l < "$CD/scratch-2.ndjson" | tr -d ' ')"
eq "gen: (no session) no generation minted" 0 "$(grep -c 'scratch-2	' "$CD/.gen")"

# --- 3b. ONE BOOK (issue #1939, #982): a bare book and a bare @origin are the one
# repo's. Before #1939 a one-repo fleet wrote `scratch-12.ndjson` and stamped bare
# @origins; the same parent's key is `acme-app:scratch-12` now. Read together they
# are one parent: each child once, no bare key on a row, the count whole; a report
# from a bare-@origin child lands in the qualified book; fleet_origin_heal rewrites
# the bare @origin, after which the dash nests it too.
mkdir -p "$WORK/repo-scratch-12"
new_win '合账'; OB="$WID"; opt "$OB" @raw 1; opt "$OB" @worktree "$WORK/repo-scratch-12"; opt "$OB" @claude_state idle
printf '%s\n' '{"seq": 1, "ts": "2026-10-05T00:00:00Z", "child": "issue-201", "state": "WAITING", "pr": "61"}' \
  '{"seq": 2, "ts": "2026-10-05T00:01:00Z", "child": "issue-204", "state": "MERGED", "pr": "64"}' > "$CD/scratch-12.ndjson"
printf '%s\n' '{"seq": 1, "ts": "2026-10-06T00:00:00Z", "child": "acme-app:issue-202", "state": "WAITING", "pr": "62"}' > "$CD/${P}scratch-12.ndjson"
new_win kid-201; B1="$WID"; opt "$B1" @issue 201; opt "$B1" @origin scratch-12; opt "$B1" @claude_state 'done'
new_win kid-202; B2="$WID"; opt "$B2" @issue 202; opt "$B2" @origin "${P}scratch-12"; opt "$B2" @claude_state working
new_win kid-203; B3="$WID"; opt "$B3" @issue 203; opt "$B3" @origin scratch-12; opt "$B3" @claude_state working
OBJ=$(bash "$CLI" -L "$LBL" scratch-12 --json 2>&1)
python3 - "$OBJ" <<'PY' || fail "one book: the bare and qualified books must read as one parent (see above)" "$OBJ"
import json, sys
d = json.loads(sys.argv[1])
assert d["parent"] == "acme-app:scratch-12", d["parent"]
kids = sorted(k["child"] for k in d["children"])
assert kids == ["acme-app:issue-201", "acme-app:issue-202", "acme-app:issue-203", "acme-app:issue-204"], kids
k = {c["child"]: c for c in d["children"]}
assert k["acme-app:issue-201"]["live"] and k["acme-app:issue-201"]["pr"] == "61", k["acme-app:issue-201"]
assert k["acme-app:issue-204"]["last"]["state"] == "MERGED" and not k["acme-app:issue-204"]["live"], k["acme-app:issue-204"]
assert d["summary"]["total"] == 4, d["summary"]
PY
CHECKS=$((CHECKS + 1))
eq "one book: the qualified key reads the same" "$(summ scratch-12)" "$(summ "${P}scratch-12")"
RUN --win "$B1" --state merged --pr 61 --summary landed
has "one book: a bare-@origin child's report is booked under the qualified key" '"child": "acme-app:issue-201"' \
  "$(tail -1 "$CD/${P}scratch-12.ndjson")"
eq "one book: …and never in the bare book again" 2 "$(wc -l < "$CD/scratch-12.ndjson" | tr -d ' ')"
eq "one book: the newer report wins over the bare book's" MERGED \
  "$(bash "$CLI" -L "$LBL" scratch-12 --json | python3 -c 'import json,sys; print({c["child"]: c for c in json.load(sys.stdin)["children"]}["acme-app:issue-201"]["last"]["state"])')"
healed=$( . "$BIN/fleet-lib.sh"; fleet_origin_heal "$LBL" "$LBL" )
has "one book: heal rewrites a bare @origin" "$B3 scratch-12 → ${P}scratch-12" "$healed"
eq "one book: …every bare one" "${P}scratch-12|${P}scratch-12" \
  "$(TM display-message -p -t "$B1" '#{@origin}')|$(TM display-message -p -t "$B3" '#{@origin}')"
eq "one book: after the heal the dash nests them all" "1/3" "$(dash_badge_of "$OB")"
TM kill-window -t "$B1"; TM kill-window -t "$B2"; TM kill-window -t "$B3"; TM kill-window -t "$OB"

# --- 4. ONE ROW PER CHILD (issue #1351): three sources, one key -----------------
# A report filed before it carried its repo says bare `issue-N`; the live window
# and the cross-machine placement say `<slug>:issue-N`. They are one child: one
# row, counted once. Two repos' same number are NOT one child. A row carrying a
# window's @fleet_id joins that window even under another key. A bare book (a
# one-repo fleet) reads byte for byte as before.
JD="$WORK/join"; mkdir -p "$JD"
JB="$JD/r-a:scratch-5.ndjson"
printf '%s\n' '{"seq": 1, "ts": "2026-10-05T00:00:00Z", "child": "issue-1317", "state": "FAILED", "pr": "1333"}' > "$JB"
printf '%s' '{"child":"issue-1317","state":"MERGED","pr":"1333"}' \
  | python3 "$BIN/fleet-children.py" append --file "$JB" >/dev/null
has "join: a bare child appended to a qualified book is written qualified" '"child": "r-a:issue-1317"' "$(sed -n 2p "$JB")"
python3 "$BIN/fleet-children.py" dispatch --file "$JD/r-a:scratch-5.dispatch" --child r-a:issue-1317 \
  --state 'done' --node m4 --op op-1 --window @9 >/dev/null
FID1=11111111-2222-3333-4444-555555555555
printf '%s\n' "{\"seq\": 3, \"ts\": \"2026-10-05T00:00:00Z\", \"child\": \"r-a:scratch-9\", \"state\": \"WAITING\", \"fid\": \"$FID1\"}" >> "$JB"
JOUT=$(printf '%s\n' \
  "@1|working||r-a:issue-1317|r-a:scratch-5||kid-a" \
  "@2|working||r-b:issue-1317|r-a:scratch-5||kid-b" \
  "@3|working||r-a:issue-1400|r-a:scratch-5|$FID1|kid-bound" \
  | python3 "$BIN/fleet-children.py" show --dir "$JD" --parent r-a:scratch-5 --json)
python3 - "$JOUT" <<'PY' || fail "join: the three sources must make one row per child (see above)" "$JOUT"
import json, sys
d = json.loads(sys.argv[1])
kids = {k["child"]: k for k in d["children"]}
assert sorted(kids) == ["r-a:issue-1317", "r-a:issue-1400", "r-b:issue-1317"], sorted(kids)
a = kids["r-a:issue-1317"]
assert a["live"] and a["window"] == "@1" and a["last"]["state"] == "MERGED" and a["pr"] == "1333", a
assert a["dispatch"]["node"] == "m4", a
assert kids["r-b:issue-1317"]["last"] is None, kids["r-b:issue-1317"]
assert kids["r-a:issue-1400"]["last"]["state"] == "WAITING", kids["r-a:issue-1400"]
assert d["summary"]["total"] == 3 and d["summary"]["needs"] == 0, d["summary"]
PY
CHECKS=$((CHECKS + 1))
JTXT=$(printf '%s\n' "@1|working||r-a:issue-1317|r-a:scratch-5||kid-a" \
  | python3 "$BIN/fleet-children.py" show --dir "$JD" --parent r-a:scratch-5)
eq "join: the text view has one line per child (no extra ↗ line for a placed child)" 0 \
  "$(printf '%s\n' "$JTXT" | grep -c '↗')"
eq "join: wake-state answers for the bare spelling too" "0 0" \
  "$(python3 "$BIN/fleet-children.py" wake-state --file "$JB" --child issue-1317)"
# Degenerate: a bare book keeps its bare keys, and an old six-field window row reads.
printf '%s\n' '{"seq": 1, "ts": "2026-10-05T00:00:00Z", "child": "issue-7", "state": "MERGED"}' > "$JD/scratch-5.ndjson"
JOUT=$(printf '%s\n' "@1|done||issue-7|scratch-5|a|b" \
  | python3 "$BIN/fleet-children.py" show --dir "$JD" --parent scratch-5 --json)
python3 - "$JOUT" <<'PY' || fail "join: a one-repo book must read as before" "$JOUT"
import json, sys
d = json.loads(sys.argv[1])
assert [k["child"] for k in d["children"]] == ["issue-7"], d
assert d["children"][0]["title"] == "a|b" and d["children"][0]["live"], d
assert "dispatch" not in d["children"][0], d
PY
CHECKS=$((CHECKS + 1))

# --- 5. A CHILD ON ANOTHER MACHINE READS ITS OWN STATE (issue #1607) -------------
# `gone · m4` / `m4 remote` said nothing about whether it is still at work. With the
# hub's session table (--hub-cache, global/remote_<sess>) the row carries what the
# machine says — its `busy` word first, `lost` for a machine the hub lost — and
# the text shows `m4 bg`. A cache past FLEET_HUB_RETAIN_SECS is no answer; no
# --hub-cache is the one-machine view, byte for byte.
RD="$WORK/remote"; mkdir -p "$RD/g"
US=$(printf '\037'); now=$(date +%s)
rrow() { local IFS="$US"; printf '%s\n' "wid:u/issue-$1${US}m4${US}${4:-online}${US}$1${US}o/r${US}$2${US}claude${US}n${US}${US}${US}0${US}${US}hub${US}$3"; }
{ printf '#ts%s%s\n' "$US" "$now"; rrow 501 'done' bg; rrow 502 'done' ''; rrow 504 idle '' lost; } > "$RD/g/remote_s"
printf '%s\n' "$now" > "$RD/g/hub_ok"
printf '%s\n' '{"seq": 1, "ts": "2026-10-05T00:00:00Z", "child": "issue-501", "state": "WAITING", "node": "m4", "pr": "9"}' \
  '{"seq": 2, "ts": "2026-10-05T00:00:00Z", "child": "issue-502", "state": "WAITING", "node": "m4"}' \
  '{"seq": 3, "ts": "2026-10-05T00:00:00Z", "child": "issue-503", "state": "WAITING", "node": "m4"}' \
  '{"seq": 4, "ts": "2026-10-05T00:00:00Z", "child": "issue-504", "state": "WAITING", "node": "m4"}' > "$RD/scratch-5.ndjson"
ROUT=$(printf '%s\n' "m4|remote||issue-502|scratch-5||" \
  | python3 "$BIN/fleet-children.py" show --dir "$RD" --parent scratch-5 --hub-cache "$RD/g/remote_s" --json)
python3 - "$ROUT" <<'PY2' || fail "remote: a child on another machine must carry that machine's word (see above)" "$ROUT"
import json, sys
k = {c["child"]: c for c in json.loads(sys.argv[1])["children"]}
assert (k["issue-501"]["remote_state"], k["issue-501"]["remote_node"]) == ("bg", "m4"), k["issue-501"]
assert k["issue-502"]["remote_state"] == "done" and k["issue-502"]["state"] == "remote", k["issue-502"]
assert "remote_state" not in k["issue-503"], k["issue-503"]
assert k["issue-504"]["remote_state"] == "lost", k["issue-504"]
PY2
CHECKS=$((CHECKS + 1))
RTXT=$(printf '' | python3 "$BIN/fleet-children.py" show --dir "$RD" --parent scratch-5 --hub-cache "$RD/g/remote_s")
has "remote: the text shows the machine's word, not \`gone · m4\`" 'm4 bg' "$RTXT"
has "remote: a child the hub has no row for still reads gone · m4" 'gone · m4' "$(printf '%s\n' "$RTXT" | grep issue-503)"
printf '%s\n' "$((now - 1000))" > "$RD/g/hub_ok"
RTXT=$(printf '' | python3 "$BIN/fleet-children.py" show --dir "$RD" --parent scratch-5 --hub-cache "$RD/g/remote_s")
eq "remote: a hub silent past FLEET_HUB_RETAIN_SECS is no answer" 4 "$(printf '%s\n' "$RTXT" | grep -c 'gone · m4')"
eq "remote: degenerate — no --hub-cache, the view is unchanged" \
  "$(printf '' | python3 "$BIN/fleet-children.py" show --dir "$RD" --parent scratch-5)" "$RTXT"

# --- 6. A CLAIM WITH NO SESSION BEHIND IT (issue #1610) ---------------------------
# A send never seen open (accepted / unknown) past FLEET_STALE_CLAIM_SECS, no window,
# no report, and a fresh hub table with no session for it: `"claim": "stale"`, the
# text `stale-claim`. A row the hub shows, a young row, a refused / done one, or a
# hub that said nothing are never stale; every other field is as it was. One send
# that went to a second machine is two rows, the answer's last.
SD="$WORK/stale"; mkdir -p "$SD/g"
old_ts=$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3600)))')
new_ts=$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))')
printf '%s\n' \
  "{\"seq\": 1, \"ts\": \"$old_ts\", \"child\": \"issue-601\", \"node\": \"mini2\", \"op\": \"o1\", \"state\": \"unknown\"}" \
  "{\"seq\": 2, \"ts\": \"$old_ts\", \"child\": \"issue-602\", \"node\": \"m4\", \"op\": \"o2\", \"state\": \"unknown\"}" \
  "{\"seq\": 3, \"ts\": \"$new_ts\", \"child\": \"issue-603\", \"node\": \"m4\", \"op\": \"o3\", \"state\": \"unknown\"}" \
  "{\"seq\": 4, \"ts\": \"$old_ts\", \"child\": \"issue-604\", \"node\": \"mini2\", \"op\": \"o4\", \"state\": \"refused\", \"exit\": 1}" \
  "{\"seq\": 5, \"ts\": \"$old_ts\", \"child\": \"issue-604\", \"node\": \"m4\", \"op\": \"o5\", \"state\": \"done\", \"window\": \"@7\"}" \
  "{\"seq\": 6, \"ts\": \"$old_ts\", \"child\": \"issue-605\", \"node\": \"m4\", \"op\": \"o6\", \"state\": \"accepted\"}" \
  > "$SD/scratch-8.dispatch"
{ printf '#ts%s%s\n' "$US" "$now"; rrow 602 working ''; } > "$SD/g/remote_s"
printf '%s\n' "$now" > "$SD/g/hub_ok"
SOUT=$(printf '%s\n' "@5|working||issue-605|scratch-8||kid" \
  | python3 "$BIN/fleet-children.py" show --dir "$SD" --parent scratch-8 --hub-cache "$SD/g/remote_s" --json)
python3 - "$SOUT" <<'PY3' || fail "stale: only a send nobody saw open, anywhere, is a stale claim (see above)" "$SOUT"
import json, sys
d = json.loads(sys.argv[1])
k = {c["child"]: c for c in d["children"]}
assert k["issue-601"].get("claim") == "stale", k["issue-601"]
assert "claim" not in k["issue-602"], k["issue-602"]          # the hub shows it working
assert "claim" not in k["issue-603"], k["issue-603"]          # too young
assert "claim" not in k["issue-604"] and k["issue-604"]["dispatch"]["node"] == "m4", k["issue-604"]
assert "claim" not in k["issue-605"], k["issue-605"]          # a window here holds it
assert k["issue-601"]["progress"] == "unknown", k["issue-601"]  # fields only added
assert [x["node"] for x in d["dispatches"] if x["child"] == "issue-604"] == ["m4"], d["dispatches"]
PY3
CHECKS=$((CHECKS + 1))
has "stale: the text says stale-claim" 'stale-claim (unknown' "$(printf '' | python3 "$BIN/fleet-children.py" show --dir "$SD" --parent scratch-8 --hub-cache "$SD/g/remote_s" | grep issue-601)"
eq "stale: a hub that said nothing proves nothing" 0 \
  "$(printf '' | python3 "$BIN/fleet-children.py" show --dir "$SD" --parent scratch-8 --json | grep -c '"claim"')"
eq "stale: FLEET_STALE_CLAIM_SECS moves the bar" 0 \
  "$(printf '' | FLEET_STALE_CLAIM_SECS=7200 python3 "$BIN/fleet-children.py" show --dir "$SD" --parent scratch-8 --hub-cache "$SD/g/remote_s" --json | grep -c '"claim"')"

printf 'fleet-children selftest: OK (%d checks)\n' "$CHECKS"
