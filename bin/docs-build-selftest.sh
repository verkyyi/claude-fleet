#!/bin/bash
# docs-build-selftest.sh — the public docs build (issue #3575, EPIC #3569 C5).
#
# Builds docs/public/ with bin/docs-build.sh into a sandbox and reads the result:
#
#   A  the build succeeds; every page is HTML + its .md; pages.tsv lists them
#   B  every page has a title (<title> and an <h1>)
#   C  every relative link in every HTML page resolves to a built page or file,
#      read the way the server answers it (/docs/<p> → zh/<p>.html, /en/docs/…)
#   D  the zh and en page sets are the same, and every en page is written — none
#      `pending` (issue #3592); in a sandbox, a zh page with no en source still
#      gets an en page that says 「English version in preparation」 and links to
#      its Chinese page
#   E  each reader has a quickstart: index · self-host/quickstart.md ·
#      hosted/quickstart.md · member/quickstart.md
#   F  no public page links into docs/dev/ (EPIC #3569 共同约定 4)
#   G  the build refuses: an en page with no zh twin, a page with no `# ` title,
#      a zh/en pair whose `##` … `######` outline differs (issue #4096) — a section
#      missing on one side, or one at another level; a `#` line in a code block
#      is not a heading
#   H  generated blocks (issue #3580): the repo's pages are not stale (--check);
#      the build fills `keys` / `keys-extra` from bin/fleet_keys.py's defaults,
#      `dash-keymap.sh --panel switch view` and fleet-ui-lang.sh's view_keys;
#      a changed default key (a sandbox copy of those scripts) reaches the output
#      and makes the old source stale, --write mends it; an unknown block refuses
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
    if '<link rel="icon" href="/favicon.svg" type="image/svg+xml">' not in h:
        bad.append('C %s/%s names no /favicon.svg (the site logo, issue #3946)' % (lang, p))
    # B
    if not re.search(r'<title>[^<]+</title>', h) or not re.search(r'<h1[^>]*>[^<]+</h1>', h):
        bad.append('B %s/%s has no title' % (lang, p))
    # C
    for href in re.findall(r'href="([^"]+)"', h):
        if re.match(r'^[a-z]+:', href) or href.startswith('#'):
            continue
        # the tab icon is the hub's, at its root (issue #3946), not a docs page
        if href in ('/favicon.ico', '/favicon.svg', '/apple-touch-icon.png'):
            continue
        target = resolve(urljoin('http://x' + url_of(lang, p), href))
        if target is None or not os.path.isfile(target):
            bad.append('C %s/%s: dead link %s' % (lang, p, href))
    # D — every page has its English source (issue #3592): translate the zh page
    if state == 'pending':
        bad.append('D en/%s is pending: write docs/public/en/%s.md (terms: docs/public/glossary.tsv)' % (p, p))
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
for d in g3 g4 g5; do
  mk "$d/zh/index.md" "# home"; mk "$d/en/index.md" "# home"
  for r in self-host hosted member; do mk "$d/zh/$r/quickstart.md" "# $r"; done
done
G_ZH='# 安装
## 1. 入口
### 1.1 镜像
```sh
# 代码块里的井号不算标题
```
### 1.2 国内部署
## 2. 机器'
mk g3/zh/self-host/install.md "$G_ZH"
mk g3/en/self-host/install.md '# Install
## 1. The hub
### 1.1 The image
## 2. Machines'
mk g4/zh/self-host/install.md "$G_ZH"
mk g4/en/self-host/install.md '# Install
## 1. The hub
### 1.1 The image
## 1.2 In mainland China
## 2. Machines'
mk g5/zh/self-host/install.md "$G_ZH"
mk g5/en/self-host/install.md '# Install
## 1. The hub
### 1.1 The image
```sh
# a hash in a code block is no heading
```
### 1.2 Deploying in mainland China
## 2. Machines'
if "$BUILD" --src "$T/g3" --out "$T/g3out" >/dev/null 2>"$T/g3.err"; then bad "G an en page missing a section was built"
elif grep -q 'self-host/install.md: zh has 4 headings, en 3' "$T/g3.err" && grep -q '### 1.2 国内部署' "$T/g3.err"; then ok "G en page missing a zh section refused"; else bad "G g3: $(cat "$T/g3.err")"; fi
if "$BUILD" --src "$T/g4" --out "$T/g4out" >/dev/null 2>"$T/g4.err"; then bad "G an en section at another level was built"
elif grep -q 'outline must match' "$T/g4.err"; then ok "G en section at another level refused"; else bad "G g4: $(cat "$T/g4.err")"; fi
if "$BUILD" --src "$T/g5" --out "$T/g5out" >/dev/null 2>"$T/g5.err"; then ok "G matching outlines build (code-block # ignored)"; else bad "G g5: $(cat "$T/g5.err")"; fi

# D — a zh page with no en source still gets an en page, never a 404
mk d1/zh/index.md "# home"
for r in self-host hosted member; do mk "d1/zh/$r/quickstart.md" "# $r"; done
mk d1/zh/faq.md "# 常见问题"
mk d1/en/index.md "# help"
if ! "$BUILD" --src "$T/d1" --out "$T/d1out" >/dev/null 2>"$T/d1.err"; then bad "D sandbox build: $(cat "$T/d1.err")"
elif ! awk -F'\t' '$1 == "en" && $2 == "faq" && $4 == "pending" {f = 1} END {exit !f}' "$T/d1out/pages.tsv"; then bad "D sandbox: en/faq is not pending: $(cat "$T/d1out/pages.tsv")"
elif ! grep -q 'English version in preparation' "$T/d1out/en/faq.html"; then bad "D sandbox: pending en/faq says nothing"
elif ! grep -q 'href="/docs/faq"' "$T/d1out/en/faq.html"; then bad "D sandbox: pending en/faq does not link its Chinese page"
else ok "D a missing en page is built pending, linking its Chinese page"; fi

