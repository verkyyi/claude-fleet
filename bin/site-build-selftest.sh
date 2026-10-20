#!/bin/bash
# site-build-selftest.sh — the public website build (issue #3584, EPIC #3569 C14).
#
# Builds site/ with bin/site-build.sh into a sandbox and reads the result:
#
#   A  no drill result: both pages build, and neither says a number of seconds
#      anywhere — the try button reads 「立即体验」 / "Try it", the hero's second
#      button 「申请使用」 → /apply, and neither page says anyone can start right
#      away (免费试用 · 登录就能 · 马上 · 现在就试 / Free trial · Start now · Try it now ·
#      sign in and — issue #4049)
#   B  each page's head: <html lang>, title, description, canonical, hreflang
#      zh-CN · en · x-default (→ /en/), og:* and twitter:* with a 1200×630 card
#      that exists, every absolute URL on the __ORIGIN__ placeholder
#   C  the JSON-LD parses: @graph has Organization · WebSite · SoftwareApplication
#      (its UseAction → /app/try) · FAQPage, and the FAQPage is the page's visible
#      FAQ word for word — which is docs-faq.py's site list, word for word
#   D  a drill whose slowest run is ≤ 60 s: 「60 秒」 / "60 seconds" on the page,
#      each step's seconds, the stopwatch and the drill's date
#   E  a drill over 60 s: the measured time in its place, no 「60 秒」, a RED: line
#   F  a drill older than 7 days: no seconds at all, a RED: line
#   G  the build refuses (exit 1) a string that states seconds no drill measured
#   H  every local href / src on both pages is a file the hub serves from the
#      build (/site/<f>, /favicon.*, /apple-touch-icon.png), or a path it owns
#      elsewhere (/app…, /docs/…, /en/docs/…, /, /en/)
#   I  the internal-name rule table finds nothing in the built pages
#      (conf/oss-scan.rules — the hub's address is filled in when served)
#   J  the files for search engines and AI assistants (issue #3585, C15):
#      robots.txt opens / /en/ /docs/ and closes /app/ /v1/ (the AI crawlers
#      named) and names the sitemap; sitemap.xml parses and lists both front
#      pages + every doc docs-build.sh built as a page — exactly those — each
#      address one the hub answers 200 from the build (site_serve.go's rules),
#      zh/en pairs as xhtml:link; llms.txt / llms-zh.txt are llmstxt.org-shaped
#      (H1 · > summary · ## lists of [links](…)), every link answered; llms-full
#      carries every doc's title; a doc added to docs/public/ is in all of them
#   T  fleet.trial off (issue #4269): the apply/ pages and llms files offer no
#      trial — every CTA 申请使用 → /apply, no drill seconds — and the trial pages
#      keep theirs
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/bin/selftest-lib.sh"
BUILD="$ROOT/bin/site-build.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/site-build-st.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0
bad() { echo "FAIL $*"; fail=1; }
NOW=2026-10-12

# A — no drill
if out="$("$BUILD" --out "$T/a" --drill "$T/none.json" --now "$NOW" 2>&1)"; then st_ok_all "A build: $out"; else bad "A build failed: $out"; echo FAIL; exit 1; fi

python3 - "$T/a" "$ROOT" <<'PY' || fail=1
import html, json, os, re, struct, subprocess, sys
OUT, ROOT = sys.argv[1], sys.argv[2]
bad = []
SECS = re.compile(r'\d+\s*(秒|s(?![a-z])|seconds?\b)|\b\d{1,2}:\d\d\b|分钟|minutes')

def text(page):
    ld = ''.join(re.findall(r'<script type="application/ld\+json">(.*?)</script>', page, flags=re.S))
    metas = ' '.join(re.findall(r'<meta [^>]*content="([^"]*)"', page))
    body = re.sub(r'<(script|style)[^>]*>.*?</\1>', ' ', page, flags=re.S)
    return html.unescape(' '.join([metas, ld, re.sub(r'<[^>]+>', ' ', body)]))

