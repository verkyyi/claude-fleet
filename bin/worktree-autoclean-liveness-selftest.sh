#!/bin/bash
# worktree-autoclean-liveness-selftest.sh — hermetic tests for the janitor's
# LIVENESS guard (issue #353). A busy worker must NOT be false-reaped just
# because its pane's cwd wandered off the worktree root. worktree-autoclean now
# keys liveness off worker IDENTITY (`@issue=<N>` on a live pane), robust to cwd,
# with the old cwd match kept as a PREFIX fallback for non-issue worktrees:
#   * issue-<N> clean+ancestor, a live pane binds @issue=N (cwd in a SUBDIR) → KEEP
#   * issue-<N> clean+ancestor, NO live pane binds @issue=N                  → PRUNE
#   * scratch-<N> clean+ancestor, a live pane cwd is a SUBDIR of the worktree → KEEP
#   * scratch-<N> clean+ancestor, no live pane anywhere in it                → PRUNE
#
# No network / no tmux server / no real GitHub: the real script + fleet-lib.sh are
# symlinked into a temp bin (so $BIN/../fleet.conf can't leak the real fleet), a
# per-fleet conf drives fleet_sockets, and a fake `tmux`/`gh` stand in. A REAL local
# git repo provides the worktrees. The fake tmux answers `list-panes -F '#{@issue}'`
# from ISSUES_FILE and `-F '#{pane_current_path}'` from PATHS_FILE — the two live
# facts the guard now reads.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/worktree-autoclean.sh"
LIB="$BIN/fleet-lib.sh"
for f in "$SRC" "$LIB"; do [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }; done
command -v git >/dev/null 2>&1 || { echo "selftest: git absent — SKIP" >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wac-liveness.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
# Normalize to the physical path (macOS /var → /private/var, and collapse any `//`
# from TMPDIR) so the LIVE-pane paths we write match what git reports.
WORK="$(cd "$WORK" && pwd -P)"

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf" "$WORK/logs"
ln -s "$SRC" "$WORK/bin/worktree-autoclean.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"
ISSUES_FILE="$WORK/issues"; PATHS_FILE="$WORK/paths"; NOTIFY_LOG="$WORK/notify"
: > "$ISSUES_FILE"; : > "$PATHS_FILE"; : > "$NOTIFY_LOG"

# --- build a real base checkout + issue/scratch worktrees ---------------------
BASE="$WORK/base"
git init -q "$BASE"
git -C "$BASE" config user.email t@t; git -C "$BASE" config user.name t
printf 'seed\n' > "$BASE/f"; git -C "$BASE" add f; git -C "$BASE" commit -qm seed
BASE_BR="$(git -C "$BASE" branch --show-current)"

# All four worktrees are clean and sit at HEAD==base → the reap gate returns
# `ancestor` for every one of them. Only the LIVENESS guard decides KEEP vs PRUNE.
git -C "$BASE" worktree add -q -b issue-100  "$WORK/base-issue-100"  >/dev/null 2>&1
git -C "$BASE" worktree add -q -b issue-200  "$WORK/base-issue-200"  >/dev/null 2>&1
git -C "$BASE" worktree add -q -b scratch-9  "$WORK/base-scratch-9"  >/dev/null 2>&1
git -C "$BASE" worktree add -q -b scratch-8  "$WORK/base-scratch-8"  >/dev/null 2>&1
mkdir -p "$WORK/base-issue-100/subdir" "$WORK/base-scratch-9/deep/sub"

# LIVE facts the fake tmux serves:
#  * issue-100 has a live worker pane bound @issue=100, but its cwd is a SUBDIR
#    (the pane_current_path never equals the worktree root) — the #353 repro.
#  * scratch-9 has a live pane cd'd into a SUBDIR of the worktree (no @issue).
#  * issue-200 / scratch-8 have no live pane at all.
printf '%s\n' '100' '' > "$ISSUES_FILE"                       # @issue per live pane
printf '%s\n' "$WORK/base-issue-100/subdir" \
              "$WORK/base-scratch-9/deep/sub" > "$PATHS_FILE"  # pane_current_path per live pane

# --- fake tmux: has-session ok; list-panes branches on the -F format ----------
cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
[ "\$1" = -L ] && shift 2
cmd="\$1"; shift 2>/dev/null || true
case "\$cmd" in
  has-session) exit 0 ;;
  list-panes)
    fmt=""
    while [ \$# -gt 0 ]; do case "\$1" in -F) fmt="\$2"; shift 2;; *) shift;; esac; done
    case "\$fmt" in
      *@issue*)            cat "$ISSUES_FILE" 2>/dev/null ;;
      *pane_current_path*) cat "$PATHS_FILE" 2>/dev/null ;;
    esac ;;
  display-message) printf 'NOTIFY %s\n' "\$*" >> "$NOTIFY_LOG" ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/tmux"

