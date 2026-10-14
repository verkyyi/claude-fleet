#!/bin/bash
# Real private tmux socket/process doubles, plus independent cron delivery state.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
bash "$BIN/fleet-transfer-selftest.sh" --norepo
python3 - "$BIN/fleet-loop-selftest.py" <<'PY'
import runpy, sys, unittest
v=runpy.run_path(sys.argv[1])
suite=unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(v[n]) for n in ('CronTests','NativeCronTests'))
for name in ('test_two_cron_jobs_deliver_independently_once_and_preserve_expiry', 'test_ambiguous_multi_cron_delivery_is_never_resent'):
    suite.addTest(v['LoopTests'](name))
raise SystemExit(not unittest.TextTestRunner().run(suite).wasSuccessful())
PY
