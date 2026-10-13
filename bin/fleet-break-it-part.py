#!/usr/bin/env python3
"""fleet-break-it-part.py K/N TABLE ID... — the ids of BREAK_PART K/N (issue #2694).

The break-it runners (bin/fleet-break-it-selftest.sh's own loop and the cred
half's cred_run_drills) cut their drills into N CONTIGUOUS slices, in the order
given, balanced by each drill's measured wall time: TABLE is
bin/break-it-durations.txt (`<secs> <id>` per line, refreshed from a CI log by
`selftest-durations.sh --drills`), and a drill with no row costs the table's
median (1 s with no table). Contiguous, because neighbours share lazy rigs
(client_setup, drive): splitting a cluster makes two parts pay its rig.

Slice K takes the drills whose cost midpoint falls in [(K-1)/N, K/N) of the
total. Prints the slice's ids, one per line; exit 2 on a bad K/N.
"""
import statistics
import sys


def load(path):
    w = {}
    try:
        for line in open(path, encoding="utf-8"):
            p = line.split()
            if len(p) == 2 and not line.startswith("#"):
                try:
                    w[p[1]] = float(p[0])
                except ValueError:
                    pass
    except OSError:
        pass
    return w


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: fleet-break-it-part.py K/N TABLE ID...\n")
        return 2
    try:
        k, n = (int(x) for x in argv[1].split("/"))
        assert 1 <= k <= n
    except (ValueError, AssertionError):
        sys.stderr.write("fleet-break-it-part: %s is not K/N\n" % argv[1])
        return 2
    table, ids = load(argv[2]), argv[3:]
    dflt = statistics.median(table.values()) if table else 1.0
    cost = [max(table.get(i, dflt), 0.05) for i in ids]
    total = sum(cost) or 1.0
    acc = 0.0
    for i, c in zip(ids, cost):
        mid = (acc + c / 2) / total
        acc += c
        if (k - 1) / n <= mid < k / n or (k == n and mid >= 1):
            print(i)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
