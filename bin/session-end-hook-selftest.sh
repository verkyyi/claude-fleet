#!/bin/bash
# session-end-hook-selftest.sh — hermetic smoke test for the SessionEnd hook
# (issue #403). Drives the REAL bin/session-end-hook.sh + the shared reap helpers
# (fleet_reap_ok / fleet_reap_record / fleet_reap_worktree_procs) end to end.
#
# No network / no live tmux server / no real GitHub: FAKE `tmux` + `gh` stand in on
# PATH (the fake tmux runs `run-shell -b` INLINE, so the detached --exec reap the
# in-pane gate dispatches actually executes — mirroring real server-side run-shell),
# a REAL local git repo provides the worktrees, and FLEET_HISTORY_LEDGER +
# CLAUDE_PROJECTS_DIR scope the /fleet-history ledger + transcript lookups to $WORK.
#
# The acceptance checklist (issues #403, #409):
#   * clear / resume                → NO-OP (window survives, no ledger row, no reap)
#   * nothing set (default)         → ON: acts on prompt_input_exit (default-on, #409)
#   * global FLEET_CLOSE_ON_EXIT=0  → COMPLETE no-op (the global opt-out)
#   * per-fleet =1 while global =0  → still a NO-OP (global-authoritative, #409)
#   * steward hub (@steward=1)      → never touched (defensive bail)
#   * panel (no @issue, no @raw)    → never touched (no dispatch)
#   * prompt_input_exit on MERGED   → worktree+branch removed, issue closed, a
#                                     `landed` row (PR resolved), window gone
#   * prompt_input_exit on ANCESTOR → worktree+branch removed, `closed-unlanded`
#                                     row, window gone, issue KEPT OPEN (no merge)
#   * prompt_input_exit on UNMERGED → worktree + issue KEPT, `closed-unlanded` row,
#                                     window gone (resume works)
#   * prompt_input_exit on DIRTY    → worktree KEPT (not force-removed),
#                                     `closed-unlanded` row, window gone
#   * idempotent vs cleanup/ledger-watch — a second fire records ONE row
#   * @raw scratch                  → window closed only (no ledger row, no gh)
#   * stdin JSON reason parse works both ways (acts on prompt_input_exit; no-op on clear)
#
# Exit 0 = pass. Non-zero = fail (prints what diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/session-end-hook.sh"
[ -x "$SRC" ] || { printf 'selftest: %s missing/not executable\n' "$SRC" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/seh-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
# Physical path (macOS /var → /private/var) so the paths git reports match the ones
# we encode into transcript-dir names.
WORK="$(cd "$WORK" && pwd -P)"

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- log ---\n%s\n' "$2" >&2; exit 1; }

# worktree path → transcript-dir under CLAUDE_PROJECTS_DIR, encoded the way Claude
# Code (and fleet-history.sh transcript_dir_for) do: every non-alnum byte → '-'.
enc() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9' '-'; }

PROJECTS="$WORK/projects"; mkdir -p "$PROJECTS"
LEDGER="$WORK/history.tsv"; : > "$LEDGER"
TMLOG="$WORK/tmlog"; GHLOG="$WORK/ghlog"; : > "$TMLOG"; : > "$GHLOG"

# --- build a real base checkout + issue worktrees -----------------------------
BASEDIR="$WORK/base"
git init -q "$BASEDIR"
git -C "$BASEDIR" config user.email t@t; git -C "$BASEDIR" config user.name t
printf 'seed\n' > "$BASEDIR/f"; git -C "$BASEDIR" add f; git -C "$BASEDIR" commit -qm seed
BASE_BR="$(git -C "$BASEDIR" branch --show-current)"

# helper: add an issue-<N> worktree, optionally with a divergent commit / dirt.
add_wt() {  # <n> <mode: ancestor|commit|dirty>
  local n="$1" mode="$2"; local wt="$WORK/wt-$n"
  git -C "$BASEDIR" worktree add -q -b "issue-$n" "$wt" >/dev/null 2>&1
  case "$mode" in
    commit) printf 'x\n' > "$wt/g"; git -C "$wt" add g; git -C "$wt" commit -qm "work $n" ;;
    dirty)  printf 'x\n' > "$wt/g"; git -C "$wt" add g; git -C "$wt" commit -qm "work $n"
            printf 'dirt\n' > "$wt/untracked" ;;
    ancestor) : ;;   # clean, tip == base
  esac
  # a surviving transcript so record / record-closed resolve a session id.
  mkdir -p "$PROJECTS/$(enc "$wt")"; : > "$PROJECTS/$(enc "$wt")/sess-$n.jsonl"
  printf '%s' "$wt"
}

