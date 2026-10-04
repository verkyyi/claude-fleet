#!/bin/bash
# run-selftests-changed-selftest.sh — `run-selftests.sh --changed <base>` picks the
# RIGHT tests (issue #1374).
#
# CI runs only what --changed selects, so a selector that under-picks is a gate that
# silently stops testing. Four kinds of change, each in a throwaway git repo whose
# bin/ holds the REAL runner + shadow-root script and five one-line fake tests:
#
#   1. a plain script     → the test that names it + the lint group
#   2. one fleet-lib.sh function → the test naming THAT function; not the one that
#      only names the library file or a sibling function (rule c, not rule b)
#   3. the selftests workflow → the full suite (the harness never vets its own edit)
#   4. docs only          → the lint group alone
#
# plus: each pick prints `select: <test> ← <reason>`; a shard left empty under
# --changed passes, while the same empty shard WITHOUT --changed still refuses
# (exit 2), so the default path is unchanged.
set -u

BIN=$(cd -- "$(dirname -- "$0")" && pwd)
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

T=$(mktemp -d "${TMPDIR:-/tmp}/fleet-selftest-changed.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
R="$T/repo"
mkdir -p "$R/bin" "$R/docs" "$R/.github/workflows"
cp "$BIN/run-selftests.sh" "$BIN/selftest-shadow-root.sh" "$R/bin/"

FAILS=0
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
ok()   { printf 'ok   %s\n' "$*"; }

mk_test() { printf '#!/bin/sh\n# %s\nexit 0\n' "$2" > "$R/bin/$1-selftest.sh"; }
mk_test portability 'lint: scans the whole tree'
mk_test alpha       'drives tool-a.sh'
mk_test beta        'calls fleet_foo from the lib'
mk_test gamma       'nothing that changes below'
mk_test delta       'sources fleet-lib.sh and calls fleet_bar'
printf '#!/bin/sh\necho a\n' > "$R/bin/tool-a.sh"
cat > "$R/bin/fleet-lib.sh" <<'EOF'
#!/bin/sh
FLEET_X=1

fleet_foo() {
  echo foo
}

fleet_bar() {
  echo bar
}
EOF
echo 'name: selftests' > "$R/.github/workflows/selftests.yml"
echo '# docs' > "$R/docs/guide.md"

g() { git -C "$R" -c user.name=t -c user.email=t@example.invalid "$@"; }
g init -q
g add -A && g commit -qm base && g tag base

# run_changed <scenario> — run the runner from the repo, echo the PASSed tests sorted.
run_changed() {
  out=$(env -u FLEET_SELFTEST_ROOT -u FLEET_SELFTEST_NO_SHADOW FLEET_HEAVY=0 \
        sh "$R/bin/run-selftests.sh" --changed base </dev/null 2>&1)
  rc=$?
  ran=$(printf '%s\n' "$out" | awk '/^PASS /{print $2}' | sort | tr '\n' ' ')
}

# scenario <name> <edit-cmd> <expected sorted list>
scenario() {
  name=$1 edit=$2 want=$3
  g checkout -q -B "s-$name" base
  (cd "$R" && eval "$edit")
  g add -A && g commit -qm "$name"
  run_changed
  if [ "$rc" -ne 0 ]; then
    fail "$name: runner exited $rc"; printf '%s\n' "$out" | sed 's/^/     /'
  elif [ "$ran" != "$want" ]; then
    fail "$name: ran [$ran], want [$want]"; printf '%s\n' "$out" | grep '^select' | sed 's/^/     /'
  else
    ok "$name → $ran"
  fi
}

scenario script 'echo b >> bin/tool-a.sh' \
  'alpha-selftest.sh portability-selftest.sh '
printf '%s\n' "$out" | grep -q '^select: alpha-selftest.sh ← mentions tool-a.sh$' \
  && ok "select line names the test and why" \
  || fail "no 'select: alpha-selftest.sh ← mentions tool-a.sh' line"
printf '%s\n' "$out" | grep -q '^select: portability-selftest.sh ← always (lint group)$' \
  && ok "lint group carries its reason" || fail "lint group select line missing"

scenario lib-function "sed -e 's/echo foo/echo FOO/' bin/fleet-lib.sh > x && mv x bin/fleet-lib.sh" \
  'beta-selftest.sh portability-selftest.sh '

scenario workflow 'echo "# touch" >> .github/workflows/selftests.yml' \
  'alpha-selftest.sh beta-selftest.sh delta-selftest.sh gamma-selftest.sh portability-selftest.sh '
printf '%s\n' "$out" | grep -q '^select: \* ← full suite (harness changed: .github/workflows/selftests.yml)$' \
  && ok "harness change says why it went full" || fail "full-suite select line missing"

scenario docs 'echo more >> docs/guide.md' 'portability-selftest.sh '

# A changed selftest selects itself.
scenario selftest 'echo "# edit" >> bin/gamma-selftest.sh' \
  'gamma-selftest.sh portability-selftest.sh '

# Empty shard: green under --changed, still a refusal without it.
g checkout -q s-docs
out=$(FLEET_HEAVY=0 sh "$R/bin/run-selftests.sh" --changed base --shard 2/3 </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'has nothing to run' \
  && ok "--changed: an empty shard passes" || { fail "--changed empty shard: rc=$rc"; printf '%s\n' "$out"; }
out=$(FLEET_HEAVY=0 sh "$R/bin/run-selftests.sh" --shard 6/6 portability </dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "without --changed an empty shard still refuses (exit 2)" \
  || fail "default empty shard: rc=$rc, want 2"

# An unresolvable base never under-selects: it runs everything.
out=$(FLEET_HEAVY=0 sh "$R/bin/run-selftests.sh" --changed no-such-ref </dev/null 2>&1); rc=$?
n=$(printf '%s\n' "$out" | grep -c '^PASS ')
[ "$rc" -eq 0 ] && [ "$n" -eq 5 ] && ok "unresolvable base → full suite" \
  || fail "unresolvable base: rc=$rc ran=$n"

# --changed with explicit names is refused.
FLEET_HEAVY=0 sh "$R/bin/run-selftests.sh" --changed base alpha >/dev/null 2>&1
[ $? -eq 2 ] && ok "--changed + test names is refused" || fail "--changed + names not refused"

[ "$FAILS" -eq 0 ] || { echo "run-selftests-changed-selftest: $FAILS failure(s)"; exit 1; }
echo "run-selftests-changed-selftest: all green"
