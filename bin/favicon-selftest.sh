#!/bin/bash
# favicon-selftest.sh — one tab icon, the site's logo (issue #3946).
#
# extras/fleet-theme/logo.svg (+ site/assets' favicon.ico, apple-touch-icon.png)
# is the only source. The console's copies are byte for byte —
#   tokenledger/hub/web/dist/favicon.svg favicon.ico apple-touch-icon.png
# — every page names them at the root, web-chat names the package's own, and no console page, web-chat page or docs page inlines an icon of its own
# (the old green M4 17l4-10… once sat on 28 pages). The Go side has the same
# check for web/dist (tokenledger/hub/web/embed_test.go); this one also runs when
# only the theme package, site/assets or extras/web-chat change.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/bin/selftest-lib.sh"
FAIL=0

for pair in "extras/fleet-theme/logo.svg tokenledger/hub/web/dist/favicon.svg" \
            "site/assets/favicon.ico tokenledger/hub/web/dist/favicon.ico" \
            "site/assets/apple-touch-icon.png tokenledger/hub/web/dist/apple-touch-icon.png"; do
  src="${pair%% *}" dst="${pair#* }"
  cmp -s "$ROOT/$src" "$ROOT/$dst" || st_miss "$dst is not $src (cp $src $dst)"
done

# no inlined icon, no old green / blue one
pages="$(cd "$ROOT" && { git ls-files 'extras/web-chat/ui/index.html' 'extras/web-chat/ui/dist/index.html'; echo site/template.html; })"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -Eq "rel=\"(icon|apple-touch-icon)\"[^>]*href=\"data:|%230e6e5e|%232a78d6" "$ROOT/$f"; then
    st_miss "$f inlines an icon of its own"
  fi
done <<<"$pages"
grep -q 'href="/favicon.svg?v=@@ICONV@@"' "$ROOT/bin/docs-build.sh" || st_miss "bin/docs-build.sh's pages do not name /favicon.svg?v=<the logo's version>"

# a new logo is a new icon URL (Safari keys its favicon cache by URL): every page
# names the root icons with ?v=<sha256(logo.svg)[:8]> — the hub's AppIconV, the
# static pages' {{icon_v}} (filled by site-build.sh), the admin page's literal
V="$(shasum -a 256 "$ROOT/extras/fleet-theme/logo.svg" | cut -c1-8)"
grep -q "const AppIconV = \"$V\"" "$ROOT/tokenledger/hub/api/site_serve.go" || st_miss "tokenledger/hub/api/site_serve.go: AppIconV is not $V (the logo's sha256[:8])"
grep -q "href=\"/favicon.svg?v=$V\"" "$ROOT/extras/web-console/admin/index.html" || st_miss "extras/web-console/admin/index.html: /favicon.svg is not ?v=$V"
for f in site/template.html site/legal.html; do
  for i in favicon.ico favicon.svg apple-touch-icon.png; do
    grep -q "href=\"/$i?v={{icon_v}}\"" "$ROOT/$f" || st_miss "$f: /$i carries no ?v={{icon_v}}"
  done
done
grep -q 'rel="icon"[^>]*href="../../fleet-theme/logo.svg"' "$ROOT/extras/web-chat/ui/index.html" || st_miss "extras/web-chat/ui/index.html does not name the theme package's logo"
# Safari draws no SVG tab icon: without an .ico link it asks the root /favicon.ico
# and keeps whatever it got there for good — every page names one of its own
for f in extras/web-console/app/index.html extras/web-chat/ui/index.html extras/web-console/admin/index.html; do
  grep -q 'rel="icon" href="[^"]*favicon.ico[^"]*" sizes="32x32"' "$ROOT/$f" || st_miss "$f names no favicon.ico (Safari shows no SVG icon)"
done

st_done
