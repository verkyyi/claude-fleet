#!/usr/bin/env python3
"""Fleet Hub administrator CLI and MCP server; see docs/FLEET-HUB.md.

`fleet hub set|get|unset|settings|users …` are the hub's own settings and
people list (claude-fleet#1986), in bin/fleet-hub-admin.py.
"""
import os
import sys

if len(sys.argv) > 1 and sys.argv[1] in ("set", "get", "unset", "settings", "users"):
    _admin = os.path.join(os.path.dirname(os.path.realpath(__file__)), "fleet-hub-admin.py")
    os.execv(sys.executable, [sys.executable, _admin] + sys.argv[1:])

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fleet_hub import main

if __name__ == "__main__":
    sys.exit(main())