WT1="$(add_wt 1 commit)"    # merged (via fake gh) → merged-pr  → reap + close issue
WT2="$(add_wt 2 commit)"    # not merged            → unmerged  → KEEP
WT3="$(add_wt 3 dirty)"     # dirty                 → dirty     → KEEP
WT4="$(add_wt 4 ancestor)"  # tip == base           → ancestor  → reap, issue kept open
WT5="$(add_wt 5 commit)"    # not merged (stdin test)→ unmerged  → KEEP
WT6="$(add_wt 6 commit)"    # not merged (default-on) → unmerged  → KEEP

# --- fake tmux: answers the window queries, executes run-shell -b inline -------
# @issue / @raw / @steward / window_id / session_name are read from env (ISS / RAW /
# STEW / WID). run-shell runs its command via `sh -c` so the dispatched --exec reap
# executes (like a real server-side background job); kill-window is logged.
mkdir -p "$WORK/fakepath"
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = "run-shell" ]; then
  shift; [ "${1:-}" = "-b" ] && shift
  printf 'RUNSHELL %s\n' "$1" >> "$TMLOG"
  sh -c "$1"
  exit 0
fi
case "$*" in
  *@issue*)       printf '%s\n' "${ISS:-}" ;;
  *@raw*)         printf '%s\n' "${RAW:-}" ;;
  *@steward*)     printf '%s\n' "${STEW:-}" ;;
  *window_id*)    printf '%s\n' "${WID:-@9}" ;;
  *session_name*) printf 's1\n' ;;
  *kill-window*)  printf 'KILL %s\n' "$*" >> "$TMLOG" ;;
  *)              : ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

# --- fake gh: a merged PR exists iff --head == $GH_MERGED_HEAD -----------------
#   pr list … --head <b> --json headRefName  → the head (so fleet_reap_ok = merged-pr)
#   pr list … --head <b> --json number       → $GH_MERGED_PR (landed-row PR resolution)
#   issue view  → $GH_ISSUE_STATE (default OPEN)   issue close → logged
cat > "$WORK/fakepath/gh" <<'FAKE'
#!/bin/bash
head=""; prev=""
for a in "$@"; do [ "$prev" = "--head" ] && head="$a"; prev="$a"; done
case "$*" in
  *"pr list"*)
    if [ -n "$head" ] && [ "$head" = "${GH_MERGED_HEAD:-}" ]; then
      case "$*" in
        *"--json number"*)      printf '%s\n' "${GH_MERGED_PR:-}" ;;
        *"--json headRefName"*) printf '%s\n' "$head" ;;
      esac
    fi ;;
  *"issue view"*)  printf '%s\n' "${GH_ISSUE_STATE:-OPEN}" ;;
  *"issue close"*) printf 'CLOSE %s\n' "$*" >> "$GHLOG" ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/gh"

