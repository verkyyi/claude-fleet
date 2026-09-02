#!/bin/bash
# fleet-bind-selftest.sh — hermetic tests for bin/fleet-bind.sh (issue #520): the
# IN-PLACE promotion of a scratch window into the worker for a GitHub issue.
#
# A scratch (dash-raw-session.sh, #290) already owns a `scratch-<K>` branch in a
# `<repo>-scratch-<K>` worktree; binding renames the BRANCH to `issue-<N>` (the
# directory stays — a running Claude's cwd must not move), stamps @issue, drops
# @raw, keeps @worktree, and renames the window after the issue title. Everything
# downstream (PR map, janitor, ledger, /fleet-claim) then sees an ordinary worker.
#
# No network: a REAL local git repo stands in for $FLEET_MAIN (the scratch worktree
# is created for real, the branch rename is observed for real); `tmux` and `gh` are
# faked — tmux answers the caller-pane probe from $PANE_INFO and logs mutations, gh
# answers the claim gate from $GH_* and logs every call.
#
#   A. happy bind     → branch scratch-1 → issue-42 (same dir), @issue=42 set, @raw
#                       unset, @worktree KEPT, window renamed to the title kebab,
#                       @summary + summary cache reseeded, issue assigned (@me),
#                       one `bound` line on stdout naming #42 + issue-42
#   B. not a scratch  → no @raw on the caller window → REFUSE (3), nothing touched
#   C. already bound  → caller window carries @issue → REFUSE (3), nothing touched
#   D. live duplicate → another window in THIS fleet binds @issue=42 → refuse (4),
#                       branch untouched, no claim
#   E. claimed away   → #42 already has an assignee → refuse (4); `--force` binds
#                       anyway and SKIPS the claim (no assignee write)
#   F. branch taken   → refs/heads/issue-42 already exists → fail (1), scratch kept
#   G. naming         → no title anywhere → window `issue-42`; --title wins and
#                       needs no gh title read
#   H. no pane        → no $TMUX_PANE → REFUSE (3)
#   I. usage          → no/garbage issue number → exit 2, nothing touched
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-bind.sh"
LIB="$BIN/fleet-lib.sh"
[ -f "$SRC" ] || { echo "selftest: $SRC missing" >&2; exit 1; }
[ -f "$LIB" ] || { echo "selftest: $LIB missing" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "selftest: git absent — SKIP" >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bind-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf" "$WORK/tmp"
OPTS_LOG="$WORK/opts"; RENAME_LOG="$WORK/rename"; DISPLAY_LOG="$WORK/display"; GH_LOG="$WORK/gh"
ln -s "$SRC" "$WORK/bin/fleet-bind.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"

# --- a real base checkout + a real scratch-1 worktree stand in for the fleet ----
MAIN="$WORK/main"
git init -q "$MAIN"
git -C "$MAIN" config user.email t@t; git -C "$MAIN" config user.name t
printf 'seed\n' > "$MAIN/f"; git -C "$MAIN" add f; git -C "$MAIN" commit -qm seed
BASE_BR="$(git -C "$MAIN" branch --show-current)"
WT="$WORK/main-scratch-1"

reset_scratch() {   # fresh scratch-1 worktree on branch scratch-1; no issue-* branches
  local b
  git -C "$MAIN" worktree remove --force "$WT" >/dev/null 2>&1
  for b in $(git -C "$MAIN" for-each-ref --format='%(refname:short)' 'refs/heads/scratch-*' 'refs/heads/issue-*' 2>/dev/null); do
    git -C "$MAIN" branch -D "$b" >/dev/null 2>&1
  done
  git -C "$MAIN" worktree prune >/dev/null 2>&1
  git -C "$MAIN" worktree add -q -b scratch-1 "$WT" "$BASE_BR" >/dev/null 2>&1 \
    || fail "harness: could not create the scratch-1 worktree"
}
branch_of() { git -C "$1" symbolic-ref --short HEAD 2>/dev/null; }
has_branch() { git -C "$MAIN" show-ref --verify --quiet "refs/heads/$1"; }

# --- fake tmux: the caller-pane probe answers from $PANE_INFO
# (window_id|@issue|@raw|@worktree|pane_current_path); list-windows answers the
# fleet's "@issue window_id" lines from $WINS_ISSUES; mutations are logged. ------
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  display-message)
    case "$*" in
      *-p*) case "$*" in
              *window_id*)    echo "${PANE_INFO:-}" ;;
              *session_name*) echo "${SESS_NAME:-testsess}" ;;
              *) echo "" ;; esac ;;
      *)    printf '%s\n' "$*" >> "$DISPLAY_LOG" ;;
    esac ;;
  list-windows)      printf '%s\n' "${WINS_ISSUES:-}" ;;
  set-window-option) printf 'SETOPT %s\n' "$*" >> "$OPTS_LOG" ;;
  rename-window)     printf 'RENAME %s\n' "$*" >> "$RENAME_LOG" ;;
  *) : ;;
