#!/bin/bash
# fleet-worker-records-selftest.sh — a reaped worker's evidence and history row
# reach the hub, and the owner's other machine reads them back (issue #1609,
# EPIC #1645 C9): bin/fleet-worker-records.sh push/fetch, and the two readers
# that merge it — bin/fleet-evidence.sh list/export and bin/fleet-history.sh
# list. The hub is stubbed through FLEET_HUB_CURL; gh and tmux are faked; no
# network, no tmux server. (The hub half — owner-only, idempotent, 30 days — is
# the Go gate's: TestWorkerRecordsUploadReadOwnerOnly.)
#
# What it pins:
#   A. degenerate   no node.env: push/fetch exit 3, curl NEVER called, nothing on
#                   stdout; `fleet-evidence.sh list --epic` and `fleet-history.sh
#                   list` print byte for byte what they print with no
#                   fleet-worker-records.sh beside them; FLEET_WORKER_RECORDS=0
#                   the same
#   B. push         POST /v1/node/worker-records with the bearer token FROM
#                   node.env; worker_id <fleet UUID>/issue-<N> (no window); repo,
#                   issue, key, the EPIC read off the evidence dir; every capture
#                   with its stage/ts/note and its bytes; the ledger row as the
#                   `history` record; --evidence-only leaves the row out; a text
#                   capture over 2 MiB is cut, never dropped
#   C. fetch        this fleet's own uploads are skipped; another machine's
#                   evidence is written under remote/<slug>/<issue>/ and printed
#                   as a row; history rows print with their machine
#   D. evidence     list --epic: a member with local captures is untouched; a
#                   `none` member fills from the hub (`[@m4]` note, the cached
#                   path); one the hub saw run elsewhere without a capture reads
#                   「在 m4 上跑过，没拍」; hub down → 「别机未查（入口不可达）」;
#                   export copies the remote file beside the page
#   E. history      list merges another machine's row (summary `@m4 …`), skips a
#                   session this ledger already has; --local leaves it out
#   F. old hub      404 → exit 3, nothing printed
#   G. wiring       fleet_reap_record pushes after recording; fleet-report-parent
#                   pushes --evidence-only on merged/blocked
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKS=0
fail() { printf 'fleet-worker-records selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }
has()  { case "$2" in *"$3"*) ok ;; *) fail "$1 — missing [$3]" "$2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) fail "$1 — unexpected [$3]" "$2" ;; *) ok ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-wr-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
export FLEET_GH_WRITE_GAP=0 FLEET_SESSION=wrsess FLEET_HISTORY_LEDGER="$WORK/ledger.tsv"
mkdir -p "$HOME" "$TMPDIR" "$WORK/bin" "$WORK/fakebin" "$FLEET_CONF_DIR/fleets/wrsess"
unset CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_CURL FLEET_HUB_TIMEOUT FLEET_WORKER_RECORDS TMUX TMUX_PANE
for f in fleet-worker-records.sh fleet-evidence.sh fleet-history.sh fleet-lib.sh; do
  cp "$BIN/$f" "$WORK/bin/$f" || fail "copy $f"
