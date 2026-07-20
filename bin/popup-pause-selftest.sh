#!/bin/bash
# popup-pause-selftest.sh — the "pause dash repaint under an open modal popup"
# contract (issue #308), its bounded self-heal (#323), and the epoch-stamp +
# client-detached self-heal that fixes the stranded-flag freeze (issue #431).
#
# The bug: a tmux display-popup is a CLIENT-SIDE overlay that does NOT freeze the
# panes under it, so the dash's 1Hz reload keeps re-rendering right beneath the
# popup and that churn flashes THROUGH it — worst where the popup edge clips a
# double-width CJK cell. The fix is a server-global @popup_open flag: the modal
# popup binds (conf/tmux-attention.conf) raise it for the popup's lifetime, and
# the dash reload loop (bin/dash-popup-wait.sh) waits on it so it emits no new
# frame while a popup is open.
#
# The FOLLOW-ON bug (issue #431): the flag was a bare `1`, and the ONE path that
# leaks it — the popup dying before its trailing `set 0` when the client detaches
# / switches fleets / disconnects mid-popup — stranded it at 1, so every later
# reload stalled ~20s = "frozen" (recurring, worst on Termius/mobile). Two
# self-heals fix it: a `client-detached` hook clears the flag the instant a client
# leaves (its popup is already gone), and the open now stamps an EPOCH (`date +%s`)
# so the dash trusts the flag only while `now - flag < MAX_AGE` — a stranded value
# ages out instead of freezing the dash forever.
#
# This asserts the whole contract:
#   • PRODUCER (static) the dash reload gates `bash $ROWS` behind the wait helper;
#                the helper bounds the pause by flag AGE; every modal popup in the
#                conf stamps an epoch open and clears to 0; the client-detached
#                hook is present.
#   • PRODUCER (live)   the conf sources on a REAL, isolated tmux server (its own
#                socket, torn down at exit — never the user's live server); the
#                prefix + mouse popup binds carry the epoch stamp; the
#                client-detached hook is installed and, on a real detach, RESETS
#                @popup_open to 0.
#   • CONSUMER (live)   the REAL bin/dash-popup-wait.sh — unset flag repaints at
#                once; a FRESH epoch suppresses the repaint and resumes the instant
#                the flag clears; a STALE (stranded) epoch self-heals — repaints at
#                once instead of stalling (issue #431).
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
DASH="$BIN/tmux-dashboard.sh"
WAIT="$BIN/dash-popup-wait.sh"
CONF="$ROOT/conf/tmux-attention.conf"
[ -f "$DASH" ] || { printf 'selftest: %s not found\n' "$DASH" >&2; exit 2; }
[ -f "$WAIT" ] || { printf 'selftest: %s not found\n' "$WAIT" >&2; exit 2; }
[ -x "$WAIT" ] || { printf 'selftest: %s not executable\n' "$WAIT" >&2; exit 1; }
[ -f "$CONF" ] || { printf 'selftest: %s not found\n' "$CONF" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# --- PRODUCER (static): dash reload GATES $ROWS behind the wait helper ---------
# The re-render (`bash $ROWS`) must sit AFTER the popup wait, so no frame is
# emitted while a popup is open. Order: sleep … wait helper … bash $ROWS.
grep -Eq 'load:reload-sync\(sleep \$REFRESH; sh \$WAIT; bash \$ROWS\)' "$DASH" \
  || fail "tmux-dashboard.sh reload bind no longer runs the popup wait before \$ROWS (issue #308)"
grep -Eq '^WAIT="\$BIN/dash-popup-wait\.sh"' "$DASH" \
  || fail "tmux-dashboard.sh no longer points \$WAIT at dash-popup-wait.sh"

# --- PRODUCER (static): the wait is BOUNDED by flag AGE, not unbounded ---------
# A leaked flag (popup died before its trailing `set 0`) must not freeze the dash
# forever (issue #323/#431). The helper must age a stale flag out via MAX_AGE.
grep -q 'FLEET_DASH_POPUP_MAX_AGE' "$WAIT" \
  || fail "dash-popup-wait.sh no longer bounds the pause by FLEET_DASH_POPUP_MAX_AGE (issue #431) — a stuck flag could freeze the dash forever"
grep -Eq '\-ge "\$MAX_AGE"' "$WAIT" \
  || fail "dash-popup-wait.sh no longer breaks the wait once the flag ages past MAX_AGE (issue #431)"

# --- PRODUCER (static): every modal popup is epoch-stamped + closed ------------
# Count in CODE lines only (skip the comment block, which names the flag in prose).
# One epoch stamp and one clear per display-popup surface; there are 7 (prefix
# b/c/? + the fleet-pick / xfleet-jump / acct / usage mouse popups). The clears
# number one MORE than the popups: the client-detached hook also sets 0 (#431).
code_only() { grep -v '^[[:space:]]*#' "$CONF"; }
npop=$(code_only | grep -c 'display-popup')
[ "$npop" -eq 7 ] || fail "expected 7 display-popup binds in conf code, found $npop"
nstamp=$(code_only | grep -c '@popup_open \$(date +%s)')
nclose=$(code_only | grep -c '@popup_open 0')
[ "$nstamp" -eq "$npop" ] \
  || fail "epoch-stamp mismatch: $nstamp opens stamp \`date +%s\` but there are $npop popups (issue #431 — every open must stamp an epoch, not a bare 1)"
[ "$nclose" -eq "$((npop + 1))" ] \
  || fail "clear mismatch: set-0 count=$nclose (want $((npop + 1)) — one per popup + the client-detached hook)"

# --- PRODUCER (static): the client-detached self-heal hook is present ----------
grep -Eq "^set-hook -g client-detached 'set -g @popup_open 0'" "$CONF" \
  || fail "conf lost the client-detached hook that clears @popup_open on detach (issue #431) — the dash would re-freeze on a fleet-switch/disconnect"

# --- isolated tmux server + PATH shim (never the user's live server) ----------
# A PATH shim routes the plain `tmux` the dash guard calls to a private socket,
# reaped on exit. Same pattern as dash-marker-selftest.sh.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pp-selftest.XXXXXX")" || exit 2
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
# A bare EXIT trap does NOT fire on a signal — turn INT/TERM/HUP into a normal exit
# so cleanup still reaps the isolated server (issue #152); fleet-selftest-reap.sh
# backstops a SIGKILL.
trap 'exit 130' INT TERM HUP

# Redirect the server-spawning command's stdio so the daemonized tmux server does
# NOT inherit (and hold open) this test's stdout/stderr — otherwise a caller that
# captures our output would block on EOF until the server dies.
tmux new-session -d -s t -x 200 -y 50 </dev/null >/dev/null 2>&1 \
  || fail "could not start isolated tmux server"

# --- PRODUCER (live): the conf parses AND registers the flagged binds ---------
tmux source-file "$CONF" 2>"$WORK/src.err" \
  || { printf '%s\n' "$(cat "$WORK/src.err" 2>/dev/null)" >&2; fail "conf/tmux-attention.conf failed to source (syntax error in the popup-bind wrap)"; }
for k in b c '?'; do
  tmux list-keys -T prefix 2>/dev/null | grep -F -- " $k " | grep -q 'date +%s' \
    || fail "prefix '$k' bind lost its @popup_open epoch stamp after sourcing (issue #431)"
done
tmux list-keys -T root 2>/dev/null | grep -i 'MouseDown1Status' | grep -q 'date +%s' \
  || fail "MouseDown1Status mouse popups lost their @popup_open epoch stamp after sourcing (issue #431)"

# --- PRODUCER (live): the client-detached hook is installed AND resets on detach
tmux show-hooks -g 2>/dev/null | grep -i 'client-detached' | grep -q '@popup_open 0' \
  || fail "client-detached hook not installed after sourcing (issue #431)"
# Functional: a REAL detach must fire the hook and reset the flag. Drive it with a
# CONTROL-MODE client over a fifo — portable (no pty; no BSD-vs-GNU `script` split).
tmux set -g @popup_open 424242
mkfifo "$WORK/fifo" 2>/dev/null || true
if [ -p "$WORK/fifo" ]; then
  tmux -C attach-session -t t < "$WORK/fifo" >/dev/null 2>&1 &
  cpid=$!
  exec 3>"$WORK/fifo"          # hold the fifo open so the control client stays attached
  attached=no
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(tmux list-clients -t t 2>/dev/null | wc -l | tr -d ' ')" != 0 ] && { attached=yes; break; }
    sleep 0.2
  done
  if [ "$attached" = yes ]; then
    tmux detach-client -s t 2>/dev/null || true
    healed=no
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ "$(tmux show-option -gqv @popup_open 2>/dev/null)" = 0 ] && { healed=yes; break; }
      sleep 0.2
    done
    exec 3>&-; kill "$cpid" 2>/dev/null || true
    [ "$healed" = yes ] \
      || fail "client-detached hook did NOT reset @popup_open on a real detach (issue #431) — the dash would stay frozen after a fleet-switch/disconnect"
  else
    # Could not attach a client in this environment — the static + show-hooks
    # assertions above already prove the hook is installed with the right body.
    exec 3>&-; kill "$cpid" 2>/dev/null || true
    printf 'selftest note: skipped the live-detach hook check (no client could attach here)\n' >&2
  fi
