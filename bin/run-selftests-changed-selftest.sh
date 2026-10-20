#!/bin/bash
# run-selftests-changed-selftest.sh — `run-selftests.sh --changed <base>` picks the
# RIGHT tests (issue #1374).
#
# CI runs only what --changed selects, so a selector that under-picks is a gate that
# silently stops testing. Four kinds of change, each in a throwaway git repo whose
# bin/ holds the REAL runner + shadow-root script and six one-line fake tests:
#
#   1. a plain script     → the test that names it + the lint group
#   2. one fleet-lib.sh function → the test naming THAT function; not the one that
#      only names the library file or a sibling function (rule c, not rule b)
#   3. the selftests workflow → the full suite (the harness never vets its own edit)
#   4. docs only          → the lint group alone
#   5. bin/fleet (no extension) → only the test naming it as a path, `/fleet`
#   6. a test declaring `# selftest-parts: N` and a `.py` entry → their ids (T525)
#
# plus: each pick prints `select: <test> ← <reason>`; a shard left empty under
# --changed passes, while the same empty shard WITHOUT --changed still refuses
# (exit 2), so the default path is unchanged.
set -u

BIN=$(cd -- "$(dirname -- "$0")" && pwd)
. "$BIN/selftest-lib.sh"
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

T=$(mktemp -d "${TMPDIR:-/tmp}/fleet-selftest-changed.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
R="$T/repo"
mkdir -p "$R/bin" "$R/docs" "$R/.github/workflows"
cp "$BIN/run-selftests.sh" "$BIN/selftest-shadow-root.sh" "$R/bin/"

FAILS=0
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }

mk_test() { printf '#!/bin/sh\n# %s\nexit 0\n' "$2" > "$R/bin/$1-selftest.sh"; }
mk_test portability 'lint: scans the whole tree'
mk_test alpha       'drives tool-a.sh'
mk_test beta        'calls fleet_foo from the lib'
mk_test gamma       'nothing that changes below'
mk_test delta       'sources fleet-lib.sh and calls fleet_bar'
mk_test epsilon     'runs "$BIN/fleet" connect'
printf '#!/bin/sh\necho a\n' > "$R/bin/tool-a.sh"
printf '#!/bin/sh\necho f\n' > "$R/bin/fleet"
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
    st_ok_all "$name → $ran"
  fi
}

scenario script 'echo b >> bin/tool-a.sh' \
  'alpha-selftest.sh portability-selftest.sh '
printf '%s\n' "$out" | grep -q '^select: alpha-selftest.sh ← mentions tool-a.sh$' \
  && st_ok_all "select line names the test and why" \
  || fail "no 'select: alpha-selftest.sh ← mentions tool-a.sh' line"
printf '%s\n' "$out" | grep -q '^select: portability-selftest.sh ← always (lint group)$' \
  && st_ok_all "lint group carries its reason" || fail "lint group select line missing"

scenario lib-function "sed -e 's/echo foo/echo FOO/' bin/fleet-lib.sh > x && mv x bin/fleet-lib.sh" \
  'beta-selftest.sh portability-selftest.sh '

scenario workflow 'echo "# touch" >> .github/workflows/selftests.yml' \
  'alpha-selftest.sh beta-selftest.sh delta-selftest.sh epsilon-selftest.sh gamma-selftest.sh portability-selftest.sh '
printf '%s\n' "$out" | grep -q '^select: \* ← full suite (harness changed: .github/workflows/selftests.yml)$' \
  && st_ok_all "harness change says why it went full" || fail "full-suite select line missing"

# An extensionless basename selects only a test naming it as a path (issue #1734):
# beta (fleet_foo) and delta (fleet-lib.sh) say `fleet` too and must stay out.
scenario extensionless 'echo g >> bin/fleet' \
  'epsilon-selftest.sh portability-selftest.sh '

scenario docs 'echo more >> docs/guide.md' 'portability-selftest.sh '

# A changed selftest selects itself.
scenario selftest 'echo "# edit" >> bin/gamma-selftest.sh' \
  'gamma-selftest.sh portability-selftest.sh '

