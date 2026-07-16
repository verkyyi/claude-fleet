#!/bin/bash
# worktree-autoclean-history-selftest.sh — hermetic tests for RECORD-BEFORE-REMOVE
# in the worktree janitor (issue #384). History rows used to be written ONLY by the
# cleanup daemon (landed) and ledger-watch (closed-unlanded), so with FLEET_CLEANUP=0
# and ledger-watch unloaded, worktree-autoclean.sh reaped merged workers that then
# vanished from /fleet-history. The fix: autoclean now writes the row ITSELF, before
# it removes the worktree, via the shared fleet_reap_record helper (also driven by
# fleet-cleanup.sh). This test drives the REAL script + helper end to end and asserts:
#
#   * a merged-PR reap        → a `landed` row (PR resolved from the branch) BEFORE removal
#   * a clean-ancestor reap   → a `closed-unlanded` row (indexed/resumable)
#   * both worktrees + branches are actually reaped after the rows are written
#   * fleet_reap_record is idempotent — TWO calls for one reap (as BOTH reapers
#     would, racing) write ONE row, and the merged path resolves the branch's PR
#
# No network / no tmux server / no real GitHub: the real script + fleet-lib.sh +
# fleet-history.sh are symlinked into a temp bin (so $BIN/../fleet.conf can't leak
# the real fleet, and fleet_reap_record resolves fleet-history.sh beside the lib),
# a per-fleet conf drives fleet_sockets, and fake `tmux`/`gh` stand in. A REAL local
# git repo provides the worktrees; FLEET_HISTORY_LEDGER + CLAUDE_PROJECTS_DIR scope
# the ledger + transcript lookups to $WORK.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/worktree-autoclean.sh"
LIB="$BIN/fleet-lib.sh"
HIST="$BIN/fleet-history.sh"
for f in "$SRC" "$LIB" "$HIST"; do [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }; done
command -v git >/dev/null 2>&1 || { echo "selftest: git absent — SKIP" >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wac-history.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
# Physical path (macOS /var → /private/var) so the paths git reports match the ones
# we encode into transcript-dir names.
WORK="$(cd "$WORK" && pwd -P)"

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

# worktree path → transcript-dir under CLAUDE_PROJECTS_DIR, encoded the way Claude
# Code (and fleet-history.sh) do: every non-alnum byte → '-'.
enc() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9' '-'; }

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf" "$WORK/logs" "$WORK/projects"
ln -s "$SRC"  "$WORK/bin/worktree-autoclean.sh"
ln -s "$LIB"  "$WORK/bin/fleet-lib.sh"
ln -s "$HIST" "$WORK/bin/fleet-history.sh"     # fleet_reap_record resolves this beside the lib

LEDGER="$WORK/landed.tsv"; : > "$LEDGER"
PROJECTS="$WORK/projects"

# --- build a real base checkout + two issue worktrees -------------------------
BASE="$WORK/base"
git init -q "$BASE"
git -C "$BASE" config user.email t@t; git -C "$BASE" config user.name t
printf 'seed\n' > "$BASE/f"; git -C "$BASE" add f; git -C "$BASE" commit -qm seed
BASE_BR="$(git -C "$BASE" branch --show-current)"

# issue-500: a DIVERGENT commit (so it is NOT an ancestor of base) but its branch
# is in the fake merged-PR list → reaped via the MERGED-PR path → a `landed` row.
WT500="$WORK/wt-500"
git -C "$BASE" worktree add -q -b issue-500 "$WT500" >/dev/null 2>&1
printf 'work\n' > "$WT500/g"; git -C "$WT500" add g; git -C "$WT500" commit -qm 'issue-500 work'
# issue-600: clean, sits at base HEAD → ancestor, NOT in the merged list → reaped
# via the ANCESTOR path → a `closed-unlanded` row.
WT600="$WORK/wt-600"
git -C "$BASE" worktree add -q -b issue-600 "$WT600" >/dev/null 2>&1

# Surviving transcripts (outside the worktree, under CLAUDE_PROJECTS_DIR) so both
# record paths resolve a session id (record-closed SKIPS a branch with no transcript).
mkdir -p "$PROJECTS/$(enc "$WT500")"; : > "$PROJECTS/$(enc "$WT500")/sess-500.jsonl"
mkdir -p "$PROJECTS/$(enc "$WT600")"; : > "$PROJECTS/$(enc "$WT600")/sess-600.jsonl"

# --- fake tmux: a live socket, but NO live pane binds either issue → both reaped -
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
[ "$1" = -L ] && shift 2
cmd="$1"; shift 2>/dev/null || true
case "$cmd" in
  has-session) exit 0 ;;
  list-panes) : ;;                # no @issue and no pane_current_path → nothing live
  display-message) : ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/tmux"

# --- fake gh: merged list = issue-500; branch→PR resolution = 5500; issues OPEN ---
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
case "$*" in
  *"pr list"*"--head"*) printf '5500\n' ;;   # fleet_reap_record resolves the branch's merged PR
  *"pr list"*)          printf 'issue-500\n' ;;   # clean_fleet MERGED_PRS (merged head-refs)
  *"issue view"*)       printf 'OPEN\n' ;;
  *"issue close"*)      : ;;
  *) : ;;
esac
exit 0
GHFAKE
chmod +x "$WORK/fakebin/gh"

# --- a per-fleet conf so fleet_sockets yields a socket ------------------------
cat > "$WORK/conf/sess1.conf" <<EOF
FLEET_MAIN="$BASE"
FLEET_REPO="fake/repo"
FLEET_BASE_BRANCH="$BASE_BR"
FLEET_PROTECTED_RE='^(master|main|develop|test)\$'
EOF

