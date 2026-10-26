#!/bin/bash
# site-build-selftest.sh — the public website build (issue #3584, EPIC #3569 C14).
#
# Builds site/ with bin/site-build.sh into a sandbox and reads the result:
#
#   A  no drill result: both pages build, and neither says a number of seconds
#      anywhere — the scan card reads 「微信扫码，立即试用」 / "Scan with WeChat to
#      try it" with one line under its code and nothing else (C2: no 立即体验 /
#      申请使用 / 其他登录方式 beside it), and neither page says anyone can start
#      right away (免费试用 · 登录就能 · 马上 · 现在就试 / Free trial · Start now · Try
#      it now · sign in and — issue #4049; the one 马上 is 「试用马上开通」 once
#      they follow, which MRGB makes true)
#   B  each page's head: <html lang>, title, description, canonical, hreflang
#      zh-CN · en · x-default (→ /en/), og:* and twitter:* with a 1200×630 card
#      that exists, every absolute URL on the __ORIGIN__ placeholder
#   C  the JSON-LD parses: @graph has Organization · WebSite · SoftwareApplication
#      (its UseAction → /app/try), and no FAQPage — the front page carries no FAQ (T872)
#   D  a drill whose slowest run is ≤ 60 s: build.json says timed, and the page
#      still shows no stopwatch — the scan card carries none since C2
#   E  a drill over 60 s: a RED: line
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
#   L  the legal pages (T883, EPIC WACK C2): /terms /privacy /en/terms /en/privacy
#      built from site/legal/, each in its language, final (no draft line) with its effective date, its
#      twin as hreflang, and the front page's footer; both front pages' footers
#      carry 用户协议 · 隐私政策 (Terms · Privacy) and no company name or ICP
#      number (ZCKT) — every footer key in both string tables; a
#      legal source missing in one language fails the build
#   X  the sandbox edition (task PNWW): sandbox/index.html + sandbox/zh/index.html,
#      the Claude Code sandbox runtime — built in the theme, GitHub sign-in and
#      Request access, no WeChat / QR / mainland / trial, nothing from elsewhere
#   T  fleet.trial off (issue #4269): the apply/ pages and llms files offer no
#      trial — the scan card is 申请使用 → /apply (T794), no drill seconds — and
#      the trial pages keep theirs
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

node "$ROOT/bin/site-qr-selftest.cjs" "$T/a" || fail=1

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

