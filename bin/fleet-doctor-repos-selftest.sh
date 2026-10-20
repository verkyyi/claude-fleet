#!/bin/bash
# fleet-doctor-repos-selftest.sh — bin/fleet-doctor.sh prints ONE block per repo
# a fleet hosts (issue #801), and a broken hosted repo is reported BY NAME.
#
# Before #801 the trust + base checks read the fleet conf alone, so a fleet that
# hosts a second repo (fleets/<sess>/repos/<slug>.conf, #788) never had that repo
# looked at: a missing checkout or trust grant surfaced only when a spawn hung.
#
# Sandbox: a fleet conf for o/alpha (a real git checkout whose origin matches) plus
# an overlay for o/beta whose FLEET_MAIN does not exist; HOME inside the sandbox; a
# PATH-shim `gh` that answers `repo view` offline. Pinned:
#   1. a block header per hosted repo, conf repo first;
#   2. o/alpha's main/base PASS, and the deploy + labels rows are per repo;
#   3. o/beta's missing FLEET_MAIN is a WARN main row naming o/beta;
#   4. the conf repo's scoped keys never leak into the overlay repo (o/beta's
#      deploy row does NOT inherit o/alpha's FLEET_DEPLOY_CHECK);
#   5. a repo missing fleet labels is named on a WARN labels row;
#   6. degenerate: no repos/ overlay → exactly one block.
#   7. (issue #1044) a base checkout ON its base branch PASSes the checkout row; one
#      left on a side branch is a WARN checkout row naming the branch + commits
#      behind origin/<base>, and the base-deps row stops passing ("fresh" is
#      against the wrong tree); another worktree holding the base branch is named.
#   8. (issue #1104) ONE `repos` summary row per fleet lists every hosted repo with
#      ✓, or ✗ plus the failing item (main / base / trust); the WARN form does not
#      count again (its items were already counted); a one-repo fleet shows it too.
#   9. (issue #1944) an `overrides` row per overlay repo names the keys it set on
#      its own (identity keys left to their rows), the fleet value each shadows, and
#      never a credential-shaped value; two / one / zero repos.
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-repo-fixture.sh"
for f in fleet-doctor.sh fleet-daemon-lib.sh fleet-trust.sh fleet-lib.sh fleet-client-core.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

st_sandbox "${TMPDIR:-/tmp}/doctor-repos-selftest.XXXXXX" physical
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/shim" "$WORK/conf/fleets/fleet-t/repos"
for f in fleet-doctor.sh fleet-daemon-lib.sh fleet-trust.sh fleet-lib.sh fleet-client-core.sh fleet-deps-link.sh; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh

# o/alpha's checkout: a real repo, origin = o/alpha, branch main
git init -q -b main "$WORK/alpha" 2>/dev/null || { git init -q "$WORK/alpha" && git -C "$WORK/alpha" checkout -q -b main; }
git -C "$WORK/alpha" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$WORK/alpha" remote add origin "git@github.com:o/alpha.git"

fx_repo "$WORK/conf" fleet-t o/alpha FLEET_MAIN="$WORK/alpha" FLEET_BASE_BRANCH=main FLEET_DEPLOY_CHECK=actions
cat > "$WORK/conf/fleets/fleet-t/conf" <<EOF
FLEET_BASE_DEPS=1
FLEET_MODEL="sonnet"
EOF
cat > "$WORK/conf/fleets/fleet-t/repos/o-beta.conf" <<EOF
FLEET_REPO="o/beta"
FLEET_MAIN="$WORK/no-such-beta"
FLEET_BASE_BRANCH="main"
FLEET_MODEL="opus"
export FLEET_API_TOKEN="s3cr3t-beta"
EOF

# gh shim: `repo view <r> …` → default branch, then label names. o/alpha carries
# every canonical label; o/beta only `bug`. Everything else succeeds silently.
LABELS=$(bash -c '. "$1" >/dev/null 2>&1 && fleet_labels_allowed' _ "$BIN/fleet-lib.sh")
printf '%s\n' "$LABELS" > "$WORK/labels"
cat > "$WORK/shim/gh" <<EOF
#!/bin/sh
if [ "\$1 \$2" = "repo view" ]; then
  echo main
  case "\$3" in o/alpha) cat "$WORK/labels" ;; *) echo bug ;; esac
