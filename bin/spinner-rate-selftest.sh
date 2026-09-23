#!/bin/bash
# spinner-rate-selftest.sh — the spinner's tmux budget (issue #887).
#
# bin/tmux-spinner.sh used to run `list-windows -a` on EVERY fleet socket on EVERY
# frame (8/s at the default 0.12s), animated or not, for a window table that moves
# every few minutes — tmux became the most-spawned program on the machine (~215
# exec/s). It now reads an animating fleet on the same process that writes its
# frame, a quiet one ≤1/s or on the hook's dirty marker, and ticks slowly when
# nothing animates. This test drives the REAL daemon on an isolated `-L` socket
# (never the live server) through a counting `tmux` shim on PATH, and pins:
#
#   IDLE     no animated window → ≤ ~1 tmux call/s for the whole daemon
#   START    a window set `working` by ANY writer (no marker) → spins within ~1s
#   ANIM     while it works the glyph still MOVES, at ≤ ~1 tmux call per frame
#   STOP     set `done` → the ✓ lands within ~1s, and the rate falls back to IDLE
#   MARKER   set-claude-state.sh (the hook) drops `<socket>.dirty` and the spinner
#            picks the change up on its next tick, well inside the 1s re-read
#   HB       the heartbeat keeps the bare epoch as its FIRST token (#677's readers)
#            and appends `tmux_calls_per_s=<n.n>` (read by fleet-doctor, #889)
#
# The latency bounds carry slack over the design numbers (1s re-read, 0.25s tick)
# because a loaded CI runner stretches every sleep; the RATE bounds are what #887
# is about and are tight.
#
# Usage: spinner-rate-selftest.sh [<spinner.sh>]   (default: this bin/'s — pass the
#        pre-#887 script to reproduce the "before" numbers; its asserts then red)
# tmux absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SPIN_SRC="${1:-$BIN/tmux-spinner.sh}"
[ -f "$SPIN_SRC" ] || { printf 'selftest: %s not found\n' "$SPIN_SRC" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/spinrate.XXXXXX")
LBL="spinrate$$"
SPIN_PID=''
cleanup() {
  [ -n "$SPIN_PID" ] && kill "$SPIN_PID" 2>/dev/null
  "$REAL_TMUX" -L "$LBL" kill-server 2>/dev/null   # our own isolated socket
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

FAILS=0 CHECKS=0
ok()   { CHECKS=$((CHECKS + 1)); printf '  ok   %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
tl() { "$REAL_TMUX" -L "$LBL" "$@"; }

# A private fleet: conf dir with one fleet whose label is our socket, a throwaway
# bin/ holding only the spinner (so no fleet.conf, no daemon-watch, logs in $WORK).
export FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$FLEET_CONF_DIR/fleets/$LBL" "$WORK/bin" "$WORK/logs" "$WORK/shim" "$WORK/tmp"
: > "$FLEET_CONF_DIR/fleets/$LBL/conf"
cp "$SPIN_SRC" "$WORK/bin/tmux-spinner.sh"
CALLS="$WORK/calls"; : > "$CALLS"
cat > "$WORK/shim/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$CALLS"
exec "$REAL_TMUX" "\$@"
EOF
chmod +x "$WORK/shim/tmux"

tl -f /dev/null new-session -d -s "$LBL" -n w1 'sleep 900' || { echo "selftest: cannot start tmux"; exit 2; }
tl new-window -d -t "$LBL" -n w2 'sleep 900'
tl new-window -d -t "$LBL" -n w3 'sleep 900'
for w in w1 w2 w3; do tl set-window-option -t "$LBL:$w" @claude_state 'done'; done
SOCKP=$(tl display-message -p '#{socket_path}')

PATH="$WORK/shim:$PATH" TMPDIR="$WORK/tmp" SPIN_INTERVAL=0.12 SPIN_HB_SECS=3 \
  sh "$WORK/bin/tmux-spinner.sh" >/dev/null 2>&1 &
SPIN_PID=$!

spin_of() { tl display-message -p -t "$LBL:$1" '#{@spin}'; }
# is <glyph> <spin|done> — spelled as literal alternatives: a bracket expression
# would compare BYTES in a C locale, and ✓ shares its UTF-8 lead byte with braille.
is() {
  case "$2:$1" in
    'spin:⠋ '|'spin:⠙ '|'spin:⠹ '|'spin:⠸ '|'spin:⠼ '|'spin:⠴ '|'spin:⠦ '|'spin:⠧ '|'spin:⠇ '|'spin:⠏ ') return 0 ;;
    'done:✓ ') return 0 ;;
  esac
  return 1
}
# wait_spin <win> <spin|done> <timeout-ms> → prints elapsed ms (or "timeout")
wait_spin() {
  _t0=$(now_ms)
  while :; do
    is "$(spin_of "$1")" "$2" && { echo $(( $(now_ms) - _t0 )); return 0; }
    [ $(( $(now_ms) - _t0 )) -gt "$3" ] && { echo timeout; return 1; }
    sleep 0.05
  done
}
# rate <secs> → tmux calls per second the daemon made over that window (x.x)
rate() {
  _a=$(wc -l < "$CALLS"); sleep "$1"; _b=$(wc -l < "$CALLS")
  awk -v n=$((_b - _a)) -v s="$1" 'BEGIN{printf "%.1f", n/s}'
}
le() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a <= b)}'; }

