#!/bin/bash
# portability-selftest.sh — the writing-rule lint (T533, EPIC T516 R1): ONE scan,
# ONE rule table, for the shell the fleet ships into a place CI does not run it.
#
# CI is ubuntu (GNU sed, bash 5, dash as sh); the operator's machine is macOS (BSD
# sed, bash 3.2, zsh as the Bash tool's shell). An idiom that one side does
# something ELSE with is green in CI and broken where it matters, and it does so
# silently: #689 (`\|` in a sed BRE — BSD matches it literally, the env scrub was a
# no-op), #703 (a bare empty `${a[@]}` is fatal under bash 3.2's `set -u`), #2727
# (`$x，` — bash 3.2 reads the UTF-8 bytes into the NAME), #1633 (`local path` in
# zsh empties PATH), #414 (`done < <(…)` kills sourcing fleet-lib.sh under sh),
# #2601 (`${v:+\}}` keeps its backslash on bash 3.2), #4668 (a write into the
# read-only install). One finding per line, `file:line: code  why`.
#
# The rule table is RULES below, one row a rule: code · scope (which files) · the
# line marker that excepts a site · the check · why. Every row carries its own red
# samples (BAD, each with the lines it must report) and every GOOD sample must stay
# clean under every row — a lint that matches nothing is a green light for free, and
# one that reds a correct form gets muted. `--table` prints the table and each
# rule's self-check. A rule is added as a row + its samples, nowhere else.
#
# The sed rules are COMMAND-scoped, not line-scoped: a line is split into shell
# segments at unquoted | ; & ( ) { } and backtick, a comment is cut at the first
# unquoted `#` at a word boundary, and only a `sed` segment is checked — BSD grep
# DOES support `\|`, awk's `/^\|---\|/` and `grep -E '\|'` are escaped literals. A
# GNU-only option is exempt inside a both-ways fallback spelled on ONE logical line
# (`stat -f … || stat -c …`): the same utility twice around `||`. A fallback split
# over two lines marks itself `# portable-ok:` (fleet_epoch_from_iso) — no credit
# for a nearby guard, the same reason bare-array gives none to a `${#a[@]}` test.
#
# After the scan, the CLAIMS each rule stands on, checked where the platform has
# them (each SKIPs elsewhere, still exit 0): BSD sed does not alternate on `\|`;
# bash 3.2 dies on a bare empty array and on `$x，`, and every bin/*.sh PARSES
# under it (a `case` in `$(…)` needs `(pat)`); zsh's `local path` loses PATH. Then
# the POSIX libs: each parses under sh and `bash --posix`, and the here-doc loops
# #414 converted give the same answers under sh, bash and dash (a here-doc runs the
# body once on empty input; `IFS=$'\t'` parses under dash but never splits). Then
# the always-run riders: dist-source-selftest.sh (#2776), iso-time-selftest.sh (#2024).
#
# Hermetic: reads files, runs shells on temp fixtures. No network, no live tmux.
set -uo pipefail

BIN=$(cd -- "$(dirname -- "$0")" && pwd)
. "$BIN/selftest-lib.sh"
ROOT=$(cd -- "$BIN/.." && pwd)
CHECKS=0
command -v python3 >/dev/null 2>&1 || st_fail "python3 missing — the scan is python"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/portability-selftest.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# The libs the shared layer keeps sourceable under POSIX sh (#414).
LIBS='fleet-lib.sh fleet-client-core.sh fleet-land-lease.sh usage-lib.sh fleet-daemon-lib.sh'

cat > "$WORK/scan.py" <<'PY'
import os, re, sys
ROOT, LIBS, MODE = sys.argv[1], sys.argv[2].split(), (sys.argv[3] if len(sys.argv) > 3 else 'scan')
SELF = 'portability-selftest.sh'
ID = r'[A-Za-z_][A-Za-z0-9_]*'

class F:
    def __init__(s, path, data):
        s.path, s.memo = path, {}
        s.b = data.split(b'\n'); s.l = data.decode('utf-8', 'replace').split('\n')

def memo(f, key, fn):
    if key not in f.memo: f.memo[key] = fn(f)
    return f.memo[key]

