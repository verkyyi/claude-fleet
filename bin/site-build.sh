#!/bin/bash
# site-build.sh — build the public website, 中文 at / and English at /en/
# (issue #3584, EPIC #3569 C14; the design is the site design v2, decided 2026-10-12).
#
#   site-build.sh                 site/ + docs/public FAQ → tokenledger/web/site/
#   site-build.sh --out <dir>     the same, into <dir> (the selftest's sandbox)
#   site-build.sh --drill <file>  the live drill's result (default site/drill.json)
#   site-build.sh --now <YYYY-MM-DD>   judge the drill's age against this day (tests)
#
# One template, one string table per language, nothing typed twice:
#
#   site/template.html            the page: {{key}} slots, <!--timed-->…<!--/timed-->
#   site/strings.{zh,en}.json     every word on the page, per language (C15's llms.txt
#                                 reads the same tables)
#   docs/public/<lang>/faq.md     the questions marked `<!-- faq: site -->`, through
#                                 bin/docs-faq.py — the visible FAQ and the FAQPage
#                                 JSON-LD are one list, word for word (check-html)
#   site/assets/                  logo, icons, share cards (bin/site-images.sh makes
#                                 the PNGs once), self-hosted Latin font subsets (OFL)
#
# Output (gitignored, built into the hub image by hub-deploy like the docs):
#
#   <out>/index.html  <out>/en/index.html     served at / and /en/
#   <out>/logo.svg  favicon.ico  apple-touch-icon.png  icon-{192,512}.png
#   <out>/og/cover-{zh,en}.png  <out>/fonts/*.woff2     served under /site/
#   <out>/build.json              what the build decided: timed or not, and why
#
# And the files for search engines and AI assistants (issue #3585, C15), served
# at the root (/robots.txt …, site_serve.go):
#
#   <out>/robots.txt      / /en/ /docs/ open, the console and the APIs (/app/ /v1/
#                         /mcp /connect /fleet/ /embed/ …) closed — the AI
#                         crawlers named, under the same rules (decided: let them in)
#   <out>/sitemap.xml     both front pages + every public doc, language pairs as
#                         xhtml:link, lastmod = the source's last git commit
#   <out>/llms.txt        English, llmstxt.org: H1 · > summary · what it is / is
#                         not / who for · ## lists of links to each doc's .md
#   <out>/llms-zh.txt     the same in 中文
#   <out>/llms-full.txt   every public doc's Markdown in one file
#
# They are read off the string tables (llms_* keys) and docs-build.sh's own
# output (pages.tsv + each page's .md, built into a scratch dir here), so a new
# doc in docs/public/ is in all of them on the next build — nothing is listed by
# hand. An en page docs-build marks `pending` (no English yet) is left out of the
# sitemap; llms.txt links its Chinese .md instead.
#
# Absolute URLs (canonical, hreflang, og:url, JSON-LD) are written with the
# placeholder __ORIGIN__; the hub puts its own public address there when it
# serves a page, so no hub's address is ever in the repo.
#
# The seconds rule (design v2 §03): a number of seconds on the page comes only
# from the live drill's result — never a target written as if measured.
#   no drill file / unreadable          → no seconds anywhere ("免费试用", "三步…")
#   drill older than 7 days             → the same, and a RED: line on stderr
#   slowest of the runs ≤ 60 s          → "60 秒" / "60 seconds", the steps' seconds,
#                                         the stopwatch and the drill's date
#   slowest of the runs > 60 s          → the measured time in place of "60 秒"
#                                         (e.g. "75 秒", "约 3 分钟"), and a RED: line
# The drill file: bin/site-drill.py writes it from a `fleet-onboard-drill.sh
# --hub prod --runs 3 --out <dir>` run (issue #3589, C19 — see its header):
#   {"date": "YYYY-MM-DD", "runs": [{"total": 46.2,
#     "steps": {"login": 8.1, "machine": 6.0, "first": 32.1},
#     "screens": {"login": "…", "machine": "…", "first": "…"}}, …]}
# The slowest run (by total) is the one shown — its seconds AND its three
# screens, which stand in the steps' pictures (<!--shot:k-->…<!--/shot--> in the
# template) in place of the design's mock: numbers and pictures from one run.
# A timed drill whose slowest run has no screens keeps the mock, with a RED:
# line. The build then checks its own output: every seconds-shaped number on
# either page is one the drill gave (a screen is the drill's own words).
#
# Exit: 0 built (RED: lines are warnings for the operator) · 1 a check failed ·
# 2 usage.
set -uo pipefail
real="$0"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
SITE="$REPO/site"
OUT="$REPO/tokenledger/web/site"
DOCS="$REPO/docs/public"
DRILL=""
NOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || { echo "site-build: --out needs a directory" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --site) [ $# -ge 2 ] || { echo "site-build: --site needs a directory" >&2; exit 2; }; SITE="$2"; shift 2 ;;
    --docs) [ $# -ge 2 ] || { echo "site-build: --docs needs a directory" >&2; exit 2; }; DOCS="$2"; shift 2 ;;
    --drill) [ $# -ge 2 ] || { echo "site-build: --drill needs a file" >&2; exit 2; }; DRILL="$2"; shift 2 ;;
    --now) [ $# -ge 2 ] || { echo "site-build: --now needs YYYY-MM-DD" >&2; exit 2; }; NOW="$2"; shift 2 ;;
    -h|--help) sed -n '2,72p' "$0"; exit 0 ;;
    *) echo "site-build: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -f "$SITE/template.html" ] || { echo "site-build: no $SITE/template.html" >&2; exit 2; }
