#!/bin/bash
# fleet-client-route-selftest.sh — the `fleet` client is the ONLY way in, and its
# line is always the fastest one (issue #1628, EPIC #1615 C11, after the
# 2026-10-05 change of course: no fallback to ssh-ing into a machine's own list).
# Covers bin/fleet's dispatch onto the one client (fleet-thin.py — the old
# two-pane client went with issue #3008) and fleet-connect.py's
# FLEET_CONNECT_ROUTE_FILE / FLEET_CONNECT_RETEST / --probe-direct.
#
# Nothing real is reached: fleet-thin.py is a FAKE in the dispatcher leg (it
# records its argv), the real fleet-connect.py in C runs against a loopback
# SSH-banner server and a fake `ssh` on PATH.
#   A. one client  — `fleet` / `fleet mac-b` / `fleet --thin <s>` all open
#                    fleet-thin.py (a machine word as --home); `fleet shell
#                    mac-b` is fleet-shell.py, the home's command line with no
#                    client (EPIC T651 C5);
#                    `fleet --old` and FLEET_CLIENT=shell say in one line that the
#                    old client is gone and open it all the same; connect is never
#                    run by the dispatcher itself
#   C. connect     — the real fleet-connect.py: FLEET_CONNECT_ROUTE_FILE gets the
#                    route; --probe-direct answers 0 while the banner server is
#                    up, 1 once it is gone or for an unknown machine;
#                    FLEET_CONNECT_RETEST=1 skips the remembered route
# python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-client-route.XXXXXX")
export HOME="$WORK/home"; mkdir -p "$HOME/.ssh" "$HOME/.config/claude-fleet"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export FLEET_CONF_DIR="$HOME/.config/claude-fleet"
unset TMUX TMUX_PANE FLEET_SHELL FLEET_HUB_URL FLEET_HUB_TOKEN SSH_CONNECTION FLEET_NODE_ALIASES \
      FLEET_CONNECT_RETEST FLEET_CONNECT_ROUTE_FILE FLEET_REMOTE_SSH_CMD

