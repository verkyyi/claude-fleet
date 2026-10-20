#!/bin/bash
# sel-visible-selftest.sh — the selected row shows on any terminal (issue #3416).
# iPhone Termius (xterm-256color, no COLORTERM) mapped ⌘P's ANSI-blue row ground
# onto its own background: the selection vanished. fleet-quickopen.py's
# `sel_attr` / `rich_color` are the one rule — a colour ground only where the
# terminal says truecolour, reverse video everywhere else — and every list keeps
# a `›` that needs no colour at all.
#
#   A  rich_color / sel_attr over TERM × COLORTERM (8 / 256 colours, none /
#      truecolor / 24bit);
#   C  every popup that draws a selection goes through the helper — no bare
#      `color_pair(…) if sel` ground left in quickopen / quick-dispatch / compose.
# (B, the old client's ⌘P list drawn for real, went with that list — issue #3008;
# the 看台's own list is fleet_view.py's.)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
python3 - "$BIN" <<'PY'
import importlib.util, re, sys
from pathlib import Path

BIN = Path(sys.argv[1])
fails = []


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        fails.append(what)


spec = importlib.util.spec_from_file_location("fleet_quickopen", str(BIN / "fleet-quickopen.py"))
qo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qo)
import curses

# A — the rule
for colors, ct, rich in ((8, "", False), (8, "truecolor", False), (256, "", False),
                         (256, "truecolor", True), (256, "24bit", True), (256, "TrueColor", True),
                         (16, "24bit", False)):
    check(qo.rich_color(colors, {"COLORTERM": ct}) is rich, "A rich_color(%d, %r) = %s" % (colors, ct, rich))
check(qo.sel_attr(2, 256, {}) == curses.A_REVERSE | curses.A_BOLD, "A sel_attr: reverse + bold off truecolour")
check(qo.sel_attr(2, 8, {"COLORTERM": "truecolor"}) & curses.A_REVERSE, "A sel_attr: 8 colours reverse even with COLORTERM")


# C — no popup paints a selection ground past the helper
bare = re.compile(r"color_pair\((?:2|3|PAIR_ON)\)[^\n]*\bif (?:sel|on|n == menu_at|focus == kind)\b")
for name in ("fleet-quickopen.py", "fleet-quick-dispatch.py", "fleet-compose.py"):
    hits = [ln for ln in (BIN / name).read_text().splitlines() if bare.search(ln)]
    check(not hits, "C %s: selection ground via sel_attr %s" % (name, hits[:1] or ""))
print("selftest %s (%d failed)" % ("FAIL" if fails else "PASS", len(fails)))
sys.exit(1 if fails else 0)
PY
