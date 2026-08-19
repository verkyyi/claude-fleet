#!/bin/bash
# dash-popup-selftest.sh — the dash in-pane popup contract (issue #448).
#
# The bug: the dash's `?` (keys cheatsheet) and ⌃n (file+spawn) binds called
# `tmux display-popup` DIRECTLY from inside an fzf `execute()` action. A popup has
# to draw on a CLIENT, and a command run from a pane process reaches tmux with no
# client of its own, so tmux guesses — and when it cannot it exits 1 with
# "no current client" and draws NOTHING. The dash runs fzf with stdout+stderr on
# /dev/null, so that error was invisible: the keystroke silently did nothing,
# intermittently, exactly across a Termius drop / reconnect / detached hub.
#
# This drives the REAL bin/dash-popup.sh against a REAL, isolated tmux server
# (its own socket, torn down at exit — never the user's live server):
#   • BUG REPRO     a raw `tmux display-popup` with no client fails AND runs nothing.
#   • FALLBACK      dash-popup.sh in that same state still RUNS the command.
#   • ARG SAFETY    an argument containing spaces survives %q-quoting intact.
#   • NO STRANDING  the no-client path leaves @popup_open unset/0, never a live epoch.
#   • CLIENT PATH   with a real attached client the popup path runs the command and
#                   clears @popup_open. BEST-EFFORT BY DESIGN: it needs a live pty
#                   client (`script`), which is racy to fake headlessly, so it SKIPs
#                   cleanly where one can't be had or drops mid-leg. It never fails
#                   spuriously — the deterministic gate is the rest of this file.
#   • STATIC GUARD  neither the dash's nor the backlog's binds call display-popup
#                   directly any more.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
HELPER="$BIN/dash-popup.sh"
DASH="$BIN/tmux-dashboard.sh"
[ -f "$HELPER" ] || { printf 'selftest: %s not found\n' "$HELPER" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dp-selftest.XXXXXX")" || exit 2

# Isolate every tmux call onto a private socket so we never touch the user's live
# server. A PATH shim routes the plain `tmux` dash-popup.sh calls to it.
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
# A bare EXIT trap does NOT fire when bash is killed by a signal — turn INT/TERM/HUP
# (Ctrl-C, a CI timeout) into a normal exit so cleanup still reaps the isolated
# server instead of leaking it to the machine (issue #152).
trap 'exit 130' INT TERM HUP

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# --- an isolated server with NO attached client (the failing condition) -------
tmux new-session -d -s t -x 200 -y 50 'sleep 600' 2>/dev/null \
  || fail "could not start isolated tmux server"
PANE="$(tmux list-panes -t t -F '#{pane_id}' | head -n1)"
[ -n "$PANE" ] || fail "could not resolve a pane on the isolated server"
export TMUX_PANE="$PANE"
[ -z "$(tmux list-clients -t t 2>/dev/null)" ] || fail "precondition: expected no attached client"

# --- 1. BUG REPRO: the old form fails, silently ------------------------------
M="$WORK/ran"
raw_out="$(tmux display-popup -E -w 50% -h 10 "echo raw >> $M" 2>&1)"; raw_rc=$?
[ "$raw_rc" -ne 0 ] || fail "bug repro: raw display-popup unexpectedly SUCCEEDED with no client"
case "$raw_out" in *"no current client"*) ;; *)
  fail "bug repro: expected 'no current client', got [$raw_out]" ;;
esac
[ ! -s "$M" ] || fail "bug repro: raw display-popup ran the command despite failing"

# --- 2. FALLBACK: the helper still runs the command --------------------------
# This is the regression the whole fix exists for: no client must NOT mean
# "the keystroke did nothing".
bash "$HELPER" -w 50% -h 10 -- sh -c "echo fell-back >> '$M'" >/dev/null 2>&1
grep -q '^fell-back$' "$M" 2>/dev/null \
  || fail "fallback: dash-popup.sh did not run the command when no client was attached"

# --- 3. ARG SAFETY: spaces survive the %q round-trip -------------------------
A="$WORK/args"
bash "$HELPER" -w 50% -h 10 -- sh -c "printf '%s\n' \"\$1\" > '$A'" _ "two words" >/dev/null 2>&1
[ "$(cat "$A" 2>/dev/null)" = "two words" ] \
  || fail "arg safety: spaced argument mangled — got [$(cat "$A" 2>/dev/null)]"

