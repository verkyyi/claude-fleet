#!/bin/bash
# dash-reap-selftest.sh — hermetic smoke test for the dash reaper (issue #100).
#
# Three layers, no network / no tmux server / no real GitHub:
#
#   A. fleet_reap_ok() — the SHARED clean+merged gate (fleet-lib.sh) that BOTH
#      the janitor (worktree-autoclean.sh) and dash-reap.sh call. Exercised
#      against REAL git worktrees:
#        • clean + ancestor-of-base           → ancestor  (rc 0)
#        • clean + merged-PR (branch in list)  → merged-pr (rc 0)
#        • clean + NOT merged                  → unmerged  (rc 1)
#        • dirty (untracked file)              → dirty     (rc 1)
#
#   B. dash-reap.sh decisions (issue #289 merged ⌃x/⌥x into one confirming ⌃x),
#      with a FAKE tmux + gh and a real git checkout:
#        • hub/panel row (no @issue)           → refuse, no side effects
#        • ⌃x on a dirty row                   → open a confirm POPUP, KEEP the
#          worktree, no kill (the popup re-invokes with `confirm`)
#        • ⌃x on a clean+unmerged row          → open a confirm POPUP, KEEP it
#        • ⌃x on a clean+merged row            → FULL reap STRAIGHT AWAY (no
#          confirm): worktree removed, branch deleted, `gh issue close` issued,
#          `tmux kill-window` issued.
#        • confirm y on dirty                  → KEEP worktree, close + kill only
#        • confirm y on clean+unmerged         → FULL reap
#        • confirm n                           → no side effects
#        • EVERY worker reap RECORDS a /fleet-history row before disposing (#471):
#          the gate verdict is threaded into the backgrounded --exec dispatch, so a
#          merged-PR reap writes a `landed` row (PR resolved from the branch) and
#          ancestor/unmerged/dirty write `closed-unlanded` — each carrying the HEAD
#          sha, which is the proof the row was written pre-removal. A verdict-less
#          dispatch (pre-#471 string in flight) records nothing; a CANCELLED reap
#          records nothing.
#        • ⌃x on a raw scratch row (@raw=1, no @issue) — the session is RECORDED into
#          the /fleet-history ledger before any disposal (#466); issue #290 the scratch owns
#          a `scratch-<N>` worktree (resolved via @worktree), reaped by the SAME
#          one-key ⌃x rule (issue #289):
#            - clean+ancestor  → window closed + worktree/branch removed (no confirm)
#            - dirty/unmerged  → confirm POPUP first; confirm y keeps a dirty wt but
#                                removes a clean+unmerged one; the window closes
#            - no @worktree    → degrade: just close the window (pre-#290 behavior)
#          Nothing issue-bound is touched.
#
#   D. the NON-INTERACTIVE entry (issue #596) — `dash-reap.sh <handle>` is a public
#      script interface, so it must not depend on a human being there:
#        • --yes / --force on dirty    → KEEP the worktree, close window+issue, NO
#                                        popup — identical to a confirmed ⌃x
#        • --yes on clean+unmerged     → full reap, NO popup
#        • --yes on clean+merged       → reaps SYNCHRONOUSLY (no run-shell dispatch),
#                                        so the caller's exit is the outcome
#        • no --yes, NO attached client → refuse with `skip:needs-confirm` rather
#                                        than drawing a y/n box nobody can press
#        • no --yes, client attached   → historic confirm popup, but the caller now
#                                        reads `skip:needs-confirm` / rc 3, not "done"
#        • every script-facing exit prints ONE token (`reaped:full` / `reaped:keep` /
#          `skip:needs-confirm` / `refused:<slug>`) with a distinct exit status
#
#   C. the dash ⌃x bind wiring (issue #313) — a static check on tmux-dashboard.sh:
#      the reap bind must be `ctrl-x:execute-silent(...)`, never a bare
#      `ctrl-x:execute(...)`. `execute` suspends + clears fzf while dash-reap runs,
#      blanking the whole dash for the reap; `execute-silent` keeps it visible.
#
# Exit 0 = pass. Non-zero = fail (prints what diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -x "$BIN/dash-reap.sh" ] || { printf 'selftest: %s missing/not executable\n' "$BIN/dash-reap.sh" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dr-selftest.XXXXXX")" || exit 2
# Physical path (macOS /var → /private/var): git reports worktrees by their real
# path, and the /fleet-history assertions (#471) encode that path into a
# transcript-dir name — a symlinked $WORK would encode to a dir that never matches.
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# --- build a real base checkout + worktrees -----------------------------------
BASEDIR="$WORK/base"
git init -q "$BASEDIR"
git -C "$BASEDIR" config user.email t@t; git -C "$BASEDIR" config user.name t
printf 'seed\n' > "$BASEDIR/f"; git -C "$BASEDIR" add f; git -C "$BASEDIR" commit -qm seed
BASE_BR="$(git -C "$BASEDIR" branch --show-current)"
MASTER="$(git -C "$BASEDIR" rev-parse HEAD)"

# issue-1: its commit is merged into base; base advances below ⇒ strict ancestor
git -C "$BASEDIR" worktree add -q -b issue-1 "$WORK/wt1" >/dev/null 2>&1
git -C "$WORK/wt1" commit --allow-empty -qm landed-work
H1="$(git -C "$WORK/wt1" rev-parse HEAD)"
git -C "$BASEDIR" merge --ff-only -q issue-1
git -C "$BASEDIR" commit --allow-empty -qm base-advance
MASTER="$(git -C "$BASEDIR" rev-parse HEAD)"
# issue-2: clean, one extra commit NOT on base ⇒ not merged
git -C "$BASEDIR" worktree add -q -b issue-2 "$WORK/wt2" >/dev/null 2>&1
printf 'x\n' > "$WORK/wt2/g"; git -C "$WORK/wt2" add g; git -C "$WORK/wt2" commit -qm work
H2="$(git -C "$WORK/wt2" rev-parse HEAD)"
# issue-3: dirty (untracked file), extra commit too
git -C "$BASEDIR" worktree add -q -b issue-3 "$WORK/wt3" >/dev/null 2>&1
printf 'y\n' > "$WORK/wt3/h"; git -C "$WORK/wt3" add h; git -C "$WORK/wt3" commit -qm work3
printf 'dirt\n' > "$WORK/wt3/untracked"
H3="$(git -C "$WORK/wt3" rev-parse HEAD)"
# issue-7: clean, divergent commit, and the fake gh reports a MERGED PR for its
# branch ⇒ merged-pr — the only verdict that records a `landed` row (#471).
git -C "$BASEDIR" worktree add -q -b issue-7 "$WORK/wt7" >/dev/null 2>&1
printf 'z\n' > "$WORK/wt7/i"; git -C "$WORK/wt7" add i; git -C "$WORK/wt7" commit -qm work7
# issue-8: clean, strict ancestor. Used only to prove that a dispatch with
# NO verdict (an in-flight pre-#471 bg string) records nothing.
git -C "$BASEDIR" worktree add -q -b issue-8 "$WORK/wt8" "$H1" >/dev/null 2>&1

