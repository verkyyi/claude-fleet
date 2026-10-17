#!/bin/bash
# selftest-deps: nogh_live_contract.py nogh_live_observer.py nogh_live_runtime.py nogh_live_gateway.py nogh_live_http.py nogh_live_identity.py nogh_live_evidence.py nogh_live_driver.py nogh_live_render.py nogh-live-selftest.py extras/managed-node/render.py
# Offline C9 contract checks only; full live acceptance belongs to its owner.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 exec python3 "$BIN/nogh-live-selftest.py"
