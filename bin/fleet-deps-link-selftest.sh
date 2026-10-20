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
#   STALE      (issue #961) the base's lockfile moved but its node_modules was not
#              reinstalled (stamp = the OLD sha) ⇒ `installed-needed:base-stale`, no
#              link; no stamp ⇒ `installed-needed:base-unstamped`; a reinstall in
#              flight (.fleet-installing) ⇒ base-stale.
#   REFRESH    --refresh-base <main> <old> <new> reinstalls exactly the dir whose
#              lockfile changed, stamps it, and a new worktree then LINKS; a quiet
#              second run does nothing; a failing install leaves it unstamped (not
#              linked) and FAILING (issue #1026): the next ticks do NOT re-run it
#              while its lockfile is unchanged (one `still failing since` line, then
#              silence), a lockfile change retries it, `--refresh-base <main> <dir>`
#              forces it, and a success clears the marker.
#   TRANSIENT  (issue #1028) the install's output classifies a failure: network /
#              corrupt cache retries itself with doubling backoff (npm cache verify
#              first after corruption) and parks only past the cap; lock drift,
#              native build, lifecycle script and unknown park at once; a legacy
#              (unclassified) marker is retried once.
#   DOCTOR     fleet-doctor's deps row: `failing (transient, retry at …)` vs
#              `failing (parked: <why>)`.
#   PRIME      --prime-base installs + stamps every lockfile dir (npm / yarn / pnpm
#              each with its frozen-lockfile form); --base-status counts them; a
#              tracked lockfile the install rewrote is restored (base stays clean).
#              pnpm absent from the (daemon's) PATH is resolved from the login
#              shell's PATH and run from there (issue #1026).
#
# Real git, temp dirs, fake node_modules — no network, no npm, no tmux.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
LIB="$BIN/fleet-lib.sh"
DL="$BIN/fleet-deps-link.sh"
GUARD="$BIN/../hooks/bash-guard.py"
[ -f "$LIB" ] && [ -x "$DL" ] && [ -f "$GUARD" ] || { printf 'selftest: missing pieces\n' >&2; exit 2; }
st_need git python3

st_sandbox "${TMPDIR:-/tmp}/fleet-deps-link.XXXXXX" physical
trap 'exit 130' INT TERM HUP

pass=0

export HOME="$WORK/home"; mkdir -p "$HOME"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$WORK/home/.gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export FLEET_WORKTREE_SETUP_LOG="$WORK/setup.log"
unset FLEET_WORKTREE_ROOT FLEET_WORKTREE_SETUP FLEET_WORKTREE_SETUP_TIMEOUT FLEET_MAIN TMUX TMUX_PANE
# The built-in clone of #3403 runs on every new worktree too; this test is about
# the symlink hook alone, so it is off here (fleet-deps-share-selftest.sh has it).
export FLEET_DEPS_SHARE=0

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
# A base install is trusted only when stamped with its lockfile's sha (issue #961):
# stamp these as a --prime-base would have.
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1"; else sha256sum < "$1"; fi | cut -d' ' -f1; }
stamp() { sha "$MAIN/$1/$2" > "$MAIN/$1/node_modules/.fleet-lock-sha"; }
stamp . package-lock.json; stamp tools yarn.lock; stamp web pnpm-lock.yaml
snap() { find "$MAIN/node_modules" "$MAIN/packages/a/node_modules" | sort; }
BASE_SNAP=$(snap)

# ---- DEFAULT --------------------------------------------------------------
WT0=$(fleet_worktree_create "$MAIN" scratch-0 "") || st_fail "create (default)"
[ ! -e "$WT0/node_modules" ] || st_fail "DEFAULT: node_modules appeared with the hook unset"
[ ! -e "$FLEET_WORKTREE_SETUP_LOG" ] || st_fail "DEFAULT: a setup log was written with the hook unset"
st_pass "DEFAULT: FLEET_WORKTREE_SETUP unset ⇒ no link, no log"

# ---- DRYRUN (on the default worktree) --------------------------------------
out=$(cd "$WT0" && "$DL" --dry-run)
printf '%s\n' "$out" | grep -qx 'linked .' || st_fail "DRYRUN: root verdict" "$out"
[ ! -e "$WT0/node_modules" ] || st_fail "DRYRUN created a link"
st_pass "DRYRUN: verdict printed, nothing created"