# Fresh issue-17 has no commits beyond the current base and no merged PR.
git -C "$BASEDIR" worktree add -q -b issue-17 "$WORK/wt17" >/dev/null 2>&1

# --- A. fleet_reap_ok direct assertions ---------------------------------------
. "$BIN/fleet-lib.sh"

chk() { # <label> <expect-token> <expect-rc> ... args to fleet_reap_ok
  local label="$1" want="$2" wantrc="$3"; shift 3
  local got rc
  got="$(fleet_reap_ok "$@")"; rc=$?
  [ "$got" = "$want" ] || fail "fleet_reap_ok $label: got '$got' want '$want'"
  [ "$rc" = "$wantrc" ] || fail "fleet_reap_ok $label: rc $rc want $wantrc"
}

chk "zero-commit-sha" unmerged 1 "$WORK/wt17" "$BASEDIR" issue-17 "$MASTER" "$MASTER" ""
chk "zero-commit-ref" unmerged 1 "$WORK/wt17" "$BASEDIR" issue-17 "$MASTER" "$BASE_BR" ""
chk "zero-commit-head-ref" unmerged 1 "$WORK/wt17" "$BASEDIR" issue-17 issue-17 "$BASE_BR" ""
chk "zero-commit-merged-PR" merged-pr 0 "$WORK/wt17" "$BASEDIR" issue-17 "$MASTER" "$BASE_BR" issue-17
chk "missing-base" unmerged 1 "$WORK/wt17" "$BASEDIR" issue-17 "$MASTER" missing-ref ""
chk "missing-head" unmerged 1 "$WORK/wt17" "$BASEDIR" issue-17 missing-ref "$BASE_BR" ""
chk "clean+ancestor" ancestor 0 "$WORK/wt1" "$BASEDIR" issue-1 "$H1" "$MASTER" ""
chk "clean+merged-PR" merged-pr 0 "$WORK/wt2" "$BASEDIR" issue-2 "$H2" "$MASTER" "issue-2"
chk "clean+unmerged" unmerged 1 "$WORK/wt2" "$BASEDIR" issue-2 "$H2" "$MASTER" ""
chk "dirty" dirty 1 "$WORK/wt3" "$BASEDIR" issue-3 "$H3" "$MASTER" "issue-3"
chk "empty-wtdir+ancestor" ancestor 0 "" "$BASEDIR" issue-1 "$H1" "$MASTER" ""

# --- B. dash-reap.sh with fakes -----------------------------------------------
mkdir -p "$WORK/fakepath" "$WORK/rt"
TMLOG="$WORK/tmlog"; GHLOG="$WORK/ghlog"; : > "$TMLOG"; : > "$GHLOG"

# fake tmux: answers the info queries dash-reap needs; logs kill-window + messages.
# @issue / @raw / window_id are read from env vars (ISS/RAW/WID, set per run).
# Order matters — check the specific #{@...}/window_id queries BEFORE session_name
# (all contain "display-message -p"); the generic MSG fallback stays last.
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
# LOG + EXECUTE run-shell (so the backgrounded reap, issue #304, actually runs its
# git worktree remove + gh close + kill-window, mirroring real `run-shell -b`).
if [ "${1:-}" = "run-shell" ]; then
  shift; [ "${1:-}" = "-b" ] && shift
  printf 'RUNSHELL %s\n' "$1" >> "$TMLOG"
  [ -n "${REAP_BG_STATE:-}" ] && export REAP_STATE="$REAP_BG_STATE"
  sh -c "$1"
  exit 0
fi
case "$*" in
  *'#{@claude_state}'*) printf '%s\n' "${REAP_STATE:-}" ;;
  *'#{pane_pid}'*) printf '%s\n' "$PPID" ;;  # this test's Python probe, not a live pane
  # attached-client probe (#596): CLIENTS unset ⇒ one fake client (the interactive
  # ⌃x cases); CLIENTS="" ⇒ a headless fleet, where a popup must never be drawn.
  *list-clients*) [ -n "${CLIENTS-}" ] && printf '%s\n' "$CLIENTS" ;;
  *@reap_hold*)   printf '%s\n' "${HOLD:-}" ;;       # issue #1244
  *@worker_lifecycle*) printf '%s\n' "${LIFE:-}" ;;
  *@raw*)         printf '%s\n' "${RAW:-}" ;;
  *@worktree*)    printf '%s\n' "${WT:-}" ;;         # scratch worktree path (#290)
  *@issue*)       printf '%s\n' "${ISS:-}" ;;
  *pane_current_path*) printf '%s\n' "${WT:-}" ;;
  # a killed window is GONE (#1244): dash-reap re-reads window_id after the kill
  # and reports failed:kill-window if it still resolves.
  *window_id*)    [ -e "$TMLOG.killed" ] && exit 1; printf '%s\n' "${WID:-@9}" ;;
  *session_name*) printf 's1\n' ;;
  *window_name*) printf 'worker name\n' ;;
  *kill-window*)  printf 'KILL %s\n' "$*" >> "$TMLOG"; [ "${KILL_FAILS:-0}" = 1 ] || : > "$TMLOG.killed" ;;
  *display-popup*)
    printf 'POPUP %s\n' "$*" >> "$TMLOG"
    # Normal popup: execute on a separate terminal (discard UI here), cancel.
    # Refusal: tmux returns success without ever running the command (#454).
    if [ "${REFUSE_POPUP:-0}" != 1 ]; then
      for popup_cmd in "$@"; do :; done
      printf n | bash -c "$popup_cmd" >/dev/null
    fi ;;
  *)              printf 'MSG %s\n' "$*" >> "$TMLOG" ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

# fake gh: a MERGED PR exists only for issue-7 (headRefName for the reap gate,
# number 7700 for fleet_reap_record's branch→PR resolution, #471); every other
# branch gets nothing, so the gate falls through to ancestor/unmerged as before.
# issue view → OPEN; issue close → log.
cat > "$WORK/fakepath/gh" <<'FAKE'
#!/bin/bash
case "$*" in
  *"pr list"*)
    head=""; prev=""
    for a in "$@"; do [ "$prev" = "--head" ] && head="$a"; prev="$a"; done
    if [ "$head" = issue-7 ]; then
      case "$*" in
        *"--json number"*)      printf '7700\n' ;;
        *"--json headRefName"*) printf 'issue-7\n' ;;
      esac
    fi ;;
  *"issue view"*)  printf 'OPEN\n' ;;
  *"issue close"*) printf 'CLOSE %s\n' "$*" >> "$GHLOG" ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/gh"

