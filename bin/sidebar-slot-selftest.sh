#!/bin/bash
# sidebar-slot-selftest.sh — a switch between machines resizes no app pane
# (issue #1702). The one list view moves between windows; fleet-sidebar.py's
# move_view used to `join-pane` it, which re-lays out BOTH windows — the one it
# left widened its app pane back, the one it entered narrowed it — a SIGWINCH,
# and a whole-screen repaint, into another machine's Claude Code each way. A
# proxy window (`@remote`) now keeps a SLOT in the view's cell and the view is
# `swap-pane`d with it, so after a window's first visit its app pane never
# changes size again.
#   A. local → proxy   — no slot anywhere yet: the join, as before
#   B. proxy → proxy   — the window left keeps a slot; its app pane keeps its size
#   C. steady state    — P1 ⇄ P2 ⇄ P1: every app pane's WxH unchanged (the
#                        issue's acceptance line), active pane still the proxy's,
#                        one view in the session
#   D. proxy → local   — the proxy window left keeps a slot, its size unchanged
#   E. local → proxy   — the proxy's slot is taken, the local window gets none
#                        back: full width again, as before
#   F. sync, list off  — every slot goes (conf/fleet-sidebar.sh hide)
#   G. sync, window    — a slot in a window with no content left goes, so it
#                        never holds a closed proxy window open
#   H. conf            — after-select-pane bounces off a slot in both confs
#                        (conf/tmux-shell.conf, conf/tmux-attention.conf)
# Real tmux on an isolated socket via a PATH shim. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { echo 'selftest SKIP: tmux missing'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'selftest SKIP: python3 missing'; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sbslot.XXXXXX")
SOCK="sbslot$$"
mkdir -p "$WORK/shim"
printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$REAL_TMUX" "$SOCK" >"$WORK/shim/tmux"
chmod +x "$WORK/shim/tmux"
cleanup() { FLEET_ALLOW_TMUX_DESTROY=1 "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT
unset TMUX TMUX_PANE

PATH="$WORK/shim:$PATH" python3 - "$BIN" "$WORK" <<'PY'
import importlib.util, subprocess, sys, time
from pathlib import Path
BIN, WORK = Path(sys.argv[1]), sys.argv[2]
spec = importlib.util.spec_from_file_location("sb", BIN / "fleet-sidebar.py")
sb = importlib.util.module_from_spec(spec); spec.loader.exec_module(sb)
LOCK = WORK + "/sb.lock"
checks = 0

def t(*a):
    return subprocess.run(["tmux", *a], text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL).stdout.strip()

def eq(name, want, got):
    global checks
    checks += 1
    if want != got:
        print("FAIL: %s\n  want: %r\n  got:  %r" % (name, want, got))
        sys.exit(1)

HOLD = "while :; do sleep 300; done"
t("-f", "/dev/null", "new-session", "-d", "-s", "f", "-x", "152", "-y", "26", "-n", "issue-1", HOLD)
t("set-option", "-g", "window-size", "manual")
L = t("display-message", "-p", "-t", "f:issue-1", "#{window_id}")
t("set-option", "-w", "-t", L, "@issue", "1")
P = {}
for node in ("m4", "m5"):
    w = t("new-window", "-d", "-P", "-F", "#{window_id}", "-t", "f:", "-n", node, HOLD)
    t("set-option", "-w", "-t", w, "@remote", node + ":x/issue-" + node)
    P[node] = w
P1, P2 = P["m4"], P["m5"]
app = {w: t("display-message", "-p", "-t", w, "#{pane_id}") for w in (L, P1, P2)}
def mkview(w):
    """A view pane beside w's app pane, as sync would have made it."""
    pane = t("split-window", "-d", "-h", "-b", "-f", "-l", "38", "-P", "-F", "#{pane_id}", "-t", app[w], HOLD)
    t("set-option", "-p", "-t", pane, "@sidebar", "1", ";",
      "set-option", "-p", "-t", pane, "@sidebar_version", sb.VIEW_VERSION, ";",
      "set-option", "-w", "-t", w, "@sidebar_worker", app[w])
    return pane

VP = mkview(L)

def size(w):
    return t("display-message", "-p", "-t", app[w], "#{pane_width}x#{pane_height}")

def sizes():
    return " ".join(size(w) for w in (P1, P2))

def where(pane):
    return t("display-message", "-p", "-t", pane, "#{window_id}")

def slots(w):
    return t("list-panes", "-t", w, "-F", "#{?#{==:#{@sidebar_slot},1},#{pane_id},}").replace("\n", " ").strip()

def active(w):
    return t("display-message", "-p", "-t", w, "#{pane_id}")

def go(w):
    sb.jump("f", w, VP, LOCK)
    eq("jump lands in " + w, w, t("display-message", "-p", "-t", "f:", "#{window_id}"))
    eq("…with the view", w, where(VP))

# A. local → proxy: nothing to swap with — the join, as before.
go(P1)
eq("A: P1 narrowed once by the join", "113x26", size(P1))
eq("A: L widened back (a local window keeps no slot)", "152x26", size(L))
eq("A: no slot anywhere", "", slots(L) + slots(P1) + slots(P2))

# B. proxy → proxy: P1 keeps a slot, its app pane its size.
before = size(P1)
go(P2)
eq("B: P1's app pane did not widen back", before, size(P1))
eq("B: …a slot holds the view's cell", 1, len(slots(P1).split()))
eq("B: P2 has no slot (the view is there)", "", slots(P2))

# C. the acceptance: switching machines changes no app pane's size.
steady = sizes()
for w in (P1, P2, P1, P2):
    go(w)
    eq("C: every proxy app pane WxH unchanged after → " + w, steady, sizes())
    eq("C: P1's active pane is its proxy pane", app[P1], active(P1))
    eq("C: P2's active pane is its proxy pane", app[P2], active(P2))
    eq("C: one view in the session", "1", str(t("list-panes", "-s", "-t", "f", "-F", "#{@sidebar}").split().count("1")))
eq("C: one slot, in the proxy window not shown", (1, ""), (len(slots(P1).split()), slots(P2)))

# D. proxy → local: P2 keeps a slot too.
go(L)
eq("D: proxy app panes unchanged", steady, sizes())
eq("D: the slot went to P2, none stays in L", (1, ""), (len(slots(P2).split()), slots(L)))

# E. local → proxy: P2's slot taken, L full width again with no slot.
go(P2)
eq("E: proxy app panes unchanged", steady, sizes())
eq("E: L back to full width, no slot", ("152x26", ""), (size(L), slots(L)))
eq("E: P2 holds the view, no slot", "", slots(P2))

# F. sync with the list off: every slot goes.
eq("F: a slot exists before", 1, len(slots(P1).split()))
sb.sync("f", "0", 38, LOCK)
eq("F: …and none after", "", slots(L) + slots(P1) + slots(P2))
eq("F: (the view went too — the list is off)", "", where(VP))
VP = mkview(P2)

# G. sync: a slot left alone in its window goes (it would hold the window open).
go(P1)                       # leaves a slot in P2
S2 = slots(P2)
eq("G: P2 has a slot", 1, len(S2.split()))
t("kill-pane", "-t", app[P2])
sb.sync("f", "1", 38, LOCK)
eq("G: the slot went with its window's content", False, S2 in t("list-panes", "-s", "-t", "f", "-F", "#{pane_id}").split())
eq("G: …and so did the window", False, P2 in t("list-windows", "-t", "f", "-F", "#{window_id}").split())
print("selftest PASS: %d checks" % checks)
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

# H. a click on a slot never leaves it the window's active pane — the proxy's
# respawn targets the window's active pane (fleet-remote-view.sh).
for c in tmux-shell.conf tmux-attention.conf; do
  grep -q "after-select-pane.*@sidebar_slot.*last-pane" "$BIN/../conf/$c" \
    || { echo "FAIL: H: $c's after-select-pane does not bounce off a slot"; exit 1; }
done
echo 'selftest PASS: H conf hooks'
