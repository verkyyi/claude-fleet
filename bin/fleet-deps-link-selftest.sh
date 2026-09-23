#!/bin/bash
# fleet-deps-link-selftest.sh — hermetic tests for borrowed dependencies (issue
# #885): the FLEET_WORKTREE_SETUP hook in fleet_worktree_create, the stock hook
# bin/fleet-deps-link.sh, the shared-deps rail in hooks/bash-guard.py, and the
# link-only removal in fleet_worktree_drop.
#
# Why: a JS worktree installed 3–6 GB / >200k files that were byte-identical to
# the base checkout's. Borrowing the base's node_modules by symlink removes that —
# but a borrowed tree is SHARED, so the guarantees below are what make it safe.
#
# Asserts:
#   DEFAULT    FLEET_WORKTREE_SETUP unset ⇒ no node_modules, no log: today's behaviour.
#   LINK       lockfile identical ⇒ `linked .`, a symlink to the base's tree, recorded
#              in the manifest, and `git status --porcelain` stays EMPTY.
#   DIFFER     lockfile differs ⇒ `installed-needed`, no link.
#   LOCAL      base node_modules links into repo source ⇒ `skipped:local-link`;
#              a pnpm-style link into node_modules/.pnpm is NOT a local link.
#   MEMBER     a lockfile-less member of a linked root is linked; of an unlinked
#              root it is `skipped:root-not-linked`.
#   DRYRUN     --dry-run prints the verdict and creates nothing.
#   GUARD      npm/pnpm/yarn install|add|ci in a linked dir (direct, `cd x &&`,
#              --prefix) is DENIED and the base's tree is untouched; `npm run`, a
#              global install, an unlinked dir and a plain checkout are allowed.
#   UNLINK     --unlink removes the LINK only (base intact), updates the manifest,
#              and the guard lets the install through afterwards.
#   FAILSAFE   a hook that fails, or outlives FLEET_WORKTREE_SETUP_TIMEOUT, is
#              logged and the worktree is still created (and promptly).
#   DROP       fleet_worktree_drop on a linked worktree drops the LINK; the trash
#              sweep never reaches the base's tree.
#
# Real git, temp dirs, fake node_modules — no network, no npm, no tmux.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
DL="$BIN/fleet-deps-link.sh"
GUARD="$BIN/../hooks/bash-guard.py"
[ -f "$LIB" ] && [ -x "$DL" ] && [ -f "$GUARD" ] || { printf 'selftest: missing pieces\n' >&2; exit 2; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not on PATH — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not on PATH — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-deps-link.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

export HOME="$WORK/home"; mkdir -p "$HOME"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$WORK/home/.gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export FLEET_WORKTREE_SETUP_LOG="$WORK/setup.log"
unset FLEET_WORKTREE_ROOT FLEET_WORKTREE_SETUP FLEET_WORKTREE_SETUP_TIMEOUT FLEET_MAIN TMUX TMUX_PANE

# shellcheck source=/dev/null
. "$LIB"

# ---- the base checkout: root (npm) + packages/a (member) + tools (own lock) ----
MAIN="$WORK/src/repo"
mkdir -p "$MAIN/packages/a" "$MAIN/tools" "$MAIN/web"
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
git add -A && git commit -qm init
mkdir -p node_modules/lodash packages/a/node_modules/left-pad tools/node_modules/x \
         web/node_modules/.pnpm/react@1/node_modules/react
: > node_modules/lodash/index.js
: > packages/a/node_modules/left-pad/index.js
ln -s ../../packages/a tools/node_modules/a-src            # workspace link → source
ln -s .pnpm/react@1/node_modules/react web/node_modules/react   # pnpm store link
snap() { find "$MAIN/node_modules" "$MAIN/packages/a/node_modules" | sort; }
BASE_SNAP=$(snap)

# ---- DEFAULT --------------------------------------------------------------
WT0=$(fleet_worktree_create "$MAIN" scratch-0 "") || fail "create (default)"
[ ! -e "$WT0/node_modules" ] || fail "DEFAULT: node_modules appeared with the hook unset"
[ ! -e "$FLEET_WORKTREE_SETUP_LOG" ] || fail "DEFAULT: a setup log was written with the hook unset"
ok "DEFAULT: FLEET_WORKTREE_SETUP unset ⇒ no link, no log"

# ---- DRYRUN (on the default worktree) --------------------------------------
out=$(cd "$WT0" && "$DL" --dry-run)
printf '%s\n' "$out" | grep -qx 'linked .' || fail "DRYRUN: root verdict" "$out"
[ ! -e "$WT0/node_modules" ] || fail "DRYRUN created a link"
ok "DRYRUN: verdict printed, nothing created"

# ---- LINK / MEMBER / LOCAL / DIFFER via the hook ---------------------------
# tools' yarn.lock differs in the worktree's branch? No — same commit, so make the
# DIFFER case by editing web's lock on the branch before linking: run by hand.
export FLEET_WORKTREE_SETUP=bin/fleet-deps-link.sh FLEET_MAIN="$MAIN"
WT=$(fleet_worktree_create "$MAIN" scratch-1 "") || fail "create (hook)"
grep -q "ok $WT" "$FLEET_WORKTREE_SETUP_LOG" || fail "hook did not log ok" "$(cat "$FLEET_WORKTREE_SETUP_LOG")"
[ -L "$WT/node_modules" ] && [ "$(readlink "$WT/node_modules")" = "$MAIN/node_modules" ] \
  || fail "LINK: root node_modules is not a link to the base's" "$(ls -la "$WT")"
[ -z "$(git -C "$WT" status --porcelain)" ] || fail "LINK: worktree reads dirty" "$(git -C "$WT" status --porcelain)"
MF="$(git -C "$WT" rev-parse --absolute-git-dir)/fleet-deps-links"
grep -qx . "$MF" || fail "LINK: manifest lacks ." "$(cat "$MF" 2>&1)"
ok "LINK: identical lockfile ⇒ symlink into the base, recorded, status clean"

[ -L "$WT/packages/a/node_modules" ] || fail "MEMBER: member of a linked root not linked"
grep -qx packages/a "$MF" || fail "MEMBER: member not in the manifest"
ok "MEMBER: lockfile-less member of a linked root is linked"

[ ! -e "$WT/tools/node_modules" ] || fail "LOCAL: tools linked despite a source link in the base"
[ -L "$WT/web/node_modules" ] || fail "LOCAL: pnpm store link wrongly read as a local link"
out=$("$DL" --dry-run "$WT" "$MAIN")
printf '%s\n' "$out" | grep -qx 'skipped:local-link tools' || fail "LOCAL: verdict line" "$out"
ok "LOCAL: workspace link ⇒ skipped:local-link; pnpm .pnpm link ⇒ linked"

WT2=$(FLEET_WORKTREE_SETUP="" fleet_worktree_create "$MAIN" scratch-2 "") || fail "create (differ)"
printf 'lockfileVersion: 10\n' > "$WT2/web/pnpm-lock.yaml"
printf '{"lockfileVersion":4}\n' > "$WT2/package-lock.json"
out=$("$DL" "$WT2" "$MAIN")
printf '%s\n' "$out" | grep -qx 'installed-needed web' || fail "DIFFER: web verdict" "$out"
printf '%s\n' "$out" | grep -qx 'installed-needed .' || fail "DIFFER: root verdict" "$out"
printf '%s\n' "$out" | grep -qx 'skipped:root-not-linked packages/a' || fail "MEMBER: unlinked-root member" "$out"
[ ! -e "$WT2/web/node_modules" ] && [ ! -e "$WT2/node_modules" ] && [ ! -e "$WT2/packages/a/node_modules" ] \
  || fail "DIFFER: something was linked"
ok "DIFFER: changed lockfile ⇒ installed-needed; its member ⇒ skipped:root-not-linked"

# ---- GUARD ----------------------------------------------------------------
guard() {  # <cwd> <command> → rc
  python3 - "$1" "$2" <<'PY' | python3 "$GUARD" >/dev/null 2>"$WORK/guard.err"
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[2]}, "cwd": sys.argv[1]}))
PY
}
deny()  { guard "$1" "$2"; [ $? -eq 2 ] || fail "GUARD should deny: [$1] $2"; }
allow() { guard "$1" "$2"; [ $? -eq 0 ] || fail "GUARD should allow: [$1] $2" "$(cat "$WORK/guard.err")"; }
deny  "$WT" "npm install"
grep -q 'fleet-deps-link.sh --unlink' "$WORK/guard.err" || fail "GUARD: denial lacks the --unlink hint" "$(cat "$WORK/guard.err")"
deny  "$WT" "npm i lodash"
deny  "$WT" "npm ci"
deny  "$WT" "yarn"
deny  "$WT" "pnpm add react"
deny  "$WT/packages/a" "npm uninstall left-pad"
deny  "$WT/src" "npm install"                        # no package.json here → walks up to root
deny  "$WORK" "cd $WT/packages/a && npm install"
deny  "$WORK" "npm --prefix $WT install"
deny  "$WT" "git status; (cd packages/a && yarn add x)"
allow "$WT" "npm run build"
allow "$WT" "npm test && npx tsc"
allow "$WT" "npm install -g typescript"
allow "$WT" "echo 'npm install'"
allow "$WT2" "npm install"                           # nothing linked there
allow "$MAIN" "npm install"                          # the base checkout itself
[ "$(snap)" = "$BASE_SNAP" ] || fail "GUARD: base tree changed"
ok "GUARD: mutating installs in a linked dir denied (direct, cd, --prefix, subshell); reads/global/unlinked allowed"