for lang, rel, url, tryw in (('zh-CN', 'index.html', '/', '微信扫码，立即试用'), ('en', 'en/index.html', '/en/', 'Scan with WeChat to try it')):
    p = open(os.path.join(OUT, rel), encoding='utf-8').read()
    t = text(p)
    # A — the trial's length (15 分钟 / 15 minutes, #4049) is a rule, not a timing
    for m in SECS.finditer(re.sub(r'15\s*(分钟|minutes)', ' ', t)):
        bad.append('A %s: says "%s" with no drill' % (rel, t[max(0, m.start() - 15):m.end() + 5].strip()))
    if tryw not in t:
        bad.append('A %s: the scan card does not say "%s"' % (rel, tryw))
    card = p.split('<div class="j j-scan">')[1].split('<div class="j j-wait">')[0]
    if card.count('<p class="lead">') != 1 or re.search(r'class="(scan|flow|alt|timed|other)"', card):
        bad.append('A %s: the scan card is not title + code + one line (C2)' % rel)
    for m in re.finditer(r'免费试用|登录就能|马上(?!开通)|现在就试|free trial|start now|try it now|sign in and', p, re.I):
        bad.append('A %s: says "%s" — access is limited (#4049)' % (rel, m.group(0)))
    # B
    head = p.split('</head>')[0]
    need = ['<html lang="%s">' % lang, '<title>tokenman', '<meta name="description" content="',
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
    for k in ('Organization', 'WebSite', 'SoftwareApplication'):
        if k not in types:
            bad.append('C %s: JSON-LD has no %s' % (rel, k))
    if 'FAQPage' in types or '<details' in p:
        bad.append('C %s: the front page still carries an FAQ (T872)' % rel)
    app = types.get('SoftwareApplication', {})
    if app.get('potentialAction', {}).get('target') != '__ORIGIN__/app/try' or app.get('offers', {}).get('price') != '0':
        bad.append('C %s: SoftwareApplication lacks the try action or the free offer' % rel)
    # H
    for u in re.findall(r'(?:href|src)="(/[^"]*)"', p):
        u = u.split('?')[0].split('#')[0]
        if u in ('/', '/en/', '/app', '/app/try', '/apply', '/status') or u.startswith(('/docs/', '/en/docs/')):
            continue
        if u in ('/terms', '/privacy', '/en/terms', '/en/privacy'):   # the legal pages (T883)
            if not os.path.isfile(os.path.join(OUT, u.lstrip('/'), 'index.html')):
                bad.append('H %s: %s is not in the build' % (rel, u))
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
    print('ok   A no seconds without a drill · B heads · C JSON-LD, no FAQ · H every local link is built')
sys.exit(1 if bad else 0)
PY

# D — a drill under 60 s
printf '{"date":"2026-10-10","runs":[{"total":44,"steps":{"login":7,"machine":5,"first":32}},{"total":46.2,"steps":{"login":8.1,"machine":6,"first":32.1}}]}\n' > "$T/fast.json"
if out="$("$BUILD" --out "$T/d" --drill "$T/fast.json" --now "$NOW" 2>&1)"; then
  if ! grep -q '"timed": true' "$T/d/build.json"; then bad "D build.json does not say timed: $(cat "$T/d/build.json")"
  elif grep -qE '60 秒|60 seconds|00:46|slowest of' "$T/d/index.html" "$T/d/en/index.html"; then bad "D the page still shows the stopwatch"
  else st_ok_all "D a drill of 46 s: recorded timed, no stopwatch on the page"; fi
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
for rel, applyw in (('index.html', '微信扫码申请'), ('en/index.html', 'to apply')):
    f = os.path.join(OUT, 'apply', rel)
    if not os.path.isfile(f):
        bad.append('T apply/%s not built' % rel); continue
    p = open(f, encoding='utf-8').read()
    t = told(p)
    for m in TRIAL.finditer(t):
        bad.append('T apply/%s says "%s"' % (rel, t[max(0, m.start() - 15):m.end() + 5].strip()))
    if '/app/try' in p or '<!--trial' in p or '<!--/trial' in p:
        bad.append('T apply/%s still links /app/try or keeps a trial marker' % rel)
    # The way in is the scan card (T794): its code is drawn for a sign-in that
    # lands on /apply, and WeChat's one tap posts to /apply.
    if 'data-p="login"' not in p or 'action="/apply"' not in p or applyw not in t:
        bad.append('T apply/%s: the scan card is not a %s → /apply' % (rel, applyw))
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
    head = '\n'.join(l for l in open(f, encoding='utf-8') if l.startswith('> ') or 'tokenman' in l[:40])
    if re.search(r'试 ?15|15 minutes|试用', head):
        bad.append('T apply/%s: its summary still offers the trial' % name)
for x in bad:
    print('FAIL ' + x)
if not bad:
    print('ok   T trial off: apply/ pages and llms files offer only 申请使用 → /apply, no seconds; the trial pages keep theirs')
sys.exit(1 if bad else 0)
PY

# S — the hero speaks of a service (#3940): no GitHub / 开源 / open source / MIT in
#     the header, the first section or the meta description; the app is a
#     BusinessApplication. The page keeps only what it must (T872): the nav is
#     文档 · 登录, the footer GitHub · status · the language · © (+ the legal line, leg L; T924 moved the
#     switch down) — one language switch, one
#     docs link, the GitHub link only in the footer, no 能交给它 / 价格 / FAQ /
#     安全 / trademark line, and the share words name no price or trial length.
#     The replay is the web app (C3): no iTerm2 / ⌘P, its address bar __HOST__/app,
#     and one developer line under it to /docs/member/connect
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
    if '<a class="gh" href="https://github.com/verkyyi/claude-fleet">' not in foot:
        bad.append('%s: footer has no GitHub link' % f)
    if '"applicationCategory":"BusinessApplication"' not in s:
        bad.append('%s: applicationCategory is not BusinessApplication' % f)
    body = re.sub(r'<(script|style)[^>]*>.*?</\1>', ' ', s, flags=re.S)
    if body.count('https://github.com/verkyyi/claude-fleet"') != 1:
        bad.append('%s: the GitHub link is not in the footer alone' % f)
    nav = re.search(r'<div class="nav-r">.*?</div>', body, re.S).group(0)
    links = re.findall(r'<a [^>]*>', re.sub(r'<aside.*?</aside>', ' ', body, flags=re.S))
    outside = [a for a in links if 'class="brand"' not in a and 'class="skip"' not in a
               and 'id="to-app"' not in a
               and not re.search(r'href="(/en)?/(terms|privacy)"|beian\.miit', a)]   # the footer legal line, T883 leg L
    # the replay's one line for a developer (C3): the terminal is a doc, once
    dev = re.findall(r'<p class="devline">[^<]*<a href="(/(?:en/)?docs/member/connect)">', body)
    if len(dev) != 1:
        bad.append('%s: the developer line under the replay is not once, to /docs/member/connect: %s' % (f, dev))
    outside = [a for a in outside if not (dev and a == '<a href="%s">' % dev[0])]
    # the replay is the web app (C3): no terminal window, no ⌘P, its address the hub's
    for w in re.findall(r'iTerm2|⌘P|class="topline"|id="panel"', s):
        bad.append('%s: the replay still shows %s' % (f, w))
    if '__HOST__/app</span>' not in s:
        bad.append('%s: the replay address bar is not __HOST__/app' % f)
    if 'href="/status"' not in foot:
        bad.append('%s: footer has no public status link' % f)
    if len(outside) != 5:
        bad.append('%s: %d entries outside the scan card, not 5 (文档 · 登录 · language · GitHub · status): %s'
                   % (f, len(outside), outside))
    if body.count('data-set=') != 1 or 'data-set=' not in foot or 'data-set=' in nav:
        bad.append('%s: the language switch is not once, in the footer' % f)
    if body.count('class="docs"') != 1 or body.count('href="/docs/"') + body.count('href="/en/docs/"') != 1:
        bad.append('%s: the docs link is not once, in the nav' % f)
    if '.nav-r .docs{display:none}' in s:
        bad.append('%s: the phone hides the docs link' % f)
    for w in re.findall(r'能交给它|Hand it|价格|Pricing|id="price"|常见问题|class="faq"|/docs/security|'
                        r'不是 Anthropic 官方产品|Not an Anthropic product', s):
        bad.append('%s: still says %s' % (f, w))
    for m in re.findall(r'<meta (?:name="description"|property="og:description"|name="twitter:description")[^>]*>', s):
        if re.search(r'15|价格|price|看板|dashboard', m, re.I):
            bad.append('%s: share words say %s' % (f, m))
print('; '.join(bad))
sys.exit(1 if bad else 0)
PY
)"; then st_ok_all "S the hero is a service; the page keeps 文档 · 登录 · GitHub · status · the footer's one language switch"
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
  elif ! printf '%s\n' "$out" | grep -q '^RED: '; then bad "E no RED: line: $out"
  else st_ok_all "E a 131 s drill: RED"; fi
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