# /fleet-history plumbing (issue #466): the scratch path records a ledger row before
# it disposes of a worktree, so the ledger + transcript lookups are scoped to $WORK —
# a selftest must never append to the operator's real history.
LEDGER="$WORK/history.tsv"; : > "$LEDGER"
PROJECTS="$WORK/projects"; mkdir -p "$PROJECTS"
# worktree path → transcript-dir name, encoded the way Claude Code (and
# fleet-history.sh) do: every non-alnum byte → '-'.
enc() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9' '-'; }
transcript_for() { mkdir -p "$PROJECTS/$(enc "$1")"; : > "$PROJECTS/$(enc "$1")/sess-$2.jsonl"; }
srows() { awk -F'\t' -v k="$1" '$2==k' "$LEDGER" | wc -l | tr -d ' '; }
# state (col 10) / pr (col 4) / sha (col 5) of the row for a key.
scol() { awk -F'\t' -v k="$1" -v c="$2" '$2==k{print $c}' "$LEDGER"; }
# Surviving transcripts for the WORKER fixtures too (#471): record-closed / record
# skip a worktree with no resolvable session, so without these the ledger
# assertions below would pass vacuously.
transcript_for "$WORK/wt1" 1
transcript_for "$WORK/wt2" 2
transcript_for "$WORK/wt3" 3
transcript_for "$WORK/wt7" 7
transcript_for "$WORK/wt8" 8

run_reap() { # <ISS> <args...> — run dash-reap with the fakes + this base checkout
  local iss="$1"; shift
  rm -f "$TMLOG.killed"
  # RAW/WID feed the fake tmux's @raw/window_id answers (empty RAW ⇒ not a raw row).
  # TMPDIR is redirected under $WORK so fleet-lib's cache dir (FLEET_C) — and the
  # raw path's summary-cache rm — stay hermetic (never touch the real cache).
  ISS="$iss" RAW="${RAW:-}" WID="${WID:-}" WT="${WT:-}" TMLOG="$TMLOG" GHLOG="$GHLOG" \
  CLIENTS="${CLIENTS-fake-client}" \
  FLEET_REPO="fake/repo" FLEET_MAIN="$BASEDIR" FLEET_BASE_BRANCH="$BASE_BR" \
  FLEET_CONF_DIR="$WORK/noconf" TMPDIR="$WORK/rt" \
  FLEET_HISTORY_LEDGER="$LEDGER" CLAUDE_PROJECTS_DIR="$PROJECTS" \
  PATH="$WORK/fakepath:$PATH" \
    bash "$BIN/dash-reap.sh" "$@"
}

# run_reap, capturing the #596 result token (stdout) and the exit status.
run_reap_tok() { TOK="$(run_reap "$@")"; RC=$?; }

# #565: even a merged/idle row must reject shifting indexes and extra targets.
for bad in 5 :6 s1:8 worker-name; do
  : > "$TMLOG"; : > "$GHLOG"
  run_reap_tok 7 "$bad" --yes 2>"$WORK/target-err"
  [ "$RC" = 4 ] && [ "$TOK" = refused:target ] || fail "unstable target was accepted: $bad"
  grep -q 'currently resolves to.*@9' "$WORK/target-err" || fail "refusal must show diagnostic resolution"
  grep -q KILL "$TMLOG" && fail "unstable target killed a window"
  [ -d "$WORK/wt7" ] || fail "unstable target removed worktree"
  [ ! -s "$GHLOG" ] || fail "unstable target wrote GitHub"
done
: > "$TMLOG"; : > "$GHLOG"
run_reap_tok 7 @9 @10 --yes
[ "$RC" = 4 ] && [ "$TOK" = refused:bad-args ] || fail "second target was ignored"
grep -q KILL "$TMLOG" && fail "multi-target call killed window"
grep -Fq 'dash-reap.sh {2}' "$BIN/tmux-dashboard.sh" || fail "dashboard must pass stable row field 2"

# #565: the Git gate says merged, but an active window is NEVER disposable.
# This must also hold for --yes, confirm and an already-queued --exec tail.
for st in working looping busy; do
  : > "$TMLOG"; : > "$GHLOG"
  REAP_STATE="$st" run_reap_tok 7 @9 --yes
  [ "$TOK" = skip:live ] && [ "$RC" = 3 ] || fail "active --yes must return skip:live"
  grep -q KILL "$TMLOG" && fail "active --yes killed a window"
  [ -d "$WORK/wt7" ] && [ "$(srows 7)" = 0 ] && [ ! -s "$GHLOG" ] \
    || fail "active --yes changed worktree/history/issue"
done
: > "$TMLOG"; : > "$GHLOG"
REAP_STATE=working run_reap_tok 7 @9 --exec full merged-pr
[ "$TOK" = skip:live ] && [ "$RC" = 3 ] || fail "--exec must recheck live state"
[ -d "$WORK/wt7" ] && [ "$(srows 7)" = 0 ] && [ ! -s "$GHLOG" ] \
  || fail "active --exec changed worktree/history/issue"
: > "$TMLOG"; : > "$GHLOG"
REAP_BG_STATE=working run_reap 7 @9 --bg >/dev/null
grep -q 'RUNSHELL .*@9.*--exec' "$TMLOG" || fail "deferred reap must pin the window id"
grep -q KILL "$TMLOG" && fail "queued reap killed a worker that resumed working"
[ -d "$WORK/wt7" ] && [ "$(srows 7)" = 0 ] && [ ! -s "$GHLOG" ] \
  || fail "queued reap changed worktree/history/issue"
: > "$TMLOG"; : > "$GHLOG"
RAW=1 REAP_STATE=looping run_reap_tok '' @9 --yes
[ "$TOK" = skip:live ] && [ "$RC" = 3 ] || fail "even a raw window with no worktree must protect live state"
grep -q KILL "$TMLOG" && fail "active ephemeral scratch was killed"
: > "$TMLOG"; : > "$GHLOG"
git -C "$BASEDIR" worktree add -q -b scratch-98 "$WORK/scratch-live" >/dev/null 2>&1
RAW=1 WT="$WORK/scratch-live" REAP_STATE=working run_reap_tok '' @9 --yes
[ "$TOK" = skip:live ] && [ "$RC" = 3 ] || fail "active clean scratch must return skip:live"
[ -d "$WORK/scratch-live" ] || fail "active clean scratch worktree was removed"
grep -q KILL "$TMLOG" && fail "active clean scratch window was killed"
: > "$TMLOG"; : > "$GHLOG"
printf y | REAP_STATE=working run_reap 7 @9 confirm >/dev/null
[ "$?" = 3 ] || fail "popup confirmation must not override live state"
grep -q KILL "$TMLOG" && fail "popup confirmation killed an active worker"

