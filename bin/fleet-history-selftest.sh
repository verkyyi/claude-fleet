#!/bin/bash
# fleet-history-selftest.sh — hermetic tests for bin/fleet-history.sh, the
# landed-session history ledger (#130).
#
# Covers the parts with real logic (not the gh/git-touching resume exec):
#   A. record — derives transcript-dir + session-id (newest *.jsonl) from the
#      worktree path, writes a well-formed 9-column TSV row, and sanitizes
#      TAB/newline out of free-text fields so a row can never break layout.
#   B. list / find_row — newest-first ordering and lookup by issue# and by #PR.
#   C. resume — verdict routing: RESUME when a transcript exists, FROM-PR when
#      only a PR is recorded, REVIEW-ONLY when neither (and for an unknown key).
#   D. rows — the dash landed view emits a header + a row whose field1 target
#      encodes the PR (or issue when PR-less).
#
# Fully hermetic: no gh, no git, no tmux, no network. FLEET_HISTORY_LEDGER points
# the ledger at a scratch file; CLAUDE_PROJECTS_DIR points the transcript lookup
# at a fake tree; TMPDIR scopes the summary cache. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
H="$BIN/fleet-history.sh"
[ -f "$H" ] || { printf 'selftest: %s not found\n' "$H" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-history-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

export FLEET_HISTORY_LEDGER="$WORK/landed.tsv"
export CLAUDE_PROJECTS_DIR="$WORK/projects"
export TMPDIR="$WORK"                       # so the dash summary cache lands under $WORK
mkdir -p "$CLAUDE_PROJECTS_DIR"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — [$2] does not contain [$3]";; esac; }

run() { bash "$H" "$@"; }

# ============================================================================
# A. record — transcript-dir + session-id derivation, TSV shape, sanitization
# ============================================================================
# Fake transcript tree for a worktree whose path contains a DOT and an UNDERSCORE
# (e.g. a dotted worktrees dir / versioned dir) — a REGRESSION GUARD that record
# encodes the cwd the way Claude Code actually does (every non-alnum byte → '-',
# not just '/'). Encode expectation with the same rule the fix uses. Two sessions;
# the NEWER mtime must win.
WT="/w/repo_v1.2/.claude-worktrees/issue-9"
ENC=$(printf '%s' "$WT" | LC_ALL=C tr -c 'A-Za-z0-9' '-')
case "$ENC" in *.*|*_*|*/*) fail "encoding: dot/underscore/slash not collapsed → [$ENC]";; esac
CHECKS=$((CHECKS + 1))
TDIR="$CLAUDE_PROJECTS_DIR/$ENC"
mkdir -p "$TDIR"
: > "$TDIR/old-session-1111.jsonl";  touch -t 200001010000 "$TDIR/old-session-1111.jsonl"
: > "$TDIR/new-session-2222.jsonl";  touch -t 203001010000 "$TDIR/new-session-2222.jsonl"

# record with no --pr (no gh needed): title/pr/sha degrade to '-', summary explicit.
# The title carries a TAB and newline to prove sanitization collapses them.
out=$(run record --issue 9 --worktree "$WT" \
        --summary "$(printf 'fixed\tthe\nthing')")
contains "record: reports the session it captured" "$out" "new-session-2222"

row=$(cat "$FLEET_HISTORY_LEDGER")
# exactly 9 tab-separated columns (count tabs = 8)
tabs=$(printf '%s' "$row" | tr -cd '\t' | wc -c | tr -d ' ')
eq "record: row has 9 columns (8 tabs)" "8" "$tabs"

IFS=$'\t' read -r c_when c_iss _ c_pr c_sha c_wt c_td c_sid c_smry <<<"$row"
eq "record: issue col"            "9"      "$c_iss"
eq "record: pr degrades to dash"  "-"      "$c_pr"
eq "record: sha degrades to dash" "-"      "$c_sha"
eq "record: worktree col"         "$WT"    "$c_wt"
eq "record: transcript-dir col"   "$TDIR"  "$c_td"
eq "record: newest session id"    "new-session-2222" "$c_sid"
eq "record: summary tab/nl flattened to spaces" "fixed the thing" "$c_smry"
# mergedAt auto-stamped (non-empty, dash-free ISO-ish) when not provided
case "$c_when" in ''|-) fail "record: mergedAt should auto-stamp, got [$c_when]";; esac
CHECKS=$((CHECKS + 1))

# --win path: pull the summary from the dash cache when --summary is absent.
DC="$TMPDIR/.claude-dash/global"; mkdir -p "$DC"   # summary_<id> lives in global/ (issue #181)
printf 'summary from the dash cache\n' > "$DC/summary_77"
run record --issue 10 --worktree "$WT" --win '@77' >/dev/null
last=$(tail -n1 "$FLEET_HISTORY_LEDGER"); smry_col=$(printf '%s' "$last" | awk -F'\t' '{print $9}')
eq "record: --win pulls summary from dash cache" "summary from the dash cache" "$smry_col"

# ============================================================================
# B. list / find_row — newest-first + lookup by issue and by #PR
# ============================================================================
# Fresh ledger with 3 rows; append order is oldest→newest, list must reverse.
: > "$FLEET_HISTORY_LEDGER"
printf '2026-01-01T00:00:00Z\t100\tfirst\t61\tabc1234\t-\t-\t-\t-\n'  >> "$FLEET_HISTORY_LEDGER"
printf '2026-01-02T00:00:00Z\t200\tsecond\t62\tdef5678\t-\t-\tsess-2\tsum2\n' >> "$FLEET_HISTORY_LEDGER"
printf '2026-01-03T00:00:00Z\t300\tthird\t63\t9abcdef\t-\t-\t-\t-\n'  >> "$FLEET_HISTORY_LEDGER"

listing=$(run list)
first_line=$(printf '%s\n' "$listing" | head -n1)
contains "list: newest row (#300) is first" "$first_line" "#300"
contains "list: shows short sha (7 chars)" "$listing" "9abcdef"

# filter narrows to matching rows only
filtered=$(run list second)
contains "list: filter keeps the match" "$filtered" "#200"
case "$filtered" in *'#100'*) fail "list: filter should drop non-matches (#100 leaked)";; esac
CHECKS=$((CHECKS + 1))

# ============================================================================
# C. resume — verdict routing
# ============================================================================
: > "$FLEET_HISTORY_LEDGER"
# Row 5: transcript on disk AND worktree already on disk → RESUME by session id
# (no recreate needed, so no git/--main required).
WT5="$WORK/wt5"; mkdir -p "$WT5"
mkdir -p "$WORK/projects/tdir5"; : > "$WORK/projects/tdir5/sid-abc.jsonl"
printf '2026-01-01T00:00:00Z\t5\ttitle5\t70\tSHA5\t%s\t%s\tsid-abc\t-\n' \
  "$WT5" "$WORK/projects/tdir5" >> "$FLEET_HISTORY_LEDGER"
# Row 55: transcript on disk but worktree GONE and sha='-' (unrecreatable) with a
# PR → must degrade to FROM-PR, NOT falsely claim RESUME. REGRESSION GUARD for the
# "RESUME points at a never-recreated worktree" bug.
mkdir -p "$WORK/projects/tdir55"; : > "$WORK/projects/tdir55/sid-x.jsonl"
printf '2026-01-02T00:00:00Z\t55\ttitle55\t80\t-\t/gone/issue-55\t%s\tsid-x\t-\n' \
  "$WORK/projects/tdir55" >> "$FLEET_HISTORY_LEDGER"
# Row 56: same, transcript present but unrecreatable AND no PR → REVIEW-ONLY.
mkdir -p "$WORK/projects/tdir56"; : > "$WORK/projects/tdir56/sid-y.jsonl"
printf '2026-01-03T00:00:00Z\t56\ttitle56\t-\t-\t/gone/issue-56\t%s\tsid-y\t-\n' \
  "$WORK/projects/tdir56" >> "$FLEET_HISTORY_LEDGER"
# Row 6: a PR but NO transcript → FROM-PR.
printf '2026-01-04T00:00:00Z\t6\ttitle6\t71\tSHA6\t/w/issue-6\t/nope\t-\t-\n' >> "$FLEET_HISTORY_LEDGER"
# Row 7: neither transcript nor PR → REVIEW-ONLY.
printf '2026-01-05T00:00:00Z\t7\ttitle7\t-\t-\t/w/issue-7\t/nope\t-\t-\n' >> "$FLEET_HISTORY_LEDGER"

v5=$(run resume 5);   contains "resume: worktree on disk → RESUME"          "$v5" "RESUME"
contains "resume: RESUME carries the session id"                            "$v5" "sid-abc"
contains "resume: RESUME points at the real worktree"                       "$v5" "$WT5"
v55=$(run resume 55); contains "resume: transcript but unrecreatable+PR → FROM-PR (not RESUME)" "$v55" "FROM-PR"
case "$v55" in *RESUME*) fail "resume: must NOT claim RESUME when the worktree can't be re-established (#130 review)";; esac
CHECKS=$((CHECKS + 1))
v56=$(run resume 56); contains "resume: transcript but unrecreatable, no PR → REVIEW-ONLY" "$v56" "REVIEW-ONLY"
case "$v56" in *RESUME*) fail "resume: REVIEW-ONLY row must not carry a RESUME verdict";; esac
CHECKS=$((CHECKS + 1))
v6=$(run resume 6);   contains "resume: no transcript, has PR → FROM-PR"    "$v6" "FROM-PR"
contains "resume: FROM-PR carries the PR number"                           "$v6" "71"
v7=$(run resume 7);   contains "resume: neither → REVIEW-ONLY"             "$v7" "REVIEW-ONLY"
vx=$(run resume 999); contains "resume: unknown key → REVIEW-ONLY"        "$vx" "REVIEW-ONLY"

# find_row by #PR (not issue): #70 → the issue-5 row.
vpr=$(run resume '#70'); contains "resume: lookup by #PR resolves the right row" "$vpr" "sid-abc"

# ============================================================================
# D. rows — dash landed view
# ============================================================================
rows=$(run rows)
contains "rows: emits a pinned header line" "$rows" "landed sessions"
contains "rows: PR-bearing row targets landed:<pr>" "$rows" "landed:70"
# a PR-less row targets landed:issue:<n>
: > "$FLEET_HISTORY_LEDGER"
printf '2026-01-01T00:00:00Z\t8\tt8\t-\t-\t/w/issue-8\t/nope\t-\t-\n' >> "$FLEET_HISTORY_LEDGER"
rows2=$(run rows)
contains "rows: PR-less row targets landed:issue:<n>" "$rows2" "landed:issue:8"

# empty ledger → a friendly placeholder row, never a crash.
: > "$FLEET_HISTORY_LEDGER"
rows3=$(run rows)
contains "rows: empty ledger yields a placeholder" "$rows3" "no landed sessions"

printf 'selftest OK: fleet-history (%s assertions — record/list/find/resume/rows)\n' "$CHECKS"
