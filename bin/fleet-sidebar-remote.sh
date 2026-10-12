#!/bin/bash
# fleet-sidebar-remote.sh — renamed bin/fleet-row-remote.sh (issue #3732): a
# 看台 or list started before the rename still calls this name by path.
# compat-1v: 下一批删
exec bash "$(cd "$(dirname "$0")" && pwd)/fleet-row-remote.sh" "$@"
