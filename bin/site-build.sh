#!/bin/bash
# site-build.sh — build the public website, 中文 at / and English at /en/
# (issue #3584, EPIC #3569 C14; the design is the site design v2, decided 2026-10-12).
#
#   site-build.sh                 site/ → tokenledger/hub/web/site/
#   site-build.sh --out <dir>     the same, into <dir> (the selftest's sandbox)
#   site-build.sh --drill <file>  the live drill's result (default site/drill.json)
#   site-build.sh --now <YYYY-MM-DD>   judge the drill's age against this day (tests)
#   site-build.sh --fonts         first cut the fonts to the pages' characters
#                                 (fontTools; issue #3799), then build
#
# One template, one string table per language, nothing typed twice:
#
#   site/template.html            the page: {{key}} slots, <!--timed-->…<!--/timed-->,
#                                 <!--trial-->…<!--/trial--> (the trial variant only),
#                                 <!--apply-->…<!--/apply--> (the apply variant only)
#   site/strings.{zh,en}.json     every word on the page, per language (C15's llms.txt
#                                 reads the same tables)
#   docs/public/                  the docs, for the sitemap and the llms files (the
#                                 front page carries no FAQ of its own — T872)
#   site/assets/                  icons, share cards (bin/site-images.sh makes
#                                 the PNGs once)
#   extras/fleet-theme/           the ONE theme (issue #3924): its fleet:tokens
#                                 block and fonts.css are inlined into the page
#                                 (the template's /*{{fleet_theme}}*/), logo.svg and
#                                 fonts/ copied out. Its fonts-src/ are the fonts as
#                                 published; --fonts cuts each to the characters both
#                                 pages carry (Plex Sans fixed at 400 / 500 / 600 from
#                                 its variable font) into its fonts/ and lists them in
#                                 glyphs.txt — every build fails on a page character
#                                 not in it
#
# Output (gitignored, built into the hub image by hub-deploy like the docs):
#
#   <out>/index.html  <out>/en/index.html     served at / and /en/
#   <out>/logo.svg  wordmark.svg  favicon.ico  apple-touch-icon.png  icon-{192,512}.png
#   <out>/og/cover-{zh,en}.png  <out>/fonts/*.woff2     served under /site/
#   <out>/build.json              what the build decided: timed or not, and why
#   <out>/apply/index.html  <out>/apply/en/index.html  <out>/apply/llms*.txt
#                                 the same with no trial (issue #4269): served in
#                                 their place while the hub's fleet.trial is off —
#                                 every 「立即体验」 is 「申请使用」 → /apply, no
#                                 seconds, no <!--trial--> block, and each
#                                 <key>_apply string in place of <key>
#   <out>/sandbox/index.html  <out>/sandbox/zh/index.html
#                                 the sandbox edition (task PNWW): the Claude Code
#                                 sandbox runtime, from site/sandbox/template.html +
#                                 strings.{en,zh}.json — served at / and /zh/ by a hub
#                                 run with CCQUOTA_SITE=sandbox
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
# The drill file (issue #3589, C19; the drill tools that wrote it left with
# #4904 — a file written by hand from a measured run reads the same):
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
OUT="$REPO/tokenledger/hub/web/site"
DOCS="$REPO/docs/public"
DRILL=""
NOW=""
FONTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || { echo "site-build: --out needs a directory" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --site) [ $# -ge 2 ] || { echo "site-build: --site needs a directory" >&2; exit 2; }; SITE="$2"; shift 2 ;;
    --docs) [ $# -ge 2 ] || { echo "site-build: --docs needs a directory" >&2; exit 2; }; DOCS="$2"; shift 2 ;;
    --drill) [ $# -ge 2 ] || { echo "site-build: --drill needs a file" >&2; exit 2; }; DRILL="$2"; shift 2 ;;
    --now) [ $# -ge 2 ] || { echo "site-build: --now needs YYYY-MM-DD" >&2; exit 2; }; NOW="$2"; shift 2 ;;
    --fonts) FONTS=1; shift ;;
    -h|--help) sed -n '2,79p' "$0"; exit 0 ;;
    *) echo "site-build: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -f "$SITE/template.html" ] || { echo "site-build: no $SITE/template.html" >&2; exit 2; }
[ -n "$DRILL" ] || DRILL="$SITE/drill.json"

exec python3 - "$SITE" "$OUT" "$DOCS" "$DRILL" "$NOW" "$REPO" "$FONTS" <<'PY'
import datetime, hashlib, html, json, math, os, re, shutil, subprocess, sys, tempfile

SITE, OUT, DOCS, DRILL, NOW, REPO, FONTS = sys.argv[1:8]
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
                reds.append('the slowest drill run carries no screens: the steps keep the design\'s pictures')
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

