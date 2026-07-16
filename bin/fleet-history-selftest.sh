#!/bin/bash
# fleet-history-selftest.sh — hermetic tests for bin/fleet-history.sh, the
# landed-session history ledger (#130).
#
# Covers the parts with real logic (not the gh/git-touching resume exec):
#   A. record — derives transcript-dir + session-id (newest *.jsonl) from the
#      worktree path, writes a well-formed 10-column TSV row (the 10th is `state`,
#      #320), and sanitizes TAB/newline out of free-text fields so a row can never
#      break layout.
#   A2. record-closed (#320) — a landed-less closed-unlanded row: idempotent (no
#      duplicate), never shadows a landed row for the same session, skips a window
#      with no transcript.
#   B. list / find_row — newest-first ordering and lookup by issue# and by #PR.
#   C. resume — verdict routing: RESUME when a transcript exists, FROM-PR when
#      only a PR is recorded, REVIEW-ONLY when neither (and for an unknown key);
#      plus reuse-if-present (#319): a worktree already on disk is REUSED (no
#      `git worktree add`), an absent one is reconstructed off the SHA.
#   D. rows — the dash landed view emits a header + a row whose field1 target
#      encodes the PR (or issue when PR-less).
#   E. meta — "<issue>\t<title>" for a landed row, by issue# and by #PR (#319).
#   F. state glyph (#320) — list/rows mark a landed row ✓, a closed-unlanded ✗.
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
# exactly 10 tab-separated columns (count tabs = 9) — the 10th is `state` (#320)
tabs=$(printf '%s' "$row" | tr -cd '\t' | wc -c | tr -d ' ')
eq "record: row has 10 columns (9 tabs)" "9" "$tabs"

IFS=$'\t' read -r c_when c_iss _ c_pr c_sha c_wt c_td c_sid c_smry c_state <<<"$row"
eq "record: issue col"            "9"      "$c_iss"
eq "record: pr degrades to dash"  "-"      "$c_pr"
eq "record: sha degrades to dash" "-"      "$c_sha"
eq "record: worktree col"         "$WT"    "$c_wt"
eq "record: transcript-dir col"   "$TDIR"  "$c_td"
eq "record: newest session id"    "new-session-2222" "$c_sid"
eq "record: summary tab/nl flattened to spaces" "fixed the thing" "$c_smry"
eq "record: state column is 'landed'" "landed" "$c_state"
# mergedAt auto-stamped (non-empty, dash-free ISO-ish) when not provided
case "$c_when" in ''|-) fail "record: mergedAt should auto-stamp, got [$c_when]";; esac
CHECKS=$((CHECKS + 1))

# --win path: pull the summary from the dash cache when --summary is absent.
# Keyed by <session>_<id> (issue #208), so --session is required to resolve it.
# Each record below uses its OWN worktree — as issue-<N> worktrees really are
# distinct — because landed `record` is now idempotent on the session/transcript
# key (#384): reusing issue-9's worktree here would dedup these rows away (the same
# session already recorded) instead of appending the fresh rows these checks need.
DC="$TMPDIR/.claude-dash/global"; mkdir -p "$DC"   # summary_<sess>_<id> lives in global/ (#181/#208)
WT10="/w/repo_v1.2/.claude-worktrees/issue-10"
ENC10=$(printf '%s' "$WT10" | LC_ALL=C tr -c 'A-Za-z0-9' '-')
mkdir -p "$CLAUDE_PROJECTS_DIR/$ENC10"; : > "$CLAUDE_PROJECTS_DIR/$ENC10/sess-10.jsonl"
printf 'summary from the dash cache\n' > "$DC/summary_fleetA_77"
run record --issue 10 --worktree "$WT10" --win '@77' --session fleetA >/dev/null
last=$(tail -n1 "$FLEET_HISTORY_LEDGER"); smry_col=$(printf '%s' "$last" | awk -F'\t' '{print $9}')
eq "record: --win pulls summary from dash cache" "summary from the dash cache" "$smry_col"

