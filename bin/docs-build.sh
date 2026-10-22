#!/bin/bash
# docs-build.sh — render the public docs to static HTML (issue #3575, EPIC #3569 C5).
#
#   docs-build.sh                 docs/public/{zh,en}/**/*.md → tokenledger/hub/web/docs/
#   docs-build.sh --out <dir>     the same, into <dir> (the selftest's sandbox)
#
# docs/public/ is the ONE home of the documentation for people who USE fleet
# (EPIC #3569 共同约定 4); docs/dev/ is for the people who build it and is never
# linked from here. The output, beside each page's HTML, keeps the page's own
# Markdown under the same name, so a reader (or an AI) can fetch either:
#
#   <out>/zh/<reader>/<slug>.html + .md     served as /docs/<reader>/<slug>[.md]
#   <out>/en/<reader>/<slug>.html + .md     served as /en/docs/<reader>/<slug>[.md]
#   <out>/zh/index.html + index.md          /docs/  (same for /en/docs/)
#   <out>/pages.tsv                         lang · path · title · state (page|pending)
#   <out>/<lang>/faq.json                   the FAQ as data (bin/docs-faq.py json), for
#                                           the site's FAQPage and llms.txt (issue #3582)
#
#   docs-build.sh --troubleshooting-skeleton
#                                 print a `#### `<row>`` section for every `fleet doctor`
#                                 row the troubleshooting page still lacks (nothing =
#                                 complete; bin/fleet-doctor-rows.py page-skeleton)
#
#   docs-build.sh --write         fill every generated block in docs/public/ in place
#   docs-build.sh --check         exit 1 naming each page whose block is stale
#
# A generated block is never hand-written (issue #3580, EPIC #3569 共同约定 4):
#   <!-- docs-gen:<name> --> … <!-- /docs-gen:<name> -->
# `keys` (the keys that open the panel + the panel's own keys) and `keys-extra`
# (the keys a person may add back) are drawn from the ONE key tables — bin/fleet_keys.py's
# defaults, `dash-keymap.sh --panel switch view`, and the words in
# bin/fleet-ui-lang.sh. The build always fills them in its output, so the site
# follows a key change on the next build; --write keeps the Markdown on GitHub in
# step and docs-build-selftest.sh H reds on a source left stale.
#
# A page links to another by its relative .md path (so GitHub and
# docs-links-selftest read the same link); the build drops the extension, and the
# server answers /docs/<p> with <p>.html — the mount and the embed are C13's
# (#3583), the sitemap and llms-full are C15's, read off pages.tsv.
#
# Chinese leads: a zh page with no en twin still gets an en page — 「English
# version in preparation」 with a link to the Chinese one (state `pending`) — never
# a 404. An en page with no zh twin is an error (exit 1). Every page needs a
# `# ` title (exit 1 otherwise), and a page with both languages one outline — the
# same `##` … `######` levels in the same order (exit 1 otherwise, issue #4096). No framework, no CDN: the CSS below is inlined,
# its colours the entry's own app.css variables.
#
# Output is a build input like fleetclient/pack: gitignored, rebuilt every time
# (the directory is emptied first, its .gitkeep put back — the hub embeds it).
# Exit: 0 built · 1 a page is wrong · 2 usage.
set -uo pipefail
real="$0"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
SRC="$REPO/docs/public"
OUT="$REPO/tokenledger/hub/web/docs"
MODE="build"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || { echo "docs-build: --out needs a directory" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --src) [ $# -ge 2 ] || { echo "docs-build: --src needs a directory" >&2; exit 2; }; SRC="$2"; shift 2 ;;
    --troubleshooting-skeleton)
      exec python3 "$REPO/bin/fleet-doctor-rows.py" page-skeleton "$SRC/zh/troubleshooting.md" --root "$REPO" ;;
    --write) MODE="write"; shift ;;
    --check) MODE="check"; shift ;;
    -h|--help) sed -n '2,49p' "$0"; exit 0 ;;
    *) echo "docs-build: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -d "$SRC/zh" ] || { echo "docs-build: no $SRC/zh" >&2; exit 2; }

exec python3 - "$SRC" "$OUT" "$REPO" "$MODE" <<'PY'
import html, json, os, re, shutil, subprocess, sys

