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
fixture_dir=$(dirname "$0")
control=1; parked=1; held=1; saved=2048
[ ! -f "$fixture_dir/control" ] || control=$(cat "$fixture_dir/control")
[ ! -f "$fixture_dir/parked" ] || parked=$(cat "$fixture_dir/parked")
[ ! -f "$fixture_dir/held" ] || held=$(cat "$fixture_dir/held")
[ ! -f "$fixture_dir/saved" ] || saved=$(cat "$fixture_dir/saved")
case "$*" in
  *has-session*) exit 0 ;;
  *list-clients*) printf '%s\037@2\n' "$control" ;;
  *list-windows*)
    case "$*" in
      *park_saved_mb*)
        case "$*" in *'#{@park_saved_mb}'*'#{@park_wrap_ver}'*'#{@park_since}'*) ;; *) exit 1 ;; esac
        case "$*" in
          *park_state*)
            printf '@1\037100\037worker\037one\037\037\0371\037\037fid1\037\n@2\037200\037worker\037two\037\037\0371\037\037fid2\037\n@3\037300\037worker\037three\037\037%s\0371\037\037fid3\037idle\n' "$saved";;
          *)
            printf '@1\037100\037worker\037one\037\037\0371\037\037fid1\037\037\037\n@2\037200\037worker\037two\037\037\0371\037\037fid2\037\037\037\n@3\037300\037worker\037three\037%s\037%s\0371\0371\037fid3\037idle\037%s\037\n' "$parked" "$saved" "$held";;
        esac;;
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
# Test the actual adapter and one parser with 37 columns, rather than making the
# controller's JSON response ourselves. Existing 34-column rows remain accepted.
printf '{"ts":"2026-10-21T12:00:00Z","fid":"fid3","act":"park","rss_mb":9999}\n' > "$WORK/conf/logs/park.ndjson"
bash "$BIN/fleet-control-read.sh" workers census > "$WORK/workers"
python3 - <<'PY' || st_fail 'production census assertion'
import json, os, time
from pathlib import Path
from fleet_hub_common import inventory_row
from fleet_control import Control
from fleet_park_metrics import daily, summarize
# Idle uses the batch acceptance definition. Viewers/background work remain
# reasons, while the three counts still cover every session exactly once.
def worker(state='done', quiet=True, why='old-shell', busy=None):
    return {'state':state, 'busy':busy, 'park':{'state':'awake','quiet':quiet,'why':why,'rss_mb':100,'saved_mb':None}}
strict = summarize([worker(), worker('looping'), worker('needs'), worker(why='watched'),
                    worker(busy='bg'), worker(quiet=False), worker('exited')])
assert (strict['sessions_idle'], strict['sessions_working'], strict['idle_rss_mb']) == (3,4,300), strict
assert (strict['idle_eligible'],strict['idle_eligible_rss_mb']) == (3,300), strict
assert strict['idle_reasons']['watched'] == strict['idle_reasons']['background'] == 1, strict
from fleet_park_metrics import inventory_park
def joined(**kw):
    w = worker(**kw)
    return inventory_park(w['park'], w['state'], w['busy'])
assert joined(why='watched')['eligible'] is False
assert joined(busy='bg')['eligible'] is False
assert joined(state='working')['eligible'] is False
assert joined(why='working')['eligible'] is False  # reconnecting before native state arrives
assert joined(quiet=None)['eligible'] is None
assert joined(why='watched', quiet=None)['why'] == 'watched'
assert joined(busy='bg', quiet=None)['why'] == 'background'
assert joined(quiet=False)['eligible'] is False
assert joined()['eligible'] is True
assert set(joined()) == {'state','rss_mb','saved_mb','why','eligible'}
w = Path(os.environ['PARK_TEST_WORK'])
lines = (w/'workers').read_text().splitlines()
assert len(lines) == 3, lines
for line in lines:
    parts, extra = inventory_row(line.split('\t'))
    assert 'park' in extra, line
    assert set(extra['park']) == {'state','rss_mb','saved_mb','why','eligible'}, extra
    assert len(line.split('\t')) == 37, line
    assert 'park' not in inventory_row(line.split('\t')[:-1])[1]