done
chmod +x "$WORK"/bin/*.sh
printf 'FLEET_REPO=o/r\n' > "$FLEET_CONF_DIR/fleets/wrsess/conf"
SUT="$WORK/bin/fleet-worker-records.sh"
EV="$WORK/bin/fleet-evidence.sh"
HI="$WORK/bin/fleet-history.sh"

cat > "$WORK/fakebin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"/parent"*)     [ -n "${GH_PARENT:-}" ] && { printf '%s\n' "$GH_PARENT"; exit 0; }; exit 1 ;;
  *"/sub_issues"*) printf '%b' "${GH_SUBS:-}"; exit 0 ;;
esac
exit 1
EOF
cat > "$WORK/fakebin/tmux" <<'EOF'
#!/bin/bash
case "$*" in *session_name*) echo wrsess ;; esac
exit 0
EOF
STUB="$WORK/curl"
cat > "$STUB" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
body=''
while [ $# -gt 0 ]; do case "$1" in --data-binary) body="${2#@}"; shift 2 ;; *) shift ;; esac; done
[ -n "$body" ] && cp "$body" "$STUB_BODY"
[ "${FAKE_RC:-0}" -eq 0 ] || exit "$FAKE_RC"
if [ -n "$body" ]; then printf '{"stored":2}\n%s' "${FAKE_CODE:-200}"
else cat "${FAKE_GET:-/dev/null}"; printf '\n%s' "${FAKE_CODE:-200}"; fi
EOF
chmod +x "$WORK"/fakebin/* "$STUB"
export PATH="$WORK/fakebin:$PATH" STUB_LOG="$WORK/curl.log" STUB_BODY="$WORK/curl.body" FLEET_HUB_CURL="$STUB"
reset() { rm -f "$STUB_LOG" "$STUB_BODY"; unset FAKE_RC FAKE_CODE FAKE_GET; }

# The control database fleet_uuid derives this fleet's UUID from.
mkdir -p "$FLEET_CONF_DIR/control"
python3 - "$FLEET_CONF_DIR/control/state.sqlite3" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT)")
con.execute("INSERT INTO metadata VALUES ('machine_id', '44444444-4444-4444-8444-444444444444')")
con.commit()
PY
OWN=$(bash -c '. "$1/fleet-lib.sh"; fleet_uuid wrsess' _ "$WORK/bin")
[ -n "$OWN" ] || fail "setup: no fleet UUID"
OTHER=55555555-5555-4555-8555-555555555555

# Evidence for member 7 of EPIC 5, and a ledger row for it.
printf 'before shot\n' > "$WORK/b.txt"
GH_PARENT=5 bash "$EV" before --session wrsess --issue 7 --note 'the before' -q "$WORK/b.txt" || fail "setup: evidence before"
head -c 3000000 /dev/zero | tr '\0' a > "$WORK/big.txt"
GH_PARENT=5 bash "$EV" after --session wrsess --issue 7 -q "$WORK/big.txt" || fail "setup: evidence after"
printf '2026-10-05T01:00:00Z\t7\tthe title\t70\tabc1234\t/wt/issue-7\t/t\tsid-local\t-\tlanded\tissue-5\n' > "$FLEET_HISTORY_LEDGER"

# ---- A. degenerate -----------------------------------------------------------
reset
out=$(bash "$SUT" push --session wrsess --repo o/r --key 7 2>/dev/null); rc=$?
{ [ "$rc" -eq 3 ] && [ -z "$out" ] && [ ! -e "$STUB_LOG" ]; } || fail "A: push without node.env → exit $rc, out '$out'"; ok
out=$(bash "$SUT" fetch --session wrsess --repo o/r --epic 5 2>/dev/null); rc=$?
{ [ "$rc" -eq 3 ] && [ -z "$out" ] && [ ! -e "$STUB_LOG" ]; } || fail "A: fetch without node.env → exit $rc"; ok
ev_with=$(GH_SUBS='7\n8\n9\n' bash "$EV" list --session wrsess --epic 5 2>&1)
hi_with=$(bash "$HI" list --repo o/r 2>&1)
mv "$SUT" "$WORK/sut.off"
ev_without=$(GH_SUBS='7\n8\n9\n' bash "$EV" list --session wrsess --epic 5 2>&1)
hi_without=$(bash "$HI" list --repo o/r 2>&1)
mv "$WORK/sut.off" "$SUT"
[ "$ev_with" = "$ev_without" ] || fail "A: evidence list differs on a login that is no node" "$ev_with"; ok
[ "$hi_with" = "$hi_without" ] || fail "A: history list differs on a login that is no node" "$hi_with"; ok
[ ! -e "$STUB_LOG" ] || fail "A: the readers asked the hub without a node token"; ok

printf 'CCQUOTA_TOKEN=node-secret\nCCQUOTA_HUB_URL=https://hub.example\n' > "$FLEET_CONF_DIR/node.env"
chmod 600 "$FLEET_CONF_DIR/node.env"
reset
out=$(FLEET_WORKER_RECORDS=0 bash "$SUT" push --session wrsess --repo o/r --key 7 2>/dev/null); rc=$?
{ [ "$rc" -eq 3 ] && [ ! -e "$STUB_LOG" ]; } || fail "A: FLEET_WORKER_RECORDS=0 → exit $rc"; ok

# ---- B. push -----------------------------------------------------------------
reset
out=$(bash "$SUT" push --session wrsess --repo o/r --key 7 2>"$WORK/err"); rc=$?
[ "$rc" -eq 0 ] || fail "B: push exit $rc: $(cat "$WORK/err")"; ok
has "B: says what it pushed" "$out" "pushed 2 record(s) for issue-7 as $OWN/issue-7"
log=$(cat "$STUB_LOG")
has "B: bearer from node.env" "$log" "Authorization: Bearer node-secret"
has "B: the endpoint" "$log" "https://hub.example/v1/node/worker-records"
[ -z "${CCQUOTA_TOKEN:-}" ] || fail "B: the token leaked into the caller's env"; ok
chk=$(python3 - "$STUB_BODY" "$OWN" <<'PY'
import base64, json, sys
b = json.load(open(sys.argv[1]))
assert b["worker_id"] == sys.argv[2] + "/issue-7", b["worker_id"]
assert (b["repo"], b["issue"], b["key"], b["epic"]) == ("o/r", 7, "issue-7", 5), b
ev = [r for r in b["records"] if r["kind"] == "evidence"]
hi = [r for r in b["records"] if r["kind"] == "history"]
assert len(ev) == 2 and len(hi) == 1, b["records"]
bef = [r for r in ev if r["stage"] == "before"][0]
assert base64.b64decode(bef["content"]) == b"before shot\n" and bef["note"] == "the before", bef
assert bef["name"].startswith("before-") and bef["name"].endswith("-b.txt"), bef["name"]
aft = base64.b64decode([r for r in ev if r["stage"] == "after"][0]["content"])
assert len(aft) <= 2 << 20 and aft.endswith(b"[cut at 2 MiB for the hub]\n"), len(aft)
row = base64.b64decode(hi[0]["content"]).decode()
assert row.split("\t")[7] == "sid-local" and hi[0]["name"] == "ledger" and hi[0]["stage"] == "landed", row
print("ok")
PY
)
[ "$chk" = ok ] || fail "B: the upload body: $chk"; ok
reset
bash "$SUT" push --session wrsess --repo o/r --key 7 --evidence-only >/dev/null 2>&1 || fail "B: --evidence-only push failed"
python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); sys.exit(any(r["kind"]=="history" for r in b["records"]))' "$STUB_BODY" \
  || fail "B: --evidence-only sent the ledger row"; ok

# ---- C. fetch ----------------------------------------------------------------
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
ROW8=$(printf '2026-10-05T03:00:00Z\t8\tremote title\t80\tdef5678\t/wt/issue-8\t/t\tsid-remote\t-\tlanded\tissue-5')
ROW9=$(printf '2026-10-05T02:00:00Z\t9\tno shots\t90\tfff0000\t/wt/issue-9\t/t\tsid-9\t-\tlanded\tissue-5')
ROWDUP=$(printf '2026-10-05T01:00:00Z\t7\tthe title\t70\tabc1234\t/wt/issue-7\t/t\tsid-local\t-\tlanded\tissue-5')
cat > "$WORK/get.json" <<EOF
{"records":[
 {"fleet_id":"$OWN","node":"m5","repo":"o/r","issue":7,"kind":"evidence","name":"after-x-own.txt","stage":"after","ts":"T0","content":"$(b64 own)"},
 {"fleet_id":"$OTHER","node":"m4","repo":"o/r","issue":8,"kind":"evidence","name":"after-20261005T030000Z-shot.png","stage":"after","ts":"20261005T030000Z","note":"the after","content":"$(b64 PNGBYTES)"},
 {"fleet_id":"$OTHER","node":"m4","repo":"o/r","issue":8,"kind":"history","name":"ledger","stage":"landed","content":"$(b64 "$ROW8")"},
 {"fleet_id":"$OTHER","node":"m4","repo":"o/r","issue":9,"kind":"history","name":"ledger","stage":"landed","content":"$(b64 "$ROW9")"},
 {"fleet_id":"$OTHER","node":"m4","repo":"o/r","issue":7,"kind":"history","name":"ledger","stage":"landed","content":"$(b64 "$ROWDUP")"}
]}
EOF
reset; export FAKE_GET="$WORK/get.json"
out=$(bash "$SUT" fetch --session wrsess --repo o/r --epic 5 2>"$WORK/err"); rc=$?
[ "$rc" -eq 0 ] || fail "C: fetch exit $rc: $(cat "$WORK/err")"; ok
hasnt "C: this fleet's own upload is skipped" "$out" "own"
RP="$FLEET_CONF_DIR/fleets/wrsess/remote/o-r/8/after-20261005T030000Z-shot.png"
has "C: the evidence row" "$out" "$(printf 'evidence\t8\tafter\t20261005T030000Z\t%s\tthe after\tm4' "$RP")"
[ "$(cat "$RP" 2>/dev/null)" = PNGBYTES ] || fail "C: the remote file was not written"; ok
has "C: a history row" "$out" "$(printf 'history\t9\tm4\t%s' "$ROW9")"
has "C: asks by epic" "$(cat "$STUB_LOG")" "worker-records?repo=o/r&epic=5"

# ---- D. evidence list / export -----------------------------------------------
reset; export FAKE_GET="$WORK/get.json"
out=$(GH_SUBS='7\n8\n9\n10\n' bash "$EV" list --session wrsess --epic 5 2>&1)
has "D: member 7 keeps its local rows" "$out" "$(printf '7\tbefore\t')"
has "D: member 8 filled from the hub" "$out" "$(printf '8\tafter\t20261005T030000Z\t%s\t[@m4] the after' "$RP")"
has "D: member 9 ran elsewhere, no shot" "$out" "$(printf '9\tnone\t\t\t在 m4 上跑过，没拍')"
has "D: member 10 plain none" "$out" "$(printf '10\tnone\t\t\t\n')"
out=$(FAKE_RC=7 GH_SUBS='7\n8\n9\n10\n' bash "$EV" list --session wrsess --epic 5 2>&1)
has "D: hub down" "$out" "$(printf '9\tnone\t\t\t别机未查（入口不可达）')"
mkdir -p "$WORK/page"
out=$(GH_SUBS='7\n8\n9\n' bash "$EV" export --session wrsess --epic 5 "$WORK/page" 2>&1)
has "D: export prints the relative path" "$out" "$(printf '8\tafter\t20261005T030000Z\tevidence/8/after-20261005T030000Z-shot.png')"
[ "$(cat "$WORK/page/evidence/8/after-20261005T030000Z-shot.png" 2>/dev/null)" = PNGBYTES ] || fail "D: export did not copy the remote file"; ok
has "D: export keeps the none note" "$out" "在 m4 上跑过，没拍"

# ---- E. history list ---------------------------------------------------------
reset; export FAKE_GET="$WORK/get.json"
out=$(bash "$HI" list --repo o/r 2>&1)
has "E: the remote row, marked" "$out" "@m4"
has "E: the remote title" "$out" "remote title"
n=$(printf '%s\n' "$out" | grep -c 'the title')
[ "$n" -eq 1 ] || fail "E: a session the ledger has is listed $n times" "$out"; ok
has "E: asks for history" "$(cat "$STUB_LOG")" "kind=history"
out=$(bash "$HI" list --repo o/r --local 2>&1)
hasnt "E: --local" "$out" "remote title"

# ---- F. old hub --------------------------------------------------------------
reset
out=$(FAKE_CODE=404 bash "$SUT" fetch --session wrsess --repo o/r --epic 5 2>/dev/null); rc=$?
{ [ "$rc" -eq 3 ] && [ -z "$out" ]; } || fail "F: 404 → exit $rc, out '$out'"; ok
out=$(FAKE_CODE=404 bash "$SUT" push --session wrsess --repo o/r --key 7 2>/dev/null); rc=$?
[ "$rc" -eq 3 ] || fail "F: push to an old hub → exit $rc"; ok

# ---- G. wiring ---------------------------------------------------------------
grep -A80 '^fleet_reap_record()' "$BIN/fleet-lib.sh" | grep -q 'fleet-worker-records.sh" push' \
  || fail "G: fleet_reap_record does not push"; ok
grep -q 'fleet-worker-records.sh" push.*' "$BIN/fleet-report-parent.sh" && grep -q -- '--evidence-only' "$BIN/fleet-report-parent.sh" \
  || fail "G: fleet-report-parent.sh does not push --evidence-only"; ok

printf 'fleet-worker-records selftest: OK (%d checks)\n' "$CHECKS"