SRC, OUT, REPO, MODE = sys.argv[1:5]
LANGS = ('zh', 'en')
# The three roads, in the order the index tells them (issue #3941): using it
# first — member, admin — and self-hosting last, as the side road. A page outside
# these directories is shared by the using roads (faq, troubleshooting, admin/),
# except SELF_HOST_PAGES, which sit with self-host.
READERS = ('member', 'hosted', 'self-host')
SELF_HOST_PAGES = ('security',)
UI = {
    'zh': {'readers': {'self-host': '自托管与开发', 'hosted': '管理员', 'member': '成员'},
           'common': '都会用到', 'home': '帮助首页', 'other': 'English', 'pending': '',
           'source': '本页 Markdown'},
    'en': {'readers': {'self-host': 'Self-host & develop', 'hosted': 'Admin', 'member': 'Member'},
           'common': 'For everyone', 'home': 'Help home', 'other': '中文',
           'pending': 'English version in preparation. The Chinese page is complete:',
           'source': 'Markdown of this page'},
}

def pages(lang):
    root = os.path.join(SRC, lang)
    found = {}
    if not os.path.isdir(root):
        return found
    for d, _, fs in os.walk(root):
        for f in fs:
            if f.endswith('.md'):
                rel = os.path.relpath(os.path.join(d, f), root)[:-3].replace(os.sep, '/')
                found[rel] = os.path.join(d, f)
    return found

def title_of(text):
    for line in text.split('\n'):
        m = re.match(r'#\s+(.+?)\s*#*\s*$', line)
        if m:
            return m.group(1)
    return None

# ---- Markdown, the subset these pages use -----------------------------------
def slug(s):
    s = re.sub(r'<[^>]+>', '', s).strip().lower()
    s = re.sub(r'[^\w一-鿿\- ]', '', s)
    return re.sub(r'\s+', '-', s) or 'section'

def link_target(t):
    if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:', t) or t.startswith('#') or t.startswith('/'):
        return t
    path, _, frag = t.partition('#')
    if path.endswith('.md'):
        path = path[:-3]
        if path == 'index' or path.endswith('/index'):
            path = path[:-5] or './'
    return path + ('#' + frag if frag else '')

def inline(s):
    out, i = [], 0
    for m in re.finditer(r'`([^`]+)`', s):
        out.append(inline_text(s[i:m.start()]))
        out.append('<code>%s</code>' % html.escape(m.group(1)))
        i = m.end()
    out.append(inline_text(s[i:]))
    return ''.join(out)

def inline_text(s):
    s = html.escape(s, quote=False)
    s = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)',
               lambda m: '<a href="%s">%s</a>' % (html.escape(link_target(m.group(2))), m.group(1)), s)
    s = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', s)
    s = re.sub(r'(?<![\w*])\*([^*\s][^*]*)\*(?!\w)', r'<em>\1</em>', s)
    return s