[ -n "$DRILL" ] || DRILL="$SITE/drill.json"

exec python3 - "$SITE" "$OUT" "$DOCS" "$DRILL" "$NOW" "$REPO" <<'PY'
import datetime, html, json, math, os, re, shutil, subprocess, sys, tempfile

SITE, OUT, DOCS, DRILL, NOW, REPO = sys.argv[1:7]
LANGS = (('zh', ''), ('en', 'en'))   # language · its directory under OUT
STALE_DAYS = 7
REPO_URL = 'https://github.com/verkyyi/claude-fleet'
errs, reds = [], []

def fail(msg):
    errs.append(msg)

today = datetime.datetime.strptime(NOW, '%Y-%m-%d').date() if NOW else datetime.date.today()

# --- the drill ------------------------------------------------------------
drill = None   # {'date', 'runs', 'total', 'steps'} of the slowest run, when usable
why = 'no drill result (%s)' % os.path.relpath(DRILL, REPO) if DRILL.startswith(REPO) else 'no drill result'
if os.path.isfile(DRILL):
    try:
        d = json.load(open(DRILL, encoding='utf-8'))
        runs = [r for r in d.get('runs', []) if isinstance(r, dict)]
        day = datetime.datetime.strptime(str(d['date'])[:10], '%Y-%m-%d').date()
        slow = max(runs, key=lambda r: float(r['total']))
        steps = {k: float(slow['steps'][k]) for k in ('login', 'machine', 'first')}
        shots = slow.get('screens') if isinstance(slow.get('screens'), dict) else {}
        shots = {k: shots[k] for k in ('login', 'machine', 'first')
                 if isinstance(shots.get(k), str) and shots[k].strip()}
        total = float(slow['total'])
        age = (today - day).days
        if age > STALE_DAYS:
            why = 'drill of %s is %d days old (> %d)' % (day, age, STALE_DAYS)
            reds.append(why + ' — the page shows no seconds until it runs again')
        else:
            drill = {'date': day.isoformat(), 'runs': len(runs), 'total': total, 'steps': steps,
                     'screens': shots if len(shots) == 3 else None}
            why = 'drill of %s, slowest of %d runs: %.1f s' % (day, len(runs), total)
            if total > 60:
                reds.append('slowest drill run took %.1f s (> 60): the page says the measured time, not 60' % total)
            if not drill['screens']:
                reds.append('the slowest drill run carries no screens: the steps keep the design\'s pictures '
                            '(bin/site-drill.py writes them)')
    except Exception as e:   # a broken file is no measurement
        why = 'drill result unreadable: %s' % e
        reds.append(why)

