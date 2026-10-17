#!/bin/bash
# selftest-part-of: fleet-node-supervisor-selftest.sh
# bin/fleet-node-supervisor-selftest.py; independent fixture, imports through cleanup.
exec python3 -W ignore::ResourceWarning "${BASH_SOURCE[0]%/*}/fleet-node-supervisor-selftest-budget.py" U_OnDemand.test_ensure_after_stop