esac
exit 0
TMUXFAKE
# --- fake gh: the claim gate (assignees/state · open PRs by head · title) answers
# from $GH_ASSIGNEES / $GH_STATE / $GH_OPEN_PRS / $GH_TITLE; every call is logged.
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *"issue view"*assignees*) printf '%s\t%s\n' "${GH_ASSIGNEES:-0}" "${GH_STATE:-OPEN}" ;;
  *"issue view"*title*)     printf '%s\n' "${GH_TITLE:-}" ;;
  *"pr list"*)              printf '%s\n' "${GH_OPEN_PRS:-0}" ;;
  *) : ;;
esac
exit 0
GHFAKE
chmod +x "$WORK/fakebin/tmux" "$WORK/fakebin/gh"

# run the binder. Per-case env (PANE_INFO, WINS_ISSUES, GH_*) rides as a prefix on
# the run_bind call; args are forwarded to the script.
run_bind() {
  : > "$OPTS_LOG"; : > "$RENAME_LOG"; : > "$DISPLAY_LOG"; : > "$GH_LOG"
  rm -rf "$WORK/tmp/.claude-dash"
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" FLEET_CONF_DIR="$WORK/conf" \
  TMUX="${FAKE_TMUX-/fake/sock,1,0}" TMUX_PANE="${FAKE_PANE-%5}" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$MAIN" FLEET_BASE_BRANCH="$BASE_BR" \
  OPTS_LOG="$OPTS_LOG" RENAME_LOG="$RENAME_LOG" DISPLAY_LOG="$DISPLAY_LOG" GH_LOG="$GH_LOG" \
    bash "$WORK/bin/fleet-bind.sh" "$@" >"$WORK/out" 2>"$WORK/err"
  RC=$?
}
SCRATCH_PANE="@9||1|$WT|$WT"     # a plain scratch window: no @issue, @raw=1, @worktree

# ============================ A: happy bind ==================================
reset_scratch
PANE_INFO="$SCRATCH_PANE" GH_TITLE="Ship the Widget!" run_bind 42
[ "$RC" -eq 0 ]                              || fail "A bind should succeed (rc=$RC)" "$(cat "$WORK/err")"
has_branch issue-42                          || fail "A branch issue-42 must exist" "$(git -C "$MAIN" branch -a)"
has_branch scratch-1                         && fail "A branch scratch-1 must be gone (renamed)" "$(git -C "$MAIN" branch -a)"
[ -d "$WT" ]                                 || fail "A the worktree DIRECTORY must stay put" "$(git -C "$MAIN" worktree list)"
[ "$(branch_of "$WT")" = issue-42 ]          || fail "A the scratch worktree must now sit on issue-42" "$(branch_of "$WT")"
grep -q 'SETOPT .*@issue 42' "$OPTS_LOG"     || fail "A @issue=42 not set" "$(cat "$OPTS_LOG")"
grep -q 'SETOPT .*-u @raw' "$OPTS_LOG"       || fail "A @raw must be UNSET" "$(cat "$OPTS_LOG")"
grep -q 'SETOPT .*-u @worktree' "$OPTS_LOG"  && fail "A @worktree must be KEPT (dash ⌃x resolves it)" "$(cat "$OPTS_LOG")"
# The window option is fleet_summary_sanitize'd, which strips '#' by design (it is
# re-parsed by pane-border-format, #455) — so the OPTION reads "bound 42" while the
# dash summary FILE below keeps the raw "bound #42", exactly as a worker spawn does.
grep -q 'SETOPT .*@summary .*bound 42' "$OPTS_LOG" || fail "A @summary must be reseeded with bound 42" "$(cat "$OPTS_LOG")"
grep -q 'RENAME .*ship-the-widget' "$RENAME_LOG" || fail "A window must be renamed to the title kebab" "$(cat "$RENAME_LOG")"
grep -q 'issue edit 42 .*--add-assignee @me' "$GH_LOG" || fail "A #42 must be claimed (assignee @me)" "$(cat "$GH_LOG")"
sf=$(ls "$WORK"/tmp/.claude-dash/global/summary_* 2>/dev/null | head -1)
[ -n "$sf" ] && grep -q 'bound #42' "$sf"    || fail "A the dash summary cache must carry bound #42" "$(ls -R "$WORK/tmp")"
grep -q 'bound' "$WORK/out" && grep -q '#42' "$WORK/out" && grep -q 'issue-42' "$WORK/out" \
  || fail "A stdout must report the bind (#42, issue-42)" "$(cat "$WORK/out")"