def secs(x):
    return int(math.floor(x + 0.5))

def total_secs():
    """The drill's total as the page shows it: over 60 never rounds down to 60."""
    x = drill['total']
    return int(math.ceil(x)) if x > 60 else secs(x)

def time_text(S):
    """What stands where the page says how long it takes."""
    t = total_secs()
    if drill['total'] <= 60:
        return S['time_60']
    if t < 120:
        return S['time_secs'].replace('{n}', str(t))
    return S['time_mins'].replace('{n}', str(int(math.floor(t / 60.0 + 0.5))))

# --- the FAQ: the docs' site questions, one source --------------------------
def faq(lang):
    p = subprocess.run([sys.executable, os.path.join(REPO, 'bin', 'docs-faq.py'), 'json',
                        '--lang', lang, '--site', '--src', DOCS],
                       capture_output=True, text=True)
    if p.returncode != 0:
        fail('docs-faq.py json --lang %s: %s' % (lang, p.stderr.strip()))
        return []
    items = json.loads(p.stdout).get('items', [])
    if not items:
        fail('%s: faq.md marks no question for the site' % lang)
    return [{'q': i['q'], 'a': i['a']} for i in items]

# --- one page ---------------------------------------------------------------
tmpl = open(os.path.join(SITE, 'template.html'), encoding='utf-8').read()
tables = {l: json.load(open(os.path.join(SITE, 'strings.%s.json' % l), encoding='utf-8')) for l, _ in LANGS}
keys = set(tables['zh'])
for l, _ in LANGS:
    if set(tables[l]) != keys:
        fail('strings.%s.json: keys differ from strings.zh.json: %s' % (l, sorted(set(tables[l]) ^ keys)))
    for k, v in tables[l].items():
        if '"' in v:
            fail('strings.%s.json %s: no double quotes (it goes into attributes)' % (l, k))

TIMED_KEYS = ('description', 'og_description', 'try', 'sub', 'steps_h', 'end_h')

