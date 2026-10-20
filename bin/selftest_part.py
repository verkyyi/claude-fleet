"""selftest_part.py — run one slice of a unittest selftest (issue #2694).

A selftest whose cases outgrow the per-test budget runs as several tests: the
original `<name>-selftest.sh` and one part file per extra slice
(`<name>-<k>-selftest.sh`, carrying `# selftest-part-of: <name>-selftest.sh` so
`run-selftests.sh --changed` selects every part together). Each part sets
SELFTEST_PART=K/N and the .py ends in `selftest_part.main()` instead of
`unittest.main(verbosity=2)`.

The slice is a STRIDE over every test method in definition order (class by
class, method by method as unittest loads them): neighbours tend to cost alike,
so a stride spreads a slow class over the parts instead of handing it to one.
A new case lands in some part on its own. No SELFTEST_PART (or `all`) ⇒ exactly
`unittest.main(verbosity=2)`.
"""
import os
import sys
import unittest


def _flat(suite):
    for t in suite:
        if isinstance(t, unittest.TestSuite):
            yield from _flat(t)
        else:
            yield t


def main(module="__main__", verbosity=2):
    part = os.environ.pop("SELFTEST_PART", "") or "all"
    if part == "all" or len(sys.argv) > 1:
        unittest.main(module=module, verbosity=verbosity)
        return
    try:
        k, n = (int(x) for x in part.split("/"))
        assert 1 <= k <= n
    except (ValueError, AssertionError):
        sys.stderr.write("selftest_part: SELFTEST_PART=%s is not K/N\n" % part)
        sys.exit(2)
    mod = sys.modules[module] if isinstance(module, str) else module
    every = list(_flat(unittest.defaultTestLoader.loadTestsFromModule(mod)))
    mine = every[k - 1::n]
    sys.stdout.write("selftest_part: part %s — %d of %d cases\n" % (part, len(mine), len(every)))
    sys.stdout.flush()
    res = unittest.TextTestRunner(verbosity=verbosity).run(unittest.TestSuite(mine))
    sys.exit(0 if res.wasSuccessful() else 1)


def fan_out(ways, argv_prefix=(), by_class=False, module="__main__"):
    """Run this part's slice (SELFTEST_PART=K/N, no case named) as <ways> child
    processes at once — the same cases, each in a process of its own, each output
    kept whole and printed in turn; exit 1 if any child failed. by_class keeps a
    class's cases in one child (a class sharing a resource across its cases),
    the classes dealt largest first to the emptiest child. A part that is not
    K/N, or a run that names cases, returns: main() runs as before."""
    import subprocess
    import tempfile
    part = os.environ.get("SELFTEST_PART", "")
    if not part or part == "all" or len(sys.argv) > 1:
        return
    try:
        k, n = (int(x) for x in part.split("/"))
        assert 1 <= k <= n
    except (ValueError, AssertionError):
        return
    mod = sys.modules[module] if isinstance(module, str) else module
    every = list(_flat(unittest.defaultTestLoader.loadTestsFromModule(mod)))
    mine = [t.id().split(".", 1)[1] for t in every[k - 1::n]]
    if by_class:
        groups = {}
        for c in mine:
            groups.setdefault(c.split(".")[0], []).append(c)
        lots = [[] for _ in range(ways)]
        for g in sorted(groups.values(), key=len, reverse=True):
            min(lots, key=len).extend(g)
    else:
        lots = [mine[i::ways] for i in range(ways)]
    sys.stdout.write("selftest_part: part %s — %d of %d cases, in %d processes\n" % (part, len(mine), len(every), ways))
    sys.stdout.flush()
    env = {x: v for x, v in os.environ.items() if x != "SELFTEST_PART"}
    procs = []
    for lot in lots:
        if lot:
            out = tempfile.TemporaryFile()
            procs.append((subprocess.Popen([sys.executable] + ["-W" + w for w in sys.warnoptions]
                                           + [os.path.abspath(sys.argv[0])] + list(argv_prefix) + lot,
                                           env=env, stdout=out, stderr=subprocess.STDOUT), out))
    rc = 0
    for p, out in procs:
        rc |= p.wait()
        out.seek(0)
        sys.stdout.flush()
        sys.stdout.buffer.write(out.read())
        sys.stdout.flush()
    sys.exit(1 if rc else 0)
