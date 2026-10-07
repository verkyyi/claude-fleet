#!/usr/bin/env python3
"""fleet users list | add <name> [--machine-login <login>] | remove <name>

Who may sign in to the hub with GitHub (claude-fleet#1986) — `fleet hub users`
under its own name; see bin/fleet-hub-admin.py for the auth and the exit codes.
"""
import os
import sys

here = os.path.dirname(os.path.realpath(__file__))
os.execv(sys.executable, [sys.executable, os.path.join(here, "fleet-hub-admin.py"), "users"] + sys.argv[1:])
