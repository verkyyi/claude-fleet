#!/bin/bash
# tokenledger-modules-selftest.sh — the Go blocks under tokenledger/ and the
# direction their dependencies run (claude-fleet#4811, EPIC #4810 共同约定 3).
#
#   shared/  — what the hub and the node both build in; names NO other block
#   (root)   — tokenledger/go.mod, the hub and the node together for now;
#              requires shared and replaces it with ./shared
#
# Later members add their own edges here (agent → shared, hub → shared, hub's
# non-test code never names agent, e2e → all). Static: reads go.mod / go.work
# and the import lines, so it needs no Go toolchain and runs on every shard;
# with Go on PATH it also asks `go list -deps` the same question.
#
#   1. tokenledger/shared/go.mod is the module …/tokenledger/shared
#   2. no .go file under shared/ imports another tokenledger package
#   3. the root go.mod requires shared and replaces it with ./shared; go.work
#      lists both (a person's editor; CI builds each GOWORK=off)
#   4. no moved package is back under internal/, and no import still names one
#      there (bin/tokenledger-split-shared.sh --check — a Go PR that raced the
#      move is merged by rerunning that script)
#   5. the node's developer road builds from a checkout: `go install
#      …/cmd/ccquota@<v>` refuses a module with a replace
set -u
BIN=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$BIN/.." && pwd)
TL="$ROOT/tokenledger"
MOD=github.com/verkyyi/claude-fleet/tokenledger
FAILS=0
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
ok()   { printf 'ok   %s\n' "$*"; }

# --- 1. the shared module ---------------------------------------------------
if [ "$(sed -n 's/^module //p' "$TL/shared/go.mod" 2>/dev/null)" = "$MOD/shared" ]; then
  ok "tokenledger/shared/go.mod is $MOD/shared"
else
  fail "tokenledger/shared/go.mod missing or not module $MOD/shared"
fi

# --- 2. shared names no other block -----------------------------------------
# every quoted tokenledger import path in a .go file under shared/ (an import
# block line or a single import), less those inside shared itself
hits=$(find "$TL/shared" -name '*.go' -type f -exec grep -HnE "^[[:space:]]*(import[[:space:]]+)?([A-Za-z_.]+[[:space:]]+)?\"$MOD/" {} + 2>/dev/null \
         | grep -vE "\"$MOD/shared(/[^\"]*)?\"" | sed "s#^$ROOT/##")
[ -z "$hits" ] && ok "no file under shared/ imports another tokenledger block" \
  || { fail "shared/ imports outside itself:"; printf '%s\n' "$hits" | sed 's/^/     /'; }
if command -v go >/dev/null 2>&1; then
  out=$(cd "$TL/shared" && GOWORK=off GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
        go list -deps -test -f '{{.ImportPath}}' ./... 2>&1); rc=$?
  if [ "$rc" = 0 ]; then
    bad=$(printf '%s\n' "$out" | grep "^$MOD/" | grep -v "^$MOD/shared\(/\|$\)")
    [ -z "$bad" ] && ok "go list -deps: shared/ reaches no other tokenledger package" \
      || { fail "go list -deps: shared/ reaches:"; printf '%s\n' "$bad" | sed 's/^/     /'; }
  else
    case "$out" in   # no module cache / an older toolchain here: the static check above stands
      *GOPROXY=off*|*'module lookup disabled'*|*'missing go.sum entry'*|*'requires go >= '*|*'toolchain'*)
        echo "SKIP go list -deps (no module cache or toolchain here)" ;;
      *) fail "go list -deps in shared/ failed: $(printf '%s' "$out" | head -3 | tr '\n' '|')" ;;
    esac
  fi
fi

# --- 3. the root module points at it ----------------------------------------
grep -qE "^(require)?[[:space:]]*$MOD/shared v" "$TL/go.mod" \
  && ok "tokenledger/go.mod requires $MOD/shared" || fail "tokenledger/go.mod does not require $MOD/shared"
grep -qE "^replace $MOD/shared => \./shared$" "$TL/go.mod" \
  && ok "tokenledger/go.mod replaces shared with ./shared" || fail "tokenledger/go.mod has no 'replace $MOD/shared => ./shared'"
if [ -f "$TL/go.work" ] && grep -qE '^[[:space:]]*\.$|use \.$' "$TL/go.work" && grep -qE '\./shared' "$TL/go.work"; then
  ok "tokenledger/go.work uses . and ./shared"
else
  fail "tokenledger/go.work missing or does not use both . and ./shared"
fi

# --- 4. nothing moved back --------------------------------------------------
pkgs=$(sed -n 's/^PKGS="\(.*\)"$/\1/p' "$BIN/tokenledger-split-shared.sh")
[ -n "$pkgs" ] || fail "no PKGS= line in bin/tokenledger-split-shared.sh"
back=''
for p in $pkgs; do
  [ -d "$TL/internal/$p" ] && back="$back internal/$p"
  [ -d "$TL/shared/$p" ] || fail "shared/$p is missing"
done
[ -z "$back" ] && ok "no shared package is back under internal/" \
  || fail "back under internal/ (rerun bin/tokenledger-split-shared.sh):$back"
[ -d "$TL/cmd/ccquota-srcdigest" ] && fail "cmd/ccquota-srcdigest is back outside shared/"
out=$(bash "$BIN/tokenledger-split-shared.sh" --check 2>&1) \
  && ok "every import of a shared package names shared/" \
  || { fail "imports still name internal/:"; printf '%s\n' "$out" | sed 's/^/     /'; }

# --- 5. no `go install …@<v>` of a module with a replace ---------------------
hits=$(grep -rnE "go[[:space:]]+install[[:space:]]+[^ ]*$MOD/[^ ]*@" "$BIN" 2>/dev/null \
         | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v "$(basename "$0"):")
[ -z "$hits" ] && ok "no bin/ script runs go install …tokenledger…@<version>" \
  || { fail "go install <pkg>@<v> refuses tokenledger's replace — build from a checkout:"; printf '%s\n' "$hits" | sed 's/^/     /'; }

[ "$FAILS" = 0 ] && echo "tokenledger-modules selftest: OK" || { echo "tokenledger-modules selftest: $FAILS FAILED"; exit 1; }