# Cross-fleet isolation (issue #208): a DIFFERENT fleet's window @77 must NOT
# render this fleet's row. fleetB's @77 has its own key; recording fleetB/@77
# pulls fleetB's summary, never fleetA's.
WT11="/w/repo_v1.2/.claude-worktrees/issue-11"
ENC11=$(printf '%s' "$WT11" | LC_ALL=C tr -c 'A-Za-z0-9' '-')
mkdir -p "$CLAUDE_PROJECTS_DIR/$ENC11"; : > "$CLAUDE_PROJECTS_DIR/$ENC11/sess-11.jsonl"
printf 'summary belonging to fleetB\n' > "$DC/summary_fleetB_77"
run record --issue 11 --worktree "$WT11" --win '@77' --session fleetB >/dev/null
last=$(tail -n1 "$FLEET_HISTORY_LEDGER"); smry_col=$(printf '%s' "$last" | awk -F'\t' '{print $9}')
eq "record: cross-fleet @77 pulls its OWN summary, not fleetA's" "summary belonging to fleetB" "$smry_col"

# landed record is IDEMPOTENT (#384): record-before-remove now runs from TWO
# reapers (fleet-cleanup.sh AND worktree-autoclean.sh, both via fleet_reap_record),
# so recording the SAME session twice — or one reaper retrying after a failed
# worktree remove — must NOT append a second row. Re-record issue 9 (same worktree
# → same transcript/session) and assert the row count is unchanged + the skip noted.
before_dup=$(wc -l < "$FLEET_HISTORY_LEDGER" | tr -d ' ')
outdup=$(run record --issue 9 --worktree "$WT" --summary "second write, same session")
after_dup=$(wc -l < "$FLEET_HISTORY_LEDGER" | tr -d ' ')
contains "record: idempotent re-record is reported as skipped" "$outdup" "already in ledger"
eq "record: idempotent (#384) — same session writes no duplicate landed row" "$before_dup" "$after_dup"

# ============================================================================
# A2. record-closed — landed-less closed-unlanded row (idempotent, no-shadow) #320
# ============================================================================
: > "$FLEET_HISTORY_LEDGER"
WTC="$WORK/wtc/issue-42"; mkdir -p "$WTC"
ENCC=$(printf '%s' "$WTC" | LC_ALL=C tr -c 'A-Za-z0-9' '-')
mkdir -p "$CLAUDE_PROJECTS_DIR/$ENCC"; : > "$CLAUDE_PROJECTS_DIR/$ENCC/sess-c-42.jsonl"

outc=$(run record-closed --repo o/r --issue 42 --worktree "$WTC" --title "fix-widget" --summary "poking the widget")
contains "record-closed: reports the closed-unlanded record" "$outc" "closed-unlanded #42"
rowc=$(cat "$FLEET_HISTORY_LEDGER")
tabsc=$(printf '%s' "$rowc" | tr -cd '\t' | wc -c | tr -d ' ')
eq "record-closed: row has 10 columns (9 tabs)" "9" "$tabsc"
IFS=$'\t' read -r cc_when cc_iss _ cc_pr cc_sha cc_wt _ cc_sid cc_smry cc_state <<<"$rowc"
eq "record-closed: issue col"       "42"                "$cc_iss"
eq "record-closed: no pr (dash)"    "-"                 "$cc_pr"
eq "record-closed: no sha (dash)"   "-"                 "$cc_sha"
eq "record-closed: worktree col"    "$WTC"              "$cc_wt"
eq "record-closed: session id"      "sess-c-42"         "$cc_sid"
eq "record-closed: summary col"     "poking the widget" "$cc_smry"
eq "record-closed: state marker"    "closed-unlanded"   "$cc_state"
case "$cc_when" in ''|-) fail "record-closed: closedAt should auto-stamp, got [$cc_when]";; esac
CHECKS=$((CHECKS + 1))

# idempotent: a second record-closed for the same session adds NO new row.
run record-closed --repo o/r --issue 42 --worktree "$WTC" >/dev/null
eq "record-closed: idempotent (no duplicate row)" "1" "$(wc -l < "$FLEET_HISTORY_LEDGER" | tr -d ' ')"

