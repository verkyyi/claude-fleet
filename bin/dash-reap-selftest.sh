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
#        • ⌃x on a raw scratch row (@raw=1, no @issue) — issue #290 the scratch owns
#          a `scratch-<N>` worktree (resolved via @worktree), reaped by the SAME
#          one-key ⌃x rule (issue #289):
#            - clean+ancestor  → window closed + worktree/branch removed (no confirm)
#            - dirty/unmerged  → confirm POPUP first; confirm y keeps a dirty wt but
#                                removes a clean+unmerged one; the window closes
#            - no @worktree    → degrade: just close the window (pre-#290 behavior)
#          Nothing issue-bound is touched; the summary-cache seed is removed.
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
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# --- build a real base checkout + worktrees -----------------------------------
BASEDIR="$WORK/base"
git init -q "$BASEDIR"
git -C "$BASEDIR" config user.email t@t; git -C "$BASEDIR" config user.name t
printf 'seed\n' > "$BASEDIR/f"; git -C "$BASEDIR" add f; git -C "$BASEDIR" commit -qm seed
BASE_BR="$(git -C "$BASEDIR" branch --show-current)"
MASTER="$(git -C "$BASEDIR" rev-parse HEAD)"

# issue-1: clean, tip == base ⇒ ancestor-of-base
git -C "$BASEDIR" worktree add -q -b issue-1 "$WORK/wt1" >/dev/null 2>&1
H1="$(git -C "$WORK/wt1" rev-parse HEAD)"
# issue-2: clean, one extra commit NOT on base ⇒ not merged
git -C "$BASEDIR" worktree add -q -b issue-2 "$WORK/wt2" >/dev/null 2>&1
printf 'x\n' > "$WORK/wt2/g"; git -C "$WORK/wt2" add g; git -C "$WORK/wt2" commit -qm work
H2="$(git -C "$WORK/wt2" rev-parse HEAD)"
# issue-3: dirty (untracked file), extra commit too
git -C "$BASEDIR" worktree add -q -b issue-3 "$WORK/wt3" >/dev/null 2>&1
printf 'y\n' > "$WORK/wt3/h"; git -C "$WORK/wt3" add h; git -C "$WORK/wt3" commit -qm work3
printf 'dirt\n' > "$WORK/wt3/untracked"
H3="$(git -C "$WORK/wt3" rev-parse HEAD)"

# --- A. fleet_reap_ok direct assertions ---------------------------------------
. "$BIN/fleet-lib.sh"

chk() { # <label> <expect-token> <expect-rc> ... args to fleet_reap_ok
  local label="$1" want="$2" wantrc="$3"; shift 3
  local got rc
  got="$(fleet_reap_ok "$@")"; rc=$?
  [ "$got" = "$want" ] || fail "fleet_reap_ok $label: got '$got' want '$want'"
  [ "$rc" = "$wantrc" ] || fail "fleet_reap_ok $label: rc $rc want $wantrc"
}

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
  sh -c "$1"
  exit 0
fi
case "$*" in
  *@raw*)         printf '%s\n' "${RAW:-}" ;;
  *@worktree*)    printf '%s\n' "${WT:-}" ;;         # scratch worktree path (#290)
  *@issue*)       printf '%s\n' "${ISS:-}" ;;
  *pane_current_path*) printf '%s\n' "${WT:-}" ;;
  *window_id*)    printf '%s\n' "${WID:-@9}" ;;
  *session_name*) printf 's1\n' ;;
  *kill-window*)  printf 'KILL %s\n' "$*" >> "$TMLOG" ;;
  *display-popup*) printf 'POPUP %s\n' "$*" >> "$TMLOG" ;;
  *)              printf 'MSG %s\n' "$*" >> "$TMLOG" ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

