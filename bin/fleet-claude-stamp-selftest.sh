#!/bin/bash
# fleet-claude-stamp-selftest.sh — the launcher must stamp @cc_account on ITS OWN
# window (issue #511).
#
# bin/fleet-claude.sh tags the window it launches in with the active account's
# label, and that tag is what the collector uses to attribute a "hit your … limit"
# banner back to an account (and rotate). It used to stamp with an UNTARGETED
# `tmux set-option -w` — which resolves to the session's CURRENT window, not the
# pane the launcher runs in. Every spawn path is `new-window -d` (the hub stays
# current on purpose), so every stamp landed on the hub: workers were unstamped
# (invisible to rotation) and the hub carried whatever spawned last. `-t
# "$TMUX_PANE"` is the fix; this pins it against a REAL tmux on an isolated socket,
# in exactly the production shape (hub current, worker spawned detached).
#
# Hermetic: private socket via a PATH shim (the SUT's bare `tmux` and ours), fake
# `claude` + fake `fleet-account.sh`, scratch HOME/FLEET_CONF_DIR. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SUT="$BIN/fleet-claude.sh"
LIB="$BIN/fleet-lib.sh"
for f in "$SUT" "$LIB"; do [ -f "$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }; done
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-claude-stamp.XXXXXX")" || exit 2
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf"

# PATH shim: every `tmux` (the SUT's and this script's) goes to the private server.
cat > "$WORK/fakebin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
# fake `claude`: just keep the window alive long enough to read the stamp off it.
printf '#!/bin/sh\nsleep 20\n' > "$WORK/fakebin/claude"
chmod +x "$WORK/fakebin/tmux" "$WORK/fakebin/claude"
export PATH="$WORK/fakebin:$PATH"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# The SUT resolves its siblings via its own dir: real script + lib, fake accounts.
ln -s "$SUT" "$WORK/bin/fleet-claude.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"
cat > "$WORK/bin/fleet-account.sh" <<'EOF'
#!/bin/sh
case "${1:-}" in active) echo acctA ;; token) echo tok-a ;; esac
exit 0
EOF
chmod +x "$WORK/bin/fleet-account.sh"

fail() { printf 'fleet-claude-stamp selftest FAIL: %s\n' "$1" >&2; exit 1; }

# Production shape: the hub is the session's current window; the worker is spawned
# DETACHED (-d) so the hub stays current while the launcher runs.
tmux new-session -d -s t -n hub 'sleep 20' || fail "could not start the isolated server"
tmux new-window -d -t t: -n worker \
  "env PATH='$PATH' HOME='$WORK' FLEET_CONF_DIR='$WORK/conf' bash '$WORK/bin/fleet-claude.sh'" \
  || fail "new-window failed"

# wait for the launcher to have stamped SOMETHING (or give up after ~6s)
for _ in $(seq 1 30); do
  h=$(tmux show-options -wv -t t:hub @cc_account 2>/dev/null)
  w=$(tmux show-options -wv -t t:worker @cc_account 2>/dev/null)
  [ -n "$h$w" ] && break
  sleep 0.2
done
[ "$w" = "acctA" ] || fail "the worker window must carry the stamp (got worker='$w' hub='$h')"
[ -z "$h" ]        || fail "the stamp must not land on the hub (the session's current window); got hub='$h'"

printf 'selftest OK: fleet-claude.sh stamps @cc_account on its own window, not the hub (issue #511)\n'