def render(text):
    text = re.sub(r'<!--.*?-->', '', text, flags=re.S)  # a marker such as docs-links-ok
    lines = text.split('\n')
    out, i, n = [], 0, len(lines)
    def para_end(l):
        return (not l.strip() or re.match(r'\s*(#{1,6}\s|```|>|[-*]\s|\d+\.\s|\|)', l) or l.strip() == '---')
    while i < n:
        l = lines[i]
        if not l.strip():
            i += 1; continue
        m = re.match(r'(#{1,6})\s+(.+?)\s*#*\s*$', l)
        if m:
            lvl, t = len(m.group(1)), m.group(2)
            out.append('<h%d id="%s">%s</h%d>' % (lvl, slug(t), inline(t), lvl))
            i += 1; continue
        if l.lstrip().startswith('```'):
            lang = l.strip()[3:].strip()
            body = []
            i += 1
            while i < n and not lines[i].lstrip().startswith('```'):
                body.append(lines[i]); i += 1
            i += 1
            cls = ' class="lang-%s"' % html.escape(lang) if lang else ''
            out.append('<pre><code%s>%s</code></pre>' % (cls, html.escape('\n'.join(body))))
            continue
        if l.strip() == '---':
            out.append('<hr>'); i += 1; continue
        if l.lstrip().startswith('>'):
            body = []
            while i < n and lines[i].lstrip().startswith('>'):
                body.append(re.sub(r'^\s*>\s?', '', lines[i])); i += 1
            out.append('<blockquote>%s</blockquote>' % render('\n'.join(body)))
            continue
        if l.lstrip().startswith('|') and i + 1 < n and re.match(r'\s*\|[\s:|-]+\|\s*$', lines[i + 1]):
            cells = lambda r: [c.strip() for c in r.strip().strip('|').split('|')]
            head = cells(l); i += 2
            rows = []
            while i < n and lines[i].lstrip().startswith('|'):
                rows.append(cells(lines[i])); i += 1
            t = '<table><thead><tr>%s</tr></thead><tbody>' % ''.join('<th>%s</th>' % inline(c) for c in head)
            t += ''.join('<tr>%s</tr>' % ''.join('<td>%s</td>' % inline(c) for c in r) for r in rows)
            out.append(t + '</tbody></table>')
            continue
        m = re.match(r'(\s*)([-*]|\d+\.)\s+', l)
        if m:
            i = render_list(lines, i, out)
            continue
        body = []
        while i < n and not para_end(lines[i]):
            body.append(lines[i].strip()); i += 1
        out.append('<p>%s</p>' % inline(' '.join(body)))
    return '\n'.join(out)

def render_list(lines, i, out):
    first = re.match(r'(\s*)([-*]|\d+\.)\s+', lines[i])
    indent, ordered = len(first.group(1)), first.group(2)[0].isdigit()
    tag = 'ol' if ordered else 'ul'
    items = []
    while i < len(lines):
        l = lines[i]
        m = re.match(r'(\s*)([-*]|\d+\.)\s+(.*)', l)
        if m and len(m.group(1)) == indent:
            items.append([m.group(3)]); i += 1; continue
        if not l.strip():
            # a blank line ends the list unless the next line continues it
            nxt = lines[i + 1] if i + 1 < len(lines) else ''
            if nxt.strip() and len(nxt) - len(nxt.lstrip()) > indent:
                items[-1].append(''); i += 1; continue
            break
        if len(l) - len(l.lstrip()) > indent and items:
            items[-1].append(l[indent + 2:] if l[:indent + 2].strip() == '' else l.strip()); i += 1; continue
        break
    out.append('<%s>' % tag)
    for it in items:
        body = render('\n'.join(it))
        if body.startswith('<p>') and body.count('<p>') == 1:
            body = body[3:].replace('</p>', '', 1)
        out.append('<li>%s</li>' % body)
    out.append('</%s>' % tag)
    return i

# ---- the page frame --------------------------------------------------------
# The look is extras/fleet-theme's (issue #3924; EPIC SGS6 C4): its tokens and the
# shadcn light / dark blocks inlined as they are, the fonts at /site/fonts/ (the
# site's copy), and every colour below a var() of them — none is defined here
# (fleet-theme-selftest.sh). The mark comes from the same package; its name is the
# site's brand key (site/strings.zh.json).
THEME = os.path.join(REPO, 'extras', 'fleet-theme')

def theme_css():
    t = open(os.path.join(THEME, 'theme.css'), encoding='utf-8').read()
    a, b = t.find('/* fleet:tokens */'), t.find('@theme inline')
    if a < 0 or b < a:
        print('docs-build: extras/fleet-theme/theme.css: no fleet:tokens block before @theme', file=sys.stderr)
        sys.exit(1)
    fonts = open(os.path.join(THEME, 'fonts.css'), encoding='utf-8').read().replace('url(./fonts/', 'url(/site/fonts/')
    tidy = lambda c: re.sub(r'\s+', ' ', re.sub(r'/\*.*?\*/', '', c, flags=re.S)).strip()
    return '\n'.join(tidy(c) for c in re.findall(r'@font-face\s*\{[^}]*\}', fonts)) + '\n' + tidy(t[a:b])