for lang, rel, url, tryw in (('zh-CN', 'index.html', '/', '立即体验'), ('en', 'en/index.html', '/en/', 'Try it')):
    p = open(os.path.join(OUT, rel), encoding='utf-8').read()
    t = text(p)
    # A — the trial's length (15 分钟 / 15 minutes, #4049) is a rule, not a timing
    for m in SECS.finditer(re.sub(r'15\s*(分钟|minutes)', ' ', t)):
        bad.append('A %s: says "%s" with no drill' % (rel, t[max(0, m.start() - 15):m.end() + 5].strip()))
    if tryw not in t:
        bad.append('A %s: no "%s" button' % (rel, tryw))
    if 'href="/apply" data-out>' not in p:
        bad.append('A %s: no 申请使用 → /apply button in the hero' % rel)
    for m in re.finditer(r'免费试用|登录就能|马上|现在就试|free trial|start now|try it now|sign in and', p, re.I):
        bad.append('A %s: says "%s" — access is limited (#4049)' % (rel, m.group(0)))
    # B
    head = p.split('</head>')[0]
    need = ['<html lang="%s">' % lang, '<title>ClaudeFleet', '<meta name="description" content="',
            '<link rel="canonical" href="__ORIGIN__%s">' % url,
            '<link rel="alternate" hreflang="zh-CN" href="__ORIGIN__/">',
            '<link rel="alternate" hreflang="en" href="__ORIGIN__/en/">',
            '<link rel="alternate" hreflang="x-default" href="__ORIGIN__/en/">',
            '<meta property="og:title"', '<meta property="og:description"', '<meta property="og:url" content="__ORIGIN__%s">' % url,
            '<meta property="og:image" content="__ORIGIN__/site/og/', '<meta property="og:image:width" content="1200">',
            '<meta property="og:image:height" content="630">', '<meta name="twitter:card" content="summary_large_image">',
            '<meta name="twitter:image" content="__ORIGIN__/site/og/', '<link rel="icon"', '<link rel="apple-touch-icon"']
    for n in need:
        if n not in head:
            bad.append('B %s: head lacks %s' % (rel, n))
    for u in re.findall(r'(?:href|content)="(https?://[^"]+)"', head):
        bad.append('B %s: an absolute address is written in: %s' % (rel, u))
    img = re.search(r'og:image" content="__ORIGIN__/site/([^"]+)"', head)
    if img:
        f = os.path.join(OUT, img.group(1))
        if not os.path.isfile(f):
            bad.append('B %s: share card %s not built' % (rel, img.group(1)))
        else:
            w, h = struct.unpack('>II', open(f, 'rb').read()[16:24])
            if (w, h) != (1200, 630):
                bad.append('B %s: share card is %dx%d, not 1200x630' % (rel, w, h))
    # C
    try:
        ld = json.loads(re.search(r'<script type="application/ld\+json">(.*?)</script>', p, flags=re.S).group(1))
    except Exception as e:
        bad.append('C %s: JSON-LD does not parse: %s' % (rel, e)); continue
    types = {g['@type']: g for g in ld.get('@graph', [])}
    for k in ('Organization', 'WebSite', 'SoftwareApplication', 'FAQPage'):
        if k not in types:
            bad.append('C %s: JSON-LD has no %s' % (rel, k))
    app = types.get('SoftwareApplication', {})
    if app.get('potentialAction', {}).get('target') != '__ORIGIN__/app/try' or app.get('offers', {}).get('price') != '0':
        bad.append('C %s: SoftwareApplication lacks the try action or the free offer' % rel)
    ldq = [(q['name'], q['acceptedAnswer']['text']) for q in types.get('FAQPage', {}).get('mainEntity', [])]
    vis = [(html.unescape(re.sub(r'<i[^>]*>.*?</i>', '', q)).strip(), html.unescape(a).strip())
           for q, a in re.findall(r'<details><summary>(.*?)</summary><p>(.*?)</p></details>', p, flags=re.S)]
    src = json.loads(subprocess.check_output([sys.executable, os.path.join(ROOT, 'bin', 'docs-faq.py'), 'json',
                                              '--lang', lang[:2], '--site']))['items']
    if not ldq or ldq != vis or vis != [(i['q'], i['a']) for i in src]:
        bad.append('C %s: FAQPage (%d) / visible FAQ (%d) / faq.md site list (%d) differ' % (rel, len(ldq), len(vis), len(src)))
    # H
    for u in re.findall(r'(?:href|src)="(/[^"]*)"', p):
        u = u.split('?')[0].split('#')[0]
        if u in ('/', '/en/', '/app', '/app/try', '/apply') or u.startswith(('/docs/', '/en/docs/')):
            continue
        f = {'/favicon.svg': 'logo.svg'}.get(u) or (u[len('/site/'):] if u.startswith('/site/') else u.lstrip('/'))
        if u not in ('/favicon.ico', '/favicon.svg', '/apple-touch-icon.png') and not u.startswith('/site/'):
            bad.append('H %s: links %s, which the site does not serve' % (rel, u))
        elif not os.path.isfile(os.path.join(OUT, f)):
            bad.append('H %s: %s is not in the build' % (rel, u))
