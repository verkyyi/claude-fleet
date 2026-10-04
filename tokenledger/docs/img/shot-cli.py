#!/usr/bin/env python3
"""Render a couple of CLI commands as a terminal SVG for the README.

Rich, the same way claude-fleet's images are made, so the two projects' docs
look like one family.

    pip install rich
    docs/img/shot-cli.py <path-to-demo.db> [out.svg]

Only commands that honour --db belong here. `ccquota report` reads the real
transcripts on THIS machine and `ccquota name`/`budget` reach for a hub -- see
the warning below -- so neither can be photographed safely.
"""

import os
import re
import subprocess
import sys

from rich.console import Console
from rich.text import Text

db = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CCQUOTA_DB", "")
out = sys.argv[2] if len(sys.argv) > 2 else "docs/img/cli.svg"
if not db or not os.path.exists(db):
    sys.exit("usage: shot-cli.py <path-to-demo.db> [out.svg]")

binary = os.environ.get("CCQUOTA_BIN", "ccquota")

# Only commands that take --db and nothing else.
#
# `ccquota name` is deliberately absent. Its --hub defaults to
# $CCQUOTA_HUB_URL and, when that is set -- which it is on any machine running
# an agent -- the hub is used INSTEAD OF --db, with no warning. So
# `ccquota name --db ./demo.db` prints the production hub's real accounts. That
# is how a real email address nearly ended up in this image.
COMMANDS = [
    ["team", "--list", "--db", db],
    ["plan", "--list", "--db", db],
]

# Last line of defence, not the first: if anything here reaches a real hub, the
# render fails loudly instead of writing a file nobody re-reads.
#
# Stated as an ALLOW-list on purpose. A deny-list would have to spell out the
# real addresses and hostnames it is protecting, and this file is public — the
# guard would publish exactly what it exists to keep out. "Everything that
# looks like an identity must be example.com" needs no such list, and it also
# catches identities nobody thought to enumerate.
IDENTITY = re.compile(
    r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+"       # email addresses
    # Hostnames. The final label must be alphabetic: without that, a money
    # column ("200.00") reads as a domain and the guard fails the render on
    # its own demo data.
    r"|(?<![\w.])[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}(?![\w.])"
    r"|/(?:Users|home)/[A-Za-z0-9._-]+"       # absolute home paths
)
ALLOWED_SUFFIXES = ("example.com",)

console = Console(record=True, width=100)

for i, cmd in enumerate(COMMANDS):
    # Show the command a reader would type, with the throwaway path elided.
    shown = " ".join(["ccquota"] + ["<hub.db>" if c == db else c for c in cmd])
    console.print(Text("$ ", style="bold green") + Text(shown, style="bold white"))
    res = subprocess.run(
        [binary, *cmd], capture_output=True, text=True, env={**os.environ}
    )
    body = (res.stdout or res.stderr).rstrip("\n")

    for found in IDENTITY.findall(body):
        if found.endswith(ALLOWED_SUFFIXES):
            continue
        sys.exit(
            f"refusing to render: output of {shown!r} contains {found!r}, "
            "which is not an example.com identity.\n"
            "Either a command reached a real hub instead of the demo database, "
            "or the demo data grew a real-looking name. Nothing was written."
        )

    console.print(Text(body, style="grey85"))
    if i != len(COMMANDS) - 1:
        console.print()

console.save_svg(out, title="tokenledger")
print(f"wrote {out}")
