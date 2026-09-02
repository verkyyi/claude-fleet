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

# repage (--refresh) re-reads the CURRENT html verbatim
printf '<!doctype html><title>v2</title><p>edited</p>\n' > "$WORK/b.html"
node "$R" repage "$WORK/entries/h1.json" "$WORK/serve/d/h1/index.html" >/dev/null || fail "repage(html) exited non-zero"
CHECKS=$((CHECKS + 1)); cmp -s "$WORK/b.html" "$WORK/serve/d/h1/index.html" || fail "repage(html): served page must be the current source, verbatim"
eq "repage(html): title refreshed" "v2" "$(title_of "$WORK/entries/h1.json")"
# repage keeps markdown wrapped
node "$R" repage "$WORK/entries/md1.json" "$WORK/serve/d/md1/index.html" >/dev/null || fail "repage(md) exited non-zero"
contains "repage(md): still the viewer wrapper" "$(cat "$WORK/serve/d/md1/index.html")" "marked"

printf 'doc-preview-render-selftest OK (%d checks)\n' "$CHECKS"
