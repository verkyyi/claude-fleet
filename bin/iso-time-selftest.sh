#!/bin/bash
# iso-time-selftest.sh — the regression net for issue #2024: a timestamp from the
# hub must read on the OLDEST python3 a fleet computer has.
#
# The hub (Go) writes RFC 3339 with nanoseconds and a `Z`
# (`2026-10-07T05:47:35.272044642Z`; Go also trims trailing zeros, so 1–9
# fraction digits all occur). `datetime.fromisoformat` reads neither the `Z` nor
# anything but 3 or 6 digits before python 3.11 — and macOS's own
# /usr/bin/python3 is 3.9. `fleet drill invite` lost its one-time code to it on
# the operator's MacBook. bin/fleet_iso.py is the one reader; this test:
#   1. lints bin/: no `fromisoformat(` outside fleet_iso.py and the selftests
#      (`# iso-ok: <why>` excepts a line);
#   2. runs the cases under every python3 on the box (PATH's, /usr/bin's, any
#      python3.N) — and under a python3 whose fromisoformat refuses what 3.9's
#      refuses, so the cases hold even where only a new python exists (CI).
# Rides along in bash32-array-selftest.sh (in SELFTEST_ALWAYS): a whole-tree lint
# no filename rule could select.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
FAILS=0 CHECKS=0
ok()  { CHECKS=$((CHECKS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/iso-time.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

# --- 1. the lint ------------------------------------------------------------------
hits=$(cd "$BIN" && grep -n 'fromisoformat(' -- * .[!.]* 2>/dev/null \
       | grep -v -e '^fleet_iso\.py:' -e '^[^:]*selftest[^:]*:' -e '# iso-ok:' || true)
if [ -n "$hits" ]; then
  bad "a bare fromisoformat( in bin/ — use fleet_iso.parse / fleet_iso.epoch (issue #2024):"
  printf '      %s\n' "$hits" | head -n 20
else ok; fi

# --- 2. the cases -----------------------------------------------------------------
cat > "$WORK/cases.py" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import fleet_iso
E = 1791352055          # 2026-10-07T05:47:35Z
cases = [
    ("2026-10-07T05:47:35.272044642Z", E, 272044),
    ("2026-10-07T05:47:35.272044642+00:00", E, 272044),
    ("2026-10-07T05:47:35.27204Z", E, 272040),
    ("2026-10-07T05:47:35.2Z", E, 200000),
    ("2026-10-07T05:47:35Z", E, 0),
    ("2026-10-07T05:47:35z", E, 0),
    ("2026-10-07T13:47:35.123+08:00", E, 123000),
    ("2026-10-07T00:47:35-0500", E, 0),
    ("2026-10-07 05:47:35.272044642Z", E, 272044),
]
bad = []
for s, ep, us in cases:
    try:
        d = fleet_iso.parse(s)
        if int(d.timestamp()) != ep or d.microsecond != us:
            bad.append("%s → %s / %d µs" % (s, int(d.timestamp()), d.microsecond))
        if fleet_iso.epoch(s) != ep:
            bad.append("epoch(%s) = %s" % (s, fleet_iso.epoch(s)))
    except Exception as e:
        bad.append("%s raised %r" % (s, e))
# no offset: naive by default, UTC on request
if fleet_iso.parse("2026-10-07T05:47:35").tzinfo is not None: bad.append("a naive stamp came back aware")
if fleet_iso.epoch("2026-10-07T05:47:35", utc=True) != E: bad.append("utc=True did not read a naive stamp as UTC")
if fleet_iso.parse("2026-10-07").hour != 0: bad.append("a date alone")
for junk in ("", None, "next tuesday", "2026-13-01T00:00:00Z", "2026-10-07T05:47:35+25:00", 12):
    if fleet_iso.epoch(junk, default=-1) != -1: bad.append("junk %r did not fall to the default" % (junk,))
if abs(fleet_iso.fepoch("2026-10-07T05:47:35.5Z") - (E + 0.5)) > 1e-6: bad.append("fepoch")
print("\n".join(bad) if bad else "OK")
PY
mkdir -p "$WORK/strict"
cat > "$WORK/strict/sitecustomize.py" <<'PY'
# python 3.9's fromisoformat: no Z, a fraction of exactly 3 or 6 digits
import datetime as _d, re as _re
class _D(_d.datetime):
    @classmethod
    def fromisoformat(cls, s):
        if not isinstance(s, str) or s.endswith(("Z", "z")) or _re.search(r"\.(\d{1,2}|\d{4,5}|\d{7,})(?!\d)", s):
            raise ValueError("Invalid isoformat string: %r" % (s,))
        return super().fromisoformat(s)
_d.datetime = _D
PY
pys=''
for p in python3 /usr/bin/python3 python3.6 python3.7 python3.8 python3.9 python3.10; do
  q=$(command -v "$p" 2>/dev/null) || continue
  case " $pys " in *" $q "*) ;; *) pys="$pys $q" ;; esac
done
[ -n "$pys" ] || { bad 'no python3 on this box'; pys=python3; }
for py in $pys; do
  v=$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
  out=$("$py" "$WORK/cases.py" "$BIN" 2>&1)
  [ "$out" = OK ] && ok || bad "fleet_iso under $py ($v): $out"
done
py1=$(printf '%s\n' $pys | head -n 1)
out=$(PYTHONPATH="$WORK/strict" "$py1" "$WORK/cases.py" "$BIN" 2>&1)
[ "$out" = OK ] && ok || bad "fleet_iso under a 3.9-strict fromisoformat: $out"
# the shim is a real test: it refuses the hub's stamp the way 3.9 does
if PYTHONPATH="$WORK/strict" "$py1" -c 'import datetime; datetime.datetime.fromisoformat("2026-10-07T05:47:35.272044642+00:00")' 2>/dev/null; then
  bad 'the 3.9-strict shim took a 9-digit fraction — it tests nothing'
else ok; fi

[ "$FAILS" = 0 ] && { printf 'iso-time-selftest: OK (%d checks)\n' "$CHECKS"; exit 0; }
printf 'iso-time-selftest: FAIL (%d)\n' "$FAILS"; exit 1
