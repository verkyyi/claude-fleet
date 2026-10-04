#!/bin/bash
# mcp-fetch.sh — start the reference `fetch` MCP server (mcp-server-fetch) on
# whatever Python runner this login has (issue #1559, EPIC #1524 C12).
# conf/agent-defaults wires it as the `fetch` server for Claude and Codex:
#
#   bash -lc 'exec "$HOME/.claude/fleet/bin/mcp-fetch.sh"'
#
# Runtime, first found wins:
#   uvx mcp-server-fetch          (`brew install uv`) — the usual one
#   pipx run mcp-server-fetch
#   python3 -m mcp_server_fetch   when the package is installed in that python
# None → one stderr line naming the install step, exit 1: the server shows as
# failed in `claude mcp list` / `codex mcp list` instead of silently missing.
set -uo pipefail
if command -v uvx >/dev/null 2>&1; then
  exec uvx mcp-server-fetch "$@"
fi
if command -v pipx >/dev/null 2>&1; then
  exec pipx run mcp-server-fetch "$@"
fi
if command -v python3 >/dev/null 2>&1 && python3 -c 'import mcp_server_fetch' >/dev/null 2>&1; then
  exec python3 -m mcp_server_fetch "$@"
fi
echo 'mcp-fetch: no runner for mcp-server-fetch — brew install uv (uvx), or pipx' >&2
exit 1
