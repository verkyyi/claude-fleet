#!/bin/bash
# docs-build-selftest.sh — the public docs build (issue #3575, EPIC #3569 C5).
#
# Builds docs/public/ with bin/docs-build.sh into a sandbox and reads the result:
#
#   A  the build succeeds; every page is HTML + its .md; pages.tsv lists them
#   B  every page has a title (<title> and an <h1>)
#   C  every relative link in every HTML page resolves to a built page or file,
#      read the way the server answers it (/docs/<p> → zh/<p>.html, /en/docs/…)
#   D  the zh and en page sets are the same; an en page with no source says
#      「English version in preparation」 and links to its Chinese page
#   E  each reader has a quickstart: index · self-host/quickstart.md ·
#      hosted/quickstart.md · member/quickstart.md
#   F  no public page links into docs/dev/ (EPIC #3569 共同约定 4)
#   G  the build refuses: an en page with no zh twin, a page with no `# ` title
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/bin/docs-build.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/docs-build-st.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# A
if out="$("$BUILD" --out "$T/out" 2>&1)"; then ok "A build: $out"; else bad "A build failed: $out"; echo "FAIL"; exit 1; fi

python3 - "$T/out" "$ROOT/docs/public" <<'PY' || fail=1
import os, re, sys
from urllib.parse import urljoin, urlparse
OUT, SRC = sys.argv[1], sys.argv[2]
bad = []
rows = [l.split('\t') for l in open(os.path.join(OUT, 'pages.tsv'), encoding='utf-8').read().splitlines() if l]
pages = {(r[0], r[1]): r[3] for r in rows}

def fs_path(lang, p):
    return os.path.join(OUT, lang, p)

def url_of(lang, p):
    pre = '/docs/' if lang == 'zh' else '/en/docs/'
    return pre if p == 'index' else pre + p

def resolve(url):
    u = urlparse(url).path
    if u.startswith('/en/docs/'): lang, rest = 'en', u[len('/en/docs/'):]
    elif u.startswith('/docs/'): lang, rest = 'zh', u[len('/docs/'):]
    else: return None
    if rest == '' or rest.endswith('/'): rest += 'index'
    f = os.path.join(OUT, lang, rest)
    return f if os.path.splitext(rest)[1] else f + '.html'

for (lang, p), state in pages.items():
    base = fs_path(lang, p)
    for ext in ('.html', '.md'):
        if not os.path.isfile(base + ext):
            bad.append('A %s/%s%s missing' % (lang, p, ext))
    if not os.path.isfile(base + '.html'):
        continue
    h = open(base + '.html', encoding='utf-8').read()
    # B
    if not re.search(r'<title>[^<]+</title>', h) or not re.search(r'<h1[^>]*>[^<]+</h1>', h):
        bad.append('B %s/%s has no title' % (lang, p))
    # C
    for href in re.findall(r'href="([^"]+)"', h):
        if re.match(r'^[a-z]+:', href) or href.startswith('#'):
            continue
        target = resolve(urljoin('http://x' + url_of(lang, p), href))
        if target is None or not os.path.isfile(target):
            bad.append('C %s/%s: dead link %s' % (lang, p, href))
    # D
    if state == 'pending':
        if 'English version in preparation' not in h:
            bad.append('D en/%s is pending but says nothing' % p)
        if 'href="%s"' % url_of('zh', p) not in h:
            bad.append('D en/%s does not link its Chinese page' % p)
    # F
    if 'docs/dev' in open(base + '.md', encoding='utf-8').read():
        bad.append('F %s/%s names docs/dev' % (lang, p))

zh = {p for (l, p) in pages if l == 'zh'}
en = {p for (l, p) in pages if l == 'en'}
if zh != en:
    bad.append('D page sets differ: zh only %s, en only %s' % (sorted(zh - en), sorted(en - zh)))
for p in ('index', 'self-host/quickstart', 'hosted/quickstart', 'member/quickstart'):
    if ('zh', p) not in pages or pages[('zh', p)] != 'page':
        bad.append('E zh/%s.md is missing' % p)
for b in bad:
    print('FAIL ' + b)
print('ok   B-F %d pages read (%d zh, %d en pending)' % (len(pages), len(zh), sum(s == 'pending' for s in pages.values())))
sys.exit(1 if bad else 0)
PY

# G — the build refuses a wrong tree
mk() { mkdir -p "$(dirname "$T/$1")"; printf '%s\n' "$2" > "$T/$1"; }
for d in g1 g2; do
  mk "$d/zh/index.md" "# home"
  for r in self-host hosted member; do mk "$d/zh/$r/quickstart.md" "# $r"; done
done
mk g1/en/extra.md "# only in English"
mk g2/zh/faq.md "no title here"
if "$BUILD" --src "$T/g1" --out "$T/g1out" >/dev/null 2>"$T/g1.err"; then bad "G an en-only page was built"
elif grep -q 'has no Chinese page' "$T/g1.err"; then ok "G en-only page refused"; else bad "G g1: $(cat "$T/g1.err")"; fi
if "$BUILD" --src "$T/g2" --out "$T/g2out" >/dev/null 2>"$T/g2.err"; then bad "G a page with no title was built"
elif grep -q 'has no "# " title' "$T/g2.err"; then ok "G untitled page refused"; else bad "G g2: $(cat "$T/g2.err")"; fi

[ "$fail" = 0 ] && echo "PASS docs-build-selftest" || { echo "FAIL docs-build-selftest"; exit 1; }