# --- the theme (issue #3924) -------------------------------------------------
# The page's colours and fonts are extras/fleet-theme's, inlined: its fleet:tokens
# block and its fonts.css, comments out, whitespace folded, the font files at
# /site/fonts/, and the light shadcn block as the replay's own (.screen). The
# template defines none of its own (fleet-theme-selftest.sh).
THEME = os.path.join(REPO, 'extras', 'fleet-theme')

def theme_css():
    def tidy(css):
        css = re.sub(r'/\*.*?\*/', '', css, flags=re.S)
        return re.sub(r'\s*([{};:,])\s*', r'\1', ' '.join(css.split())).replace(';}', '}')
    t = open(os.path.join(THEME, 'theme.css'), encoding='utf-8').read()
    m = re.search(r'/\* fleet:tokens \*/(.*?)/\* /fleet:tokens \*/', t, re.S)
    if not m:
        fail('extras/fleet-theme/theme.css has no fleet:tokens block')
        return '', ''
    fonts = open(os.path.join(THEME, 'fonts.css'), encoding='utf-8').read().replace('url(./fonts/', 'url(/site/fonts/')
    bg = re.search(r'--fleet-bg:\s*(#[0-9a-fA-F]{6})', m.group(1))
    # the replay is the web app as it looks signed in (C3): theme.css's light
    # shadcn block — the console's own tokens — scoped to the demo's screen
    light = re.search(r'/\* shadcn — light[^*]*\*/\s*:root\s*(\{.*?\n\})', t, re.S)
    if not light:
        fail('extras/fleet-theme/theme.css has no shadcn light :root block')
        return '', ''
    return ('\n'.join(tidy(c) for c in re.findall(r'@font-face\s*\{[^}]*\}', fonts)) + '\n' + tidy(m.group(1))
            + '\n' + tidy('.screen' + light.group(1)), bg.group(1) if bg else '')

# --- one page ---------------------------------------------------------------
THEME_CSS, THEME_BG = theme_css()
tmpl = open(os.path.join(SITE, 'template.html'), encoding='utf-8').read()
if '/*{{fleet_theme}}*/' not in tmpl:
    fail('template.html has no /*{{fleet_theme}}*/ slot for the theme')
# The icon links carry the logo's version (?v=<sha256[:8]>): Safari keys its favicon
# cache by URL and keeps an old icon for weeks; a new logo is a new URL.
ICON_V = hashlib.sha256(open(os.path.join(THEME, 'logo.svg'), 'rb').read()).hexdigest()[:8]
tmpl = tmpl.replace('/*{{fleet_theme}}*/', THEME_CSS).replace('{{fleet_bg}}', THEME_BG).replace('{{icon_v}}', ICON_V)
# The wordmark (extras/fleet-theme/wordmark.svg) as a symbol the header and the demo's sidebar <use>.
_wm = open(os.path.join(THEME, 'wordmark.svg'), encoding='utf-8').read()
_wm_m = re.search(r'viewBox="([^"]+)"[^>]*>(?:<title>[^<]*</title>)?(.*)</svg>', _wm, re.S)
if '{{fleet_wordmark}}' not in tmpl or not _wm_m:
    fail('template.html has no {{fleet_wordmark}} slot, or extras/fleet-theme/wordmark.svg is unreadable')
else:
    tmpl = tmpl.replace('{{fleet_wordmark}}', '<symbol id="wm" viewBox="%s">%s</symbol>' % (_wm_m.group(1), _wm_m.group(2).strip()))
tables = {l: json.load(open(os.path.join(SITE, 'strings.%s.json' % l), encoding='utf-8')) for l, _ in LANGS}
keys = set(tables['zh'])
for l, _ in LANGS:
    if set(tables[l]) != keys:
        fail('strings.%s.json: keys differ from strings.zh.json: %s' % (l, sorted(set(tables[l]) ^ keys)))
    for k, v in tables[l].items():
        if '"' in v:
            fail('strings.%s.json %s: no double quotes (it goes into attributes)' % (l, k))
# The brand (EPIC SGS6 B1): ONE name, the strings' `brand` — every other string
# says {brand}, and the docs (bin/docs-build.sh) and the share card read the same key.
BRAND = tables['zh'].get('brand', '')
if not BRAND or any(tables[l].get('brand') != BRAND for l, _ in LANGS):
    fail('strings.*.json: brand must be set, and the same in every language')
for l, _ in LANGS:
    tables[l] = {k: v.replace('{brand}', BRAND) for k, v in tables[l].items()}
    t = tables[l].get('brand_tag', '')
    tables[l]['brand_tag_html'] = '<span class="tag">%s</span>' % t if t else ''

