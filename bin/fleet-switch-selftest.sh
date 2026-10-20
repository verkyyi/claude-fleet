#!/bin/bash
# fleet-switch-selftest.sh — switching sessions from the keyboard (issue #1903,
# EPIC #1906 C10): the helpers bin/fleet-quickopen.py keeps for the 看台
# (fleet_view.py) after the old client's list, ⌘P and its row menu went with
# that client (issue #3008; the 看台's own keys are fleet-view-*-selftest.sh's).
#
#   A  the history steps like a browser's and skips a closed row; the stack and
#      the recency are capped; rows_text folds a heading into its rows' group;
#      parse_rows reads a lost machine's `!` and a via `~` off the machine mark
#   C  no iTerm2: the profile writer writes nothing and says no-iterm (the iTerm2
#      `fleet` profile is what a fresh install's ⌘P / ⌘↓ ride)
#
# Drives: bin/fleet-quickopen.py, bin/fleet-iterm-profile.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"

# --- A ---------------------------------------------------------------------------
python3 - "$BIN" <<'PY' || st_fail "leg A (its FAIL line above)"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("q", os.path.join(sys.argv[1], "fleet-quickopen.py"))
q = importlib.util.module_from_spec(spec); spec.loader.exec_module(q)
errs = []
n = [0]
def eq(what, got, want):
    n[0] += 1
    if got != want:
        errs.append("%s: %r, want %r" % (what, got, want))
h = {"stack": [], "at": -1, "mru": []}
for k in ("@1", "@2", "@3", "@2"):
    q.visit(h, k)
eq("stack", h["stack"], ["@1", "@2", "@3", "@2"])
eq("mru", h["mru"], ["@2", "@3", "@1"])
live = {"@1", "@2", "@3"}
eq("back", q.step(h, live, -1), "@3")
q.visit(h, "@3")  # the list sees the row it stepped onto: no new entry
eq("a step adds no entry", h["stack"], ["@1", "@2", "@3", "@2"])
eq("back skips a closed row", q.step(h, {"@1", "@3"}, -1), "@1")
eq("back at the start", q.step(h, live, -1), "")
eq("fwd", q.step(h, live, 1), "@2")
q.visit(h, "@4")  # a new switch drops what was ahead
eq("a switch after back truncates", h["stack"], ["@1", "@2", "@4"])
eq("a test function for live", q.step(h, lambda k: k == "@1", -1), "@1")
for i in range(80):
    q.visit(h, "@x%d" % i)
eq("stack cap", len(h["stack"]), q.STACK_MAX)
eq("at stays on the top", h["stack"][h["at"]], "@x79")
# rows_text: the list's rows → switch-rows.tsv, headings folded into a group
text = q.rows_text([["hdr", "verkyyi/claude-fleet", "", "verkyyi/claude-fleet", ""],
                    ["@9", "needs", "!", " nine", "", "b", "0", "", "mac-a", "", "", "", ""]])
# issue #2365 appends issue · PR · reap · title · repo after the seven
eq("rows_text", text, "@9\tneeds\t!\tnine\tmac-a\tverkyyi/claude-fleet\tb\t\t\t\t\tverkyyi/claude-fleet\n")
# a lost machine's rows (issue #3164)
rows = q.parse_rows("k1\tworking\t●\tone\tmac-a!\tg\t\nk2\tidle\t○\ttwo\tmac-b~\tg\t\nk3\tidle\t○\tthree\t\tg\t\n")
eq("parse: lost", [r["lost"] for r in rows], [True, False, False])
eq("parse: the machine without its mark", [r["node"] for r in rows], ["mac-a", "mac-b", ""])
if errs:
    print("FAIL A:\n  " + "\n  ".join(errs)); sys.exit(1)
print("A: the history, the rows: %d checks" % n[0])
PY

# --- C ---------------------------------------------------------------------------
python3 - "$BIN" <<'PY' || st_fail "leg C (its FAIL line above)"
import os, subprocess, sys, tempfile
from pathlib import Path
bin_dir = Path(sys.argv[1])
work = Path(tempfile.mkdtemp())
errs = []
# no iTerm2 here (a HOME without ~/Library/Application Support/iTerm2): nothing written
# (no bytecode either: Apple's CommandLineTools python caches it under
# $HOME/Library/Caches/com.apple.python, which is not the writer writing)
env = dict(os.environ, HOME=str(work), PYTHONDONTWRITEBYTECODE="1")
for k in ("FLEET_ITERM_DIR", "ITERM_PROFILE", "TERM_PROGRAM", "LC_TERMINAL"):
    env.pop(k, None)
r = subprocess.run(["python3", str(bin_dir / "fleet-iterm-profile.py"), "write"], env=env)
if r.returncode != 0 or any(work.rglob("*")):
    errs.append("no iTerm2: write wrote %s (rc %d)" % ([str(p) for p in work.rglob("*")], r.returncode))
st = subprocess.run(["python3", str(bin_dir / "fleet-iterm-profile.py"), "status"], env=env, capture_output=True, text=True)
if st.stdout.strip() != "no-iterm" or st.returncode != 2:
    errs.append("no iTerm2: status %r rc %d" % (st.stdout, st.returncode))
if errs:
    print("FAIL C:\n  " + "\n  ".join(errs)); sys.exit(1)
print("C: no iTerm2 = nothing written")
PY
echo "fleet-switch selftest: OK"