# --- 4. NO STRANDING: the no-client path never leaves a live epoch -----------
# dash-popup-wait.sh pauses the dash's repaint while @popup_open is a FRESH epoch
# (#308/#431); a fallback run must not raise it at all.
v="$(tmux show-option -gqv @popup_open 2>/dev/null)"
case "$v" in ''|0) ;; *) fail "no stranding: fallback left @popup_open=[$v], expected unset/0" ;; esac

# --- 5. CLIENT PATH (best-effort) --------------------------------------------
# Needs a real pty client. `script` differs across BSD/GNU, so try both and SKIP
# rather than fail where neither works — the hermetic core above is the gate.
attach_bg() {
  if script -q /dev/null true >/dev/null 2>&1; then           # BSD/macOS
    script -q /dev/null tmux -S "$SOCK" attach -t t >/dev/null 2>&1 &
  elif script -q -c true /dev/null >/dev/null 2>&1; then      # GNU/util-linux
    script -q -c "$REAL_TMUX -S '$SOCK' attach -t t" /dev/null >/dev/null 2>&1 &
  else
    return 1
  fi
  CLIENT_PID=$!
  # Give the pty client a generous window to show up: a loaded machine (or CI) can
  # take a second or two to fork `script` + connect, and a 3s window made this leg
  # skip intermittently — a leg that silently vanishes half the time is not coverage.
  i=0
  while [ "$i" -lt 60 ]; do
    [ -n "$(tmux list-clients -t t 2>/dev/null)" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}
if attach_bg; then
  P="$WORK/popup"
  bash "$HELPER" -w 50% -h 10 -- sh -c "echo popped >> '$P'" >/dev/null 2>&1
  # Re-read the client BEFORE asserting. A pty client driven by `script` in a
  # headless run can drop between the attach and the popup; that is a flaky
  # harness, not a defect in the code under test, so it degrades to a SKIP rather
  # than a spurious FAIL. Only a client that was still attached gets to assert.
  if [ -n "$(tmux list-clients -t t 2>/dev/null)" ]; then
    grep -q '^popped$' "$P" 2>/dev/null \
      || fail "client path: dash-popup.sh did not run the command with a client attached"
    v="$(tmux show-option -gqv @popup_open 2>/dev/null)"
    case "$v" in ''|0) ;; *)
      fail "client path: @popup_open left at [$v] after the popup closed, expected 0" ;;
    esac
  else
    printf 'selftest: pty client dropped mid-leg — SKIP the attached-client case\n' >&2
  fi
  kill "${CLIENT_PID:-0}" 2>/dev/null
else
  printf 'selftest: no usable pty (`script`) — SKIP the attached-client case\n' >&2
fi

# --- 6. STATIC GUARD: the binds route through the helper ---------------------
[ -f "$DASH" ] || fail "static guard: $DASH not found"
grep -q 'dash-popup\.sh -w 72% -h 80% -- bash \$BIN/fleet-keys\.sh --context dash' "$DASH" \
  || fail "static guard: the dash '?' bind does not route through dash-popup.sh"
grep -q 'dash-popup\.sh -w 90% -h 12 -- bash \$BIN/dash-issue-new\.sh confirm --spawn' "$DASH" \
  || fail "static guard: the dash ⌃n bind does not route through dash-popup.sh"
# No fzf --bind may call display-popup directly any more — that is the whole bug.
if grep -n -- '--bind' "$DASH" | grep -q 'display-popup'; then
  fail "static guard: an fzf --bind still calls 'tmux display-popup' directly"
fi
# The backlog panel's WINDOWED `?` is the same bind in the other panel — it runs
# from a pane process too, so it must route through the helper as well. (Its POPUP
# mode is unaffected: there `?` drops a 'keys' sentinel and the gap dispatcher runs
# the sheet inline, since tmux cannot nest a popup inside a popup — #123/#122.)
ISSUES="$BIN/tmux-issues.sh"
[ -f "$ISSUES" ] || fail "static guard: $ISSUES not found"
grep -q 'dash-popup\.sh -w 72% -h 80% -- bash \$BIN/fleet-keys\.sh --context backlog' "$ISSUES" \
  || fail "static guard: the backlog windowed '?' bind does not route through dash-popup.sh"
grep -q 'K_BIND="?:execute(tmux display-popup' "$ISSUES" \
  && fail "static guard: the backlog '?' bind still calls 'tmux display-popup' directly"

printf 'dash-popup-selftest: OK\n'
exit 0
