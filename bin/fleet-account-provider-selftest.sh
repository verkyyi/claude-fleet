#!/bin/bash
# Provider inventory/selection contracts; fixtures only, no real logins or hub.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 "$BIN/fleet-account-provider-selftest.py"
