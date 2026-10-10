#!/usr/bin/env python3
"""fleet_redact.py — take credentials out of text, by conf/secret-shapes.list.

Issue #2890 (EPIC #2889 C1, 共同约定第 1 条). The ONE table of credential shapes
is conf/secret-shapes.list; this file and bin/fleet-redact.awk (for a computer
with no working Python — C3's fleet-debug) both read it and must write the same
bytes for the same input (doctor-bundle-selftest.sh pins it).

    fleet_redact.py [--table F] [--stats F] < in > out   every match → <redacted:name>
    fleet_redact.py [--table F] --check FILE…             FILE<TAB>shape per hit; exit 1 on any
    fleet_redact.py [--table F] --lint                    the table's own rules; exit 1 on a bad row

--stats writes `<name><TAB><count>` for every shape that replaced something, in
table order. Exit 2: the table is missing or a row is bad.

Same semantics as the awk copy, line by line (bytes, `\\n`-split, every line
written back with a `\\n`): the open block shape first (its lines dropped, the
end line's rest kept), then each row in table order, left to right — a `value`
match that follows [A-Za-z0-9_] is skipped and the search goes on one byte later.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TABLE = os.path.join(HERE, "..", "conf", "secret-shapes.list")
KINDS = ("value", "text", "block")
WORD = re.compile(rb"[A-Za-z0-9_]")


class Shape(object):
    __slots__ = ("name", "kind", "rx", "end")

    def __init__(self, name, kind, pat, end):
        self.name, self.kind = name, kind
        self.rx = re.compile(pat.encode())
        self.end = re.compile(end.encode()) if end else None


def lint_row(cols):
    """'' when a row is good, else why not."""
    if len(cols) < 3:
        return "needs name, kind and an ERE"
    name, kind, pat = cols[0], cols[1], cols[2]
    if not re.match(r"^[a-z0-9-]+$", name):
        return "name %r: lowercase letters, digits and - only" % name
    if kind not in KINDS:
        return "kind %r: one of %s" % (kind, " ".join(KINDS))
    if (kind == "block") != (len(cols) == 4):
        return "only a block row has an end ERE"
    for p in cols[2:]:
        for bad in ("\\", "^", "$"):
            if bad in p.replace("[^", "["):
                return "ERE %r: no %r (awk and Python read it differently)" % (p, bad)
        try:
            if re.compile(p).search(""):
                return "ERE %r matches the empty string" % p
        except re.error as e:
            return "ERE %r: %s" % (p, e)
    return ""


def load(path=None):
    path = path or TABLE
    shapes, seen = [], set()
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            cols = line.split("\t")
            why = lint_row(cols)
            if not why and cols[0] in seen:
                why = "name %r twice" % cols[0]
            if why:
                raise ValueError("%s:%d: %s" % (path, n, why))
            seen.add(cols[0])
            shapes.append(Shape(cols[0], cols[1], cols[2], cols[3] if len(cols) > 3 else ""))
    return shapes


def _search(sh, line, pos):
    """The leftmost match at or after pos, honouring a value's boundary."""
    while pos <= len(line):
        m = sh.rx.search(line, pos)
        if not m:
            return None
        s = m.start()
        if sh.kind == "value" and s > 0 and WORD.match(line, s - 1):
            pos = s + 1
            continue
        return m
    return None


def redact_lines(lines, shapes, counts):
    """Yield the redacted lines (bytes, no newline); counts[name] += hits."""
    blocks = [s for s in shapes if s.kind == "block"]
    inline = [s for s in shapes if s.kind != "block"]
    inside = None
    for line in lines:
        if inside is not None:
            m = inside.end.search(line)
            if not m:
                continue
            inside, line = None, line[m.end():]
            if not line:
                continue
        for sh in blocks:
            pos = 0
            while True:
                m = sh.rx.search(line, pos)
                if not m:
                    break
                counts[sh.name] = counts.get(sh.name, 0) + 1
                tok = b"<redacted:" + sh.name.encode() + b">"
                rest = line[m.end():]
                e = sh.end.search(rest)
                if not e:
                    line, inside = line[:m.start()] + tok, sh
                    break
                line = line[:m.start()] + tok + rest[e.end():]
                pos = m.start() + len(tok)
            if inside is not None:
                break
        for sh in inline:
            out, pos = [], 0
            tok = b"<redacted:" + sh.name.encode() + b">"
            while True:
                m = _search(sh, line, pos)
                if not m:
                    break
                out.append(line[pos:m.start()])
                out.append(tok)
                counts[sh.name] = counts.get(sh.name, 0) + 1
                pos = m.end()
            if out:
                out.append(line[pos:])
                line = b"".join(out)
        yield line


def split_lines(data):
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    return lines


def redact(data, shapes=None, counts=None):
    """bytes → (bytes, {name: hits})."""
    shapes = load() if shapes is None else shapes
    counts = {} if counts is None else counts
    out = b"".join(l + b"\n" for l in redact_lines(split_lines(data), shapes, counts))
    return out, counts


def hits(data, shapes=None):
    """The shape names found in bytes (the whole-bundle check)."""
    shapes = load() if shapes is None else shapes
    found = []
    for line in split_lines(data):
        for sh in shapes:
            if sh.name in found:
                continue
            if (sh.rx.search(line) if sh.kind == "block" else _search(sh, line, 0)):
                found.append(sh.name)
    return found


def find_str(text, shapes=None):
    """True when a str holds a `value` or `block` shape — fleet-agent-team.py's
    credential scan of a config value (a context shape is not its business)."""
    shapes = load() if shapes is None else shapes
    data = text.encode("utf-8", "surrogateescape")
    for line in split_lines(data):
        for sh in shapes:
            if sh.kind == "block" and sh.rx.search(line):
                return True
            if sh.kind == "value" and _search(sh, line, 0):
                return True
    return False


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
            for sh in shapes:
                if counts.get(sh.name):
                    f.write("%s\t%d\n" % (sh.name, counts[sh.name]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