ctl = Control()
fleet = {'fleet_id':'test', 'name':'census', 'agent':'claude', 'repo':''}
snap = ctl.workers(fleet)
p = snap['park_metrics']
assert (p['sessions_working'],p['sessions_idle'],p['sessions_parked']) == (None,None,1), p
assert p['parked_saved_mb'] == 2048 and p['idle_rss_mb'] is None, p
unknown = summarize([{'state':'parked', 'park':{'state':'parked','saved_mb':None}}])
assert unknown['sessions_parked'] == 1 and unknown['parked_saved_mb'] is None, unknown
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
assert q['sessions_idle'] == q['idle_eligible'] == 1 and q['idle_rss_mb'] == q['idle_eligible_rss_mb'] == 201, q
assert q['sessions_working'] == 1 and q['sessions_parked'] == 1, q
assert ctl.workers(fleet)['park_metrics'] == q
# A collector's control client is not a viewer; an attached human is.
(w/'fake/control').write_text('0')
viewed = ctl.workers(fleet)['park_metrics']
assert (viewed['sessions_idle'], viewed['sessions_working'], viewed['idle_rss_mb']) == (0,2,0), viewed
assert viewed['idle_eligible'] == viewed['idle_eligible_rss_mb'] == 0, viewed
assert viewed['idle_reasons']['watched'] == 1, viewed
(w/'fake/control').unlink()
# HHV0 requires both intent and a confirmed holding page; either alone is awake.
for marker in ('parked', 'held'):
    (w/'fake'/marker).write_text('')
    assert ctl.workers(fleet)['park_metrics']['sessions_parked'] == 0
    (w/'fake'/marker).unlink()
# A valid C1 snapshot wins over the ledger; missing stamps use the latest park
# action for this identity. Invalid stamps remain unknown instead of estimating.
(w/'fake/saved').write_text('')
assert ctl.workers(fleet)['park_metrics']['parked_saved_mb'] == 9999
for value in ('-1', 'NaN'):
    (w/'fake/saved').write_text(value)
    missing = ctl.workers(fleet)['park_metrics']
    assert missing['sessions_parked'] == 1 and missing['parked_saved_mb'] is None, missing
(w/'fake/saved').unlink()
# Snapshot savings do not depend on an action book being present.
book = w/'conf/logs/park.ndjson'
book.unlink()
assert ctl.workers(fleet)['park_metrics']['parked_saved_mb'] == 2048
(w/'fake/saved').write_text('')
assert ctl.workers(fleet)['park_metrics']['parked_saved_mb'] is None
(w/'fake/saved').unlink()
book = w/'conf/logs/park.ndjson'
book.write_text('\n'.join(json.dumps(r) for r in [
 {'ts':'2026-10-21T12:00:00Z','fid':'fid3','act':'park','rss_mb':2048},
 {'ts':'2026-10-21T12:00:02Z','act':'wake','secs':2,'result':'ok','next':10,'started':12},
 {'ts':'2026-10-21T13:00:00Z','act':'wake','secs':5,'result':'ok','next':10,'started':45},
 {'ts':'2026-10-21T13:00:01Z','act':'wake','secs':3,'result':'ok','next':0,'started':0},
 {'ts':'2026-10-21T14:00:00Z','act':'fail'},
 {'ts':'2026-10-21T14:00:01Z','act':'deferred'},
 {'ts':'2026-10-20T14:00:01Z','act':'wake','secs':100,'result':'ok'}])+'\ninvalid\n')
d=daily(book,'2026-10-21')
assert (d['park'],d['wake'],d['fail'],d['deferred'],d['p50'],d['p95'],d['scheduled'],d['on_time_rate']) == (1,3,1,1,3,5,2,.5),d
PY
# Drive doctor's real --park entry using the real Control inventory and adapter.
row=$(sh "$BIN/fleet-doctor.sh" --park)
st_has 'doctor census' "$row" 'working 1 · idle 1 · parked 1 · saved 2048.0 MB · idle RSS 201.0 MB · eligible 1 · eligible RSS 201.0 MB'
st_ok 'park inventory → heartbeat census / doctor / daily ledger'
