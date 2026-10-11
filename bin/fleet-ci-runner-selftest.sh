#!/bin/bash
# fleet-ci-runner-selftest.sh — the machine's test runner, sandboxed (issue #3144,
# EPIC #3139 C5): bin/fleet-ci-runner.py (yield, the login, the pinned runner, one
# JIT runner at a time, the App credential), bin/fleet-ci-job-gate.sh and
# bin/fleet-node-supervisor.py's ci-runner child / word / line / tenant.
# Cases in bin/fleet-ci-runner-selftest.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 -W ignore::ResourceWarning "$BIN/fleet-ci-runner-selftest.py"