def render(lang, S, items):
    v = dict(S)
    v['lang_key'] = lang
    v['cur_zh'] = ' aria-current="page"' if lang == 'zh' else ''
    v['cur_en'] = ' aria-current="page"' if lang == 'en' else ''
    allowed = set()
    if drill:
        tt = time_text(S)
        allowed.add(tt)
        for k in TIMED_KEYS:
            v[k] = S[k].replace('{time}', tt)
        scale = max(60, int(math.ceil(drill['total'] / 15.0)) * 15)
        for k in ('login', 'machine', 'first'):
            n = secs(drill['steps'][k])
            chip = S['secs'].replace('{n}', str(n))
            allowed.add(chip)
            v['t_' + k] = '<span class="sec-t">%s</span>' % chip
            v['w_' + k] = '%.1f' % (100.0 * drill['steps'][k] / scale)
        t = total_secs()
        v['clock'] = '%02d:%02d' % (t // 60, t % 60)
        allowed.add(v['clock'])
        for i in range(1, 5):
            v['tick%d' % i] = str(scale * i // 4)
        allowed.update(('0s', '%ds' % scale))
        v['drill_src'] = S['drill_src'].replace('{runs}', str(drill['runs'])).replace('{date}', drill['date'])
        page = tmpl.replace('<!--timed-->\n', '').replace('<!--/timed-->\n', '')
        if drill['screens']:
            page = re.sub(r'<!--shot:([a-z]+)-->.*?<!--/shot-->', lambda m: '\x00SHOT:%s\x00' % m.group(1),
                          page, flags=re.S)
    else:
        for k in TIMED_KEYS:
            v[k] = S[k + '_untimed']
        for k in ('login', 'machine', 'first'):
            v['t_' + k] = ''
        page = re.sub(r'<!--timed-->\n.*?<!--/timed-->\n', '', tmpl, flags=re.S)

    v['faq_items'] = '\n'.join(
        '  <details><summary>%s<i aria-hidden="true">+</i></summary><p>%s</p></details>'
        % (html.escape(i['q'], quote=False), html.escape(i['a'], quote=False)) for i in items)

    origin = '__ORIGIN__'
    url = origin + S['path']
    graph = [
        {'@type': 'Organization', '@id': origin + '/#org', 'name': 'ClaudeFleet',
         'url': origin + '/', 'logo': origin + '/site/icon-512.png', 'sameAs': [REPO_URL]},
        {'@type': 'WebSite', '@id': origin + '/#website', 'name': 'ClaudeFleet', 'url': url,
         'inLanguage': S['lang'], 'publisher': {'@id': origin + '/#org'}},
        {'@type': 'SoftwareApplication', '@id': origin + '/#app', 'name': 'ClaudeFleet',
         'applicationCategory': 'DeveloperApplication', 'operatingSystem': 'macOS, Linux',
         'description': v['description'], 'url': url, 'inLanguage': S['lang'],
         'image': origin + S['og_image'], 'license': 'https://opensource.org/licenses/MIT',
         'isAccessibleForFree': True, 'publisher': {'@id': origin + '/#org'},
         'offers': {'@type': 'Offer', 'price': '0', 'priceCurrency': 'CNY', 'description': S['offer']},
         'potentialAction': {'@type': 'UseAction', 'target': origin + '/app/try'}},
        {'@type': 'FAQPage', '@id': url + '#faq', 'inLanguage': S['lang'],
         'mainEntity': [{'@type': 'Question', 'name': i['q'],
                         'acceptedAnswer': {'@type': 'Answer', 'text': i['a']}} for i in items]},
    ]
    ld = json.dumps({'@context': 'https://schema.org', '@graph': graph}, ensure_ascii=False, separators=(',', ':'))
    v['jsonld'] = ld.replace('</', '<\\/')

    def sub(m):
        k = m.group(1)
        if k not in v:
            fail('%s: template slot {{%s}} has no string' % (lang, k))
            return ''
        return v[k]
    page = re.sub(r'\{\{([a-z0-9_]+)\}\}', sub, page)
    if '{time}' in page or '{n}' in page:
        fail('%s: an unfilled {time} / {n} is left on the page' % lang)
    page = re.sub(r'<!--/?shot(:[a-z]+)?-->', '', page)
    if drill and drill['screens']:
        page = re.sub('\x00SHOT:([a-z]+)\x00', lambda m: '<pre class="term-shot">%s</pre>'
                      % html.escape(drill['screens'][m.group(1)], quote=False), page)
    return page, allowed

# --- the seconds check -----------------------------------------------------
SECS = re.compile(r'(\d+(?:\.\d+)?)\s*(?:秒|s(?![a-z])|sec\b|seconds?\b)|\b\d{1,2}:\d\d\b|约\s*\d+\s*分钟|about \d+ minutes')

def text_of(page):
    """Everything a reader or a crawler is told: the visible text, the head's
    words, the structured data — not the replay script's timings."""
    ld = ''.join(re.findall(r'<script type="application/ld\+json">(.*?)</script>', page, flags=re.S))
    metas = ' '.join(re.findall(r'<meta [^>]*content="([^"]*)"', page))
    title = ''.join(re.findall(r'<title>(.*?)</title>', page, flags=re.S))
    body = re.sub(r'<(script|style)[^>]*>.*?</\1>', ' ', page, flags=re.S)
    body = re.sub(r'<pre class="term-shot">.*?</pre>', ' ', body, flags=re.S)   # the drill's own screen
    body = re.sub(r'<[^>]+>', ' ', body)
    return html.unescape(' '.join([title, metas, ld, body]))

def check_seconds(lang, page, allowed):
    t = text_of(page)
    for a in sorted(allowed, key=len, reverse=True):
        t = t.replace(a, ' ')
    for m in SECS.finditer(t):
        fail('%s: "%s" on the page is not a drill result — a number of seconds comes only from the drill'
             % (lang, t[max(0, m.start() - 20):m.end() + 10].strip()))

# --- build -------------------------------------------------------------------
pages = {}
for lang, sub_dir in LANGS:
    items = faq(lang)
    page, allowed = render(lang, tables[lang], items)
    check_seconds(lang, page, allowed)
    pages[lang] = (sub_dir, page)

if errs:
    for e in errs:
        print('site-build: ' + e, file=sys.stderr)
    sys.exit(1)

if os.path.isdir(OUT):
    shutil.rmtree(OUT)
os.makedirs(OUT)
open(os.path.join(OUT, '.gitkeep'), 'w').close()
for lang, (sub_dir, page) in pages.items():
    d = os.path.join(OUT, sub_dir)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, 'index.html'), 'w', encoding='utf-8') as fh:
        fh.write(page)

