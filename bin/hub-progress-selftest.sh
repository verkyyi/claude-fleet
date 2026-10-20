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
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-repo-fixture.sh"
REAL_TMUX=$(command -v tmux) || { echo 'hub-progress selftest: tmux absent — SKIP'; exit 0; }
st_need python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hub-progress.XXXXXX")" || exit 2
L="hprg$$"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
: > "$FLEET_CONF_DIR/fleets/$L/conf"
fx_repo "$FLEET_CONF_DIR" "$L" acme/app FLEET_MAIN="$WORK/main"
unset TMUX TMUX_PANE CCQUOTA_FLEET CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_PROGRESS FLEET_CHILD_REPORT FLEET_PROGRESS_MAX_AGE

st_tally
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
F=11111111-2222-3333-4444-555555555555          # a fleet on another machine ("mac-a")
O1=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee         # the placement's operation id
CD="$(bash -c '. "$1/fleet-lib.sh"; . "$1/fleet-children-lib.sh"; children_dir "$2"' _ "$BIN" "$L")"
LEDGER="$CD/acme-app:issue-7.ndjson"; DISP="$CD/acme-app:issue-7.dispatch"   # one book per parent, its repo in the key (#1939)
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
k = [c for c in d["children"] if c["child"] == "acme-app:issue-42"]
print("%d|%s|%s|%d" % (d["summary"]["total"], k[0]["bucket"] if k else "", k[0].get("progress", "") if k else "", len(k)))'; }

# --- A: degenerate ----------------------------------------------------------------------
run bash "$BIN/fleet-children.sh" -L "$L" issue-7; base="$rc|$out"
answer 9 "$(ev 9 "$F/issue-42#1.1" "$U/issue-7" report MERGED '{"child":"issue-42","state":"MERGED","pr":"50","node":"mac-a"}')"
pull
st_count; [ "$rc" = 3 ] && [ ! -e "$WORK/curl.log" ] && [ ! -d "$FLEET_CONF_DIR/hub-progress" ] \
  || st_miss "A: hub off ⇒ progress exits 3, asks nothing, writes nothing" "rc=$rc $err"
run bash "$BIN/fleet-children.sh" -L "$L" issue-7
st_count; [ "$rc|$out" = "$base" ] && [ ! -e "$WORK/curl.log" ] || st_miss "A: hub off ⇒ fleet-children.sh byte for byte, no pull" "[$out] vs [$base]"
export CCQUOTA_FLEET=1 CCQUOTA_TOKEN=t0k CCQUOTA_HUB_URL=http://hub.invalid
FLEET_HUB_PROGRESS=0 run bash "$BIN/fleet-hub-node.sh" progress
st_count; [ "$rc" = 3 ] && [ ! -e "$WORK/curl.log" ] || st_miss "A: FLEET_HUB_PROGRESS=0 ⇒ exit 3, nothing asked" "rc=$rc"

# --- B: a MERGED that only the hub carried -----------------------------------------------
answer 9 \
  "$(ev 8 "$F/issue-42#1.1" "$U/issue-7" report MERGED '{"child":"issue-42","state":"MERGED","pr":"50","title":"kid","node":"mac-a"}')" \
  "$(ev 9 "$F/issue-43#1.1" "$F/issue-1" report MERGED '{"child":"issue-43","state":"MERGED","node":"mac-a"}')"
pull
st_count; [ "$rc" = 0 ] && [ "$(nlines "$LEDGER")" = 1 ] || st_miss "B: the hub's MERGED lands in the parent's book" "rc=$rc lines=$(nlines "$LEDGER") $out $err"
st_count; python3 -c 'import json, sys; e = json.loads(open(sys.argv[1]).readline())
sys.exit(0 if (e["child"], e["state"], e["pr"], e["node"], e["rid"]) == ("acme-app:issue-42", "MERGED", "50", "mac-a", sys.argv[2]) else 1)' \
  "$LEDGER" "$F/issue-42#1.1" || st_miss "B: the row carries node + rid" "$(cat "$LEDGER")"