# A conf assignment need not be exported; the Python probe must still receive it.
REAL_REAP_PYTHON=$(command -v python3)
cat > "$WORK/fakepath/python3" <<'PYFAKE'
#!/bin/bash
case "${1:-}" in *fleet-reap-live.py) printf '%s' "${FLEET_REAP_MIN_AGE:-missing}" > "$REAP_ENV_LOG" ;; esac
exec "$REAL_REAP_PYTHON" "$@"
PYFAKE
chmod +x "$WORK/fakepath/python3"
mkdir -p "$WORK/noconf/fleets/s1"
printf 'FLEET_REAP_MIN_AGE=1234\n' > "$WORK/noconf/fleets/s1/conf"
REAP_ENV_LOG="$WORK/probe-age" REAL_REAP_PYTHON="$REAL_REAP_PYTHON" REAP_STATE=working \
  run_reap_tok 7 @9 --yes
[ "$(cat "$WORK/probe-age")" = 1234 ] || fail "non-exported per-fleet age was lost at Python boundary"
rm "$WORK/fakepath/python3" "$WORK/noconf/fleets/s1/conf"

# B1: no @issue (hub/panel) → refuse, no kill, no close
: > "$TMLOG"; : > "$GHLOG"
run_reap_tok "" "@9"
grep -q 'MSG.*no issue' "$TMLOG" || fail "no-issue row should refuse with 'no issue'"
[ "$TOK" = "refused:no-issue" ] || fail "a refusal must print refused:no-issue (got [$TOK]) (#596)"
[ "$RC" = 4 ] || fail "a refusal must exit 4, not a blanket 0 (got $RC) (#596)"
grep -q 'KILL' "$TMLOG" && fail "no-issue row must not kill a window"
[ -s "$GHLOG" ] && fail "no-issue row must not touch gh"

# B2: ⌃x on dirty (issue-3) → open a confirm popup, worktree kept, no kill (#289)
: > "$TMLOG"; : > "$GHLOG"
run_reap "3" "@9"
grep -q 'POPUP' "$TMLOG" || fail "dirty ⌃x should open a confirm popup"
grep -q 'KILL' "$TMLOG" && fail "dirty ⌃x must not kill the window before confirm"
[ -s "$GHLOG" ] && fail "dirty ⌃x must not touch gh before confirm"
[ -d "$WORK/wt3" ] || fail "dirty worktree must be kept"

# B3: ⌃x on clean+unmerged (issue-2) → open a confirm popup, worktree kept (#289)
: > "$TMLOG"; : > "$GHLOG"
run_reap "2" "@9"
grep -q 'POPUP' "$TMLOG" || fail "unmerged ⌃x should open a confirm popup"
grep -q 'KILL' "$TMLOG" && fail "unmerged ⌃x must not kill the window before confirm"
[ -d "$WORK/wt2" ] || fail "unmerged worktree must be kept"

# B4: ⌃x on clean+merged (issue-1, ancestor) → full reap, BACKGROUNDED (issue #304):
# the slow git remove + gh close run via run-shell -b (an --exec re-exec), so the ⌃x
# bind returns instantly; the fake tmux runs the dispatched command so we still see
# the effects.
: > "$TMLOG"; : > "$GHLOG"
run_reap "1" "@9" --bg
grep -q 'RUNSHELL .*--exec full' "$TMLOG" || fail "merged reap must be dispatched via run-shell -b (--exec full)"
[ -d "$WORK/wt1" ] && fail "merged worktree should be removed"
git -C "$BASEDIR" show-ref --verify -q refs/heads/issue-1 && fail "issue-1 branch should be deleted"
grep -q 'CLOSE' "$GHLOG" || fail "merged reap should close the issue"
grep -q 'KILL' "$TMLOG" || fail "merged reap should kill the window"
# #471: the GATE verdict rides along to the bg pass, which records the row BEFORE
# the removal. issue-1 is an ancestor (no PR) → a closed-unlanded row carrying the
# HEAD sha — the sha is the proof it was written while the worktree still stood.
grep -qE "RUNSHELL .*--exec full '?ancestor'?" "$TMLOG" || fail "the gate verdict must be threaded into the bg dispatch" "$(cat "$TMLOG")"
[ "$(srows 1)" = 1 ] || fail "⌃x on a worker must record ONE /fleet-history row" "$(cat "$LEDGER")"
[ "$(scol 1 10)" = closed-unlanded ] || fail "an ancestor reap must record a closed-unlanded row (got [$(scol 1 10)])" "$(cat "$LEDGER")"
case "$(scol 1 5)" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) fail "the row must carry the worktree HEAD sha (recorded pre-removal)" "$(cat "$LEDGER")" ;; esac

# B4b (#471): ⌃x on a clean row whose branch HAS a merged PR → `merged-pr` verdict →
# a LANDED row with the PR resolved from the branch (7700), recorded before the
# worktree is removed. This is the path that must not be re-derived in the bg pass.
: > "$TMLOG"; : > "$GHLOG"
run_reap "7" "@9" --bg
grep -qE "RUNSHELL .*--exec full '?merged-pr'?" "$TMLOG" || fail "a merged-PR reap must thread the merged-pr verdict" "$(cat "$TMLOG")"
[ -d "$WORK/wt7" ] && fail "merged-PR worktree should be removed"
[ "$(srows 7)" = 1 ] || fail "a merged-PR ⌃x must record ONE row" "$(cat "$LEDGER")"
[ "$(scol 7 10)" = landed ] || fail "a merged-PR reap must record a LANDED row (got [$(scol 7 10)])" "$(cat "$LEDGER")"
[ "$(scol 7 4)" = 7700 ] || fail "the landed row must carry the branch's resolved PR 7700 (got [$(scol 7 4)])" "$(cat "$LEDGER")"

# B4c (#471): a dispatch with NO verdict — an --exec string queued by a pre-#471
# install — records NOTHING rather than inventing a row kind. The reap itself still
# happens, so the upgrade is never a behavior regression.
: > "$TMLOG"; : > "$GHLOG"; rm -f "$TMLOG.killed"
ISS=8 TMLOG="$TMLOG" GHLOG="$GHLOG" \
FLEET_REPO="fake/repo" FLEET_MAIN="$BASEDIR" FLEET_BASE_BRANCH="$BASE_BR" \
FLEET_CONF_DIR="$WORK/noconf" TMPDIR="$WORK/rt" \
FLEET_HISTORY_LEDGER="$LEDGER" CLAUDE_PROJECTS_DIR="$PROJECTS" \
PATH="$WORK/fakepath:$PATH" \
  bash "$BIN/dash-reap.sh" "@9" --exec full
[ -d "$WORK/wt8" ] && fail "a verdict-less --exec must still reap the worktree"
[ "$(srows 8)" = 0 ] || fail "a verdict-less --exec must record NO row (no invented state)" "$(cat "$LEDGER")"