# --- sed / GNU option / brace (command-scoped, over logical lines) -------------
GFLAG = {'readlink': '-f', 'date': '-d', 'stat': '-c', 'base64': '-w', 'mktemp': '-p'}
BRE = ['\\|', '\\+', '\\?', '\\d']
KEYW = set('command builtin exec time nohup ! then else elif do if while until'.split())

def cmdword(seg):
    for w in seg.split():
        if re.match(ID + '=', w) or w in KEYW: continue
        return w.rsplit('/', 1)[-1]
    return ''

def port_line(s, ln, out):
    if 'portable-ok' in s: return
    segs, seg, q, prev, hasor, i, n, cut = [], '', '', '', False, 0, len(s), len(s)
    while i < n:
        c = s[i]
        if q == "'":
            seg += c; q = '' if c == "'" else q; prev = c
        elif q == '"':
            seg += c
            if c == '\\' and i < n - 1: i += 1; seg += s[i]; prev = 'x'
            else:
                if c == '"': q = ''
                prev = c
        elif c == '\\':
            seg += c
            if i < n - 1: i += 1; seg += s[i]
            prev = 'x'
        elif c in '\'"': q = c; seg += c; prev = c
        elif c == '#' and prev in ('', ' ', '\t'): cut = i; break
        elif c in '|;&(){}`':
            if c == '|' and s[i + 1:i + 2] == '|': hasor = True
            segs.append(seg); seg = ''; prev = ''
        else: seg += c; prev = c
        i += 1
    segs.append(seg)
    if re.search(r'\$\{' + ID + r':?[-+=?]\\\}', s[:cut]): out.append((ln, 'brace-esc'))
    cw = [cmdword(x) for x in segs]
    for seg, w in zip(segs, cw):
        t = seg.split()
        if w == 'sed':
            ere = any((re.fullmatch('-[A-Za-z]+', x) and re.search('[Er]', x)) or x.startswith('--regexp-extended') for x in t)
            if not ere: out += [(ln, 'sed-bre') for b in BRE if b in seg]
            out += [(ln, 'sed-i') for x in t if re.fullmatch('-[A-Za-z]*i', x)]
        if w in GFLAG and not (cw.count(w) >= 2 and hasor):
            p = GFLAG[w]
            if any(x.startswith(p) and not re.match('[A-Za-z]', x[len(p):len(p) + 1]) for x in t):
                out.append((ln, 'gnu-opt'))

def port_all(f):
    out, buf, start = [], '', 0
    for n, l in enumerate(f.l, 1):
        if buf == '': start = n
        if l.endswith('\\'): buf += l[:-1] + ' '; continue
        port_line(buf + l, start, out); buf = ''
    if buf: port_line(buf, start, out)
    return out

def port(code):
    return lambda f, h: [(ln, '') for ln, c in memo(f, 'port', port_all) if c == code]

# --- bash 3.2: a bare expansion of an array the file can leave empty ----------
SAFE = [re.compile(r'\$\{' + ID + r'\[[@*]\]:?\+"?\$\{' + ID + r'\[[@*]\]\}"?\}'),
        re.compile(r'\$\{#' + ID + r'\[[@*]\]\}'),
        re.compile(r'\$\{' + ID + r'\[[@*]\]:?[-+][^}]*\}')]
def bare_array(f, h):
    names = set(re.findall('(' + ID + r')=\([ \t]*\)', '\n'.join(f.l)))
    for l in f.l:
        if re.search(r'(^|[^A-Za-z0-9_])(read|mapfile|readarray)([^A-Za-z0-9_]|$)', l):
            names |= set(re.findall(r'-a[ \t]+(' + ID + ')', l))
        names |= set(re.findall(r'(?:mapfile|readarray)(?:[ \t]+-[A-Za-z][^ \t]*)*[ \t]+(' + ID + ')', l))
    out = []
    for n, l in enumerate(f.l if names else [], 1):
        if h in l or re.match(r'\s*#', l): continue
        for rx in SAFE: l = rx.sub('', l)
        out += [(n, nm) for nm in sorted(set(re.findall(r'\$\{(' + ID + r')\[[@*]\]\}', l))) if nm in names]
    return out

