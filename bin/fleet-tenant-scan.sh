#!/bin/bash
# fleet-tenant-scan.sh — run AS a freshly opened ordinary login: try every way
# into the subscription, root and other people's sessions, and pass only when
# each is refused (issue #2298, EPIC #2293 C7). bin/fleet-tenant-scan.py does
# the work and documents the items; one table row per item, each a docs/BREAK-IT.md row.
#
#   fleet-tenant-scan.sh [--only a,b] [--json] [--hashes FILE] [--no-hub] [--no-drill] [--no-ports]
#
# On a real machine (EPIC #2293 convention 5 — a NEW ordinary login, never the admin):
#   sudo -u <drill login> -i bash <checkout>/bin/fleet-tenant-scan.sh
# Exit: 0 every metric 0 · 1 a way in still works · 2 usage · 3 run as root
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 -I "$BIN/fleet-tenant-scan.py" "$@"
