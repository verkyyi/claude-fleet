#!/bin/bash
# tokenledger-split-hub.sh — the mechanical half of claude-fleet#4814 (EPIC
# #4810 C4): the hub becomes its own module, tokenledger/hub, and the root
# tokenledger/go.mod is gone.
#
#   bin/tokenledger-split-hub.sh [--check]
#
#   go.mod go.sum        → hub/go.mod hub/go.sum   (module …/tokenledger/hub)
#   cmd/ccquota/         → hub/cmd/ccquota/        (the hub's build)
#   internal/<pkg>/      → hub/<pkg>/              (api store credvault mcp …)
#   web/                 → hub/web/                (what the hub embeds)
#
# and every path that names them — Go imports, and the repo's scripts, docs and
# workflows (tokenledger/internal/X → tokenledger/hub/X, tokenledger/cmd/ →
# tokenledger/hub/cmd/, tokenledger/web → tokenledger/hub/web, tokenledger/go.mod
# → tokenledger/hub/go.mod). Idempotent like bin/tokenledger-split-agent.sh: a
# file already moved is left alone and only old spellings are rewritten, so a Go
# PR that raced this move is merged by re-running the script on top of it (EPIC
# #4810 共同约定 8), never by hand. --check exits 1 (and lists them) when
# something still names the old place.
#
# The hand-made half — hub/go.mod no longer requiring agent, the hub's main
# without agent/cli, the联调 tests in tokenledger/e2e and their harness
# hub/apitest — was written once in the same commit; a raced edit to one of
# those spots is a normal merge. A raced api test that starts a node
# (`tokenledger/agent`) must move to e2e/ by hand: the hub module refuses it
# (bin/tokenledger-modules-selftest.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TL="$ROOT/tokenledger"
MOD=github.com/verkyyi/claude-fleet/tokenledger
# the text files whose paths must not be rewritten: digest vectors (a fixed
# hash over the old paths) and the split scripts, which name them on purpose
KEEP='^(tokenledger/shared/release/srcdigest_test\.go|bin/fleet-src-digest-selftest\.sh|bin/tokenledger-(split-(hub|agent|shared)|modules-selftest)\.sh)$'
OLD_RE='tokenledger/(internal(?![\w-])|cmd(?![\w-])|go\.(mod|sum)\b|web\b(?![-.]))'
# tracked text files naming an old path (perl: BSD grep has no -P); a line that
# says compat-1v names it on purpose (an older commit still has it there)
old_files() {
  git ls-files -z | xargs -0 perl -e 'for $f (@ARGV) { next unless -f $f && -T $f; open F, "<", $f or next;
    while (<F>) { next if /compat-1v/; if (m{'"$OLD_RE"'}) { print "$f\n"; last } } close F }' | grep -vE "$KEEP" || true
}

if [ "${1:-}" = --check ]; then
  left=""
  for p in go.mod go.sum cmd web; do [ -e "$TL/$p" ] && left="$left
tokenledger/$p"; done
  [ -d "$TL/internal" ] && left="$left
tokenledger/internal/"
  more=$(cd "$ROOT" && old_files)
  for f in "$ROOT"/bin/fleet-break-it*-selftest.sh; do
    [ -f "$f" ] && grep -qE 'GOWORK=off GOFLAGS=-mod=mod GOPROXY=off' "$f" && more="$more
${f#"$ROOT"/}"
  done
  grep -qE '^(tokenledge\?/(internal|cmd)/|\*\*/internal/)' "$ROOT/conf/oss-scan.allow" 2>/dev/null && more="$more
conf/oss-scan.allow"
  left=$(printf '%s\n%s\n' "$left" "$more" | sed '/^$/d')
  [ -z "$left" ] && { echo "tokenledger-split-hub: everything is on hub/"; exit 0; }
  echo "tokenledger-split-hub: still in (or naming) the old place — rerun bin/tokenledger-split-hub.sh:"
  printf '%s\n' "$left" | sed 's/^/  /'
  exit 1
fi

cd "$ROOT"
mkdir -p "$TL/hub"
mvtree() { # <from dir> <to dir>: file by file, so a raced file joins the moved tree
  [ -d "$1" ] || return 0
  (cd "$1" && git ls-files) | while read -r f; do
    mkdir -p "$(dirname "$2/$f")"
    git mv -f "$1/$f" "$2/$f"
  done
  # ignored leftovers (a packed client, built web assets) follow their tree
  if [ -d "$1" ]; then
    (cd "$1" && find . -type f) | while read -r f; do
      mkdir -p "$(dirname "$2/$f")"; mv -f "$1/$f" "$2/$f"
    done
    find "$1" -depth -type d -empty -delete 2>/dev/null || true
  fi
}
for f in go.mod go.sum; do [ -f "$TL/$f" ] && git mv -f "$TL/$f" "$TL/hub/$f"; done
mvtree "$TL/cmd" "$TL/hub/cmd"
mvtree "$TL/web" "$TL/hub/web"
if [ -d "$TL/internal" ]; then
  for d in "$TL"/internal/*/; do
    d=${d%/}; mvtree "$d" "$TL/hub/${d##*/}"
  done
  rmdir "$TL/internal" 2>/dev/null || true
fi

# the hub's module: its own path, shared one directory up, no agent
perl -pi -e "s#^module $MOD\$#module $MOD/hub#; s#=> \\./shared\$#=> ../shared#" "$TL/hub/go.mod"
perl -ni -e "print unless m#$MOD/agent #" "$TL/hub/go.mod"

# every path that names the old place (Go imports and comments, scripts, docs)
old_files | while read -r f; do
  perl -pi -e 'next if /compat-1v/; s#tokenledger/internal(?![\w-])#tokenledger/hub#g;
               s#tokenledger/cmd(?![\w-])#tokenledger/hub/cmd#g;
               s#tokenledger/go\.(mod|sum)\b#tokenledger/hub/go.$1#g;
               s#tokenledger/web\b(?![-.])#tokenledger/hub/web#g' "$f"
done
# the BREAK-IT drills' Go halves run from tokenledger/, which is no module now:
# in workspace mode (go.work), the hub's packages at ./hub/<pkg>
for f in "$ROOT"/bin/fleet-break-it*-selftest.sh; do
  perl -0pi -e 's/(cd "\$ROOT\/tokenledger" && (?:\\\n\s*|[A-Z_]+="[^"]*" \\\n\s*)?)GOWORK=off GOFLAGS=-mod=mod GOPROXY=off/${1}GOFLAGS=\x27\x27 GOPROXY=off/g' "$f"
  perl -pi -e 'if (/go (test|build|vet|list)\b/ || /term_go |_drill_go_tests /) { s#(?<![\w/])\./internal/#./hub/#g; s#(?<![\w/])\./cmd/ccquota\b#./hub/cmd/ccquota#g }' "$f"
done
# conf/oss-scan.allow spells the tree tokenledge?/… (and **/internal/<pkg>/…)
perl -pi -e 's#^tokenledge\?/internal/#tokenledge?/hub/#; s#^tokenledge\?/cmd/#tokenledge?/hub/cmd/#;
             s#^\*\*/internal/(api|store|credvault|mcp|findings|authz|badge|dns|leader|rolemerge)/#**/hub/$1/#' "$ROOT/conf/oss-scan.allow"
# a renamed import re-sorts within its group (only files that name hub/)
grep -rlE "\"$MOD/hub/" --include='*.go' "$TL" | xargs gofmt -w
echo "tokenledger-split-hub: go.mod cmd/ internal/* web/ → tokenledger/hub/"