b = json.load(open(os.path.join(OUT, 'build.json')))
if b.get('timed') is not False:
    bad.append('A build.json says timed with no drill: %s' % b)
for x in bad:
    print('FAIL ' + x)
if not bad:
    print('ok   A no seconds without a drill · B heads · C JSON-LD = visible FAQ = faq.md · H every local link is built')
sys.exit(1 if bad else 0)
PY

# D — a drill under 60 s
printf '{"date":"2026-10-10","runs":[{"total":44,"steps":{"login":7,"machine":5,"first":32}},{"total":46.2,"steps":{"login":8.1,"machine":6,"first":32.1}}]}\n' > "$T/fast.json"
if out="$("$BUILD" --out "$T/d" --drill "$T/fast.json" --now "$NOW" 2>&1)"; then
  miss=""
  for s in '<em>60 秒</em>' '>8 秒<' '>6 秒<' '>32 秒<' '00:46' '2026-10-10' '立即体验'; do
    grep -qF "$s" "$T/d/index.html" || miss="$miss $s"
  done
  for s in '<em>60 seconds</em>' '>8 s<' 'Try it<' 'slowest of 2 runs'; do
    grep -qF "$s" "$T/d/en/index.html" || miss="$miss $s"
  done
  [ -z "$miss" ] && st_ok_all "D a drill of 46 s: 60 秒, the steps 8/6/32, 00:46, its date" || bad "D missing:$miss"
else bad "D build failed: $out"; fi

# T — fleet.trial off (issue #4269): apply/index.html + apply/en/index.html, served
#     in place of the pages while the trial is off, carry no trial at all — no
#     /app/try, no 立即体验 / 试用 / Try it / trial / 15 分钟 in what a reader or
#     a crawler is told, no drill seconds (they time the trial), every CTA and
#     the JSON-LD's UseAction → /apply — while the trial pages keep theirs; the
#     apply/ llms files say no trial in their summaries
python3 - "$T/d" <<'PY' || fail=1
import html, json, os, re, sys
OUT = sys.argv[1]
bad = []
def told(p):
    ld = ''.join(re.findall(r'<script type="application/ld\+json">(.*?)</script>', p, flags=re.S))
    metas = ' '.join(re.findall(r'<meta [^>]*content="([^"]*)"', p))
    title = ''.join(re.findall(r'<title>(.*?)</title>', p, flags=re.S))
    body = re.sub(r'<(script|style)[^>]*>.*?</\1>', ' ', p, flags=re.S)
    return html.unescape(' '.join([title, metas, ld, re.sub(r'<[^>]+>', ' ', body)]))
TRIAL = re.compile(r'立即体验|试用|先试|Try it|\btrial\b|15\s*(分钟|minutes)|\d+\s*(秒|seconds?\b)|\b\d\d:\d\d\b', re.I)
for rel, applyw in (('index.html', '申请使用'), ('en/index.html', 'Apply for access')):
    f = os.path.join(OUT, 'apply', rel)
    if not os.path.isfile(f):
        bad.append('T apply/%s not built' % rel); continue
    p = open(f, encoding='utf-8').read()
    t = told(p)
    for m in TRIAL.finditer(t):
        bad.append('T apply/%s says "%s"' % (rel, t[max(0, m.start() - 15):m.end() + 5].strip()))
    if '/app/try' in p or '<!--trial' in p or '<!--/trial' in p:
        bad.append('T apply/%s still links /app/try or keeps a trial marker' % rel)
    if p.count('href="/apply"') < 3 or applyw not in t:
        bad.append('T apply/%s: the nav, hero and end CTAs are not %s → /apply' % (rel, applyw))
    ld = json.loads(re.search(r'<script type="application/ld\+json">(.*?)</script>', p, flags=re.S).group(1))
    app = [g for g in ld['@graph'] if g['@type'] == 'SoftwareApplication'][0]
    if app['potentialAction']['target'] != '__ORIGIN__/apply':
        bad.append('T apply/%s: UseAction → %s' % (rel, app['potentialAction']['target']))
    if '/app/try' not in open(os.path.join(OUT, rel), encoding='utf-8').read():
        bad.append('T %s (the trial page) lost its 立即体验 → /app/try' % rel)