# --- run the hook (the in-pane gate) with the fakes + a scoped estate ----------
# ISS/RAW/STEW/WID feed the fake tmux; REASON drives the reason gate (via the
# FLEET_SESSION_END_REASON test seam); CLOSE drives FLEET_CLOSE_ON_EXIT. GH_* drive
# the fake gh. FLEET_CONF_DIR points at nothing so fleet_load_conf is a no-op and the
# FLEET_REPO/MAIN/BASE env below win (matching dash-reap-selftest).
run_hook() {
  ISS="${ISS:-}" RAW="${RAW:-}" STEW="${STEW:-}" WID="${WID:-@9}" \
  TMLOG="$TMLOG" GHLOG="$GHLOG" \
  GH_MERGED_HEAD="${GH_MERGED_HEAD:-}" GH_MERGED_PR="${GH_MERGED_PR:-}" GH_ISSUE_STATE="${GH_ISSUE_STATE:-OPEN}" \
  FLEET_SESSION_END_REASON="${REASON:-}" \
  FLEET_CLOSE_ON_EXIT="${CLOSE:-1}" \
  FLEET_REPO="fake/repo" FLEET_MAIN="$BASEDIR" FLEET_BASE_BRANCH="$BASE_BR" \
  FLEET_CONF_DIR="${CONFDIR:-$WORK/noconf}" TMPDIR="$WORK/rt" \
  FLEET_HISTORY_LEDGER="$LEDGER" CLAUDE_PROJECTS_DIR="$PROJECTS" \
  TMUX="fake-sock" TMUX_PANE="%1" \
  PATH="$WORK/fakepath:$PATH" \
    bash "$SRC"
}

rows() { awk -F'\t' -v i="$1" -v s="$2" '$2==i && $10==s' "$LEDGER" | wc -l | tr -d ' '; }
clr()  { : > "$TMLOG"; : > "$GHLOG"; }

# ============================ NO-OP GATES ====================================
# T1: reason=clear → the in-pane gate returns BEFORE dispatch (no RUNSHELL/KILL, no row).
clr; REASON=clear ISS=2 WID='@2' run_hook
grep -q 'RUNSHELL' "$TMLOG" && fail "clear must not dispatch a reap" "$(cat "$TMLOG")"
grep -q 'KILL' "$TMLOG" && fail "clear must not close a window"
[ -d "$WT2" ] || fail "clear must not touch the worktree"
[ "$(rows 2 closed-unlanded)" = 0 ] || fail "clear must not write a ledger row"
ok "reason=clear → complete no-op (no dispatch, no reap, no row)"

# T2: reason=resume → same no-op.
clr; REASON=resume ISS=2 WID='@2' run_hook
grep -q 'RUNSHELL\|KILL' "$TMLOG" && fail "resume must be a no-op" "$(cat "$TMLOG")"
ok "reason=resume → complete no-op"

# T3: GLOBAL FLEET_CLOSE_ON_EXIT=0 (the machine-wide opt-out) + a real exit reason →
# complete no-op. run_hook passes the value in the env, snapshotted as the global one.
clr; REASON=prompt_input_exit CLOSE=0 ISS=2 WID='@2' run_hook
grep -q 'RUNSHELL\|KILL' "$TMLOG" && fail "global FLEET_CLOSE_ON_EXIT=0 must be a no-op" "$(cat "$TMLOG")"
[ -d "$WT2" ] || fail "global opt-out must not touch the worktree"
ok "global FLEET_CLOSE_ON_EXIT=0 → complete no-op (the machine-wide opt-out)"

# T3b: NOTHING set (FLEET_CLOSE_ON_EXIT genuinely UNSET, no global conf) → the hook is
# ON BY DEFAULT (#409) and ACTS. Fires on the unmerged #6 → KEEP worktree + issue,
# closed-unlanded row, window closed. (Inverts #403's old opt-in default-off case.)
clr
( unset FLEET_CLOSE_ON_EXIT
  env ISS=6 WID='@6' TMLOG="$TMLOG" GHLOG="$GHLOG" \
      FLEET_SESSION_END_REASON=prompt_input_exit \
      FLEET_REPO="fake/repo" FLEET_MAIN="$BASEDIR" FLEET_BASE_BRANCH="$BASE_BR" \
      FLEET_CONF_DIR="$WORK/noconf" TMPDIR="$WORK/rt" \
      FLEET_HISTORY_LEDGER="$LEDGER" CLAUDE_PROJECTS_DIR="$PROJECTS" \
      TMUX="fake-sock" TMUX_PANE="%1" PATH="$WORK/fakepath:$PATH" \
      bash "$SRC" )
