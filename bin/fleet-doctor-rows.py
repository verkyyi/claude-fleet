#!/usr/bin/env python3
"""fleet-doctor-rows.py — the doctor's row table, read off its source (issue #3587,
EPIC #3569 C17).

Every row `fleet doctor` can print is named in exactly two places: bin/fleet-doctor.sh
(`pass|warn|fail|info <row> "<msg>"`) and, for `fleet doctor --machine`,
bin/fleet-node-update.py (`("PASS", "<row>", …)` tuples). Anything that maps a
row to advice — the fleet-infra plugin's node-doctor skill, the public
troubleshooting page (C12) — is generated from THIS list, never typed by hand
twice (EPIC #3569 共同约定 4).

  names     [--root R]          one `<row>\t<half>` per row, sorted (half = node | machine)
  skeleton  [--root R] [--from SKILL.md]
                                the markdown table node-doctor carries: one line per
                                row; a row the given SKILL.md already maps keeps its
                                line byte for byte, a new one gets `| <row> | <half> | ? | ? |`
  check     <SKILL.md> [--root R]
                                every row is in the SKILL.md's table and every skill it
                                names exists beside it; exit 1 + one line per gap

A label the shell reads from a variable (`warn "$rk" …`) is declared next to it
with `# doctor-rows: <row> …` in the 30 lines above; an undeclared one is an
error (exit 2), so a new dynamic row cannot slip past the table.
"""
import os
import re
import sys

LEVELS = ("pass", "warn", "fail", "info")
# a level at command position: start of line, after ; & | { ( ) or then / else / do
SH_ROW = re.compile(r"(?:^|[;&|{(]|\)|\bthen\b|\belse\b|\bdo\b)\s*(pass|warn|fail|info)\s+(\"?)([^\s\"]+)\2(?=\s|$)")
SH_DECL = re.compile(r"#\s*doctor-rows:\s*(.+)$")
PY_ROW = re.compile(r"\(\s*(?:\"[A-Z]+\"(?:\s+if\s+[^,]+?\s+else\s+\"[A-Z]+\")?|lvl)\s*,\s*(\"([a-z][a-z0-9-]*)\"|tool)\s*,")
PY_TOOLS = re.compile(r"^TOOLS\s*=\s*\(([^)]*)\)", re.M)
TABLE_ROW = re.compile(r"^\|\s*`([^`]+)`\s*\|")


def root_of(args):
    if "--root" in args:
        return args[args.index("--root") + 1]
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def node_rows(path):
    """(rows, errors) of bin/fleet-doctor.sh."""
    rows, errs = set(), []
    lines = open(path, encoding="utf-8").read().split("\n")
    in_verdict = False
    for i, line in enumerate(lines):
        s = line.lstrip()
        if s.startswith("#"):
            continue
        if re.match(r"\s*daemon_verdict\(\)", line):
            in_verdict = True
        elif in_verdict and re.match(r"^}", line):
            in_verdict = False
        m = re.match(r"\s*daemon_verdict\s+([a-z][a-z0-9-]*)\s", line)
        if m:
            rows.add(m.group(1))
        # quoted strings hold prose ("… and warn more"): match outside them only
        code = re.sub(r"'[^']*'", "''", line)
        for m in SH_ROW.finditer(code):
            label = m.group(3)
            if label.startswith("$"):
                if in_verdict:
                    continue    # daemon_verdict's "$tag": its callers name the row
                decl = None
                for j in range(i - 1, max(-1, i - 31), -1):
                    d = SH_DECL.search(lines[j])
                    if d:
                        decl = d.group(1).split()
                        break
                if decl is None:
                    errs.append("%s:%d: %s %s — a row named by a variable needs `# doctor-rows: <row> …` above it"
                                % (path, i + 1, m.group(1), label))
                else:
                    rows.update(decl)
                continue
            rows.add(label)
    return rows, errs


def machine_rows(path):
    src = open(path, encoding="utf-8").read()
    rows = set()
    tools = PY_TOOLS.search(src)
    for m in PY_ROW.finditer(src):
        if m.group(2):
            rows.add(m.group(2))
        elif tools:
            rows.update(re.findall(r"\"([a-z0-9-]+)\"", tools.group(1)))
    return rows


def table(root):
    """{row: half} — a row both halves print is `node · machine`."""
    nr, errs = node_rows(os.path.join(root, "bin", "fleet-doctor.sh"))
    mr = machine_rows(os.path.join(root, "bin", "fleet-node-update.py"))
    out = {}
    for r in nr:
        out[r] = "node"
    for r in mr:
        out[r] = "node · machine" if r in out else "machine"
    return out, errs


def skill_lines(path):
    """{row: the table line} of a SKILL.md's row table."""
    got = {}
    if path and os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            m = TABLE_ROW.match(line)
            if m:
                got[m.group(1)] = line.rstrip("\n")
    return got


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0
    cmd, args = argv[0], argv[1:]
    root = root_of(args)
    rows, errs = table(root)
    for e in errs:
        sys.stderr.write(e + "\n")
    if errs:
        return 2
    if cmd == "names":
        for r in sorted(rows):
            print("%s\t%s" % (r, rows[r]))
        return 0
    if cmd == "skeleton":
        have = skill_lines(args[args.index("--from") + 1] if "--from" in args else None)
        for r in sorted(rows):
            print(have.get(r) or "| `%s` | %s | ? | ? |" % (r, rows[r]))
        return 0
    if cmd == "check":
        if not args or args[0].startswith("--"):
            sys.stderr.write("usage: fleet-doctor-rows.py check <SKILL.md> [--root R]\n")
            return 2
        sk = args[0]
        have = skill_lines(sk)
        skills_dir = os.path.dirname(os.path.dirname(os.path.abspath(sk)))
        bad = []
        for r in sorted(rows):
            if r not in have:
                bad.append("missing row `%s` (%s) — run: fleet-doctor-rows.py skeleton --from %s" % (r, rows[r], sk))
                continue
            for name in re.findall(r"\[([a-z][a-z0-9-]*)\]", have[r]):
                if not os.path.isfile(os.path.join(skills_dir, name, "SKILL.md")):
                    bad.append("row `%s` names [%s], which is not a skill beside node-doctor" % (r, name))
            if "| ? |" in have[r]:
                bad.append("row `%s` is still a skeleton line (? unfilled)" % r)
        for r in sorted(set(have) - set(rows)):
            bad.append("row `%s` is in the table but the doctor no longer prints it" % r)
        for b in bad:
            print(b)
        return 1 if bad else 0
    sys.stderr.write("unknown command %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