def theme_brand():
    """The name is the site's one brand key (site/strings.zh.json `brand`, EPIC SGS6
    B1); the mark is the theme's logo.svg."""
    try:
        name = json.load(open(os.path.join(REPO, 'site', 'strings.zh.json'), encoding='utf-8'))['brand']
    except (OSError, ValueError, KeyError):
        print('docs-build: site/strings.zh.json has no brand (the product name)', file=sys.stderr)
        sys.exit(1)
    svg = open(os.path.join(THEME, 'logo.svg'), encoding='utf-8').read().strip()
    mark = re.sub(r'<title>[^<]*</title>', '', svg).replace('<svg ', '<svg class="mark" aria-hidden="true" ', 1)
    return name, mark

BRAND, MARK = theme_brand()
CSS = theme_css() + """
:root{--bg:var(--background);--panel:var(--card);--ink:var(--foreground);--ink-2:var(--foreground);--muted:var(--muted-foreground);
--line:var(--border);--line-2:var(--code-bg);--brand:var(--link);--brand-soft:var(--accent);--term:var(--fleet-term);--term-ink:var(--fleet-ink);
--f-display:var(--fleet-font-display);--f-ui:var(--fleet-font-ui);--f-mono:var(--fleet-font-mono);--warn-soft:#fbefd6}
@media (prefers-color-scheme:dark){:root{--warn-soft:#33290f}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15.5px/1.7 var(--f-ui);-webkit-font-smoothing:antialiased}
a{color:var(--brand);text-decoration:none}a:hover{text-decoration:underline}
header{display:flex;flex-wrap:wrap;align-items:center;gap:8px 18px;padding:12px 24px;border-bottom:1px solid var(--line);background:var(--panel);position:sticky;top:0;z-index:2}
header .brand{display:inline-flex;align-items:center;gap:9px;font:700 17px var(--f-display);color:var(--ink)}header .brand:hover{text-decoration:none}
header .brand .mark{width:26px;height:26px;flex:none}
header nav{display:flex;flex-wrap:wrap;gap:4px}header nav a{padding:4px 10px;border-radius:7px;color:var(--ink-2);font-size:14px}
header nav a.aux{margin-left:10px;color:var(--muted)}header nav a.on{background:var(--brand-soft);color:var(--brand);font-weight:600}
header .lang{margin-left:auto;font-size:14px}
.wrap{display:grid;grid-template-columns:220px minmax(0,760px);gap:40px;max-width:1080px;margin:0 auto;padding:28px 24px 80px}
aside{font-size:14px}aside h4{margin:18px 0 6px;font-size:12px;letter-spacing:.06em;color:var(--muted);text-transform:uppercase}
aside a{display:block;padding:3px 0;color:var(--ink-2)}aside a.on{color:var(--brand);font-weight:600}
main{min-width:0}main h1{font:650 30px/1.25 var(--f-display);margin:0 0 18px}main h2{font:620 21px/1.3 var(--f-display);margin:34px 0 10px;padding-top:8px;border-top:1px solid var(--line-2)}
main h3{font-size:17px;margin:24px 0 8px}main p,main ul,main ol{margin:0 0 14px}main li{margin:4px 0}
code{font-family:var(--f-mono);font-size:.88em;background:var(--code-bg);color:var(--code-fg);padding:1px 5px;border-radius:5px}
pre{background:var(--term);color:var(--term-ink);padding:14px 16px;border-radius:9px;overflow:auto;line-height:1.55}
pre code{background:none;padding:0;color:inherit}
blockquote{margin:0 0 14px;padding:10px 14px;border-left:3px solid var(--brand);background:var(--brand-soft);border-radius:0 8px 8px 0}
blockquote p:last-child{margin:0}
table{border-collapse:collapse;width:100%;margin:0 0 16px;font-size:14.5px;display:block;overflow-x:auto}
th,td{border:1px solid var(--line);padding:6px 10px;text-align:left;vertical-align:top}th{background:var(--line-2)}
.pending{padding:12px 16px;background:var(--warn-soft);border-radius:9px;margin:0 0 18px}
footer{margin-top:48px;font-size:13px;color:var(--muted)}
@media (max-width:820px){.wrap{grid-template-columns:minmax(0,1fr);gap:12px;padding:18px 16px 60px}aside{order:2;border-top:1px solid var(--line);padding-top:8px}
header{padding:10px 16px}main h1{font-size:25px}}
"""

def url_prefix(lang):
    return '/docs/' if lang == 'zh' else '/en/docs/'