# ---- LINK / MEMBER / LOCAL / DIFFER via the hook ---------------------------
# tools' yarn.lock differs in the worktree's branch? No — same commit, so make the
# DIFFER case by editing web's lock on the branch before linking: run by hand.
export FLEET_WORKTREE_SETUP=bin/fleet-deps-link.sh FLEET_MAIN="$MAIN"
WT=$(fleet_worktree_create "$MAIN" scratch-1 "") || st_fail "create (hook)"
grep -q "ok $WT" "$FLEET_WORKTREE_SETUP_LOG" || st_fail "hook did not log ok" "$(cat "$FLEET_WORKTREE_SETUP_LOG")"
[ -L "$WT/node_modules" ] && [ "$(readlink "$WT/node_modules")" = "$MAIN/node_modules" ] \
  || st_fail "LINK: root node_modules is not a link to the base's" "$(ls -la "$WT")"
[ -z "$(git -C "$WT" status --porcelain)" ] || st_fail "LINK: worktree reads dirty" "$(git -C "$WT" status --porcelain)"
MF="$(git -C "$WT" rev-parse --absolute-git-dir)/fleet-deps-links"
grep -qx . "$MF" || st_fail "LINK: manifest lacks ." "$(cat "$MF" 2>&1)"
st_pass "LINK: identical lockfile ⇒ symlink into the base, recorded, status clean"

[ -L "$WT/packages/a/node_modules" ] || st_fail "MEMBER: member of a linked root not linked"
grep -qx packages/a "$MF" || st_fail "MEMBER: member not in the manifest"
st_pass "MEMBER: lockfile-less member of a linked root is linked"

[ ! -e "$WT/tools/node_modules" ] || st_fail "LOCAL: tools linked despite a source link in the base"
[ -L "$WT/web/node_modules" ] || st_fail "LOCAL: pnpm store link wrongly read as a local link"
out=$("$DL" --dry-run "$WT" "$MAIN")
printf '%s\n' "$out" | grep -qx 'skipped:local-link tools' || st_fail "LOCAL: verdict line" "$out"
st_pass "LOCAL: workspace link ⇒ skipped:local-link; pnpm .pnpm link ⇒ linked"

WT2=$(FLEET_WORKTREE_SETUP="" fleet_worktree_create "$MAIN" scratch-2 "") || st_fail "create (differ)"
printf 'lockfileVersion: 10\n' > "$WT2/web/pnpm-lock.yaml"
printf '{"lockfileVersion":4}\n' > "$WT2/package-lock.json"
out=$("$DL" "$WT2" "$MAIN")
printf '%s\n' "$out" | grep -qx 'installed-needed web' || st_fail "DIFFER: web verdict" "$out"
printf '%s\n' "$out" | grep -qx 'installed-needed .' || st_fail "DIFFER: root verdict" "$out"
printf '%s\n' "$out" | grep -qx 'skipped:root-not-linked packages/a' || st_fail "MEMBER: unlinked-root member" "$out"
[ ! -e "$WT2/web/node_modules" ] && [ ! -e "$WT2/node_modules" ] && [ ! -e "$WT2/packages/a/node_modules" ] \
  || st_fail "DIFFER: something was linked"
st_pass "DIFFER: changed lockfile ⇒ installed-needed; its member ⇒ skipped:root-not-linked"

# ---- GUARD ----------------------------------------------------------------
guard() {  # <cwd> <command> → rc
  python3 - "$1" "$2" <<'PY' | python3 "$GUARD" >/dev/null 2>"$WORK/guard.err"
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[2]}, "cwd": sys.argv[1]}))
PY
}
deny()  { guard "$1" "$2"; [ $? -eq 2 ] || st_fail "GUARD should deny: [$1] $2"; }
allow() { guard "$1" "$2"; [ $? -eq 0 ] || st_fail "GUARD should allow: [$1] $2" "$(cat "$WORK/guard.err")"; }
deny  "$WT" "npm install"
grep -q 'fleet-deps-link.sh --unlink' "$WORK/guard.err" || st_fail "GUARD: denial lacks the --unlink hint" "$(cat "$WORK/guard.err")"
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
[ "$(snap)" = "$BASE_SNAP" ] || st_fail "GUARD: base tree changed"
st_pass "GUARD: mutating installs in a linked dir denied (direct, cd, --prefix, subshell); reads/global/unlinked allowed"

# ---- UNLINK ---------------------------------------------------------------
out=$(cd "$WT/packages/a" && "$DL" --unlink node_modules)
[ "$out" = 'unlinked packages/a' ] || st_fail "UNLINK: member line" "$out"
[ ! -e "$WT/packages/a/node_modules" ] && [ -L "$WT/node_modules" ] && [ -L "$WT/web/node_modules" ] \
  || st_fail "UNLINK: wrong set removed"
