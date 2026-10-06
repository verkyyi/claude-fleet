#!/usr/bin/env python3
"""The pre-#1807 fleet-peer server (list_agents / send_message, issue #1185).

Its tools now live in bin/fleet-mcp.py — the one tool service, as `agents` and
`send` (issue #1807). This shim keeps a config that still mounts fleet-peer
working for one version; mount bin/fleet-mcp.py (conf/mcp-worker.json) instead.
"""
import os
import sys

here = os.path.dirname(os.path.realpath(__file__))
os.execv(sys.executable, [sys.executable, os.path.join(here, "fleet-mcp.py"), "--legacy-peer"])