fi
tmux set-option -g @popup_open 0

# --- CONSUMER (live): the REAL wait helper, driven on the isolated server ------
# Run the ACTUAL bin/dash-popup-wait.sh (not a reimplementation) so the test can
# never drift from the shipped guard. A small MAX_AGE keeps the checks fast.
export FLEET_DASH_POPUP_POLL=0.05
running()  { kill -0 "$1" 2>/dev/null; }
# wait until $1 exits, up to ~2s; return 0 if it exited, 1 if still running.
await_exit() { w=0; while [ "$w" -lt 40 ]; do running "$1" || return 0; sleep 0.05; w=$((w + 1)); done; return 1; }

# 1) UNSET flag → the guard falls straight through (a normal repaint).
tmux set-option -gu @popup_open 2>/dev/null
FLEET_DASH_POPUP_MAX_AGE=10 sh "$WAIT" & wpid=$!
await_exit "$wpid" || { kill "$wpid" 2>/dev/null; fail "wait blocked with @popup_open UNSET — the dash would never repaint"; }

# 2) FRESH epoch (popup open) → the guard MUST NOT repaint (no under-popup churn),
#    and MUST resume the instant the flag clears.
tmux set-option -g @popup_open "$(date +%s)"
FLEET_DASH_POPUP_MAX_AGE=10 sh "$WAIT" & wpid=$!
sleep 0.4
running "$wpid" || fail "wait repainted while a FRESH @popup_open epoch was set — the dash would flicker under an open popup (issue #308)"
tmux set-option -g @popup_open 0          # popup closes
await_exit "$wpid" || { kill "$wpid" 2>/dev/null; fail "wait did not resume after @popup_open cleared — the dash would stay frozen"; }

# 3) STALE epoch (stranded flag) → the guard MUST self-heal: repaint at once
#    instead of stalling (issue #431). Set an epoch far past MAX_AGE.
tmux set-option -g @popup_open "$(( $(date +%s) - 99999 ))"
FLEET_DASH_POPUP_MAX_AGE=10 sh "$WAIT" & wpid=$!
await_exit "$wpid" || { kill "$wpid" 2>/dev/null; fail "wait STALLED on a STALE (stranded) @popup_open epoch — a leaked flag would still freeze the dash (issue #431)"; }

tmux set-option -gu @popup_open 2>/dev/null   # leave the isolated server tidy

printf 'selftest PASS: modal popups stamp an epoch @popup_open; the dash pauses its repaint while it is fresh, resumes on clear, self-heals a stranded flag, and a client-detached hook clears it on detach\n'
exit 0
