#!/bin/bash
# tmux-guard-selftest.sh — the tmux() destroy-guard's allow/deny matrix (issue #158).
#
# shell/cw.zsh installs a tmux() wrapper that stops a bypass-perms worker from
# ACCIDENTALLY taking down every fleet on the shared default socket. This test
# drives the REAL wrapper (sourced from cw.zsh) against a REAL, isolated tmux
# server (its own -S socket, torn down at exit — never the user's live server):
#
#   • kill-server            → REFUSED (server survives).
#   • kill-window @sibling   → REFUSED (the other window survives).
#   • kill-session (default) → REFUSED (a multi-window session survives).
#   • kill-window -a         → REFUSED (all-but-current sweep hits siblings).
#   • kill-window @own       → ALLOWED (self-teardown; the window is gone).
#   • FLEET_ALLOW_TMUX_DESTROY=1 → guard OFF: kill-window @sibling ALLOWED.
#   • tmux -L <name> kill-server → guard PASSES THROUGH (isolated server = ok);
#                              the refusal text is proven absent from stderr.
#
# The guard is a zsh function, but run-selftests.sh invokes every test under
# bash, so each assertion is bridged through `zsh -c 'source cw.zsh; tmux …'`
# with PATH/SOCK/TMUX_PANE exported. The guard's own `command tmux` calls then
# route through the same isolated-socket PATH shim the fixture is built with.
#
# zsh or tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CW="$BIN/../shell/cw.zsh"
[ -f "$CW" ] || { printf 'selftest: %s not found\n' "$CW" >&2; exit 2; }
CW="$(cd "$(dirname "$CW")" && pwd)/$(basename "$CW")"   # absolutize for zsh -c

REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
REAL_ZSH="$(command -v zsh 2>/dev/null)"
[ -n "$REAL_ZSH" ] || { printf 'selftest: zsh not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tmg-selftest.XXXXXX")" || exit 2
SOCK="$WORK/tmux.sock"

# PATH shim: route the plain `tmux` the guard calls onto our private socket — but
# NOT when the caller already picked a server (-L/-S), so the isolated-bypass
# assertion below can reach a *different* server without a socket-flag clash.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
case " \$* " in
  *" -L "*|*" -S "*) exec "$REAL_TMUX" "\$@" ;;
  *)                 exec "$REAL_TMUX" -S "$SOCK" "\$@" ;;
esac
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
export SOCK CW

cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# --- build the fixture: one session, a hub window + two worker windows --------
# `tmux` here is the shim (no guard function in bash) → all on the isolated -S.
tmux new-session -d -s t -n hub -x 200 -y 50 2>/dev/null || fail "could not start isolated tmux server"
tmux new-window -t t: -n w1 2>/dev/null || fail "could not create window w1"
tmux new-window -t t: -n w2 2>/dev/null || fail "could not create window w2"

win_id()  { tmux list-windows -t t -F '#{window_name} #{window_id}' | awk -v n="$1" '$1==n{print $2}'; }
win_gone() { ! tmux list-windows -t t -F '#{window_name}' 2>/dev/null | grep -qx "$1"; }
pane_of() { tmux list-panes -t "t:$1" -F '#{pane_id}' | head -n1; }

W1="$(win_id w1)"; W2="$(win_id w2)"; PANE_W1="$(pane_of w1)"; PANE_W2="$(pane_of w2)"
[ -n "$W1" ] && [ -n "$W2" ] && [ "$W1" != "$W2" ] || fail "could not build two distinct worker windows"

# guard <TMUX_PANE> <args…> : run the sourced tmux() guard as THIS worker (=pane).
# Prints the guard's stderr to fd 3 (captured by callers), returns its exit code.
guard() {
  local pane="$1"; shift
  TMUX_PANE="$pane" zsh -c 'source "$CW"; tmux "$@"' zsh "$@"
}

# --- kill-server is always refused; the server must survive -------------------
if guard "$PANE_W1" kill-server 2>/dev/null; then fail "kill-server should be REFUSED (non-zero)"; fi
tmux list-windows -t t >/dev/null 2>&1 || fail "server must survive a refused kill-server"

# --- kill-window against a SIBLING window is refused --------------------------
if guard "$PANE_W1" kill-window -t "$W2" 2>/dev/null; then fail "kill-window @sibling should be REFUSED"; fi
win_gone w2 && fail "sibling window w2 must survive a refused kill-window"

# --- kill-session (default target = own multi-window session) is refused ------
if guard "$PANE_W1" kill-session 2>/dev/null; then fail "kill-session on a multi-window session should be REFUSED"; fi
tmux list-windows -t t >/dev/null 2>&1 || fail "session must survive a refused kill-session"

# --- kill-window -a (all but current) is refused (it sweeps siblings) ---------
if guard "$PANE_W1" kill-window -a 2>/dev/null; then fail "kill-window -a should be REFUSED"; fi
win_gone w2 && fail "sibling window w2 must survive a refused kill-window -a"

# --- the refusal actually names the escape hatch (one-line explanation) -------
msg="$(guard "$PANE_W1" kill-server 2>&1 1>/dev/null || true)"
case "$msg" in
  *FLEET_ALLOW_TMUX_DESTROY*) : ;;
  *) fail "refusal message must point at the FLEET_ALLOW_TMUX_DESTROY escape hatch (got: $msg)" ;;
esac

# --- kill-window against the worker's OWN window is ALLOWED (self-teardown) ----
# Run it as w2's own pane, targeting w2 → the wrapper must let it through.
guard "$PANE_W2" kill-window -t "$W2" 2>/dev/null || fail "self kill-window should be ALLOWED"
win_gone w2 || fail "own window w2 should be gone after an allowed kill-window"

# --- FLEET_ALLOW_TMUX_DESTROY=1 disables the guard entirely -------------------
tmux new-window -t t: -n w3 2>/dev/null || fail "could not recreate a sibling window w3"
W3="$(win_id w3)"
FLEET_ALLOW_TMUX_DESTROY=1 guard "$PANE_W1" kill-window -t "$W3" 2>/dev/null \
  || fail "escape hatch should ALLOW kill-window @sibling"
win_gone w3 || fail "sibling window w3 should be gone once the guard is disabled"

# --- a command on an ISOLATED server (-L <name>) passes straight through -------
# There is no server on that label, so real tmux errors — but the KEY assertion
# is that the GUARD didn't block it (its refusal text must be absent).
iso="$(guard "$PANE_W1" -L "guard-selftest-$$" kill-server 2>&1 1>/dev/null || true)"
case "$iso" in
  *"refusing"*) fail "an isolated-server (-L) kill-server must NOT be refused by the guard (got: $iso)" ;;
  *) : ;;
esac

printf 'selftest PASS: tmux destroy-guard refuses server/sibling kills, allows self-teardown + isolated + escape hatch\n'
exit 0
