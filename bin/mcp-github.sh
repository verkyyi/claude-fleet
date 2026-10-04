#!/bin/bash
# mcp-github.sh — start the GitHub MCP server with a token that never touches disk
# (issue #1559, EPIC #1524 C12). conf/agent-defaults wires it as the `github`
# server for Claude (~/.claude.json) and Codex ($CODEX_HOME/config.toml) on every
# managed login:
#
#   bash -lc 'exec "$HOME/.claude/fleet/bin/mcp-github.sh"'
#
# The token is read from `gh auth token` HERE, at start, and handed to the server
# through its environment only — it is never written into a config file, so the
# merged configs can be grepped for tokens and come up empty (the selftest does).
#
# Runtime, first found wins:
#   $GITHUB_MCP_SERVER            an explicit binary (path)
#   github-mcp-server on PATH     the official server (`brew install github-mcp-server`)
#   npx @modelcontextprotocol/server-github   the archived npm server — works, no
#                                 install step; one stderr line says so
set -uo pipefail
tok=$(gh auth token 2>/dev/null) || tok=''
if [ -z "$tok" ]; then
  echo 'mcp-github: no GitHub token — `gh auth login` on this login first' >&2
  exit 1
fi
export GITHUB_PERSONAL_ACCESS_TOKEN="$tok"
unset tok
if [ -n "${GITHUB_MCP_SERVER:-}" ] && [ -x "$GITHUB_MCP_SERVER" ]; then
  exec "$GITHUB_MCP_SERVER" stdio "$@"
fi
if command -v github-mcp-server >/dev/null 2>&1; then
  exec github-mcp-server stdio "$@"
fi
if command -v npx >/dev/null 2>&1; then
  echo 'mcp-github: github-mcp-server not on PATH — using npx @modelcontextprotocol/server-github (brew install github-mcp-server for the official one)' >&2
  exec npx -y @modelcontextprotocol/server-github "$@"
fi
echo 'mcp-github: neither github-mcp-server nor npx on PATH — brew install github-mcp-server' >&2
exit 1