# L — the legal pages and the footer (T883)
python3 - "$T/a" "$ROOT" <<'PY' || fail=1
import json, os, re, sys
OUT, ROOT = sys.argv[1], sys.argv[2]
bad = []
S = {l: json.load(open(os.path.join(ROOT, 'site', 'strings.%s.json' % l), encoding='utf-8')) for l in ('zh', 'en')}
for k in ('terms', 'privacy', 'terms_path', 'privacy_path', 'legal_home', 'terms_desc', 'privacy_desc'):
    for l in S:
        if not S[l].get(k):
            bad.append('L strings.%s.json: no %s' % (l, k))
for l, home in (('zh', 'index.html'), ('en', 'en/index.html')):
    p = open(os.path.join(OUT, home), encoding='utf-8').read()
    foot = re.search(r'<footer>.*?</footer>', p, re.S)
    foot = foot.group(0) if foot else ''
    for want in ('href="%s">%s</a>' % (S[l]['terms_path'], S[l]['terms']),
                 'href="%s">%s</a>' % (S[l]['privacy_path'], S[l]['privacy'])):
        if want not in foot:
            bad.append('L %s footer: no %s' % (home, want))
    # ZCKT: the footer carries no company name and no ICP number (the operator's call)
    for gone in ('广州二四网络科技有限公司', 'ICP备', 'beian.miit.gov.cn'):
        if gone in foot:
            bad.append('L %s footer: still carries %s' % (home, gone))
    for doc in ('terms', 'privacy'):
        path = S[l][doc + '_path']
        f = os.path.join(OUT, path.lstrip('/'), 'index.html')
        if not os.path.isfile(f):
            bad.append('L %s is not built' % path)
            continue
        q = open(f, encoding='utf-8').read()
        twin = S['en' if l == 'zh' else 'zh'][doc + '_path']
        need = ['<html lang="%s">' % S[l]['lang'], '<link rel="canonical" href="__ORIGIN__%s">' % path,
                'href="__ORIGIN__%s"' % twin, '<h1>', '生效日期' if l == 'zh' else 'Effective:',
                'href="%s" aria-current="page"' % path]
        for w in need:
            if w not in q:
                bad.append('L %s: lacks %s' % (path, w))
        if '{{' in q:
            bad.append('L %s: an unfilled slot' % path)
        if ('草稿' if l == 'zh' else 'Draft') in q:
            bad.append('L %s: still marked as a draft' % path)
        for u in re.findall(r'href="(/[^"]*)"', q):
            u = u.split('#')[0]
            if u in ('/', '/en/', '/status') or u.startswith(('/favicon', '/apple-touch')):
                continue
            if not os.path.isfile(os.path.join(OUT, u.lstrip('/'), 'index.html')):
                bad.append('L %s: links %s, which is not built' % (path, u))
