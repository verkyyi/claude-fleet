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
#   • kill-window @sibling from a STEWARD pane (@steward=1) → ALLOWED (issue #177:
#                              the operator's hub kills a merged worker's window).
#   • kill-window @sibling from a STEWARD pane while a NON-steward window is the
#                              ACTIVE one → still ALLOWED (#177 reopen: the seat
#                              is read from the caller's $TMUX_PANE, not the
#                              focused pane).
#   • kill-window @sibling with an EMPTY $TMUX_PANE, steward window ACTIVE →
#                              REFUSED (#177 reopen: never guess the seat from the
#                              active pane; empty caller pane is conservatively
#                              NOT steward).
#   • kill-window @sibling from an unmarked WORKER pane → REFUSED (#158 holds).
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
# A bare EXIT trap does NOT fire when bash is killed by a signal — turn INT/TERM/HUP
# (Ctrl-C, a CI timeout) into a normal exit so cleanup still reaps the isolated
# server instead of leaking it to the machine (issue #152). fleet-selftest-reap.sh
# is the backstop for the runs that a SIGKILL still slips past.
trap 'exit 130' INT TERM HUP

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

# --- STEWARD-seat cross-window kill is ALLOWED (issue #177) --------------------
# The operator's steward hub (its pane carries @steward=1) legitimately kills a
# merged worker's window as the last step of /fleet-land. Build a steward window
# (hub, marked) + a worker window (wk), then kill wk FROM the steward pane — a
# cross-window kill the guard must ALLOW because the caller is the steward.
tmux new-window -t t: -n stew 2>/dev/null || fail "could not create steward window stew"
tmux new-window -t t: -n wk   2>/dev/null || fail "could not create worker window wk"
PANE_STEW="$(pane_of stew)"; PANE_WK="$(pane_of wk)"; WK="$(win_id wk)"
[ -n "$PANE_STEW" ] && [ -n "$PANE_WK" ] && [ -n "$WK" ] || fail "could not build steward/worker fixture"
tmux set-option -p -t "$PANE_STEW" @steward 1 2>/dev/null || fail "could not mark steward pane"
guard "$PANE_STEW" kill-window -t "$WK" 2>/dev/null \
  || fail "steward-seat kill-window @sibling should be ALLOWED (#177)"
win_gone wk || fail "worker window wk should be gone after a steward-seat kill-window"

# --- a WORKER-seat cross-window kill is STILL refused (the #158 guarantee) ------
# Same shape, but the caller pane has NO @steward marker → must be refused again.
# Caller = a fresh, unmarked worker pane; target = the (marked) steward window,
# a genuine cross-window kill. The guard keys off the CALLER's seat, so it must
# refuse — and the steward window survives.
tmux new-window -t t: -n wk 2>/dev/null || fail "could not recreate worker window wk"
PANE_WK="$(pane_of wk)"; STEW="$(win_id stew)"
[ -n "$PANE_WK" ] && [ -n "$STEW" ] || fail "could not build worker-seat refusal fixture"
if guard "$PANE_WK" kill-window -t "$STEW" 2>/dev/null; then
  fail "worker-seat kill-window @sibling must STILL be REFUSED (#158 must hold)"
fi
win_gone stew && fail "steward window stew must survive a refused worker-seat kill-window"

# --- STEWARD exemption is FOCUS-INDEPENDENT (issue #177 reopen) ----------------
# The reopen: the pre-fix guard read the seat from `display-message -t ""`, which
# falls back to the *active* pane. The plan hub has two panes — dash (no @steward)
# and steward (@steward=1). With the dash focused, the steward's own /fleet-land
# was misread as a worker and REFUSED. The fix resolves the seat STRICTLY from the
# caller's $TMUX_PANE. Prove it: focus a NON-steward window as the active pane,
# then land FROM the steward pane — the active pane isn't the caller, yet it must
# still be ALLOWED.
tmux new-window -t t: -n stew2 2>/dev/null || fail "could not create steward window stew2"
tmux new-window -t t: -n wk2   2>/dev/null || fail "could not create worker window wk2"
PANE_STEW2="$(pane_of stew2)"; WK2="$(win_id wk2)"
[ -n "$PANE_STEW2" ] && [ -n "$WK2" ] || fail "could not build focus-independence fixture"
tmux set-option -p -t "$PANE_STEW2" @steward 1 2>/dev/null || fail "could not mark steward pane stew2"
tmux select-window -t t:wk2 2>/dev/null   # focus a NON-steward window as the active pane
guard "$PANE_STEW2" kill-window -t "$WK2" 2>/dev/null \
  || fail "steward-seat kill must be ALLOWED with a non-steward window focused (#177 reopen)"
win_gone wk2 || fail "worker window wk2 should be gone after a focus-independent steward kill"

# --- EMPTY $TMUX_PANE is REFUSED, never active-pane-guessed (issue #177 reopen) -
# When $TMUX_PANE is empty/unresolvable the pre-fix guard read the ACTIVE pane; if
# a steward window happened to be focused it would WRONGLY allow a cross-window
# kill from a caller with no resolvable pane. The fix treats an empty caller pane
# as conservatively NOT steward. Mark + FOCUS a steward window, then call with an
# EMPTY TMUX_PANE targeting a sibling worker → must be REFUSED, worker survives.
tmux new-window -t t: -n stew3 2>/dev/null || fail "could not create steward window stew3"
tmux new-window -t t: -n wk3   2>/dev/null || fail "could not create worker window wk3"
PANE_STEW3="$(pane_of stew3)"; WK3="$(win_id wk3)"
[ -n "$PANE_STEW3" ] && [ -n "$WK3" ] || fail "could not build empty-TMUX_PANE fixture"
tmux set-option -p -t "$PANE_STEW3" @steward 1 2>/dev/null || fail "could not mark steward pane stew3"
tmux select-window -t t:stew3 2>/dev/null   # steward window is now the ACTIVE pane
if guard "" kill-window -t "$WK3" 2>/dev/null; then
  fail "empty \$TMUX_PANE must be REFUSED even with a steward window active (no active-pane guess)"
fi
win_gone wk3 && fail "worker window wk3 must survive a refused empty-\$TMUX_PANE kill"

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
