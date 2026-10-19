#!/bin/bash
# tokenledger-split-shared.sh — the mechanical half of claude-fleet#4811 (EPIC
# #4810 C1): move the packages BOTH the hub and the node use into their own
# module, tokenledger/shared, and rewrite every import that names them.
#
#   bin/tokenledger-split-shared.sh [--check]
#
# Idempotent: a package already under shared/ is left alone, and the import
# rewrite only touches paths still spelled tokenledger/internal/<pkg>. So a Go
# PR that raced this move is merged by re-running the script on top of it
# (EPIC #4810 共同约定 8), never by hand. --check exits 1 (and lists them) when
# a .go file still imports a moved package from internal/.
#
# The list is the packages the node (internal/agent) and the hub (internal/api)
# both import that import neither api, store nor agent — `go list -deps`,
# re-checked when this was written. Adding one later: put it in PKGS and rerun.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TL="$ROOT/tokenledger"
MOD=github.com/verkyyi/claude-fleet/tokenledger
PKGS="control nodesig release sshca identity model codex limits scan sessions attachment spool fleetid credproxy"
alt=$(printf '%s' "$PKGS" | tr ' ' '|')

if [ "${1:-}" = --check ]; then
  left=$(grep -rlE "\"$MOD/internal/($alt)(/[^\"]*)?\"" --include='*.go' "$TL" || true)
  [ -z "$left" ] && { echo "tokenledger-split-shared: every import is on shared/"; exit 0; }
  echo "tokenledger-split-shared: still imported from internal/ — rerun bin/tokenledger-split-shared.sh:"
  printf '%s\n' "$left" | sed "s#^$ROOT/#  #"
  exit 1
fi

cd "$ROOT"
mkdir -p "$TL/shared/cmd"
for p in $PKGS; do
  [ -d "$TL/internal/$p" ] || continue
  if [ -d "$TL/shared/$p" ]; then
    # a raced PR added files under the old path: carry them over one by one
    (cd "$TL/internal/$p" && find . -type f) | while read -r f; do
      mkdir -p "$(dirname "$TL/shared/$p/$f")"
      git mv -f "$TL/internal/$p/$f" "$TL/shared/$p/$f"
    done
  else
    git mv "$TL/internal/$p" "$TL/shared/$p"
  fi
done
[ -d "$TL/cmd/ccquota-srcdigest" ] && git mv "$TL/cmd/ccquota-srcdigest" "$TL/shared/cmd/ccquota-srcdigest"

# imports (and the comments that cite a moved package by its path)
find "$TL" -name '*.go' -type f -print0 | xargs -0 perl -pi -e \
  "s#\\b(tokenledger/)?internal/($alt)\\b#\${1}shared/\$2#g"
# a renamed path re-sorts within its import group: gofmt puts it where CI's
# `gofmt -l` wants it (only files that name shared/ — the rest stay byte for byte)
grep -rlE "$MOD/shared/" --include='*.go' "$TL" | xargs gofmt -w
echo "tokenledger-split-shared: moved $(printf '%s' "$PKGS" | wc -w | tr -d ' ') packages + cmd/ccquota-srcdigest to tokenledger/shared"