# --- bash 3.2 + UTF-8: `$x，` reads the bytes into the name -------------------
def utf8_name(f, h):
    out = []
    for n, l in enumerate(f.b, 1):
        if h.encode() in l or re.match(rb'\s*#', l): continue
        if re.search(rb'\$[A-Za-z_][A-Za-z0-9_]*[^ -~\s]', l.replace(b'\\$', b'')): out.append((n, ''))
    return out

# --- zsh: a local named like a special parameter --------------------------------
ZSH = set('''path fpath cdpath manpath mailpath module_path psvar fignore watch argv status
pipestatus options prompt histchars signals commands functions aliases galiases saliases
dis_aliases dis_functions builtins reswords parameters modules history historywords jobstates
jobtexts jobdirs dirstack userdirs nameddirs mapfile sysparams errnos termcap terminfo widgets
keymaps patchars funcstack functrace funcfiletrace funcsourcetrace zsh_eval_context'''.split())
DECL = re.compile(r'(?:^|[;&|{(]|\bthen|\bdo|\belse)\s*(local|typeset|declare|readonly)\s+(.*)')
def zsh_special(f, h):
    out = []
    for n, raw in enumerate(f.l, 1):
        if h in raw or raw.lstrip().startswith('#'): continue
        s = re.sub(r'"(?:[^"\\]|\\.)*"', '""', re.sub(r"'[^']*'", "''", re.sub(r'\$\([^()]*\)', ' ', raw)))
        for m in DECL.finditer(s):
            for tok in re.split(r'[;&|)#]', m.group(2), maxsplit=1)[0].split():
                nm = re.match(ID, tok)
                if not tok.startswith('-') and nm and nm.group(0) in ZSH: out.append((n, nm.group(0)))
    return out

# --- the install is read-only (#4668) -------------------------------------------
NAMES = r'(?:logs|epic-pages)\b'
RO = [('install-logs', re.compile(r'(?:\$\{?(?:BIN|BIN_DIR|ROOT|HERE)\}?|\$\(dirname "?\$0"?\))/(?:\.\./)?' + NAMES)),
      ('install-logs', re.compile(r'\.claude/fleet/' + NAMES)),
      ('install-logs', re.compile(r'\b(?:BIN|HERE|ROOT)\.parent\s*/\s*[\'"]' + NAMES)),
      ('install-logs', re.compile(r'[\'"]\.\.[\'"]\s*,\s*[\'"]' + NAMES)),
      ('install-logs', re.compile(r'dirname\((?:BIN|HERE)\)\s*,\s*[\'"]' + NAMES)),
      ('install-write', re.compile(r'(?:>>?|\bmkdir(?:\s+-p)?|\btouch|\btee(?:\s+-a)?)\s+"?(?:\$\{?BIN\}?|\$\(dirname "?\$0"?\))/\.\./'))]
def ro_all(f):
    out = []
    for n, l in enumerate(f.l, 1):
        t = l.lstrip()
        if t.startswith('#') or t.startswith('//') or 'install-write-ok:' in l: continue
        hit = next((c for c, rx in RO if rx.search(l)), None)
        if hit: out.append((n, hit, t[:120]))
    return out
def ro(code):
    return lambda f, h: [(n, d) for n, c, d in memo(f, 'ro', ro_all) if c == code]

def proc_subst(f, h):
    return [(n, '') for n, l in enumerate(f.l, 1) if h not in l and re.search(r'done\s*<\s*<\(', l)]

