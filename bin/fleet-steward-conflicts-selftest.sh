#!/bin/bash
# fleet-steward-conflicts-selftest.sh — hermetic tests for
# bin/fleet-steward-conflicts.sh, the steward's «tell, never hold back» probe
# (issue #2673, EPIC #2668 C5). `gh` is a PATH fake that answers REST reads from
# files and logs every call; TMPDIR (so the dash cache) and FLEET_CONF_DIR are a
# sandbox; the quota reading comes through FLEET_STEWARD_QUOTA_CMD. Pinned:
#   A. two batches' PRs on one file → one overlap (prs, batches, first); two PRs
#      of ONE batch on a file → nothing; a PR with no EPIC parent is its own batch
#   B. the files refill: ≤ FLEET_STEWARD_FILES_BUDGET (10) REST reads a run, the
#      rest `deferred` to the next run; a cached PR costs nothing; a closed PR
#      leaves the cache
#   C. no pr-refresh cache → ONE REST `/pulls?state=open` list
#   D. ci: queued count + the oldest wait; a run GitHub never started is `stuck`,
#      out of both; gh refusing → null, never 0
#   E. quota: blind / stale / never / fresh-with-no-rows ⇒ state blind (pct null);
#      fresh + rows ⇒ ok, the best headroom; off ⇒ off
#   F. only reads: gh is never asked anything but `api` GET; usage / no repo codes
#   G. the text mode speaks fleet-ui-lang.sh's words (额度读不到)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-steward-conflicts.sh"
[ -x "$SRC" ] || { echo "selftest: $SRC missing" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fsc-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

pass=0
ok()   { pass=$((pass+1)); }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${OUT:-}" ] && printf -- '--- output ---\n%s\n' "$OUT" >&2; exit 1; }
eq()   { [ "$2" = "$3" ] && ok || fail "$1 — expected [$2], got [$3]"; }
has()  { case "$2" in *"$3"*) ok ;; *) fail "$1 — missing [$3]" ;; esac; }

mkdir -p "$WORK/fake" "$WORK/gh" "$WORK/tmp" "$WORK/conf"
cat > "$WORK/fake/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FSC_GH_LOG"
[ "${1:-}" = api ] || exit 9
shift; [ "${1:-}" = --paginate ] && shift
f="$FSC_GH_DIR/$(printf '%s' "$1" | tr '/?&=' '____')"
[ -f "$f" ] || { echo 'HTTP 404' >&2; exit 1; }
cat "$f"
EOF
chmod +x "$WORK/fake/gh"
export PATH="$WORK/fake:$PATH" TMPDIR="$WORK/tmp" FLEET_CONF_DIR="$WORK/conf"
export FSC_GH_LOG="$WORK/gh.log" FSC_GH_DIR="$WORK/gh"
unset FLEET_SESSION TMUX TMUX_PANE
FD="$WORK/tmp/.claude-dash/fleets/o-r"; mkdir -p "$FD"
QROWS="$WORK/tmp/.claude-dash/global/account.quota"; mkdir -p "${QROWS%/*}"

ghf() { printf '%s' "$2" > "$WORK/gh/$(printf '%s' "$1" | tr '/?&=' '____')"; }
files() { local n=$1 out='[' f sep=''; shift; for f in "$@"; do out="$out$sep{\"filename\":\"$f\"}"; sep=,; done
          ghf "repos/o/r/pulls/$n/files?per_page=100" "$out]"; }
iso() { python3 -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-int(sys.argv[1]))))' "$1"; }
run() { : > "$FSC_GH_LOG"; OUT=$(FLEET_STEWARD_QUOTA_CMD="${QCMD:-printf 'off\t0\t0\n'}" "$SRC" "$@" 2>&1); RC=$?; }
jq_() { printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1]), sort_keys=True))' "$1"; }
calls() { grep -c "$1" "$FSC_GH_LOG" 2>/dev/null; }

# ---- A. overlaps by batch -----------------------------------------------------
printf 'issue-11\t#21\tOPEN\t✓\tready\t\nissue-12\t#22\tOPEN\t…\t\t\nissue-13\t#23\tOPEN\t\t\t\nissue-14\t#24\tOPEN\t\t\t\nissue-15\t#25\tMERGED\t✓\t\tabc\n' > "$FD/prmap"
printf '11\t100\n12\t200\n13\t100\n' > "$FD/parents"
files 21 bin/a.sh bin/b.sh; files 22 bin/a.sh; files 23 bin/b.sh; files 24 bin/b.sh docs/c.md; files 25 bin/a.sh
ghf 'repos/o/r/actions/runs?status=queued&per_page=100' '{"total_count":0,"workflow_runs":[]}'
run --json --repo o/r
eq "A rc" 0 "$RC"
eq "A two overlaps" 2 "$(jq_ 'len(d["overlaps"])')"
eq "A a.sh: batches 100 vs 200" '{"batches": ["o/r#100", "o/r#200"], "first": 21, "path": "bin/a.sh", "prs": [21, 22], "repo": "o/r"}' "$(jq_ 'd["overlaps"][0]')"
# b.sh: #21 and #23 share batch 100 (never alone a finding) — #24 has no parent, its own batch
eq "A b.sh: the no-parent PR is its own batch" '{"batches": ["o/r#100", null], "first": 21, "path": "bin/b.sh", "prs": [21, 23, 24], "repo": "o/r"}' "$(jq_ 'd["overlaps"][1]')"
eq "A merged PR not read" 0 "$(calls 'pulls/25/')"
eq "A four file reads" 4 "$(jq_ 'd["rest"]["files"]')"
printf '11\t100\n12\t100\n13\t100\n14\t100\n' > "$FD/parents"
run --json --repo o/r
eq "A one batch → no overlap" '[]' "$(jq_ 'd["overlaps"]')"
eq "A cached → no file read" 0 "$(calls 'files')"

