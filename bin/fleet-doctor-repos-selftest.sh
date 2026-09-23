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
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-doctor.sh fleet-daemon-lib.sh fleet-trust.sh fleet-lib.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-repos-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/shim" "$WORK/conf/fleets/fleet-t/repos"
for f in fleet-doctor.sh fleet-daemon-lib.sh fleet-trust.sh fleet-lib.sh fleet-deps-link.sh; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh

# o/alpha's checkout: a real repo, origin = o/alpha, branch main
git init -q -b main "$WORK/alpha" 2>/dev/null || { git init -q "$WORK/alpha" && git -C "$WORK/alpha" checkout -q -b main; }
git -C "$WORK/alpha" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$WORK/alpha" remote add origin "git@github.com:o/alpha.git"

cat > "$WORK/conf/fleets/fleet-t/conf" <<EOF
FLEET_REPO="o/alpha"
FLEET_MAIN="$WORK/alpha"
FLEET_BASE_BRANCH="main"
FLEET_DEPLOY_CHECK="actions"
FLEET_BASE_DEPS=1
EOF
cat > "$WORK/conf/fleets/fleet-t/repos/o-beta.conf" <<EOF
FLEET_REPO="o/beta"
FLEET_MAIN="$WORK/no-such-beta"
FLEET_BASE_BRANCH="main"
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
ok() { CHECKS=$((CHECKS + 1)); }
run_doctor() {
  env HOME="$WORK/home" TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 \
    PATH="$WORK/shim:$PATH" sh "$WORK/bin/fleet-doctor.sh" >"$WORK/stdout" 2>"$WORK/stderr"
  return 0
}
row() {   # row <PASS|WARN|FAIL> <tag> <ERE after the tag>
  grep -Eq "^[[:space:]]+$1[[:space:]]+$2[[:space:]]+$3" "$WORK/stdout"
}

run_doctor
grep -q 'unbound variable' "$WORK/stderr" && fail "doctor died on an unbound variable"

# 1. one block per hosted repo, conf repo first
heads=$(grep -E '── fleet-t · ' "$WORK/stdout" | sed 's/.*── fleet-t · //' | tr -d '\033' | sed 's/\[[0-9;]*m//g')
[ "$heads" = "$(printf 'o/alpha\no/beta')" ] || fail "expected blocks o/alpha then o/beta, got: $heads"
ok

# 2. the healthy repo passes main + base + labels, and gets its own deploy row
row PASS main  'o/alpha: ' || fail "o/alpha main did not PASS"
row PASS base  'o/alpha: base "main" is the repo default' || fail "o/alpha base did not PASS"
row PASS labels 'o/alpha: every fleet label is seeded' || fail "o/alpha labels did not PASS"
row PASS deploy 'o/alpha: FLEET_DEPLOY_CHECK=actions' || fail "o/alpha deploy row missing"
ok

# 3. the broken hosted MAIN is reported by name
row WARN main "o/beta: FLEET_MAIN $WORK/no-such-beta does not exist" || fail "o/beta's missing FLEET_MAIN was not reported by name"
ok

# 4. scoped keys do not leak from the conf repo into the overlay repo
row PASS deploy 'o/beta: no deploy state configured' || fail "o/beta inherited o/alpha's FLEET_DEPLOY_CHECK"
ok

# 5. missing labels are named, per repo
row WARN labels 'o/beta: missing fleet labels: enhancement' || fail "o/beta's missing labels were not reported"
ok

# 7. (issue #1044) the base checkout must sit ON its base branch
ga() { git -C "$WORK/alpha" -c user.name=t -c user.email=t@t "$@"; }
row PASS checkout 'o/alpha: .* is on "main"' || fail "o/alpha on main did not PASS the checkout row"
row PASS deps 'fleet-t: base deps ' || fail "o/alpha's base deps did not PASS on main"
ok
ga checkout -q -b ops/side
ga commit -q --allow-empty -m side
tip=$(ga rev-parse main)
ga commit -q --allow-empty -m m1 && ga commit -q --allow-empty -m m2   # on ops/side …
ga update-ref refs/remotes/origin/main "$(ga rev-parse HEAD)"          # … origin/main = side+m1+m2
ga reset -q --hard "$tip"; ga commit -q --allow-empty -m side2          # side: 3 behind origin/main
run_doctor
row WARN checkout "o/alpha: base checkout $WORK/alpha is on ops/side, not \"main\" \\(3 commit\\(s\\) behind origin/main\\).*git -C '$WORK/alpha' checkout main" \
  || fail "a base on a side branch was not a WARN checkout row with its behind count"
row WARN deps 'fleet-t: base deps .*\[against ops/side, not main' || fail "base deps still passed against the wrong branch"
row PASS deps 'fleet-t: base deps ' && fail "base deps PASSed on a side branch"
ok
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
ok

# 6. degenerate: no overlay → exactly one block
rm -rf "$WORK/conf/fleets/fleet-t/repos"
run_doctor
[ "$(grep -c '── fleet-t · ' "$WORK/stdout")" = 1 ] || fail "a one-repo fleet printed other than one block"
grep -q 'o/beta' "$WORK/stdout" && fail "o/beta still reported after its overlay was removed"
ok

printf 'fleet-doctor-repos-selftest: %d checks passed\n' "$CHECKS"