def rel(from_page, to_page):
    """A relative href from one page's URL to another's (both no extension)."""
    base = os.path.dirname(from_page)
    if to_page == 'index' or to_page.endswith('/index'):
        target = to_page[:-5]
        r = os.path.relpath(target or '.', base or '.')
        return (r + '/') if r != '.' else './'
    return os.path.relpath(to_page, base or '.')

def reader_of(p):
    head = p.split('/', 1)[0]
    return head if head in READERS and '/' in p else None

def frame(lang, page, title, body, all_titles, pending=False, ld=''):
    ui = UI[lang]
    cur = reader_of(page)
    nav = ''.join('<a href="%s" class="%s">%s</a>' % (html.escape(rel(page, r + '/quickstart')),
                  ' '.join(c for c in ('on' if r == cur else '', 'aux' if r == 'self-host' else '') if c),
                  ui['readers'][r]) for r in READERS).replace(' class=""', '')
    side = ['<a href="%s"%s>%s</a>' % (html.escape(rel(page, 'index')), ' class="on"' if page == 'index' else '', ui['home'])]
    def group(name, members):
        if not members:
            return
        side.append('<h4>%s</h4>' % name)
        for p in members:
            side.append('<a href="%s"%s>%s</a>' % (html.escape(rel(page, p)), ' class="on"' if p == page else '',
                                                   html.escape(all_titles[p])))
    order = lambda p: (0 if p.endswith('/quickstart') or p.endswith('/index') else 1, p)
    if cur and cur != 'self-host':
        group(ui['readers'][cur], sorted((p for p in all_titles if reader_of(p) == cur), key=order))
    group(ui['common'], sorted((p for p in all_titles if p != 'index' and not reader_of(p)
                                and p not in SELF_HOST_PAGES), key=order))
    # the side road always last, so a page's first screen leads with using it
    group(ui['readers']['self-host'], sorted((p for p in all_titles if reader_of(p) == 'self-host'), key=order)
          + [p for p in SELF_HOST_PAGES if p in all_titles])
    other = 'en' if lang == 'zh' else 'zh'
    other_url = url_prefix(other) + ('' if page == 'index' else page)
    src = os.path.basename(page) + '.md'
    head_lang = 'zh-CN' if lang == 'zh' else 'en'
    return ('<!doctype html><html lang="%s"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>%s · %s</title><link rel="icon" href="/favicon.ico" sizes="32x32">'
            '<link rel="icon" href="/favicon.svg" type="image/svg+xml"><link rel="apple-touch-icon" href="/apple-touch-icon.png">'
            '<link rel="alternate" type="text/markdown" href="%s">'
            '<link rel="alternate" hreflang="%s" href="%s"><style>%s</style>%s</head><body>'
            '<header><a class="brand" href="%s">%s%s</a><nav>%s</nav><a class="lang" href="%s">%s</a></header>'
            '<div class="wrap"><aside>%s</aside><main>%s<footer><a href="%s">%s</a></footer></main></div></body></html>\n') % (
        head_lang, html.escape(title), html.escape(BRAND), html.escape(src), 'en' if other == 'en' else 'zh-CN', other_url, CSS,
        ld, html.escape(rel(page, 'index')), MARK, html.escape(BRAND), nav, other_url, ui['other'], ''.join(side), body, html.escape(src), ui['source'])

# ---- generated blocks (issue #3580) -------------------------------------------
GEN_RE = re.compile(r'(<!-- docs-gen:([a-z-]+) -->\n)(.*?)(<!-- /docs-gen:\2 -->)', re.S)
GEN_WORDS = {
    'zh': {'where': '在哪', 'press': '按', 'mac': 'Mac 上的 iTerm2', 'phone': '手机（Termius）或别的终端',
           'or': ' 或 ', 'then': '再按', 'key': '键', 'does': '做什么', 'nokey': '—',
           'action': '名字', 'mac_x': 'Mac 上（⌘）', 'phone_x': '手机上（⌃] 再按）', 'space': '空格',
           'home': '任何画面：家里这台机器的命令行（在 $HOME 下），不需要会话、不需要 hub；再按一次回来',
           'rows': '面板里的入口（选中 ↵，或直接打字）：'},
    'en': {'where': 'Where', 'press': 'Press', 'mac': 'iTerm2 on a Mac', 'phone': 'A phone (Termius) or another terminal',
           'or': ' or ', 'then': 'then', 'key': 'Key', 'does': 'What it does', 'nokey': '—',
           'action': 'Name', 'mac_x': 'On a Mac (⌘)', 'phone_x': 'On a phone (⌃] then)', 'space': 'Space',
           'home': 'From any screen: the home machine\'s command line ($HOME), no session or hub needed; again to come back',
           'rows': 'Rows of the panel (pick one, ↵ — or type its name): '},
}
_GEN_CACHE = {}

