#!/bin/bash
# site-build-selftest.sh — the public website build (issue #3584, EPIC #3569 C14).
#
# Builds site/ with bin/site-build.sh into a sandbox and reads the result:
#
#   A  no drill result: both pages build, and neither says a number of seconds
#      anywhere — the try button reads 「免费试用」 / "Try it free"
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
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/bin/site-build.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/site-build-st.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
NOW=2026-10-12

# A — no drill
if out="$("$BUILD" --out "$T/a" --drill "$T/none.json" --now "$NOW" 2>&1)"; then ok "A build: $out"; else bad "A build failed: $out"; echo FAIL; exit 1; fi

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

for lang, rel, url, tryw in (('zh-CN', 'index.html', '/', '免费试用'), ('en', 'en/index.html', '/en/', 'Try it free')):
    p = open(os.path.join(OUT, rel), encoding='utf-8').read()
    t = text(p)
    # A
    for m in SECS.finditer(t):
        bad.append('A %s: says "%s" with no drill' % (rel, t[max(0, m.start() - 15):m.end() + 5].strip()))
    if tryw not in t:
        bad.append('A %s: no "%s" button' % (rel, tryw))
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
        if u in ('/', '/en/', '/app', '/app/try') or u.startswith(('/docs/', '/en/docs/')):
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
  for s in '<b>60 秒</b>' '<em>60 秒</em>' '>8 秒<' '>6 秒<' '>32 秒<' '00:46' '2026-10-10' '60 秒试用'; do
    grep -qF "$s" "$T/d/index.html" || miss="$miss $s"
  done
  for s in 'Working in 60 seconds.' '>8 s<' 'Try in 60 seconds' 'slowest of 2 runs'; do
    grep -qF "$s" "$T/d/en/index.html" || miss="$miss $s"
  done
  [ -z "$miss" ] && ok "D a drill of 46 s: 60 秒, the steps 8/6/32, 00:46, its date" || bad "D missing:$miss"
else bad "D build failed: $out"; fi

# E — a drill over 60 s
printf '{"date":"2026-10-10","runs":[{"total":131,"steps":{"login":9,"machine":90,"first":32}}]}\n' > "$T/slow.json"
if out="$("$BUILD" --out "$T/e" --drill "$T/slow.json" --now "$NOW" 2>&1)"; then
  if grep -qE '60 秒|60 seconds' "$T/e/index.html" "$T/e/en/index.html"; then bad "E a 131 s drill still says 60"
  elif ! grep -qF '约 2 分钟' "$T/e/index.html" || ! grep -qF 'about 2 minutes' "$T/e/en/index.html"; then bad "E the measured time is not on the page"
  elif ! printf '%s\n' "$out" | grep -q '^RED: '; then bad "E no RED: line: $out"
  else ok "E a 131 s drill: 约 2 分钟 in place of 60 秒, RED"; fi
else bad "E build failed: $out"; fi

# F — a stale drill
printf '{"date":"2026-09-01","runs":[{"total":40,"steps":{"login":8,"machine":6,"first":26}}]}\n' > "$T/old.json"
if out="$("$BUILD" --out "$T/f" --drill "$T/old.json" --now "$NOW" 2>&1)"; then
  if grep -qE '[0-9]+ 秒|[0-9]+ seconds|[0-9]+ s<' "$T/f/index.html" "$T/f/en/index.html"; then bad "F a 41-day-old drill still shows seconds"
  elif ! printf '%s\n' "$out" | grep -q '^RED: .*days old'; then bad "F no RED: line: $out"
  else ok "F a 41-day-old drill: no seconds, RED"; fi
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
if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q 'not a drill result'; then ok "G an unmeasured 「60 秒上手」 is refused"
else bad "G the build took an unmeasured number of seconds (rc $rc): $out"; fi
[ ! -e "$T/g/index.html" ] || bad "G a refused build still wrote its pages"

# I — no internal names in what the hub serves (the rule table, its #@keep words kept)
if [ -f "$ROOT/conf/oss-scan.rules" ]; then
  hits=$(python3 - "$ROOT/conf/oss-scan.rules" "$T/a/index.html" "$T/a/en/index.html" "$T/d/index.html" <<'PY2'
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
  [ -z "$hits" ] && ok "I no internal name or address in the built pages" || bad "I internal names: $(printf '%s' "$hits" | tr '\n' ' ')"
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