# fake gh: pr list → empty (rely on ancestor); issue view → OPEN; issue close → log.
cat > "$WORK/fakepath/gh" <<'FAKE'
#!/bin/bash
case "$*" in
  *"pr list"*)     : ;;
  *"issue view"*)  printf 'OPEN\n' ;;
  *"issue close"*) printf 'CLOSE %s\n' "$*" >> "$GHLOG" ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/gh"

run_reap() { # <ISS> <args...> — run dash-reap with the fakes + this base checkout
  local iss="$1"; shift
  # RAW/WID feed the fake tmux's @raw/window_id answers (empty RAW ⇒ not a raw row).
  # TMPDIR is redirected under $WORK so fleet-lib's cache dir (FLEET_C) — and the
  # raw path's summary-cache rm — stay hermetic (never touch the real cache).
  ISS="$iss" RAW="${RAW:-}" WID="${WID:-}" WT="${WT:-}" TMLOG="$TMLOG" GHLOG="$GHLOG" \
  FLEET_REPO="fake/repo" FLEET_MAIN="$BASEDIR" FLEET_BASE_BRANCH="$BASE_BR" \
  FLEET_CONF_DIR="$WORK/noconf" TMPDIR="$WORK/rt" \
  PATH="$WORK/fakepath:$PATH" \
    bash "$BIN/dash-reap.sh" "$@"
}

# B1: no @issue (hub/panel) → refuse, no kill, no close
: > "$TMLOG"; : > "$GHLOG"
run_reap "" "s1:9"
grep -q 'MSG.*no issue' "$TMLOG" || fail "no-issue row should refuse with 'no issue'"
grep -q 'KILL' "$TMLOG" && fail "no-issue row must not kill a window"
[ -s "$GHLOG" ] && fail "no-issue row must not touch gh"

# B2: ⌃x on dirty (issue-3) → open a confirm popup, worktree kept, no kill (#289)
: > "$TMLOG"; : > "$GHLOG"
run_reap "3" "s1:3"
grep -q 'POPUP' "$TMLOG" || fail "dirty ⌃x should open a confirm popup"
grep -q 'KILL' "$TMLOG" && fail "dirty ⌃x must not kill the window before confirm"
[ -s "$GHLOG" ] && fail "dirty ⌃x must not touch gh before confirm"
[ -d "$WORK/wt3" ] || fail "dirty worktree must be kept"

# B3: ⌃x on clean+unmerged (issue-2) → open a confirm popup, worktree kept (#289)
: > "$TMLOG"; : > "$GHLOG"
run_reap "2" "s1:2"
grep -q 'POPUP' "$TMLOG" || fail "unmerged ⌃x should open a confirm popup"
grep -q 'KILL' "$TMLOG" && fail "unmerged ⌃x must not kill the window before confirm"
[ -d "$WORK/wt2" ] || fail "unmerged worktree must be kept"

# B4: ⌃x on clean+merged (issue-1, ancestor) → full reap, BACKGROUNDED (issue #304):
# the slow git remove + gh close run via run-shell -b (an --exec re-exec), so the ⌃x
# bind returns instantly; the fake tmux runs the dispatched command so we still see
# the effects.
: > "$TMLOG"; : > "$GHLOG"
run_reap "1" "s1:1"
grep -q 'RUNSHELL .*--exec full' "$TMLOG" || fail "merged reap must be dispatched via run-shell -b (--exec full)"
[ -d "$WORK/wt1" ] && fail "merged worktree should be removed"
git -C "$BASEDIR" show-ref --verify -q refs/heads/issue-1 && fail "issue-1 branch should be deleted"
grep -q 'CLOSE' "$GHLOG" || fail "merged reap should close the issue"
grep -q 'KILL' "$TMLOG" || fail "merged reap should kill the window"

# B5: confirm y on dirty (issue-3) → KEEP worktree, close + kill only
: > "$TMLOG"; : > "$GHLOG"
printf 'y' | run_reap "3" "s1:3" confirm
[ -d "$WORK/wt3" ] || fail "confirmed reap on dirty must KEEP the worktree"
grep -q 'CLOSE' "$GHLOG" || fail "confirmed reap on dirty should close the issue"
grep -q 'KILL' "$TMLOG" || fail "confirmed reap on dirty should kill the window"

