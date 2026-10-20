#!/bin/bash
# fleet-deps-share-selftest.sh — hermetic tests for shared dependency trees (issue
# #3403): bin/fleet-deps-share.sh and its call in fleet_worktree_setup
# (fleet_worktree_deps_share, bin/fleet-lib.sh).
#
# Asserts:
#   NONE      a repo with no lockfile (claude-fleet's shape) ⇒ no record, no log
#             line, nothing in the worktree: behaviour unchanged.
#   CLONE     npm lockfile identical + the base's tree installed from it (npm's own
#             .package-lock.json not older than the lockfile) ⇒ `clone:<how> .`, a
#             real node_modules (not a link) with the base's files, its workspace
#             member's tree too; writing in it leaves the base untouched;
#             `git status --porcelain` empty; the record + one log line say so.
#   STAMP     a fleet stamp (.fleet-lock-sha) of another sha, or a reinstall in
#             flight ⇒ `install`; the stamp of THIS sha ⇒ cloned.
#   STALE     no stamp and the install marker older than the lockfile ⇒ `install`.
#   DIFFER    the lockfile differs from every source ⇒ `install`, nothing cloned.
#   SIBLING   the base has no tree, another worktree of the same checkout has one
#             for the identical lockfile ⇒ cloned from that worktree.
#   NOCLONE   the filesystem cannot clone ⇒ `skipped:no-clone`, nothing left behind.
#   ABSLINK   an absolute link into the source checkout ⇒ `skipped:link-into-source`
#             and the member trees already cloned for that lockfile are removed.
#   IGNORE    node_modules not git-ignored ⇒ `skipped:not-ignored`, status clean.
#   PNPM/UV/GO  pnpm with no source ⇒ `pnpm-store`; uv.lock ⇒ `uv-cache`; go.mod ⇒
#             `go-modcache` — recorded, nothing written into the worktree.
#   SETUP     automatic sharing is opt-in; explicit setup and direct sharing stay
#             available; a share that cannot clone still creates the worktree.
#   NATIVE    the real clone of this filesystem (clonefile on macOS, reflink on
#             Linux) either clones or says `skipped:no-clone` — never a full copy.
#
# Real git, temp dirs, fake node_modules — no network, no npm, no tmux.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
LIB="$BIN/fleet-lib.sh"
DS="$BIN/fleet-deps-share.sh"
[ -f "$LIB" ] && [ -x "$DS" ] || { printf 'selftest: missing pieces\n' >&2; exit 2; }
st_need git

st_sandbox "${TMPDIR:-/tmp}/fleet-deps-share.XXXXXX" physical
trap 'exit 130' INT TERM HUP

pass=0

export HOME="$WORK/home"; mkdir -p "$HOME"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$WORK/home/.gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export FLEET_DEPS_SHARE_LOG="$WORK/share.log" FLEET_WORKTREE_SETUP_LOG="$WORK/setup.log"
# Every leg but NATIVE uses a plain copy as "the clone": CI's ext4 has no reflink,
# and what is under test is the choosing, not the filesystem.
export FLEET_DEPS_SHARE_CLONE=copy
unset FLEET_WORKTREE_ROOT FLEET_WORKTREE_SETUP FLEET_DEPS_SHARE FLEET_MAIN TMUX TMUX_PANE

# shellcheck source=/dev/null
. "$LIB"

sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1"; else sha256sum < "$1"; fi | cut -d' ' -f1; }
older() { touch -t 202001010000 "$1"; }   # make a marker older than any checkout
newwt() {  # <main> → a fresh worktree path (detached at HEAD); runs in $(…), so no counter
  local w; w=$(mktemp -d "$WORK/wt.XXXXXX") && rmdir "$w" || exit 1
  git -C "$1" worktree add -q --detach "$w" HEAD >/dev/null 2>&1 || exit 1
  printf '%s' "$w"
}
rec() { "$DS" --status "$1"; }
# drop_wts — remove every test worktree, so a leg's only candidate source is the
# one it set up (a worktree an earlier leg filled is a legitimate source too).
drop_wts() {
  local w
  for w in "$WORK"/wt.*; do [ -d "$w" ] && git -C "$MAIN" worktree remove --force "$w" >/dev/null 2>&1; rm -rf "$w"; done
  git -C "$MAIN" worktree prune >/dev/null 2>&1
  return 0
}

