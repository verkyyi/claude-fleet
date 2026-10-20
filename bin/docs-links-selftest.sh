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
#   E  nothing names the old flat layout `docs/<NAME>.md` (a selftest's or a Go
#      test's fixture tree, and the prose inside docs/dev/ itself, excepted)
#   G  the four places that describe the scripts — docs/dev/COMPONENTS.md,
#      conf/fleet-env-internal.list, docs/dev/BREAK-IT.md, CLAUDE.md — name no
#      script that is gone (EPIC T605 R1): every `bin/<name>` exists (a glob
#      `bin/*lib.sh` matches one; `bin/ccquota` is the release's built binary),
#      every bare `fleet-*.sh|py` / `fleet_*.py` is some tracked file's name. A
#      line that must keep a gone name marks itself `# gone-ok: <why>`. The rule
#      runs on its own red samples first (GONE_RED / GONE_GREEN), so a regex
#      that stops matching reds instead of passing on nothing.
#
# A link inside a fenced code block or inline `code` is not a link. URLs,
# mailto: and in-page `#anchor` links are not checked. A line that must keep a
# dead path marks itself `docs-links-ok: <why>`. tokenledger/ is not read yet:
# its comments move to docs/dev/ in #3659 (a PR touching it runs the 45-minute
# Go jobs, which #3613 could not get through while master kept moving).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
git rev-parse --git-dir >/dev/null 2>&1 || { echo "docs-links-selftest: SKIP (not a git checkout)"; exit 0; }

python3 - <<'PY'
import os, re, subprocess, sys

files = subprocess.run(['git', 'ls-files', '-z'], capture_output=True, text=True).stdout.split('\0')
files = [f for f in files if f and os.path.isfile(f) and not f.startswith('tokenledger/')]  # → #3659
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

# E — the old flat layout, named anywhere
FLAT = re.compile(r'(?<![A-Za-z0-9_-])docs/([A-Z][A-Z0-9_-]*\.md)')
for f in files:
    if f == 'bin/docs-links-selftest.sh' or 'selftest' in f or f.endswith('_test.go'):
        continue
    if f.startswith('docs/dev/'):
        continue        # the moved docs stay byte for byte what they were (prose names, not links)
    try:
        text = open(f, encoding='utf-8').read()
    except (UnicodeDecodeError, OSError):
        continue
    if 'docs/' not in text:
        continue
    for n, line in enumerate(text.split('\n'), 1):
        if 'docs-links-ok' in line:
            continue
        for m in FLAT.finditer(line):
            checked += 1
            if m.group(1) != 'README.md' and not os.path.exists(os.path.join(os.path.dirname(f), m.group(0))):
                bad.append('E %s:%d: names docs/%s — the docs live in docs/dev/ now' % (f, n, m.group(1)))

# G — a script the descriptions name is still there
GONE_FILES = ('docs/dev/COMPONENTS.md', 'conf/fleet-env-internal.list', 'docs/dev/BREAK-IT.md', 'CLAUDE.md')
GONE_BIN = re.compile(r'(?<![A-Za-z0-9_./~$<>-])bin/([A-Za-z0-9_.*-]+(?:/[A-Za-z0-9_.*-]+)*)')
GONE_BARE = re.compile(r'(?<![A-Za-z0-9_./-])(fleet[-_][A-Za-z0-9_-]*\.(?:sh|py))(?![A-Za-z0-9_])')
GONE_BUILT = {'bin/ccquota'}        # built into a release, never tracked
import glob as _glob
tracked_names = {os.path.basename(t) for t in files}

def gone_names(line, have_path, have_name):
    """The gone scripts one line names (empty when it marks itself gone-ok)."""
    if 'gone-ok:' in line:
        return []
    out = []
    for m in GONE_BIN.finditer(line):
        p = 'bin/' + m.group(1).rstrip('.')
        if p in GONE_BUILT or p == 'bin/':
            continue
        if not have_path(p):
            out.append(p)
    for m in GONE_BARE.finditer(line):
        if not have_name(m.group(1)):
            out.append(m.group(1))
    return out

def _have_path(p):
    return bool(_glob.glob(p)) if '*' in p else os.path.exists(p)

GONE_RED = [                         # each must name exactly one gone script
    'runs `bin/fleet-gone-sample.sh` first',
    'FLEET_X   knob: read by fleet-gone-sample.sh (#1)',
    '| row | `fleet_gone_sample.py` keeps it |',
    'every `bin/*gone-sample-lib.sh` file',
]
GONE_GREEN = [                       # each must name none
    'runs `bin/fleet-lib.sh` first, then fleet-mcp.py',
    'the `bin/*lib.sh` functions and `bin/tmux-shim/tmux`',
    '`<current>/bin/ccquota` and `$BIN/../conf`',
    'a historical `bin/fleet-gone-sample.sh` # gone-ok: deleted in #1, kept as the record',
]
for smp in GONE_RED:
    if len(gone_names(smp, _have_path, tracked_names.__contains__)) != 1:
        bad.append('G rule: red sample not caught: %s' % smp)
for smp in GONE_GREEN:
    hit = gone_names(smp, _have_path, tracked_names.__contains__)
    if hit:
        bad.append('G rule: green sample flagged %s: %s' % (' '.join(hit), smp))
for f in GONE_FILES:
    if not os.path.isfile(f):
        bad.append('G %s is missing' % f)
        continue
    for n, line in enumerate(open(f, encoding='utf-8').read().split('\n'), 1):
        for g in gone_names(line, _have_path, tracked_names.__contains__):
            bad.append('G %s:%d: names %s, which is gone — drop it, or mark the line # gone-ok: <why>' % (f, n, g))
        checked += len(GONE_BIN.findall(line)) + len(GONE_BARE.findall(line))

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
