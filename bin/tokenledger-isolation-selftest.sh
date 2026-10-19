#!/bin/bash
# tokenledger-isolation-selftest.sh — the tokenledger/ subtree is inert to the
# fleet (issue #1391).
#
# TokenLedger (Go: the ccquota hub + agent + web) was merged into this repo under
# tokenledger/ with its full history. The live install is a git checkout of this
# repo, so every login now carries a tokenledger/ directory — and that must change
# NOTHING about the fleet. "Degenerate case is sacred": a live install with the
# extra directory behaves byte for byte as one without it. Four rails:
#
#   1. install sync never builds Go — fleet-install-apply.sh and
#      fleet-sync-logins.sh invoke no `go`/`npm`/`docker` and never name
#      tokenledger/ (they may COPY it as plain files; they must not act on it);
#   2. no hook, daemon unit or tmux conf names tokenledger/ — so the extra
#      directory cannot alter any hook/daemon behaviour;
#   3. CI is split both ways: the PR gate's plan (bin/ci-plan.sh, issue #4815)
#      never runs the selftests for tokenledger/**, and runs the Go tests ONLY for
#      tokenledger/** (plus the few scripts and the workflow that gate them);
#      selftests-macos.yml has no PR trigger at all;
#   4. run-selftests.sh --changed, driven for real in a throwaway repo, picks
#      only the lint group for a change confined to tokenledger/ — even when a
#      test names a file whose basename matches one in there (hub.go, README.md).
set -u

BIN=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$BIN/.." && pwd)

FAILS=0
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
ok()   { printf 'ok   %s\n' "$*"; }

# --- 1. install sync never builds Go ----------------------------------------
for s in fleet-install-apply.sh fleet-sync-logins.sh; do
  f="$BIN/$s"
  [ -f "$f" ] || { fail "$s missing"; continue; }
  # Code lines only: a comment may explain this very rule.
  hits=$(grep -nE '(^|[^A-Za-z0-9_./-])(go[[:space:]]+(build|install|test|run|generate|mod)|npm[[:space:]]|docker[[:space:]]|make[[:space:]]+-C)' "$f" \
           | grep -vE '^[0-9]+:[[:space:]]*#')
  [ -z "$hits" ] && ok "$s runs no go/npm/docker build" \
    || { fail "$s invokes a build:"; printf '%s\n' "$hits" | sed 's/^/     /'; }
  hits=$(grep -n 'tokenledger' "$f" | grep -vE '^[0-9]+:[[:space:]]*#')
  [ -z "$hits" ] && ok "$s never names tokenledger/" \
    || { fail "$s acts on tokenledger:"; printf '%s\n' "$hits" | sed 's/^/     /'; }
done

# --- 2. no hook / daemon / conf names it ------------------------------------
hits=''
for d in hooks launchd systemd conf; do
  [ -d "$ROOT/$d" ] || continue
  # a line that only keeps it OUT (conf/release-tree.list's `!tokenledger/`,
  # #2771) or a comment is not acting on it
  h=$(grep -rlE '^[^#!]*tokenledger/' "$ROOT/$d" 2>/dev/null)
  [ -n "$h" ] && hits="$hits$h
"
done
[ -z "$hits" ] && ok "no hook / daemon unit / conf names tokenledger/" \
  || { fail "a hook/daemon/conf names tokenledger/:"; printf '%s' "$hits" | sed 's/^/     /'; }

# --- 3. CI split both ways --------------------------------------------------
WF="$ROOT/.github/workflows"
# paths_of <file> — every `- '<glob>'` entry of the file's `paths:` lists.
paths_of() {
  awk '/^[[:space:]]*paths:[[:space:]]*$/ { inp = 1; next }
       inp && /^[[:space:]]*-[[:space:]]/ { s = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", s); gsub(/["'\'']/, "", s); print s; next }
       { inp = 0 }' "$1"
}
w=selftests-macos.yml
if [ -f "$WF/$w" ]; then
  # no push / pull_request trigger at all (since #3141: nightly + dispatch only)
  grep -qE '^[[:space:]]*(push|pull_request):' "$WF/$w" \
    && fail "$w runs on a push or PR" || ok "$w is never triggered by a push or PR"
else
  fail "$w missing"
