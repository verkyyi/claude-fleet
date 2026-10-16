#!/usr/bin/env python3
"""STRUCTURAL: production loop/idle_nap with a controlled clock and waiter.

No real-60-second claim. The sibling watch selftest supplies real event coverage.
"""
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import tempfile
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
source = (BIN / 'fleet-hub-sessions.sh').read_text()
defaults = source[source.index('EVERY="'):source.index('ETAGF=')]
functions = '\n'.join(re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S)[0]
                      for name in ('loop', 'loop_cleanup', 'idle_nap', 'thin_lease_beat'))

# Only external time, fetch, view predicate and waiter IO are controlled. The
# production loop chooses every deadline, interval, follow-up and lease beat.
fixture = r'''
set -eu
BIN=$1; G=$2; scenario=$3; LOOP_SECS=$4
FLEET_CONF_DIR=$G/conf; mkdir -p "$FLEET_CONF_DIR"
CLOCK=$G/clock; printf '0\n' > "$CLOCK"
unset SECONDS; SECONDS=0  # ordinary controlled variable, no real-clock drift
PIDF=$G/pid; WANTF=$G/want; LOOPCODEF=$G/code; MAPCODE=''
NAP_PID=''; NAP_SOCKS=(); FOLLOWUP=0; LP_WAIT=25
FLEET_HUBSESS_LOCKED=1; FLEET_HUB_SESSIONS_LONGPOLL=0
case "$scenario" in *thin*) : > "$FLEET_CONF_DIR/thin-lease.json" ;; esac
date() { [ "$1" = +%s ]; cat "$CLOCK"; }
hub_on() { return 0; }
watched() { [ "$scenario" = watched ]; }
refresh_all() { printf '%s\n' "$(cat "$CLOCK")" >> "$G/fetch"; }
python3() {
  case "$1" in
    */fleet_thin_lease.py) cat "$CLOCK" >> "$G/beat" ;;
    */fleet-render-watch.py)
      [ "$2" = --events-only ] && [ "$3" = --max-frames ] || return 92
      cap=$4; now=$(cat "$CLOCK"); reason=timeout; next=$((now + cap))
      printf '%s %s\n' "$now" "$cap" >> "$G/waits"
      case "$scenario" in
        event*) if [ ! -f "$G/event" ]; then
          : > "$G/event"; next=10; reason=changed
        fi ;;
        want) [ -f "$WANTF" ] || printf '20\n' > "$WANTF" ;;
      esac
      printf '%s\n' "$next" > "$CLOCK"; printf '%s\n' "$reason" ;;
    *) return 93 ;;
  esac
}
wait() { builtin wait "$1"; SECONDS=$(cat "$CLOCK"); }
'''

cases = [
    ('idle', 59, [0], [59]),
    ('idle', 60, [0], [60]),
    ('idle', 61, [0, 60], [60, 1]),
    ('thin', 61, [0, 60], [15, 15, 15, 15, 1]),
    ('thin', 59, [0], [15, 15, 15, 14]),
    ('want', 61, [0, 60], [60, 21]),
    ('event', 65, [0, 10, 11], [60, 1, 54]),
    ('event-thin', 65, [0, 10, 11], [15, 1, 15, 15, 15, 9]),
    ('watched', 5, [0, 2, 4], [2, 2, 1]),
]
env = {k: v for k, v in os.environ.items() if not k.startswith('FLEET_')}
with tempfile.TemporaryDirectory(prefix='hubsess-schedule.') as tmp:
    root = Path(tmp)
    script = root / 'probe.sh'
    script.write_text(fixture + defaults + '\n' + functions +
                      '\n[ "$IDLE_EVERY" = 60 ] && [ "$WATCHED_EVERY" = 2 ]\nloop\n')
    for i, (name, lifetime, expected, caps) in enumerate(cases):
        work = root / str(i)
        work.mkdir()
        subprocess.run(['bash', str(script), str(BIN), str(work), name, str(lifetime)],
                       env=env, check=True, capture_output=True, text=True, timeout=5)
        actual = [int(v) for v in (work / 'fetch').read_text().split()]
        waits = [list(map(int, row.split())) for row in (work / 'waits').read_text().splitlines()]
        assert actual == expected, (name, lifetime, actual)
        assert [cap for _, cap in waits] == caps, (name, lifetime, waits)
        assert int((work / 'clock').read_text()) == (81 if name == 'want' else lifetime)
        assert not (work / 'pid').exists() and not list(work.glob('hubsess.wake.*'))
        if name == 'thin' and lifetime == 61:
            assert list(map(int, (work / 'beat').read_text().split())) == [0, 15, 30, 45, 60]
        print('PASS STRUCTURAL loop/idle_nap %s lifetime=%s fetch=%s waits=%s' %
              (name, lifetime, actual, caps))

    spec = importlib.util.spec_from_file_location('watch', BIN / 'fleet-render-watch.py')
    watch = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(watch)
    request = root / 'view'
    request.touch()
    with patch.object(watch.time, 'time', return_value=1000), patch.object(watch, 'attached', return_value=True):
        for age, accepted in [(0, True), (30, True), (30.001, False), (31, False), (-.001, False)]:
            os.utime(request, (1000 - age, 1000 - age))
            assert watch.view_active(str(request), ['private']) is accepted, age
    print('PASS STRUCTURAL actual view_active: 0..30 inclusive; expired/future refused')
