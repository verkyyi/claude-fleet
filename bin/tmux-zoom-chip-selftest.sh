#!/bin/bash
# tmux-zoom-chip-selftest.sh — the single-tap touch pane-zoom chip contract
# (issue #329).
#
# The gap: `bind -n DoubleClick1Pane resize-pane -Z -t=` zooms a pane on a desktop
# trackpad but does NOT reliably fire over iPad/Termius touch — the two taps jitter
# a cell (any movement downgrades it to two single clicks), the client's gesture
# recognizer may consume the double-tap, and SSH latency can exceed tmux's ~500ms
# double-click window. Single-click status ranges DO reach tmux over touch (the
# footer hub/attn/acct/usage chips already prove it), so the fix is a single-tap
# "⛶" zoom chip in status-left wired to a new `zoom` MouseDown1Status range that
# toggles the active pane's zoom (resize-pane -Z) — additive, the desktop
# DoubleClick1* binds stay.
#
# This asserts the whole contract against a REAL, isolated tmux server (its own
# socket via a PATH shim, torn down at exit — never the user's live server, same
# pattern as dash-marker-selftest.sh / popup-pause-selftest.sh):
#   • EMITTED     status-left carries the clickable `range=user|zoom` chip.
#   • PARSES      the conf sources cleanly (the new nested `if -F zoom` branch does
#                 not break the deeply-nested MouseDown1Status dispatch).
#   • ROUTES      the MouseDown1Status bind gates a `zoom` branch on its OWN
#                 `mouse_status_range,zoom` and runs `resize-pane -Z` — so a zoom
#                 click can't hijack another range, and no other range triggers zoom.
#   • NO REGRESS  the pre-existing ranges (fleet/attn/acct/usage/hub) all survive
#                 in the same dispatch, and the desktop `DoubleClick1Pane` /
#                 `DoubleClick1Border` zoom binds are still present.
#   • TOGGLES     the exact command the zoom branch runs (`resize-pane -Z`) flips
#                 the active pane's `window_zoomed_flag` 0→1→0 on a real 2-pane
#                 window — the mechanism the chip fires actually zooms.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
CONF="$ROOT/conf/tmux-attention.conf"
[ -f "$CONF" ] || { printf 'selftest: %s not found\n' "$CONF" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# --- EMITTED (static): status-left ships the clickable zoom chip ---------------
# The ⛶ glyph wrapped in `range=user|zoom` is what makes the chip tappable; the
# dispatch below is dead without it.
grep -Eq 'status-left .*range=user\|zoom' "$CONF" \
  || fail "status-left no longer emits the clickable 'range=user|zoom' chip (issue #329)"
grep -Eq 'status-left .*⛶' "$CONF" \
  || fail "status-left no longer carries the ⛶ zoom glyph (issue #329)"

# --- isolated tmux server + PATH shim (never the user's live server) -----------
# Route the plain `tmux` used below to a private socket, reaped on exit.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zc-selftest.XXXXXX")" || exit 2
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

# --- PARSES (live): the conf sources without a syntax error -------------------
tmux source-file "$CONF" 2>"$WORK/src.err" \
  || { printf '%s\n' "$(cat "$WORK/src.err" 2>/dev/null)" >&2; fail "conf/tmux-attention.conf failed to source (syntax error in the zoom-branch nesting)"; }

# --- ROUTES / NO REGRESS (live): inspect the dispatch as tmux flattened it -----
# list-keys renders the whole MouseDown1Status bind on ONE line, so grep it whole.
mds="$(tmux list-keys -T root 2>/dev/null | grep -i 'MouseDown1Status' | grep -v -i 'C-MouseDown1Status')"
[ -n "$mds" ] || fail "no MouseDown1Status bind registered after sourcing the conf"
# The zoom branch is gated on its OWN range and runs resize-pane -Z (can't hijack
# another range; no other range runs resize-pane).
printf '%s\n' "$mds" | grep -Eq 'mouse_status_range\},zoom.*\{ *resize-pane -Z *\}' \
  || fail "MouseDown1Status has no 'zoom' branch gated on mouse_status_range=zoom running 'resize-pane -Z' (issue #329)"
# The pre-existing ranges all survive the edit (guards an accidental branch drop).
for r in fleet attn acct usage hub; do
  printf '%s\n' "$mds" | grep -Eq "mouse_status_range\\},$r" \
    || fail "MouseDown1Status lost its pre-existing '$r' range after adding zoom"
done
# Desktop double-click zoom is NOT regressed — both binds still map to resize-pane -Z.
tmux list-keys -T root 2>/dev/null | grep -Eq 'DoubleClick1Pane +resize-pane -Z' \
  || fail "DoubleClick1Pane no longer zooms (resize-pane -Z) — desktop path regressed"
tmux list-keys -T root 2>/dev/null | grep -Eq 'DoubleClick1Border +resize-pane -Z' \
  || fail "DoubleClick1Border no longer zooms (resize-pane -Z) — desktop divider path regressed"

# --- TOGGLES (live): the zoom branch's command flips window_zoomed_flag --------
# Build a two-pane window so zoom has something to toggle, then run the EXACT
# command the zoom branch runs and watch the active pane's zoom flag flip 0→1→0.
paneA="$(tmux list-panes -t t -F '#{pane_id}' | head -n1)"
paneB="$(tmux split-window -d -P -F '#{pane_id}' -t "$paneA")"
[ -n "$paneA" ] && [ -n "$paneB" ] && [ "$paneA" != "$paneB" ] || fail "could not build two distinct panes"
tmux select-pane -t "$paneA"
zflag() { tmux display-message -p -t t '#{window_zoomed_flag}'; }
[ "$(zflag)" = 0 ] || fail "a fresh 2-pane window should start un-zoomed (window_zoomed_flag=0)"
tmux resize-pane -Z                        # the zoom branch's command (default target = active pane)
[ "$(zflag)" = 1 ] || fail "resize-pane -Z did not zoom the active pane (window_zoomed_flag stayed 0)"
tmux resize-pane -Z                        # tap again → un-zoom (a toggle)
[ "$(zflag)" = 0 ] || fail "a second resize-pane -Z did not un-zoom — the chip must toggle, not one-way"

printf 'selftest PASS: the ⛶ zoom chip emits a gated zoom range that toggles the active pane; existing ranges + desktop double-click zoom intact\n'
exit 0