for name in ('llms.txt', 'llms-zh.txt', 'llms-full.txt'):
    f = os.path.join(OUT, 'apply', name)
    if not os.path.isfile(f):
        bad.append('T apply/%s not built' % name); continue
    head = '\n'.join(l for l in open(f, encoding='utf-8') if l.startswith('> ') or 'ClaudeFleet' in l[:40])
    if re.search(r'试 ?15|15 minutes|试用', head):
        bad.append('T apply/%s: its summary still offers the trial' % name)
for x in bad:
    print('FAIL ' + x)
if not bad:
    print('ok   T trial off: apply/ pages and llms files offer only 申请使用 → /apply, no seconds; the trial pages keep theirs')
sys.exit(1 if bad else 0)
PY

# S — the hero speaks of a service (#3940): no GitHub / 开源 / open source / MIT in
#     the header, the first section or the meta description; the footer keeps
#     the 开源 / 自托管 block with the GitHub link; the app is a BusinessApplication
if [ -f "$T/d/index.html" ]; then
  if out="$(python3 - "$T/d/index.html" "$T/d/en/index.html" <<'PY'
import re, sys
bad = []
for f in sys.argv[1:]:
    s = open(f, encoding='utf-8').read()
    top = (re.search(r'<header.*?</header>', s, re.S).group(0) + re.search(r'<section.*?</section>', s, re.S).group(0)
           + re.search(r'<meta name="description"[^>]*>', s).group(0))
    hits = re.findall(r'github|开源|open source|\bMIT\b', top, re.I)
    if hits:
        bad.append('%s: hero / nav / description say %s' % (f, hits))
    foot = re.search(r'<footer.*?</footer>', s, re.S).group(0)
    if 'class="oss"' not in foot or 'https://github.com/verkyyi/claude-fleet' not in foot:
        bad.append('%s: footer lost the open source / self-host block' % f)
    if '"applicationCategory":"BusinessApplication"' not in s:
        bad.append('%s: applicationCategory is not BusinessApplication' % f)
    if 'id="price"' not in s:
        bad.append('%s: no #price section' % f)
print('; '.join(bad))
sys.exit(1 if bad else 0)
PY
)"; then st_ok_all "S the hero is a service: no GitHub / 开源 up top, the footer keeps 开源 / 自托管"
  else bad "S $out"; fi
else bad "S no built page from D"; fi

# K — signed in, the nav says 进入控制台 · 退出 (#3798): both buttons are in the
#     page (hidden), the 退出 form posts to /logout with to=site / site-en, and
#     the script asks /v1/me who is looking
if [ -f "$T/d/index.html" ]; then
  miss=""
  for s in 'id="to-app" hidden>进入控制台<' 'action="/logout" hidden><input type="hidden" name="to" value="site">' '>退出</button>' "fetch('/v1/me'" 'data-out>登录<'; do
    grep -qF "$s" "$T/d/index.html" || miss="$miss [$s]"
  done
  for s in '>Open console<' 'name="to" value="site-en">' '>Sign out</button>'; do
    grep -qF "$s" "$T/d/en/index.html" || miss="$miss [$s]"
  done
  [ -z "$miss" ] && st_ok_all "K signed in: 进入控制台 · 退出, back to the site" || bad "K missing:$miss"
else bad "K no built page from D"; fi

