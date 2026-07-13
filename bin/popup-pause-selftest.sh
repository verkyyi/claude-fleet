#!/bin/bash
# popup-pause-selftest.sh — the "pause dash repaint under an open modal popup"
# contract (issue #308).
#
# The bug: a tmux display-popup is a CLIENT-SIDE overlay that does NOT freeze the
# panes under it, so the dash's 1Hz reload keeps re-rendering right beneath the
# popup and that churn flashes THROUGH it — worst where the popup edge clips a
# double-width CJK cell. The fix is a server-global @popup_open flag: the modal
# popup binds (conf/tmux-attention.conf) raise it for the popup's lifetime, and
# the dash reload loop (bin/tmux-dashboard.sh) busy-waits on it so it emits no new
# frame while a popup is open.
#
# This asserts BOTH ends of that contract:
#   • PRODUCER  every modal display-popup bind in the conf is bracketed by
#               `set -g @popup_open 1 … set -g @popup_open 0`, and the conf still
#               parses on a REAL, isolated tmux server (its own socket, torn down
#               at exit — never the user's live server).
#   • CONSUMER  the dash's reload guard BLOCKS while @popup_open=1 (no repaint
#               under the popup), RESUMES the instant the flag clears, and — when
#               the flag STICKS at 1 (a popup that leaked without clearing it,
#               issue #323) — self-heals by repainting after a bounded cap instead
#               of busy-waiting forever. Driven against the isolated server through
#               the exact bare-`tmux` predicate the dashboard uses (a PATH shim
#               routes it to the private socket).
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
DASH="$BIN/tmux-dashboard.sh"
CONF="$ROOT/conf/tmux-attention.conf"
[ -f "$DASH" ] || { printf 'selftest: %s not found\n' "$DASH" >&2; exit 2; }
[ -f "$CONF" ] || { printf 'selftest: %s not found\n' "$CONF" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# --- PRODUCER (static): dash reload GATES $ROWS on @popup_open ----------------
# The re-render (`bash $ROWS`) must sit AFTER the @popup_open wait loop, so no
# frame is emitted while the flag is set. Order matters: @popup_open … done …
# bash $ROWS.
grep -Eq 'load:reload-sync\(.*@popup_open.*done;[[:space:]]*bash[[:space:]]+\$ROWS\)' "$DASH" \
  || fail "tmux-dashboard.sh reload bind no longer gates \$ROWS on @popup_open (issue #308)"

# --- PRODUCER (static): the @popup_open pause is CAPPED, not unbounded ----------
# A leaked flag (popup died before its trailing `set 0`) must not freeze the dash
# forever (issue #323). The reload wait must carry an upper-bound counter (`-lt`)
# alongside the @popup_open predicate, so it repaints after the cap regardless.
grep -Eq 'load:reload-sync\(.*@popup_open.*-lt.*done;[[:space:]]*bash[[:space:]]+\$ROWS\)' "$DASH" \
  || fail "tmux-dashboard.sh reload bind no longer CAPS the @popup_open pause (issue #323) — a stuck flag could freeze the dash forever"

# --- PRODUCER (static): every modal popup in the conf is flag-bracketed -------
# Count in CODE lines only (skip the explanatory comment block, which names the
# flag in prose). One set-1 and one set-0 per display-popup surface; there are 6
# (prefix b/c/? + the fleet-pick / acct / usage mouse popups).
code_only() { grep -v '^[[:space:]]*#' "$CONF"; }
npop=$(grep -c 'display-popup' "$CONF")
[ "$npop" -ge 6 ] || fail "expected >=6 display-popup binds in conf, found $npop"
nset1=$(code_only | grep -c '@popup_open 1')
nset0=$(code_only | grep -c '@popup_open 0')
{ [ "$nset1" -eq 6 ] && [ "$nset0" -eq 6 ]; } \
  || fail "flag set/clear mismatch: set-1=$nset1 set-0=$nset0 (want 6 each — one per popup)"

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

tmux new-session -d -s t -x 200 -y 50 2>/dev/null || fail "could not start isolated tmux server"

# --- PRODUCER (live): the conf parses AND registers the flagged binds ---------
tmux source-file "$CONF" 2>"$WORK/src.err" \
  || { printf '%s\n' "$(cat "$WORK/src.err" 2>/dev/null)" >&2; fail "conf/tmux-attention.conf failed to source (syntax error in the popup-bind wrap)"; }
for k in b c '?'; do
  tmux list-keys -T prefix 2>/dev/null | grep -F -- " $k " | grep -q 'popup_open' \
    || fail "prefix '$k' bind lost its @popup_open wrap after sourcing"
done
tmux list-keys -T root 2>/dev/null | grep -i 'MouseDown1Status' | grep -q 'popup_open' \
  || fail "MouseDown1Status mouse popups lost their @popup_open wrap after sourcing"

# --- CONSUMER (live): the dash guard blocks on the flag, resumes on clear ------
# Mirror the EXACT predicate from tmux-dashboard.sh's reload bind. MARK stands in
# for `bash $ROWS` — it must appear only once the guard is allowed past the wait.
MARK="$WORK/rows_ran"
guard() { while [ "$(tmux show-option -gqv @popup_open 2>/dev/null)" = 1 ]; do sleep 0.05; done; : > "$MARK"; }
wait_mark() { w=0; while [ "$w" -lt 40 ]; do [ -e "$MARK" ] && return 0; sleep 0.05; w=$((w + 1)); done; return 1; }

# 1) DEFAULT (flag unset): the guard must fall straight through — a normal repaint.
tmux set-option -gu @popup_open 2>/dev/null
rm -f "$MARK"; guard & gpid=$!
wait_mark || fail "guard blocked with @popup_open UNSET — the dash would never repaint"
wait "$gpid" 2>/dev/null || true

# 2) POPUP OPEN (flag=1): the guard must NOT emit a frame (no under-popup churn).
tmux set-option -g @popup_open 1
rm -f "$MARK"; guard & gpid=$!
sleep 0.4
[ -e "$MARK" ] && fail "guard emitted a frame while @popup_open=1 — the dash would repaint under the popup"

# 3) POPUP CLOSED (flag→0): the guard must resume promptly and emit one frame.
tmux set-option -g @popup_open 0
wait_mark || fail "guard did not resume after @popup_open cleared — the dash would stay frozen"
wait "$gpid" 2>/dev/null || true

# 4) STUCK FLAG (flag=1 forever): the CAPPED guard must self-heal — repaint after
# the cap instead of busy-waiting unbounded (issue #323). Mirror the real reload
# predicate but with a small tick cap so the test is fast; the flag never clears.
CAP_TICKS=4   # 4 × 0.05s ≈ 0.2s cap for the test (real default: FLEET_DASH_POPUP_MAX_PAUSE/POPUP_POLL)
guard_capped() {
  n=0
  while [ "$(tmux show-option -gqv @popup_open 2>/dev/null)" = 1 ] && [ "$n" -lt "$CAP_TICKS" ]; do
    sleep 0.05; n=$((n + 1))
  done
  : > "$MARK"
}
tmux set-option -g @popup_open 1   # leak it: stays 1 for the whole check
rm -f "$MARK"; guard_capped & gpid=$!
wait_mark || fail "capped guard never repainted with @popup_open STUCK at 1 — a leaked flag would freeze the dash forever (issue #323)"
wait "$gpid" 2>/dev/null || true
tmux set-option -gu @popup_open 2>/dev/null   # leave the isolated server tidy

printf 'selftest PASS: modal popups flag @popup_open; the dash pauses its repaint while set, resumes on clear, and self-heals when the flag sticks\n'
exit 0