# no-shadow: a LANDED row already present for this session → record-closed skips
# (dedup on session-id keeps a merged session from getting a second, closed row).
: > "$FLEET_HISTORY_LEDGER"
run record --repo o/r --issue 42 --worktree "$WTC" --summary "landed the widget" >/dev/null
outs=$(run record-closed --repo o/r --issue 42 --worktree "$WTC")
contains "record-closed: skips when a landed row exists" "$outs" "already in ledger"
eq "record-closed: landed row not shadowed (still 1 row)" "1" "$(wc -l < "$FLEET_HISTORY_LEDGER" | tr -d ' ')"

# no transcript → nothing to index/resume → skip (no row written), not an error.
: > "$FLEET_HISTORY_LEDGER"
WTN="$WORK/wtn/issue-77"; mkdir -p "$WTN"
outn=$(run record-closed --repo o/r --issue 77 --worktree "$WTN")
contains "record-closed: no transcript → skipped" "$outn" "no transcript"
eq "record-closed: no-transcript writes no row" "0" "$(wc -l < "$FLEET_HISTORY_LEDGER" | tr -d ' ')"

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

# ---- reuse-if-present (issue #319): present worktree skips `git worktree add` ----
# A git PATH-shim logs every git call and fakes `worktree add <path>` by creating
# <path>, so we can assert exactly WHEN a reconstruct (add) fires under --exec.
mkdir -p "$WORK/gitbin"
cat > "$WORK/gitbin/git" <<'GITSHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GIT_LOG"
[ "${1:-}" = "-C" ] && shift 2          # drop a leading `-C <dir>`
if [ "${1:-}" = "worktree" ] && [ "${2:-}" = "add" ]; then
  mkdir -p "$3" 2>/dev/null             # fake the checkout so [ -d "$wt" ] passes downstream
fi
exit 0
GITSHIM
chmod +x "$WORK/gitbin/git"
GIT_LOG="$WORK/gitlog"
FAKEMAIN="$WORK/fakemain"; mkdir -p "$FAKEMAIN"

: > "$FLEET_HISTORY_LEDGER"
# Row 900: worktree ALREADY on disk → reuse, must NOT run `git worktree add`.
WTP="$WORK/wt-present"; mkdir -p "$WTP"
mkdir -p "$WORK/projects/tdirP"; : > "$WORK/projects/tdirP/sid-p.jsonl"
printf '2026-02-01T00:00:00Z\t900\tt900\t-\tSHAP\t%s\t%s\tsid-p\t-\n' \
  "$WTP" "$WORK/projects/tdirP" >> "$FLEET_HISTORY_LEDGER"
# Row 901: worktree ABSENT but SHA+main present → reconstruct via `git worktree add`.
WTA="$WORK/gone/wt-absent"
mkdir -p "$WORK/projects/tdirA"; : > "$WORK/projects/tdirA/sid-a.jsonl"
printf '2026-02-02T00:00:00Z\t901\tt901\t-\tSHAA\t%s\t%s\tsid-a\t-\n' \
  "$WTA" "$WORK/projects/tdirA" >> "$FLEET_HISTORY_LEDGER"

: > "$GIT_LOG"
vP=$(PATH="$WORK/gitbin:$PATH" GIT_LOG="$GIT_LOG" run resume --exec --main "$FAKEMAIN" 900)
contains "resume: present worktree → RESUME"              "$vP" "RESUME"
contains "resume: present worktree → RESUME points at it" "$vP" "$WTP"
case "$(cat "$GIT_LOG")" in *"worktree add"*) fail "resume(#319): present worktree must NOT run git worktree add";; esac
CHECKS=$((CHECKS + 1))

: > "$GIT_LOG"
vA=$(PATH="$WORK/gitbin:$PATH" GIT_LOG="$GIT_LOG" run resume --exec --main "$FAKEMAIN" 901)
contains "resume: absent worktree → still RESUME (reconstructed)" "$vA" "RESUME"
contains "resume(#319): absent worktree reconstructs via git worktree add" \
  "$(cat "$GIT_LOG")" "worktree add $WTA SHAA"