grep -q 'RUNSHELL' "$TMLOG" || fail "default-on: unset FLEET_CLOSE_ON_EXIT must ACT" "$(cat "$TMLOG")"
grep -q 'KILL' "$TMLOG" || fail "default-on exit must close the window"
[ -d "$WT6" ] || fail "default-on unmerged #6 worktree must be KEPT (resumable)"
[ "$(rows 6 closed-unlanded)" = 1 ] || fail "default-on exit must write ONE closed-unlanded row for #6" "$(cat "$LEDGER")"
ok "nothing set → ON by default (#409): acts on prompt_input_exit"

# T3c: a PER-FLEET FLEET_CLOSE_ON_EXIT=1 while the GLOBAL value is 0 → STILL a no-op.
# Global-authoritative on TWO layers: fleet_load_conf STRIPS a per-fleet
# FLEET_CLOSE_ON_EXIT (it is in fleet-lib's $_FLEET_GLOBAL_ONLY, issue #237), AND the
# hook snapshots the global 0 BEFORE the overlay and gates on that snapshot. If the
# per-fleet value were honored this would dispatch — so no-dispatch proves global wins.
PFCONF="$WORK/pfconf"; mkdir -p "$PFCONF/fleets/s1"
printf 'FLEET_CLOSE_ON_EXIT=1\n' > "$PFCONF/fleets/s1/conf"
clr; REASON=prompt_input_exit CLOSE=0 CONFDIR="$PFCONF" ISS=2 WID='@2' run_hook
grep -q 'RUNSHELL\|KILL' "$TMLOG" && fail "per-fleet=1 while global=0 must STILL be a no-op (global-authoritative)" "$(cat "$TMLOG")"
[ -d "$WT2" ] || fail "global-authoritative no-op must not touch the worktree"
[ "$(rows 2 closed-unlanded)" = 0 ] || fail "global-authoritative no-op must write no ledger row" "$(cat "$LEDGER")"
ok "per-fleet FLEET_CLOSE_ON_EXIT=1 while global=0 → still a no-op (global wins)"

# T4: steward hub (@steward=1) → defensive bail (no dispatch), even opted-in.
clr; REASON=prompt_input_exit STEW=1 ISS='' WID='@1' run_hook
grep -q 'RUNSHELL\|KILL' "$TMLOG" && fail "steward hub must never be touched" "$(cat "$TMLOG")"
ok "steward hub (@steward=1) → never touched"

# T5: panel (no @issue, no @raw, no @steward) → no dispatch.
clr; REASON=prompt_input_exit ISS='' RAW='' STEW='' WID='@1' run_hook
grep -q 'RUNSHELL\|KILL' "$TMLOG" && fail "a panel row must not dispatch" "$(cat "$TMLOG")"
ok "panel (no @issue/@raw) → never touched"

# ============================ ACTING PATHS ===================================
# T6: MERGED worker → reap worktree+branch, close issue, landed row (PR resolved), window gone.
clr; REASON=prompt_input_exit ISS=1 WID='@1' GH_MERGED_HEAD=issue-1 GH_MERGED_PR=111 run_hook
grep -q 'RUNSHELL' "$TMLOG" || fail "merged exit must dispatch the reap" "$(cat "$TMLOG")"
grep -q 'KILL' "$TMLOG" || fail "merged exit must close the window"
[ -d "$WT1" ] && fail "merged worktree must be removed"
git -C "$BASEDIR" show-ref --verify -q refs/heads/issue-1 && fail "issue-1 branch must be deleted"
[ "$(rows 1 landed)" = 1 ] || fail "merged exit must write ONE landed row for #1" "$(cat "$LEDGER")"
lp="$(awk -F'\t' '$2==1{print $4}' "$LEDGER")"
[ "$lp" = 111 ] || fail "landed #1 row must carry the resolved PR 111 (got [$lp])"
grep -q 'CLOSE' "$GHLOG" || fail "merged exit must close the issue"
ok "prompt_input_exit on MERGED → wt+branch reaped, issue closed, landed row (PR 111), window gone"

