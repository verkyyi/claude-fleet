#!/usr/bin/env python3
"""compat-1v: 下一批删 — report delegation retired; existing audit remains readable."""
import json
import os
from pathlib import Path
import sys

RETIRED = "RETIRED: Parent report delegation is disabled; nothing was delivered."


def history():
    path = Path(os.environ.get("FLEET_CONF_DIR") or Path.home() / ".config/claude-fleet") / "report-delegation/audit.ndjson"
    try:
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    except FileNotFoundError:
        return []


def active(rows):
    grants = {}
    for row in rows:
        if row['action'] == 'grant':
            grants[row['id']] = row
        elif row['action'] == 'revoke':
            grants.pop(row['id'], None)
    return list(grants.values())


def change(*args, **kwargs):
    raise ValueError(RETIRED)


def deliver(*args, **kwargs):
    raise ValueError(RETIRED)


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action not in ("audit", "show"):
        print(RETIRED, file=sys.stderr)
        return 2
    try:
        rows = history()
        print(json.dumps(rows if action == "audit" else active(rows), ensure_ascii=False))
        return 0
    except (OSError, ValueError, KeyError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