# --- THE TABLE: one row a rule -------------------------------------------------
RULES = [  # code, scope, marker that excepts a line, check, why
 ('sed-bre',       'sh',  'portable-ok:',      port('sed-bre'), r'\| \+ \? in a sed BRE are GNU-only (BSD reads them literally, silently — #689), \d is a digit in no sed: two -e, sed -E, or [0-9]'),
 ('sed-i',         'sh',  'portable-ok:',      port('sed-i'),   'sed -i with no ATTACHED suffix: GNU -i.bak, BSD -i \'\' — only -i.bak (or a temp file + mv) is portable'),
 ('gnu-opt',       'sh',  'portable-ok:',      port('gnu-opt'), 'readlink -f / date -d / stat -c / base64 -w / mktemp -p are GNU-only: a `bsd … || gnu …` fallback on ONE line'),
 ('brace-esc',     'sh',  'portable-ok:',      port('brace-esc'), r'${v:+\}} keeps its backslash on bash 3.2 inside "…" — put the } in a variable (#2601)'),
 ('bare-array',    'bin', 'bash32-ok:',        bare_array,      'a bare ${a[@]} / ${a[*]} of an array the file can leave empty is fatal under bash 3.2 set -u — ${a[@]+"${a[@]}"} or "${a[*]-}" (#703)'),
 ('utf8-name',     'bin', 'bash32-ok:',        utf8_name,       '$name glued to a non-ASCII byte: bash 3.2 + UTF-8 reads it into the name — write ${name} (#2727)'),
 ('zsh-special',   'bin', 'zsh-ok:',           zsh_special,     'a local/typeset/declare names a zsh special parameter (path, argv, status …): zsh runs fleet-lib.sh in the Bash tool — rename it (#1633)'),
 ('proc-subst',    'lib', 'portable-ok:',      proc_subst,      'done < <(cmd) is a syntax error under POSIX sh, which sources these libs — a here-doc (#414)'),
 ('install-logs',  'ro',  'install-write-ok:', ro('install-logs'),  "a path into the install's logs/ or epic-pages/ — records are $FLEET_CONF_DIR/logs (#4668)"),
 ('install-write', 'ro',  'install-write-ok:', ro('install-write'), 'a write aimed at $BIN/.. — the install is read-only (#4668)'),
]

