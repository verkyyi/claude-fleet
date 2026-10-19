#!/bin/bash
# Existing native observation: bin/fleet_native_observe.py, bin/fleet_repo_authority.py,
# bin/fleet_launch.py, bin/fleet-codex-session.py, bin/fleet-codex-rpc.py,
# bin/fleet_hub_rest.py, bin/fleet_sleep_argv.py, bin/.fleet-account.py,
# bin/fleet-cred-proxy.py, bin/fleet-cred-proxy.sh, bin/fleet_native_observe_test.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 "$BIN/fleet_native_observe_test.py"