# B6: confirm y on clean+unmerged (issue-2) → full reap (relaxes merged)
: > "$TMLOG"; : > "$GHLOG"
printf 'y' | run_reap "2" "s1:2" confirm
[ -d "$WORK/wt2" ] && fail "confirmed reap on clean+unmerged should remove the worktree"
git -C "$BASEDIR" show-ref --verify -q refs/heads/issue-2 && fail "issue-2 branch should be deleted"
grep -q 'CLOSE' "$GHLOG" || fail "confirmed reap should close the issue"

# B7: confirm 'n' (cancel) → no side effects
git -C "$BASEDIR" worktree add -q -b issue-4 "$WORK/wt4" >/dev/null 2>&1
: > "$TMLOG"; : > "$GHLOG"
printf 'n' | run_reap "4" "s1:4" confirm
[ -d "$WORK/wt4" ] || fail "cancelled reap must keep the worktree"
grep -q 'KILL' "$TMLOG" && fail "cancelled reap must not kill the window"
[ -s "$GHLOG" ] && fail "cancelled reap must not touch gh"

# B8: ⌃x on a raw scratch row (@raw=1, no @issue, no @worktree) → DEGRADE to the
# pre-#290 behavior: just close the window. No refuse, the dash summary-cache seed
# is removed, and nothing issue-bound is touched (no gh). The summary key mirrors
# dash-raw-session.sh: fleet_summary_key <session s1> <window @9> = s1_9.
CACHE="$WORK/rt/.claude-dash/global"; mkdir -p "$CACHE"
SEED="$CACHE/summary_s1_9"; printf 'scratch (raw session)' > "$SEED"
: > "$TMLOG"; : > "$GHLOG"
RAW=1 WID='@9' WT='' run_reap "" "s1:9"
grep -q 'KILL' "$TMLOG" || fail "raw ⌃x (no worktree) should kill the scratch window"
grep -qi 'nothing to reap' "$TMLOG" && fail "raw ⌃x must not refuse (no 'nothing to reap')"
grep -qi 'MSG.*closed scratch' "$TMLOG" || fail "raw ⌃x should report 'closed scratch'"
[ -e "$SEED" ] && fail "raw ⌃x should remove the summary-cache seed"
[ -s "$GHLOG" ] && fail "raw ⌃x (no worktree) must not touch gh (no issue/PR lifecycle)"

# B8b: ⌃x on a scratch row WITH a clean+ancestor worktree (issue #290) → close the
# window AND remove the scratch worktree + branch. No issue/gh close (scratch has
# no issue). Build a real `scratch-9` worktree, clean, tip == base ⇒ ancestor.
git -C "$BASEDIR" worktree add -q -b scratch-9 "$WORK/scr9" >/dev/null 2>&1
: > "$TMLOG"; : > "$GHLOG"
RAW=1 WID='@9' WT="$WORK/scr9" run_reap "" "s1:9"
grep -q 'KILL' "$TMLOG" || fail "scratch ⌃x should kill the window"
grep -qi 'MSG.*worktree reaped' "$TMLOG" || fail "scratch ⌃x (clean) should report 'worktree reaped'"
[ -d "$WORK/scr9" ] && fail "clean scratch ⌃x should remove the worktree"
git -C "$BASEDIR" show-ref --verify -q refs/heads/scratch-9 && fail "clean scratch ⌃x should delete the branch"
grep -q 'CLOSE' "$GHLOG" && fail "scratch reap must NOT close any issue (no @issue)"