printf 'spinner-rate-selftest (%s)\n' "$SPIN_SRC"
# Warm-up: the first frame writes every window once.
w=$(wait_spin w1 'done' 5000)
[ "$w" != timeout ] || { fail "warm-up: the spinner never painted w1 ✓" "$(tail -5 "$CALLS")"; exit 1; }
sleep 1.5

# --- IDLE ----------------------------------------------------------------------
r=$(rate 6)
if le "$r" 1.3; then ok "IDLE: nothing animating → $r tmux calls/s (≤ ~1)"
else fail "IDLE: nothing animating → $r tmux calls/s, want ≤ ~1" "$(tail -8 "$CALLS")"; fi

# --- START (no marker: a writer that is not the hook) ---------------------------
tl set-window-option -t "$LBL:w1" @claude_state working
w=$(wait_spin w1 spin 3000)
if [ "$w" != timeout ] && [ "$w" -le 1600 ]; then ok "START: working → spinning after ${w}ms (design ≤ 1000)"
else fail "START: working → spinning after ${w}ms, want ≤ ~1000"; fi

# --- ANIM ----------------------------------------------------------------------
g1=$(spin_of w1); sleep 0.4; g2=$(spin_of w1)
if is "$g1" spin && is "$g2" spin && [ "$g1" != "$g2" ]; then ok "ANIM: the glyph still moves ('$g1' → '$g2')"
else fail "ANIM: the glyph froze at '$g1'"; fi
r=$(rate 4)
# 1/0.12 ≈ 8.3 frames/s; one tmux per frame, plus the stuck sweep's ~0.1/s.
if le "$r" 10; then ok "ANIM: one working window → $r tmux calls/s (≤ ~1 per frame)"
else fail "ANIM: one working window → $r tmux calls/s, want ≤ ~1 per frame (8.3)" "$(sort "$CALLS" | uniq -c | sort -rn | head -5)"; fi

# --- STOP ----------------------------------------------------------------------
tl set-window-option -t "$LBL:w1" @claude_state 'done'
w=$(wait_spin w1 'done' 3000)
if [ "$w" != timeout ] && [ "$w" -le 1000 ]; then ok "STOP: done → ✓ after ${w}ms"
else fail "STOP: done → ✓ after ${w}ms, want ≤ 1000"; fi
sleep 1.5
r=$(rate 5)
if le "$r" 1.3; then ok "STOP: back to $r tmux calls/s once nothing animates"
else fail "STOP: still $r tmux calls/s after the last animation ended"; fi

# --- MARKER (the hook path) -----------------------------------------------------
# Run the real hook the way Claude Code would: inside the pane's $TMUX/$TMUX_PANE.
pane=$(tl display-message -p -t "$LBL:w2" '#{pane_id}')
rm -f "$SOCKP.dirty"
TMUX="$SOCKP,1,0" TMUX_PANE="$pane" CLAUDE_CODE_ENTRYPOINT=cli sh "$BIN/set-claude-state.sh" working </dev/null >/dev/null 2>&1
t0=$(now_ms)
if [ "$SPIN_SRC" = "$BIN/tmux-spinner.sh" ]; then
  [ "$(tl display-message -p -t "$LBL:w2" '#{@claude_state}')" = working ] \
    || fail "MARKER: set-claude-state.sh did not stamp the pane (test harness)"
fi
w=$(wait_spin w2 spin 3000)
[ "$w" = timeout ] || w=$(( $(now_ms) - t0 ))
if [ "$w" != timeout ] && [ "$w" -le 800 ]; then ok "MARKER: hook write → spinning after ${w}ms (design ≤ 250 + a frame)"
else fail "MARKER: hook write → spinning after ${w}ms, want well under the 1s re-read"; fi
if [ ! -e "$SOCKP.dirty" ]; then ok "MARKER: the spinner consumed <socket>.dirty"
else fail "MARKER: <socket>.dirty is still there — the quiet-fleet path never read it"; fi
tl set-window-option -t "$LBL:w2" @claude_state 'done'

# --- HB ------------------------------------------------------------------------
sleep 3.5
hb=$(cat "$WORK/logs/spinner.heartbeat" 2>/dev/null)
ep=${hb%% *}
case "$ep" in
  ''|*[!0-9]*) fail "HB: first token is not an epoch" "got: '$hb'" ;;
  *) ok "HB: first token is the bare epoch ($ep)" ;;
esac
tc=$(printf '%s' "$hb" | sed -n 's/.*tmux_calls_per_s=\([0-9.]*\).*/\1/p')
if [ -n "$tc" ]; then ok "HB: publishes tmux_calls_per_s=$tc (fleet-doctor's machine line)"
else fail "HB: no tmux_calls_per_s= field" "got: '$hb'"; fi

kill "$SPIN_PID" 2>/dev/null; wait "$SPIN_PID" 2>/dev/null; SPIN_PID=''

# --- the hook's half, with no spinner to consume it ------------------------------
rm -f "$SOCKP.dirty"
TMUX="$SOCKP,1,0" TMUX_PANE="$pane" CLAUDE_CODE_ENTRYPOINT=cli sh "$BIN/set-claude-state.sh" 'done' </dev/null >/dev/null 2>&1
if [ -e "$SOCKP.dirty" ]; then ok "MARKER: set-claude-state.sh drops <socket>.dirty on a state write"
else fail "MARKER: set-claude-state.sh wrote no <socket>.dirty ($SOCKP.dirty)"; fi
rm -f "$SOCKP.dirty"
printf '%d/%d checks passed\n' $((CHECKS - FAILS)) "$CHECKS"
[ "$FAILS" = 0 ]