grep -qx packages/a "$MF" && st_fail "UNLINK: manifest still lists packages/a"
out=$(cd "$WT" && "$DL" --unlink .)
printf '%s\n' "$out" | grep -qx 'unlinked .' && printf '%s\n' "$out" | grep -qx 'unlinked web' \
  || st_fail "UNLINK: . must take every link beneath it" "$out"
[ ! -e "$WT/node_modules" ] && [ ! -e "$WT/web/node_modules" ] || st_fail "UNLINK: link survived"
[ "$(snap)" = "$BASE_SNAP" ] && [ -d "$MAIN/web/node_modules/.pnpm" ] || st_fail "UNLINK: base tree changed"
allow "$WT" "npm install"
out=$(cd "$WT" && "$DL" --unlink .)
[ "$out" = 'not-linked .' ] || st_fail "UNLINK: idempotent re-run" "$out"
st_pass "UNLINK: link-only removal (member alone, or a dir + all beneath); base intact; guard releases"

# ---- FAILSAFE -------------------------------------------------------------
printf '#!/bin/sh\necho boom; exit 3\n' > "$WORK/bad.sh"; chmod +x "$WORK/bad.sh"
printf '#!/bin/sh\nsleep 30\n' > "$WORK/slow.sh"; chmod +x "$WORK/slow.sh"
WT3=$(FLEET_WORKTREE_SETUP="$WORK/bad.sh" fleet_worktree_create "$MAIN" scratch-3 "") || st_fail "FAILSAFE: failing hook failed the create"
[ -d "$WT3" ] && grep -q "FAILED rc=3 $WT3" "$FLEET_WORKTREE_SETUP_LOG" && grep -q boom "$FLEET_WORKTREE_SETUP_LOG" \
  || st_fail "FAILSAFE: failure not logged" "$(cat "$FLEET_WORKTREE_SETUP_LOG")"
t0=$SECONDS
WT4=$(FLEET_WORKTREE_SETUP="$WORK/slow.sh" FLEET_WORKTREE_SETUP_TIMEOUT=2 fleet_worktree_create "$MAIN" scratch-4 "") \
  || st_fail "FAILSAFE: slow hook failed the create"
[ $((SECONDS - t0)) -lt 15 ] || st_fail "FAILSAFE: timebox not enforced ($((SECONDS - t0))s)"
[ -d "$WT4" ] && grep -q "TIMEOUT after 2s $WT4" "$FLEET_WORKTREE_SETUP_LOG" || st_fail "FAILSAFE: timeout not logged" "$(cat "$FLEET_WORKTREE_SETUP_LOG")"
FLEET_WORKTREE_SETUP="$WORK/nope.sh" fleet_worktree_create "$MAIN" scratch-5 "" >/dev/null || st_fail "FAILSAFE: missing hook failed the create"
grep -q "not executable: $WORK/nope.sh" "$FLEET_WORKTREE_SETUP_LOG" || st_fail "FAILSAFE: missing hook not logged"
st_pass "FAILSAFE: failing / timed-out / missing hook ⇒ logged, worktree still created"

# ---- DROP -----------------------------------------------------------------
WT6=$(fleet_worktree_create "$MAIN" scratch-6 "") || st_fail "create (drop)"
[ -L "$WT6/node_modules" ] || st_fail "DROP: setup did not link"
tok=$(fleet_worktree_drop "$MAIN" "$WT6") || st_fail "DROP: drop refused a linked worktree" "$tok"
case "$tok" in trashed:*) ;; *) st_fail "DROP: unexpected token" "$tok" ;; esac
[ ! -e "${tok#trashed:}/node_modules" ] && [ ! -L "${tok#trashed:}/node_modules" ] || st_fail "DROP: link went to the trash"
fleet_trash_sweep "$MAIN" 0 >/dev/null
[ "$(snap)" = "$BASE_SNAP" ] || st_fail "DROP: base tree changed"
st_pass "DROP: link removed before the trash; sweep leaves the base intact"

