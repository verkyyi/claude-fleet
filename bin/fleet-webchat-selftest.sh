#!/bin/bash
# fleet-webchat-selftest.sh — the browser chat (issue #3567): extras/web-chat/server.mjs
# as bin/fleet-webchat.sh starts it, with a stub Agent SDK / fleet-session-cred.sh /
# credential proxy — binds 127.0.0.1 only, nobody without the one-time link gets in,
# the model allowlist is the server's, the turn's usage goes through the proxy on a
# minted session credential, and no credential reaches a response, a log or a file.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 18 ]; then
  echo "SKIP fleet-webchat-selftest: node >= 18 not found"; exit 0
fi
exec node "$BIN/fleet-webchat-selftest.mjs"
