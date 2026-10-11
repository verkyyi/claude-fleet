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
#   B  draw_cmds (⌘P's `>` list) for real, under curses on a pty, per terminal:
#      the selected line carries `›`; low depth draws it in reverse (SGR 7), a
#      truecolour 256 terminal keeps the coloured ground and no reverse;
#   C  every popup that draws a selection goes through the helper — no bare
#      `color_pair(…) if sel` ground left in quickopen / quick-dispatch / compose / ask.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'selftest SKIP: python3 missing'; exit 0; }
python3 - "$BIN" <<'PY'
import importlib.util, os, pty, re, sys
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


# B — drawn for real
def draw(term, colorterm):
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ, TERM=term)
        env.pop("COLORTERM", None)
        if colorterm:
            env["COLORTERM"] = colorterm
        os.environ.clear()
        os.environ.update(env)
        try:
            def run(screen):
                curses.use_default_colors()
                curses.init_pair(2, -1, curses.COLOR_BLUE)
                h, w = screen.getmaxyx()
                items = [("a", "alpha", "first"), ("b", "beta", "second"), ("c", "gamma", "third")]
                qo.draw_cmds(screen, ">", "", items, 1, w, h, {})
                screen.refresh()
            import locale
            for loc in ("en_US.UTF-8", "C.UTF-8"):   # macOS has the first, a CI box the second
                try:
                    locale.setlocale(locale.LC_ALL, loc)
                    break
                except locale.Error:
                    pass
            curses.wrapper(run)
        finally:
            os._exit(0)
    out = b""
    while True:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    os.waitpid(pid, 0)
    return out


for term, ct, low in (("xterm", "", True), ("xterm", "truecolor", True), ("xterm-256color", "", True),
                      ("xterm-256color", "truecolor", False), ("screen-256color", "", True)):
    raw = draw(term, ct)
    text = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][0-9A-Za-z]|\x1b[=>]", b"", raw).decode("utf-8", "replace")
    tag = "B TERM=%s COLORTERM=%s" % (term, ct or "-")
    check("› beta" in text and "› alpha" not in text, tag + ": `›` marks the selected line only")
    at = raw.find("beta".encode())
    rev = re.search(rb"\x1b\[(?:[0-9;]*;)?7(?:;[0-9;]*)?m", raw[:at]) is not None
    if low:
        check(rev, tag + ": selected line drawn in reverse video")
    else:
        check(not rev, tag + ": truecolour keeps the colour ground (no reverse)")
        check(re.search(rb"\x1b\[(?:44|48;5;4)m", raw) is not None, tag + ": the blue ground is drawn")

# C — no popup paints a selection ground past the helper
bare = re.compile(r"color_pair\((?:2|3|PAIR_ON)\)[^\n]*\bif (?:sel|on|n == menu_at|focus == kind)\b")
for name in ("fleet-quickopen.py", "fleet-quick-dispatch.py", "fleet-compose.py"):
    hits = [ln for ln in (BIN / name).read_text().splitlines() if bare.search(ln)]
    check(not hits, "C %s: selection ground via sel_attr %s" % (name, hits[:1] or ""))
check("sel_attr(3)" in (BIN / "fleet-ask.py").read_text(), "C fleet-ask.py: the chosen answer via sel_attr")

print("selftest %s (%d failed)" % ("FAIL" if fails else "PASS", len(fails)))
sys.exit(1 if fails else 0)
PY
