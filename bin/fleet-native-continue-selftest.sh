#!/bin/bash
# bin/fleet_native_continue.py bin/fleet_native_continue_test.py
# bin/fleet_native_observe.py bin/fleet-input.py bin/fleet_repo_authority.py
# bin/fleet-codex-rpc.py bin/fleet-codex-session.py bin/fleet_worker_life.py
# bin/fleet_native_registration.py bin/fleet_native_registration_test.py hooks/settings-hooks.json
# bin/.fleet-transfer.py bin/fleet-cleanup.sh bin/worktree-autoclean.sh bin/fleet-lib.sh
# bin/fleet-native-cleanup-selftest.py bin/fleet_runtime.py docs/dev/NATIVE-OBSERVE.md
# bin/fleet_native_continue_native_test.py bin/fleet_agent_mcp.py bin/fleet_agent_argv.py bin/fleet-mcp.py
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 "$BIN/fleet_native_continue_test.py"
python3 "$BIN/fleet_native_registration_test.py"
python3 "$BIN/fleet-native-cleanup-selftest.py"