# ---- UNLINK ---------------------------------------------------------------
out=$(cd "$WT/packages/a" && "$DL" --unlink node_modules)
[ "$out" = 'unlinked packages/a' ] || fail "UNLINK: member line" "$out"
[ ! -e "$WT/packages/a/node_modules" ] && [ -L "$WT/node_modules" ] && [ -L "$WT/web/node_modules" ] \
  || fail "UNLINK: wrong set removed"
grep -qx packages/a "$MF" && fail "UNLINK: manifest still lists packages/a"
out=$(cd "$WT" && "$DL" --unlink .)
printf '%s\n' "$out" | grep -qx 'unlinked .' && printf '%s\n' "$out" | grep -qx 'unlinked web' \
  || fail "UNLINK: . must take every link beneath it" "$out"
[ ! -e "$WT/node_modules" ] && [ ! -e "$WT/web/node_modules" ] || fail "UNLINK: link survived"
[ "$(snap)" = "$BASE_SNAP" ] && [ -d "$MAIN/web/node_modules/.pnpm" ] || fail "UNLINK: base tree changed"
allow "$WT" "npm install"
out=$(cd "$WT" && "$DL" --unlink .)
[ "$out" = 'not-linked .' ] || fail "UNLINK: idempotent re-run" "$out"
ok "UNLINK: link-only removal (member alone, or a dir + all beneath); base intact; guard releases"

