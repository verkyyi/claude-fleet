#!/bin/bash
# worktree-autoclean-scratch-selftest.sh — hermetic tests for the janitor's SCRATCH
# reap rules (issue #290). A `scratch-<N>` worktree (dash-raw-session.sh) has no
# issue/PR, so worktree-autoclean must:
#   * clean + no unmerged work (tip is an ancestor of base)  → PRUNE silently
#   * escalated + merged (branch in the merged-PR list)       → PRUNE (like a worker)
#   * dirty (uncommitted/untracked)                           → KEEP + surface ONCE
#   * clean but unmerged local commits                        → KEEP + surface ONCE
#   * a live tmux pane inside it                              → KEEP (attached)
# and a normal `issue-<N>` worktree must be UNAFFECTED by the scratch wording.
#
# No network / no tmux server / no real GitHub: the real script + fleet-lib.sh are
# symlinked into a temp bin (so $BIN/../fleet.conf can't leak the real fleet), a
# per-fleet conf drives fleet_sockets, and a fake `tmux`/`gh` stand in. A REAL local
# git repo provides the worktrees.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/worktree-autoclean.sh"
LIB="$BIN/fleet-lib.sh"
for f in "$SRC" "$LIB"; do [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }; done
command -v git >/dev/null 2>&1 || { echo "selftest: git absent — SKIP" >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wac-scratch.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
# Normalize to the physical path (macOS /var → /private/var, and collapse any `//`
# from TMPDIR) so the LIVE-pane string we write matches the path git reports.
WORK="$(cd "$WORK" && pwd -P)"

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf" "$WORK/logs"
ln -s "$SRC" "$WORK/bin/worktree-autoclean.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"
NOTIFY_LOG="$WORK/notify"; LIVE_FILE="$WORK/live"; : > "$NOTIFY_LOG"; : > "$LIVE_FILE"

# --- build a real base checkout + scratch/issue worktrees ---------------------
BASE="$WORK/base"
git init -q "$BASE"
git -C "$BASE" config user.email t@t; git -C "$BASE" config user.name t
printf 'seed\n' > "$BASE/f"; git -C "$BASE" add f; git -C "$BASE" commit -qm seed
BASE_BR="$(git -C "$BASE" branch --show-current)"

build_trees() {   # (re)create the five scratch worktrees + one issue worktree
  # scratch-1: clean, tip == base ⇒ ancestor ⇒ PRUNE silently
  git -C "$BASE" worktree add -q -b scratch-1 "$WORK/base-scratch-1" >/dev/null 2>&1
  # scratch-2: clean, one extra commit ⇒ unmerged ⇒ KEEP + surface
  git -C "$BASE" worktree add -q -b scratch-2 "$WORK/base-scratch-2" >/dev/null 2>&1
  printf 'x\n' > "$WORK/base-scratch-2/g"; git -C "$WORK/base-scratch-2" add g; git -C "$WORK/base-scratch-2" commit -qm work
  # scratch-3: dirty (untracked) ⇒ KEEP + surface
  git -C "$BASE" worktree add -q -b scratch-3 "$WORK/base-scratch-3" >/dev/null 2>&1
  printf 'exp\n' > "$WORK/base-scratch-3/untracked"
  # scratch-4: escalated + merged (in the merged-PR list) ⇒ PRUNE
  git -C "$BASE" worktree add -q -b scratch-4 "$WORK/base-scratch-4" >/dev/null 2>&1
  printf 'y\n' > "$WORK/base-scratch-4/h"; git -C "$WORK/base-scratch-4" add h; git -C "$WORK/base-scratch-4" commit -qm landed
  # scratch-5: live pane inside it ⇒ KEEP (attached)
  git -C "$BASE" worktree add -q -b scratch-5 "$WORK/base-scratch-5" >/dev/null 2>&1
  # issue-7: dirty ⇒ KEEP, but with the ISSUE wording (not the scratch surface)
  git -C "$BASE" worktree add -q -b issue-7 "$WORK/base-issue-7" >/dev/null 2>&1
  printf 'dirt\n' > "$WORK/base-issue-7/untracked"
  printf '%s\n' "$WORK/base-scratch-5" > "$LIVE_FILE"   # scratch-5 is the only "live" pane
}
build_trees

# --- fake tmux: has-session ok, list-panes → LIVE_FILE, display-message → NOTIFY_LOG
cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
[ "\$1" = -L ] && shift 2
case "\$1" in
  has-session)     exit 0 ;;
  list-panes)      cat "$LIVE_FILE" 2>/dev/null ;;
  display-message) shift; printf 'NOTIFY %s\n' "\$*" >> "$NOTIFY_LOG" ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/tmux"