for x in bad:
    print('FAIL ' + x)
if not bad:
    print('ok   L /terms /privacy /en/terms /en/privacy built, final, twins · footers carry both links, no company or ICP number')
sys.exit(1 if bad else 0)
PY
mkdir -p "${T:?}/lsite"; cp -R "$ROOT/site/." "${T:?}/lsite/"; rm -f "${T:?}/lsite/legal/privacy.en.md"
if out="$("$BUILD" --site "$T/lsite" --out "$T/l" --drill "$T/none.json" --now "$NOW" 2>&1)"; then
  bad "L a missing site/legal/privacy.en.md still built"
elif printf '%s' "$out" | grep -q 'privacy.en.md is missing'; then st_ok_all "L a legal page missing in one language fails the build"
else bad "L missing legal page: $out"; fi

# X — the sandbox edition (task PNWW): sandbox/index.html (en, at /) and
#     sandbox/zh/index.html (中文, at /zh/) are built in the theme, every slot
#     filled; the way in is Sign in with GitHub → /auth/github/start and Request
#     access → /apply; no WeChat, QR code, mainland positioning or trial; nothing
#     loaded from elsewhere; every local link a path the hub answers — and a
#     sandbox string saying WeChat, or a missing language, fails the build
python3 - "$T/a" <<'PY' || fail=1
import os, re, sys
OUT = sys.argv[1]
bad = []
pages = (('en', 'sandbox/index.html', '/', '/zh/'), ('zh-CN', 'sandbox/zh/index.html', '/zh/', '/'))
for lang, rel, path, other in pages:
    f = os.path.join(OUT, rel)
    if not os.path.isfile(f):
        bad.append('X %s was not built' % rel); continue
    p = open(f, encoding='utf-8').read()
    if '<html lang="%s">' % lang not in p:
        bad.append('X %s: not <html lang="%s">' % (rel, lang))
    if '<link rel="canonical" href="__ORIGIN__%s">' % path not in p:
        bad.append('X %s: canonical is not __ORIGIN__%s' % (rel, path))
    if re.search(r'\{\{|\{brand\}|/\*\{\{', p):
        bad.append('X %s: an unfilled slot' % rel)
    if '--fleet-bg:' not in p or '<symbol id="wm"' not in p:
        bad.append('X %s: the theme (tokens, wordmark) is not inlined' % rel)
    if 'href="/auth/github/start"' not in p or 'href="/apply"' not in p:
        bad.append('X %s: no Sign in with GitHub (/auth/github/start) and Request access (/apply)' % rel)
    m = re.search(r'wechat|微信|weixin|mainland|china|大陆|中国|二四网络|qrcode|\bqr\b|扫码|/app/try|/auth/wechat|试用|trial', p, re.I)
    if m:
        bad.append('X %s: says %r — the sandbox page is not the China one' % (rel, m.group(0)))
    if re.search(r'''(?:\bsrc|srcset)\s*=\s*["']?(?:https?:)?//|url\(\s*["']?(?:https?:)?//|@import''', p):
        bad.append('X %s: loads something from elsewhere' % rel)
    if 'href="%s"' % other not in p:
        bad.append('X %s: no switch to the other language (%s)' % (rel, other))
    for h in re.findall(r'(?:href|src)="(/[^"#]*)"', p):
        h = h.split('?')[0]
        served = (h in ('/', '/zh/', '/app', '/apply', '/status', '/auth/github/start', '/favicon.ico', '/favicon.svg', '/apple-touch-icon.png',
                        '/terms', '/privacy', '/en/terms', '/en/privacy', '/docs/', '/en/docs/')
                  or (h.startswith('/site/') and os.path.isfile(os.path.join(OUT, h[len('/site/'):]))))
        if not served:
            bad.append('X %s: links %s, which the hub does not answer' % (rel, h))
