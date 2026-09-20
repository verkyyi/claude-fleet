#!/usr/bin/env python3
"""Fleet Hub administrator CLI and MCP server; see docs/FLEET-HUB.md."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fleet_hub import main

if __name__ == "__main__":
    sys.exit(main())
