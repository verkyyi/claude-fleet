#!/bin/bash
# fleet-base-branch-selftest.sh — hermetic unit tests for fleet_resolve_base_branch()
# in bin/fleet-lib.sh, the ONE place a fleet's trunk is decided (issue #603).
#
# The bug: a fleet's FLEET_BASE_BRANCH ended up pointing at a branch that merely
# happened to be checked out ('dashboard-redesign') instead of the repo's default
# branch ('main'). Nothing looked broken — workers claimed, branched, pushed, CI went
# green, PRs merged — and every one of them landed on a dead branch five commits
# behind main. It is the fleet's most expensive SILENT failure, and the same
# "point at the current branch, not the trunk" mistake had already bitten ccquota's
# push trigger (its PR #11). So the resolution order is pinned down here:
#
#   flag > default (gh) > origin-head > checkout > fallback('main')
#
# and the authoritative default branch is reported alongside the answer even when
# it was NOT used, because that is what lets fleet-up.sh SAY that an explicit
# --base disagrees with the repo instead of obeying it in silence.
#
# Covered:
#   1. DEFAULT     — gh answers: that answer wins, tagged `default`.
#   2. REGRESSION  — standing on 'dashboard-redesign' while gh says 'main' resolves
#                    to main. This is issue #603 itself.
#   3. FLAG        — an explicit --base wins over the gh default...
#   4. FLAG-REPORT — ...and the gh default is STILL reported, so a mismatch is
#                    detectable by the caller (the whole point).
#   5. ORIGIN-HEAD — gh unusable: refs/remotes/origin/HEAD, stripped of 'origin/'.
#   6. CHECKOUT    — gh unusable and no origin/HEAD: the current branch, tagged
#                    `checkout` so the caller knows to warn. Never reached while a
#                    better source exists.
#   7. FALLBACK    — nothing knowable (detached HEAD): 'main', tagged `fallback`.
#   8. NO-GH       — gh not on PATH at all behaves exactly like a failing gh.
#   9. SPLIT       — the output really is 3 tab-separated fields a caller can
#                    `IFS=$'\t' read` — including when the default field is empty.
#
# Fully hermetic: a stub `gh` on a minimal PATH, throwaway git repos, no network.
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-base-branch-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
# shellcheck source=/dev/null
. "$LIB"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() {  # <desc> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"
}

# --- a minimal PATH so `command -v gh` is ours to control -------------------
# The stub dirs carry ONLY the binaries the function itself shells out to (git,
# sed) plus, in STUB_GH, a fake `gh`. CI runners ship a real gh in /usr/bin, so
# "gh is absent" can only be tested by owning the whole PATH.
STUB_GH="$WORK/bin-gh"; STUB_NOGH="$WORK/bin-nogh"
mkdir -p "$STUB_GH" "$STUB_NOGH"
for tool in git sed; do
  real=$(command -v "$tool") || { printf 'selftest: %s not found\n' "$tool" >&2; exit 2; }
  ln -s "$real" "$STUB_GH/$tool"; ln -s "$real" "$STUB_NOGH/$tool"
done
# The stub answers `gh repo view … -q .defaultBranchRef.name` with $GH_DEFAULT, and
# fails like an unauthed/offline gh when GH_DEFAULT is empty.
cat > "$STUB_GH/gh" <<'GH'
#!/bin/sh
[ -n "${GH_DEFAULT:-}" ] || { echo "gh: not authenticated" >&2; exit 1; }
printf '%s\n' "$GH_DEFAULT"
GH
chmod +x "$STUB_GH/gh"

# resolve <checkout> <flag> — run the function with the stub PATH, echo its line.
resolve() { ( PATH="$STUB_GH"; fleet_resolve_base_branch acme/widgets "$1" "$2" ); }
resolve_nogh() { ( PATH="$STUB_NOGH"; fleet_resolve_base_branch acme/widgets "$1" "$2" ); }
field() { printf '%s' "$1" | cut -d"$(printf '\t')" -f"$2"; }