# ---- STALE (issue #961) ------------------------------------------------------
# The base fast-forwards to a commit that bumps the root lockfile; its node_modules
# still carries the OLD stamp. A fresh worktree's lockfile matches the base's —
# exactly the case the lockfile compare alone got wrong.
unset FLEET_WORKTREE_SETUP
OLD=$(git -C "$MAIN" rev-parse HEAD)
printf '{"lockfileVersion":3,"bump":1}\n' > "$MAIN/package-lock.json"
git -C "$MAIN" commit -qam 'bump root deps'
NEW=$(git -C "$MAIN" rev-parse HEAD)
git -C "$MAIN" worktree add -q "$WORK/wt-stale" -b wt-stale >/dev/null 2>&1 || st_fail "STALE: worktree add"
out=$("$DL" --dry-run "$WORK/wt-stale" "$MAIN")
printf '%s\n' "$out" | grep -qx 'installed-needed:base-stale .' || st_fail "STALE: stamp of the old lockfile must not link" "$out"
printf '%s\n' "$out" | grep -qx 'skipped:root-not-linked packages/a' || st_fail "STALE: member of a stale root" "$out"
printf '%s\n' "$out" | grep -qx 'linked web' || st_fail "STALE: an untouched fresh dir still links" "$out"
mv "$MAIN/node_modules/.fleet-lock-sha" "$WORK/stamp.bak"
out=$("$DL" --dry-run "$WORK/wt-stale" "$MAIN")
printf '%s\n' "$out" | grep -qx 'installed-needed:base-unstamped .' || st_fail "STALE: no stamp must not link" "$out"
stamp . package-lock.json; : > "$MAIN/node_modules/.fleet-installing"
out=$("$DL" --dry-run "$WORK/wt-stale" "$MAIN")
printf '%s\n' "$out" | grep -qx 'installed-needed:base-stale .' || st_fail "STALE: a reinstall in flight must not link" "$out"
rm -f "$MAIN/node_modules/.fleet-installing"; mv "$WORK/stamp.bak" "$MAIN/node_modules/.fleet-lock-sha"
st_pass "STALE: old stamp / no stamp / install in flight ⇒ installed-needed:base-*, no link"

# ---- REFRESH ---------------------------------------------------------------
# Fake package managers: record the call, make a node_modules, exit $FAKE_RC.
FB="$WORK/fakebin"; mkdir -p "$FB"
for pm in npm yarn pnpm; do
  cat > "$FB/$pm" <<FAKE
#!/bin/sh
printf '%s %s %s\n' "\$(pwd -P)" "$pm" "\$*" >> "$WORK/pm.calls"
[ -z "\${FAKE_OUT:-}" ] || printf '%b\\n' "\$FAKE_OUT" >&2
[ "\${FAKE_RC:-0}" = 0 ] || exit "\$FAKE_RC"
mkdir -p node_modules/fresh-from-$pm
[ "$pm" != yarn ] || printf '# rewritten by yarn\\n' >> yarn.lock   # yarn v1 does this for real
FAKE
  chmod +x "$FB/$pm"
done
export PATH="$FB:$PATH" FLEET_BASE_DEPS_LOG="$WORK/base-deps.log"
: > "$WORK/pm.calls"
out=$(FAKE_RC=1 "$DL" --refresh-base "$MAIN" "$OLD" "$NEW")
printf '%s\n' "$out" | grep -qx 'install-failed:rc=1 .' || st_fail "REFRESH: failing install verdict" "$out"
[ ! -e "$MAIN/node_modules/.fleet-lock-sha" ] || st_fail "REFRESH: a failed install left a stamp"
[ ! -e "$MAIN/node_modules/.fleet-installing" ] || st_fail "REFRESH: a failed install left the in-flight marker"
[ "$(cut -d' ' -f1 "$MAIN/node_modules/.fleet-install-failed" 2>/dev/null)" = "$(sha "$MAIN/package-lock.json")" ] \
  || st_fail "REFRESH: failure marker must carry the lockfile's sha" "$(cat "$MAIN/node_modules/.fleet-install-failed" 2>&1)"
out=$("$DL" --dry-run "$WORK/wt-stale" "$MAIN")
printf '%s\n' "$out" | grep -qx 'installed-needed:base-failing .' || st_fail "REFRESH: failed install must not link" "$out"
out=$("$DL" --base-status "$MAIN")
printf '%s\n' "$out" | grep -qx 'failing .' || st_fail "REFRESH: status must say failing" "$out"
printf '%s\n' "$out" | grep -q '^summary .* failing=1 .* failing-since=20[0-9-]*T' || st_fail "REFRESH: summary failing count + since" "$out"
# The next ticks: same lockfile ⇒ NOT re-run (issue #1026). One log line, then silence.
: > "$WORK/pm.calls"
out=$(FAKE_RC=1 "$DL" --refresh-base "$MAIN")
[ "$out" = "skipped:failing ." ] && [ ! -s "$WORK/pm.calls" ] || st_fail "REFRESH: a failing dir with an unchanged lock was re-run" "$out / $(cat "$WORK/pm.calls")"
out=$(FAKE_RC=1 "$DL" --refresh-base "$MAIN")
[ -z "$out" ] && [ ! -s "$WORK/pm.calls" ] || st_fail "REFRESH: 2nd skip must be silent and install nothing" "$out / $(cat "$WORK/pm.calls")"
[ "$(grep -c "$MAIN still failing since" "$WORK/base-deps.log")" = 1 ] || st_fail "REFRESH: expected ONE still-failing log line" "$(cat "$WORK/base-deps.log")"
# A lockfile change is a new attempt.
cp "$MAIN/package-lock.json" "$WORK/lock.bak"; printf '{"lockfileVersion":3,"bump":2}\n' > "$MAIN/package-lock.json"
out=$(FAKE_RC=1 "$DL" --refresh-base "$MAIN")
printf '%s\n' "$out" | grep -qx 'install-failed:rc=1 .' && grep -qx "$MAIN npm ci" "$WORK/pm.calls" \
  || st_fail "REFRESH: a lockfile change must retry a failing dir" "$out / $(cat "$WORK/pm.calls")"