A = os.path.join(SITE, 'assets')
for name in ('logo.svg', 'favicon.ico', 'apple-touch-icon.png', 'icon-192.png', 'icon-512.png'):
    src = os.path.join(A, name)
    if os.path.isfile(src):
        shutil.copy2(src, os.path.join(OUT, name))
    else:
        errs.append('site/assets/%s is missing (bin/site-images.sh makes it)' % name)
for sub_dir, pat in (('fonts', r'\.(woff2|txt)$'), ('og', r'\.png$')):
    src = os.path.join(A, sub_dir)
    os.makedirs(os.path.join(OUT, sub_dir), exist_ok=True)
    for name in sorted(os.listdir(src)) if os.path.isdir(src) else []:
        if re.search(pat, name):
            shutil.copy2(os.path.join(src, name), os.path.join(OUT, sub_dir, name))
for lang in tables:
    if not os.path.isfile(os.path.join(OUT, tables[lang]['og_image'].replace('/site/', '', 1))):
        errs.append('share card %s is missing (bin/site-images.sh makes it)' % tables[lang]['og_image'])

# The FAQ on each page is the docs' list, word for word (C12's check).
for lang, (sub_dir, _) in pages.items():
    p = subprocess.run([sys.executable, os.path.join(REPO, 'bin', 'docs-faq.py'), 'check-html',
                        os.path.join(OUT, sub_dir, 'index.html'), '--lang', lang, '--src', DOCS],
                       capture_output=True, text=True)
    if p.returncode != 0:
        errs.append('%s: FAQ differs from faq.md: %s' % (lang, (p.stdout + p.stderr).strip()))