# Empty shard: green under --changed, still a refusal without it.
g checkout -q s-docs
out=$(FLEET_HEAVY=0 sh "$R/bin/run-selftests.sh" --changed base --shard 2/3 </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'has nothing to run' \
  && st_ok_all "--changed: an empty shard passes" || { fail "--changed empty shard: rc=$rc"; printf '%s\n' "$out"; }
out=$(FLEET_HEAVY=0 sh "$R/bin/run-selftests.sh" --shard 6/6 portability </dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ] && st_ok_all "without --changed an empty shard still refuses (exit 2)" \
  || fail "default empty shard: rc=$rc, want 2"

# An unresolvable base never under-selects: it runs everything.
out=$(FLEET_HEAVY=0 sh "$R/bin/run-selftests.sh" --changed no-such-ref </dev/null 2>&1); rc=$?
n=$(printf '%s\n' "$out" | grep -c '^PASS ')
[ "$rc" -eq 0 ] && [ "$n" -eq 6 ] && st_ok_all "unresolvable base → full suite" \
  || fail "unresolvable base: rc=$rc ran=$n"

# --changed with explicit names is refused.
FLEET_HEAVY=0 sh "$R/bin/run-selftests.sh" --changed base alpha >/dev/null 2>&1
[ $? -eq 2 ] && st_ok_all "--changed + test names is refused" || fail "--changed + names not refused"

# A family edit selects every thin wrapper exactly once, including a new part.
# Keep the wrappers in the BASE too: otherwise "changed itself" would mask a
# missing selftest-part-of edge (issue #4500).
g checkout -q -B s-parts base
mk_test alpha-2 'selftest-part-of: alpha-selftest.sh'
mk_test alpha-3 'selftest-part-of: alpha-selftest.sh'
g add -A && g commit -qm parts && g tag parts-base
echo changed >> "$R/bin/tool-a.sh"
g add -A && g commit -qm part-source
out=$(env -u FLEET_SELFTEST_ROOT -u FLEET_SELFTEST_NO_SHADOW FLEET_HEAVY=0 \
      sh "$R/bin/run-selftests.sh" --changed parts-base </dev/null 2>&1); rc=$?
ran=$(printf '%s\n' "$out" | awk '/^PASS /{print $2}' | sort | tr '\n' ' ')
[ "$rc" -eq 0 ] && [ "$ran" = 'alpha-2-selftest.sh alpha-3-selftest.sh alpha-selftest.sh portability-selftest.sh ' ] \
  && st_ok_all "a family source selects its parent and every part once" \
  || fail "family selection: rc=$rc ran=$ran"

# Parts declared in the test's header (T525): a change selecting the test runs and
# lists every id once, each with its K/N; a `.py` entry naming the changed file is
# selected by its own words and runs by its shebang.
g checkout -q -B s-ids base
printf '#!/bin/sh\n# selftest-parts: 3\n# drives tool-a.sh\necho "part $SELFTEST_PART"\n' > "$R/bin/alpha-selftest.sh"
printf '#!/bin/sh\n# selftest-entry\n# drives tool-a.sh\nexit 0\n' > "$R/bin/zeta-selftest.py"
chmod +x "$R/bin/zeta-selftest.py"
g add -A && g commit -qm ids && g tag ids-base
echo changed >> "$R/bin/tool-a.sh"
g add -A && g commit -qm ids-source
list=$(FLEET_HEAVY=0 sh "$R/bin/run-selftests.sh" --changed ids-base --list-only 2>&1 | tr '\n' ' ')
[ "$list" = 'alpha-selftest.sh#1 alpha-selftest.sh#2 alpha-selftest.sh#3 portability-selftest.sh zeta-selftest.py ' ] \
  && st_ok_all "--list-only prints the ids of a declared test and a .py entry" || fail "id list: $list"
out=$(env -u FLEET_SELFTEST_ROOT -u FLEET_SELFTEST_NO_SHADOW FLEET_HEAVY=0 \
      sh "$R/bin/run-selftests.sh" --changed ids-base </dev/null 2>&1); rc=$?
ran=$(printf '%s\n' "$out" | awk '/^PASS /{print $2}' | tr '\n' ' ')
parts=$(printf '%s\n' "$out" | grep -c '^part [123]/3$')
[ "$rc" -eq 0 ] && [ "$ran" = "$list" ] && [ "$parts" -eq 3 ] \
  && st_ok_all "every id runs once, each part with its K/N" || fail "id run: rc=$rc ran=$ran parts=$parts"

[ "$FAILS" -eq 0 ] || { echo "run-selftests-changed-selftest: $FAILS failure(s)"; exit 1; }
echo "run-selftests-changed-selftest: all green"