fi
# the PR gate (issue #4815): ONE plan, bin/ci-plan.sh, says what a PR runs
eval "$(sed -n '/^check_rules()/,/^}/p; /^block_of()/,/^}/p' "$BIN/ci-plan.sh")"
globs=""
if command -v check_rules >/dev/null 2>&1 && check_rules selftests; then
  bad=''
  for g in $globs; do case "$g" in tokenledger*|'*'|'**'*) bad="$bad $g" ;; esac; done
  [ -z "$bad" ] && ok "the selftests' plan rule never matches tokenledger/**" \
    || fail "the selftests' plan rule matches tokenledger/**:$bad"
else
  fail "bin/ci-plan.sh has no selftests rule"
fi
if command -v block_of >/dev/null 2>&1; then
  out=''
  for f in bin/fleet-lib.sh hooks/bash-guard.py conf/x.conf docs/README.md; do out="$out$(block_of "$f")"; done
  [ -z "$out" ] && ok "the Go tests run for no change outside tokenledger/ (shell, hooks, conf, docs)" \
    || fail "a shell / hook / conf / docs change reaches a Go block: [$out]"
  [ "$(block_of tokenledger/hub/api/x.go)" = hub ] && ok "a tokenledger/ change reaches its Go block" \
    || fail "tokenledger/hub/api/x.go reaches no Go block"
else
  fail "bin/ci-plan.sh has no block_of"
fi
T_WF="$WF/tokenledger.yml"
if [ -f "$T_WF" ]; then
  grep -qE '^[[:space:]]*(push|pull_request):' "$T_WF" \
    && fail "tokenledger.yml runs on a push or PR by itself (ci.yml calls it)" \
    || ok "tokenledger.yml runs only when the PR gate calls it (or by hand)"
  grep -qE '^[[:space:]]*working-directory:[[:space:]]*tokenledger$' "$T_WF" \
    && ok "tokenledger.yml runs inside tokenledger/" || fail "tokenledger.yml has no working-directory: tokenledger"
else
  fail "tokenledger.yml missing"
fi

# --- 4. run-selftests.sh --changed ignores tokenledger/ ---------------------
if command -v git >/dev/null 2>&1; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/fleet-selftest-tokenledger.XXXXXX") || exit 1
  trap 'rm -rf "$T"' EXIT
  R="$T/repo"
  mkdir -p "$R/bin" "$R/tokenledger/hub/cmd/ccquota"
  cp "$BIN/run-selftests.sh" "$BIN/selftest-shadow-root.sh" "$R/bin/"
  mk_test() { printf '#!/bin/sh\n# %s\nexit 0\n' "$2" > "$R/bin/$1-selftest.sh"; }
  mk_test portability 'lint: scans the whole tree'
  mk_test alpha       'reads hub.go and README.md and Makefile'
  mk_test beta        'drives tool-b.sh'
  printf '#!/bin/sh\n' > "$R/bin/tool-b.sh"
  echo 'package main' > "$R/tokenledger/hub/cmd/ccquota/hub.go"
  echo '# tl' > "$R/tokenledger/README.md"
  echo 'all:' > "$R/tokenledger/Makefile"
  g() { git -C "$R" -c user.name=t -c user.email=t@example.invalid "$@"; }
  g init -q && g add -A && g commit -qm base && g tag base
  echo '// edit' >> "$R/tokenledger/hub/cmd/ccquota/hub.go"
  echo more >> "$R/tokenledger/README.md"
  echo '	true' >> "$R/tokenledger/Makefile"
  g add -A && g commit -qm tl
  out=$(env -u FLEET_SELFTEST_ROOT -u FLEET_SELFTEST_NO_SHADOW FLEET_HEAVY=0 \
        sh "$R/bin/run-selftests.sh" --changed base </dev/null 2>&1); rc=$?
  ran=$(printf '%s\n' "$out" | awk '/^PASS /{print $2}' | sort | tr '\n' ' ')
  [ "$rc" -eq 0 ] && [ "$ran" = 'portability-selftest.sh ' ] \
    && ok "--changed: a tokenledger/-only change runs the lint group alone" \
    || { fail "--changed on tokenledger/: rc=$rc ran=[$ran]"; printf '%s\n' "$out" | grep '^select' | sed 's/^/     /'; }
else
  echo "SKIP: git not installed (rail 4)"
fi

[ "$FAILS" -eq 0 ] || { echo "tokenledger-isolation-selftest: $FAILS failure(s)"; exit 1; }
echo "tokenledger-isolation-selftest: all green"