# --- each rule's red samples: (text, the lines it must report) -------------------
BAD = {
 'sed-bre': [("#!/bin/sh\nenv | sed -n -e 's/^\\(FLEET_[A-Za-z0-9_]*\\)=.*\\|^\\(CCQUOTA_[A-Za-z0-9_]*\\)=.*/\\1/p'\n", [2]),
             ("#!/bin/sh\nprintf '%s' \"$1\" | sed 's/[0-9]\\+//'\n", [2]),
             ("#!/bin/sh\nprintf '%s' \"$1\" | sed 's/colou\\?r/color/'\n", [2]),
             ("#!/bin/sh\nprintf '%s' \"$1\" | sed 's/\\d//g'\n", [2]),
             ("#!/bin/sh\necho hi\nenv | sed -n \\\n  -e 's/^a.*\\|^b.*/x/p'\n", [3])],   # reported where the command STARTS
 'sed-i': [("#!/bin/sh\nsed -i 's/a/b/' \"$1\"\n", [2])],
 'gnu-opt': [("#!/bin/sh\nm=$(stat -c %Y \"$1\")\n", [2]),
             ("#!/bin/sh\nwhen=$(date -d \"@$1\" '+%H:%M')\n", [2]),
             ("#!/bin/sh\nroot=$(readlink -f \"$1\")\nb=$(printf '%s' \"$1\" | base64 -w 0)\nd=$(mktemp -p /tmp)\n", [2, 3, 4]),
             # the || exemption is ONE logical line: a fallback split over two still reds
             ("#!/bin/sh\niso2epoch() {\n  date -u -d \"$1\" +%s 2>/dev/null && return 0\n  TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' \"$1\" +%s 2>/dev/null\n}\n", [3])],
 'brace-esc': [('#!/bin/bash\nf="#{?a,,#{window_name}${W:+\\}}}"\n', [2])],
 'bare-array': [('#!/bin/bash\na=()\nfor x in "${a[@]}"; do :; done\n', [3]),
                ("#!/bin/bash\nKEYS=()\nprintf 'got: %s\\n' \"${KEYS[*]}\"\n", [3]),
                ("#!/bin/bash\nread -r -a idxs <<< \"$1\"\nprintf '%s\\n' \"${idxs[@]}\"\n", [3])],
 'utf8-name': [('#!/bin/bash\n# a comment: $x，\necho "$y，"\necho "\\$z，"\necho "${w}，"\necho "$v，"  # bash32-ok: fixture\necho "$u ，" "$t→"\n', [3, 7])],
 'zsh-special': [('  local o iss owt path k pre\n  local sess="$1" conf repo path="$x"\n  local rule="$1" argv="$7" action="$8"\n'
                  '  local status="$1" limit="$2" waited=0\n  typeset -a path\n  x=1; declare options=()\n  if :; then local aliases=x; fi\n', [1, 2, 3, 4, 5, 6, 7])],
 'proc-subst': [('f() {\n  while read -r x; do :; done < <(ls)\n}\n', [2])],
 'install-logs': [('#!/bin/sh\nLOG="$BIN/../logs/x.log"\nmkdir -p "$ROOT/logs"\n', [2, 3]),
                  ('LOG = BIN.parent / "logs" / "x.log"\nP = os.path.join(os.path.dirname(__file__), "..", "logs", "y")\n', [1, 2])],
 'install-write': [('#!/bin/sh\necho hi >> "$(dirname "$0")/../state"\n', [2])],
}
# the false-positive traps: real shapes from this repo, clean under EVERY rule
GOOD = [
 r'''#!/bin/sh
# A comment that talks about sed and `\|` at length, and mentions sed -i and stat -c too.
grep -q 'RUNSHELL\|KILL' "$1" && echo hit            # BSD grep DOES support \|
grep -Eq 'command -v fzf[^|]*\|\|' "$1" && echo hit  # escaped literal pipe in an ERE
awk -F'|' '$0 !~ /^\|---\|/ && NF != 6 { print NR }' "$1"
printf 'a\n' | sed -E 's/foo|bar/X/'
printf 'a\n' | sed -e 's/foo/X/' -e 's/bar/X/'
sed -i.bak 's/a/b/' "$1"
mt() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
ts() { date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M' 2>/dev/null; }
m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo '')
for c in $(pgrep -P "$$" 2>/dev/null); do echo "$c"; done
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
_WTEND='}'; f="#{?a,,#{window_name}${_WTEND}}"   # bash 3.2 keeps ${v:+\}}'s backslash
m=$(stat -c %Y "$1")   # portable-ok: GNU-only path, guarded by a uname check above
''',
 '''#!/bin/bash
a=(); b=()
for x in ${a[@]+"${a[@]}"}; do :; done
[ "${#a[@]}" -gt 0 ] && printf '%s' "${b[@]:+"${b[@]}"}"
printf 'joined: %s\\n' "${a[*]-}"
cmd=(tmux -L sock)
"${cmd[@]}" list-windows
c=()
c+=(x)
for x in "${c[@]}"; do :; done   # bash32-ok: c is unconditionally appended to above
''',
 '''  local o iss owt pth k pre
  local msg="path status argv"
  local dirty; dirty=$(git -C "$wt" status --porcelain)
  local out=$(git status --short)
  # local path is what broke #1633
  local pth  # not path
  local path  # zsh-ok: fixture
  local paths path_x my_path statuses argv0
                local[m.group(1)] = 1
  while read -r x; do :; done <<EOF
EOF
''',
 '''#!/bin/sh
# the old $BIN/../logs is gone — a comment may say so
LOG="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/logs/x.log"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
mkdir -p "$ROOT/logs"   # install-write-ok: a fixture that says why
''',
]

def self_check():
    bad = []
    for code, _, hatch, chk, _ in RULES:
        if not BAD.get(code): bad.append('%s: no red sample' % code); continue
        for k, (text, want) in enumerate(BAD[code], 1):
            got = sorted(ln for ln, _ in chk(F('<%s#%d>' % (code, k), text.encode()), hatch))
            if got != want: bad.append('%s#%d: want lines %s, got %s' % (code, k, want, got))
        for k, text in enumerate(GOOD, 1):
            got = chk(F('<good#%d>' % k, text.encode()), hatch)
            if got: bad.append('%s: reds GOOD sample %d at %s' % (code, k, [ln for ln, _ in got]))
    return bad

def walk(dirs, exts):
    for d in dirs:
        for dp, _, fn in os.walk(os.path.join(ROOT, d), followlinks=True):
            for x in sorted(fn):
                if x.endswith(exts): yield os.path.join(dp, x)
