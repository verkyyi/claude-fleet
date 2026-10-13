#!/bin/bash
# fleet-theme-selftest.sh — ClaudeFleet's colours and fonts are defined in ONE
# place, extras/fleet-theme/ (issue #3924, EPIC #3923 C1).
#
# A "definition" is what would let a page drift from the theme on its own:
#   · a CSS custom property set to one of the theme's colours (the hex values of
#     theme.css's fleet:tokens block: --x: #19182a)
#   · a font family declared with one of the theme's families (Bricolage Grotesque,
#     IBM Plex): font-family / font shorthand / a custom property / @font-face, an
#     @fontsource import, a Google Fonts link
#   · a logo.svg anywhere but the package
# looked for in every tracked style-bearing file (css html tsx ts js mjs go sh py
# svg) but the package itself, built output, tests and their fixtures. Each hit
# outside the package is RED, except a page on the EXEMPT list below — each one
# named with the EPIC #3923 member that replaces it, so the list only shrinks.
#
# Legs:
#   A  the package: theme.css carries the fleet:tokens block, fonts.css names
#      every file in fonts/, logo.svg is there, the system-dark block and its
#      data-theme="dark" twin carry the same lines (claude-fleet#3931)
#   B  the repo: one source (the package), nothing outside it — prints the report
#   C  the consumers take it from the package: site/template.html has the
#      /*{{fleet_theme}}*/ slot, the web chat's theme.css and the console's
#      index.css import it, site-build.sh and site-images.sh read
#      extras/fleet-theme, the way-in pages link the packed copy
#      (web-console-pack.sh copies it, claude-fleet#3932)
#   D  the guard bites: a planted definition (a colour, a family, a logo) in a
#      sandbox copy is red, naming the file
set -uo pipefail
real="$0"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
THEME="$REPO/extras/fleet-theme"
pass=0 fail=0
ok()  { printf 'ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$*"; fail=$((fail + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# scan <root> <file list> — prints `SOURCE <dir>`, `EXEMPT <file> <owner>`,
# `HIT <file>:<line> <what>`; exit 1 on any HIT
scan() {
  python3 - "$1" "$2" <<'PY'
import os, re, sys
root, listing = sys.argv[1:3]
PKG = 'extras/fleet-theme/'
EXEMPT = {   # a page the batch replaces, and the member that does
    'tokenledger/web/dist/app.css': 'C16 #3939 拆掉旧控制台',
    'tokenledger/web/dist/landing.html': 'C16 #3939 拆掉旧控制台',
    'tokenledger/internal/api/oldpages_palette.go': 'C5 #3928 · C7 #3930 单子页、从手机连',
    'bin/docs-build.sh': 'C18 #3941 帮助文档',
    'plugins/fleet-epic/skills/epic-page/template.html': 'EPIC 设计页（doc-preview，不是产品页面）',
}
# built output (a Vite build of the package, committed), tests and their fixtures
SKIP = re.compile(r'^extras/([\w-]+/ui|web-console)/dist(-site)?/|(^|/)(node_modules|testdata)/|selftest|_test\.go$')
EXT = re.compile(r'\.(css|html?|tsx?|jsx?|mjs|go|sh|py|svg)$')
t = open(os.path.join(root, PKG, 'theme.css'), encoding='utf-8').read()
m = re.search(r'/\* fleet:tokens \*/(.*?)/\* /fleet:tokens \*/', t, re.S)
if not m:
    print('HIT %stheme.css:0 no fleet:tokens block' % PKG); sys.exit(1)
hexes = sorted({h.lower() for h in re.findall(r':\s*(#[0-9a-fA-F]{6})\b', m.group(1))})
FAM = r'(Bricolage[ +]Grotesque|IBM[ +]Plex)'
RULES = (
    ('a theme colour as a variable', re.compile(r'--[\w-]+\s*:\s*(%s)\b' % '|'.join(hexes), re.I)),
    ('a theme font family', re.compile(r'(font-family|font|--[\w-]+)\s*:[^;{}]*?["\']?' + FAM)),
    ('an @font-face for a theme family', re.compile(r'@font-face[^}]*' + FAM, re.S)),
    ('an @fontsource import', re.compile(r'@fontsource')),
    ('Google Fonts for a theme family', re.compile(r'fonts\.googleapis\.com/css2?\?[^"\'\s]*family=' + FAM)),
)
hits, exempt = [], {}
for f in open(listing, encoding='utf-8').read().split('\n'):
    if not f or f.startswith(PKG) or SKIP.search(f):
        continue
    if os.path.basename(f) == 'logo.svg':
        hits.append('%s:1 a logo outside the package' % f); continue
    if not EXT.search(f):
        continue
    try:
        text = open(os.path.join(root, f), encoding='utf-8').read()
    except (OSError, UnicodeDecodeError):
        continue
    for what, rx in RULES:
        for mm in rx.finditer(text):
            if f in EXEMPT:
                exempt[f] = EXEMPT[f]
            else:
                hits.append('%s:%d %s: %s' % (f, text.count('\n', 0, mm.start()) + 1, what, mm.group(0)[:80].replace('\n', ' ')))
print('SOURCE %s' % PKG.rstrip('/'))
for f in sorted(exempt):
    print('EXEMPT %s (%s)' % (f, exempt[f]))
for h in hits:
    print('HIT %s' % h)
sys.exit(1 if hits else 0)
PY
}

# --- A: the package -----------------------------------------------------------
if grep -q '/\* fleet:tokens \*/' "$THEME/theme.css" 2>/dev/null && grep -q '/\* /fleet:tokens \*/' "$THEME/theme.css"; then
  ok "A theme.css carries the fleet:tokens block"
else bad "A theme.css has no fleet:tokens block"; fi
missing=""
for f in $(grep -o 'url(\./fonts/[^)]*\.woff2)' "$THEME/fonts.css" 2>/dev/null | sed 's#url(\./##; s#)$##'); do
  [ -f "$THEME/$f" ] || missing="$missing $f"
done
if [ -z "$missing" ] && grep -q 'url(\./fonts/' "$THEME/fonts.css" 2>/dev/null; then ok "A every face in fonts.css is a file in fonts/"
else bad "A fonts.css names missing files:${missing:- (none listed)}"; fi
missing=""
[ -f "$THEME/logo.svg" ] && ok "A logo.svg is in the package" || bad "A no extras/fleet-theme/logo.svg"
for v in $(grep -o -- '--fleet-[a-z0-9-]*:' "$THEME/theme.css" | tr -d : | sort -u); do
  grep -q -- "\`$v\`" "$THEME/README.md" 2>/dev/null || missing="$missing $v"
done
[ -z "$missing" ] && ok "A README.md has a line for every --fleet- variable" || bad "A README.md lacks:$missing"
# the console's 深浅色 (claude-fleet#3931): the chosen dark is the system's dark, line for line
sysdark=$(awk '/:root:not\(\[data-theme="light"\]\) \{/{f=1;next} f&&/^  \}/{exit} f{sub(/^ +/,"");print}' "$THEME/theme.css")
pickdark=$(awk '/^:root\[data-theme="dark"\] \{/{f=1;next} f&&/^\}/{exit} f{sub(/^ +/,"");print}' "$THEME/theme.css")
if [ -n "$sysdark" ] && [ "$sysdark" = "$pickdark" ]; then ok "A the data-theme=\"dark\" block is the system dark block, line for line"
else bad "A theme.css: the system dark block and :root[data-theme=\"dark\"] differ (or one is missing)"; fi

# --- B: the repo --------------------------------------------------------------
git -C "$REPO" ls-files > "$T/files" 2>/dev/null || find "$REPO" -type f | sed "s#^$REPO/##" > "$T/files"
out="$(scan "$REPO" "$T/files")"; rc=$?
printf '%s\n' "$out" | sed 's/^/     /'
src="$(printf '%s\n' "$out" | grep -c '^SOURCE ')"
if [ "$rc" = 0 ] && [ "$src" = 1 ]; then ok "B colours and fonts come from 1 source (extras/fleet-theme), nothing else defines them"
else bad "B a theme colour / font / logo is defined outside extras/fleet-theme (the HIT lines above)"; fi

# --- C: the consumers ---------------------------------------------------------
grep -q '/\*{{fleet_theme}}\*/' "$REPO/site/template.html" && ok "C the website's template takes the theme through its slot" \
  || bad "C site/template.html has no /*{{fleet_theme}}*/ slot"
grep -q '@import "../../../fleet-theme/theme.css"' "$REPO/extras/web-chat/ui/src/theme.css" && ok "C the web chat imports the package" \
  || bad "C extras/web-chat/ui/src/theme.css does not import extras/fleet-theme/theme.css"
grep -q 'THEME="$REPO/extras/fleet-theme"' "$REPO/bin/web-console-pack.sh" \
  && grep -q 'themePrefix + `theme.css' "$REPO/tokenledger/internal/api/entry_pages.go" \
  && ok "C the way-in pages link the theme web-console-pack.sh packs" \
  || bad "C the way-in pages (entry_pages.go) do not take extras/fleet-theme through web-console-pack.sh"
grep -q '@import "../../../fleet-theme/theme.css"' "$REPO/extras/web-console/src/shared/index.css" && ok "C the console imports the package (#3926)" \
  || bad "C extras/web-console/src/shared/index.css does not import extras/fleet-theme/theme.css"
for s in site-build.sh site-images.sh; do
  grep -q "extras.*fleet-theme\|'extras', 'fleet-theme'" "$REPO/bin/$s" && ok "C $s reads extras/fleet-theme" || bad "C $s does not read extras/fleet-theme"
done

# --- D: the guard bites -------------------------------------------------------
mkdir -p "$T/r/extras" "$T/r/x"
cp -R "$THEME" "$T/r/extras/fleet-theme"
printf ':root{--brand:#D9765A}\n' > "$T/r/x/a.css"
printf 'body{font:600 15px "IBM Plex Sans",sans-serif}\n' > "$T/r/x/b.html"
printf '<svg/>\n' > "$T/r/x/logo.svg"
printf ':root{--ink:#123456;font-family:Georgia}\n' > "$T/r/x/fine.css"
printf 'extras/fleet-theme/theme.css\nextras/fleet-theme/fonts.css\nx/a.css\nx/b.html\nx/logo.svg\nx/fine.css\n' > "$T/rfiles"
out="$(scan "$T/r" "$T/rfiles")"; rc=$?
if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q '^HIT x/a.css:1 a theme colour' \
   && printf '%s\n' "$out" | grep -q '^HIT x/b.html:1 a theme font family' \
   && printf '%s\n' "$out" | grep -q '^HIT x/logo.svg' && ! printf '%s\n' "$out" | grep -q 'fine.css'; then
  ok "D a planted colour, family and logo are red; an unrelated colour is not"
else bad "D the guard missed a planted definition (rc $rc): $out"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
