#!/bin/bash
# gone-selftest.sh — what was deleted stays deleted: ONE list, ONE scan (T537, EPIC T516 R3).
#
# conf/gone.list names every file, function, setting and word the fleet deleted on
# purpose, with the ticket that deleted it. This test reads the list and reds on any
# of them back in the tree. A PR that deletes a feature adds its lines; a PR that
# brings one back on purpose deletes the line, and says why.
#
# The kinds (conf/gone.list's header has the format):
#   path  <p>     no file or directory at <p> (relative to the repo root)
#   func  <name>  no definition of <name> in code: sh `name()` / `function name`,
#                 python `def name(`, go `func name(` / `func (r T) name(`,
#                 ts/js `function name` · `const name =`
#   word  <tok>   <tok> on no CODE line: whole word (a `-` or `_` beside it is part
#                 of another word), comment lines and prose (*.md, docs/) skipped
#   key   <NAME>  a word, and not a key of conf/fleet.conf.reference
#   text  <s>     the literal <s> on no code line (no word boundary)
#   re    <rx>    the python regex <rx> on no code line (a space is `\s` or `[ ]`)
# An optional 4th field narrows any but a path to path prefixes, comma-separated
# (`bin/`, `conf/tmux-attention.conf,conf/tmux-bar.conf`); the default is the tree.
#
# Never scanned: selftests (`*selftest*`: a test spells the gone thing to prove it
# stays gone), conf/gone.list itself, built output (dist/, pack/, node_modules/),
# docs/, and prose (*.md, *.html …) unless a scope names it — a prompt's or a page's
# retired wording is listed by its file. A comment line (`#`, `//`, `*` …) is never
# a hit, but in prose `#` is a heading and counts. A code line may keep a gone word
# with `gone-ok: <why>` on it.
#
# Before the scan the scanner proves itself: each kind runs on a red sample tree
# that must red and a good one that must stay clean (as portability-selftest.sh's
# rule table does — that one scans HOW code is written; this one WHAT must not be in
# it). `--list` prints the list as the scanner reads it.
#
# Usage: gone-selftest.sh [--list]
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$BIN/.."
LIST="${GONE_LIST:-$ROOT/conf/gone.list}"
[ -f "$LIST" ] || { echo "gone FAIL: no list at $LIST" >&2; exit 1; }

exec python3 - "$ROOT" "$LIST" "${1:-}" <<'PY'
import os, re, subprocess, sys, tempfile

root, listfile, mode = sys.argv[1], sys.argv[2], sys.argv[3]
KINDS = ("path", "func", "word", "key", "text", "re")
SKIP_DIRS = {".git", "node_modules", "dist", "pack", "docs", "__pycache__", ".venv", "vendor"}
PROSE = (".md", ".txt", ".html", ".svg", ".png", ".jpg", ".ico", ".woff", ".woff2", ".lock", ".sum")
COMMENT = re.compile(r"^\s*(#|//|/\*|\*|--|;)")

def read_list(path):
    rows, bad = [], []
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        f = s.split()
        if len(f) not in (3, 4) or f[0] not in KINDS or not re.match(r"^(#\d+|T\d+)$", f[2]):
            bad.append("%s:%d: want '<kind> <thing> <#issue|T<n>> [<scope>]': %s" % (os.path.basename(path), n, line.rstrip()))
            continue
        if f[0] == "re":
            try:
                re.compile(f[1])
            except re.error as e:
                bad.append("%s:%d: not a regex (%s): %s" % (os.path.basename(path), n, e, f[1]))
                continue
        rows.append({"n": n, "kind": f[0], "thing": f[1], "ticket": f[2], "scope": f[3] if len(f) > 3 else ""})
    return rows, bad

def tree(top):
    """Every file to scan, relative to top: git's list when there is one, else a walk."""
    try:
        out = subprocess.run(["git", "-C", top, "ls-files", "-z"], capture_output=True, check=True).stdout
        files = [p for p in out.decode("utf-8", "replace").split("\0") if p]
    except Exception:
        files = []
    if not files:
        for d, dirs, names in os.walk(top, followlinks=True):
            dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
            rel = os.path.relpath(d, top)
            files += [os.path.normpath(os.path.join(rel, x)) for x in names]
    keep = []
    for p in files:
        parts = p.split("/")
        if any(x in SKIP_DIRS for x in parts[:-1]):
            continue
        b = parts[-1]
        if "selftest" in b or p == "conf/gone.list":
            continue
        keep.append(p)
    return keep

def func_re(name):
    q = re.escape(name)
    return re.compile(r"^\s*(?:function\s+%s\b|%s\s*\(\)|(?:async\s+)?def\s+%s\s*\(|func\s+(?:\([^)]*\)\s*)?%s\s*\(|(?:export\s+)?(?:async\s+)?function\*?\s+%s\b|(?:export\s+)?(?:const|let|var)\s+%s\s*=)" % (q, q, q, q, q, q))

def word_re(tok):
    return re.compile(r"(?<![A-Za-z0-9_\-])%s(?![A-Za-z0-9_])" % re.escape(tok))

