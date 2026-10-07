"""fleet_iso — the ONE ISO-8601 / RFC 3339 timestamp reader for bin/ (issue #2024).

The hub (Go) writes time.Time as RFC 3339 with NANOSECONDS and a `Z`:
`2026-10-07T05:47:35.272044642Z`, or `…+00:00`. `datetime.fromisoformat` takes
neither the 9-digit fraction nor the `Z` before python 3.11, and macOS's own
/usr/bin/python3 is 3.9 — so every bare `fromisoformat` in bin/ was a
ValueError waiting for the first machine without a newer python
(`fleet drill invite` lost its one-time code to one). This parser builds the
datetime itself, so it reads the same on every python3 ≥ 3.6:

    import fleet_iso
    fleet_iso.parse("2026-10-07T05:47:35.272044642Z")   # aware datetime, µs
    fleet_iso.epoch("2026-10-07T05:47:35Z")              # int seconds, 0 on junk

A fraction is cut (never rounded) to microseconds; `Z`/`z` and `±HH[:MM]` are
the offsets; no offset = a naive datetime (as fromisoformat), unless utc=True.
bin/iso-time-selftest.sh holds bin/ to it and runs the cases under the oldest
python3 on the box.
"""
import datetime
import re

_RE = re.compile(
    r"\s*(\d{4})-(\d{2})-(\d{2})"
    r"(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?)?"
    r"\s*(?:([Zz])|([+-])(\d{2})(?::?(\d{2}))?)?\s*$"
)


def parse(value, utc=False):
    """value → datetime; ValueError when it is no ISO-8601 timestamp.
    utc=True reads a timestamp with no offset as UTC instead of naive."""
    m = _RE.match(str(value if value is not None else ""))
    if not m:
        raise ValueError("not an ISO-8601 timestamp: %r" % (value,))
    y, mo, d, h, mi, s, frac, z, sign, oh, om = m.groups()
    us = int((frac or "")[:6].ljust(6, "0"))
    tz = None
    if z:
        tz = datetime.timezone.utc
    elif sign:
        off = datetime.timedelta(hours=int(oh), minutes=int(om or 0))
        tz = datetime.timezone(-off if sign == "-" else off)
    elif utc:
        tz = datetime.timezone.utc
    return datetime.datetime(int(y), int(mo), int(d), int(h or 0), int(mi or 0),
                             int(s or 0), us, tzinfo=tz)


def epoch(value, default=0, utc=False):
    """value → int epoch seconds; default when it does not parse."""
    try:
        return int(parse(value, utc=utc).timestamp())
    except (ValueError, OverflowError, OSError):
        return default


def fepoch(value, default=0.0, utc=False):
    """As epoch(), as a float (to the microsecond)."""
    try:
        return parse(value, utc=utc).timestamp()
    except (ValueError, OverflowError, OSError):
        return default