# B5: confirm y on dirty (issue-3) → KEEP worktree, close + kill only
: > "$TMLOG"; : > "$GHLOG"
printf 'y' | run_reap "3" "@9" confirm
[ -d "$WORK/wt3" ] || fail "confirmed reap on dirty must KEEP the worktree"
grep -q 'CLOSE' "$GHLOG" || fail "confirmed reap on dirty should close the issue"
grep -q 'KILL' "$TMLOG" || fail "confirmed reap on dirty should kill the window"
# #471: the confirm path threads its verdict too — a KEPT dirty worktree is exactly
# the resumable case the ledger row exists for.
grep -qE "RUNSHELL .*--exec keep '?dirty'?" "$TMLOG" || fail "the confirm path must thread the dirty verdict" "$(cat "$TMLOG")"
[ "$(srows 3)" = 1 ] || fail "a confirmed dirty reap must record ONE closed-unlanded row" "$(cat "$LEDGER")"
[ "$(scol 3 10)" = closed-unlanded ] || fail "a dirty reap row must be closed-unlanded (got [$(scol 3 10)])"

# B6: confirm y on clean+unmerged (issue-2) → full reap (relaxes merged)
: > "$TMLOG"; : > "$GHLOG"
printf 'y' | run_reap "2" "@9" confirm
[ -d "$WORK/wt2" ] && fail "confirmed reap on clean+unmerged should remove the worktree"
git -C "$BASEDIR" show-ref --verify -q refs/heads/issue-2 && fail "issue-2 branch should be deleted"
grep -q 'CLOSE' "$GHLOG" || fail "confirmed reap should close the issue"
# #471: a force-reaped unmerged worker is indexed WITH its sha before the removal.
# (That sha lives only until git gc prunes the now-unreachable commit — documented
# in dash-reap.sh's reap_record; the row is still strictly better than none.)
[ "$(srows 2)" = 1 ] || fail "a confirmed unmerged reap must record ONE row" "$(cat "$LEDGER")"
case "$(scol 2 5)" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) fail "the unmerged reap row must carry the HEAD sha (recorded pre-removal)" "$(cat "$LEDGER")" ;; esac

# B7: confirm 'n' (cancel) → no side effects
git -C "$BASEDIR" worktree add -q -b issue-4 "$WORK/wt4" >/dev/null 2>&1
: > "$TMLOG"; : > "$GHLOG"
printf 'n' | run_reap "4" "@9" confirm
[ -d "$WORK/wt4" ] || fail "cancelled reap must keep the worktree"
grep -q 'KILL' "$TMLOG" && fail "cancelled reap must not kill the window"
[ -s "$GHLOG" ] && fail "cancelled reap must not touch gh"
[ "$(srows 4)" = 0 ] || fail "a CANCELLED reap must not record a row (the session is still live)" "$(cat "$LEDGER")"

# B8: ⌃x on a raw scratch row (@raw=1, no @issue, no @worktree) → DEGRADE to the
# pre-#290 behavior: just close the window. No refuse, and nothing issue-bound is
# touched (no gh).
: > "$TMLOG"; : > "$GHLOG"
rows_before="$(wc -l < "$LEDGER" | tr -d ' ')"   # the worker cases above populated it (#471)
RAW=1 WID='@9' WT='' run_reap "" "@9"
grep -q 'KILL' "$TMLOG" || fail "raw ⌃x (no worktree) should kill the scratch window"
grep -qi 'nothing to reap' "$TMLOG" && fail "raw ⌃x must not refuse (no 'nothing to reap')"
grep -qi 'MSG.*closed scratch' "$TMLOG" || fail "raw ⌃x should report 'closed scratch'"
[ -s "$GHLOG" ] && fail "raw ⌃x (no worktree) must not touch gh (no issue/PR lifecycle)"
[ "$(wc -l < "$LEDGER" | tr -d ' ')" = "$rows_before" ] \
  || fail "raw ⌃x with no worktree has nothing to index — no NEW ledger row" "$(cat "$LEDGER")"

# Zero-commit issue and scratch: no automatic disposal, even with state=done.
# No client means a clear refusal instead of an unanswered popup.
: > "$TMLOG"; : > "$GHLOG"
CLIENTS="" run_reap_tok 17 @9
[ "$RC" = 3 ] && [ "$TOK" = skip:needs-confirm ] || fail "zero-commit worker must need confirmation"
[ -d "$WORK/wt17" ] || fail "zero-commit worker worktree must survive"
git -C "$BASEDIR" show-ref --verify -q refs/heads/issue-17 || fail "zero-commit branch must survive"
grep -q KILL "$TMLOG" && fail "zero-commit worker window must survive"
grep -q CLOSE "$GHLOG" && fail "zero-commit worker issue must stay open"
git -C "$BASEDIR" worktree add -q -b scratch-17 "$WORK/scr17" >/dev/null 2>&1
: > "$TMLOG"; : > "$GHLOG"
CLIENTS="" RAW=1 WID='@9' WT="$WORK/scr17" run_reap_tok '' @9
[ "$RC" = 3 ] && [ "$TOK" = skip:needs-confirm ] || fail "zero-commit scratch must need confirmation"
[ -d "$WORK/scr17" ] || fail "zero-commit scratch must survive"
grep -q KILL "$TMLOG" && fail "zero-commit scratch window must survive"

# B8b: ⌃x on a scratch row WITH a clean+ancestor worktree (issue #290) → close the
# window AND remove the scratch worktree + branch. No issue/gh close (scratch has
# no issue). Build a clean scratch at the already-merged strict ancestor.
git -C "$BASEDIR" worktree add -q -b scratch-9 "$WORK/scr9" "$H1" >/dev/null 2>&1
transcript_for "$WORK/scr9" 9
: > "$TMLOG"; : > "$GHLOG"
RAW=1 WID='@9' WT="$WORK/scr9" run_reap "" "@9"
grep -q 'KILL' "$TMLOG" || fail "scratch ⌃x should kill the window"
grep -qi 'MSG.*worktree reaped' "$TMLOG" || fail "scratch ⌃x (clean) should report 'worktree reaped'"
[ -d "$WORK/scr9" ] && fail "clean scratch ⌃x should remove the worktree"
git -C "$BASEDIR" show-ref --verify -q refs/heads/scratch-9 && fail "clean scratch ⌃x should delete the branch"
grep -q 'CLOSE' "$GHLOG" && fail "scratch reap must NOT close any issue (no @issue)"
# …and the session is INDEXED before that disposal (issue #466): one row keyed by the
# scratch slug, carrying the HEAD sha `resume` rebuilds the worktree from. Recording
# after the remove would strand the transcript — hence "record before remove".
[ "$(srows scratch-9)" = 1 ] || fail "clean scratch ⌃x must record ONE /fleet-history row (scratch-9)" "$(cat "$LEDGER")"
awk -F'\t' '$2=="scratch-9"{exit !($5 ~ /^[0-9a-f]{7,}$/)}' "$LEDGER" \
  || fail "the scratch-9 row must carry the worktree HEAD sha (recorded pre-removal)" "$(cat "$LEDGER")"