# ============================================================================
# D. rows — dash landed view
# ============================================================================
# Self-contained ledger (one PR-bearing row: issue 5 / PR 70 / sid-abc) so this
# section doesn't hinge on leftover state from the resume tests above.
: > "$FLEET_HISTORY_LEDGER"
printf '2026-01-01T00:00:00Z\t5\ttitle5\t70\tSHA5\t/w/issue-5\t/nope\tsid-abc\t-\n' >> "$FLEET_HISTORY_LEDGER"
rows=$(run rows)
# The landed view now shares the live list's column header (issue · window ·
# summary · act · PR · ctx) so the two read as one table (issue #228).
contains "rows: emits the unified column header (window)"  "$rows" "window"
contains "rows: emits the unified column header (summary)" "$rows" "summary"
contains "rows: emits the last-activity column header"     "$rows" "act"
contains "rows: PR-bearing row targets landed:<pr>" "$rows" "landed:70"
# field2 still carries the session id (used by the resume/restore path).
contains "rows: PR-bearing row carries its session id in field2" "$rows" "sid-abc"
# a PR-less row targets landed:issue:<n>
: > "$FLEET_HISTORY_LEDGER"
printf '2026-01-01T00:00:00Z\t8\tt8\t-\t-\t/w/issue-8\t/nope\t-\t-\n' >> "$FLEET_HISTORY_LEDGER"
rows2=$(run rows)
contains "rows: PR-less row targets landed:issue:<n>" "$rows2" "landed:issue:8"

# empty ledger → a friendly placeholder row, never a crash.
: > "$FLEET_HISTORY_LEDGER"
rows3=$(run rows)
contains "rows: empty ledger yields a placeholder" "$rows3" "no landed sessions"

# ============================================================================
# E. meta — "<issue>\t<title>" for a landed row (faithful resume naming, #319)
# ============================================================================
: > "$FLEET_HISTORY_LEDGER"
printf '2026-03-01T00:00:00Z\t42\tPolish the dash\t61\tabc1234\t-\t-\tsid-m\t-\n' >> "$FLEET_HISTORY_LEDGER"
m=$(run meta 42)
eq "meta: issue column by issue key" "42"              "$(printf '%s' "$m" | cut -f1)"
eq "meta: title column by issue key" "Polish the dash" "$(printf '%s' "$m" | cut -f2)"
# by #PR the row still resolves to its issue + title (a #PR resume binds @issue).
eq "meta: #PR key resolves to the row's issue" "42" "$(run meta '#61' | cut -f1)"
# unknown key → nothing (no crash, no stray row).
eq "meta: unknown key prints nothing" "" "$(run meta 999)"

# ============================================================================
# F. state glyph (#320): a landed row lists/renders ✓, a closed-unlanded row ✗. A
# legacy pre-#320 row (9 cols, no state) is treated as landed (✓) — see section D above.
# ============================================================================
: > "$FLEET_HISTORY_LEDGER"
printf '2026-01-01T00:00:00Z\t8\tt8\t-\t-\t/w/issue-8\t/nope\tsid-8\t-\tclosed-unlanded\n' >> "$FLEET_HISTORY_LEDGER"
printf '2026-01-02T00:00:00Z\t9\tt9\t63\tabc1234\t-\t-\tsid-9\t-\tlanded\n'                 >> "$FLEET_HISTORY_LEDGER"
lst=$(run list)
contains "list: closed-unlanded row shows the ✗ marker" "$lst" "✗ #8"
contains "list: landed row shows the ✓ marker"          "$lst" "✓ #9"
rws=$(run rows)
contains "rows: closed-unlanded row carries the ✗ glyph" "$rws" "✗"

printf 'selftest OK: fleet-history (%s assertions — record/record-closed/list/find/resume/reuse/meta/rows/state)\n' "$CHECKS"