# E — a drill over 60 s
printf '{"date":"2026-10-10","runs":[{"total":131,"steps":{"login":9,"machine":90,"first":32}}]}\n' > "$T/slow.json"
if out="$("$BUILD" --out "$T/e" --drill "$T/slow.json" --now "$NOW" 2>&1)"; then
  if grep -qE '60 秒|60 seconds' "$T/e/index.html" "$T/e/en/index.html"; then bad "E a 131 s drill still says 60"
  elif ! grep -qF '约 2 分钟' "$T/e/index.html" || ! grep -qF 'about 2 minutes' "$T/e/en/index.html"; then bad "E the measured time is not on the page"
  elif ! printf '%s\n' "$out" | grep -q '^RED: '; then bad "E no RED: line: $out"
  else st_ok_all "E a 131 s drill: 约 2 分钟 in place of 60 秒, RED"; fi
else bad "E build failed: $out"; fi

# F — a stale drill
printf '{"date":"2026-09-01","runs":[{"total":40,"steps":{"login":8,"machine":6,"first":26}}]}\n' > "$T/old.json"
if out="$("$BUILD" --out "$T/f" --drill "$T/old.json" --now "$NOW" 2>&1)"; then
  if grep -qE '[0-9]+ 秒|[0-9]+ seconds|[0-9]+ s<' "$T/f/index.html" "$T/f/en/index.html"; then bad "F a 41-day-old drill still shows seconds"
  elif ! printf '%s\n' "$out" | grep -q '^RED: .*days old'; then bad "F no RED: line: $out"
  else st_ok_all "F a 41-day-old drill: no seconds, RED"; fi
else bad "F build failed: $out"; fi

# G — a string claiming seconds no drill measured
mkdir -p "$T/site" && cp -RL "$ROOT/site/." "$T/site/"   # -L: under the gate's shadow root site/ is a link
python3 - "$T/site/strings.zh.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p, encoding='utf-8'))
d['fine'] = '免费试用 · 开源 MIT · 60 秒上手'
json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False)
PY
out="$("$BUILD" --site "$T/site" --out "$T/g" --drill "$T/none.json" --now "$NOW" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q 'not a drill result'; then st_ok_all "G an unmeasured 「60 秒上手」 is refused"
else bad "G the build took an unmeasured number of seconds (rc $rc): $out"; fi
[ ! -e "$T/g/index.html" ] || bad "G a refused build still wrote its pages"

# K — the fonts are cut to the pages' characters (issue #3799): every face the
# page names is a built file, and a new character the cut lacks fails the build
missing="$(grep -o 'url(/site/fonts/[^)]*)' "$T/a/index.html" | sed 's#url(/site/##; s#)$##' | sort -u |
  while read -r f; do [ -f "$T/a/$f" ] || echo "$f"; done)"
[ -z "$missing" ] && st_ok_all "K every @font-face file is built" || bad "K a face names a missing file: $missing"
mkdir -p "$T/ksite" && cp -RL "$ROOT/site/." "$T/ksite/"
python3 - "$T/ksite/strings.en.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p, encoding='utf-8'))
d['fine'] = d['fine'] + ' · café'
json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False)
PY
out="$("$BUILD" --site "$T/ksite" --out "$T/k" --drill "$T/none.json" --now "$NOW" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q 'the fonts lack U+00E9'; then st_ok_all "K a character the font cut lacks (é) fails the build"
else bad "K the build took a character its fonts lack (rc $rc): $out"; fi

# J — robots.txt · sitemap.xml · llms.txt · llms-zh.txt · llms-full.txt
"$ROOT/bin/docs-build.sh" --out "$T/docs" >/dev/null 2>"$T/docs.err" || bad "J docs-build failed: $(cat "$T/docs.err")"
mkdir -p "$T/jdocs" && cp -RL "$ROOT/docs/public/." "$T/jdocs/"
printf '# 新加的一篇\n\n这一篇只为自测而加。\n' > "$T/jdocs/zh/added-for-test.md"
"$BUILD" --docs "$T/jdocs" --out "$T/j" --drill "$T/none.json" --now "$NOW" >/dev/null 2>"$T/j.err" || bad "J build with an added doc failed: $(cat "$T/j.err")"
"$ROOT/bin/docs-build.sh" --src "$T/jdocs" --out "$T/jdocsout" >/dev/null 2>&1 || bad "J docs-build of the added doc failed"
python3 - "$T/a" "$T/docs" "$T/j" "$T/jdocsout" <<'PY' || fail=1
import os, re, sys
import xml.etree.ElementTree as ET
bad = []
O = '__ORIGIN__'
CRAWL = ('robots.txt', 'sitemap.xml', 'llms.txt', 'llms-zh.txt', 'llms-full.txt')