# B8c: ⌃x on a scratch row WITH a DIRTY worktree → open a confirm POPUP first (#289
# one-key rule); do NOT close the window or touch the worktree yet.
git -C "$BASEDIR" worktree add -q -b scratch-10 "$WORK/scr10" >/dev/null 2>&1
printf 'exp\n' > "$WORK/scr10/untracked"
: > "$TMLOG"; : > "$GHLOG"
RAW=1 WID='@9' WT="$WORK/scr10" run_reap "" "@9"
grep -q 'POPUP' "$TMLOG" || fail "dirty scratch ⌃x should open a confirm popup"
grep -q 'KILL' "$TMLOG" && fail "dirty scratch ⌃x must not close the window before confirm"
[ -d "$WORK/scr10" ] || fail "dirty scratch ⌃x must KEEP the worktree"

# A refused scratch popup must also fall back without disposing on cancel.
: > "$TMLOG"; : > "$GHLOG"
TOK=$(printf n | REFUSE_POPUP=1 RAW=1 WID='@9' WT="$WORK/scr10" run_reap "" "@9")
case "$TOK" in *'[y] reap'*) ;; *) fail "refused scratch popup never reached the inline prompt" ;; esac
grep -q KILL "$TMLOG" && fail "declining scratch fallback killed the window"
[ -d "$WORK/scr10" ] || fail "declining scratch fallback removed the worktree"

# B8d: confirm y on the DIRTY scratch → still KEEP the worktree, close the window
# only (git refuses a dirty remove; a confirmed reap never destroys uncommitted work).
: > "$TMLOG"; : > "$GHLOG"
transcript_for "$WORK/scr10" 10
printf 'y' | RAW=1 WID='@9' WT="$WORK/scr10" run_reap "" "@9" confirm
[ -d "$WORK/scr10" ] || fail "confirmed reap on a dirty scratch must KEEP the worktree"
grep -q 'KILL' "$TMLOG" || fail "confirmed reap on a dirty scratch should close the window"
[ "$(srows scratch-10)" = 1 ] || fail "a confirmed dirty-scratch reap must still index the session" "$(cat "$LEDGER")"

# B8e: confirm y on a clean+unmerged scratch → remove worktree + branch, close window.
git -C "$BASEDIR" worktree add -q -b scratch-11 "$WORK/scr11" >/dev/null 2>&1
printf 'x\n' > "$WORK/scr11/g"; git -C "$WORK/scr11" add g; git -C "$WORK/scr11" commit -qm work
transcript_for "$WORK/scr11" 11
: > "$TMLOG"; : > "$GHLOG"
printf 'y' | RAW=1 WID='@9' WT="$WORK/scr11" run_reap "" "@9" confirm
[ -d "$WORK/scr11" ] && fail "confirmed reap on a clean+unmerged scratch should remove the worktree"
git -C "$BASEDIR" show-ref --verify -q refs/heads/scratch-11 && fail "confirmed reap should delete the scratch branch"
[ "$(srows scratch-11)" = 1 ] || fail "a confirmed scratch reap must index the session before disposing of it" "$(cat "$LEDGER")"

# B9: hub/panel row with @raw explicitly 0 (not a scratch) still refuses — the
# raw early-return keys on @raw=1 exactly, not merely "@raw set".
: > "$TMLOG"; : > "$GHLOG"
RAW=0 run_reap "" "@9"
grep -qi 'MSG.*no issue' "$TMLOG" || fail "@raw=0 hub row should still refuse ('no issue')"
grep -q 'KILL' "$TMLOG" && fail "@raw=0 hub row must not kill a window"

# --- D. the NON-INTERACTIVE entry (issue #596) --------------------------------
# `dash-reap.sh <handle>` is documented as a script interface (fleet-keys.sh), but
# it used to answer a dirty/unmerged row by opening a confirm popup on whatever
# client the operator was looking at and returning `exit 0` — so a script both
# interrupted a human who had pressed nothing AND read "reaped" off a row that was
# still sitting there. Fresh fixtures throughout: these cases reap for real, and
# reusing B's worktrees would silently pre-satisfy its assertions.
git -C "$BASEDIR" worktree add -q -b issue-12 "$WORK/wt12" >/dev/null 2>&1
printf 'c\n' > "$WORK/wt12/j"; git -C "$WORK/wt12" add j; git -C "$WORK/wt12" commit -qm w12
printf 'dirt\n' > "$WORK/wt12/untracked"                       # dirty
git -C "$BASEDIR" worktree add -q -b issue-13 "$WORK/wt13" >/dev/null 2>&1
printf 'c\n' > "$WORK/wt13/j"; git -C "$WORK/wt13" add j; git -C "$WORK/wt13" commit -qm w13
git -C "$BASEDIR" worktree add -q -b issue-14 "$WORK/wt14" "$H1" >/dev/null 2>&1   # strict ancestor
git -C "$BASEDIR" worktree add -q -b issue-15 "$WORK/wt15" >/dev/null 2>&1
printf 'dirt\n' > "$WORK/wt15/untracked"                       # dirty, never reaped below
git -C "$BASEDIR" worktree add -q -b issue-16 "$WORK/wt16" >/dev/null 2>&1
printf 'dirt\n' > "$WORK/wt16/untracked"                       # dirty, for the --force alias
for n in 12 13 14 15 16; do transcript_for "$WORK/wt$n" "$n"; done

# D1: --yes on a DIRTY row → the confirm branch, unasked: worktree KEPT, window +
# issue closed, NO popup. Same semantics as a confirmed ⌃x — --yes skips the
# question, never the dirty-worktree protection.
: > "$TMLOG"; : > "$GHLOG"
run_reap_tok "12" "@9" --yes
grep -q 'POPUP' "$TMLOG" && fail "--yes on dirty must NOT open a confirm popup (#596)"
[ -d "$WORK/wt12" ] || fail "--yes on dirty must KEEP the worktree (#596)"
grep -q 'KILL' "$TMLOG" || fail "--yes on dirty should kill the window (#596)"
grep -q 'CLOSE' "$GHLOG" || fail "--yes on dirty should close the issue (#596)"
[ "$TOK" = "reaped:keep" ] || fail "--yes on dirty must print reaped:keep (got [$TOK]) (#596)"
[ "$RC" = 0 ] || fail "--yes on dirty must exit 0 (got $RC) (#596)"
[ "$(srows 12)" = 1 ] || fail "--yes must still record ONE /fleet-history row (#471+#596)" "$(cat "$LEDGER")"
[ "$(scol 12 10)" = closed-unlanded ] || fail "a --yes dirty reap row must be closed-unlanded (got [$(scol 12 10)])"