def bin_shell():
    b = os.path.join(ROOT, 'bin')
    for x in sorted(os.listdir(b)):
        p = os.path.join(b, x)
        if not os.path.isfile(p): continue
        if x.endswith('.sh'): yield p
        elif '.' not in x:
            with open(p, 'rb') as fh:
                if re.match(rb'#!.*[/ ](ba)?sh(\s|$)', fh.readline()): yield p
SCOPES = {
 'sh':  lambda: [p for p in walk(['bin', 'hooks', 'shell', 'extras'], ('.sh', '.zsh')) if os.path.basename(p) != SELF],
 'bin': lambda: [p for p in bin_shell() if os.path.basename(p) != SELF],
 'lib': lambda: [os.path.join(ROOT, 'bin', x) for x in LIBS],
 'ro':  lambda: [p for p in walk(['bin', 'hooks', 'launchd', 'systemd'], ('.sh', '.py', '.tmpl', '.service', '.ts'))
                 if '-selftest' not in os.path.basename(p)],
}

sc = self_check()
if MODE == '--table':
    for code, scope, hatch, _, why in RULES:
        print('%-14s %-4s %-18s %s' % (code, scope, '# ' + hatch, why))
    print()
    for code, *_ in RULES:
        print('self-check %-14s %d red sample(s) red, %d good sample(s) clean' % (code, len(BAD.get(code, [])), len(GOOD)))
if sc:
    print('\n'.join('SELF-CHECK FAIL ' + x for x in sc)); sys.exit(2)
files, cache, hits = {}, {}, []
for code, scope, hatch, chk, why in RULES:
    if scope not in files: files[scope] = SCOPES[scope]()
    for p in files[scope]:
        if p not in cache:
            with open(p, 'rb') as fh: cache[p] = F(p, fh.read())
        for ln, det in chk(cache[p], hatch):
            hits.append('%s:%d: %s  %s%s' % (os.path.relpath(p, ROOT), ln, code, why, (' [%s]' % det) if det else ''))
if not files['lib'] or not files['sh']: print('SCAN: found nothing to scan under %s' % ROOT); sys.exit(2)
print('\n'.join(hits))
print('scan: %d rules, %d files' % (len(RULES), len(cache)), file=sys.stderr)
sys.exit(1 if hits else 0)
PY

if [ "${1:-}" = --table ]; then python3 "$WORK/scan.py" "$ROOT" "$LIBS" --table; exit; fi

# ============================================================================
# THE SCAN — every rule over its files, after its own self-check
# ============================================================================
out=$(python3 "$WORK/scan.py" "$ROOT" "$LIBS" 2>"$WORK/scan.err"); rc=$?
st_count; [ "$rc" = 0 ] || st_fail "$(cat "$WORK/scan.err")
$out
(a deliberate site marks its line with the rule's marker — \`$0 --table\` lists them)"
SCANNED=$(sed -n 's/^scan: //p' "$WORK/scan.err")

# ============================================================================
# THE CLAIMS — each rule's premise, where the platform has it
# ============================================================================
if sed --version 2>/dev/null | head -1 | grep -q GNU; then
  printf 'portability-selftest: GNU sed here — the BSD sed claim skipped\n' >&2
else
  st_count; [ "$(printf 'foo\n' | sed 's/foo\|bar/X/' 2>/dev/null)" = foo ] || st_fail "this sed ALTERNATED on \`\\|\` in a BRE — sed-bre's premise needs re-checking"
  st_count; [ "$(printf 'foo\n' | sed -e 's/foo/X/' -e 's/bar/X/')" = X ] || st_fail "the two-expression form did not substitute"
  st_count; [ "$(printf 'foo\n' | sed -E 's/foo|bar/X/')" = X ] || st_fail "sed -E did not alternate — the ERE escape is wrong here"
fi

B32=""
for c in /bin/bash bash3.2 bash; do
  command -v "$c" >/dev/null 2>&1 || continue
  case "$("$c" --version 2>/dev/null | head -1)" in *"version 3."*) B32="$c"; break ;; esac
