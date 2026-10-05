#!/bin/bash
# hub-progress-selftest.sh — one progress stream per parent (issue #1648, EPIC
# #1645 C5). On an isolated tmux server and a sandbox conf dir, with the hub's
# GET /v1/node/progress faked by FLEET_HUB_CURL (a canned answer, every call
# logged), pins `fleet-hub-node.sh progress` + `fleet-children.py merge` +
# `fleet-children.sh`:
#   A  the degenerate case: hub off ⇒ progress exits 3, asks nothing, writes
#      nothing, and fleet-children.sh prints byte for byte what it did.
#   B  a remote child's MERGED that reaches this machine ONLY through the hub's
#      stream lands in the parent's book — one row, with node + rid; a parent of a
#      fleet not on this machine is skipped; the cursor moves to the answer's seq.
#   C  the same event by two roads is one row: the relay push (deliver) first,
#      then the pull — and a pull run again from seq 0 adds nothing.
#   D  a placement advances in ONE fleet-children row: accepted → running → done
#      → a WAITING report with its PR → MERGED, the row's `progress` saying
#      accepted / starting / running / pr / merged and the summary counting one
#      child throughout; no `↗` line of its own.
#   E  the open placements ride along as `ops=` (each child's last row accepted /
#      running / unknown) and stop once the placement is final.
#   F  a later STOPPED does not un-land a MERGED (✓, progress merged), and a
#      STOPPED whose PR the dash's cache calls MERGED reads merged too.
# tmux / python3 absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { echo 'hub-progress selftest: tmux absent — SKIP'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'hub-progress selftest: python3 absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hub-progress.XXXXXX")" || exit 2
L="hprg$$"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$FLEET_CONF_DIR/fleets/$L/conf"
unset TMUX TMUX_PANE CCQUOTA_FLEET CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_PROGRESS FLEET_CHILD_REPORT FLEET_PROGRESS_MAX_AGE

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
lib() { bash -c '. "$1/fleet-lib.sh"; shift; "$@"' _ "$BIN" "$@"; }
run() { out=$(env -u TMUX "$@" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err"); }

tf -f /dev/null new-session -d -s "$L" -n plan 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'hub-progress selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
wp=$(tf new-window -d -P -F '#{window_id}' -n issue-7 'while :; do sleep 300; done')
tf set-window-option -t "$wp" @issue 7
(cd "$BIN" && python3 -c 'import sys, fleet_control as c; c.Control(sys.argv[1]).inventory()' "$FLEET_CONF_DIR") >/dev/null 2>&1
U=$(lib fleet_uuid "$L")
[ -n "$U" ] || { echo 'hub-progress selftest: no fleet UUID could be minted' >&2; exit 1; }
F=11111111-2222-3333-4444-555555555555          # a fleet on another machine ("m4")
O1=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee         # the placement's operation id
CD="$(bash -c '. "$1/fleet-lib.sh"; . "$1/fleet-children-lib.sh"; children_dir "$2"' _ "$BIN" "$L")"
LEDGER="$CD/issue-7.ndjson"; DISP="$CD/issue-7.dispatch"
nlines() { [ -f "$1" ] && grep -c . "$1" || echo 0; }

# The fake hub: prints $WORK/answer.json then the status line, logs its argv.
cat > "$WORK/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/curl.log"
cat "$WORK/answer.json"; printf '\n200'
EOF
chmod +x "$WORK/curl"
export FLEET_HUB_CURL="$WORK/curl"
# answer <seq> <event-json>... — the events, each `{seq, rid, parent, kind, state, event}`.
answer() { local s=$1; shift; python3 -c 'import json, sys
print(json.dumps({"seq": int(sys.argv[1]), "events": [json.loads(x) for x in sys.argv[2:]]}))' "$s" "$@" > "$WORK/answer.json"; }
ev() { # <seq> <rid> <parent> <kind> <state> <event-json>
  python3 -c 'import json, sys
s, rid, p, k, st, e = sys.argv[1:7]
print(json.dumps(dict(seq=int(s), rid=rid, parent=p, kind=k, state=st, event=json.loads(e))))' "$@"; }
pull() { run bash "$BIN/fleet-hub-node.sh" progress; }
kid() { # → `<total>|<bucket>|<progress>|<rows naming issue-42>` off fleet-children.sh --json
  env -u TMUX FLEET_HUB_PROGRESS=0 bash "$BIN/fleet-children.sh" -L "$L" issue-7 --json 2>/dev/null | python3 -c 'import json, sys
d = json.load(sys.stdin)
k = [c for c in d["children"] if c["child"] == "issue-42"]
print("%d|%s|%s|%d" % (d["summary"]["total"], k[0]["bucket"] if k else "", k[0].get("progress", "") if k else "", len(k)))'; }

# --- A: degenerate ----------------------------------------------------------------------
run bash "$BIN/fleet-children.sh" -L "$L" issue-7; base="$rc|$out"
answer 9 "$(ev 9 "$F/issue-42#1.1" "$U/issue-7" report MERGED '{"child":"issue-42","state":"MERGED","pr":"50","node":"m4"}')"
pull
ok; [ "$rc" = 3 ] && [ ! -e "$WORK/curl.log" ] && [ ! -d "$FLEET_CONF_DIR/hub-progress" ] \
  || fail "A: hub off ⇒ progress exits 3, asks nothing, writes nothing" "rc=$rc $err"
run bash "$BIN/fleet-children.sh" -L "$L" issue-7
ok; [ "$rc|$out" = "$base" ] && [ ! -e "$WORK/curl.log" ] || fail "A: hub off ⇒ fleet-children.sh byte for byte, no pull" "[$out] vs [$base]"
export CCQUOTA_FLEET=1 CCQUOTA_TOKEN=t0k CCQUOTA_HUB_URL=http://hub.invalid
FLEET_HUB_PROGRESS=0 run bash "$BIN/fleet-hub-node.sh" progress
ok; [ "$rc" = 3 ] && [ ! -e "$WORK/curl.log" ] || fail "A: FLEET_HUB_PROGRESS=0 ⇒ exit 3, nothing asked" "rc=$rc"

# --- B: a MERGED that only the hub carried -----------------------------------------------
answer 9 \
  "$(ev 8 "$F/issue-42#1.1" "$U/issue-7" report MERGED '{"child":"issue-42","state":"MERGED","pr":"50","title":"kid","node":"m4"}')" \
  "$(ev 9 "$F/issue-43#1.1" "$F/issue-1" report MERGED '{"child":"issue-43","state":"MERGED","node":"m4"}')"
pull
ok; [ "$rc" = 0 ] && [ "$(nlines "$LEDGER")" = 1 ] || fail "B: the hub's MERGED lands in the parent's book" "rc=$rc lines=$(nlines "$LEDGER") $out $err"
ok; python3 -c 'import json, sys; e = json.loads(open(sys.argv[1]).readline())
sys.exit(0 if (e["child"], e["state"], e["pr"], e["node"], e["rid"]) == ("issue-42", "MERGED", "50", "m4", sys.argv[2]) else 1)' \
  "$LEDGER" "$F/issue-42#1.1" || fail "B: the row carries node + rid" "$(cat "$LEDGER")"
ok; case "$out" in *'1 new row(s), 1 parent(s) not here'*) ;; *) fail "B: a parent of a fleet not here is skipped, said once" "$out" ;; esac
ok; [ "$(cat "$FLEET_CONF_DIR/hub-progress/seq")" = 9 ] || fail "B: the cursor moves to the answer's seq" "$(cat "$FLEET_CONF_DIR/hub-progress/seq")"
ok; grep -q 'since=0' "$WORK/curl.log" && grep -q 'Bearer t0k' "$WORK/curl.log" && grep -q '/v1/node/progress' "$WORK/curl.log" \
  || fail "B: GET /v1/node/progress?since=0 with the node token" "$(cat "$WORK/curl.log")"
pull
ok; grep -q 'since=9' "$WORK/curl.log" || fail "B: the next pull asks from the cursor" "$(tail -n 1 "$WORK/curl.log")"

# --- C: two roads, one row ----------------------------------------------------------------
R2="$F/issue-44#1.1"
relay=$(python3 -c 'import json, sys; f, t, i = sys.argv[1:4]
print(json.dumps({"id": i, "kind": "child_report", "from": f, "to": t, "from_node": "m4",
  "payload": {"child": "issue-44", "state": "WAITING", "pr": "51", "tier": "silent", "msg": "x"}}))' "$F/issue-44" "$U/issue-7" "$R2")
printf '%s' "$relay" | env -u TMUX bash "$BIN/fleet-hub-node.sh" deliver 2>/dev/null
ok; [ "$(nlines "$LEDGER")" = 2 ] || fail "C: the push lands first" "$(cat "$LEDGER")"
answer 10 "$(ev 10 "$R2" "$U/issue-7" report WAITING '{"child":"issue-44","state":"WAITING","pr":"51","tier":"silent","node":"m4"}')"
pull
ok; [ "$(nlines "$LEDGER")" = 2 ] || fail "C: the same event by the pull is not a second row" "$(cat "$LEDGER")"
rm -f "$FLEET_CONF_DIR/hub-progress/seq"
answer 10 \
  "$(ev 8 "$F/issue-42#1.1" "$U/issue-7" report MERGED '{"child":"issue-42","state":"MERGED","pr":"50","node":"m4"}')" \
  "$(ev 10 "$R2" "$U/issue-7" report WAITING '{"child":"issue-44","state":"WAITING","pr":"51","node":"m4"}')"
pull
ok; [ "$(nlines "$LEDGER")" = 2 ] && [ -z "$out" ] || fail "C: a pull from seq 0 again adds nothing" "lines=$(nlines "$LEDGER") $out"

# --- D + E: a placement advances in one row -------------------------------------------------
: > "$LEDGER"; rm -f "$DISP" "$FLEET_CONF_DIR/hub-progress/seq"
# The spawn's own row, as dash-issue-session.sh writes it for an --async placement.
python3 "$BIN/fleet-children.py" dispatch --file "$DISP" --child issue-42 --state accepted --node m4 --op "$O1" >/dev/null
ok; [ "$(kid)" = "1|▸|accepted|1" ] || fail "D: placed, nothing more ⇒ one working row, progress accepted" "$(kid)"
txt=$(env -u TMUX FLEET_HUB_PROGRESS=0 bash "$BIN/fleet-children.sh" -L "$L" issue-7)
ok; case "$txt" in *'↗ issue-42'*) fail "D: no ↗ line of its own" "$txt" ;; *'▸ issue-42'*'gone ↗m4'*'accepted'*'0/1 ✓') ;; *) fail "D: the text row says where and how far" "$txt" ;; esac
step() { # <seq> <rid> <kind> <state> <event-json> <want kid()> <what>
  answer "$1" "$(ev "$1" "$2" "$U/issue-7" "$3" "$4" "$5")"; : > "$WORK/curl.log"; pull
  ok; [ "$(kid)" = "$6" ] || fail "D: $7" "$(kid) (rc=$rc $err)"
}
step 21 "op:$O1:running" dispatch running '{"op":"'"$O1"'","node":"m4","issue":"42","repo":"acme/app","state":"running"}' "1|▸|starting|1" "running ⇒ starting"
ok; grep -q "ops=$O1" "$WORK/curl.log" || fail "E: an open placement rides along as ops=" "$(cat "$WORK/curl.log")"
step 22 "op:$O1:done" dispatch done '{"op":"'"$O1"'","node":"m4","issue":"42","repo":"acme/app","state":"done","window":"@9","exit":0}' "1|▸|running|1" "done ⇒ running there"
ok; grep -q "ops=$O1" "$WORK/curl.log" || fail "E: still open when this pull asked" "$(cat "$WORK/curl.log")"
step 23 "$F/issue-42#2.1" report WAITING '{"child":"issue-42","state":"WAITING","pr":"60","verdict":"pr-open","node":"m4"}' "1|⏳|pr|1" "a WAITING report with its PR ⇒ pr"
ok; ! grep -q 'ops=' "$WORK/curl.log" || fail "E: a final placement is not asked about again" "$(cat "$WORK/curl.log")"
step 24 "$F/issue-42#2.2" report MERGED '{"child":"issue-42","state":"MERGED","pr":"60","node":"m4"}' "1|✓|merged|1" "MERGED ⇒ merged, ✓"
ok; [ "$(grep -c '"rid"' "$DISP")" = 2 ] && [ "$(nlines "$DISP")" = 3 ] || fail "D: the stream's states are rid-stamped rows of .dispatch" "$(cat "$DISP")"
pull
ok; [ "$(nlines "$DISP")" = 3 ] && [ "$(nlines "$LEDGER")" = 2 ] || fail "D: the same answer twice adds nothing" "$(cat "$DISP" "$LEDGER")"

# --- F: a later quiet row never un-lands -----------------------------------------------------
B="$WORK/f/scratch-1.ndjson"; mkdir -p "$WORK/f"
for st in MERGED STOPPED; do printf '{"child":"issue-5","state":"%s","pr":"70"}' "$st" | python3 "$BIN/fleet-children.py" append --file "$B" >/dev/null; done
printf '{"child":"issue-6","state":"STOPPED","pr":""}' | python3 "$BIN/fleet-children.py" append --file "$B" >/dev/null
printf 'issue-6\t#71\tMERGED\n' > "$WORK/f/prmap"
fo=$(python3 "$BIN/fleet-children.py" show --dir "$WORK/f" --parent scratch-1 --json --prmap "$WORK/f/prmap" < /dev/null)
ok; python3 -c 'import json, sys; d = json.loads(sys.argv[1]); k = {c["child"]: c for c in d["children"]}
assert k["issue-5"]["bucket"] == "✓" and k["issue-5"]["progress"] == "merged" and k["issue-5"]["last"]["state"] == "STOPPED", k["issue-5"]
assert k["issue-5"]["settled"]["state"] == "MERGED", k["issue-5"]
assert k["issue-6"]["bucket"] == "✓" and k["issue-6"]["progress"] == "merged", k["issue-6"]
assert d["summary"]["text"] == "2/2 ✓", d["summary"]' "$fo" 2>"$WORK/err" || fail "F: STOPPED after MERGED (or a merged PR) reads ✓ merged" "$(cat "$WORK/err")"
ft=$(python3 "$BIN/fleet-children.py" show --dir "$WORK/f" --parent scratch-1 --prmap "$WORK/f/prmap" < /dev/null)
ok; case "$ft" in *'✓ issue-5'*'MERGED #70'*) ;; *) fail "F: the text row shows the MERGED" "$ft" ;; esac

if [ "$FAIL" -gt 0 ]; then
  printf 'hub-progress selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2; exit 1
fi
printf 'hub-progress selftest: OK (%d checks)\n' "$CHECKS"