ok "A bind renames scratch-1→issue-42 in place, @issue set, @raw dropped, window renamed, claimed"

# ============================ B: not a scratch ==============================
reset_scratch
PANE_INFO="@9||0|$MAIN|$MAIN" run_bind 42
[ "$RC" -eq 3 ]                              || fail "B a non-scratch pane must REFUSE with 3 (rc=$RC)" "$(cat "$WORK/err")"
has_branch scratch-1                         || fail "B nothing must be renamed on refusal"
[ -s "$OPTS_LOG" ]                           && fail "B no window option may change on refusal" "$(cat "$OPTS_LOG")"
grep -q 'issue edit' "$GH_LOG"               && fail "B no claim on refusal" "$(cat "$GH_LOG")"
grep -qi 'scratch' "$WORK/err"               || fail "B the refusal should say it is not a scratch" "$(cat "$WORK/err")"
ok "B a window without @raw is refused (3), untouched"

# ============================ C: already bound ==============================
reset_scratch
PANE_INFO="@9|7|1|$WT|$WT" run_bind 42
[ "$RC" -eq 3 ]                              || fail "C an @issue-bound pane must REFUSE with 3 (rc=$RC)" "$(cat "$WORK/err")"
has_branch scratch-1                         || fail "C nothing must be renamed on refusal"
[ -s "$OPTS_LOG" ]                           && fail "C no window option may change on refusal" "$(cat "$OPTS_LOG")"
grep -q '#7' "$WORK/err"                     || fail "C the refusal should name the existing binding (#7)" "$(cat "$WORK/err")"
ok "C a window already bound to #7 is refused (3), untouched"

# ============================ D: live duplicate in this fleet ===============
reset_scratch
PANE_INFO="$SCRATCH_PANE" WINS_ISSUES=$'12 @3\n42 @4' run_bind 42
[ "$RC" -eq 4 ]                              || fail "D a live @issue=42 window must refuse with 4 (rc=$RC)" "$(cat "$WORK/err")"
has_branch scratch-1                         || fail "D branch must be untouched on a duplicate"
grep -q 'issue edit' "$GH_LOG"               && fail "D no claim on a duplicate" "$(cat "$GH_LOG")"
[ -s "$OPTS_LOG" ]                           && fail "D no window option may change on a duplicate" "$(cat "$OPTS_LOG")"
ok "D a live window already bound to #42 in this fleet refuses (4)"

# ============================ E: claimed elsewhere · --force ================
reset_scratch
PANE_INFO="$SCRATCH_PANE" GH_ASSIGNEES=1 run_bind 42
[ "$RC" -eq 4 ]                              || fail "E an assigned issue must refuse with 4 (rc=$RC)" "$(cat "$WORK/err")"
has_branch scratch-1                         || fail "E branch must be untouched when claimed elsewhere"
grep -q 'issue edit' "$GH_LOG"               && fail "E no claim write when claimed elsewhere" "$(cat "$GH_LOG")"
# an open PR with head issue-42 is a claim too
PANE_INFO="$SCRATCH_PANE" GH_OPEN_PRS=1 run_bind 42
[ "$RC" -eq 4 ]                              || fail "E2 an open PR on issue-42 must refuse with 4 (rc=$RC)" "$(cat "$WORK/err")"
# --force: bind anyway, skip the gate AND the claim write
PANE_INFO="$SCRATCH_PANE" GH_ASSIGNEES=1 GH_TITLE="Taken" run_bind 42 --force
[ "$RC" -eq 0 ]                              || fail "E3 --force must bind past a stale claim (rc=$RC)" "$(cat "$WORK/err")"
[ "$(branch_of "$WT")" = issue-42 ]          || fail "E3 --force must still rename the branch"
grep -q 'issue edit' "$GH_LOG"               && fail "E3 --force must NOT re-assign" "$(cat "$GH_LOG")"
grep -q 'SETOPT .*@issue 42' "$OPTS_LOG"     || fail "E3 --force must still bind @issue" "$(cat "$OPTS_LOG")"
ok "E an assigned issue / open PR refuses (4); --force binds without re-claiming"