for x in bad:
    print('FAIL ' + x)
if not bad:
    print('ok   X sandbox edition: / (en) and /zh/ built in the theme, GitHub sign-in + Request access, no WeChat / QR / trial, nothing from elsewhere')
sys.exit(1 if bad else 0)
PY
# Unified portal is a separate opt-in output; off keeps the sandbox pages above.
python3 - "$T/a" <<'PYPORTAL' || fail=1
from pathlib import Path
import sys
root = Path(sys.argv[1])
for suffix in ('sandbox/index.html', 'sandbox/zh/index.html'):
    page = (root / 'portal' / suffix).read_text()
    assert 'href="/app/signin"' in page
    assert 'href="/apply"' in page and 'href="/app/try"' in page
    assert 'href="/?lang=' in page
    assert 'href="/app/try"' not in (root / 'apply/portal' / suffix).read_text()
print('ok   portal: shared login, apply/trial and remembered language; trial-off omits trial')
PYPORTAL
mkdir -p "${T:?}/xsite" && cp -RL "$ROOT/site/." "${T:?}/xsite/"
python3 - "$T/xsite/sandbox/strings.en.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p, encoding='utf-8'))
d['fine'] = 'Scan with WeChat to apply'
json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False)
PY
out="$("$BUILD" --site "$T/xsite" --out "$T/x" --drill "$T/none.json" --now "$NOW" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q 'sandbox en: says WeChat'; then st_ok_all "X a sandbox string saying WeChat fails the build"
else bad "X the sandbox build took WeChat (rc $rc): $out"; fi
mkdir -p "${T:?}/xsite2" && cp -RL "$ROOT/site/." "${T:?}/xsite2/" && rm -f "${T:?}/xsite2/sandbox/strings.zh.json"
out="$("$BUILD" --site "$T/xsite2" --out "$T/x2" --drill "$T/none.json" --now "$NOW" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q 'sandbox/strings.zh.json is missing'; then st_ok_all "X a sandbox language missing fails the build"
else bad "X the sandbox build went on without its 中文 strings (rc $rc): $out"; fi

# I — no internal names in what the hub serves (the rule table, its #@keep words kept)
if [ -f "$ROOT/conf/oss-scan.rules" ]; then
  hits=$(python3 - "$ROOT/conf/oss-scan.rules" "$T/a/index.html" "$T/a/en/index.html" "$T/d/index.html" \
    "$T/a/sandbox/index.html" "$T/a/sandbox/zh/index.html" "$T/a/terms/index.html" "$T/a/privacy/index.html" "$T/a/en/terms/index.html" "$T/a/en/privacy/index.html" \
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