# ---- B. the refill budget -----------------------------------------------------
: > "$FD/prmap"; rm -f "$FD/prfiles.json"
for n in 31 32 33 34 35 36 37 38 39 40 41 42; do
  printf 'issue-%s\t#%s\tOPEN\t\t\t\n' "$n" "$n" >> "$FD/prmap"; files "$n" "f$n"
done
run --json --repo o/r
eq "B ten reads" 10 "$(jq_ 'd["rest"]["files"]')"
eq "B two deferred" 2 "$(jq_ 'd["rest"]["deferred"]')"
eq "B gh saw ten" 10 "$(calls 'files')"
run --json --repo o/r
eq "B the rest next run" 2 "$(jq_ 'd["rest"]["files"]')"
eq "B nothing deferred" 0 "$(jq_ 'd["rest"]["deferred"]')"
FLEET_STEWARD_FILES_BUDGET=3 FLEET_STEWARD_FILES_TTL=0 run --json --repo o/r
eq "B stale + budget 3" 3 "$(jq_ 'd["rest"]["files"]')"
printf 'issue-31\t#31\tOPEN\t\t\t\n' > "$FD/prmap"
run --json --repo o/r
eq "B closed PRs leave the cache" '["31"]' "$(python3 -c 'import json,sys; print(json.dumps(sorted(json.load(open(sys.argv[1])))))' "$FD/prfiles.json")"

# ---- C. no pr-refresh cache ---------------------------------------------------
rm -f "$FD/prmap" "$FD/prfiles.json"
ghf 'repos/o/r/pulls?state=open&per_page=100' '[{"number":51,"head":{"ref":"issue-61"}},{"number":52,"head":{"ref":"issue-62"}}]'
printf '61\t300\n62\t400\n' > "$FD/parents"
files 51 x.go; files 52 x.go
run --json --repo o/r
eq "C one list read" 1 "$(jq_ 'd["rest"]["lists"]')"
eq "C overlap off the REST list" '[51, 52]' "$(jq_ 'd["overlaps"][0]["prs"]')"

# ---- D. ci queue --------------------------------------------------------------
ghf 'repos/o/r/actions/runs?status=queued&per_page=100' "{\"total_count\":3,\"workflow_runs\":[{\"created_at\":\"$(iso 120)\"},{\"created_at\":\"$(iso 600)\"},{\"created_at\":\"$(iso 999999)\"}]}"
run --json --repo o/r
eq "D queued" 2 "$(jq_ 'd["ci"]["queued"]')"
eq "D stuck" 1 "$(jq_ 'd["ci"]["stuck"]')"
o=$(jq_ 'd["ci"]["oldest_secs"]'); [ "$o" -ge 600 ] && [ "$o" -lt 700 ] && ok || fail "D oldest ≈600, got $o"
rm -f "$WORK/gh/repos_o_r_actions_runs_status_queued_per_page_100"
run --json --repo o/r
eq "D unreadable is null" '{"oldest_secs": null, "queued": null, "stuck": null}' "$(jq_ 'd["ci"]')"

# ---- E. quota -----------------------------------------------------------------
for w in blind stale never; do
  QCMD="printf '$w\t10\t3\n'" run --json --repo o/r
  eq "E $w ⇒ blind" '{"pct": null, "state": "blind", "watch": "'"$w"'"}' "$(jq_ 'd["quota"]')"
done
: > "$QROWS"
QCMD="printf 'fresh\t10\t0\n'" run --json --repo o/r
eq "E fresh, no rows ⇒ blind" '"blind"' "$(jq_ 'd["quota"]["state"]')"
printf 'a\t90\t50\t10\t0\t0\t1\nb\t20\t30\t70\t0\t0\t1\n' > "$QROWS"
QCMD="printf 'fresh\t10\t0\n'" run --json --repo o/r
eq "E fresh ⇒ best headroom" '{"pct": 70, "state": "ok", "watch": "fresh"}' "$(jq_ 'd["quota"]')"
QCMD="printf 'off\t0\t0\n'" run --json --repo o/r
eq "E off" '"off"' "$(jq_ 'd["quota"]["state"]')"

# ---- F. read-only + usage -----------------------------------------------------
run --json --repo o/r
eq "F only gh api" 0 "$(grep -cv '^api --paginate repos/' "$FSC_GH_LOG")"
run --bogus; eq "F usage rc" 2 "$RC"
run --json; eq "F no repo rc" 3 "$RC"

# ---- G. text mode -------------------------------------------------------------
QCMD="printf 'blind\t10\t3\n'" FLEET_UI_LANG=zh run --repo o/r
has "G zh blind" "$OUT" '额度读不到（blind）'
has "G zh overlap" "$OUT" '撞车 o/r:x.go · #51 #52 · 建议先合 #51'
has "G zh ci" "$OUT" '测试排队读不到'

printf 'fleet-steward-conflicts-selftest: %d passed\n' "$pass"