# T7: UNMERGED worker → KEEP worktree + issue, closed-unlanded row, window gone, no gh close.
clr; REASON=prompt_input_exit ISS=2 WID='@2' run_hook
grep -q 'RUNSHELL' "$TMLOG" || fail "unmerged exit must dispatch" "$(cat "$TMLOG")"
grep -q 'KILL' "$TMLOG" || fail "unmerged exit must close the window"
[ -d "$WT2" ] || fail "unmerged worktree must be KEPT (resumable)"
git -C "$BASEDIR" show-ref --verify -q refs/heads/issue-2 || fail "unmerged branch must be KEPT"
[ "$(rows 2 closed-unlanded)" = 1 ] || fail "unmerged exit must write ONE closed-unlanded row for #2" "$(cat "$LEDGER")"
grep -q 'CLOSE' "$GHLOG" && fail "unmerged exit must NOT close the issue"
ok "prompt_input_exit on UNMERGED → wt+issue KEPT, closed-unlanded row, window gone"

# T8: DIRTY worker → KEEP worktree (git refuses forceless remove), closed-unlanded row, window gone.
clr; REASON=prompt_input_exit ISS=3 WID='@3' run_hook
grep -q 'KILL' "$TMLOG" || fail "dirty exit must close the window"
[ -d "$WT3" ] || fail "dirty worktree must be KEPT (never force-removed)"
[ -f "$WT3/untracked" ] || fail "dirty worktree's uncommitted file must survive"
[ "$(rows 3 closed-unlanded)" = 1 ] || fail "dirty exit must write ONE closed-unlanded row for #3" "$(cat "$LEDGER")"
grep -q 'CLOSE' "$GHLOG" && fail "dirty exit must NOT close the issue"
ok "prompt_input_exit on DIRTY → wt KEPT (not force-removed), closed-unlanded row, window gone"

# T9: ANCESTOR worker → reap worktree+branch, closed-unlanded row, window gone, issue KEPT OPEN.
clr; REASON=prompt_input_exit ISS=4 WID='@4' run_hook
grep -q 'KILL' "$TMLOG" || fail "ancestor exit must close the window"
[ -d "$WT4" ] && fail "ancestor worktree must be removed"
git -C "$BASEDIR" show-ref --verify -q refs/heads/issue-4 && fail "ancestor branch must be deleted"
[ "$(rows 4 closed-unlanded)" = 1 ] || fail "ancestor exit must write ONE closed-unlanded row for #4" "$(cat "$LEDGER")"
grep -q 'CLOSE' "$GHLOG" && fail "ancestor (no merged PR) must KEEP the issue open (no gh close)"
ok "prompt_input_exit on ANCESTOR → wt+branch reaped, closed-unlanded row, issue KEPT OPEN"

# T10: IDEMPOTENT — a SECOND fire on the still-kept unmerged #2 records NO extra row
# (record-closed dedups on session-id, so racing the cleanup daemon / ledger-watch is safe).
clr; REASON=prompt_input_exit ISS=2 WID='@2' run_hook
[ "$(rows 2 closed-unlanded)" = 1 ] || fail "a second fire must NOT add a duplicate row for #2 (idempotent)" "$(cat "$LEDGER")"
ok "idempotent — a second fire records ONE row (dedup vs cleanup/ledger-watch)"

