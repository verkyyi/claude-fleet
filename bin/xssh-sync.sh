#!/bin/bash
# xssh-sync.sh — the door's patched copy of golang.org/x/crypto/ssh (A5SQ).
#
# The door terminates each person's SSH and hands the hub the signature they
# made to log in (the hub signs the hop home only for it — docs/dev/DOOR-SIMPLIFY.md
# §5). golang.org/x/crypto/ssh verifies that signature but never gives it to
# its caller, so the door carries ONE package of it, copied verbatim, with ONE
# small patch (tokenledger/agent/internal/xssh/fleet.patch: ServerConfig.
# SignedPublicKeyCallback, called after the signature verified, with it).
#
#   xssh-sync.sh           copy the ssh package (and its bcrypt_pbkdf) of the
#                          x/crypto version tokenledger/agent/go.mod requires,
#                          rewrite its two module-internal imports, apply the patch
#   xssh-sync.sh --check   the same into a scratch dir and compare: exit 0 when the
#                          copy in the tree is exactly that (upstream + the patch),
#                          1 when not (and says which file), 3 with no go toolchain
#
# When to run it: whenever golang.org/x/crypto moves in tokenledger/agent/go.mod
# (a security fix upstream — Dependabot or by hand): bump it, run this, commit
# both. xssh-sync-selftest.sh reds until the copy matches the required version.
# tokenledger/agent/internal/xssh/README.md says the same for a person.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="${XSSH_DEST:-$ROOT/tokenledger/agent/internal/xssh}"   # XSSH_DEST: the drill's seam
CHECK=0
[ "${1:-}" = --check ] && CHECK=1
command -v go >/dev/null 2>&1 || { echo "xssh-sync: no go toolchain here" >&2; exit 3; }
VER=$(awk '$1 == "golang.org/x/crypto" { print $2; exit }' "$ROOT/tokenledger/agent/go.mod")
[ -n "$VER" ] || { echo "xssh-sync: tokenledger/agent/go.mod requires no golang.org/x/crypto" >&2; exit 1; }
SRC=$(cd "$ROOT/tokenledger/agent" && GOFLAGS=-mod=mod go mod download -json "golang.org/x/crypto@$VER" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Dir",""))')
[ -n "$SRC" ] && [ -d "$SRC/ssh" ] || { echo "xssh-sync: golang.org/x/crypto@$VER is not in the module cache" >&2; exit 1; }
OUT=$(mktemp -d "${TMPDIR:-/tmp}/xssh.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/internal/bcrypt_pbkdf"
for f in "$SRC"/ssh/*.go; do
  case $f in *_test.go) continue ;; esac
  cp "$f" "$OUT/"
done
cp "$SRC/ssh/internal/bcrypt_pbkdf/bcrypt_pbkdf.go" "$OUT/internal/bcrypt_pbkdf/"
cp "$SRC/LICENSE" "$OUT/LICENSE"
chmod u+w "$OUT"/*.go "$OUT/internal/bcrypt_pbkdf"/*.go "$OUT/LICENSE"
# the two imports a copy outside the module cannot keep: x/crypto's internal
# poly1305 (its public face has the same Sum / Verify / TagSize) and the
# package's own internal bcrypt_pbkdf (copied beside it)
for f in "$OUT"/*.go; do
  sed -e 's#"golang.org/x/crypto/internal/poly1305"#"golang.org/x/crypto/poly1305" //nolint:staticcheck // xssh: the public face of the same code#' \
      -e 's#"golang.org/x/crypto/ssh/internal/bcrypt_pbkdf"#"github.com/verkyyi/claude-fleet/tokenledger/agent/internal/xssh/internal/bcrypt_pbkdf"#' \
      "$f" > "$f.new" && mv "$f.new" "$f"
done
(cd "$OUT" && patch -s -p1 < "$DEST/fleet.patch") || { echo "xssh-sync: fleet.patch does not apply to x/crypto@$VER — redo it by hand" >&2; exit 1; }
printf '%s\n' "$VER" > "$OUT/UPSTREAM_VERSION"
if [ "$CHECK" = 1 ]; then
  bad=0
  for f in $(cd "$OUT" && find . -type f | sort); do
    cmp -s "$OUT/$f" "$DEST/$f" || { echo "xssh-sync: ${f#./} differs from x/crypto@$VER + fleet.patch" >&2; bad=1; }
  done
  for f in $(cd "$DEST" && find . -type f ! -name fleet.patch ! -name README.md ! -name '*_test.go' | sort); do
    [ -e "$OUT/$f" ] || { echo "xssh-sync: ${f#./} is not upstream's" >&2; bad=1; }
  done
  [ "$bad" = 0 ] && echo "xssh-sync: the copy is x/crypto@$VER + fleet.patch"
  exit "$bad"
fi
find "$DEST" -type f ! -name fleet.patch ! -name README.md ! -name '*_test.go' -delete
cp -R "$OUT"/. "$DEST"/
echo "xssh-sync: copied x/crypto@$VER ssh + fleet.patch into ${DEST#$ROOT/}"
