#!/usr/bin/env python3
"""fleet_redact.py — take credentials out of text, by conf/secret-shapes.list.

Issue #2890 (EPIC #2889 C1, 共同约定第 1 条). The ONE table of credential shapes
is conf/secret-shapes.list (C7 #2896 made it; bin/fleet_clientlog.py and
fleet_clientlog in bin/fleet-client-lib.sh read it too). This file and
bin/fleet-redact.awk (for a computer with no working Python — C3's fleet-debug)
must write the same bytes for the same input (doctor-bundle-selftest.sh pins it).

    fleet_redact.py [--table F] [--stats F] < in > out   every match → <redacted:name>
    fleet_redact.py [--table F] --check FILE…             FILE<TAB>shape per hit; exit 1 on any
    fleet_redact.py [--table F] --lint                    the table's own rules; exit 1 on a bad row

--stats writes `<name><TAB><count>` for every shape that replaced something, in
table order. Exit 2: the table is missing or a row is bad.

Line by line (bytes, `\\n`-split, every line written back with a `\\n`): an open
`#@block` first (its lines dropped, the end line's rest kept; a begin whose end
is not on its line opens one), then every row top to bottom, each over the whole
line — the client logs' own semantics (fleet_clientlog.py's `sub`, awk's `gsub`).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# beside this file's bin/, else beside the real file's (a dir-of-symlinks shadow)
TABLE = next((t for t in (os.path.join(d, "..", "conf", "secret-shapes.list")
                          for d in (HERE, os.path.dirname(os.path.realpath(__file__))))
              if os.path.isfile(t)), os.path.join(HERE, "..", "conf", "secret-shapes.list"))


class Shape(object):
    __slots__ = ("name", "rx", "end", "tok")

    def __init__(self, name, pat, end=""):
        self.name = name
        self.rx = re.compile(pat.encode())
        self.end = re.compile(end.encode()) if end else None
        self.tok = b"<redacted:" + name.encode() + b">"


class Table(object):
    def __init__(self):
        self.rows, self.blocks, self.scan = [], [], []


def lint_pat(p):
    """'' when an ERE keeps to the rules both readers share, else why not."""
    for bad, why in (("\\", "a backslash"), ("{", "an interval"), ("(?", "(?…)"), ("[[:", "a [[:class:]]"),
                     ("$", "an anchor")):
        if bad in p:
            return "%r: no %s (awk and Python read it differently)" % (p, why)
    if "^" in p.replace("[^", "["):
        return "%r: no anchor" % p
    try:
        if re.compile(p).search(""):
            return "%r matches the empty string" % p
    except re.error as e:
        return "%r: %s" % (p, e)
    return ""


def load(path=None):
    path = path or TABLE
    t, names = Table(), set()
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            cols = line.split("\t")
            why = ""
            if line.startswith("#@block\t"):
                if len(cols) != 4:
                    why = "#@block needs a name, a begin and an end"
                else:
                    why = lint_pat(cols[2]) or lint_pat(cols[3])
                    t.blocks.append(Shape(cols[1], cols[2], cols[3]))
            elif line.startswith("#@scan\t"):
                t.scan = line.split("\t", 1)[1].split()
            elif line.startswith("#") or "\t" not in line:
                continue
            elif len(cols) != 2:
                why = "one tab: <name><TAB><ERE>"
            elif not re.match(r"^[a-z0-9_]+$", cols[0]) or cols[0] in names:
                why = "name %r: lowercase, digits and _, once" % cols[0]
            else:
                why = lint_pat(cols[1])
                names.add(cols[0])
                t.rows.append(Shape(cols[0], cols[1]))
            if why:
                raise ValueError("%s:%d: %s" % (path, n, why))
    unknown = [x for x in t.scan if x not in names]
    if unknown or not t.rows:
        raise ValueError("%s: %s" % (path, "#@scan names no row: %s" % " ".join(unknown) if unknown else "no shapes"))
    return t


def redact_lines(lines, t, counts):
    """Yield the redacted lines (bytes, no newline); counts[name] += hits."""
    inside = None
    for line in lines:
        if inside is not None:
            m = inside.end.search(line)
            if not m:
                continue
            inside, line = None, line[m.end():]
            if not line:
                continue
        for sh in t.blocks:
            m = sh.rx.search(line)
            if m and not sh.end.search(line, m.end()):
                counts[sh.name] = counts.get(sh.name, 0) + 1
                line, inside = line[:m.start()] + sh.tok, sh
                break
        for sh in t.rows:
            line, k = sh.rx.subn(sh.tok, line)
            if k:
                counts[sh.name] = counts.get(sh.name, 0) + k
        yield line


def split_lines(data):
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    return lines


def redact(data, t=None, counts=None):
    """bytes → (bytes, {name: hits})."""
    t = load() if t is None else t
    counts = {} if counts is None else counts
    out = b"".join(l + b"\n" for l in redact_lines(split_lines(data), t, counts))
    return out, counts


def hits(data, t=None):
    """The shape names found in bytes (the whole-bundle check)."""
    t = load() if t is None else t
    found = []
    for line in split_lines(data):
        for sh in t.blocks + t.rows:
            if sh.name not in found and sh.rx.search(line):
                found.append(sh.name)
    return found


def find_str(text, t=None):
    """True when a str holds a credential VALUE — a `#@scan` row:
    fleet-agent-team.py's scan of a config value."""
    t = load() if t is None else t
    data = text.encode("utf-8", "surrogateescape")
    return any(sh.rx.search(data) for sh in t.rows if sh.name in t.scan)


def main(argv):
    table, stats, mode, files = None, None, "redact", []
    it = iter(argv)
    for a in it:
        if a == "--table":
            table = next(it, None)
        elif a == "--stats":
            stats = next(it, None)
        elif a == "--check":
            mode = "check"
        elif a == "--lint":
            mode = "lint"
        elif a in ("-h", "--help"):
            sys.stdout.write(__doc__)
            return 0
        elif a.startswith("-"):
            sys.stderr.write("fleet_redact: unknown option %s\n" % a)
            return 2
        else:
            files.append(a)
    try:
        shapes = load(table)
    except (OSError, ValueError) as e:
        sys.stderr.write("fleet_redact: %s\n" % e)
        return 2
    if mode == "lint":
        return 0
    if mode == "check":
        rc = 0
        for fn in files:
            try:
                with open(fn, "rb") as f:
                    data = f.read()
            except OSError as e:
                sys.stderr.write("fleet_redact: %s\n" % e)
                return 2
            for name in hits(data, shapes):
                sys.stdout.write("%s\t%s\n" % (fn, name))
                rc = 1
        return rc
    data = sys.stdin.buffer.read()
    out, counts = redact(data, shapes)
    sys.stdout.buffer.write(out)
    if stats:
        with open(stats, "w") as f:
            done = set()
            for sh in shapes.blocks + shapes.rows:
                if counts.get(sh.name) and sh.name not in done:
                    done.add(sh.name)
                    f.write("%s\t%d\n" % (sh.name, counts[sh.name]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
