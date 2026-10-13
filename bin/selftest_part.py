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
