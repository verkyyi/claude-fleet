#!/bin/bash
# close-lands-next-selftest.sh — closing a task lands on its neighbour (issue #900).
#
# Closing the window you are on used to leave the client wherever tmux chose —
# usually the hub. Now fleet-sidebar.py publishes, for the task on screen, the
# ordered landing candidates (`@sidebar_next`, pinned to that window by
# `@sidebar_next_of`), and the hub-arrival hook (session-window-changed[73] →
# fleet-hub-visits.sh record) moves a `closed` arrival on to the first candidate
# that is alive, awake and not a panel, logging `closed-next`. Asserts:
#   • landing(): rows below first, then above nearest-first; not in list ⇒ none
#   • the node conf no longer sets the hub-arrival hook, and drops it from a
#     live server (issue #1714 — the tmux legs that drove it went with it)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CONF="$BIN/../conf/tmux-attention.conf"

fail() {
  printf 'selftest FAIL: %s\n' "$1" >&2
  [ -f "${LOG:-}" ] && { printf -- '--- %s ---\n' "$LOG" >&2; cat "$LOG" >&2; }
  exit 1
}

# --- landing(): the pure ordering rule ----------------------------------------
got="$(python3 - "$BIN/fleet-sidebar.py" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sb", sys.argv[1])
sb = importlib.util.module_from_spec(spec); spec.loader.exec_module(sb)
ids = ["@1", "@2", "@3", "@4"]
for w in ("@2", "@4", "@1", "@9"):
    print(w + "=" + ",".join(sb.landing(ids, w)))
print("cap", len(sb.landing([f"@{i}" for i in range(20)], "@0")))
EOF
)" || fail "landing(): python import failed"
want='@2=@3,@4,@1
@4=@3,@2,@1
@1=@2,@3,@4
@9=
cap 8'
[ "$got" = "$want" ] || fail "landing() ordering: got
$got"

# The landing itself rode the node's hub-arrival hook (session-window-changed[73]
# → fleet-hub-visits.sh record), which left the node with the person's keys and
# hooks (issue #1714, EPIC #1710 C4): a node draws no list since #1713, so no
# @sidebar_next is published there to land on. The rule above stays pinned; the
# node conf must take the hook off a live server.
grep -Eq '^set-hook -g [a-z-]+\[73\] ' "$CONF" && fail "the node conf still sets a [73] hook (#1714)"
grep -Eq '^set-hook -gu session-window-changed\[73\]$' "$CONF" || fail "the node conf must drop a live server's [73] hook (#1714)"
printf 'close-lands-next-selftest: PASS\n'
exit 0