st_count; case "$out" in *'1 new row(s), 1 parent(s) not here'*) ;; *) st_miss "B: a parent of a fleet not here is skipped, said once" "$out" ;; esac
st_count; [ "$(cat "$FLEET_CONF_DIR/hub-progress/seq")" = 9 ] || st_miss "B: the cursor moves to the answer's seq" "$(cat "$FLEET_CONF_DIR/hub-progress/seq")"
st_count; grep -q 'since=0' "$WORK/curl.log" && grep -q 'Bearer t0k' "$WORK/curl.log" && grep -q '/v1/node/progress' "$WORK/curl.log" \
  || st_miss "B: GET /v1/node/progress?since=0 with the node token" "$(cat "$WORK/curl.log")"
pull
st_count; grep -q 'since=9' "$WORK/curl.log" || st_miss "B: the next pull asks from the cursor" "$(tail -n 1 "$WORK/curl.log")"

# --- C: two roads, one row ----------------------------------------------------------------
R2="$F/issue-44#1.1"
relay=$(python3 -c 'import json, sys; f, t, i = sys.argv[1:4]
print(json.dumps({"id": i, "kind": "child_report", "from": f, "to": t, "from_node": "mac-a",
  "payload": {"child": "issue-44", "state": "WAITING", "pr": "51", "tier": "silent", "msg": "x"}}))' "$F/issue-44" "$U/issue-7" "$R2")
printf '%s' "$relay" | env -u TMUX bash "$BIN/fleet-hub-node.sh" deliver 2>/dev/null
st_count; [ "$(nlines "$LEDGER")" = 2 ] || st_miss "C: the push lands first" "$(cat "$LEDGER")"
answer 10 "$(ev 10 "$R2" "$U/issue-7" report WAITING '{"child":"issue-44","state":"WAITING","pr":"51","tier":"silent","node":"mac-a"}')"
pull
st_count; [ "$(nlines "$LEDGER")" = 2 ] || st_miss "C: the same event by the pull is not a second row" "$(cat "$LEDGER")"
rm -f "$FLEET_CONF_DIR/hub-progress/seq"
answer 10 \
  "$(ev 8 "$F/issue-42#1.1" "$U/issue-7" report MERGED '{"child":"issue-42","state":"MERGED","pr":"50","node":"mac-a"}')" \
  "$(ev 10 "$R2" "$U/issue-7" report WAITING '{"child":"issue-44","state":"WAITING","pr":"51","node":"mac-a"}')"
pull
st_count; [ "$(nlines "$LEDGER")" = 2 ] && [ -z "$out" ] || st_miss "C: a pull from seq 0 again adds nothing" "lines=$(nlines "$LEDGER") $out"

# --- D + E: a placement advances in one row -------------------------------------------------
: > "$LEDGER"; rm -f "$DISP" "$FLEET_CONF_DIR/hub-progress/seq"
# The spawn's own row, as dash-issue-session.sh writes it for an --async placement.
python3 "$BIN/fleet-children.py" dispatch --file "$DISP" --child acme-app:issue-42 --state accepted --node mac-a --op "$O1" >/dev/null
st_count; [ "$(kid)" = "1|▸|accepted|1" ] || st_miss "D: placed, nothing more ⇒ one working row, progress accepted" "$(kid)"
txt=$(env -u TMUX FLEET_HUB_PROGRESS=0 bash "$BIN/fleet-children.sh" -L "$L" issue-7)
st_count; case "$txt" in *'↗ acme-app:issue-42'*) st_miss "D: no ↗ line of its own" "$txt" ;; *'▸ acme-app:issue-42'*'gone · mac-a'*'accepted'*'0/1 ✓') ;; *) st_miss "D: the text row says where and how far" "$txt" ;; esac
step() { # <seq> <rid> <kind> <state> <event-json> <want kid()> <what>
  answer "$1" "$(ev "$1" "$2" "$U/issue-7" "$3" "$4" "$5")"; : > "$WORK/curl.log"; pull
  st_count; [ "$(kid)" = "$6" ] || st_miss "D: $7" "$(kid) (rc=$rc $err)"
}
step 21 "op:$O1:running" dispatch running '{"op":"'"$O1"'","node":"mac-a","issue":"42","repo":"acme/app","state":"running"}' "1|▸|starting|1" "running ⇒ starting"
st_count; grep -q "ops=$O1" "$WORK/curl.log" || st_miss "E: an open placement rides along as ops=" "$(cat "$WORK/curl.log")"
step 22 "op:$O1:done" dispatch 'done' '{"op":"'"$O1"'","node":"mac-a","issue":"42","repo":"acme/app","state":"done","window":"@9","exit":0}' "1|▸|running|1" "done ⇒ running there"
st_count; grep -q "ops=$O1" "$WORK/curl.log" || st_miss "E: still open when this pull asked" "$(cat "$WORK/curl.log")"
step 23 "$F/issue-42#2.1" report WAITING '{"child":"issue-42","state":"WAITING","pr":"60","verdict":"pr-open","node":"mac-a"}' "1|⏳|pr|1" "a WAITING report with its PR ⇒ pr"
st_count; ! grep -q 'ops=' "$WORK/curl.log" || st_miss "E: a final placement is not asked about again" "$(cat "$WORK/curl.log")"
step 24 "$F/issue-42#2.2" report MERGED '{"child":"issue-42","state":"MERGED","pr":"60","node":"mac-a"}' "1|✓|merged|1" "MERGED ⇒ merged, ✓"
st_count; [ "$(grep -c '"rid"' "$DISP")" = 2 ] && [ "$(nlines "$DISP")" = 3 ] || st_miss "D: the stream's states are rid-stamped rows of .dispatch" "$(cat "$DISP")"
pull
st_count; [ "$(nlines "$DISP")" = 3 ] && [ "$(nlines "$LEDGER")" = 2 ] || st_miss "D: the same answer twice adds nothing" "$(cat "$DISP" "$LEDGER")"