# H — generated blocks follow the key tables
if "$BUILD" --check >"$T/h0.out" 2>&1; then ok "H docs/public is not stale"; else bad "H stale: $(cat "$T/h0.out")"; fi
HR="$T/hrepo"; mkdir -p "$HR/bin"
for f in docs-build.sh fleet_keys.py dash-keymap.sh fleet-ui-lang.sh; do cp "$ROOT/bin/$f" "$HR/bin/$f"; done
for d in h1 h2; do
  mk "$d/zh/index.md" "# home"
  for r in self-host hosted member; do mk "$d/zh/$r/quickstart.md" "# $r"; done
done
mk h1/zh/member/usage.md "# usage
<!-- docs-gen:keys -->
<!-- /docs-gen:keys -->
<!-- docs-gen:keys-extra -->
<!-- /docs-gen:keys-extra -->"
cp "$T/h1/zh/member/usage.md" "$T/h1.orig"
python3 - "$ROOT" "$BUILD" "$T" <<'PY' || fail=1
import os, subprocess, sys
ROOT, BUILD, T = sys.argv[1:4]
sys.path.insert(0, os.path.join(ROOT, 'bin'))
import fleet_keys
bad = []
def chord(c):  # the defaults' chords as a person reads them
    if c.startswith('ctrl+]'):
        return '⌃] ' + c[6:]
    m, _, k = c.rpartition('+')
    k = {'space': '空格'}.get(k, k.upper())
    return ''.join({'cmd': '⌘', 'ctrl': '⌃'}[x] for x in m.split('+') if x) + k
def build(src, out, build=BUILD, env=None):
    return subprocess.run([build, '--src', src, '--out', out], capture_output=True, text=True, env=env)
if build(os.path.join(T, 'h1'), os.path.join(T, 'h1out')).returncode != 0:
    bad.append('H the build failed on a page with generated blocks')
md = open(os.path.join(T, 'h1out/zh/member/usage.md'), encoding='utf-8').read()
html = open(os.path.join(T, 'h1out/zh/member/usage.html'), encoding='utf-8').read()
want = [chord(fleet_keys.DEFAULT_PANEL)] + [chord(c) for c in fleet_keys.DEFAULT_PHONE.split()]
view = subprocess.run(['bash', os.path.join(ROOT, 'bin/dash-keymap.sh'), '--panel', 'switch', 'view'],
                      capture_output=True, text=True).stdout
letters = dict(l.split()[:2] for l in view.splitlines() if l.strip())
for action, c, g, _ in fleet_keys.FORWARD:
    if action in letters:
        want += ['`%s`' % action, g, '⌃] ' + letters[action]]
words = subprocess.run(['bash', os.path.join(ROOT, 'bin/fleet-ui-lang.sh'), 't', 'view_keys'],
                       capture_output=True, text=True, env=dict(os.environ, FLEET_UI_LANG='zh')).stdout
want += [w.split(' ', 1)[-1] for w in words.split('  ') if w.strip()]
for w in want:
    if w not in md:
        bad.append('H the generated .md lacks %r' % w)
if 'docs-gen' in html or chord(fleet_keys.DEFAULT_PANEL) not in html:
    bad.append('H the generated .html does not carry the key table')
# a changed default key reaches the output, and the old source is stale
hb = os.path.join(T, 'hrepo/bin')
kf = os.path.join(hb, 'fleet_keys.py')
src = open(kf).read().replace('DEFAULT_PANEL = "%s"' % fleet_keys.DEFAULT_PANEL, 'DEFAULT_PANEL = "cmd+k"')
open(kf, 'w').write(src)
hbuild = os.path.join(hb, 'docs-build.sh')
r = subprocess.run([hbuild, '--write', '--src', os.path.join(T, 'h1')], capture_output=True, text=True)
first = open(os.path.join(T, 'h1/zh/member/usage.md'), encoding='utf-8').read()
build(os.path.join(T, 'h1'), os.path.join(T, 'h2out'), build=hbuild)
out = open(os.path.join(T, 'h2out/zh/member/usage.md'), encoding='utf-8').read()
if '`⌘K`' not in out or '`%s`' % chord(fleet_keys.DEFAULT_PANEL) in out.split('docs-gen:keys-extra')[0]:
    bad.append('H a changed default key (cmd+k) did not reach the output')
if subprocess.run([BUILD, '--check', '--src', os.path.join(T, 'h1')], capture_output=True).returncode != 1:
    bad.append('H a source written under another key table is not reported stale')
subprocess.run([BUILD, '--write', '--src', os.path.join(T, 'h1')], capture_output=True)
if subprocess.run([BUILD, '--check', '--src', os.path.join(T, 'h1')], capture_output=True).returncode != 0:
    bad.append('H --write did not mend a stale block')
for b in bad:
    print('FAIL ' + b)
if not bad:
    print('ok   H keys / keys-extra generated; a changed default follows; --check / --write')
sys.exit(1 if bad else 0)
PY
mk h2/zh/member/usage.md "# usage
<!-- docs-gen:nope -->
<!-- /docs-gen:nope -->"
if "$BUILD" --src "$T/h2" --out "$T/h2bad" >/dev/null 2>"$T/h2.err"; then bad "H an unknown generated block was built"
elif grep -q 'unknown generated block' "$T/h2.err"; then ok "H unknown block refused"; else bad "H h2: $(cat "$T/h2.err")"; fi

[ "$fail" = 0 ] && echo "PASS docs-build-selftest" || { echo "FAIL docs-build-selftest"; exit 1; }