# ---- NONE: no lockfile -------------------------------------------------------
PLAIN="$WORK/src/plain"; mkdir -p "$PLAIN"; ( cd "$PLAIN" && git init -q -b master && printf 'x\n' > a.sh && git add -A && git commit -qm i )
W=$(newwt "$PLAIN") || st_fail "worktree add"
out=$("$DS" "$W" "$PLAIN")
[ -z "$out" ] && [ ! -e "$FLEET_DEPS_SHARE_LOG" ] && [ "$(rec "$W")" = "none ." ] \
  && [ -z "$(git -C "$W" status --porcelain)" ] || st_fail "NONE: a repo without lockfiles was touched" "$out"
st_pass "NONE: no lockfile ⇒ no record, no log, worktree untouched"

# ---- the JS checkout: root npm (+ member packages/a), tools (yarn), web (pnpm),
#      py (uv), svc (go) -------------------------------------------------------
MAIN="$WORK/src/repo"
mkdir -p "$MAIN/packages/a" "$MAIN/tools" "$MAIN/web" "$MAIN/py" "$MAIN/svc"
cd "$MAIN" || exit 2
git init -q -b master
printf 'node_modules/\n' > .gitignore
printf '{"name":"root"}\n'  > package.json
printf '{"lockfileVersion":3}\n' > package-lock.json
printf '{"name":"a"}\n'     > packages/a/package.json
printf '{"name":"tools"}\n' > tools/package.json
printf 'lock: 1\n'          > tools/yarn.lock
printf '{"name":"web"}\n'   > web/package.json
printf 'lockfileVersion: 9\n' > web/pnpm-lock.yaml
printf 'version = 1\n'      > py/uv.lock
printf 'module x\n'         > svc/go.mod
git add -A && git commit -qm init
mkdir -p node_modules/lodash packages/a/node_modules/left-pad tools/node_modules/x
printf 'base\n' > node_modules/lodash/index.js
: > packages/a/node_modules/left-pad/index.js
ln -s ../lodash node_modules/rel-link                  # a relative link follows the clone
: > node_modules/.package-lock.json                     # npm's install marker, newer than the lock
: > tools/node_modules/.yarn-integrity
cd "$BIN" || exit 2

# ---- CLONE + PNPM/UV/GO --------------------------------------------------------
W=$(newwt "$MAIN")
out=$("$DS" "$W" "$MAIN")
printf '%s\n' "$out" | grep -qx "clone:copy \\. $MAIN" || st_fail "CLONE: root not cloned" "$out"
printf '%s\n' "$out" | grep -qx "clone:copy tools $MAIN" || st_fail "CLONE: yarn dir not cloned" "$out"
[ -d "$W/node_modules" ] && [ ! -L "$W/node_modules" ] && [ "$(cat "$W/node_modules/lodash/index.js")" = base ] \
  || st_fail "CLONE: node_modules is not a real copy of the base's" "$(ls -la "$W/node_modules" 2>&1)"
[ -f "$W/packages/a/node_modules/left-pad/index.js" ] || st_fail "CLONE: workspace member's tree not cloned"
[ "$(readlink "$W/node_modules/rel-link")" = ../lodash ] || st_fail "CLONE: relative link not kept"
printf 'mine\n' > "$W/node_modules/lodash/index.js"
[ "$(cat "$MAIN/node_modules/lodash/index.js")" = base ] || st_fail "CLONE: a write in the clone reached the base"
[ -z "$(git -C "$W" status --porcelain)" ] || st_fail "CLONE: worktree not clean" "$(git -C "$W" status --porcelain)"
printf '%s\n' "$out" | grep -qx "pnpm-store web" || st_fail "PNPM: pnpm dir not recorded as pnpm-store" "$out"
[ ! -e "$W/web/node_modules" ] || st_fail "PNPM: something was written into web/"
printf '%s\n' "$out" | grep -qx "uv-cache py" && printf '%s\n' "$out" | grep -qx "go-modcache svc" \
  || st_fail "UV/GO: not recorded" "$out"
[ "$(rec "$W")" = "$out" ] || st_fail "CLONE: --status differs from the run" "$(rec "$W")"
grep -q "$W clone=2 pnpm-store=1 uv-cache=1 go-modcache=1 " "$FLEET_DEPS_SHARE_LOG" \
  || st_fail "CLONE: no summary log line" "$(cat "$FLEET_DEPS_SHARE_LOG")"
st_pass "CLONE: identical lockfile + installed base ⇒ real copy-on-write tree, member too, base untouched, status clean"
st_pass "PNPM/UV/GO: per-login stores recorded, nothing written"