# B8c: ⌃x on a scratch row WITH a DIRTY worktree → open a confirm POPUP first (#289
# one-key rule); do NOT close the window or touch the worktree yet.
git -C "$BASEDIR" worktree add -q -b scratch-10 "$WORK/scr10" >/dev/null 2>&1
printf 'exp\n' > "$WORK/scr10/untracked"
: > "$TMLOG"; : > "$GHLOG"
RAW=1 WID='@9' WT="$WORK/scr10" run_reap "" "s1:9"
grep -q 'POPUP' "$TMLOG" || fail "dirty scratch ⌃x should open a confirm popup"
grep -q 'KILL' "$TMLOG" && fail "dirty scratch ⌃x must not close the window before confirm"
[ -d "$WORK/scr10" ] || fail "dirty scratch ⌃x must KEEP the worktree"

# B8d: confirm y on the DIRTY scratch → still KEEP the worktree, close the window
# only (git refuses a dirty remove; a confirmed reap never destroys uncommitted work).
: > "$TMLOG"; : > "$GHLOG"
printf 'y' | RAW=1 WID='@9' WT="$WORK/scr10" run_reap "" "s1:9" confirm
[ -d "$WORK/scr10" ] || fail "confirmed reap on a dirty scratch must KEEP the worktree"
grep -q 'KILL' "$TMLOG" || fail "confirmed reap on a dirty scratch should close the window"

# B8e: confirm y on a clean+unmerged scratch → remove worktree + branch, close window.
git -C "$BASEDIR" worktree add -q -b scratch-11 "$WORK/scr11" >/dev/null 2>&1
printf 'x\n' > "$WORK/scr11/g"; git -C "$WORK/scr11" add g; git -C "$WORK/scr11" commit -qm work
: > "$TMLOG"; : > "$GHLOG"
printf 'y' | RAW=1 WID='@9' WT="$WORK/scr11" run_reap "" "s1:9" confirm
[ -d "$WORK/scr11" ] && fail "confirmed reap on a clean+unmerged scratch should remove the worktree"
git -C "$BASEDIR" show-ref --verify -q refs/heads/scratch-11 && fail "confirmed reap should delete the scratch branch"

# B9: hub/panel row with @raw explicitly 0 (not a scratch) still refuses — the
# raw early-return keys on @raw=1 exactly, not merely "@raw set".
: > "$TMLOG"; : > "$GHLOG"
RAW=0 run_reap "" "s1:1"
grep -qi 'MSG.*no issue' "$TMLOG" || fail "@raw=0 hub row should still refuse ('no issue')"
grep -q 'KILL' "$TMLOG" && fail "@raw=0 hub row must not kill a window"

# --- C. the dash ⌃x bind must be NON-BLOCKING (issue #313) --------------------
# The blank-dash bug: `ctrl-x:execute(...)` makes fzf SUSPEND + clear the whole
# display while dash-reap.sh runs — and dash-reap prints nothing to stdout (its
# messages go to the tmux status line), so the pane sits BLANK for the reap.
# `execute-silent` does not suspend fzf, so the dash stays visible. Assert the
# bind on the launcher itself (a static wiring check, no tmux server needed).
# Pairs with B4 above, which asserts the slow teardown is dispatched via
# `run-shell -b` (backgrounded) rather than run inline on the bind.
DASH="$BIN/tmux-dashboard.sh"
[ -f "$DASH" ] || fail "tmux-dashboard.sh missing next to dash-reap.sh (#313)"
cx="$(grep -n 'ctrl-x:' "$DASH" | head -1)"
[ -n "$cx" ] || fail "no ctrl-x bind found in tmux-dashboard.sh (#313)"
case "$cx" in
  *'ctrl-x:execute-silent('*) : ;;                                  # non-blocking — correct
  *'ctrl-x:execute('*)  fail "ctrl-x uses blocking execute() — blanks the dash; must be execute-silent (#313): $cx" ;;
  *)                    fail "ctrl-x bind is neither execute-silent nor execute — unexpected (#313): $cx" ;;
esac

printf 'selftest PASS: fleet_reap_ok gate + dash-reap reap/confirm/cancel + raw/scratch paths + non-blocking ⌃x bind (#289+#290+#313)\n'
exit 0
