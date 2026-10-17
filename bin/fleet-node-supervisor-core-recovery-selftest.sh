#!/bin/bash
# selftest-part-of: fleet-node-supervisor-selftest.sh
# bin/fleet-node-supervisor-selftest.py; independent fixture, imports through cleanup.
exec python3 -W ignore::ResourceWarning "${BASH_SOURCE[0]%/*}/fleet-node-supervisor-selftest-budget.py" O_SweepRemoves.test_a_core_gone_from_launchd_is_put_back