# ---- STAMP / STALE / DIFFER ---------------------------------------------------
drop_wts
printf 'other\n' > "$MAIN/node_modules/.fleet-lock-sha"
W=$(newwt "$MAIN"); out=$("$DS" "$W" "$MAIN")
printf '%s\n' "$out" | grep -qx "install \\." && [ ! -e "$W/node_modules" ] || st_fail "STAMP: another sha still cloned" "$out"
sha "$MAIN/package-lock.json" > "$MAIN/node_modules/.fleet-lock-sha"; : > "$MAIN/node_modules/.fleet-installing"
drop_wts; W=$(newwt "$MAIN"); out=$("$DS" "$W" "$MAIN")
printf '%s\n' "$out" | grep -qx "install \\." || st_fail "STAMP: a reinstall in flight still cloned" "$out"
rm -f "$MAIN/node_modules/.fleet-installing"; older "$MAIN/node_modules/.package-lock.json"
drop_wts; W=$(newwt "$MAIN"); out=$("$DS" "$W" "$MAIN")
printf '%s\n' "$out" | grep -qx "clone:copy \\. $MAIN" || st_fail "STAMP: this sha's stamp not trusted" "$out"
st_pass "STAMP: another sha / in flight ⇒ install; this sha ⇒ clone (even with an old marker)"
rm -f "$MAIN/node_modules/.fleet-lock-sha"
drop_wts; W=$(newwt "$MAIN"); out=$("$DS" "$W" "$MAIN")
printf '%s\n' "$out" | grep -qx "install \\." && [ ! -e "$W/node_modules" ] || st_fail "STALE: an install older than the lockfile was cloned" "$out"
st_pass "STALE: install marker older than the lockfile ⇒ install"
: > "$MAIN/node_modules/.package-lock.json"
drop_wts; W=$(newwt "$MAIN"); printf '{"lockfileVersion":3,"x":1}\n' > "$W/package-lock.json"
out=$("$DS" "$W" "$MAIN")
printf '%s\n' "$out" | grep -qx "install \\." && [ ! -e "$W/node_modules" ] || st_fail "DIFFER: a differing lockfile was cloned" "$out"
st_pass "DIFFER: lockfile differs ⇒ install, nothing cloned"

# ---- SIBLING ---------------------------------------------------------------------
drop_wts
mv "$MAIN/tools/node_modules" "$WORK/tools-nm"
SIB=$(newwt "$MAIN"); mkdir -p "$SIB/tools/node_modules/y"; : > "$SIB/tools/node_modules/.yarn-integrity"
W=$(newwt "$MAIN"); out=$("$DS" "$W" "$MAIN")
printf '%s\n' "$out" | grep -qx "clone:copy tools $SIB" && [ -d "$W/tools/node_modules/y" ] \
  || st_fail "SIBLING: not cloned from the other worktree" "$out"
mv "$WORK/tools-nm" "$MAIN/tools/node_modules"
st_pass "SIBLING: base has no tree ⇒ cloned from another worktree with the same lockfile"

# ---- NOCLONE -----------------------------------------------------------------------
drop_wts
W=$(newwt "$MAIN"); out=$(FLEET_DEPS_SHARE_CLONE=off "$DS" "$W" "$MAIN")
printf '%s\n' "$out" | grep -qx "skipped:no-clone \\." && [ ! -e "$W/node_modules" ] \
  && [ -z "$(git -C "$W" status --porcelain --ignored | grep -v '^!! .*node_modules/$')" ] \
  || st_fail "NOCLONE: not skipped cleanly" "$out
$(git -C "$W" status --porcelain --ignored)"
st_pass "NOCLONE: no clone on this filesystem ⇒ skipped:no-clone, nothing left behind"

# ---- ABSLINK ---------------------------------------------------------------------------
drop_wts
ln -s "$MAIN/packages/a" "$MAIN/packages/a/node_modules/a-src"
W=$(newwt "$MAIN"); out=$("$DS" "$W" "$MAIN")
printf '%s\n' "$out" | grep -qx "skipped:link-into-source \\." && [ ! -e "$W/node_modules" ] && [ ! -e "$W/packages/a/node_modules" ] \
  || st_fail "ABSLINK: a tree linking into the source was cloned (or half of it kept)" "$out"
rm -f "$MAIN/packages/a/node_modules/a-src"
st_pass "ABSLINK: absolute link into the source ⇒ skipped, the lockfile's other trees removed"

# ---- IGNORE ------------------------------------------------------------------------
IG="$WORK/src/noignore"; mkdir -p "$IG"
( cd "$IG" && git init -q -b master && printf '{}\n' > package.json && printf '{}\n' > package-lock.json && git add -A && git commit -qm i \
  && mkdir -p node_modules/z && : > node_modules/.package-lock.json )
