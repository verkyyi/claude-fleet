#!/bin/sh
# fleet-notice.sh — the fleet's one on-screen notice, from any shell (T675).
#   fleet-notice.sh <error|warn|info> <text> [--next <下一步>] [--client <name>]
#                   [--sock <label>] [--all] [--source <name>] [--secs N]
#   fleet-notice.sh list [--n 50] [--json] | page | unread | read | seen <tag>
# bin/fleet_notice.py is the implementation (tiers, the record, the 看台's line).
here=$(cd "$(dirname "$0")" && pwd)
case "${1:-}" in
  list|page|unread|read|seen) exec python3 "$here/fleet_notice.py" "$@" ;;
  error|warn|info) exec python3 "$here/fleet_notice.py" notify "$@" ;;
  *) echo "usage: fleet-notice.sh <error|warn|info> <text> [--next …] [--client …] | list | page | unread | read" >&2; exit 2 ;;
esac