# --- F: a later quiet row never un-lands -----------------------------------------------------
B="$WORK/f/scratch-1.ndjson"; mkdir -p "$WORK/f"
for st in MERGED STOPPED; do printf '{"child":"issue-5","state":"%s","pr":"70"}' "$st" | python3 "$BIN/fleet-children.py" append --file "$B" >/dev/null; done
printf '{"child":"issue-6","state":"STOPPED","pr":""}' | python3 "$BIN/fleet-children.py" append --file "$B" >/dev/null
printf 'issue-6\t#71\tMERGED\n' > "$WORK/f/prmap"
fo=$(python3 "$BIN/fleet-children.py" show --dir "$WORK/f" --parent scratch-1 --json --prmap "$WORK/f/prmap" < /dev/null)
st_count; python3 -c 'import json, sys; d = json.loads(sys.argv[1]); k = {c["child"]: c for c in d["children"]}
assert k["issue-5"]["bucket"] == "✓" and k["issue-5"]["progress"] == "merged" and k["issue-5"]["last"]["state"] == "STOPPED", k["issue-5"]
assert k["issue-5"]["settled"]["state"] == "MERGED", k["issue-5"]
assert k["issue-6"]["bucket"] == "✓" and k["issue-6"]["progress"] == "merged", k["issue-6"]
assert d["summary"]["text"] == "2/2 ✓", d["summary"]' "$fo" 2>"$WORK/err" || st_miss "F: STOPPED after MERGED (or a merged PR) reads ✓ merged" "$(cat "$WORK/err")"
ft=$(python3 "$BIN/fleet-children.py" show --dir "$WORK/f" --parent scratch-1 --prmap "$WORK/f/prmap" < /dev/null)
st_count; case "$ft" in *'✓ issue-5'*'MERGED #70'*) ;; *) st_miss "F: the text row shows the MERGED" "$ft" ;; esac

st_done