def served(site, docs, u):
    """The file the hub answers u from (site_serve.go), or None; 'external' off the hub."""
    if not u.startswith(O):
        return 'external'
    p = u[len(O):]
    if p in ('/', '/en/'):
        f = os.path.join(site, {'/': 'index.html', '/en/': 'en/index.html'}[p])
    elif p.lstrip('/') in CRAWL:
        f = os.path.join(site, p.lstrip('/'))
    else:
        f = None
        for pre, lang in (('/en/docs/', 'en'), ('/docs/', 'zh')):
            if p.startswith(pre):
                rest = p[len(pre):]
                name = (rest + 'index.html' if rest == '' or rest.endswith('/')
                        else rest if rest.endswith('.md') else rest + '.html')
                f = os.path.join(docs, lang, name)
                break
    return f if f and os.path.isfile(f) else None

def doc_url(l, p):
    b = '/docs/' if l == 'zh' else '/en/docs/'
    return O + b + (p[:-len('index')] if p == 'index' or p.endswith('/index') else p)

def check(site, docs, tag):
    pages = [l.rstrip('\n').split('\t') for l in open(os.path.join(docs, 'pages.tsv'), encoding='utf-8') if l.strip()]
    real = [(l, p, t) for l, p, t, st in pages if st == 'page']
    pairs = {(l, p) for l, p, _ in real}
    # robots
    rb = open(os.path.join(site, 'robots.txt'), encoding='utf-8').read().splitlines()
    for need in ('User-agent: *', 'User-agent: GPTBot', 'User-agent: ClaudeBot', 'Allow: /', 'Allow: /docs/',
                 'Allow: /en/docs/', 'Disallow: /app/', 'Disallow: /v1/', 'Disallow: /mcp', 'Disallow: /connect',
                 'Disallow: /fleet/', 'Disallow: /embed/', 'Disallow: /chat/', 'Sitemap: %s/sitemap.xml' % O):
        if need not in rb:
            bad.append('J%s robots.txt lacks %r' % (tag, need))
    for l in rb:
        if l.startswith('Disallow:') and l.split(':', 1)[1].strip() in ('/', '/en/', '/docs/', '/en/docs/', '/site/'):
            bad.append('J%s robots.txt closes a public path: %s' % (tag, l))
    # sitemap
    ns = {'s': 'http://www.sitemaps.org/schemas/sitemap/0.9', 'x': 'http://www.w3.org/1999/xhtml'}
    try:
        root = ET.parse(os.path.join(site, 'sitemap.xml')).getroot()
    except Exception as e:
        bad.append('J%s sitemap.xml does not parse: %s' % (tag, e))
        return None
    locs = {}
    for u in root.findall('s:url', ns):
        loc = u.find('s:loc', ns).text
        lm = u.find('s:lastmod', ns)
        if lm is not None and not re.match(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d([+-]\d\d:\d\d|Z)$', lm.text or ''):
            bad.append('J%s sitemap %s: lastmod %r is not W3C time' % (tag, loc, lm.text))
        locs[loc] = {a.get('hreflang'): a.get('href') for a in u.findall('x:link', ns)}
    want = {O + '/', O + '/en/'} | {doc_url(l, p) for l, p, _ in real}
    if set(locs) != want:
        bad.append('J%s sitemap differs from the built docs: missing %s, extra %s'
                   % (tag, sorted(want - set(locs)), sorted(set(locs) - want)))
    for loc in locs:
        if not served(site, docs, loc):
            bad.append('J%s sitemap lists %s, which the hub would not answer 200' % (tag, loc))
    if locs.get(O + '/', {}).get('en') != O + '/en/':
        bad.append('J%s sitemap: / has no en alternate' % tag)
    for l, p, _ in real:
        if l == 'en' and ('zh', p) in pairs and locs.get(doc_url('en', p), {}).get('zh-CN') != doc_url('zh', p):
            bad.append('J%s sitemap: %s lacks its zh-CN pair' % (tag, doc_url('en', p)))
    # llms.txt · llms-zh.txt (llmstxt.org: H1, > summary, ## sections of link lists)
    ndocs = len({p for _, p, _, _ in pages})
    for name in ('llms.txt', 'llms-zh.txt'):
        t = open(os.path.join(site, name), encoding='utf-8').read().splitlines()
        if not t or not re.match(r'# \S', t[0]):
            bad.append('J%s %s: first line is not an H1' % (tag, name))
        if not any(l.startswith('> ') for l in t[1:4]):
            bad.append('J%s %s: no > summary right under the H1' % (tag, name))
        secs = [i for i, l in enumerate(t) if l.startswith('## ')]
        if not secs or any(l.startswith('# ') for l in t[1:]):
            bad.append('J%s %s: no ## sections, or a second H1' % (tag, name))
        links = []
        for l in t[secs[0] if secs else len(t):]:
            if l.startswith('## ') or not l.strip():
                continue
            m = re.match(r'- \[([^\]]+)\]\(([^)\s]+)\)(: .+)?$', l)
            if m:
                links.append(m.group(2))
            else:
                bad.append('J%s %s: not a link line: %r' % (tag, name, l))
        for u in links:
            if not served(site, docs, u):
                bad.append('J%s %s links %s, which the hub would not answer' % (tag, name, u))
        if len([u for u in links if u.endswith('.md')]) != ndocs:
            bad.append('J%s %s: %d doc links for %d docs' % (tag, name, len([u for u in links if u.endswith('.md')]), ndocs))
    # llms-full
    full = open(os.path.join(site, 'llms-full.txt'), encoding='utf-8').read()
    for l, p, title in real:
        if '\n# %s\n' % title not in full:
            bad.append('J%s llms-full.txt lacks %s/%s 「%s」' % (tag, l, p, title))
    return locs

check(sys.argv[1], sys.argv[2], '')
locs = check(sys.argv[3], sys.argv[4], '(added)')
if locs is not None and O + '/docs/added-for-test' not in locs:
    bad.append('J an added doc is not in the sitemap')
if '新加的一篇' not in open(os.path.join(sys.argv[3], 'llms-zh.txt'), encoding='utf-8').read() \
        or '# 新加的一篇' not in open(os.path.join(sys.argv[3], 'llms-full.txt'), encoding='utf-8').read():
    bad.append('J an added doc is not in llms-zh.txt / llms-full.txt')
for x in bad:
    print('FAIL ' + x)
if not bad:
    print('ok   J robots closes /app /v1 · sitemap = every built doc, each answered · llms.txt shaped · llms-full has every title · an added doc follows')
sys.exit(1 if bad else 0)
PY

# I — no internal names in what the hub serves (the rule table, its #@keep words kept)
if [ -f "$ROOT/conf/oss-scan.rules" ]; then
  hits=$(python3 - "$ROOT/conf/oss-scan.rules" "$T/a/index.html" "$T/a/en/index.html" "$T/d/index.html" \
    "$T/a/robots.txt" "$T/a/sitemap.xml" "$T/a/llms.txt" "$T/a/llms-zh.txt" "$T/a/llms-full.txt" <<'PY2'
import re, sys
rules, keep = [], []
for l in open(sys.argv[1], encoding='utf-8'):
    l = l.rstrip('\n')
    if l.startswith('#@keep\t'):
        keep.append(l.split('\t', 1)[1])
    elif l and not l.startswith('#') and l.count('\t') >= 2:
        rid, rx = l.split('\t')[:2]
        rules.append((rid, re.compile(rx)))
for f in sys.argv[2:]:
    for n, line in enumerate(open(f, encoding='utf-8'), 1):
        for k in keep:
            line = line.replace(k, ' ')
        for rid, rx in rules:
            if rx.search(line):
                print('%s:%d %s' % (f.rsplit('/', 2)[-2] + '/' + f.rsplit('/', 1)[-1], n, rid))
PY2
)
  [ -z "$hits" ] && st_ok_all "I no internal name or address in the built pages" || bad "I internal names: $(printf '%s' "$hits" | tr '\n' ' ')"
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
