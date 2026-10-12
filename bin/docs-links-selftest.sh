#!/bin/bash
# docs-links-selftest.sh — no dead link to a document (issue #3576, EPIC #3569 C6).
#
# The docs moved: docs/ holds only the index (docs/README.md), docs/public/ (for
# readers outside — C5) and docs/dev/ (for the people who build fleet). A move
# like that leaves dead links behind unless something reads every one, so this
# test does, over every tracked file:
#
#   A  a relative Markdown link `](path)` / `](path#anchor)` in a tracked *.md
#      names a file or directory that exists, resolved from that file's dir
#   B  every `docs/dev/<name>` / `docs/public/<name>` a tracked file names
#      (code, comments, skills, CLAUDE.md …) exists, resolved from the repo root
#   C  docs/ itself holds only README.md, dev/ and public/
#   D  the index docs/README.md lists every docs/dev/*.md
#
# A link inside a fenced code block or inline `code` is not a link. URLs,
# mailto: and in-page `#anchor` links are not checked. A line that must keep a
# dead path marks itself `docs-links-ok: <why>`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
git rev-parse --git-dir >/dev/null 2>&1 || { echo "docs-links-selftest: SKIP (not a git checkout)"; exit 0; }

python3 - <<'PY'
import os, re, subprocess, sys

files = subprocess.run(['git', 'ls-files', '-z'], capture_output=True, text=True).stdout.split('\0')
files = [f for f in files if f and os.path.isfile(f)]
bad = []
checked = 0

LINK = re.compile(r'\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)')
FENCE = re.compile(r'^\s*(```|~~~)')
CODESPAN = re.compile(r'`[^`]*`')

def exists(base, target):
    p = os.path.normpath(os.path.join(base, target))
    return os.path.exists(p)

# A — Markdown links
for f in files:
    if not f.endswith('.md'):
        continue
    try:
        lines = open(f, encoding='utf-8').read().split('\n')
    except (UnicodeDecodeError, OSError):
        continue
    infence = False
    for n, line in enumerate(lines, 1):
        if FENCE.match(line):
            infence = not infence
            continue
        if infence or 'docs-links-ok' in line:
            continue
        for m in LINK.finditer(CODESPAN.sub('', line)):
            t = m.group(1)
            if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:', t) or t.startswith('#') or t.startswith('/'):
                continue
            path = t.split('#', 1)[0].split('?', 1)[0]
            if not path or '…' in path or '<' in path or '$' in path:
                continue
            checked += 1
            if not exists(os.path.dirname(f), path):
                bad.append('A %s:%d: dead link %s' % (f, n, t))

# B — every docs/dev/… or docs/public/… a tracked file names
NAMED = re.compile(r'(?<![A-Za-z0-9_./-])((?:\.\./)*docs/(?:dev|public)/[A-Za-z0-9_./-]*[A-Za-z0-9_])')
for f in files:
    if f == 'bin/docs-links-selftest.sh':
        continue
    try:
        text = open(f, encoding='utf-8').read()
    except (UnicodeDecodeError, OSError):
        continue
    if 'docs/' not in text:
        continue
    for n, line in enumerate(text.split('\n'), 1):
        if 'docs-links-ok' in line:
            continue
        for m in NAMED.finditer(line):
            t = m.group(1)
            if t.startswith('../'):
                if f.endswith('.md'):
                    continue                     # a relative Markdown link: leg A's
                t = t.lstrip('./')
            checked += 1
            if not os.path.exists(t):
                bad.append('B %s:%d: names %s, which is not there' % (f, n, t))

# C — what docs/ holds
extra = sorted(e for e in os.listdir('docs') if e not in ('README.md', 'dev', 'public'))
if extra:
    bad.append('C docs/ holds more than README.md, dev/ and public/: %s' % ' '.join(extra))

if not os.path.isfile('docs/README.md'):
    bad.append('C docs/README.md (the index) is missing')
else:
    idx = open('docs/README.md', encoding='utf-8').read()
    for e in sorted(os.listdir('docs/dev')):
        if e.endswith('.md') and '(dev/%s)' % e not in idx:
            bad.append('D docs/README.md does not list dev/%s' % e)

for b in bad:
    print('FAIL ' + b)
if bad:
    print('docs-links-selftest: %d dead of %d checked' % (len(bad), checked))
    sys.exit(1)
print('docs-links-selftest OK (%d links checked, 0 dead)' % checked)
PY
