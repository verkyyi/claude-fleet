#!/bin/bash
# dash-rename-selftest.sh — the dash ⌃e RENAME MODE contract (issue #449).
#
# ⌃e arms rename mode (bin/dash-rename.sh), Enter commits it and Esc cancels it
# (the long-standing rename branches in dash-enter.sh / dash-esc.sh, orphaned
# between #289 and #449). This drives all three scripts for real against an
# ISOLATED tmux server on its own socket — never the user's live server — via the
# `-S <sock>` PATH shim the sibling dash selftests use (dash-marker-selftest.sh):
#
#   A. ARM          a live row → stashes the target, emits show-input +
#                   change-prompt(rename ▸ ) + change-query(<current name>)
#   A2. UNBIND ?    show-input does NOT demote a PRINTABLE key that --bind claimed:
#                   with `?` (the dash cheatsheet) still bound, typing `?` into a
#                   name fires the popup instead of inserting a character (verified
#                   live on fzf 0.74.3). ⌃e must unbind it; Enter/Esc must rebind it.
#   B. IDEMPOTENT   a second ⌃e while armed is a NO-OP (⌃e is fzf's default
#                   end-of-line, so a stray press must not reset a half-typed name)
#   C. LANDED ROW   a `landed:<pr>` target never arms (not a live window)
#   D. NO TARGET    an empty target never arms
#   E. LANDED VIEW  with the per-fleet dash_view_<sess> flag = landed, ⌃e is inert
#   F. STALE ROW    a row whose window is gone never arms (an armed flag with no
#                   window would swallow the next Enter)
#   G. PARENS       a window name containing parens is stripped, so the emitted
#                   change-query(...) stays parseable (fzf stops at the first ')')
#   H. COMMIT       Enter renames the STASHED target to the typed query, drops the
#                   flag, and restores hide-input + the '▸ ' prompt
#   I. EMPTY CANCEL an empty query cancels — the window keeps its name
#   J. ESC CANCEL   Esc drops the flag and backs out WITHOUT aborting the dash
#   K. @issue KEEPS the window's @issue binding survives the rename (what
#                   dash-issue-session.sh's "survives a ctrl-e rename" match relies on)
#   M. LEADING '-'  a name starting with '-' commits (dash-enter.sh passes `--`,
#                   or tmux parses the name as a flag and the rename silently fails)
#   L. SHELLCHECK   dash-rename.sh is shellcheck-clean (skipped if absent)
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REN="$BIN/dash-rename.sh"; ENT="$BIN/dash-enter.sh"; ESC="$BIN/dash-esc.sh"
for f in "$REN" "$ENT" "$ESC"; do
  [ -f "$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }
done
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dr-selftest.XXXXXX")" || exit 2

# Route every bare `tmux` (the scripts call it unqualified) to a private socket.
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
# The scripts key their state dir off \$TMPDIR — point it at the sandbox so a run
# can never read or clobber the real dash's $TMPDIR/.claude-dash flags.
export TMPDIR="$WORK"
C="$WORK/.claude-dash"; FLAG="$C/rename_target"
export FLEET_SESSION=t
VIEW="$C/global/dash_view_t"
mkdir -p "$C/global"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
# A bare EXIT trap does NOT fire on a signal — turn INT/TERM/HUP into a normal
# exit so the isolated server is reaped rather than leaked (issue #152).
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }
wname() { tmux display-message -p -t "$1" '#{window_name}' 2>/dev/null; }

tmux new-session -d -s t -n one -x 200 -y 50 2>/dev/null \
  || fail "could not start the isolated tmux server"
T="t:$(tmux list-windows -t t -F '#{window_index}' | head -n1)"
[ "$(wname "$T")" = one ] || fail "fixture window should be named 'one'"

# --- A. ARM -------------------------------------------------------------------
out="$(bash "$REN" "$T")"
case "$out" in *show-input*) ;; *) fail "A: ⌃e must emit show-input" "$out" ;; esac
case "$out" in *"change-prompt(rename ▸ )"*) ;; *) fail "A: ⌃e must switch the prompt to 'rename ▸ '" "$out" ;; esac
case "$out" in *"change-query(one)"*) ;; *) fail "A: ⌃e must pre-fill the current window name" "$out" ;; esac
case "$out" in *"unbind(?)"*) ;; *) fail "A2: ⌃e must unbind '?' so it types instead of opening the cheatsheet" "$out" ;; esac
[ "$(cat "$FLAG" 2>/dev/null)" = "$T" ] || fail "A: ⌃e must stash the highlighted target in rename_target"
ok "A ⌃e arms rename mode on the highlighted row"

# --- B. IDEMPOTENT (flag still set from A) ------------------------------------
out="$(bash "$REN" "t:99")"
[ -z "$out" ] || fail "B: a second ⌃e while armed must emit no action" "$out"
[ "$(cat "$FLAG" 2>/dev/null)" = "$T" ] || fail "B: a second ⌃e must not re-stash the target"
ok "B a second ⌃e while armed is a no-op"
rm -f "$FLAG"