cp "$WORK/lock.bak" "$MAIN/package-lock.json"
# The explicit retry: --refresh-base <main> <dir> forces a failing dir, lock unchanged.
out=$(FAKE_RC=1 "$DL" --refresh-base "$MAIN")    # back on the committed lock ⇒ a change ⇒ one run
: > "$WORK/pm.calls"
out=$("$DL" --refresh-base "$MAIN")
[ "$out" = "skipped:failing ." ] && [ ! -s "$WORK/pm.calls" ] || st_fail "REFRESH: re-failed dir must be parked again" "$out"
out=$("$DL" --refresh-base "$MAIN" .)
[ "$out" = "installed ." ] || st_fail "REFRESH: --refresh-base <main> <dir> must force the retry" "$out"
grep -qx "$MAIN npm ci" "$WORK/pm.calls" || st_fail "REFRESH: expected npm ci in the base root" "$(cat "$WORK/pm.calls")"
[ ! -e "$MAIN/node_modules/.fleet-install-failed" ] || st_fail "REFRESH: a success must clear the failure marker"
[ "$(cat "$MAIN/node_modules/.fleet-lock-sha")" = "$(sha "$MAIN/package-lock.json")" ] || st_fail "REFRESH: stamp is not the new lockfile's sha"
grep -q "$MAIN ok" "$WORK/base-deps.log" || st_fail "REFRESH: install not logged" "$(cat "$WORK/base-deps.log")"
out=$("$DL" "$WORK/wt-stale" "$MAIN")
printf '%s\n' "$out" | grep -qx 'linked .' || st_fail "REFRESH: reinstalled base must link" "$out"
: > "$WORK/pm.calls"
out=$("$DL" --refresh-base "$MAIN" "$NEW" "$NEW")
[ -z "$out" ] && [ ! -s "$WORK/pm.calls" ] || st_fail "REFRESH: a quiet run must install nothing" "$out"
st_pass "REFRESH: changed lockfile ⇒ reinstall + stamp ⇒ link; failure ⇒ parked until the lock changes or a forced retry; quiet run is a no-op"

# ---- TRANSIENT (issue #1028) ------------------------------------------------
# The install's output classifies the failure: a transient one (network, a corrupt
# npm cache/extract) retries itself with backoff and is parked only past the cap;
# a deterministic one (lock drift, native build, …) parks at once, as in #1026.
mk() { cut -d' ' -f"$1" "$MAIN/node_modules/.fleet-install-failed" 2>/dev/null; }
T0=2000000000; export FLEET_BASE_DEPS_RETRY_BASE=300 FLEET_BASE_DEPS_RETRY_CAP=1000
CORRUPT='npm warn tarball tarball data for yallist@4.0.0 seems to be corrupted. Trying again.\nnpm error code ENOENT\nnpm error ENOENT: Cannot cd into /x/node_modules/yallist'
: > "$WORK/pm.calls"
out=$(FAKE_RC=1 FAKE_OUT="$CORRUPT" FLEET_DEPS_NOW=$T0 "$DL" --refresh-base "$MAIN" .)
[ "$out" = "install-failed:rc=1 ." ] || st_fail "TRANSIENT: corrupt-cache failure verdict" "$out"
[ "$(mk 4) $(mk 5) $(mk 6) $(mk 7)" = "transient corrupt-cache 1 $T0" ] \
  || st_fail "TRANSIENT: 1st failure ⇒ transient, retry due next tick" "$(cat "$MAIN/node_modules/.fleet-install-failed")"