# D2: --yes on a clean+unmerged row → full reap (worktree + branch + issue), no popup.
: > "$TMLOG"; : > "$GHLOG"
run_reap_tok "13" "@9" --yes 2>"$WORK/description"
grep -q 'reap target: window=@9 .*issue=13 .*state=.*worktree=.*reason=unmerged' "$WORK/description" || fail "missing disposal target description"
grep -q 'POPUP' "$TMLOG" && fail "--yes on unmerged must NOT open a confirm popup (#596)"
[ -d "$WORK/wt13" ] && fail "--yes on clean+unmerged should remove the worktree (#596)"
git -C "$BASEDIR" show-ref --verify -q refs/heads/issue-13 && fail "--yes should delete the issue-13 branch (#596)"
grep -q 'CLOSE' "$GHLOG" || fail "--yes on unmerged should close the issue (#596)"
[ "$TOK" = "reaped:full" ] || fail "--yes on unmerged must print reaped:full (got [$TOK]) (#596)"
[ "$RC" = 0 ] || fail "--yes on unmerged must exit 0 (got $RC) (#596)"

# D3: no --yes and NO attached client → never draw a popup nobody can press, and
# say so instead of returning a blanket success. Nothing is touched.
: > "$TMLOG"; : > "$GHLOG"
CLIENTS="" run_reap_tok "15" "@9"
grep -q 'POPUP' "$TMLOG" && fail "a headless fleet must NOT get a confirm popup (#596)"
grep -q 'KILL' "$TMLOG" && fail "a refused confirm must not kill the window (#596)"
[ -s "$GHLOG" ] && fail "a refused confirm must not touch gh (#596)"
[ -d "$WORK/wt15" ] || fail "a refused confirm must keep the worktree (#596)"
[ "$TOK" = "skip:needs-confirm" ] || fail "a headless dirty row must print skip:needs-confirm (got [$TOK]) (#596)"
[ "$RC" = 3 ] || fail "skip:needs-confirm must exit 3, not 0 (got $RC) (#596)"
[ "$(srows 15)" = 0 ] || fail "a refused confirm must record no ledger row (#596)" "$(cat "$LEDGER")"

# D4: no --yes but a client IS attached → the historic confirm popup still opens
# (⌃x is unchanged), yet the CALLER now learns it reaped nothing.
: > "$TMLOG"; : > "$GHLOG"
run_reap_tok "15" "@9"
grep -q 'POPUP' "$TMLOG" || fail "an attached client should still get the ⌃x confirm popup (#289)"
grep -q 'KILL' "$TMLOG" && fail "the popup pass must not kill the window itself"
[ "$TOK" = "skip:needs-confirm" ] || fail "the popup pass must report skip:needs-confirm (got [$TOK]) (#596)"
[ "$RC" = 3 ] || fail "the popup pass must exit 3 — it reaped nothing (got $RC) (#596)"

# Refused popup must expose the actual confirm inline; declining it stays safe.
: > "$TMLOG"; : > "$GHLOG"
TOK=$(printf n | REFUSE_POPUP=1 run_reap "15" "@9"); RC=$?
case "$TOK" in *'[y] reap'*) ;; *) fail "refused issue popup never reached the inline prompt" ;; esac
[ "$RC" = 3 ] || fail "refused issue popup lost its dispatch result"
grep -q KILL "$TMLOG" && fail "declining inline confirm killed the issue window"
[ -s "$GHLOG" ] && fail "declining inline confirm closed an issue"
[ -d "$WORK/wt15" ] || fail "declining inline confirm removed the worktree"

# D5: --yes on a clean+merged row → reaped SYNCHRONOUSLY. The ⌃x path backgrounds
# this (issue #304) so the bind returns instantly, but a script's `reaped:full`
# must mean DONE, not "dispatched" — hence no run-shell re-exec here.
: > "$TMLOG"; : > "$GHLOG"
run_reap_tok "14" "@9" --yes
grep -q 'RUNSHELL' "$TMLOG" && fail "--yes must reap in the foreground, not via run-shell (#596)"
[ -d "$WORK/wt14" ] && fail "--yes on a merged row should remove the worktree (#596)"
grep -q 'CLOSE' "$GHLOG" || fail "--yes on a merged row should close the issue (#596)"
[ "$TOK" = "reaped:full" ] || fail "--yes on a merged row must print reaped:full (got [$TOK]) (#596)"
[ "$(srows 14)" = 1 ] || fail "the synchronous --yes reap must still record its row (#471+#596)" "$(cat "$LEDGER")"

# D6: --force is an alias for --yes.
: > "$TMLOG"; : > "$GHLOG"
run_reap_tok "16" "@9" --force
grep -q 'POPUP' "$TMLOG" && fail "--force must behave like --yes (no popup) (#596)"
[ -d "$WORK/wt16" ] || fail "--force on dirty must KEEP the worktree (#596)"
[ "$TOK" = "reaped:keep" ] || fail "--force must print reaped:keep (got [$TOK]) (#596)"

# D7: the SCRATCH path gets the same treatment — dirty + --yes disposes without a
# popup (worktree still KEPT), and a headless fleet refuses instead of popping.
git -C "$BASEDIR" worktree add -q -b scratch-12 "$WORK/scr12" >/dev/null 2>&1
printf 'exp\n' > "$WORK/scr12/untracked"
transcript_for "$WORK/scr12" 112   # a session id of its own: record-closed dedups on it
: > "$TMLOG"; : > "$GHLOG"
CLIENTS="" RAW=1 WID='@9' WT="$WORK/scr12" run_reap_tok "" "@9"
grep -q 'POPUP' "$TMLOG" && fail "a headless dirty scratch must NOT get a popup (#596)"
grep -q 'KILL' "$TMLOG" && fail "a refused scratch confirm must not close the window (#596)"
[ "$TOK" = "skip:needs-confirm" ] || fail "a headless dirty scratch must print skip:needs-confirm (got [$TOK]) (#596)"
[ "$RC" = 3 ] || fail "a headless dirty scratch must exit 3 (got $RC) (#596)"
: > "$TMLOG"; : > "$GHLOG"
RAW=1 WID='@9' WT="$WORK/scr12" run_reap_tok "" "@9" --yes
grep -q 'POPUP' "$TMLOG" && fail "--yes on a dirty scratch must NOT open a popup (#596)"
grep -q 'KILL' "$TMLOG" || fail "--yes on a dirty scratch should close the window (#596)"
[ -d "$WORK/scr12" ] || fail "--yes on a dirty scratch must KEEP the worktree (#596)"
[ "$TOK" = "reaped:keep" ] || fail "--yes on a dirty scratch must print reaped:keep (got [$TOK]) (#596)"
[ "$(srows scratch-12)" = 1 ] || fail "a --yes scratch disposal must index the session (#466+#596)" "$(cat "$LEDGER")"

# --- E. sleepers + truthful results (issue #1244) ------------------------------
# Every fixture is a clean strict ancestor of base (merged, no confirm needed).
for n in 20 21 22 23 24 25; do
  git -C "$BASEDIR" worktree add -q -b "issue-$n" "$WORK/wt$n" "$H1" >/dev/null 2>&1
  transcript_for "$WORK/wt$n" "$n"
