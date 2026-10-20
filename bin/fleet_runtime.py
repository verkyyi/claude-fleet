#!/usr/bin/env python3
"""Retired: the provider observations of a launch-proof session (EPIC T497 C8).

Every observation here read a window's launch receipt (@launch_receipt), which
nothing writes since C8 — a window is its ID. The fleet mod still names this
file for a session that carries FLEET_LAUNCH_CONTEXT (none is started now); its
`event` is taken and dropped, every read answers unknown, never a delivery.
"""
import json
import sys


def main(argv):
    command = argv[0] if argv else ""
    if command == "event":
        return 0
    print(json.dumps(dict(version=1, state="unknown", reason="launch_proof_retired"),
                     separators=(",", ":")))
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