done
if [ -n "$B32" ]; then
  st_count; "$B32" -c 'set -u; a=(); for x in "${a[@]}"; do :; done' 2>/dev/null && st_fail "bash 3.2 accepted a bare empty \${a[@]} — bare-array's premise is gone"
  st_count; "$B32" -c 'set -u; a=(); printf "%s" "${a[*]}"' 2>/dev/null && st_fail "bash 3.2 accepted a bare empty \${a[*]}"
  st_count; "$B32" -c 'set -u; a=(); for x in ${a[@]+"${a[@]}"}; do :; done; [ "${#a[@]}" = 0 ]; printf "%s" "${a[*]-}"' || st_fail "bash 3.2 rejected a form bare-array calls safe"
  st_count; [ "$("$B32" -c 'set -u; a=(p "q r"); printf "[%s]" ${a[@]+"${a[@]}"}')" = '[p][q r]' ] || st_fail "\${a[@]+\"\${a[@]}\"} lost the element split on bash 3.2"
  for l in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
    [ "$(LC_ALL=$l "$B32" -c 'printf %s "${#1}"' _ '，' 2>/dev/null)" = 1 ] || continue
    st_count; LC_ALL=$l "$B32" -c 'set -u; x=1; printf "%s" "$x，"' >/dev/null 2>&1 && st_fail "bash 3.2 ($l) read \$x， as \$x — utf8-name's premise is gone"
    st_count; [ "$(LC_ALL=$l "$B32" -c 'set -u; x=1; printf "%s" "${x}，"')" = '1，' ] || st_fail "bash 3.2 ($l) mangled \${x}，"
    break
  done
  bad=$(for f in "$BIN"/*.sh; do "$B32" -n "$f" 2>/dev/null || printf '%s\n' "${f##*/}"; done)
  st_count; [ -z "$bad" ] || st_fail "does not parse under bash 3.2 ($B32), the operator's shell:
$bad
(\`$B32 -n bin/<name>\` for the message; a \`case\` inside \`\$(...)\` writes its pattern \`(pat)\`)"
else
  printf 'portability-selftest: no bash 3.x here — the bash 3.2 claims skipped\n' >&2
fi

if command -v zsh >/dev/null 2>&1; then
  got=$(zsh -fc 'f() { local path; command -v ls >/dev/null && echo found || echo lost; }; f' 2>/dev/null)
  st_count; [ "$got" = lost ] || st_fail "zsh 'local path' was expected to lose PATH, got [$got]"
  got=$(zsh -fc 'f() { local pth; command -v ls >/dev/null && echo found || echo lost; }; f' 2>/dev/null)
  st_count; [ "$got" = found ] || st_fail "zsh 'local pth' should keep PATH, got [$got]"
  got=$(cd "$WORK" && zsh -fc ". '$BIN/fleet-lib.sh'" 2>/dev/null)
  st_count; [ -z "$got" ] || st_fail "sourcing fleet-lib.sh under zsh printed [$got]"
else
  printf 'portability-selftest: no zsh here — the zsh claims skipped\n' >&2
fi

# ============================================================================
# THE POSIX LIBS (#414) — parse under sh and bash --posix; same answers everywhere
# ============================================================================
have_bash=0; command -v bash >/dev/null 2>&1 && have_bash=1
have_dash=0; command -v dash >/dev/null 2>&1 && have_dash=1
for lib in $LIBS; do
  f="$BIN/$lib"; [ -f "$f" ] || st_fail "guarded lib missing: $f"
  st_count; sh -n "$f" 2>/dev/null || st_fail "sh -n rejected $lib (a bashism): $(sh -n "$f" 2>&1 | head -3)"
  if [ "$have_bash" = 1 ]; then
    st_count; bash --posix -n "$f" 2>/dev/null || st_fail "bash --posix -n rejected $lib: $(bash --posix -n "$f" 2>&1 | head -3)"
  fi
done

. "$BIN/selftest-repo-fixture.sh"
LIB="$BIN/fleet-lib.sh"
export FLEET_SKIP_GLOBAL_CONF=1
# a fake tmux: has-session (down iff the label is in FAKE_DOWN) + list-windows; an
# EMPTY label to list-windows is the spurious here-doc pass — a sentinel says so
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<'TMUXFAKE'
#!/bin/sh
label=""
case "${1:-}" in -L|-S) label="$2"; shift 2 ;; esac
case "${1:-}" in
  has-session) for d in ${FAKE_DOWN:-}; do [ "$d" = "$label" ] && exit 1; done; exit 0 ;;
  list-windows) [ -z "$label" ] && { printf 'EMPTYLABEL\n'; exit 0; }; printf 'win@%s\n' "$label" ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"; export PATH
# every_sh <desc> <expected> <snippet> — the same answer under sh, bash and dash
# ($0 = the lib's path: dash has no BASH_SOURCE, fleet-lib finds its core by it)
every_sh() {
  for s in sh bash dash; do
    case $s in bash) [ "$have_bash" = 1 ] || continue ;; dash) [ "$have_dash" = 1 ] || continue ;; esac
    o=$("$s" -c ". \"$LIB\"; $3" "$LIB" 2>/dev/null)
    st_count; [ "$o" = "$2" ] || st_fail "$1 [$s]: expected [$2] got [$o]"
  done
}
CR="$WORK/conf-repo"; mkdir -p "$CR/fleets/fleet-a"; : > "$CR/fleets/fleet-a/conf"; fx_repo "$CR" fleet-a acme/new
CS="$WORK/conf-sock"; mkdir -p "$CS"; : > "$CS/s1.conf"; : > "$CS/s2.conf"; : > "$CS/s3.conf"
CE="$WORK/conf-empty"; mkdir -p "$CE"
every_sh "sess_for_repo: match" fleet-a "FLEET_CONF_DIR='$CR'; fleet_sess_for_repo acme/new"
every_sh "sess_for_repo: miss" "" "FLEET_CONF_DIR='$CR'; fleet_sess_for_repo acme/nope"
every_sh "sess_for_repo: empty conf dir (no spurious pass)" "" "FLEET_CONF_DIR='$CE'; fleet_sess_for_repo acme/new"
every_sh "sockets: s3 down" "s1,s2," "FLEET_CONF_DIR='$CS'; export FAKE_DOWN=s3; fleet_sockets | sort | tr '\n' ','"
every_sh "sockets: empty conf dir" "" "FLEET_CONF_DIR='$CE'; fleet_sockets | tr '\n' ','"
every_sh "list_windows_all: fan-out" "win@s1,win@s2,win@s3," "FLEET_CONF_DIR='$CS'; fleet_list_windows_all '#{x}' | sort | tr '\n' ','"
every_sh "list_windows_all: empty conf dir, no EMPTYLABEL" "" "FLEET_CONF_DIR='$CE'; fleet_list_windows_all '#{x}' | tr '\n' ','"
if command -v git >/dev/null 2>&1; then
  R="$WORK/repo"; git init -q "$R"
  git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  BR=$(git -C "$R" rev-parse --abbrev-ref HEAD); MAIN_SHA=$(git -C "$R" rev-parse HEAD)
  git -C "$R" -c user.email=t@t -c user.name=t worktree add -q -b feat "$WORK/wt-feat" >/dev/null 2>&1
  every_sh "worktree_head: main branch" "$MAIN_SHA" "fleet_worktree_head '$R' '$BR' | cut -f2"
  every_sh "worktree_head: the linked worktree's own record" "$(git -C "$R" rev-parse feat)" "fleet_worktree_head '$R' feat | cut -f2"
  every_sh "worktree_head: unknown branch" "" "fleet_worktree_head '$R' no-such-branch"
fi

# ============================================================================
# THE RIDERS — whole-tree lints no filename rule can select
# ============================================================================
st_count; o=$(bash "$BIN/dist-source-selftest.sh" 2>&1) || st_fail "dist-source: $o"
st_count; o=$(bash "$BIN/iso-time-selftest.sh" 2>&1) || st_fail "iso-time: $o"

printf 'portability-selftest: OK (%d checks; %s)\n' "$CHECKS" "${SCANNED:-scan}"
