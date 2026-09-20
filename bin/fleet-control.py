#!/usr/bin/env python3
"""Fleet's fixed local/SSH control entry point; see docs/FLEET-HUB.md."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fleet_control import main

if __name__ == "__main__":
    sys.exit(main())