# ============================ F: branch already exists =======================
reset_scratch
git -C "$MAIN" branch issue-42 "$BASE_BR" >/dev/null 2>&1
PANE_INFO="$SCRATCH_PANE" run_bind 42
[ "$RC" -eq 1 ]                              || fail "F an existing issue-42 branch must fail with 1 (rc=$RC)" "$(cat "$WORK/err")"
[ "$(branch_of "$WT")" = scratch-1 ]         || fail "F the scratch must keep its branch when issue-42 is taken"
[ -s "$OPTS_LOG" ]                           && fail "F no window option may change on failure" "$(cat "$OPTS_LOG")"
grep -q 'issue edit' "$GH_LOG"               && fail "F must not claim when the branch is taken (gate runs after)" "$(cat "$GH_LOG")"
ok "F a pre-existing issue-42 branch fails (1) and leaves the scratch alone"

# ============================ G: naming =====================================
reset_scratch
PANE_INFO="$SCRATCH_PANE" GH_TITLE="" run_bind 42
[ "$RC" -eq 0 ]                              || fail "G1 bind should succeed with no title (rc=$RC)" "$(cat "$WORK/err")"
grep -q 'RENAME .*issue-42' "$RENAME_LOG"    || fail "G1 no title → window named issue-42" "$(cat "$RENAME_LOG")"
reset_scratch
PANE_INFO="$SCRATCH_PANE" GH_TITLE="Wrong One" run_bind 42 --title "My Custom Title"
[ "$RC" -eq 0 ]                              || fail "G2 bind should succeed with --title (rc=$RC)" "$(cat "$WORK/err")"
grep -q 'RENAME .*my-custom-title' "$RENAME_LOG" || fail "G2 --title must name the window" "$(cat "$RENAME_LOG")"
grep -q 'issue view 42 .*title' "$GH_LOG"    && fail "G2 --title must skip the gh title read" "$(cat "$GH_LOG")"
grep -q 'SETOPT .*@summary .*My Custom Title' "$OPTS_LOG" || fail "G2 the summary seed should carry the title" "$(cat "$OPTS_LOG")"
ok "G no title → issue-42; --title names the window without a gh read"

# ============================ H: no pane ====================================
reset_scratch
FAKE_PANE="" FAKE_TMUX="" PANE_INFO="$SCRATCH_PANE" run_bind 42
[ "$RC" -eq 3 ]                              || fail "H no \$TMUX_PANE must REFUSE with 3 (rc=$RC)" "$(cat "$WORK/err")"
has_branch scratch-1                         || fail "H nothing must change outside a pane"
ok "H outside a tmux pane the bind is refused (3)"

# ============================ I: usage ======================================
reset_scratch
PANE_INFO="$SCRATCH_PANE" run_bind
[ "$RC" -eq 2 ]                              || fail "I1 a missing issue number must exit 2 (rc=$RC)" "$(cat "$WORK/err")"
PANE_INFO="$SCRATCH_PANE" run_bind --bogus
[ "$RC" -eq 2 ]                              || fail "I2 an unknown flag must exit 2 (rc=$RC)" "$(cat "$WORK/err")"
has_branch scratch-1                         || fail "I nothing must change on a usage error"
ok "I a missing number / unknown flag exits 2 and touches nothing"

printf '\nselftest OK: %s assertions passed (fleet-bind: rename-in-place · marks · gate · force · naming)\n' "$pass"
exit 0