W=$(newwt "$IG"); out=$("$DS" "$W" "$IG")
printf '%s\n' "$out" | grep -qx "skipped:not-ignored \\." && [ -z "$(git -C "$W" status --porcelain)" ] \
  || st_fail "IGNORE: an un-ignored node_modules was cloned" "$out"
st_pass "IGNORE: node_modules not git-ignored ⇒ skipped, status clean"

# ---- SETUP: through fleet_worktree_create --------------------------------------------
drop_wts
W=$(FLEET_DEPS_SHARE=1 fleet_worktree_create "$MAIN" scratch-71 "") || st_fail "SETUP: worktree not created"
[ -d "$W/node_modules" ] && rec "$W" | grep -qx "clone:copy \\. $MAIN" || st_fail "SETUP: create did not share" "$(rec "$W")"
drop_wts; W=$(FLEET_DEPS_SHARE=0 fleet_worktree_create "$MAIN" scratch-72 "") || st_fail "SETUP: worktree not created (off)"
[ ! -e "$W/node_modules" ] && [ "$(rec "$W")" = "none ." ] || st_fail "SETUP: FLEET_DEPS_SHARE=0 still shared"
W=$(FLEET_DEPS_SHARE=1 FLEET_DEPS_SHARE_CLONE=off fleet_worktree_create "$MAIN" scratch-73 "") || st_fail "SETUP: a failing share blocked the worktree"
[ -d "$W" ] && [ ! -e "$W/node_modules" ] || st_fail "SETUP: no-clone left something"
st_pass "SETUP: explicit sharing works; 0 disables; a failing share never blocks the worktree"

W=$(fleet_worktree_create "$MAIN" scratch-74 "") || st_fail "DEFAULT: worktree not created"
[ ! -e "$W/node_modules" ] && [ "$(rec "$W")" = "none ." ] || st_fail "DEFAULT: unselected dependency sharing ran"
(
  fleet_timebox() { printf 'unexpected share\n' >> "$WORK/unexpected-share"; }
  unset FLEET_DEPS_SHARE
  fleet_worktree_deps_share "$MAIN" "$W"
  for setting in '' 0 invalid; do
    FLEET_DEPS_SHARE=$setting fleet_worktree_deps_share "$MAIN" "$W"
  done
)
[ ! -e "$WORK/unexpected-share" ] || st_fail "DEFAULT: unselected sharing started its helper"
st_pass "DEFAULT: unset, empty, zero and invalid selections do not start the sharing helper"

export SETUP_CALLS="$WORK/custom-setup-calls"
cat > "$WORK/custom-setup" <<'SH'
#!/bin/sh
printf '%s|%s|%s\n' "$PWD" "$1" "$2" >> "$SETUP_CALLS"
touch "$1/setup-ran"
SH
chmod +x "$WORK/custom-setup"
W=$(FLEET_WORKTREE_SETUP="$WORK/custom-setup" fleet_worktree_create "$MAIN" scratch-75 "") \
  || st_fail "CUSTOM: worktree not created"
[ "$(cat "$SETUP_CALLS")" = "$W|$W|$MAIN" ] && [ -f "$W/setup-ran" ] \
  && [ ! -e "$W/node_modules" ] && [ "$(rec "$W")" = "none ." ] \
  || st_fail "CUSTOM: explicit setup changed or implicitly opted into dependency sharing"
st_pass "CUSTOM: explicit project setup runs once without enabling dependency sharing"

# ---- NATIVE: this filesystem's own clone ------------------------------------------------
drop_wts
W=$(newwt "$MAIN"); out=$(env -u FLEET_DEPS_SHARE_CLONE "$DS" "$W" "$MAIN")
line=$(printf '%s\n' "$out" | awk '$2 == "." { print $1 " ."; exit }')
case "$line" in
  "clone:clonefile ."*|"clone:reflink ."*)
    [ "$(cat "$W/node_modules/lodash/index.js")" = base ] || st_fail "NATIVE: clone has the wrong bytes" ;;
  "skipped:no-clone .")
    [ ! -e "$W/node_modules" ] || st_fail "NATIVE: no-clone left a tree" ;;
  *) st_fail "NATIVE: unexpected verdict" "$out" ;;
esac
[ "$(uname -s)" != Darwin ] || case "$line" in skipped:*) ;; *) [ "${line%% *}" = clone:clonefile ] || st_fail "NATIVE: macOS did not use clonefile" "$line" ;; esac
st_pass "NATIVE: $line"

printf 'fleet-deps-share-selftest: %s passed\n' "$pass"
