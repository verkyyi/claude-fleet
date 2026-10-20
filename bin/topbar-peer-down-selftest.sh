#!/bin/bash
# topbar-peer-down-selftest.sh — 顶栏的「<机器> 连不上」只看链路此刻的 phase (issue #3959).
#
# fleet-peerlink.py's state.json keeps `fails` as the link's LIFETIME count — a
# rebuild that comes back up clears err / bad_since, never fails. fleet-topbar.py's
# peer_down read `fails > 0` as down, so a link that once failed drew 「mac-a
# 连不上」 forever while it was up at 28 ms. Pinned:
#   A. up + fails 9           → not down
#   B. down (phase down)      → down
#   C. reconnecting (phase starting / any non-up) → down
#   D. no phase (an older writer) + fails > 0 → down (the old reading, kept)
#   E. no file / no entry / another login → not down
# No tmux, no network. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tbpd-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

python3 - "$BIN/fleet-topbar.py" "$WORK" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("topbar", sys.argv[1])
tb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tb)
conf = sys.argv[2]
os.makedirs(os.path.join(conf, "peerlink"))
bad = 0

def case(name, links, node, login, want):
    global bad
    with open(os.path.join(conf, "peerlink", "state.json"), "w") as f:
        json.dump({"links": links}, f)
    got = tb.peer_down(conf, node, login)
    print("%s %s (want %s, got %s)" % ("PASS" if got == want else "FAIL", name, want, got))
    bad += got != want

up = {"machine": "mac-a", "login": "alice", "phase": "up", "fails": 9, "bad_since": 0.0, "err": ""}
case("A: up with lifetime fails", [up], "mac-a", "alice", False)
case("B: phase down", [dict(up, phase="down", err="Host key verification failed.")], "mac-a", "alice", True)
case("C: reconnecting", [dict(up, phase="starting")], "mac-a", "alice", True)
case("D: no phase, fails", [{"machine": "mac-a", "login": "alice", "fails": 2}], "mac-a", "alice", True)
case("E1: another login", [dict(up, phase="down", login="other")], "mac-a", "alice", False)
case("E2: no entry", [], "mac-a", "alice", False)
os.remove(os.path.join(conf, "peerlink", "state.json"))
got = tb.peer_down(conf, "mac-a", "alice")
print("%s E3: no file" % ("PASS" if got is False else "FAIL"))
bad += got is not False
sys.exit(1 if bad else 0)
PY
rc=$?
[ "$rc" -eq 0 ] || st_fail "a leg above printed FAIL (exit $rc)"
echo 'topbar-peer-down selftest: PASS'
