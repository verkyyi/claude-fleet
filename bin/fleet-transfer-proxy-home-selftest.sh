#!/bin/bash
# Keep fleet-failover-selftest.py fixtures paired with proxy-home clean Stop checks.
# .fleet-account.py + fleet-transfer.sh: proxy home arm, clean Stop, bound successor.
BIN="$(cd "$(dirname "$0")" && pwd)"
exec bash "$BIN/fleet-transfer-selftest.sh" --proxy-home