fi
exit 0
EOF
chmod +x "$WORK/shim/gh"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- stdout ---\n%s\n--- stderr ---\n%s\n' "$(cat "$WORK/stdout" 2>/dev/null)" "$(cat "$WORK/stderr" 2>/dev/null)" >&2; exit 1; }
run_doctor() {
  env HOME="$WORK/home" CLAUDE_CONFIG_DIR="$WORK/home" TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 \
    PATH="$WORK/shim:$PATH" sh "$WORK/bin/fleet-doctor.sh" >"$WORK/stdout" 2>"$WORK/stderr"
  return 0
}
row() {   # row <PASS|WARN|FAIL> <tag> <ERE after the tag>
  grep -Eq "^[[:space:]]+$1[[:space:]]+$2[[:space:]]+$3" "$WORK/stdout"
}

run_doctor
grep -q 'unbound variable' "$WORK/stderr" && fail "doctor died on an unbound variable"

# 1. one block per hosted repo, in repos/.order
heads=$(grep -E '── fleet-t · ' "$WORK/stdout" | sed 's/.*── fleet-t · //' | tr -d '\033' | sed 's/\[[0-9;]*m//g')
[ "$heads" = "$(printf 'o/alpha\no/beta')" ] || fail "expected blocks o/alpha then o/beta, got: $heads"
st_count

# 2. the healthy repo passes main + base + labels, and gets its own deploy row
row PASS main  'o/alpha: ' || fail "o/alpha main did not PASS"
row PASS base  'o/alpha: base "main" is the repo default' || fail "o/alpha base did not PASS"
row PASS labels 'o/alpha: every fleet label is seeded' || fail "o/alpha labels did not PASS"
row PASS deploy 'o/alpha: FLEET_DEPLOY_CHECK=actions' || fail "o/alpha deploy row missing"
st_count

# 3. the broken hosted MAIN is reported by name
row WARN main "o/beta: FLEET_MAIN $WORK/no-such-beta does not exist" || fail "o/beta's missing FLEET_MAIN was not reported by name"
st_count

# 4. scoped keys do not leak from one repo's overlay into another's
row PASS deploy 'o/beta: no deploy state configured' || fail "o/beta inherited o/alpha's FLEET_DEPLOY_CHECK"
st_count

# 5. missing labels are named, per repo
row WARN labels 'o/beta: missing fleet labels: enhancement' || fail "o/beta's missing labels were not reported"
st_count

# 9. (issue #1944) two repos: o/beta's own settings, the fleet value it shadows,
#    the token hidden; o/alpha's row names its own key
row INFO overrides "o/beta: FLEET_MODEL=opus \\(fleet: sonnet\\) · FLEET_API_TOKEN=<hidden> — in $WORK/conf/fleets/fleet-t/repos/o-beta.conf\$" \
  || fail "o/beta's overrides row did not list its own keys"
grep -q 's3cr3t-beta' "$WORK/stdout" && fail "a credential value was printed"
grep -q 'overrides .*FLEET_BASE_BRANCH' "$WORK/stdout" && fail "an identity key was listed as an override"
row INFO overrides "o/alpha: FLEET_DEPLOY_CHECK=actions — in $WORK/conf/fleets/fleet-t/repos/o-alpha.conf\$" \
  || fail "o/alpha's overrides row did not name its own deploy check"
st_count

# 8. (issue #1104) the `repos` summary row: both repos, beta's broken main named
row WARN repos '2 hosted: o/alpha ✓ · o/beta ✗ \(main\)$' || fail "repos row did not list o/alpha ✓ and o/beta ✗ (main)"
[ "$(grep -c '^[[:space:]]*[^[:space:]]*WARN[^[:space:]]*[[:space:]]*repos ' "$WORK/stdout")" = 1 ] || fail "expected exactly one repos row"
nwarn=$(grep -c 'WARN' "$WORK/stdout"); said=$(tail -1 "$WORK/stdout" | grep -oE '[0-9]+ warn' | cut -d' ' -f1)   # "N warn" or "M fail, N warn"
[ "$said" = "$((nwarn - 1))" ] || fail "the repos WARN counted again: $nwarn WARN rows, summary says $said"
st_count
# … an untrusted main is named as trust, a missing base as base
printf '{"projects":{}}\n' > "$WORK/home/.claude.json"
printf 'FLEET_REPO="o/beta"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="nope"\n' "$WORK/alpha" > "$WORK/conf/fleets/fleet-t/repos/o-beta.conf"
git -C "$WORK/alpha" remote set-url origin "git@github.com:o/beta.git"
run_doctor
row WARN repos '2 hosted: o/alpha ✗ \(main, trust\) · o/beta ✗ \(base, trust\)$' || fail "repos row did not name main/base/trust"
git -C "$WORK/alpha" remote set-url origin "git@github.com:o/alpha.git"
rm -f "$WORK/home/.claude.json"
printf 'FLEET_REPO="o/beta"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="main"\n' "$WORK/no-such-beta" > "$WORK/conf/fleets/fleet-t/repos/o-beta.conf"
run_doctor
st_count