TIMED_KEYS = ('description', 'og_description', 'try', 'steps_h', 'end_h')
# The apply-only variant (issue #4269): these words say <key>_apply instead.
APPLY_KEYS = ('description', 'og_description', 'try', 'fine', 's1', 'end_h', 'llms_summary',
              'join_h', 'join_p', 'join_lead', 'ph_h')
for _k in APPLY_KEYS:
    if _k + '_apply' not in keys:
        fail('strings.zh.json: no %s_apply (the page with the trial off says it)' % _k)

def render(lang, S, variant='trial'):
    """One page. variant 'apply' is the page with fleet.trial off (issue #4269):
    no trial anywhere, so no drill seconds either — they time the trial."""
    v = dict(S)
    if variant == 'apply':
        base = re.sub(r'<!--trial-->.*?<!--/trial-->\n?', '', tmpl, flags=re.S)
        base = re.sub(r'<!--/?apply-->\n?', '', base)
    else:
        base = re.sub(r'<!--apply-->.*?<!--/apply-->\n?', '', tmpl, flags=re.S)
        base = re.sub(r'<!--/?trial-->\n?', '', base)
    timed = drill if variant == 'trial' else None
    v['lang_key'] = lang
    v['cur_zh'] = ' aria-current="page"' if lang == 'zh' else ''
    v['cur_en'] = ' aria-current="page"' if lang == 'en' else ''
    allowed = set()
    if timed:
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
        page = base.replace('<!--timed-->\n', '').replace('<!--/timed-->\n', '')
        if drill['screens']:
            page = re.sub(r'<!--shot:([a-z]+)-->.*?<!--/shot-->', lambda m: '\x00SHOT:%s\x00' % m.group(1),
                          page, flags=re.S)
    else:
        for k in TIMED_KEYS:
            v[k] = S[k + '_untimed']
        for k in ('login', 'machine', 'first'):
            v['t_' + k] = ''
        page = re.sub(r'<!--timed-->\n.*?<!--/timed-->\n', '', base, flags=re.S)
    v['try_href'] = '/app/try'
    if variant == 'apply':
        for k in APPLY_KEYS:
            v[k] = S[k + '_apply']
        v['try_href'] = '/apply'

    origin = '__ORIGIN__'
    url = origin + S['path']
    graph = [
        {'@type': 'Organization', '@id': origin + '/#org', 'name': BRAND,
         'url': origin + '/', 'logo': origin + '/site/icon-512.png', 'sameAs': [REPO_URL]},
        {'@type': 'WebSite', '@id': origin + '/#website', 'name': BRAND, 'url': url,
         'inLanguage': S['lang'], 'publisher': {'@id': origin + '/#org'}},
        {'@type': 'SoftwareApplication', '@id': origin + '/#app', 'name': BRAND,
         'applicationCategory': 'BusinessApplication', 'operatingSystem': 'Web, iOS, Android, macOS',
         'description': v['description'], 'url': url, 'inLanguage': S['lang'],
         'image': origin + S['og_image'], 'license': 'https://opensource.org/licenses/MIT',
         'isAccessibleForFree': True, 'publisher': {'@id': origin + '/#org'},
         'offers': {'@type': 'Offer', 'price': '0', 'priceCurrency': 'CNY'},
         'potentialAction': {'@type': 'UseAction', 'target': origin + v['try_href']}},
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
    if timed and drill['screens']:
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
pages, apply_pages = {}, {}
for lang, sub_dir in LANGS:
    page, allowed = render(lang, tables[lang])
    check_seconds(lang, page, allowed)
    pages[lang] = (sub_dir, page)
    page, allowed = render(lang, tables[lang], 'apply')
    check_seconds(lang, page, allowed)
    for bad in ('/app/try', '<!--trial', '<!--/trial'):
        if bad in page:
            fail('%s: the page with the trial off still carries %s' % (lang, bad))
    apply_pages[lang] = (os.path.join('apply', sub_dir), page)

# --- the legal pages (T883, EPIC WACK C2) -----------------------------------
# site/legal/<doc>.<lang>.md → /terms /privacy (中文) and /en/terms /en/privacy,
# each in site/legal.html's frame with the front page's own footer (cut from
# template.html, so the two never drift). The Markdown is the subset the texts
# use: headings, paragraphs, lists, a blockquote, a table, **bold**, [links](…).
LEGAL_DOCS = ('terms', 'privacy')

def md_inline(s):
    s = html.escape(s, quote=False)
    s = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', lambda m: '<a href="%s">%s</a>' % (html.escape(m.group(2)), m.group(1)), s)
    return re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', s)

def md_render(text):
    lines, out, i = text.split('\n'), [], 0
    starts = lambda l: re.match(r'\s*(#{1,6}\s|>|[-*]\s|\d+\.\s|\|)', l)
    while i < len(lines):
        l = lines[i]
        if not l.strip():
            i += 1
            continue
        m = re.match(r'(#{1,6})\s+(.+?)\s*$', l)
        if m:
            out.append('<h%d>%s</h%d>' % (len(m.group(1)), md_inline(m.group(2)), len(m.group(1))))
            i += 1
        elif l.startswith('>'):
            body = []
            while i < len(lines) and lines[i].startswith('>'):
                body.append(lines[i][1:].strip()); i += 1
            out.append('<blockquote><p>%s</p></blockquote>' % md_inline(' '.join(body)))
        elif l.startswith('|'):
            cells = lambda r: [c.strip() for c in r.strip().strip('|').split('|')]
            head, rows = cells(l), []
            i += 2
            while i < len(lines) and lines[i].startswith('|'):
                rows.append(cells(lines[i])); i += 1
            out.append('<table><thead><tr>%s</tr></thead><tbody>%s</tbody></table>' % (
                ''.join('<th>%s</th>' % md_inline(c) for c in head),
                ''.join('<tr>%s</tr>' % ''.join('<td>%s</td>' % md_inline(c) for c in r) for r in rows)))
        elif re.match(r'([-*]|\d+\.)\s', l):
            tag = 'ol' if l[0].isdigit() else 'ul'
            items = []
            while i < len(lines) and re.match(r'([-*]|\d+\.)\s', lines[i]):
                items.append(re.sub(r'^([-*]|\d+\.)\s+', '', lines[i])); i += 1
            out.append('<%s>%s</%s>' % (tag, ''.join('<li>%s</li>' % md_inline(x) for x in items), tag))
        else:
            body = []
            while i < len(lines) and lines[i].strip() and not starts(lines[i]):
                body.append(lines[i].strip()); i += 1
            out.append('<p>%s</p>' % md_inline(' '.join(body)))
    return '\n'.join(out)

legal_pages = {}   # served path → page
LEGAL_FRAME = os.path.join(SITE, 'legal.html')
FOOTER = re.search(r'<footer>.*?</footer>', tmpl, flags=re.S)
if not os.path.isfile(LEGAL_FRAME) or not FOOTER:
    fail('site/legal.html (the legal pages\' frame) or template.html\'s <footer> is missing')
else:
    frame = open(LEGAL_FRAME, encoding='utf-8').read()
    frame = frame.replace('/*{{fleet_theme}}*/', THEME_CSS).replace('{{fleet_bg}}', THEME_BG).replace('{{icon_v}}', ICON_V)
    for lang, _ in LANGS:
        S = tables[lang]
        other = 'en' if lang == 'zh' else 'zh'
        for doc in LEGAL_DOCS:
            src = os.path.join(SITE, 'legal', '%s.%s.md' % (doc, lang))
            if not os.path.isfile(src):
                fail('site/legal/%s.%s.md is missing (every legal page has both languages)' % (doc, lang))
                continue
            md = open(src, encoding='utf-8').read().replace('{brand}', BRAND)
            title = re.search(r'^#\s+(.+?)\s*$', md, flags=re.M)
            if not title:
                fail('site/legal/%s.%s.md has no # title' % (doc, lang))
                continue
            v = dict(S)
            path = S[doc + '_path']
            v.update(legal_title=title.group(1), legal_desc=S[doc + '_desc'], legal_path=path,
                     legal_zh=tables['zh'][doc + '_path'], legal_en=tables['en'][doc + '_path'],
                     legal_other=tables[other][doc + '_path'], legal_body=md_render(md),
                     footer=FOOTER.group(0).replace('href="{{%s_path}}"' % doc, 'href="{{%s_path}}" aria-current="page"' % doc))
            page = frame.replace('{{footer}}', v['footer'])
            def lsub(m, v=v, doc=doc, lang=lang):
                if m.group(1) not in v:
                    fail('%s %s: legal slot {{%s}} has no string' % (lang, doc, m.group(1)))
                    return ''
                return v[m.group(1)]
            legal_pages[path] = re.sub(r'\{\{([a-z0-9_]+)\}\}', lsub, page)

# --- the sandbox edition (task PNWW) -------------------------------------------
# A hub run with CCQUOTA_SITE=sandbox shows another front page: the Claude Code
# sandbox runtime, English at / and 中文 at /zh/ (app_mount.go, site_serve.go).
# site/sandbox/template.html + strings.{en,zh}.json → <out>/sandbox/index.html and
# <out>/sandbox/zh/index.html, in the same theme (the same slots), checked the same
# way (every slot filled, keys alike, no double quotes) and more: nothing loaded
# from anywhere else, no WeChat, no QR code, no mainland positioning, and no word
# of the trial (fleet.trial is the China page's).
SB = os.path.join(SITE, 'sandbox')
SB_LANGS = (('en', 'sandbox'), ('zh', os.path.join('sandbox', 'zh')))
sandbox_pages = {}   # lang → (its directory under OUT, page)
SB_NO = re.compile(r'wechat|微信|weixin|mainland|china|大陆|中国|二四网络|qrcode|\bqr\b|扫码|/app/try|/auth/wechat', re.I)
sb_tables = {}
SB_LOAD = re.compile(r'''(?:\bsrc|srcset)\s*=\s*["']?(?:https?:)?//|<link\b[^>]*\brel=["']?(?:stylesheet|preload|modulepreload|prefetch)[^>]*\bhref=["']?(?:https?:)?//|url\(\s*["']?(?:https?:)?//|@import''', re.I)
if os.path.isfile(os.path.join(SB, 'template.html')):
    sb_tmpl = open(os.path.join(SB, 'template.html'), encoding='utf-8').read()
    for slot in ('/*{{fleet_theme}}*/', '{{fleet_wordmark}}'):
        if slot not in sb_tmpl:
            fail('site/sandbox/template.html has no %s slot for the theme' % slot)
    sb_tmpl = sb_tmpl.replace('/*{{fleet_theme}}*/', THEME_CSS).replace('{{fleet_bg}}', THEME_BG).replace('{{icon_v}}', ICON_V)
    if _wm_m:
        sb_tmpl = sb_tmpl.replace('{{fleet_wordmark}}', '<symbol id="wm" viewBox="%s">%s</symbol>' % (_wm_m.group(1), _wm_m.group(2).strip()))
    sb_tables = {}
    for l, _ in SB_LANGS:
        f = os.path.join(SB, 'strings.%s.json' % l)
        if not os.path.isfile(f):
            fail('site/sandbox/strings.%s.json is missing (the sandbox page has both languages)' % l)
            continue
        sb_tables[l] = json.load(open(f, encoding='utf-8'))
    if set(sb_tables) == {'en', 'zh'} and set(sb_tables['en']) != set(sb_tables['zh']):
        fail('site/sandbox/strings.zh.json: keys differ from strings.en.json: %s'
             % sorted(set(sb_tables['en']) ^ set(sb_tables['zh'])))
    for l, S in sorted(sb_tables.items()):
        for k, v in S.items():
            if '"' in v:
                fail('site/sandbox/strings.%s.json %s: no double quotes (it goes into attributes)' % (l, k))
        v = {k: x.replace('{brand}', BRAND) for k, x in S.items()}
        v['brand'] = BRAND
        O = '__ORIGIN__'
        ld = {'@context': 'https://schema.org', '@graph': [
            {'@type': 'Organization', '@id': O + '/#org', 'name': BRAND, 'url': O + '/',
             'logo': O + '/site/icon-512.png', 'sameAs': [REPO_URL]},
            {'@type': 'SoftwareApplication', '@id': O + '/#app', 'name': BRAND,
             'applicationCategory': 'DeveloperApplication', 'operatingSystem': 'Web, macOS, Linux, iOS, Android',
             'description': v.get('description', ''), 'url': O + v.get('path', '/'), 'inLanguage': v.get('lang', l),
             'publisher': {'@id': O + '/#org'},
             'potentialAction': {'@type': 'UseAction', 'target': O + '/auth/github/start'}}]}
        v['jsonld'] = json.dumps(ld, ensure_ascii=False, separators=(',', ':')).replace('</', '<\\/')

        def sbsub(m, v=v, l=l):
            if m.group(1) not in v:
                fail('sandbox %s: template slot {{%s}} has no string' % (l, m.group(1)))
                return ''
            return v[m.group(1)]
        page = re.sub(r'\{\{([a-z0-9_]+)\}\}', sbsub, sb_tmpl)
        if re.search(r'\{\{|\{brand\}', page):
            fail('sandbox %s: an unfilled slot is left on the page' % l)
        for rx, what in ((SB_NO, 'says %s (the sandbox page is not the China one)'),
                         (SB_LOAD, 'loads %s from elsewhere (CSP: self only)')):
            for m in rx.finditer(page):
                fail('sandbox %s: %s' % (l, what % m.group(0)))
        sandbox_pages[l] = (dict(SB_LANGS)[l], page)
        # T1112: opt-in unified portal; the original sandbox output stays identical.
        portal = page.replace('href="/auth/github/start"', 'href="/app/signin"')
        portal = portal.replace(v['cta_github'], v['signin'])
        portal = portal.replace('<svg aria-hidden="true"><use href="#gh"/></svg>' + v['signin'], v['signin'])
        portal = portal.replace('href="' + v['other_path'] + '" hreflang=',
                                'href="/?lang=' + ('zh-CN' if l == 'en' else 'en') + '" hreflang=')
        trial = 'Try it' if l == 'en' else '立即体验'
        portal = portal.replace('<a class="btn" href="/apply">',
                                '<a class="btn" href="/app/try">' + trial + '</a><a class="btn" href="/apply">')
        sandbox_pages['portal-' + l] = ('portal/' + dict(SB_LANGS)[l], portal)
        sandbox_pages['portal-apply-' + l] = ('apply/portal/' + dict(SB_LANGS)[l],
            portal.replace('<a class="btn" href="/app/try">' + trial + '</a>', ''))

# --- architecture: one Markdown source for the site and the text edition ---
architecture_pages = {}
arch_frame = open(os.path.join(SITE, 'architecture.html'), encoding='utf-8').read()
arch_css = open(os.path.join(SITE, 'architecture.css'), encoding='utf-8').read()
arch_frame = arch_frame.replace('/*{{fleet_theme}}*/', THEME_CSS).replace('{{fleet_bg}}', THEME_BG).replace('{{icon_v}}', ICON_V)
arch_frame = arch_frame.replace('{{architecture_css}}', arch_css)
for lang, _ in LANGS:
    source = os.path.join(DOCS, lang, 'architecture.md')
    # --docs fixtures may omit this optional page; the repository supplies both.
    if not os.path.isfile(source):
        continue
    md = open(source, encoding='utf-8').read()
    parts = re.split(r'<!-- blueprint:([a-z]+) -->', md)
    blocks = dict(zip(parts[1::2], parts[2::2]))
    required = {'layers', 'external', 'cross', 'flows', 'boundaries', 'principles', 'glossary', 'version'}
    if set(blocks) != required:
        fail('architecture %s: expected blueprint sections %s' % (lang, sorted(required)))
        continue
    intro = re.sub(r'^!\[.*?\]\(.*?\)\s*$', '', parts[0], flags=re.M)
    intro = re.sub(r'^\[.*$', '', intro, flags=re.M)
    prefix = '/en/docs/' if lang == 'en' else '/docs/'
    def arch_render(text):
        rendered = md_render(text)
        return re.sub(r'href="([a-z][a-z0-9/-]*)\.md"', lambda m: 'href="%s%s"' % (prefix, m.group(1).removesuffix('/index') + ('/' if m.group(1).endswith('/index') else '')), rendered)
    def cards(text, kind):
        chunks = re.split(r'(?=^### )', text, flags=re.M)
        out = arch_render(chunks[0])
        if kind != 'layer':
            out += '<div class="%s-grid">' % kind
        for chunk in chunks[1:]:
            card = arch_render(chunk)
            card = re.sub(r' · (live|in progress)</h3>', lambda m: '</h3><span class="badge %s">%s</span>' % ('live' if m.group(1) == 'live' else 'progress', m.group(1)), card)
            connector = ''
            if kind == 'layer' and '</ul>\n<p>' in card:
                card, connector = card.split('</ul>\n', 1)
                card += '</ul>'
            out += '<section class="%s">%s</section>' % (kind, card)
            if connector:
                out += '<div class="connector">%s</div>' % connector
        return out + ('</div>' if kind != 'layer' else '')
    title_match = re.search(r'^# (.+)$', md, re.M)
    if not title_match:
        fail('architecture %s: no Markdown title' % lang)
        continue
    title = title_match.group(1)
    text_label = 'Text version and diagram description' if lang == 'en' else '文字版与图示说明'
    body = arch_render(intro) + '<p><a href="%sarchitecture">%s</a></p>' % (prefix, text_label)
    body += '<div class="blueprint"><div>' + cards(blocks['layers'], 'layer') + '</div><aside>'
    body += ''.join('<section class="side">%s</section>' % arch_render(blocks[k]) for k in ('external', 'cross')) + '</aside></div>'
    body += cards(blocks['flows'], 'flow')
    body += '<section class="boundaries">%s</section>' % arch_render(blocks['boundaries'])
    body += cards(blocks['principles'], 'principle')
    body += '<section class="glossary">%s</section>' % arch_render(blocks['glossary'])
    body += '<div class="version">%s</div>' % arch_render(blocks['version'])
    for sandbox in (False, True):
        if sandbox and lang not in sb_tables:
            continue  # the missing-language error above must remain the build verdict
        S = dict(sb_tables[lang] if sandbox else tables[lang])
        zh_path = '/zh/architecture' if sandbox else '/architecture'
        en_path = '/architecture' if sandbox else '/en/architecture'
        path = en_path if lang == 'en' else zh_path
        S.update(brand=BRAND, architecture_title=title, architecture_desc=title,
                 architecture_path=path, architecture_zh=zh_path, architecture_en=en_path,
                 architecture_other=zh_path if lang == 'en' else en_path,
                 architecture_home='Home' if lang == 'en' else '首页',
                 architecture_skip='Skip to content' if lang == 'en' else '跳到正文',
                 architecture_body=body, lang_group='Language' if lang == 'en' else '语言',
                 other_name='中文' if lang == 'en' else 'English')
        footer_template = sb_tmpl if sandbox else tmpl
        footer = re.search(r'<footer>.*?</footer>', footer_template, re.S).group(0)
        # The compact frame uses the shared wordmark image, not the front page's symbols.
        footer = re.sub(r'<svg\b.*?</svg>', '', footer, flags=re.S)
        frame = arch_frame.replace('{{footer}}', footer)
        def arch_sub(m):
            if m.group(1) not in S:
                fail('architecture %s: unfilled slot %s' % (lang, m.group(1)))
            return S.get(m.group(1), '').replace('{brand}', BRAND)
        page = re.sub(r'\{\{([a-z0-9_]+)\}\}', arch_sub, frame)
        architecture_pages[('sandbox' if sandbox else '') + path] = page


if errs:
    for e in errs:
        print('site-build: ' + e, file=sys.stderr)
    sys.exit(1)

# --- the fonts (issue #3799) -------------------------------------------------
# Each served font is cut down to the characters the two pages carry, so a slow
# phone fetches ~55 KB of fonts instead of ~95 KB. The cut is made by --fonts
# (fontTools) from extras/fleet-theme/fonts-src/ into its fonts/ and committed; every build checks it still
# covers both pages, or a new word would fall back to the system font unseen.
FONT_SRC = os.path.join(THEME, 'fonts-src')
FONT_OUT = os.path.join(THEME, 'fonts')
GLYPHS = os.path.join(FONT_SRC, 'glyphs.txt')
FONT_CUTS = (   # served file · its source · the weight a variable source is fixed at
    ('ibm-plex-sans-400-latin.woff2', 'ibm-plex-sans-var-latin.woff2', 400),
    ('ibm-plex-sans-500-latin.woff2', 'ibm-plex-sans-var-latin.woff2', 500),
    ('ibm-plex-sans-600-latin.woff2', 'ibm-plex-sans-var-latin.woff2', 600),
    ('ibm-plex-mono-400-latin.woff2', 'ibm-plex-mono-400-latin.woff2', None),
    ('ibm-plex-mono-500-latin.woff2', 'ibm-plex-mono-500-latin.woff2', None),
    ('bricolage-grotesque-600-latin.woff2', 'bricolage-grotesque-600-latin.woff2', None),
    ('bricolage-grotesque-800-latin.woff2', 'bricolage-grotesque-800-latin.woff2', None),
)

def font_range(page):
    # The @font-face unicode-range (one list, every face): only these characters
    # are ever drawn with our fonts — the rest is the system's (中文 included).
    m = re.search(r'unicode-range:([^;}]+)', page)
    spans = []
    for part in (m.group(1).split(',') if m else []):
        a, _, b = part.strip()[2:].partition('-')
        spans.append((int(a, 16), int(b or a, 16)))
    return spans

def page_chars():
    spans = font_range(pages['en'][1])
    chars = set(range(0x20, 0x7f))   # all of printable ASCII, used or not
    for _, page in list(pages.values()) + list(apply_pages.values()) + list(sandbox_pages.values()) + [('', p) for p in list(legal_pages.values()) + list(architecture_pages.values())]:
        chars |= {ord(c) for c in html.unescape(page)
                  if ord(c) >= 0x20 and any(a <= ord(c) <= b for a, b in spans)}
    return chars

if FONTS:
    try:
        from fontTools import subset
        from fontTools.ttLib import TTFont
        from fontTools.varLib import instancer
        import brotli   # noqa: F401 — woff2
    except ImportError:
        print('site-build: --fonts needs fontTools + brotli (pip install fonttools brotli)', file=sys.stderr)
        sys.exit(2)
    chars = page_chars()
    for name, src, wght in FONT_CUTS:
        f = TTFont(os.path.join(FONT_SRC, src))
        if wght is not None:
            f = instancer.instantiateVariableFont(f, {'wght': wght})
        o = subset.Options()
        o.flavor, o.layout_features, o.name_IDs, o.notdef_outline = 'woff2', ['*'], ['*'], True
        s = subset.Subsetter(o)
        s.populate(unicodes=chars)
        s.subset(f)
        f.flavor = 'woff2'
        f.save(os.path.join(FONT_OUT, name))
    with open(GLYPHS, 'w', encoding='utf-8') as fh:
        fh.write(''.join(chr(c) for c in sorted(chars)) + '\n')
    print('site-build: fonts cut to %d characters → extras/fleet-theme/fonts/' % len(chars))

have = set(open(GLYPHS, encoding='utf-8').read().rstrip('\n')) if os.path.isfile(GLYPHS) else set()
lack = sorted(chr(c) for c in page_chars() if chr(c) not in have)
if lack:
    errs.append('the fonts lack %s (on the page now): run bin/site-build.sh --fonts (needs fontTools)'
                % ' '.join('U+%04X %s' % (ord(c), c) for c in lack))
for name, _, _ in FONT_CUTS:
    if not os.path.isfile(os.path.join(FONT_OUT, name)):
        errs.append('extras/fleet-theme/fonts/%s is missing: run bin/site-build.sh --fonts' % name)
if errs:
    for e in errs:
        print('site-build: ' + e, file=sys.stderr)
    sys.exit(1)

if os.path.isdir(OUT):
    shutil.rmtree(OUT)
os.makedirs(OUT)
open(os.path.join(OUT, '.gitkeep'), 'w').close()
for lang, (sub_dir, page) in list(pages.items()) + list(apply_pages.items()) + list(sandbox_pages.items()):
    d = os.path.join(OUT, sub_dir)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, 'index.html'), 'w', encoding='utf-8') as fh:
        fh.write(page)

