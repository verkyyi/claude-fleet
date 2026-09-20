#!/bin/bash
# doc-preview-render-selftest.sh — the doc-preview skill's renderer contract
# (skills/doc-preview/render.mjs), hermetic: no tailscale, no server, no network.
#
#   • MARKDOWN  `page` wraps the source in the GitHub-styled viewer (client-side
#               marked) and titles the entry from the first `# H1`.
#   • HTML      (issue #526) an .html source is served AS-IS — byte-identical —
#               titled from its <title> (else the file name), same entry json, so
#               a dashboard or an interactive page has a tailnet home too and the
#               fleet's "no Artifacts" rail can be absolute.
#   • REPAGE    `--refresh` re-renders both kinds from the entry's source path and
#               keeps html verbatim (the CURRENT file content).
#   • IMAGES    (issue #810) a LOCAL image referenced by a RELATIVE path — `![]()`
#               in Markdown, `<img src>` in html — is copied beside the served
#               page (on `page` and on `repage`); remote / data: / site-absolute
#               refs and a missing file are left alone, without error.
#
# node absent → SKIP cleanly (exit 0), per the run-selftests convention.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
R="$BIN/../skills/doc-preview/render.mjs"
[ -f "$R" ] || { printf 'selftest: %s not found\n' "$R" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { printf 'doc-preview-render-selftest: node not installed — SKIP\n'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/docprev-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]";; esac; }
title_of() { node -e 'const e=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(e.title)' "$1"; }
render() { ID="$1" HREF="/d/$1/" ADDED="2026-09-02 13:00" SESSION="t" DISP="repo/$(basename "$2")" SRC="$2" \
             node "$R" page "$2" "$WORK/serve/d/$1/index.html" "$WORK/entries/$1.json" >/dev/null; }

# markdown → wrapped viewer, H1 title
printf '# Design note\n\nhello **md**\n' > "$WORK/a.md"
render md1 "$WORK/a.md" || fail "page(md) exited non-zero"
contains "md: served page is the viewer wrapper" "$(cat "$WORK/serve/d/md1/index.html")" "marked"
eq "md: title from H1" "Design note" "$(title_of "$WORK/entries/md1.json")"

# html → verbatim, <title> title
printf '<!doctype html>\n<html><head><title>CD throughput dashboard</title></head>\n<body><h1>dash</h1><script>let x=1</script></body></html>\n' > "$WORK/b.html"
render h1 "$WORK/b.html" || fail "page(html) exited non-zero"
CHECKS=$((CHECKS + 1)); cmp -s "$WORK/b.html" "$WORK/serve/d/h1/index.html" || fail "html: served page must be byte-identical to the source"
eq "html: title from <title>" "CD throughput dashboard" "$(title_of "$WORK/entries/h1.json")"
eq "html: entry keeps the display path" "repo/b.html" "$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).src)' "$WORK/entries/h1.json")"

# html without <title> → file name
printf '<p>no title here</p>\n' > "$WORK/c.htm"
render h2 "$WORK/c.htm" || fail "page(htm) exited non-zero"
eq "html: no <title> → file name" "c.htm" "$(title_of "$WORK/entries/h2.json")"

# html: RELATIVE <img src> files are copied beside the served page (issue #810);
# remote / data: / site-absolute refs and a missing file are left alone, no error
mkdir -p "$WORK/evidence/42"; printf 'PNG' > "$WORK/evidence/42/after.png"
printf '<!doctype html><title>EPIC 7</title>\n<img src="evidence/42/after.png" alt="after"><img src="evidence/42/missing.png">\n<img src="https://x/y.png"><img src="/abs/z.png"><img src="data:image/png;base64,AA==">\n' > "$WORK/e.html"
render h3 "$WORK/e.html" || fail "page(html+img) exited non-zero"
CHECKS=$((CHECKS + 1)); cmp -s "$WORK/e.html" "$WORK/serve/d/h3/index.html" || fail "html+img: the page itself is still served verbatim"
CHECKS=$((CHECKS + 1)); [ -f "$WORK/serve/d/h3/evidence/42/after.png" ] || fail "html: a relative <img src> file must be copied beside the page"
eq "html: copied image bytes intact" "PNG" "$(cat "$WORK/serve/d/h3/evidence/42/after.png")"
CHECKS=$((CHECKS + 1)); [ ! -e "$WORK/serve/d/h3/abs" ] && [ ! -e "$WORK/serve/d/h3/evidence/42/missing.png" ] || fail "html: absolute / missing refs must not produce files"
# a --refresh after a NEW image was referenced picks it up too
printf 'PNG2' > "$WORK/evidence/42/before.png"
printf '<!doctype html><title>EPIC 7</title>\n<img src="evidence/42/before.png"><img src="evidence/42/after.png">\n' > "$WORK/e.html"
node "$R" repage "$WORK/entries/h3.json" "$WORK/serve/d/h3/index.html" >/dev/null || fail "repage(html+img) exited non-zero"
CHECKS=$((CHECKS + 1)); [ -f "$WORK/serve/d/h3/evidence/42/before.png" ] || fail "repage(html): a newly referenced image must be copied"
# markdown images: the pre-existing behaviour, unchanged
printf '# Pics\n\n![after](evidence/42/after.png)\n' > "$WORK/p.md"
render md2 "$WORK/p.md" || fail "page(md+img) exited non-zero"
CHECKS=$((CHECKS + 1)); [ -f "$WORK/serve/d/md2/evidence/42/after.png" ] || fail "md: a relative image must be copied beside the page"

# repage (--refresh) re-reads the CURRENT html verbatim
printf '<!doctype html><title>v2</title><p>edited</p>\n' > "$WORK/b.html"
node "$R" repage "$WORK/entries/h1.json" "$WORK/serve/d/h1/index.html" >/dev/null || fail "repage(html) exited non-zero"
CHECKS=$((CHECKS + 1)); cmp -s "$WORK/b.html" "$WORK/serve/d/h1/index.html" || fail "repage(html): served page must be the current source, verbatim"
eq "repage(html): title refreshed" "v2" "$(title_of "$WORK/entries/h1.json")"
# repage keeps markdown wrapped
node "$R" repage "$WORK/entries/md1.json" "$WORK/serve/d/md1/index.html" >/dev/null || fail "repage(md) exited non-zero"
contains "repage(md): still the viewer wrapper" "$(cat "$WORK/serve/d/md1/index.html")" "marked"

printf 'doc-preview-render-selftest OK (%d checks)\n' "$CHECKS"