# 7. (issue #1044) the base checkout must sit ON its base branch
ga() { git -C "$WORK/alpha" -c user.name=t -c user.email=t@t "$@"; }
row PASS checkout 'o/alpha: .* is on "main"' || fail "o/alpha on main did not PASS the checkout row"
row PASS deps 'fleet-t \[o-alpha\]: base deps ' || fail "o/alpha's base deps did not PASS on main"
st_count
ga checkout -q -b ops/side
ga commit -q --allow-empty -m side
tip=$(ga rev-parse main)
ga commit -q --allow-empty -m m1 && ga commit -q --allow-empty -m m2   # on ops/side …
ga update-ref refs/remotes/origin/main "$(ga rev-parse HEAD)"          # … origin/main = side+m1+m2
ga reset -q --hard "$tip"; ga commit -q --allow-empty -m side2          # side: 3 behind origin/main
run_doctor
row WARN checkout "o/alpha: base checkout $WORK/alpha is on ops/side, not \"main\" \\(3 commit\\(s\\) behind origin/main\\).*git -C '$WORK/alpha' checkout main" \
  || fail "a base on a side branch was not a WARN checkout row with its behind count"
row WARN deps 'fleet-t \[o-alpha\]: base deps .*\[against ops/side, not main' || fail "base deps still passed against the wrong branch"
row PASS deps 'fleet-t \[o-alpha\]: base deps ' && fail "base deps PASSed on a side branch"
st_count
ga worktree add -q "$WORK/stray" main 2>/dev/null
run_doctor
row WARN checkout "o/alpha: worktree $WORK/stray holds \"main\"" || fail "a stray worktree holding main was not named"
rm -rf "$WORK/stray"
run_doctor
row WARN checkout "o/alpha: worktree $WORK/stray \\(prunable\\) holds" || fail "a gone stray worktree was not marked prunable"
ga worktree prune; ga checkout -q main
run_doctor
row PASS checkout 'o/alpha: .* is on "main"' || fail "back on main did not PASS"
grep -q 'holds "main"' "$WORK/stdout" && fail "a pruned holder is still reported"
st_count

# 6. one repo → exactly one block
rm -f "$WORK/conf/fleets/fleet-t/repos/o-beta.conf"
run_doctor
[ "$(grep -c '── fleet-t · ' "$WORK/stdout")" = 1 ] || fail "a one-repo fleet printed other than one block"
grep -q 'o/beta' "$WORK/stdout" && fail "o/beta still reported after its overlay was removed"
row PASS repos '1 hosted: o/alpha ✓$' || fail "a one-repo fleet has no PASS repos row"
[ "$(grep -c 'repos ' "$WORK/stdout")" = 1 ] || fail "a one-repo fleet printed other than one repos row"
st_count
# 9. one repo as an overlay holding only its identity
mkdir -p "$WORK/conf/fleets/fleet-t/repos"
printf 'FLEET_REPO="o/alpha"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="main"\n' "$WORK/alpha" > "$WORK/conf/fleets/fleet-t/repos/o-alpha.conf"
run_doctor
row INFO overrides "o/alpha: no setting of its own" || fail "an identity-only overlay did not say it has no setting of its own"
st_count
# 9. zero repos: no block, no overrides row, the repos row says 0 hosted
rm -rf "$WORK/conf/fleets/fleet-t/repos"
printf 'FLEET_BASE_DEPS=0\n' > "$WORK/conf/fleets/fleet-t/conf"
run_doctor
grep -q 'unbound variable' "$WORK/stderr" && fail "doctor died on an unbound variable with zero repos"
row PASS repos '0 hosted' || fail "a fleet with no repo has no '0 hosted' repos row"
grep -Eq '── fleet-t · |overrides ' "$WORK/stdout" && fail "a fleet with no repo printed a repo block"
st_count

printf 'fleet-doctor-repos-selftest: %d checks passed\n' "$CHECKS"
