#!/bin/bash
# favicon-selftest.sh — one tab icon, the site's logo (issue #3946).
#
# extras/fleet-theme/logo.svg (+ site/assets' favicon.ico, apple-touch-icon.png)
# is the only source. The console's copies are byte for byte —
#   tokenledger/web/dist/favicon.svg favicon.ico apple-touch-icon.png
# — every page names them at the root, web-chat names the package's own, and no console page, web-chat page or docs page inlines an icon of its own
# (the old green M4 17l4-10… once sat on 28 pages). The Go side has the same
# check for web/dist (tokenledger/web/embed_test.go); this one also runs when
# only the theme package, site/assets or extras/web-chat change.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
bad() { echo "FAIL: $*"; fail=1; }

for pair in "extras/fleet-theme/logo.svg tokenledger/web/dist/favicon.svg" \
            "site/assets/favicon.ico tokenledger/web/dist/favicon.ico" \
            "site/assets/apple-touch-icon.png tokenledger/web/dist/apple-touch-icon.png"; do
  src="${pair%% *}" dst="${pair#* }"
  cmp -s "$ROOT/$src" "$ROOT/$dst" || bad "$dst is not $src (cp $src $dst)"
done

# no inlined icon, no old green / blue one
pages="$(cd "$ROOT" && { git ls-files 'extras/web-chat/ui/index.html' 'extras/web-chat/ui/dist/index.html'; echo site/template.html; })"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -Eq "rel=\"(icon|apple-touch-icon)\"[^>]*href=\"data:|%230e6e5e|%232a78d6" "$ROOT/$f"; then
    bad "$f inlines an icon of its own"
  fi
done <<<"$pages"
grep -q 'href="/favicon.svg"' "$ROOT/bin/docs-build.sh" || bad "bin/docs-build.sh's pages do not name /favicon.svg"
grep -q 'rel="icon"[^>]*href="../../fleet-theme/logo.svg"' "$ROOT/extras/web-chat/ui/index.html" || bad "extras/web-chat/ui/index.html does not name the theme package's logo"

[ "$fail" = 0 ] && echo "PASS favicon-selftest"
exit "$fail"
