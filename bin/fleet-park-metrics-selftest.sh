#!/bin/bash
# fleet-park-metrics-selftest.sh — drives fleet-control-read.sh inventory through
# fleet_control.Control, fleet_hub_common.inventory_row and fleet-doctor.sh --park.
# No live socket: all tmux/ps reads are hermetic. Also reads the real daily ledger
# reducer against action fixtures; it never writes census rows to that ledger.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
st_sandbox "${TMPDIR:-/tmp}/park-metrics.XXXXXX" physical
mkdir -p "$WORK/bin" "$WORK/conf/fleets/census/repos" "$WORK/conf/logs" "$WORK/fake" "$WORK/conf/global"
# The adapter sources its real libraries; only the observation commands are fake.
cat > "$WORK/fake/tmux" <<'SH'
#!/bin/sh
case "$*" in
  *has-session*) exit 0 ;;
  *list-clients*) exit 0 ;;
  *list-windows*)
    case "$*" in
      *park_state*) printf '@1\037100\037worker\037one\037\037\0371\037\n@2\037200\037worker\037two\037\037\0371\037\n@3\037300\037worker\037three\037停放中\0372048\0371\037\n';;
      *ctx_left*) printf '@1\t=\t=\t=\t=\t=\t=\t=\n@2\t=\t=\t=\t=\t=\t=\t=\n@3\t=\t=\t=\t=\t=\t=\t=\n';;
      *pane_current_path*) printf '@1\t/tmp/scratch-1\t\tclaude\t\t1\tkeep\t\t\t\t\t\t\t\t\n@2\t/tmp/scratch-2\t\tclaude\t\t1\tkeep\t\t\t\t\t\t\t\t\n@3\t/tmp/scratch-3\t\tclaude\t\t1\tkeep\t\t\t\t\t\t\t\t\n';;
      *cc_agent*loop*) exit 0 ;;
      *pane_pid*) exit 0 ;;
      *) printf '@1\t\t1\t/tmp/scratch-1\tworking\tclaude\th1\t\t?\tone\t\t\tfid1\n@2\t\t1\t/tmp/scratch-2\tdone\tclaude\th2\t\t?\ttwo\t\t\tfid2\n@3\t\t1\t/tmp/scratch-3\tdone\tclaude\th3\t\t?\tthree\t\t\tfid3\n';;
    esac ;;
  *) exit 0 ;;
esac
SH
cat > "$WORK/fake/ps" <<'SH'
#!/bin/sh
case "$*" in
 *rss=*) printf '100 1 1024 00:02 wrapper\n101 100 102400 00:10 claude\n200 1 1024 00:01 wrapper\n201 200 204800 00:00 claude\n300 1 4096 00:00 wrapper\n';;
esac
SH
chmod +x "$WORK/fake/"*
printf 'FLEET_SESSION=census\n' > "$WORK/conf/fleets/census/conf"
printf 'test-identity\n' > "$WORK/conf/fleets/census/identity"
export PATH="$WORK/fake:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
export PYTHONPATH="$BIN" PARK_TEST_WORK="$WORK"
# Test the actual adapter and one parser with 36 columns, rather than making the
# controller's JSON response ourselves. Existing 34-column rows remain accepted.
bash "$BIN/fleet-control-read.sh" workers census > "$WORK/workers"
python3 - <<'PY' || st_fail 'production census assertion'
import json, os, time
from pathlib import Path
from fleet_hub_common import inventory_row
from fleet_control import Control
from fleet_park_metrics import daily
w = Path(os.environ['PARK_TEST_WORK'])
lines = (w/'workers').read_text().splitlines()
assert len(lines) == 3, lines
for line in lines:
    parts, extra = inventory_row(line.split('\t'))
    assert 'park' in extra, line
    assert len(line.split('\t')) == 36, line
    assert 'park' not in inventory_row(line.split('\t')[:-1])[1]
ctl = Control()
fleet = {'fleet_id':'test', 'name':'census', 'agent':'claude', 'repo':''}
snap = ctl.workers(fleet)
p = snap['park_metrics']
assert (p['sessions_working'],p['sessions_idle'],p['sessions_parked']) == (1,1,1), p
assert p['parked_saved_mb'] == 2048 and p['idle_rss_mb'] == 201, p
assert p['idle_eligible'] is None, p # not yet 60 seconds: never claim eligibility
# A second repo changes no count or identity.
(w/'conf/fleets/census/repos/second.conf').write_text('FLEET_REPO=acme/second\n')
assert ctl.workers(fleet)['park_metrics'] == p
# A full minute of low CPU makes the batch figure known; the next census keeps
# that completed reading while accumulating the next minute (never flickers).
cache = w/'conf/global/park-cpu-census.json'
cache.write_text(json.dumps({
 '@1': {'at':time.time()-61,'pid':'100','cpu':12},
 '@2': {'at':time.time()-61,'pid':'200','cpu':1},
 '@3': {'at':time.time()-61,'pid':'300','cpu':0}}))
q=ctl.workers(fleet)['park_metrics']
assert q['idle_eligible'] == 1 and q['idle_eligible_rss_mb'] == 201, q
assert ctl.workers(fleet)['park_metrics'] == q
book = w/'conf/logs/park.ndjson'
book.write_text('\n'.join(json.dumps(r) for r in [
 {'ts':'2026-10-21T12:00:00Z','act':'park'},
 {'ts':'2026-10-21T12:00:02Z','act':'wake','secs':2,'result':'ok','next':10,'started':12},
 {'ts':'2026-10-21T13:00:00Z','act':'wake','secs':5,'result':'ok','next':10,'started':45},
 {'ts':'2026-10-21T14:00:00Z','act':'fail'},
 {'ts':'2026-10-21T14:00:01Z','act':'deferred'},
 {'ts':'2026-10-20T14:00:01Z','act':'wake','secs':100,'result':'ok'}])+'\ninvalid\n')
d=daily(book,'2026-10-21')
assert (d['park'],d['wake'],d['fail'],d['deferred'],d['p50'],d['p95'],d['on_time_rate']) == (1,2,1,1,2,5,.5),d
PY
# Drive doctor's real --park entry using the real Control inventory and adapter.
row=$(sh "$BIN/fleet-doctor.sh" --park)
st_has 'doctor census' "$row" 'working 1 · idle 1 · parked 1 · saved 2048.0 MB · idle RSS 201.0 MB'
st_ok 'park inventory → heartbeat census / doctor / daily ledger'