run_wac() {   # run worktree-autoclean.sh with the fakes + scoped ledger/projects
  PATH="$WORK/fakebin:$PATH" FLEET_CONF_DIR="$WORK/conf" TMPDIR="$WORK" \
    FLEET_HISTORY_LEDGER="$LEDGER" CLAUDE_PROJECTS_DIR="$PROJECTS" \
    bash "$WORK/bin/worktree-autoclean.sh" "$@" 2>"$WORK/err"
}

# ================= PART 0: dry-run previews only — writes NO row ===============
# The record step sits PAST the DRY gate, so a --dry-run must preview decisions
# without writing a history row or removing anything (a row on a dry sweep would
# be a phantom landed session).
run_wac --dry-run >/dev/null
[ -s "$LEDGER" ] && fail "dry-run must not write any history row" "$(cat "$LEDGER")"
[ -d "$WT500" ] || fail "dry-run must not remove the issue-500 worktree"
[ -d "$WT600" ] || fail "dry-run must not remove the issue-600 worktree"
ok "dry-run previews only — no history row written, no worktree removed"

# ================= PART 1: real reap writes the row, THEN removes ==============
run_wac >/dev/null

# merged-PR reap → a landed row for #500 carrying the resolved PR (5500) + session id.
land_row=$(awk -F'\t' '$2==500 && $10=="landed"' "$LEDGER")
[ -n "$land_row" ] || fail "merged-PR reap must leave a 'landed' row for #500" "$(cat "$LEDGER")"
lp=$(printf '%s' "$land_row" | awk -F'\t' '{print $4}')
[ "$lp" = 5500 ] || fail "landed #500 row must carry the branch's resolved PR 5500 (got [$lp])" "$land_row"
ls=$(printf '%s' "$land_row" | awk -F'\t' '{print $8}')
[ "$ls" = sess-500 ] || fail "landed #500 row must carry the surviving session id (got [$ls])" "$land_row"
ok "merged-PR reap → landed row for #500 (PR resolved from branch, session indexed)"

# ancestor reap → a closed-unlanded row for #600 (indexed/resumable, no PR/sha).
cu_row=$(awk -F'\t' '$2==600 && $10=="closed-unlanded"' "$LEDGER")
[ -n "$cu_row" ] || fail "clean-ancestor reap must leave a 'closed-unlanded' row for #600" "$(cat "$LEDGER")"
cp=$(printf '%s' "$cu_row" | awk -F'\t' '{print $4}')
[ "$cp" = "-" ] || fail "closed-unlanded #600 row must have no PR (got [$cp])" "$cu_row"
ok "clean-ancestor reap → closed-unlanded row for #600 (indexed, no PR)"

# the rows were written BEFORE removal: both worktrees + branches are now gone.
[ -d "$WT500" ] && fail "issue-500 worktree must be reaped after its row is recorded"
[ -d "$WT600" ] && fail "issue-600 worktree must be reaped after its row is recorded"
git -C "$BASE" show-ref --verify -q refs/heads/issue-500 && fail "issue-500 branch should be deleted"
git -C "$BASE" show-ref --verify -q refs/heads/issue-600 && fail "issue-600 branch should be deleted"
ok "both worktrees + branches reaped (record ran BEFORE remove)"

# ================= PART 2: fleet_reap_record is idempotent =====================
# BOTH reapers (fleet-cleanup.sh + worktree-autoclean.sh) can record the SAME reap
# if they race — the helper drives record, which dedups on the session key, so two
# calls for one worktree must write exactly ONE landed row (no double-recording).
export PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK"
export FLEET_HISTORY_LEDGER="$WORK/landed2.tsv"; : > "$FLEET_HISTORY_LEDGER"
export CLAUDE_PROJECTS_DIR="$PROJECTS"
# shellcheck source=/dev/null
. "$WORK/bin/fleet-lib.sh"                    # BASH_SOURCE → $WORK/bin → resolves fleet-history.sh here
WT700="$WORK/wt-700"; mkdir -p "$WT700"      # kept on disk so both calls see the same worktree
mkdir -p "$PROJECTS/$(enc "$WT700")"; : > "$PROJECTS/$(enc "$WT700")/sess-700.jsonl"
fleet_reap_record "merged-PR" "fake/repo" "$BASE" 700 "$WT700" "" "" "" "issue-700"
fleet_reap_record "merged-PR" "fake/repo" "$BASE" 700 "$WT700" "" "" "" "issue-700"
n=$(wc -l < "$FLEET_HISTORY_LEDGER" | tr -d ' ')
[ "$n" = 1 ] || fail "fleet_reap_record: two calls for one reap must write ONE landed row (got $n)" "$(cat "$FLEET_HISTORY_LEDGER")"
prc=$(awk -F'\t' '$2==700{print $4}' "$FLEET_HISTORY_LEDGER")
[ "$prc" = 5500 ] || fail "fleet_reap_record: merged path must resolve the branch's PR (got [$prc])"
# an empty issue (e.g. a scratch-<N> worktree) is a clean no-op — writes nothing.
fleet_reap_record "merged-PR" "fake/repo" "$BASE" "" "$WT700" "" "" "" "scratch-9"
n2=$(wc -l < "$FLEET_HISTORY_LEDGER" | tr -d ' ')
[ "$n2" = 1 ] || fail "fleet_reap_record: empty issue must record nothing (got $n2 rows)"
ok "fleet_reap_record: merged path resolves the PR, is idempotent, no-ops on empty issue"

printf '\nselftest OK: %s assertions passed (worktree-autoclean record-before-remove, #384)\n' "$pass"
exit 0