# --- the files for search engines and AI assistants (C15) -------------------
def crawl_files():
    tmp = tempfile.mkdtemp(prefix='site-docs.')
    try:
        p = subprocess.run([os.path.join(REPO, 'bin', 'docs-build.sh'), '--src', DOCS, '--out', tmp],
                           capture_output=True, text=True)
        if p.returncode != 0:
            errs.append('docs-build.sh (for the sitemap / llms files): %s' % (p.stderr.strip() or p.stdout.strip()))
            return
        docs = []   # {lang, path, title, state, md}
        for line in open(os.path.join(tmp, 'pages.tsv'), encoding='utf-8'):
            f = line.rstrip('\n').split('\t')
            if len(f) < 4:
                continue
            md = open(os.path.join(tmp, f[0], f[1] + '.md'), encoding='utf-8').read()
            docs.append({'lang': f[0], 'path': f[1], 'title': f[2], 'state': f[3], 'md': md})
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if not any(d['lang'] == 'zh' for d in docs):
        errs.append('docs-build.sh listed no zh page in pages.tsv')
        return
    O = '__ORIGIN__'
    base = {'zh': '/docs/', 'en': '/en/docs/'}

    def url(lang, p):        # what the hub answers the page's HTML at (serveDoc)
        if p == 'index':
            return base[lang]
        if p.endswith('/index'):
            return base[lang] + p[:-len('index')]
        return base[lang] + p

    def md_url(lang, p):
        return base[lang] + p + '.md'

    def lastmod(*rels):
        """The newest git commit time of these sources; '' off a checkout."""
        best = ''
        for rel in rels:
            g = subprocess.run(['git', '-C', REPO, 'log', '-1', '--format=%cI', '--', rel],
                               capture_output=True, text=True)
            t = g.stdout.strip() if g.returncode == 0 else ''
            if t and (not best or t > best):
                best = t
        return best

    def src_rel(path):       # a source path relative to the repo, or None (a sandbox)
        path = os.path.realpath(path)
        r = os.path.realpath(REPO)
        return os.path.relpath(path, r) if path.startswith(r + os.sep) else None

    def doc_src(lang, p):
        return src_rel(os.path.join(DOCS, lang, p + '.md'))

    real = {(d['lang'], d['path']): d for d in docs if d['state'] == 'page'}
    zh_docs = [d for d in docs if d['lang'] == 'zh']
    en_docs = [d for d in docs if d['lang'] == 'en']

    # robots.txt
    closed = ['/app/', '/app$', '/v1/', '/mcp', '/connect', '/fleet/', '/embed/', '/install',
              '/auth', '/signin', '/logout', '/badge', '/healthz', '/readyz', '/version']
    ai = ['GPTBot', 'OAI-SearchBot', 'ChatGPT-User', 'ClaudeBot', 'Claude-User', 'Claude-SearchBot',
          'anthropic-ai', 'PerplexityBot', 'Perplexity-User', 'Google-Extended', 'Applebot-Extended',
          'CCBot', 'Bytespider', 'meta-externalagent']
    lines = ['# ClaudeFleet — the website and its docs are open to every crawler, AI assistants included;',
             '# the console (/app) and the APIs are not. (bin/site-build.sh writes this file.)',
             'User-agent: *'] + ['User-agent: %s' % a for a in ai]
    lines += ['Allow: /', 'Allow: /en/', 'Allow: /docs/', 'Allow: /en/docs/', 'Allow: /site/']
    lines += ['Disallow: %s' % c for c in closed]
    lines += ['', 'Sitemap: %s/sitemap.xml' % O, '']
    robots = '\n'.join(lines)

    # sitemap.xml
    def x(s):
        return html.escape(s, quote=True)
    entries = []   # (loc, lastmod, [(hreflang, href)])
    home = {l: tables[l]['path'] for l, _ in LANGS}
    home_alt = [('zh-CN', O + home['zh']), ('en', O + home['en']), ('x-default', O + home['en'])]
    for l, _ in LANGS:
        rels = [r for r in (src_rel(os.path.join(SITE, 'template.html')),
                            src_rel(os.path.join(SITE, 'strings.%s.json' % l)),
                            src_rel(os.path.join(DOCS, l, 'faq.md'))) if r]
        entries.append((O + home[l], lastmod(*rels) if rels else '', home_alt))
    for d in zh_docs + en_docs:
        if d['state'] != 'page':
            continue
        alt = []
        if ('zh', d['path']) in real and ('en', d['path']) in real:
            alt = [('zh-CN', O + url('zh', d['path'])), ('en', O + url('en', d['path']))]
        r = doc_src(d['lang'], d['path'])
        entries.append((O + url(d['lang'], d['path']), lastmod(r) if r else '', alt))
    sm = ['<?xml version="1.0" encoding="UTF-8"?>',
          '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">']
    for loc, lm, alt in entries:
        sm.append('  <url>')
        sm.append('    <loc>%s</loc>' % x(loc))
        if lm:
            sm.append('    <lastmod>%s</lastmod>' % x(lm))
        for hl, href in alt:
            sm.append('    <xhtml:link rel="alternate" hreflang="%s" href="%s"/>' % (x(hl), x(href)))
        sm.append('  </url>')
    sm += ['</urlset>', '']
    sitemap = '\n'.join(sm)

    # llms.txt / llms-zh.txt
    def blurb(md):
        """A page's first paragraph of prose, plain, ≤ 200 characters."""
        body = re.sub(r'<!--.*?-->', '', md, flags=re.S)
        for para in re.split(r'\n\s*\n', body):
            t = para.strip()
            if not t or t[0] in '#|>-*<`!' or re.match(r'\d+\.', t):
                continue
            t = re.sub(r'!?\[([^\]]*)\]\([^)]*\)', r'\1', t)
            t = re.sub(r'[*`]', '', ' '.join(t.split()))
            if len(t) > 200:
                cut = t[:200]
                stop = max(cut.rfind('。'), cut.rfind('. '), cut.rfind('；'))
                t = cut[:stop + 1] if stop > 80 else cut.rstrip() + '…'
            return t
        return ''

    def llms(lang):
        S = tables[lang]
        other = 'llms-zh.txt' if lang == 'en' else 'llms.txt'
        out = ['# ClaudeFleet', '', '> ' + S['llms_summary'], '',
               S['llms_is'], '', S['llms_not'], '', S['llms_for'], '',
               '## ' + S['llms_docs_h'], '']
        mine = en_docs if lang == 'en' else zh_docs
        for d in sorted(mine, key=lambda d: d['state'] != 'page'):   # real English first, stable
            if d['state'] == 'page':
                out.append('- [%s](%s%s): %s' % (d['title'], O, md_url(lang, d['path']), blurb(d['md'])))
            else:
                z = real.get(('zh', d['path']))
                if z:
                    out.append('- [%s](%s%s): %s%s' % (z['title'], O, md_url('zh', d['path']),
                                                        blurb(z['md']), S['llms_in_zh']))
        out += ['', '## ' + S['llms_site_h'], '',
                '- [%s](%s%s): %s' % (S['llms_site_home'], O, S['path'], S['description_untimed']),
                '- [GitHub](%s): %s' % (REPO_URL, S['t2']),
                '', '## ' + S['llms_other_h'], '',
                '- [llms-full.txt](%s/llms-full.txt): %s' % (O, S['llms_full']),
                '- [%s](%s/%s): %s' % (other, O, other, S['llms_other_lang']), '']
        return '\n'.join(out)

    # llms-full.txt: the real pages, English first, each link made absolute
    def absolute(md, lang, p):
        d = os.path.dirname(p)
        def fix(m):
            target, frag = m.group(2), m.group(3) or ''
            q = os.path.normpath(os.path.join(d, target))[:-len('.md')]
            return '%s%s%s%s)' % (m.group(1), O, md_url(lang, q), frag)
        return re.sub(r'(\]\()(?!https?:|/|#|mailto:)([^)\s#]+\.md)(#[^)\s]*)?\)', fix, md)
    full = ['# ClaudeFleet — full documentation', '',
            '> ' + tables['en']['llms_summary'], '',
            '> ' + tables['zh']['llms_summary'], '']
    for d in en_docs + zh_docs:
        if d['state'] != 'page':
            continue
        full += ['---', '', 'Source: %s%s' % (O, url(d['lang'], d['path'])), '',
                 absolute(d['md'], d['lang'], d['path']).strip(), '']
    files = {'robots.txt': robots, 'sitemap.xml': sitemap, 'llms.txt': llms('en'),
             'llms-zh.txt': llms('zh'), 'llms-full.txt': '\n'.join(full)}
    for name, body in files.items():
        if '{time}' in body or '{n}' in body:
            errs.append('%s: an unfilled {time} / {n}' % name)
        with open(os.path.join(OUT, name), 'w', encoding='utf-8') as fh:
            fh.write(body)

crawl_files()

with open(os.path.join(OUT, 'build.json'), 'w', encoding='utf-8') as fh:
    json.dump({'timed': bool(drill), 'why': why, 'day': today.isoformat(),
               'screens': bool(drill and drill['screens']),
               'drill': dict(drill, screens=sorted(drill['screens'] or [])) if drill else None},
              fh, ensure_ascii=False, indent=1)
    fh.write('\n')

for r in reds:
    print('RED: site-build: ' + r, file=sys.stderr)
if errs:
    for e in errs:
        print('site-build: ' + e, file=sys.stderr)
    sys.exit(1)
print('site-build: / and /en/ → %s (%s)' % (OUT, ('timed — ' if drill else 'no seconds — ') + why))
PY