# --- C/D. landed row · no target ----------------------------------------------
for bad in "landed:42" "landed:issue:42" ""; do
  out="$(bash "$REN" "$bad")"
  [ -z "$out" ] || fail "C/D: target '$bad' must not arm rename" "$out"
  [ -f "$FLAG" ] && fail "C/D: target '$bad' must leave no rename_target flag"
done
ok "C/D landed rows and an empty target never arm rename"

# --- E. LANDED VIEW -----------------------------------------------------------
printf 'landed\n' > "$VIEW"
out="$(bash "$REN" "$T")"
[ -z "$out" ] || fail "E: ⌃e must be inert in the landed view" "$out"
[ -f "$FLAG" ] && fail "E: ⌃e must not arm in the landed view"
rm -f "$VIEW"
ok "E ⌃e is inert while the dash shows the landed view"

# --- F. STALE ROW -------------------------------------------------------------
out="$(bash "$REN" "t:9999")"
[ -z "$out" ] || fail "F: a row whose window is gone must not arm rename" "$out"
[ -f "$FLAG" ] && fail "F: a stale row must leave no rename_target flag"
ok "F a stale row (window gone) never arms rename"

# --- G. PARENS in the current name --------------------------------------------
tmux rename-window -t "$T" 'web (old)' 2>/dev/null
out="$(bash "$REN" "$T")"
case "$out" in *"change-query(web old)"*) ;; *) fail "G: parens must be stripped from the pre-filled name" "$out" ;; esac
# change-query(...) must be the LAST action and its argument paren-free — fzf
# stops the argument at the first ')', so a stray one would truncate the name.
tail="${out#*change-query\(}"
[ "$tail" = "web old)" ] || fail "G: change-query(...) must end the action list with a paren-free name" "$out"
rm -f "$FLAG"
tmux rename-window -t "$T" one 2>/dev/null
ok "G a parenthesised window name stays parseable in change-query(...)"

# --- H. COMMIT ----------------------------------------------------------------
tmux set-window-option -t "$T" @issue 449 >/dev/null 2>&1
bash "$REN" "$T" >/dev/null
out="$(bash "$ENT" "$T" 'issue-449')"
[ "$(wname "$T")" = 'issue-449' ] || fail "H: Enter must rename the stashed target"
[ -f "$FLAG" ] && fail "H: Enter must drop the rename_target flag"
case "$out" in *hide-input*) ;; *) fail "H: Enter must hide the input again" "$out" ;; esac
case "$out" in *"rebind(?)"*) ;; *) fail "H: Enter must rebind '?' when it hides the input" "$out" ;; esac
case "$out" in *"change-prompt(▸ )"*) ;; *) fail "H: Enter must restore the '▸ ' prompt" "$out" ;; esac
ok "H Enter commits the rename and restores the dash prompt"

# --- K. @issue survives (dash-issue-session.sh matches @issue first) ----------
[ "$(tmux display-message -p -t "$T" '#{@issue}' 2>/dev/null)" = 449 ] \
  || fail "K: the window's @issue binding must survive a ⌃e rename"
ok "K the @issue binding survives the rename"

# --- I. EMPTY QUERY CANCELS ---------------------------------------------------
bash "$REN" "$T" >/dev/null
out="$(bash "$ENT" "$T" '')"
[ "$(wname "$T")" = 'issue-449' ] || fail "I: an empty query must NOT rename the window"
[ -f "$FLAG" ] && fail "I: an empty query must still drop the rename_target flag"
case "$out" in *hide-input*) ;; *) fail "I: an empty query must hide the input again" "$out" ;; esac
case "$out" in *"rebind(?)"*) ;; *) fail "I: an empty query must rebind '?' when it hides the input" "$out" ;; esac
ok "I an empty name cancels the rename"

# --- J. ESC CANCELS -----------------------------------------------------------
bash "$REN" "$T" >/dev/null
out="$(bash "$ESC")"
[ "$(wname "$T")" = 'issue-449' ] || fail "J: Esc must not rename the window"
[ -f "$FLAG" ] && fail "J: Esc must drop the rename_target flag"
case "$out" in *hide-input*) ;; *) fail "J: Esc must hide the input again" "$out" ;; esac
case "$out" in *"rebind(?)"*) ;; *) fail "J: Esc must rebind '?' when it hides the input" "$out" ;; esac
case "$out" in *abort*) fail "J: Esc in rename mode must back out, not abort the dash" "$out" ;; esac
ok "J Esc cancels rename mode without aborting the dash"

# --- M. LEADING '-' -----------------------------------------------------------
bash "$REN" "$T" >/dev/null
bash "$ENT" "$T" '-dashy' >/dev/null
[ "$(wname "$T")" = '-dashy' ] || fail "M: a name starting with '-' must commit (tmux needs a '--')"
[ -f "$FLAG" ] && fail "M: the rename_target flag must be dropped"
ok "M a window name starting with '-' renames instead of tripping tmux flag parsing"

# --- L. SHELLCHECK ------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  sc="$(shellcheck -x "$REN" 2>&1)" || fail "L: dash-rename.sh is not shellcheck-clean" "$sc"
  ok "L dash-rename.sh is shellcheck-clean"
else
  printf 'skip L shellcheck absent\n'
fi

printf 'selftest OK: dash ⌃e rename mode (%s assertions)\n' "$pass"