def _gen_inputs():
    if 'keys' not in _GEN_CACHE:
        sys.path.insert(0, os.path.join(REPO, 'bin'))
        import fleet_keys
        view = subprocess.run(['bash', os.path.join(REPO, 'bin', 'dash-keymap.sh'), '--panel', 'switch', 'view'],
                              capture_output=True, text=True).stdout
        letters = dict(l.split()[:2] for l in view.splitlines() if len(l.split()) >= 2)
        _GEN_CACHE['keys'] = (fleet_keys, letters)
    return _GEN_CACHE['keys']

def _keymap_rows():
    return subprocess.run(['bash', os.path.join(REPO, 'bin', 'dash-keymap.sh'), '--panel', 'switch', 'list'],
                          capture_output=True, text=True).stdout.splitlines()

def _ui(lang):
    if lang not in _GEN_CACHE:
        env = dict(os.environ, FLEET_UI_LANG=lang)
        raw = subprocess.run(['bash', os.path.join(REPO, 'bin', 'fleet-ui-lang.sh'), 'dump', 'view_keys', 'keys_switch_',
                              'view_cmd_'],
                             capture_output=True, env=env).stdout.decode('utf-8').split('\0')
        _GEN_CACHE[lang] = dict(zip(raw[0::2], raw[1::2]))
    return _GEN_CACHE[lang]

GLYPH_MOD = {'cmd': '⌘', 'command': '⌘', 'ctrl': '⌃', 'control': '⌃', 'alt': '⌥', 'opt': '⌥', 'option': '⌥', 'shift': '⇧'}
GLYPH_KEY = {'down': '↓', 'up': '↑', 'left': '←', 'right': '→', 'return': '↩', 'enter': '↩', 'tab': 'Tab', 'esc': 'Esc'}

def glyph(chord, lang):
    """A fleet_keys chord as a person reads it: cmd+p → ⌘P, ctrl+]p → ⌃] p."""
    if chord.startswith('ctrl+]') and len(chord) > 6:
        return '⌃] ' + glyph(chord[6:], lang)
    parts = chord.split('+')
    mods, key = parts[:-1], parts[-1]
    if key == 'space':
        key = GEN_WORDS[lang]['space']
    elif key in GLYPH_KEY:
        key = GLYPH_KEY[key]
    elif re.match(r'^f[0-9]+$', key):
        key = key.upper()
    elif len(key) == 1:
        key = key.upper() if mods else key
    return ''.join(GLYPH_MOD.get(m, m) for m in mods) + key

KEY_TOKEN = re.compile(r'^([↵↑↓←→?]+|Tab|esc|Esc)$')

