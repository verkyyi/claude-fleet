#!/bin/bash
# backlog-hide-bound-selftest.sh — the "hide issues bound to a live worker" rail
# (issue #162).
#
# By default the backlog panel hides any open issue that already has a live
# worker window (@issue) in THIS fleet; ⌃b flips a per-fleet state file to reveal
# them. This drives the REAL bin/tmux-issues-rows.sh against a REAL, isolated
# tmux server (its own socket, torn down at exit — never the user's live server)
# and the REAL bin/dash-toggle-show-bound.sh:
#   • HIDE DEFAULT   a bound issue is absent from the rows; unbound ones stay.
#   • COUNTS         milestone counts reflect the visible rows, not the hidden ones.
#   • TOGGLE SHOW    after the toggle, the bound issue reappears with its ▶window marker
#                    and the count grows; a second toggle hides it again (persists).
#   • ALL BOUND      every open issue bound + hide-mode ⇒ the friendly explainer line,
#                    not a bare "(no open issues)".
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-issues-rows.sh"
TOGGLE="$BIN/dash-toggle-show-bound.sh"
[ -f "$ROWS" ]   || { printf 'selftest: %s not found\n' "$ROWS" >&2; exit 2; }
[ -f "$TOGGLE" ] || { printf 'selftest: %s not found\n' "$TOGGLE" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bhb-selftest.XXXXXX")" || exit 2

# Isolate every tmux call (rows reads @issue bindings via `tmux list-windows`)
# onto a private socket so we never touch the user's live server. A PATH shim
# routes the plain `tmux` the scripts call to it. TMPDIR points the dash state
# dir ($C / FLEET_C) at our sandbox too, so the issues cache + toggle file live
# under $WORK and there is no sessmap (⇒ flat $C/issues fallback).
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
export TMPDIR="$WORK"
C="$WORK/.claude-dash"
mkdir -p "$C"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
TAB=$'\t'; US=$'\x1f'
# count visible DATA rows (numeric field1) — the flat list (issue #377) has no
# ' <milestone> (N) ' group-header line to read a count off, so tally rows directly.
count_rows() { printf '%s\n' "$1" | awk -F"$US" '$1 ~ /^[0-9]+$/{n++} END{print n+0}'; }

# --- fixture: three open issues, one of which we bind to a live worker window --
# cache format (collector's $C/issues): milestone<TAB>#num<TAB>assignee<TAB>title.
# The assignee field is '·' for unassigned — the collector never writes it empty,
# and it must not be (IFS=$'\t' is whitespace, so a genuinely empty field would
# collapse two tabs into one and shift the title out). Titles stay ≤14 chars —
# the rows producer truncates the title column at 14.
printf 'Week 1%s#40%s·%salpha\n'  "$TAB" "$TAB" "$TAB" >  "$C/issues"
printf 'Week 1%s#42%s·%sbravo\n'  "$TAB" "$TAB" "$TAB" >> "$C/issues"
printf '· no milestone%s#50%s·%scharlie\n' "$TAB" "$TAB" "$TAB" >> "$C/issues"

# a fleet session "t" with a worker window bound to issue #42
tmux new-session -d -s t -x 200 -y 50 2>/dev/null || fail "could not start isolated tmux server"
tmux rename-window -t t "wrk"
tmux set-option -w -t t:wrk @issue 42

rows() { FLEET_SESSION=t bash "$ROWS" "${1:-all}" 2>/dev/null; }

# --- HIDE DEFAULT: bound #42 gone, unbound #40/#50 present ------------------
out="$(rows all)"
printf '%s\n' "$out" | grep -qF 'alpha'   || fail "unbound issue #40 should be listed by default"
printf '%s\n' "$out" | grep -qF 'charlie' || fail "unbound issue #50 should be listed by default"
printf '%s\n' "$out" | grep -qF 'bravo'     && fail "bound issue #42 must be HIDDEN by default"

# --- COUNTS: 2 issues visible (#40 + #50); the bound #42 is hidden -----------
[ "$(count_rows "$out")" = 2 ] || fail "expected 2 visible rows (bound #42 hidden), got $(count_rows "$out")"

# --- TOGGLE SHOW: reveal bound rows -----------------------------------------
bash "$TOGGLE" t
[ -f "$C/global/backlog_show_bound_t" ] || fail "toggle should create the per-fleet show-bound state file"
out="$(rows all)"
printf '%s\n' "$out" | grep -qF 'bravo' || fail "bound issue #42 should REAPPEAR after the toggle"
printf '%s\n' "$out" | grep -qF '▶ wrk'       || fail "a shown bound issue keeps its ▶window marker"
[ "$(count_rows "$out")" = 3 ] || fail "visible rows must grow to 3 when the bound row is shown, got $(count_rows "$out")"

# --- TOGGLE HIDE again: back to hidden, state removed ------------------------
bash "$TOGGLE" t
[ -f "$C/global/backlog_show_bound_t" ] && fail "a second toggle should remove the show-bound state file"
out="$(rows all)"
printf '%s\n' "$out" | grep -qF 'bravo' && fail "bound issue #42 should be HIDDEN again after re-toggle"

# --- ALL BOUND: every open issue bound + hide-mode ⇒ explainer line ----------
printf 'Week 1%s#42%s·%sbravo\n' "$TAB" "$TAB" "$TAB" > "$C/issues"   # only the bound one
out="$(rows all)"
printf '%s\n' "$out" | grep -qF 'all open issues have a live worker' \
  || fail "all-bound + hide-mode should show the friendly explainer, not a blank/'(no open issues)'"
printf '%s\n' "$out" | grep -qF 'no open issues' \
  && fail "all-bound case must NOT fall through to the bare '(no open issues)' line"

printf 'selftest PASS: backlog hides bound issues by default, ⌃b toggles them, counts + all-bound line track\n'
exit 0