for path, page in list(legal_pages.items()) + list(architecture_pages.items()):
    d = os.path.join(OUT, path.strip('/'))
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, 'index.html'), 'w', encoding='utf-8') as fh:
        fh.write(page)

A = os.path.join(SITE, 'assets')
for name in ('logo.svg', 'wordmark.svg', 'favicon.ico', 'apple-touch-icon.png', 'icon-192.png', 'icon-512.png'):
    src = os.path.join(THEME if name.endswith('.svg') else A, name)
    if os.path.isfile(src):
        shutil.copy2(src, os.path.join(OUT, name))
    else:
        errs.append('%s is missing (bin/site-images.sh makes it)' % os.path.relpath(src, REPO))
for sub_dir, pat in (('fonts', r'\.(woff2|txt)$'), ('og', r'\.png$')):
    src = FONT_OUT if sub_dir == 'fonts' else os.path.join(A, sub_dir)
    os.makedirs(os.path.join(OUT, sub_dir), exist_ok=True)
    for name in sorted(os.listdir(src)) if os.path.isdir(src) else []:
        if re.search(pat, name):
            shutil.copy2(os.path.join(src, name), os.path.join(OUT, sub_dir, name))
for lang in tables:
    if not os.path.isfile(os.path.join(OUT, tables[lang]['og_image'].replace('/site/', '', 1))):
        errs.append('share card %s is missing (bin/site-images.sh makes it)' % tables[lang]['og_image'])

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
    closed = ['/app/', '/app$', '/v1/', '/mcp', '/connect', '/fleet/', '/embed/', '/chat/', '/install',
              '/auth', '/signin', '/logout', '/badge', '/healthz', '/readyz', '/version']
    ai = ['GPTBot', 'OAI-SearchBot', 'ChatGPT-User', 'ClaudeBot', 'Claude-User', 'Claude-SearchBot',
          'anthropic-ai', 'PerplexityBot', 'Perplexity-User', 'Google-Extended', 'Applebot-Extended',
          'CCBot', 'Bytespider', 'meta-externalagent']
    lines = ['# %s — the website and its docs are open to every crawler, AI assistants included;' % BRAND,
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
                            src_rel(os.path.join(SITE, 'strings.%s.json' % l))) if r]
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
        out = ['# ' + BRAND, '', '> ' + S['llms_summary'], '',
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
                '- [GitHub](%s): %s' % (REPO_URL, S['oss_line']),
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
    full = ['# %s — full documentation' % BRAND, '',
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
    # the llms files with the trial off (issue #4269): the same, each summary
    # and the front page's line in their apply words
    os.makedirs(os.path.join(OUT, 'apply'), exist_ok=True)
    for name in ('llms.txt', 'llms-zh.txt', 'llms-full.txt'):
        body = files[name]
        for S in tables.values():
            body = body.replace(S['llms_summary'], S['llms_summary_apply'])
            body = body.replace(S['description_untimed'], S['description_apply'])
        with open(os.path.join(OUT, 'apply', name), 'w', encoding='utf-8') as fh:
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