def gen_block(name, lang):
    w = GEN_WORDS[lang]
    fk, letters = _gen_inputs()
    ui = _ui(lang)
    code = lambda k: '`%s`' % k
    if name == 'keys':
        phone = w['or'].join(code(glyph(c, lang)) for c in fk.DEFAULT_PHONE.split())
        rows = ['| %s | %s |' % (w['where'], w['press']), '|---|---|',
                '| %s | %s |' % (w['mac'], code(glyph(fk.DEFAULT_PANEL, lang))),
                '| %s | %s |' % (w['phone'], phone), '',
                '| %s | %s |' % (w['key'], w['does']), '|---|---|']
        for item in re.split(r'\s{2,}', ui.get('view_keys', '').strip()):
            head, _, rest = item.partition(' ')
            if KEY_TOKEN.match(head) and rest:
                rows.append('| %s | %s |' % (code(head), rest))
            else:
                rows.append('| %s | %s |' % (w['nokey'], item))
        # T685: every other action is a row of the panel — 新会话 · 命令行 · 退出 fleet;
        # $ 命令行's words are its subtitle on screen (T774), its parenthesis here
        # T923: the words carry no icon — the panel's table (fleet_view.CMD_ICONS) does
        panel_rows = [(icon + ' ' + ui[k]) if ui.get(k) else ''
                      for k, icon in (('view_cmd_blank', '+'), ('view_cmd_home', '$'), ('view_cmd_quit', '⏏'))]
        if panel_rows[1] and ui.get('view_cmd_home_foot'):
            panel_rows[1] += ('（%s）' if lang == 'zh' else ' (%s)') % ui['view_cmd_home_foot']
        rows.append('| %s | %s |' % (w['nokey'], w['rows'] + ' · '.join(r for r in panel_rows if r)))
        return '\n'.join(rows) + '\n'
    if name == 'keys-extra':
        rows = ['| %s | %s | %s | %s |' % (w['action'], w['does'], w['mac_x'], w['phone_x']), '|---|---|---|---|']
        for action, chord, _g, _c in fk.RETIRED:
            desc = ui.get('keys_switch_' + action)
            if not desc or action not in letters:
                continue  # no words, or not a key a phone can take: not offered here
            rows.append('| %s | %s | %s | %s |' % (code(action), desc, code(glyph(chord, lang)),
                                                    code(glyph('ctrl+]' + letters[action], lang))))
        # ⌘\ · ⌃\ (EPIC T651 C3): the home shell — dash-keymap.sh's `home` row, fleet_keys.HOME_CHORD
        mac = next((l.split()[1] for l in _keymap_rows() if l.split()[:1] == ['home']), '')
        rows.append('| %s | %s | %s | %s |' % (code('home'), w['home'],
                                                w['or'].join(code(k) for k in (mac, glyph(fk.HOME_CHORD, lang)) if k),
                                                w['nokey']))
        return '\n'.join(rows) + '\n'
    return None

def fill(text, lang, where):
    def sub(m):
        body = gen_block(m.group(2), lang)
        if body is None:
            errors.append('%s: unknown generated block docs-gen:%s' % (where, m.group(2)))
            return m.group(0)
        return m.group(1) + body + m.group(4)
    return GEN_RE.sub(sub, text)

# ---- build -----------------------------------------------------------------
src = {l: pages(l) for l in LANGS}
errors = []
stale = []
for p in src['en']:
    if p not in src['zh']:
        errors.append('en/%s.md has no Chinese page (zh/%s.md)' % (p, p))
texts, titles = {}, {}
for l in LANGS:
    for p, f in src[l].items():
        t = open(f, encoding='utf-8').read()
        filled = fill(t, l, '%s/%s.md' % (l, p))
        if filled != t:
            stale.append((f, filled))
        texts[(l, p)] = filled
        titles[(l, p)] = title_of(t)
        if not titles[(l, p)]:
            errors.append('%s/%s.md has no "# " title' % (l, p))
# The two languages keep ONE outline (issue #4096): a section the Chinese page
# grew and the English one has not is refused here, not found by a reader.
def outline(text):
    out, infence = [], False
    for line in text.split('\n'):
        if re.match(r'\s*(```|~~~)', line):
            infence = not infence
        elif not infence:
            m = re.match(r'(#{2,6})\s+(.+?)\s*#*\s*$', line)
            if m:
                out.append((len(m.group(1)), m.group(2)))
    return out
for p in sorted(src['en']):
    if p not in src['zh']:
        continue
    zo, eo = outline(texts[('zh', p)]), outline(texts[('en', p)])
    if [h[0] for h in zo] != [h[0] for h in eo]:
        i = next((k for k, (a, b) in enumerate(zip(zo, eo)) if a[0] != b[0]), min(len(zo), len(eo)))
        at = lambda o: '%s %s' % ('#' * o[i][0], o[i][1]) if i < len(o) else '(none)'
        errors.append('%s.md: zh has %d headings, en %d; they part at #%d: zh "%s" / en "%s" '
                      '(the ## … ###### outline must match)' % (p, len(zo), len(eo), i + 1, at(zo), at(eo)))