st_tally count miss
waitfor() {  # <secs> <cmd…> — until the command succeeds
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
SRV_PID=''
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- a bin/ of our own: every real script, FAKE fleet-connect.py + fleet-thin.py ---
SB="$WORK/sbin"; mkdir -p "$SB" "$WORK/conf"
for f in "$BIN"/*; do [ -f "$f" ] && ln -s "$f" "$SB/${f##*/}"; done
for f in "$BIN"/../conf/*; do [ -f "$f" ] && ln -s "$f" "$WORK/conf/${f##*/}"; done
rm -f "$SB/fleet-connect.py"
cat > "$SB/fleet-connect.py" <<EOF
#!/usr/bin/env python3
import json, os, sys
with open(os.path.join("$WORK", "connect.log"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\\n")
if "--pick" in sys.argv:
    print(json.dumps({"machine": "mac-b", "hostname": "mac-c", "reason": "last", "login": "bob",
                      "machines": [{"alias": "mac-b", "hostname": "mac-c"}]}))
sys.exit(0)
EOF
chmod +x "$SB/fleet-connect.py"
rm -f "$SB/fleet-thin.py" "$SB/fleet-client-update.sh" "$SB/fleet-shell.py"
cat > "$SB/fleet-shell.py" <<EOF
#!/usr/bin/env python3
import sys
open("$WORK/thin.log", "a").write("shell [" + " ".join(sys.argv[1:]) + "]\\n")
EOF
cat > "$SB/fleet-thin.py" <<EOF
#!/usr/bin/env python3
import sys
open("$WORK/thin.log", "a").write("thin [" + " ".join(sys.argv[1:]) + "]\\n")
EOF


# ================================================================================
# A. one client — every road opens fleet-thin.py, no fallback
# ================================================================================
run() { : > "$WORK/thin.log"; : > "$WORK/connect.log"; env -u FLEET_CLIENT "$@" "$SB/fleet" ${ARGS[@]+"${ARGS[@]}"} 2>"$WORK/a.err" >/dev/null; }
ARGS=(); run env
st_eq 'A: fleet → the client, no arguments' 'thin []' "$(cat "$WORK/thin.log")"
ARGS=(mac-b); run env
st_eq 'A: fleet mac-b → the client with mac-b as home' 'thin [--home mac-b]' "$(cat "$WORK/thin.log")"
ARGS=(--thin issue-7); run env
st_eq 'A: fleet --thin <session> → the client on that session' 'thin [issue-7]' "$(cat "$WORK/thin.log")"
ARGS=(shell mac-b); run env
st_eq 'A: fleet shell mac-b → fleet-shell.py, never the client' 'shell [mac-b]' "$(cat "$WORK/thin.log")"
ARGS=(--old); run env
st_eq 'A: fleet --old → the client' 'thin []' "$(cat "$WORK/thin.log")"
st_has 'A: … saying the old client is gone' "$(cat "$WORK/a.err")" '旧客户端已删除（#3008）'
ARGS=(); run env FLEET_CLIENT=shell
st_eq 'A: FLEET_CLIENT=shell → the client all the same' 'thin []' "$(cat "$WORK/thin.log")"
st_has 'A: … and says so' "$(cat "$WORK/a.err")" 'FLEET_CLIENT=shell'
st_eq 'A: the dispatcher never ran connect itself' '' "$(cat "$WORK/connect.log")"
ARGS=(mac-b extra); run env
st_eq 'A: a machine word with more words → not the client' '' "$(cat "$WORK/thin.log")"

# ================================================================================
# C. connect — the real fleet-connect.py
# ================================================================================
python3 - "$WORK/port" <<'EOF' &
import socket, sys, threading
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(16)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept()
    try:
        c.sendall(b"SSH-2.0-selftest\r\n")
    finally:
        c.close()
EOF
SRV_PID=$!
waitfor 5 test -s "$WORK/port" || st_miss 'C: the banner server did not start'
PORT=$(cat "$WORK/port")
mkdir -p "$XDG_CACHE_HOME/claude-fleet"
python3 - "$XDG_CACHE_HOME/claude-fleet/connect.json" "$PORT" <<'EOF'
import json, sys, time
r = {"name": "lan", "kind": "direct", "host": "127.0.0.1", "port": int(sys.argv[2])}
json.dump({"last": "mac-b", "machines": {"mac-b": {"at": time.time(), "hub": "", "label": "mac-b", "login": "bob",
          "machine": {"alias": "mac-b", "hostname": "mac-c"}, "route": r, "routes": [r]}}}, open(sys.argv[1], "w"))
EOF
FAKESSH="$WORK/fakessh"; mkdir -p "$FAKESSH"
printf '#!/bin/sh\necho "SSH-RAN ARGS=$*"\n' > "$FAKESSH/ssh"; chmod +x "$FAKESSH/ssh"
out=$(PATH="$FAKESSH:$PATH" FLEET_CONNECT_ROUTE_FILE="$WORK/route.json" \
      python3 "$BIN/fleet-connect.py" mac-b 2>&1); rc=$?
st_eq 'C: connect → ssh ran, exit 0' 0 "$rc"
st_has 'C: … over the remembered line' "$out" 'SSH-RAN'
st_hasnt 'C: no fallback words, ever' "$out" '直连'
st_has 'C: the route file' "$(cat "$WORK/route.json" 2>/dev/null)" '"kind": "direct"'
python3 "$BIN/fleet-connect.py" --probe-direct mac-b >/dev/null 2>&1; rc=$?
st_eq 'C: --probe-direct with the line up → 0' 0 "$rc"
python3 "$BIN/fleet-connect.py" --probe-direct m9 >/dev/null 2>&1; rc=$?
st_eq 'C: --probe-direct for an unknown machine → 1' 1 "$rc"
out=$(PATH="$FAKESSH:$PATH" FLEET_CONNECT_RETEST=1 python3 "$BIN/fleet-connect.py" mac-b 2>&1); rc=$?
st_hasnt 'C: FLEET_CONNECT_RETEST=1 skips the remembered line' "$out" 'SSH-RAN'
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=''
FLEET_CONNECT_PROBE_TIMEOUT=1 python3 "$BIN/fleet-connect.py" --probe-direct mac-b >/dev/null 2>&1; rc=$?
st_eq 'C: --probe-direct with the line down → 1' 1 "$rc"

printf 'fleet-client-route selftest: %d checks, %d failed\n' "$CHECKS" "$FAIL"
st_done