# --- fake gh: merged-PR list → scratch-4 (the escalated one) ------------------
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
case "$*" in
  *"pr list"*)    printf 'scratch-4\n' ;;
  *"issue view"*) printf 'OPEN\n' ;;
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
printf '%s\n' "$out" | grep -Eq 'PRUNE +scratch-1 ' || fail "clean+ancestor scratch-1 should PRUNE" "$out"
printf '%s\n' "$out" | grep -Eq 'PRUNE +scratch-4 ' || fail "merged scratch-4 should PRUNE (escalation)" "$out"
printf '%s\n' "$out" | grep -Eq 'KEEP +scratch-2 .*unmerged work — scratch experiment' || fail "unmerged scratch-2 should KEEP + surface" "$out"
printf '%s\n' "$out" | grep -Eq 'KEEP +scratch-3 .*dirty — scratch experiment' || fail "dirty scratch-3 should KEEP + surface" "$out"
printf '%s\n' "$out" | grep -Eq 'KEEP +scratch-5 .*live tmux session' || fail "live scratch-5 should KEEP (attached)" "$out"
printf '%s\n' "$out" | grep -Eq 'KEEP +issue-7 .*dirty — uncommitted changes' || fail "issue-7 must keep the ISSUE wording, not scratch" "$out"
printf '%s\n' "$out" | grep -Eq 'issue-7 .*scratch experiment' && fail "issue-7 must NOT be treated as a scratch experiment" "$out"
# dry run mutates nothing
[ -d "$WORK/base-scratch-1" ] || fail "dry run must not remove scratch-1"
ok "DRY: clean/merged scratch → PRUNE; dirty/unmerged → KEEP+surface; live → KEEP; issue unaffected"

# ============================ REAL RUN: reap + surface once ================
run_wac >/dev/null
[ -d "$WORK/base-scratch-1" ] && fail "real run should remove clean scratch-1"
git -C "$BASE" show-ref --verify -q refs/heads/scratch-1 && fail "real run should delete branch scratch-1"
[ -d "$WORK/base-scratch-4" ] && fail "real run should remove merged scratch-4"
[ -d "$WORK/base-scratch-2" ] || fail "real run must KEEP unmerged scratch-2"
[ -d "$WORK/base-scratch-3" ] || fail "real run must KEEP dirty scratch-3"
[ -d "$WORK/base-scratch-5" ] || fail "real run must KEEP live scratch-5"
[ -d "$WORK/base-issue-7" ]   || fail "real run must KEEP dirty issue-7"
# surface markers exist for the two kept experiments
SURF="$WORK/logs/.scratch-surfaced"
[ "$(ls -1 "$SURF" 2>/dev/null | wc -l | tr -d ' ')" = 2 ] || fail "exactly two scratch surface markers expected" "$(ls -la "$SURF" 2>/dev/null)"
# notify fired for scratch-2 + scratch-3
grep -q 'NOTIFY.*scratch-2 kept (unmerged work)' "$NOTIFY_LOG" || fail "scratch-2 should have surfaced a notify" "$(cat "$NOTIFY_LOG")"
grep -q 'NOTIFY.*scratch-3 kept (dirty)' "$NOTIFY_LOG" || fail "scratch-3 should have surfaced a notify" "$(cat "$NOTIFY_LOG")"
n1="$(wc -l < "$NOTIFY_LOG" | tr -d ' ')"
ok "REAL: clean/merged scratch reaped; dirty/unmerged kept + surfaced once (markers + notify)"

# ============================ SURFACE-ONCE dedup ===========================
run_wac >/dev/null
n2="$(wc -l < "$NOTIFY_LOG" | tr -d ' ')"
[ "$n1" = "$n2" ] || fail "a second sweep must NOT re-notify a still-kept scratch (surface once)" "before=$n1 after=$n2"
ok "SURFACE-ONCE: a kept scratch is surfaced only on the first sweep, not every cycle"

printf '\nselftest OK: %s assertions passed (janitor scratch reap rules, #290)\n' "$pass"
exit 0
