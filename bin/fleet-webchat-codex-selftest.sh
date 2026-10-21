#!/bin/bash
# fleet-webchat-codex-selftest.sh — the web chat's Codex side (task R9A2): runs
# bin/fleet-webchat-codex-selftest.mjs (extras/web-chat/server.mjs + codex.mjs
# against a fake `codex app-server`). Needs node >= 18.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 18 ]; then
  echo "SKIP fleet-webchat-codex-selftest: node >= 18 not found"; exit 0
fi
exec node "$BIN/fleet-webchat-codex-selftest.mjs"