for p in ('index',) + tuple(r + '/quickstart' for r in READERS):
    if p not in src['zh']:
        errors.append('zh/%s.md is missing (every reader needs a quickstart)' % p)
if errors:
    for e in errors:
        print('docs-build: ' + e, file=sys.stderr)
    sys.exit(1)
if MODE == 'check':
    for f, _ in stale:
        print('docs-build: %s: a generated block is stale — run bin/docs-build.sh --write' % os.path.relpath(f, REPO), file=sys.stderr)
    sys.exit(1 if stale else 0)
if MODE == 'write':
    for f, filled in stale:
        with open(f, 'w', encoding='utf-8') as fh:
            fh.write(filled)
        print('docs-build: wrote %s' % os.path.relpath(f, REPO))
    sys.exit(0)

if os.path.isdir(OUT):
    shutil.rmtree(OUT)
# the hub embeds this directory (tokenledger/hub/web/embed.go): its committed .gitkeep
# keeps that compiling in a checkout that never built the docs (issue #3584)
os.makedirs(OUT)
open(os.path.join(OUT, '.gitkeep'), 'w').close()
# the FAQ as data, off the same faq.md (bin/docs-faq.py is its one reader): faq.json
# beside the page, and the page's FAQPage JSON-LD — the docs are its ONE home (EPIC
# SGS6 C4: the site's front page carries no FAQ of its own)
faq_raw = {}
for l in LANGS:
    if 'faq' in src[l]:
        r = subprocess.run([sys.executable, os.path.join(REPO, 'bin', 'docs-faq.py'), 'json', '--lang', l,
                            '--src', SRC], capture_output=True, text=True)
        if r.returncode != 0:
            print('docs-build: %s/faq.md: %s' % (l, r.stderr.strip()), file=sys.stderr)
            sys.exit(1)
        faq_raw[l] = r.stdout

def faq_ld(l):
    items = json.loads(faq_raw[l])['items']
    ld = {'@context': 'https://schema.org', '@type': 'FAQPage', 'inLanguage': 'zh-CN' if l == 'zh' else 'en',
          'mainEntity': [{'@type': 'Question', 'name': it['q'],
                          'acceptedAnswer': {'@type': 'Answer', 'text': it['a']}} for it in items]}
    return ('<script type="application/ld+json">%s</script>'
            % json.dumps(ld, ensure_ascii=False, separators=(',', ':')).replace('</', '<\\/'))

rows = []
for l in LANGS:
    all_titles = {}
    for p in src['zh']:
        all_titles[p] = titles.get((l, p)) or titles[('zh', p)]
    for p in sorted(src['zh']):
        dest = os.path.join(OUT, l, p)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if (l, p) in texts:
            md, body, state = texts[(l, p)], render(texts[(l, p)]), 'page'
        else:
            zh_url = url_prefix('zh') + ('' if p == 'index' else p)
            md = texts[('zh', p)]
            body = ('<div class="pending">%s <a href="%s">%s</a></div>' % (UI[l]['pending'], zh_url, html.escape(titles[('zh', p)]))
                    + '<h1>%s</h1>' % html.escape(titles[('zh', p)]))
            state = 'pending'
        with open(dest + '.html', 'w', encoding='utf-8') as fh:
            fh.write(frame(l, p, all_titles[p], body, all_titles, state == 'pending',
                           faq_ld(l) if p == 'faq' and state == 'page' and l in faq_raw else ''))
        with open(dest + '.md', 'w', encoding='utf-8') as fh:
            fh.write(md)
        rows.append('%s\t%s\t%s\t%s' % (l, p, all_titles[p], state))
with open(os.path.join(OUT, 'pages.tsv'), 'w', encoding='utf-8') as fh:
    fh.write('\n'.join(rows) + '\n')
for l in LANGS:
    if l in faq_raw:
        with open(os.path.join(OUT, l, 'faq.json'), 'w', encoding='utf-8') as fh:
            fh.write(faq_raw[l])
print('docs-build: %d pages (%d zh, %d en of which %d pending) → %s' % (
    len(rows), len(src['zh']), len(src['zh']), sum(r.endswith('\tpending') for r in rows), OUT))
PY