def scan(top, rows):
    found = []
    files = None
    texts = {}
    def text(p):
        if p not in texts:
            try:
                with open(os.path.join(top, p), encoding="utf-8") as fh:
                    texts[p] = fh.read().splitlines()
            except (OSError, UnicodeDecodeError):
                texts[p] = []
        return texts[p]
    ref = os.path.join(top, "conf/fleet.conf.reference")
    reftext = open(ref, encoding="utf-8").read() if os.path.isfile(ref) else ""
    for r in rows:
        k, t = r["kind"], r["thing"]
        if k == "path":
            if os.path.lexists(os.path.join(top, t)):
                found.append((r, t, 0, "exists"))
            continue
        if files is None:
            files = tree(top)
        rx = {"func": func_re, "text": lambda x: re.compile(re.escape(x)), "re": re.compile}.get(k, word_re)(t)
        scopes = [x for x in r["scope"].split(",") if x]
        for p in (files if scopes else [f for f in files if not f.endswith(PROSE)]):
            if scopes and not any(p.startswith(x) for x in scopes):
                continue
            prose = p.endswith(PROSE)
            for i, line in enumerate(text(p), 1):
                if k != "func" and not prose and COMMENT.match(line):
                    continue
                if "gone-ok:" in line or not rx.search(line):
                    continue
                found.append((r, p, i, line.strip()[:120]))
        if k == "key" and re.search(r"(?m)^#?\s*%s=" % re.escape(t), reftext):
            found.append((r, "conf/fleet.conf.reference", 0, "a key of the reference"))
    return found

# --- self-check: each kind reds on its red sample and passes on its good one ---
SAMPLES = {
    "path": ({"bin/old-thing.sh": "echo\n"}, {"bin/new-thing.sh": "echo\n"}),
    "func": ({"bin/a.sh": "old_thing() { :; }\n", "bin/b.py": "def old_thing(x):\n", "x/c.go": "func (s *S) old_thing(a int) {\n", "x/d.ts": "export function old_thing() {}\n"},
             {"bin/a.sh": "# old_thing() was here\nold_thing_two() { :; }\ncall old_thing\n"}),
    "word": ({"bin/a.sh": "x=$(old_thing --go)\n", "bin/b.py": "run('old_thing')\n"},
             {"bin/a.sh": "# old_thing went with #1\nnew-old_thing\nold_thing_x\nold_thing2 x\n",
              "bin/b.sh": "say old_thing  # gone-ok: the refusal names it\n",
              "bin/old_thing-selftest.sh": "old_thing\n", "README.md": "old_thing\n", "docs/x.sh": "old_thing\n"}),
    "key": ({"conf/fleet.conf.reference": "#   FLEET_OLD_THING=1\n"}, {"conf/fleet.conf.reference": "FLEET_OLD_THING_2=1\n"}),
    "text": ({"conf/a.conf": "set -g status-left '#[range=user|x]'\n", "conf/b.md": "# see range=x\n"},
             {"conf/a.conf": "# range= went with #1714\n", "bin/b.sh": "range=1\n", "c.md": "range=\n"}),
    "re": ({"conf/a.conf": "bind x run 'popup --title popup_keys'\n"},
           {"conf/a.conf": "bind x run 'popup --title view_title'\n", "bin/b.sh": "--title popup_keys\n"}),
}
THING = {"path": "bin/old-thing.sh", "func": "old_thing", "word": "old_thing", "key": "FLEET_OLD_THING",
         "text": "range=", "re": r"--title\s+popup_"}
SCOPE = {"text": "conf/", "re": "conf/a.conf"}
WANT_RED = {"path": 1, "func": 4, "word": 2, "key": 1, "text": 2, "re": 1}
selfbad = []
for k in KINDS:
    for which, files in (("red", SAMPLES[k][0]), ("good", SAMPLES[k][1])):
        with tempfile.TemporaryDirectory() as d:
            for p, body in files.items():
                os.makedirs(os.path.dirname(os.path.join(d, p)), exist_ok=True)
                open(os.path.join(d, p), "w").write(body)
            got = scan(d, [{"n": 0, "kind": k, "thing": THING[k], "ticket": "#1", "scope": SCOPE.get(k, "")}])
            want = WANT_RED[k] if which == "red" else 0
            if len(got) != want:
                selfbad.append("SELF-CHECK FAIL %s/%s: want %d finding(s), got %d: %s" % (k, which, want, len(got), [g[1:3] for g in got]))
if selfbad:
    print("gone FAIL:\n" + "\n".join(selfbad), file=sys.stderr)
    sys.exit(1)

rows, bad = read_list(listfile)
if mode == "--list":
    for r in rows:
        print("%-5s %-48s %-7s %s" % (r["kind"], r["thing"], r["ticket"], r["scope"] or "."))
    sys.exit(0)
seen = {}
for r in rows:
    key = (r["kind"], r["thing"], r["scope"])
    if key in seen:
        bad.append("listed twice: lines %d and %d (%s %s)" % (seen[key], r["n"], r["kind"], r["thing"]))
    seen[key] = r["n"]
if bad:
    print("gone FAIL: the list itself:\n  " + "\n  ".join(bad), file=sys.stderr)
    sys.exit(1)
if not rows:
    print("gone FAIL: the list is empty", file=sys.stderr)
    sys.exit(1)

found = scan(root, rows)
if found:
    print("gone FAIL: %d deleted thing(s) came back:" % len(found), file=sys.stderr)
    for r, p, i, what in found:
        where = "%s:%d" % (p, i) if i else p
        print("  %s %s (deleted %s) — %s: %s" % (r["kind"], r["thing"], r["ticket"], where, what), file=sys.stderr)
    print("  Bring one back on purpose: delete its line in conf/gone.list and say why in the PR.", file=sys.stderr)
    sys.exit(1)
by = {}
for r in rows:
    by[r["kind"]] = by.get(r["kind"], 0) + 1
print("self-check: %s — each red sample red, each good one clean" % " ".join(KINDS))
print("selftest PASS: gone — %d deleted thing(s) stay gone (%s)" % (len(rows), " · ".join("%s %d" % (k, by[k]) for k in KINDS if k in by)))
PY
