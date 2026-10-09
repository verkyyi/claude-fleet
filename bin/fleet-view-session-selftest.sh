#!/bin/bash
# fleet-view-session-selftest.sh — view sessions (issue #1489, EPIC #1479 R4): a
# shell or proxy client of a machine attaches to a GROUPED session of its own,
# `<fleet>@view-<id>` (bin/fleet-remote-view.sh attach), which shares the fleet's
# windows — so tmux lists every window once per session and, asked which session
# a window / pane / client is in, names whichever was active last. The rails are
# in bin/fleet-lib.sh: fleet_lw (every `list-windows -a`) and FLEET_SESSION_FMT
# (every window→session read); inline copies live in bin/tmux-spinner.sh (POSIX
# sh, no lib) and bin/fleet-alerts.sh (too hot to source the lib).
#
#   A. lint        — no bare `list-windows -a` in bin/ (fleet_lw, fleet_lw_fmt or
#                    an inline copy's format in front); no bare `#{session_name}`
#                    in a display-message of bin/, hooks/, or a run-shell hook of
#                    conf/ (the canonical `#{?#{session_group},…}` form instead)
#   B. in sync     — the inline awk copies in tmux-spinner.sh and fleet-alerts.sh
#                    are fleet_lw_filter's, byte for byte
#   C. degenerate  — on an isolated socket with NO view session, fleet_lw is the
#                    bare scan byte for byte (several formats, the empty one too)
#   D. view        — with a view session: fleet_lw lists each window once, as the
#                    fleet's row; FLEET_SESSION_FMT names the fleet from `-t @w`,
#                    `-t %p` and from INSIDE a pane (fleet_current_session), where
#                    the bare session_name names the view; fleet_is_view_session /
#                    fleet_session_canon; the inline filters agree on live rows
#   E. no close    — fleet-window-reap.sh --hook '<fleet>@view-x' is a no-op (a
#                    view session going away unlinks every window from IT); the
#                    list-sessions walkers (fleet-restore, the collector) skip a
#                    view session by name
# tmux absent → legs C–E SKIP (the lints still run). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$BIN/.."
FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }

# ============================================================================
# A. lint
# ============================================================================
# A1. every `list-windows -a` outside a comment or a selftest is fleet_lw's own
# call, or carries fleet_lw_fmt / an inline copy's `#{window_id}:#{session_id}:#{session_name} `
# in front of its format. `# view-ok: <why>` marks a deliberate exception.
bad=$(grep -n 'list-windows -a' "$BIN"/*.sh "$BIN"/*.py 2>/dev/null \
  | grep -v -- '-selftest\.sh:' \
  | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -v -E 'list-windows -a -F "\$\(fleet_lw_fmt |list-windows -a -F "\$\(_lw_fmt |list-windows -a -F "#\{window_id\}:#\{session_id\}:#\{session_name\} ' \
  | grep -v 'view-ok:')
eq "A1: no bare list-windows -a in bin/ (use fleet_lw; see bin/fleet-lib.sh)" "" "$bad"
# A2. a display-message that reads session_name reads it the canonical way.
bad=$(grep -n 'display-message' "$BIN"/*.sh "$BIN"/*.py "$ROOT"/hooks/*.py 2>/dev/null \
  | grep -v -- '-selftest\.sh:' | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep '#{session_name}' | grep -v 'session_group' | grep -v 'view-ok:')
eq "A2: no bare #{session_name} in a display-message of bin/ or hooks/ (use \$FLEET_SESSION_FMT)" "" "$bad"
# A2b. …nor one handed to a helper that reads it (issue #2102): fleet-transfer.sh's
# `opt '#{session_name}'` and fleet-loop.py's `pane(r, '#{session_name}|…')` never
# spelled display-message on the line, so A2 missed them — and with a Fleet Shell
# view attached every window read as another session's, so the quota failover
# marked them all unsupported. A quoted format that STARTS with a bare
# session_name is a window/pane read unless the line is a list-* scan.
bad=$(grep -n -E "[\"']#\{session_name\}[\"'| ]" "$BIN"/*.sh "$BIN"/*.py "$ROOT"/hooks/*.py 2>/dev/null \
  | grep -v -- '-selftest\.' | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -v -E 'list-sessions|list-clients|list-windows|fleet_lw|_fa_lw|lw_all|fleet_list_windows_all|WFMT=|_fmt=|session_group|view-ok:')
eq "A2b: no bare #{session_name} format handed to a pane/window read helper (use \$FLEET_SESSION_FMT)" "" "$bad"
# A2c. …nor the brace-less name a format helper wraps (issue #2622):
# fleet-sleep.py's `self.opt('session_name')` became `#{session_name}` inside
# opt(), so neither A2 nor A2b saw it — and with a view attached every worker
# read `wrong fleet`, so no idle window ever slept.
bad=$(grep -n -E "[(,][[:space:]]*[\"']session_name[\"'][[:space:]]*\)" "$BIN"/*.sh "$BIN"/*.py "$ROOT"/hooks/*.py 2>/dev/null \
  | grep -v -- '-selftest\.' | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v 'view-ok:')
eq "A2c: no bare 'session_name' handed to a format-wrapping read helper (use \$FLEET_SESSION_FMT)" "" "$bad"
# A3. a conf hook that hands a script the session names the fleet.
bad=$(grep -n 'run-shell' "$ROOT"/conf/*.conf 2>/dev/null | grep '#{session_name}' | grep -v 'session_group' | grep -v 'view-ok:')
eq "A3: no run-shell hook in conf/ passes a bare #{session_name}" "" "$bad"
# A4. the lib's own definitions are where the rails say.
has "A4: FLEET_SESSION_FMT is the group-or-name form" "$(grep -m1 '^FLEET_SESSION_FMT=' "$BIN/fleet-lib.sh")" "#{?#{session_group},#{session_group},#{session_name}}"
eq "A4: fleet_lw_fmt puts @wid:\$sid:session in front" "fleet_lw_fmt() { printf '#{window_id}:#{session_id}:#{session_name} %s' \"\$1\"; }" "$(grep -m1 '^fleet_lw_fmt()' "$BIN/fleet-lib.sh")"

# ============================================================================
# B. the inline copies are the lib's filter, byte for byte
# ============================================================================
awk_of() {   # <file> <function> — the awk program text of that function, whitespace squeezed
  awk -v fn="$2" '$0 ~ "^"fn"\\(\\) \\{" { on = 1 } on && /awk / { grab = 1 } grab { print } grab && /\}'"'"'/ { exit }' "$1" \
    | sed -n "s/.*awk '//; s/'\(.*\)\$//; p" | tr -s ' \t' ' ' | sed 's/^ //; s/ $//' | tr '\n' ' '
}
lib=$(awk_of "$BIN/fleet-lib.sh" fleet_lw_filter)
has "B: the lib filter drops view rows and dedups by window id" "$lib" 'index(s, "@view-") || (id in seen)'
eq "B: tmux-spinner.sh's _lw_filter is the lib's" "$lib" "$(awk_of "$BIN/tmux-spinner.sh" _lw_filter)"
eq "B: fleet-alerts.sh's _fa_lw filter is the lib's" "$lib" "$(awk_of "$BIN/fleet-alerts.sh" _fa_lw)"
eq "B: tmux-spinner.sh's _lw_fmt is the lib's" "_lw_fmt() { printf '#{window_id}:#{session_id}:#{session_name} %s' \"\$1\"; }" "$(grep -m1 '^_lw_fmt()' "$BIN/tmux-spinner.sh")"
has "B: fleet-alerts.sh asks tmux for the same prefix" "$(grep -m1 '^  tmux list-windows -a' "$BIN/fleet-alerts.sh")" '-F "#{window_id}:#{session_id}:#{session_name} $1"'
# a fake tmux's canned rows — even ones that begin with a window id — pass through untouched
eq "B: rows that are not fleet_lw_fmt's pass through the filter untouched" "$(printf '@9 done\n@1 %%1 101 acctB\ns1\t@1\tdone\nworking\nworking\n')" "$(printf '@9 done\n@1 %%1 101 acctB\ns1\t@1\tdone\nworking\nworking\n@3:$0:f@view-x a\n@2:$1:f b\n@2:$0:f@view-x b\n' | bash -c '. "$0/fleet-lib.sh"; fleet_lw_filter' "$BIN" | sed '$d')"
eq "B: …while fleet_lw_fmt rows are folded (a view row dropped, a window once)" "b" "$(printf '@3:$0:f@view-x a\n@2:$1:f b\n@2:$0:f@view-x b\n' | bash -c '. "$0/fleet-lib.sh"; fleet_lw_filter' "$BIN")"

# ============================================================================
# C/D/E need a tmux
# ============================================================================
REAL_TMUX=$(command -v tmux) || { printf 'fleet-view-session selftest: tmux absent — legs C–E SKIP; lints %s\n' "$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)"; exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fvs-st.XXXXXX")" || exit 2
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
unset TMUX TMUX_PANE
S="vs$$"
T() { "$REAL_TMUX" -L "$S" "$@"; }
cleanup() { "$REAL_TMUX" -L "$S" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
T -f /dev/null new-session -d -s "$S" -n hub -x 120 -y 30 'while :; do sleep 300; done' 2>/dev/null \
  || { printf 'fleet-view-session selftest: cannot start an isolated tmux server — SKIP\n' >&2; exit 0; }
W1=$(T new-window -d -P -F '#{window_id}' -t "$S:" -n 'issue-7 x' 'while :; do sleep 300; done')
W2=$(T new-window -d -P -F '#{window_id}' -t "$S:" -n issue-8 'while :; do sleep 300; done')
T set-window-option -t "$W1" @issue 7; T set-window-option -t "$W2" @issue 8
. "$BIN/fleet-lib.sh"
US=$'\037'; TAB=$'\t'

# ---- C. degenerate: no view session → fleet_lw IS the bare scan ----------------
for fmt in '#{session_name}:#{window_index} #{window_name}' '#{window_id}|#{session_name}|#{@issue}|#{window_name}' "#{session_name}${TAB}#{@issue}${TAB}#{window_name}" "#{window_id}${US}#{window_name}${US}#{@issue}" '#{@wid}' ''; do
  eq "C: fleet_lw == bare list-windows -a for format '${fmt//$US/\\037}'" "$(T list-windows -a -F "$fmt")" "$(fleet_lw "$fmt" T)"
done
eq "C: a dead server reads as tmux's failure" "1" "$(fleet_lw x "$REAL_TMUX" -L "nosuch$$" >/dev/null; echo $?)"
eq "C: FLEET_SESSION_FMT from a pane names the (ungrouped) fleet" "$S" "$(T display-message -p -t "$W1" "$FLEET_SESSION_FMT")"

# ---- D. with a view session ------------------------------------------------------
V="$S@view-abc1"
T new-session -d -t "=$S" -s "$V" || fail "D: rig: no grouped session"
T select-window -t "=$V:$W2"; T select-window -t "=$S:hub"
eq "D: tmux itself now lists every window twice" "6" "$(T list-windows -a -F x | grep -c x)"
for fmt in '#{session_name}:#{window_index} #{window_name}' '#{window_id}|#{session_name}|#{@issue}|#{window_name}' "#{session_name}${TAB}#{@issue}${TAB}#{window_name}" '#{@wid}'; do
  eq "D: fleet_lw lists each window once, as the fleet's row, for '$fmt'" "$(T list-windows -t "=$S" -F "$fmt")" "$(fleet_lw "$fmt" T)"
done
eq "D: …the fleet's current window, not the view's, is the active one it reports" "hub" "$(fleet_lw '#{?window_active,#{window_name},}' T | grep .)"
eq "D: fleet_lw_fmt + fleet_lw_filter (a command sequence's form) agree with fleet_lw" "$(fleet_lw '#{session_name} #{window_id}' T)" "$(T list-windows -a -F "$(fleet_lw_fmt '#{session_name} #{window_id}')" | fleet_lw_filter)"
eq "D: fleet_list_windows_all fans fleet_lw over the sockets" "$(T list-windows -t "=$S" -F '#{session_name} #{window_id}')" "$(fleet_sockets() { printf '%s\n' "$S"; }; fleet_list_windows_all '#{session_name} #{window_id}')"
# the window→session reads
eq "D: FLEET_SESSION_FMT from -t @w names the fleet" "$S" "$(T display-message -p -t "$W2" "$FLEET_SESSION_FMT")"
P2=$(T display-message -p -t "$W2" '#{pane_id}')
eq "D: …from -t %p too" "$S" "$(T display-message -p -t "$P2" "$FLEET_SESSION_FMT")"
eq "D: …and from the view session itself" "$S" "$(T display-message -p -t "=$V:" "$FLEET_SESSION_FMT")"
eq "D: (the bare session_name there is the view's — the hazard)" "$V" "$(T display-message -p -t "=$V:" '#{session_name}')"
# from INSIDE a pane: what a Claude hook or a dash script sees
T respawn-pane -k -t "$W1" "sh -c '. $BIN/fleet-lib.sh; fleet_current_session > $WORK/cur; tmux display-message -p \"#{session_name}\" > $WORK/bare; while :; do sleep 300; done'"
n=50; while [ "$n" -gt 0 ] && [ ! -s "$WORK/bare" ]; do sleep 0.1; n=$((n - 1)); done
eq "D: fleet_current_session inside a pane of the shared window names the fleet" "$S" "$(cat "$WORK/cur" 2>/dev/null)"
case "$(cat "$WORK/bare" 2>/dev/null)" in "$S"|"$V") CHECKS=$((CHECKS + 1)) ;; *) fail "D: rig: the bare read inside the pane is neither name" "$(cat "$WORK/bare")" ;; esac
# the names
eq "D: fleet_is_view_session" "view fleet" "$(fleet_is_view_session "$V" && echo view) $(fleet_is_view_session "$S" || echo fleet)"
eq "D: fleet_session_canon" "$S $S" "$(fleet_session_canon "$V") $(fleet_session_canon "$S")"
# the inline copies, on live rows
raw=$(T list-windows -a -F "$(fleet_lw_fmt '#{session_name} #{window_id} #{window_name}')")
spin=$(sed -n '/^_lw_filter() {/,/^}/p' "$BIN/tmux-spinner.sh")
eq "D: tmux-spinner.sh's _lw_filter agrees with fleet_lw_filter on live rows" "$(printf '%s\n' "$raw" | fleet_lw_filter)" "$(printf '%s\n' "$raw" | sh -c "$spin; _lw_filter")"
eq "D: fleet-alerts.sh's _fa_lw agrees with fleet_lw on live rows" "$(fleet_lw '#{session_name} #{window_id} #{window_name}' T)" \
   "$(tmux() { T "$@"; }; eval "$(sed -n '/^_fa_lw() {/,/^}/p' "$BIN/fleet-alerts.sh")"; _fa_lw '#{session_name} #{window_id} #{window_name}')"

# ---- E. a view session is no close and no fleet ------------------------------------
FLEET_WINDOW_REAP_FG=1 FLEET_WINDOW_REAP_PASSES=0 bash "$BIN/fleet-window-reap.sh" --hook "$V" >/dev/null 2>&1; rc=$?
eq "E: fleet-window-reap.sh --hook <view session> is a no-op (exit 0, no sweeper lock)" "0 none" "$rc $([ -d "$FLEET_CONF_DIR/diskguard/window-reap.lock" ] && echo lock || echo none)"
has "E: fleet-restore.sh skips a view session when it walks list-sessions" "$(grep -A1 'fleet_is_pool_session "\$sess" "\$sock" && continue' "$BIN/fleet-restore.sh")" 'fleet_is_view_session "$sess" && continue'
has "E: the collector skips a view session when it walks list-sessions" "$(grep -A1 "list-sessions -F '#{session_name}' 2>/dev/null); do" "$BIN/tmux-dash-collect.sh")" 'fleet_is_view_session "$sess" && continue'
has "E: the window-unlinked hook hands the reaper the unlinking session" "$(grep 'window-unlinked\[72\]' "$ROOT/conf/tmux-attention.conf")" "--hook '#{hook_session_name}'"

if [ "$FAIL" -eq 0 ]; then printf 'fleet-view-session selftest: PASS (%d checks)\n' "$CHECKS"; exit 0; fi
printf 'fleet-view-session selftest: %d FAILED of %d\n' "$FAIL" "$CHECKS" >&2
exit 1