# --- throwaway checkouts ----------------------------------------------------
# REPO_FEATURE stands on a feature branch with origin/HEAD → origin/main: the exact
# shape of the machine on 2026-09-12.
mkgit() { # <dir> <branch-to-stand-on>
  git init -q -b main "$1" >/dev/null 2>&1 || { git init -q "$1"; git -C "$1" checkout -q -b main 2>/dev/null; }
  git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  [ "$2" = main ] || git -C "$1" checkout -q -b "$2"
}
REPO_FEATURE="$WORK/feature"; mkgit "$REPO_FEATURE" dashboard-redesign
git -C "$REPO_FEATURE" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

# REPO_BARE_HEAD has NO origin/HEAD at all — the only way `checkout` is ever reached.
REPO_NOHEAD="$WORK/nohead"; mkgit "$REPO_NOHEAD" dashboard-redesign

# REPO_DETACHED has neither origin/HEAD nor a current branch.
REPO_DETACHED="$WORK/detached"; mkgit "$REPO_DETACHED" main
git -C "$REPO_DETACHED" checkout -q --detach

# ============================================================ 1. DEFAULT =====
out=$(GH_DEFAULT=main resolve "$REPO_FEATURE" "")
eq "default: branch" "main"    "$(field "$out" 1)"
eq "default: source" "default" "$(field "$out" 2)"
eq "default: reports the authoritative default" "main" "$(field "$out" 3)"

# ========================================================= 2. REGRESSION =====
# Issue #603: the checkout is standing on dashboard-redesign, origin/HEAD is stale-ish,
# gh says main. The trunk — not the branch we happen to be on — must win.
eq "regression #603: the current branch NEVER wins over the repo default" \
   "main" "$(field "$(GH_DEFAULT=main resolve "$REPO_FEATURE" "")" 1)"

# =============================================================== 3+4. FLAG ===
out=$(GH_DEFAULT=main resolve "$REPO_FEATURE" dashboard-redesign)
eq "flag: an explicit --base wins"  "dashboard-redesign" "$(field "$out" 1)"
eq "flag: source"                   "flag"               "$(field "$out" 2)"
eq "flag: the default is STILL reported so the caller can warn on a mismatch" \
   "main" "$(field "$out" 3)"

# ========================================================= 5. ORIGIN-HEAD ====
out=$(GH_DEFAULT='' resolve "$REPO_FEATURE" "")
eq "origin-head: branch, 'origin/' stripped" "main"        "$(field "$out" 1)"
eq "origin-head: source"                     "origin-head" "$(field "$out" 2)"
eq "origin-head: no authoritative default to report" ""    "$(field "$out" 3)"

# ============================================================ 6. CHECKOUT ====
out=$(GH_DEFAULT='' resolve "$REPO_NOHEAD" "")
eq "checkout: last-resort current branch" "dashboard-redesign" "$(field "$out" 1)"
eq "checkout: source (the caller MUST warn on this)" "checkout" "$(field "$out" 2)"

# ============================================================ 7. FALLBACK ====
out=$(GH_DEFAULT='' resolve "$REPO_DETACHED" "")
eq "fallback: nothing knowable" "main"     "$(field "$out" 1)"
eq "fallback: source"           "fallback" "$(field "$out" 2)"

# =============================================================== 8. NO-GH ====
out=$(resolve_nogh "$REPO_FEATURE" "")
eq "no-gh: behaves like a failing gh" "origin-head" "$(field "$out" 2)"
eq "no-gh: no default reported"       ""            "$(field "$out" 3)"

# ================================================================ 9. SPLIT ===
# The caller's real parse, including the empty-default case (trailing tab).
IFS=$'\t' read -r b s d < <(GH_DEFAULT='' resolve "$REPO_NOHEAD" "")
eq "split: branch"  "dashboard-redesign" "$b"
eq "split: source"  "checkout"           "$s"
eq "split: default" ""                   "$d"
IFS=$'\t' read -r b s d < <(GH_DEFAULT=trunk resolve "$REPO_FEATURE" "")
eq "split: branch (default path)"  "trunk" "$b"
eq "split: source (default path)"  "default" "$s"
eq "split: default (default path)" "trunk" "$d"

printf 'selftest PASS: fleet_resolve_base_branch — flag > gh default > origin/HEAD > checkout > main, %d checks held (issue #603)\n' "$CHECKS"
