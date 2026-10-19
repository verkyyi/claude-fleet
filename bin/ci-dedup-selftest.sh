#!/bin/bash
# ci-dedup-selftest.sh — the PR checks run once per change, on the PR (issue #4663).
#
#   A  no PR check re-runs on a master push: selftests.yml, shellcheck.yml,
#      tokenledger.yml, fleet-hub.yml, client-e2e.yml, task-acceptance.yml,
#      browser-attachment.yml, web-console.yml, web-chat-ui.yml carry no `push:`
#      trigger (the release train is master's run), and each still runs on its
#      PR — called by the PR gate, ci.yml (issue #4815), which runs on
#      pull_request alone; shellcheck.yml's nightly full run is ci-nightly.yml's
#      call (issue #4816), on a schedule.
#   B  bin/ci-shellcheck.sh --changed <base> --list, in a throwaway repo: only the
#      *.sh under bin hooks shell extras that the change adds or modifies (a
#      deleted one, a .py, a docs file never); none ⇒ nothing; a change to
#      .shellcheckrc / .shellcheck-version / the script / the workflow ⇒ the whole
#      tree; a base that does not resolve ⇒ the whole tree; no --changed ⇒ the
#      whole tree.
#   C  shellcheck.yml runs bin/ci-shellcheck.sh with --changed HEAD^1 on a PR (its
#      merge commit's first parent is the base) and fetches depth 2 for it.
set -u
BIN=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$BIN/.." && pwd)
WF="$ROOT/.github/workflows"
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

FAILS=0
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
ok()   { printf 'ok   %s\n' "$*"; }

# the `on:` block's top-level keys of a workflow
on_keys() { awk '/^on:/{o=1; next} o && /^[^ #]/{o=0} o && /^  [a-z_]+:/{sub(/:.*/, ""); sub(/^ +/, ""); print}' "$1"; }

# ── A ──
for f in selftests shellcheck tokenledger fleet-hub client-e2e task-acceptance browser-attachment web-console web-chat-ui; do
  [ -f "$WF/$f.yml" ] || { fail "A: $f.yml is gone"; continue; }
  keys=$(on_keys "$WF/$f.yml" | tr '\n' ' ')
  case " $keys" in *" push "*) fail "A: $f.yml still re-runs on push ($keys)" ;; esac
  case " $keys" in *" workflow_call "*) ;; *) fail "A: $f.yml is not callable by the PR gate ($keys)" ;; esac
  grep -q "uses: ./.github/workflows/$f.yml" "$WF/ci.yml" || fail "A: ci.yml does not call $f.yml"
done
ckeys=$(on_keys "$WF/ci.yml" | tr '\n' ' ')
[ "$ckeys" = "pull_request " ] || fail "A: ci.yml runs on [$ckeys], want pull_request alone"
{ on_keys "$WF/ci-nightly.yml" | grep -qx schedule && grep -q 'uses: ./.github/workflows/shellcheck.yml' "$WF/ci-nightly.yml"; } \
  || fail "A: shellcheck.yml lost its nightly full run (ci-nightly.yml, on a schedule, calls it)"
[ "$FAILS" -eq 0 ] && ok "A: no PR check re-runs on a master push; ci.yml calls each on its PR; shellcheck has a nightly"

# ── B ──
T=$(mktemp -d "${TMPDIR:-/tmp}/ci-dedup-selftest.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
R="$T/repo"
mkdir -p "$R/bin" "$R/hooks" "$R/shell" "$R/extras/x" "$R/docs" "$R/.github/workflows"
cp "$BIN/ci-shellcheck.sh" "$R/bin/"
for f in bin/a.sh bin/b.sh hooks/h.sh shell/s.sh extras/x/e.sh; do printf '#!/bin/sh\necho %s\n' "$f" > "$R/$f"; done
echo 'print(1)' > "$R/bin/p.py"; echo '# d' > "$R/docs/d.md"
echo 'disable=SC1091' > "$R/.shellcheckrc"; echo 0.11.0 > "$R/.shellcheck-version"
echo 'name: shellcheck' > "$R/.github/workflows/shellcheck.yml"
g() { git -C "$R" -c user.name=t -c user.email=t@example.invalid "$@"; }
g init -q && g add -A && g commit -qm base || { fail "B: git init"; exit 1; }
base=$(g rev-parse HEAD)
list() { (cd "$R" && sh bin/ci-shellcheck.sh "$@" --list 2>/dev/null) | tr '\n' ' '; }
all=$(list)
[ "$all" = "bin/a.sh bin/b.sh bin/ci-shellcheck.sh extras/x/e.sh hooks/h.sh shell/s.sh " ] \
  || fail "B: no --changed should list every script, got: $all"

echo 'echo more' >> "$R/bin/a.sh"; echo 'x=1' >> "$R/bin/p.py"; echo more >> "$R/docs/d.md"
g rm -q bin/b.sh; printf '#!/bin/sh\n' > "$R/hooks/new.sh"; g add -A; g commit -qm change
got=$(list --changed "$base")
[ "$got" = "bin/a.sh hooks/new.sh " ] || fail "B: --changed should list the added + modified *.sh only, got: $got"

g reset -q --hard "$base"; echo more >> "$R/docs/d.md"; g commit -qam docs
got=$(list --changed "$base")
[ -z "$got" ] || fail "B: a change with no script should list nothing, got: $got"
(cd "$R" && sh bin/ci-shellcheck.sh --changed "$base" >/dev/null 2>&1) \
  || fail "B: a change with no script should pass (nothing to lint), not fail"

for cfg in .shellcheckrc .shellcheck-version bin/ci-shellcheck.sh .github/workflows/shellcheck.yml; do
  g reset -q --hard "$base"; echo '# x' >> "$R/$cfg"; g commit -qam cfg
  got=$(list --changed "$base")
  [ "$got" = "$all" ] || fail "B: a change to $cfg should lint the whole tree, got: $got"
done
got=$(list --changed no-such-rev)
[ "$got" = "$all" ] || fail "B: an unresolvable base should lint the whole tree, got: $got"
[ "$FAILS" -eq 0 ] && ok "B: --changed lints what the change touches; config / unresolvable base ⇒ everything"

# ── C ──
grep -q 'set -- --changed HEAD^1' "$WF/shellcheck.yml" && grep -q 'sh bin/ci-shellcheck.sh' "$WF/shellcheck.yml" \
  && grep -q 'fetch-depth: 2' "$WF/shellcheck.yml" \
  && ok "C: shellcheck.yml runs ci-shellcheck.sh --changed HEAD^1 on a PR, depth 2" \
  || fail "C: shellcheck.yml does not run bin/ci-shellcheck.sh --changed HEAD^1 with fetch-depth 2"

[ "$FAILS" -eq 0 ] && { echo "ci-dedup-selftest: all green"; exit 0; }
echo "ci-dedup-selftest: $FAILS failure(s)"; exit 1