# T11: @raw scratch → close the window ONLY (no ledger row, no gh). A summary-cache
# seed under the dash cache is dropped. fleet_summary_key s1/@9 = s1_9.
CACHE="$WORK/rt/.claude-dash/global"; mkdir -p "$CACHE"
SEED="$CACHE/summary_s1_9"; printf 'scratch' > "$SEED"
before="$(wc -l < "$LEDGER" | tr -d ' ')"
clr; REASON=prompt_input_exit ISS='' RAW=1 WID='@9' run_hook
grep -q 'RUNSHELL' "$TMLOG" || fail "raw scratch exit must dispatch (window close)" "$(cat "$TMLOG")"
grep -q 'KILL' "$TMLOG" || fail "raw scratch exit must close the window"
[ -s "$GHLOG" ] && fail "raw scratch exit must not touch gh"
[ -e "$SEED" ] && fail "raw scratch exit should drop the dash summary-cache seed"
[ "$(wc -l < "$LEDGER" | tr -d ' ')" = "$before" ] || fail "raw scratch exit must write NO ledger row" "$(cat "$LEDGER")"
ok "@raw scratch → window closed only (no ledger row, no gh)"

# ======================= STDIN JSON REASON PARSE =============================
# T12: no FLEET_SESSION_END_REASON — the reason comes from the piped hook payload.
# prompt_input_exit → acts (dispatch + closed-unlanded row for the kept #5).
clr
printf '{"hook_event_name":"SessionEnd","reason":"prompt_input_exit","cwd":"/x"}' | \
  env ISS=5 WID='@5' TMLOG="$TMLOG" GHLOG="$GHLOG" \
      FLEET_CLOSE_ON_EXIT=1 \
      FLEET_REPO="fake/repo" FLEET_MAIN="$BASEDIR" FLEET_BASE_BRANCH="$BASE_BR" \
      FLEET_CONF_DIR="$WORK/noconf" TMPDIR="$WORK/rt" \
      FLEET_HISTORY_LEDGER="$LEDGER" CLAUDE_PROJECTS_DIR="$PROJECTS" \
      TMUX="fake-sock" TMUX_PANE="%1" PATH="$WORK/fakepath:$PATH" \
      bash "$SRC"
grep -q 'RUNSHELL' "$TMLOG" || fail "stdin reason=prompt_input_exit must act" "$(cat "$TMLOG")"
[ -d "$WT5" ] || fail "unmerged #5 worktree must be KEPT"
[ "$(rows 5 closed-unlanded)" = 1 ] || fail "stdin prompt_input_exit must write a closed-unlanded row for #5" "$(cat "$LEDGER")"
ok "stdin JSON reason=prompt_input_exit → parsed + acted"

# T13: stdin reason=clear → no-op (verifies the parse gate the other way).
clr
printf '{"reason":"clear"}' | \
  env ISS=5 WID='@5' TMLOG="$TMLOG" GHLOG="$GHLOG" FLEET_CLOSE_ON_EXIT=1 \
      FLEET_REPO="fake/repo" FLEET_MAIN="$BASEDIR" FLEET_BASE_BRANCH="$BASE_BR" \
      FLEET_CONF_DIR="$WORK/noconf" TMPDIR="$WORK/rt" \
      FLEET_HISTORY_LEDGER="$LEDGER" CLAUDE_PROJECTS_DIR="$PROJECTS" \
      TMUX="fake-sock" TMUX_PANE="%1" PATH="$WORK/fakepath:$PATH" \
      bash "$SRC"
grep -q 'RUNSHELL\|KILL' "$TMLOG" && fail "stdin reason=clear must be a no-op" "$(cat "$TMLOG")"
ok "stdin JSON reason=clear → no-op"

printf '\nselftest PASS: %s assertions (SessionEnd hook — reason gate, default-on + global opt-out, seat scope, gate-reap by verdict, record-now, idempotent, @raw window-close, stdin parse) [#403, #409]\n' "$pass"
exit 0