done
# fake python3: `fleet-sleep.py dispose` is logged (DISPOSE_FAILS=1 refuses it);
# REAP_LIVE_PASSES=<n> lets the first n liveness probes pass and fails the rest —
# the shape of #1244's foreground-passes / tail-refuses split. Else the real one.
REAL_PY=$(command -v python3)
cat > "$WORK/fakepath/python3" <<PYFAKE
#!/bin/bash
case "\${1:-}" in
  *fleet-sleep.py)
    printf 'SLEEP %s\n' "\$*" >> "$TMLOG"
    [ "\${DISPOSE_FAILS:-0}" = 1 ] && { echo 'fleet-sleep: a wake raced us' >&2; exit 1; }
    exit 0 ;;
  *fleet-reap-live.py)
    if [ -n "\${REAP_LIVE_PASSES:-}" ]; then
      c=\$(( \$(cat "$WORK/probes" 2>/dev/null || echo 0) + 1 )); echo "\$c" > "$WORK/probes"
      [ "\$c" -le "\$REAP_LIVE_PASSES" ] && exit 0
      echo 'young-agent:codex:53s<1800s'; exit 1
    fi ;;
esac
exec "$REAL_PY" "\$@"
PYFAKE
chmod +x "$WORK/fakepath/python3"

# E1: a SLEEPING merged worker is reaped WITHOUT a wake — sleep record retired
# before the kill, window gone, worktree removed, history row written.
: > "$TMLOG"; : > "$GHLOG"
LIFE=sleeping REAP_STATE="done" run_reap_tok 20 @9
[ "$TOK" = reaped:full ] && [ "$RC" = 0 ] || fail "sleeping merged worker must reap (got [$TOK] rc $RC)" "$(cat "$TMLOG")"
grep -q 'SLEEP .* dispose ' "$TMLOG" || fail "the sleep record must be retired before the kill"
grep -q 'SLEEP .* wake ' "$TMLOG" && fail "a sleeper must never be woken to be reaped"
awk '/^SLEEP .* dispose /{d=NR} /^KILL/{k=NR} END{exit !(d && k && d<k)}' "$TMLOG" \
  || fail "dispose must precede kill-window" "$(cat "$TMLOG")"
[ -d "$WORK/wt20" ] && fail "sleeping merged worktree should be removed"
[ "$(srows 20)" = 1 ] || fail "a sleeper reap must record ONE /fleet-history row" "$(cat "$LEDGER")"

# E2: a sleeper under a reap HOLD is retained — ⌃x, --yes, everything.
: > "$TMLOG"; : > "$GHLOG"
LIFE=sleeping HOLD=1 run_reap_tok 21 @9 --yes 2>"$WORK/hold-err"
[ "$TOK" = skip:live ] && [ "$RC" = 3 ] || fail "a held sleeper must be retained (got [$TOK] rc $RC)"
grep -q 'retained:hold' "$WORK/hold-err" || fail "the refusal must name the hold" "$(cat "$WORK/hold-err")"
grep -q KILL "$TMLOG" && fail "a held sleeper was killed"
[ -d "$WORK/wt21" ] && [ "$(srows 21)" = 0 ] || fail "a held sleeper lost its worktree / got a row"
# ...and the transitional phases stay retained as before.
LIFE=waking run_reap_tok 21 @9 --yes 2>/dev/null
[ "$TOK" = skip:live ] || fail "a waking worker must stay retained"

# E3: a refused sleep-record retirement (a wake raced us) → failed, nothing killed.
: > "$TMLOG"; : > "$GHLOG"
LIFE=sleeping DISPOSE_FAILS=1 run_reap_tok 22 @9
[ "$TOK" = failed:sleep-record ] && [ "$RC" = 5 ] || fail "refused dispose must fail loudly (got [$TOK] rc $RC)"
grep -q KILL "$TMLOG" && fail "refused dispose still killed the window"
[ -d "$WORK/wt22" ] || fail "refused dispose removed the worktree"

# E4: the gate passes in the foreground but the disposal tail's own gate refuses
# (#1244's `FLEET_REAP_MIN_AGE=0 dash-reap.sh @65`): a script caller runs the tail
# SYNCHRONOUSLY, so it exits non-zero and never prints reaped:full.
: > "$TMLOG"; : > "$GHLOG"; rm -f "$WORK/probes"
REAP_LIVE_PASSES=2 run_reap_tok 23 @9 2>"$WORK/tail-err"
[ "$RC" != 0 ] && [ "$TOK" != reaped:full ] || fail "a tail refusal was reported as success (got [$TOK] rc $RC)"
[ "$TOK" = skip:live ] || fail "a tail refusal must print skip:live (got [$TOK])"
grep -q 'young-agent' "$WORK/tail-err" || fail "the refusal must name its reason" "$(cat "$WORK/tail-err")"
grep -q 'RUNSHELL' "$TMLOG" && fail "a script caller's merged reap must not be backgrounded"
grep -q KILL "$TMLOG" && fail "a refused tail killed the window"
[ -d "$WORK/wt23" ] || fail "a refused tail removed the worktree"

# E5: the dash bind (--bg) is told `dispatched:full`, never `reaped:full`, and an
# inline FLEET_REAP_MIN_AGE override reaches the backgrounded tail's gate.
: > "$TMLOG"; : > "$GHLOG"
FLEET_REAP_MIN_AGE=0 run_reap_tok 24 @9 --bg
[ "$TOK" = dispatched:full ] || fail "--bg must print dispatched:full (got [$TOK])"
grep -q 'RUNSHELL .*FLEET_REAP_MIN_AGE=0 bash .*--exec full' "$TMLOG" \
  || fail "the age override must be forwarded into the bg tail" "$(cat "$TMLOG")"
[ -d "$WORK/wt24" ] && fail "the dispatched bg reap should still remove the worktree"

# E6: kill-window that leaves the window standing → failed:kill-window, the
# worktree + issue untouched.
: > "$TMLOG"; : > "$GHLOG"
KILL_FAILS=1 run_reap_tok 25 @9
[ "$TOK" = failed:kill-window ] && [ "$RC" = 5 ] || fail "a surviving window must report failed:kill-window (got [$TOK] rc $RC)"
[ -d "$WORK/wt25" ] || fail "a failed kill must not remove the worktree"
[ -s "$GHLOG" ] && fail "a failed kill must not close the issue"
rm -f "$WORK/fakepath/python3"

# --- C. interactive terminal handoff (#451), asynchronous cleanup (#304) ------
# execute() yields fzf's terminal for the inline confirm. B4 above still asserts
# that the slow teardown is dispatched via run-shell -b after authorization.
DASH="$BIN/tmux-dashboard.sh"
grep -Fq '$DASH_KEY_REAP:execute(' "$DASH" \
  || fail "reap bind must hand the terminal to its inline confirm (#451)"
grep -Fq 'dash-reap.sh {2} --bg)' "$DASH" \
  || fail "the dash bind must ask for the backgrounded tail explicitly (#1244)"

printf 'selftest PASS: reap gates, confirmation/cancel, ledger, async cleanup, CLI results, refused-popup fallback\n'
exit 0
