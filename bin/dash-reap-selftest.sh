#!/bin/bash
# dash-reap-selftest.sh — hermetic smoke test for the dash reaper (issue #100).
#
# Two layers, no network / no tmux server / no real GitHub:
#
#   A. fleet_reap_ok() — the SHARED clean+merged gate (fleet-lib.sh) that BOTH
#      the janitor (worktree-autoclean.sh) and dash-reap.sh call. Exercised
#      against REAL git worktrees:
#        • clean + ancestor-of-base           → ancestor  (rc 0)
#        • clean + merged-PR (branch in list)  → merged-pr (rc 0)
#        • clean + NOT merged                  → unmerged  (rc 1)
#        • dirty (untracked file)              → dirty     (rc 1)
#
#   B. dash-reap.sh decisions, with a FAKE tmux + gh and a real git checkout:
#        • hub/panel row (no @issue)           → refuse, no side effects
#        • ⌃x on a dirty row                   → refuse ("worktree has changes")
#        • ⌃x on a clean+unmerged row          → refuse ("PR not merged")
#        • ⌃x on a clean+merged row            → FULL reap: worktree removed,
#          branch deleted, `gh issue close` issued, `tmux kill-window` issued.
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
mkdir -p "$WORK/fakepath"
TMLOG="$WORK/tmlog"; GHLOG="$WORK/ghlog"; : > "$TMLOG"; : > "$GHLOG"

# fake tmux: answers the info queries dash-reap needs; logs kill-window + messages.
# @issue is read from the env var ISS (set per run). Order matters — check @issue
# BEFORE session_name (both contain "display-message -p").
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
case "$*" in
  *@issue*)       printf '%s\n' "${ISS:-}" ;;
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
  ISS="$iss" TMLOG="$TMLOG" GHLOG="$GHLOG" \
  FLEET_REPO="fake/repo" FLEET_MAIN="$BASEDIR" FLEET_BASE_BRANCH="$BASE_BR" \
  FLEET_CONF_DIR="$WORK/noconf" \
  PATH="$WORK/fakepath:$PATH" \
    bash "$BIN/dash-reap.sh" "$@"
}

# B1: no @issue (hub/panel) → refuse, no kill, no close
: > "$TMLOG"; : > "$GHLOG"
run_reap "" "s1:9"
grep -q 'MSG.*no issue' "$TMLOG" || fail "no-issue row should refuse with 'no issue'"
grep -q 'KILL' "$TMLOG" && fail "no-issue row must not kill a window"
[ -s "$GHLOG" ] && fail "no-issue row must not touch gh"

# B2: ⌃x on dirty (issue-3) → refuse, worktree kept
: > "$TMLOG"; : > "$GHLOG"
run_reap "3" "s1:3"
grep -qi 'MSG.*has changes' "$TMLOG" || fail "dirty ⌃x should refuse ('has changes')"
grep -q 'KILL' "$TMLOG" && fail "dirty ⌃x must not kill the window"
[ -d "$WORK/wt3" ] || fail "dirty worktree must be kept"

# B3: ⌃x on clean+unmerged (issue-2) → refuse
: > "$TMLOG"; : > "$GHLOG"
run_reap "2" "s1:2"
grep -qi 'MSG.*not merged' "$TMLOG" || fail "unmerged ⌃x should refuse ('not merged')"
[ -d "$WORK/wt2" ] || fail "unmerged worktree must be kept"

# B4: ⌃x on clean+merged (issue-1, ancestor) → full reap
: > "$TMLOG"; : > "$GHLOG"
run_reap "1" "s1:1"
[ -d "$WORK/wt1" ] && fail "merged worktree should be removed"
git -C "$BASEDIR" show-ref --verify -q refs/heads/issue-1 && fail "issue-1 branch should be deleted"
grep -q 'CLOSE' "$GHLOG" || fail "merged reap should close the issue"
grep -q 'KILL' "$TMLOG" || fail "merged reap should kill the window"

printf 'selftest PASS: fleet_reap_ok gate + dash-reap safe/refuse/reap paths\n'
exit 0