# ---- FAILSAFE -------------------------------------------------------------
printf '#!/bin/sh\necho boom; exit 3\n' > "$WORK/bad.sh"; chmod +x "$WORK/bad.sh"
printf '#!/bin/sh\nsleep 30\n' > "$WORK/slow.sh"; chmod +x "$WORK/slow.sh"
WT3=$(FLEET_WORKTREE_SETUP="$WORK/bad.sh" fleet_worktree_create "$MAIN" scratch-3 "") || fail "FAILSAFE: failing hook failed the create"
[ -d "$WT3" ] && grep -q "FAILED rc=3 $WT3" "$FLEET_WORKTREE_SETUP_LOG" && grep -q boom "$FLEET_WORKTREE_SETUP_LOG" \
  || fail "FAILSAFE: failure not logged" "$(cat "$FLEET_WORKTREE_SETUP_LOG")"
t0=$SECONDS
WT4=$(FLEET_WORKTREE_SETUP="$WORK/slow.sh" FLEET_WORKTREE_SETUP_TIMEOUT=2 fleet_worktree_create "$MAIN" scratch-4 "") \
  || fail "FAILSAFE: slow hook failed the create"
[ $((SECONDS - t0)) -lt 15 ] || fail "FAILSAFE: timebox not enforced ($((SECONDS - t0))s)"
[ -d "$WT4" ] && grep -q "TIMEOUT after 2s $WT4" "$FLEET_WORKTREE_SETUP_LOG" || fail "FAILSAFE: timeout not logged" "$(cat "$FLEET_WORKTREE_SETUP_LOG")"
FLEET_WORKTREE_SETUP="$WORK/nope.sh" fleet_worktree_create "$MAIN" scratch-5 "" >/dev/null || fail "FAILSAFE: missing hook failed the create"
grep -q "not executable: $WORK/nope.sh" "$FLEET_WORKTREE_SETUP_LOG" || fail "FAILSAFE: missing hook not logged"
ok "FAILSAFE: failing / timed-out / missing hook ⇒ logged, worktree still created"

# ---- DROP -----------------------------------------------------------------
WT6=$(fleet_worktree_create "$MAIN" scratch-6 "") || fail "create (drop)"
[ -L "$WT6/node_modules" ] || fail "DROP: setup did not link"
tok=$(fleet_worktree_drop "$MAIN" "$WT6") || fail "DROP: drop refused a linked worktree" "$tok"
case "$tok" in trashed:*) ;; *) fail "DROP: unexpected token" "$tok" ;; esac
[ ! -e "${tok#trashed:}/node_modules" ] && [ ! -L "${tok#trashed:}/node_modules" ] || fail "DROP: link went to the trash"
fleet_trash_sweep "$MAIN" 0 >/dev/null
[ "$(snap)" = "$BASE_SNAP" ] || fail "DROP: base tree changed"
ok "DROP: link removed before the trash; sweep leaves the base intact"

printf 'fleet-deps-link-selftest: %d checks passed\n' "$pass"
