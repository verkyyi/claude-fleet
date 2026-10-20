#!/bin/bash
# fleet-claude-stamp-selftest.sh — the launcher stamps @cc_account on ITS OWN
# window, and only for an account a caller NAMED (issues #511, T550).
#
# bin/fleet-claude.sh tags the window it launches in with the label of the
# account a migrate / handoff pinned (FLEET_ACCOUNT_LABEL). It used to stamp with
# an UNTARGETED `tmux set-option -w` — which resolves to the session's CURRENT
# window, not the pane the launcher runs in. Every spawn path is `new-window -d`
# (the hub stays current on purpose), so every stamp landed on the hub. `-t
# "$TMUX_PANE"` is the fix; this pins it against a REAL tmux on an isolated
# socket, in exactly the production shape (hub current, worker spawned detached).
#
# Since T550 (EPIC T542 C4) the launcher picks no account: with two accounts in
# accounts/ and nothing named, it asks fleet-account.sh nothing, exports no
# token and stamps nothing — the session runs on this login's own login.
#
# Hermetic: private socket via a PATH shim (the SUT's bare `tmux` and ours), fake
# `claude` + fake `fleet-account.sh`, scratch HOME/FLEET_CONF_DIR. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
SUT="$BIN/fleet-claude.sh"
LIB="$BIN/fleet-lib.sh"
for f in "$SUT" "$LIB"; do [ -f "$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }; done
st_real_tmux

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-claude-stamp.XXXXXX")" || exit 2
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf"

# PATH shim: every `tmux` (the SUT's and this script's) goes to the private server.
st_tmux_socket "$WORK/fakebin" "$SOCK"
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
cat > "$WORK/bin/fleet-account.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/account.calls"
case "\${1:-}" in active) echo acctA ;; token) [ -n "\${2:-}" ] && echo tok-a ;; esac
exit 0
EOF
chmod +x "$WORK/bin/fleet-account.sh"


# Production shape: the hub is the session's current window; the worker is spawned
# DETACHED (-d) so the hub stays current while the launcher runs.
tmux new-session -d -s t -n hub 'sleep 20' || st_fail "could not start the isolated server"
mkdir -p "$WORK/accounts"; printf 'tok-a\n' > "$WORK/accounts/acctA"; printf 'tok-b\n' > "$WORK/accounts/acctB"

# --- 1. nothing named: no pick, no token, no stamp (T550) ----------------------
tmux new-window -d -t t: -n plain \
  "env PATH='$PATH' HOME='$WORK' FLEET_CONF_DIR='$WORK/conf' FLEET_ACCOUNTS_DIR='$WORK/accounts' bash '$WORK/bin/fleet-claude.sh'" \
  || st_fail "new-window failed"
for _ in $(seq 1 30); do
  [ -n "$(tmux show-options -wv -t t:plain @cc_agent 2>/dev/null)" ] && break
  sleep 0.2
done
[ -n "$(tmux show-options -wv -t t:plain @cc_agent 2>/dev/null)" ] || st_fail "the plain launch never ran"
[ -z "$(tmux show-options -wv -t t:plain @cc_account 2>/dev/null)" ] || st_fail "a launch that named no account must stamp no @cc_account"
[ ! -s "$WORK/account.calls" ] || st_fail "a launch that named no account must ask fleet-account.sh nothing: $(cat "$WORK/account.calls")"

# --- 2. a named account: stamped on the worker's own window, not the hub (#511) --
tmux new-window -d -t t: -n worker \
  "env PATH='$PATH' HOME='$WORK' FLEET_CONF_DIR='$WORK/conf' FLEET_ACCOUNTS_DIR='$WORK/accounts' FLEET_ACCOUNT_LABEL=acctA bash '$WORK/bin/fleet-claude.sh'" \
  || st_fail "new-window failed"

# wait for the launcher to have stamped SOMETHING (or give up after ~6s)
for _ in $(seq 1 30); do
  h=$(tmux show-options -wv -t t:hub @cc_account 2>/dev/null)
  w=$(tmux show-options -wv -t t:worker @cc_account 2>/dev/null)
  [ -n "$h$w" ] && break
  sleep 0.2
done
[ "$w" = "acctA" ] || st_fail "the worker window must carry the named account (got worker='$w' hub='$h')"
[ -z "$h" ]        || st_fail "the stamp must not land on the hub (the session's current window); got hub='$h'"
grep -q '^active' "$WORK/account.calls" && st_fail "the launcher must never ask fleet-account.sh active (T550)"

printf 'selftest OK: fleet-claude.sh picks no account; a named one is stamped on its own window (issues #511, T550)\n'