# --- fake gh: no merged PRs (every reap here is via ancestor), issues OPEN -----
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
case "$*" in
  *"pr list"*)     : ;;                  # no merged PRs — reaps go through ancestor
  *"issue view"*)  printf 'OPEN\n' ;;
  *"issue close"*) : ;;
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

run_wac() {   # run worktree-autoclean.sh with the fakes; args forwarded (--dry-run)
  PATH="$WORK/fakebin:$PATH" FLEET_CONF_DIR="$WORK/conf" \
    bash "$WORK/bin/worktree-autoclean.sh" "$@" 2>"$WORK/err"
}

# ============================ DRY RUN: decisions ============================
out="$(run_wac --dry-run)"
# core repro: a live worker whose cwd is a subdir is KEPT via @issue identity
printf '%s\n' "$out" | grep -Eq 'KEEP +issue-100 .*live worker window @issue=100' \
  || fail "issue-100: a live worker (@issue=100, cwd in subdir) must KEEP via identity" "$out"
printf '%s\n' "$out" | grep -Eq 'PRUNE +issue-100 ' \
  && fail "issue-100: a live worker must NEVER be reaped (the #353 false-reap)" "$out"
# a truly-gone worker (no live @issue) is still reaped
printf '%s\n' "$out" | grep -Eq 'PRUNE +issue-200 ' \
  || fail "issue-200: no live @issue=200 anywhere → must still PRUNE" "$out"
# prefix cwd fallback: a pane cd'd into a SUBDIR of a non-issue worktree KEEPs it
printf '%s\n' "$out" | grep -Eq 'KEEP +scratch-9 .*live tmux session' \
  || fail "scratch-9: a live pane in a subdir must KEEP via the prefix cwd fallback" "$out"
printf '%s\n' "$out" | grep -Eq 'PRUNE +scratch-9 ' \
  && fail "scratch-9: a live-in-subdir worktree must not be reaped" "$out"
# no pane anywhere in scratch-8 → reaped
printf '%s\n' "$out" | grep -Eq 'PRUNE +scratch-8 ' \
  || fail "scratch-8: no live pane inside it → must PRUNE" "$out"
# dry run mutates nothing
[ -d "$WORK/base-issue-100" ] || fail "dry run must not remove issue-100"
ok "DRY: live worker kept by @issue identity (cwd-independent); prefix cwd fallback; gone workers reaped"

# ============================ REAL RUN: reap only the dead ================
run_wac >/dev/null
[ -d "$WORK/base-issue-100" ] || fail "real run must KEEP live worker issue-100 (false-reap regression)"
[ -d "$WORK/base-scratch-9" ] || fail "real run must KEEP live-in-subdir scratch-9"
[ -d "$WORK/base-issue-200" ] && fail "real run should reap gone worker issue-200"
[ -d "$WORK/base-scratch-8" ] && fail "real run should reap gone scratch-8"
git -C "$BASE" show-ref --verify -q refs/heads/issue-100 || fail "issue-100 branch must survive"
git -C "$BASE" show-ref --verify -q refs/heads/issue-200 && fail "issue-200 branch should be deleted"
ok "REAL: only the workers with no live @issue / no live pane are reaped; the busy ones survive"

printf '\nselftest OK: %s assertions passed (janitor liveness guard, #353)\n' "$pass"
exit 0