grep -q "$MAIN FAILED (rc=1, transient: corrupt-cache) — left unstamped; retry 2 at" "$WORK/base-deps.log" \
  || st_fail "TRANSIENT: failure + class logged" "$(tail -3 "$WORK/base-deps.log")"
out=$(FLEET_DEPS_NOW=$T0 "$DL" --base-status "$MAIN")
printf '%s\n' "$out" | grep -q '^summary .* failing=1 .* failing-transient=1 next-retry=next-tick parked-causes=-$' \
  || st_fail "TRANSIENT: status says transient, due" "$out"
# Next tick: retried — `npm cache verify` first (the last failure was corruption).
: > "$WORK/pm.calls"
out=$(FAKE_RC=1 FAKE_OUT="$CORRUPT" FLEET_DEPS_NOW=$T0 "$DL" --refresh-base "$MAIN")
[ "$out" = "install-failed:rc=1 ." ] || st_fail "TRANSIENT: next tick must retry" "$out"
[ "$(cat "$WORK/pm.calls")" = "$MAIN npm cache verify
$MAIN npm ci" ] || st_fail "TRANSIENT: expected cache verify, then npm ci" "$(cat "$WORK/pm.calls")"
[ "$(mk 6) $(mk 7)" = "2 $((T0 + 300))" ] || st_fail "TRANSIENT: 2nd failure ⇒ retry after RETRY_BASE" "$(cat "$MAIN/node_modules/.fleet-install-failed")"
# Before it is due: silent, nothing run; the dry run says why; status names the time.
: > "$WORK/pm.calls"
out=$(FAKE_RC=1 FLEET_DEPS_NOW=$((T0 + 100)) "$DL" --refresh-base "$MAIN")
[ -z "$out" ] && [ ! -s "$WORK/pm.calls" ] || st_fail "TRANSIENT: a retry not yet due must be silent" "$out / $(cat "$WORK/pm.calls")"
out=$(FLEET_DEPS_NOW=$((T0 + 100)) "$DL" --dry-run --refresh-base "$MAIN")
[ "$out" = "skipped:retry-later ." ] || st_fail "TRANSIENT: dry run names the pending retry" "$out"
out=$(FLEET_DEPS_NOW=$((T0 + 100)) "$DL" --base-status "$MAIN")
printf '%s\n' "$out" | grep -q '^summary .* failing-transient=1 next-retry=20[0-9-]*T[0-9:]*Z parked-causes=-$' \
  || st_fail "TRANSIENT: status carries the retry time" "$out"
# Due ⇒ retried, the delay doubles …
out=$(FAKE_RC=1 FAKE_OUT="$CORRUPT" FLEET_DEPS_NOW=$((T0 + 300)) "$DL" --refresh-base "$MAIN")
[ "$(mk 6) $(mk 7)" = "3 $((T0 + 900))" ] || st_fail "TRANSIENT: 3rd failure ⇒ the delay doubles" "$out / $(cat "$MAIN/node_modules/.fleet-install-failed")"
# … until the next retry would land past RETRY_CAP after the first failure ⇒ parked.
out=$(FAKE_RC=1 FAKE_OUT="$CORRUPT" FLEET_DEPS_NOW=$((T0 + 900)) "$DL" --refresh-base "$MAIN")
[ "$(mk 4) $(mk 5) $(mk 6)" = "parked corrupt-cache 4" ] || st_fail "TRANSIENT: past the cap ⇒ parked" "$(cat "$MAIN/node_modules/.fleet-install-failed")"
grep -q "past the 1000s retry window; parked until the lockfile changes" "$WORK/base-deps.log" || st_fail "TRANSIENT: park logged" "$(tail -3 "$WORK/base-deps.log")"
: > "$WORK/pm.calls"
out=$(FAKE_RC=1 FLEET_DEPS_NOW=$((T0 + 99999)) "$DL" --refresh-base "$MAIN")
[ "$out" = "skipped:failing ." ] && [ ! -s "$WORK/pm.calls" ] || st_fail "TRANSIENT: a parked transient stays parked" "$out"
out=$("$DL" --base-status "$MAIN")
printf '%s\n' "$out" | grep -q '^summary .* failing-transient=0 next-retry=- parked-causes=corrupt-cache$' || st_fail "TRANSIENT: parked status" "$out"
# A success clears it all.
out=$("$DL" --refresh-base "$MAIN" .)
[ "$out" = "installed ." ] && [ ! -e "$MAIN/node_modules/.fleet-install-failed" ] || st_fail "TRANSIENT: success clears the marker" "$out"
# Deterministic: parked on the FIRST failure, never retried on its own.
out=$(FAKE_RC=1 FAKE_OUT='npm error code EUSAGE\nnpm error `npm ci` can only install packages when your package.json and package-lock.json are in sync.' \
      FLEET_DEPS_NOW=$T0 "$DL" --refresh-base "$MAIN" .)
[ "$(mk 4) $(mk 5)" = "parked lock-drift" ] || st_fail "TRANSIENT: EUSAGE ⇒ parked lock-drift" "$(cat "$MAIN/node_modules/.fleet-install-failed")"
grep -q "$MAIN FAILED (rc=1, deterministic: lock-drift) — left unstamped; not retried" "$WORK/base-deps.log" || st_fail "TRANSIENT: deterministic logged" "$(tail -2 "$WORK/base-deps.log")"
: > "$WORK/pm.calls"
out=$(FAKE_RC=1 FLEET_DEPS_NOW=$T0 "$DL" --refresh-base "$MAIN")
[ "$out" = "skipped:failing ." ] && [ ! -s "$WORK/pm.calls" ] || st_fail "TRANSIENT: a deterministic failure is not retried next tick" "$out"
grep -q "$MAIN still failing since .* (lock-drift)" "$WORK/base-deps.log" || st_fail "TRANSIENT: skip line names the cause" "$(tail -2 "$WORK/base-deps.log")"
out=$("$DL" --base-status "$MAIN")
printf '%s\n' "$out" | grep -q '^summary .* failing-transient=0 next-retry=- parked-causes=lock-drift$' || st_fail "TRANSIENT: lock-drift status" "$out"
# The classifier over the other shapes the issue names.
for c in 'ERR_PNPM_LOCKFILE_BREAKING_CHANGE  Lockfile /x/pnpm-lock.yaml not compatible|parked lock-format' \
         'gyp ERR! build error|parked native-build' \
         'npm error code ELIFECYCLE\nnpm error command sh -c node postinstall.js|parked lifecycle-script' \
         'npm error code ETIMEDOUT\nnpm error network request to https://registry.npmjs.org failed|transient network' \
         'npm error code E503\nnpm error 503 Service Unavailable - GET https://registry.npmjs.org/x|transient network' \
         'npm error code EINTEGRITY|transient corrupt-cache' \
         'something nobody has seen before|parked unknown'; do
  rm -f "$MAIN/node_modules/.fleet-install-failed"      # each shape a first failure
  out=$(FAKE_RC=1 FAKE_OUT="${c%|*}" FLEET_DEPS_NOW=$T0 "$DL" --refresh-base "$MAIN" .)
  [ "$(mk 4) $(mk 5)" = "${c#*|}" ] || st_fail "TRANSIENT: classify '${c%|*}' ⇒ ${c#*|}" "$(cat "$MAIN/node_modules/.fleet-install-failed")"
done
# A pre-#1028 marker (no class) is retried once, so that failure classifies it.
printf '%s 2026-09-23T00:00:00Z noted\n' "$(sha "$MAIN/package-lock.json")" > "$MAIN/node_modules/.fleet-install-failed"
: > "$WORK/pm.calls"
out=$("$DL" --refresh-base "$MAIN")
[ "$out" = "installed ." ] && grep -qx "$MAIN npm ci" "$WORK/pm.calls" || st_fail "TRANSIENT: a legacy marker must be retried once" "$out"
unset FLEET_BASE_DEPS_RETRY_BASE FLEET_BASE_DEPS_RETRY_CAP
st_pass "TRANSIENT: network/corrupt-cache retry with doubling backoff (+ npm cache verify) then park past the cap; lock drift/native/lifecycle park at once; legacy marker retried once"

# ---- PRIME + STATUS ---------------------------------------------------------
rm -f "$MAIN/tools/node_modules/.fleet-lock-sha"
printf 'lockfileVersion: 10\n' > "$MAIN/web/pnpm-lock.yaml"     # stale web stamp
git -C "$MAIN" commit -qam 'bump web deps'
out=$("$DL" --base-status "$MAIN")
printf '%s\n' "$out" | grep -qx 'summary fresh=1 stale=1 failing=0 unstamped=1 installing=0 not-installed=0 failing-since=- failing-transient=0 next-retry=- parked-causes=-' || st_fail "STATUS: counts" "$out"
# pnpm is NOT on this (daemon-like) PATH — only on the login shell's (issue #1026).
LB="$WORK/loginbin"; mkdir -p "$LB"; mv "$FB/pnpm" "$LB/pnpm"
NOPM=""
while IFS= read -r p; do
  [ -n "$p" ] && [ ! -x "$p/pnpm" ] && [ ! -x "$p/corepack" ] && NOPM="$NOPM${NOPM:+:}$p"
done <<EOF
$(printf '%s\n' "$PATH" | tr ':' '\n')
EOF
printf '#!/bin/sh\necho "motd noise"\nprintf "\\n__FLEET_PATH__=%%s\\n" "%s:$NOPM"\n' "$LB" > "$WORK/loginsh"; chmod +x "$WORK/loginsh"
: > "$WORK/pm.calls"
out=$(PATH="$NOPM" FLEET_DEPS_LOGIN_SHELL="$WORK/loginsh" FLEET_DEPS_TOOL_DIRS="$WORK/none" "$DL" --prime-base "$MAIN")
[ "$(printf '%s\n' "$out" | grep -c '^installed ')" = 3 ] || st_fail "PRIME: expected 3 installs" "$out"
grep -qx "$MAIN/tools yarn install --frozen-lockfile" "$WORK/pm.calls" || st_fail "PRIME: yarn v1 form" "$(cat "$WORK/pm.calls")"
grep -qx "$MAIN/web pnpm install --frozen-lockfile" "$WORK/pm.calls" || st_fail "PRIME: pnpm form" "$(cat "$WORK/pm.calls")"
grep -q "pnpm not on PATH — resolved $LB/pnpm" "$WORK/base-deps.log" || st_fail "PRIME: pnpm resolved from the login PATH, logged" "$(cat "$WORK/base-deps.log")"
out=$("$DL" --base-status "$MAIN")
printf '%s\n' "$out" | grep -qx 'summary fresh=3 stale=0 failing=0 unstamped=0 installing=0 not-installed=0 failing-since=- failing-transient=0 next-retry=- parked-causes=-' || st_fail "PRIME: status after prime" "$out"
[ -z "$(git -C "$MAIN" status --porcelain --untracked-files=no)" ] \
  || st_fail "PRIME: an install left the base dirty (yarn rewrote its lockfile)" "$(git -C "$MAIN" status --porcelain)"
grep -q 'restored tracked tools/yarn.lock' "$WORK/base-deps.log" || st_fail "PRIME: restore not logged" "$(cat "$WORK/base-deps.log")"
st_pass "PRIME: every lockfile dir installed with its frozen form + stamped; --base-status counts; a rewritten lockfile is restored; pnpm resolved off the login PATH"

# ---- DOCTOR (issue #1028) ---------------------------------------------------
# fleet-doctor's deps row names the failing class: transient + its retry time vs
# parked + why. Its _deps_row is evaluated against canned --base-status summaries.
DOC="$BIN/fleet-doctor.sh"
row=$(awk '/^_deps_row\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$DOC")
[ -n "$row" ] || st_fail "DOCTOR: _deps_row not found in fleet-doctor.sh"
eval "$row"
warn() { printf 'WARN %s: %s\n' "$1" "$2"; }; pass() { printf 'PASS %s: %s\n' "$1" "$2"; }
doc_with() {  # <summary fields> → the row
  printf '#!/bin/sh\necho "summary %s"\n' "$1" > "$WORK/fake-dl"; chmod +x "$WORK/fake-dl"
  dl_sh="$WORK/fake-dl" _deps_row fleet "$MAIN"
}
base='fresh=2 stale=0 failing=1 unstamped=0 installing=0 not-installed=0 failing-since=2026-09-23T08:00:00Z'
out=$(doc_with "$base failing-transient=1 next-retry=2026-09-23T09:10:00Z parked-causes=-")
printf '%s\n' "$out" | grep -q '^WARN deps: .* 1 failing / .* (failing: transient, retry at 2026-09-23T09:10:00Z; since 2026-09-23T08:00:00Z) — a transient' \
  || st_fail "DOCTOR: transient row" "$out"
out=$(doc_with "$base failing-transient=0 next-retry=- parked-causes=lock-drift")
printf '%s\n' "$out" | grep -q '(failing: parked: lock drift; since 2026-09-23T08:00:00Z) — the install fails on the repo' \
  || st_fail "DOCTOR: parked row" "$out"
out=$(doc_with "${base/failing=1/failing=3} failing-transient=1 next-retry=next-tick parked-causes=lock-drift,native-build")
printf '%s\n' "$out" | grep -q '(failing: 1 transient, retry at next tick; 2 parked: lock drift/native build; since' \
  || st_fail "DOCTOR: mixed row" "$out"
st_pass "DOCTOR: the deps row says transient (retry at …) vs parked (why)"

printf 'fleet-deps-link-selftest: %d checks passed\n' "$pass"
