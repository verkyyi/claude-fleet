#!/bin/bash
# dash-marker-selftest.sh — the @dash / @steward pane-marker contract (issue #135).
#
# The bug: bin/tmux-dashboard.sh marked its pane with a bare `set-option -p @dash 1`.
# `-p` WITHOUT an explicit `-t` targets the *active* pane, not the pane the script
# runs in — so an embedded dash relaunching while the steward pane was focused
# tagged the STEWARD pane instead. Both zoom scripts and /fleet-sync-install key
# off these markers, and a pane must never carry both @dash and @steward.
#
# This drives the REAL fleet_mark_role() (fleet-lib.sh) against a REAL, isolated
# tmux server (its own socket, torn down at exit — never the user's live server):
#   • NOT-ACTIVE-PANE  marking pane B while pane A is active tags B, not A.
#   • DEFAULT TARGET   with no pane arg it marks $TMUX_PANE (the caller's own pane).
#   • MUTUAL EXCLUSION setting one role clears the other on that pane.
#   • BUG REPRO        the old bare `-p` form provably tags the active pane.
#   • STATIC GUARD     tmux-dashboard.sh no longer uses the bare-`-p` form.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dm-selftest.XXXXXX")" || exit 2

# Isolate every tmux call onto a private socket so we never touch the user's live
# server. A PATH shim routes the plain `tmux` that fleet_mark_role calls to it.
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

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
opt()  { tmux show-options -p -t "$1" -v "$2" 2>/dev/null; }  # pane option value (empty if unset)

# shellcheck source=/dev/null
. "$LIB"
command -v fleet_mark_role >/dev/null 2>&1 || fail "fleet_mark_role not defined by fleet-lib.sh"

# --- build a two-pane window on the isolated server -------------------------
tmux new-session -d -s t -x 200 -y 50 2>/dev/null || fail "could not start isolated tmux server"
paneA="$(tmux list-panes -t t -F '#{pane_id}' | head -n1)"
paneB="$(tmux split-window -d -P -F '#{pane_id}' -t "$paneA")"
[ -n "$paneA" ] && [ -n "$paneB" ] && [ "$paneA" != "$paneB" ] || fail "could not build two distinct panes"
tmux select-pane -t "$paneA"   # pane A is the ACTIVE pane for the rest of the test

# --- NOT-ACTIVE-PANE: mark B explicitly while A is active -------------------
fleet_mark_role dash "$paneB"
[ "$(opt "$paneB" @dash)" = 1 ] || fail "dash marker should land on the named pane B"
[ -z "$(opt "$paneA" @dash)" ]  || fail "dash marker must NOT leak onto the active pane A (issue #135)"

# --- DEFAULT TARGET: no pane arg ⇒ caller's own \$TMUX_PANE ------------------
tmux set-option -u -p -t "$paneB" @dash 2>/dev/null
TMUX_PANE="$paneB" fleet_mark_role dash
[ "$(opt "$paneB" @dash)" = 1 ] || fail "default target (\$TMUX_PANE) should mark pane B"

# --- MUTUAL EXCLUSION: a pane is never both @dash and @steward --------------
fleet_mark_role steward "$paneB"
[ "$(opt "$paneB" @steward)" = 1 ] || fail "steward marker should be set on pane B"
[ -z "$(opt "$paneB" @dash)" ]     || fail "@dash must be cleared when @steward is set"
fleet_mark_role dash "$paneB"
[ "$(opt "$paneB" @dash)" = 1 ]    || fail "dash marker should be set on pane B"
[ -z "$(opt "$paneB" @steward)" ]  || fail "@steward must be cleared when @dash is set"

# --- invalid role ⇒ non-zero, no marker written -----------------------------
tmux set-option -u -p -t "$paneB" @dash 2>/dev/null
if fleet_mark_role bogus "$paneB"; then fail "an unknown role should return non-zero"; fi
[ -z "$(opt "$paneB" @dash)" ] || fail "an unknown role must not write a marker"

# --- BUG REPRO: the OLD bare `-p` form tags whatever pane is ACTIVE ----------
# Documents exactly why the explicit `-t` matters — with A active, the bare form
# marks A even though the intent was to mark B.
tmux set-option -u -p -t "$paneA" @dash 2>/dev/null
tmux set-option -u -p -t "$paneB" @dash 2>/dev/null
tmux select-pane -t "$paneA"
tmux set-option -p @dash 1 2>/dev/null   # the pre-fix form (no -t)
[ "$(opt "$paneA" @dash)" = 1 ] || fail "sanity: a bare -p set-option should mark the ACTIVE pane"

# --- STATIC GUARD: the dashboard no longer uses the bare-`-p` form -----------
if grep -Eq 'set-option +-p +@dash' "$BIN/tmux-dashboard.sh"; then
  fail "tmux-dashboard.sh still marks @dash with a bare 'set-option -p' (no -t) — regression"
fi

printf 'selftest PASS: @dash/@steward markers target the named pane, stay mutually exclusive\n'
exit 0
