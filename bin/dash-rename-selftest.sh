#!/bin/bash
# dash-rename-selftest.sh — the dash ⌃e RENAME MODE contract (issue #449).
#
# ⌃e arms rename mode (bin/dash-rename.sh), Enter commits it and Esc cancels it
# (the long-standing rename branches in dash-enter.sh / dash-esc.sh, orphaned
# between #289 and #449). This drives all three scripts for real against an
# ISOLATED tmux server on its own socket — never the user's live server — via the
# `-S <sock>` PATH shim the sibling dash selftests use (dash-marker-selftest.sh):
#
#   A. ARM          a live row → stashes the target, emits
#                   change-prompt(rename ▸ ) + change-query(<current name>)
#   A2. UNBIND ?    a PRINTABLE key that --bind claimed fires instead of typing:
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
#                   flag, and restores the '▸ ' prompt
#   I. EMPTY CANCEL an empty query cancels — the window keeps its name
#   J. ESC CANCEL   Esc drops the flag and backs out WITHOUT aborting the dash
#   K. @issue KEEPS the window's @issue binding survives the rename (what
#                   dash-issue-session.sh's "survives a ctrl-e rename" match relies on)
#   N. LANDED UNDO  Enter in the LANDED view drops a rename armed back in live view —
#                   and must REBIND `?` while it does. Dropping the flag alone left the
#                   dash's cheatsheet key unbound for the rest of that fzf's life, so
#                   `?` silently opened nothing (issue #454).
#   M. LEADING '-'  a name starting with '-' commits (dash-enter.sh passes `--`,
#                   or tmux parses the name as a flag and the rename silently fails)
#   L. SHELLCHECK   dash-rename.sh is shellcheck-clean (skipped if absent)
#
# The query line is ALWAYS visible — it doubles as the quick-scratch box (type a
# task, ↵ → a scratch session seeded with it). Rename borrows it; the two must
# not bleed into each other:
#   P. TYPED TASK   Enter with a non-empty query and NO mode armed spawns a seeded
#                   scratch (dash-raw-session.sh --bg --prompt <q>), clears the
#                   query, never jumps/renames
#   P2. BLANK TASK  a whitespace-only query is a plain jump (no spawn)
#   Q. ESC CLEARS   Esc with a half-typed task clears it (no abort); an empty line
#                   still aborts (relaunch)
#   R. MODE WINS    a typed query while rename is armed is the NAME — no scratch
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
for f in dash-rename.sh dash-enter.sh dash-esc.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s missing\n' "$BIN/$f" >&2; exit 2; }
done
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dr-selftest.XXXXXX")" || exit 2

# The scripts resolve their siblings off their own dirname, so run them from a
# stub dir: the three under test are symlinked in, and dash-raw-session.sh (what a
# typed task spawns through) is a FAKE that logs its argv — no worktree, no claude.
mkdir -p "$WORK/sbin"
for f in dash-rename.sh dash-enter.sh dash-esc.sh; do ln -s "$BIN/$f" "$WORK/sbin/$f"; done
# dash-enter.sh sources fleet-lib.sh (fleet_bg / fleet_now_ms / fleet_spawn_is_burst,
# the paste-storm guard, #531) — provide it in the stub dir so the source resolves.
ln -s "$BIN/fleet-lib.sh" "$WORK/sbin/fleet-lib.sh"
RAW_LOG="$WORK/raw.log"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$RAW_LOG" > "$WORK/sbin/dash-raw-session.sh"
chmod +x "$WORK/sbin/dash-raw-session.sh"
REN="$WORK/sbin/dash-rename.sh"; ENT="$WORK/sbin/dash-enter.sh"; ESC="$WORK/sbin/dash-esc.sh"

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
case "$out" in *"rebind(?)"*) ;; *) fail "H: Enter must rebind '?' when it restores the prompt" "$out" ;; esac
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
case "$out" in *"change-prompt(▸ )"*) ;; *) fail "I: an empty query must restore the '▸ ' prompt" "$out" ;; esac
case "$out" in *"rebind(?)"*) ;; *) fail "I: an empty query must rebind '?' when it restores the prompt" "$out" ;; esac
ok "I an empty name cancels the rename"

# --- J. ESC CANCELS -----------------------------------------------------------
bash "$REN" "$T" >/dev/null
out="$(bash "$ESC")"
[ "$(wname "$T")" = 'issue-449' ] || fail "J: Esc must not rename the window"
[ -f "$FLAG" ] && fail "J: Esc must drop the rename_target flag"
case "$out" in *"change-prompt(▸ )"*) ;; *) fail "J: Esc must restore the '▸ ' prompt" "$out" ;; esac
case "$out" in *"rebind(?)"*) ;; *) fail "J: Esc must rebind '?' when it restores the prompt" "$out" ;; esac
case "$out" in *abort*) fail "J: Esc in rename mode must back out, not abort the dash" "$out" ;; esac
ok "J Esc cancels rename mode without aborting the dash"

# --- N. LANDED-VIEW ENTER UNDOES THE ARM, `?` INCLUDED (issue #454) -----------
# ⌃e arms in LIVE view, ⌃t flips to LANDED, then Enter. dash-enter.sh drops the flag
# there (a mode from live view is inert on landed rows) — but the arm also emitted
# unbind(?) + the rename prompt, so an Enter that drops the flag WITHOUT rebinding
# leaves `?` dead until the dash relaunches. Both landed exits are covered: a `landed:` row and a
# stray live row falling through to the jump branch.
for lrow in "landed:99" "$T"; do
  printf '' > "$VIEW"          # arm in LIVE view, exactly as the operator does
  bash "$REN" "$T" >/dev/null
  [ -f "$FLAG" ] || fail "N: precondition — ⌃e should have armed in the live view"
  printf 'landed
' > "$VIEW"  # ⌃t
  out="$(bash "$ENT" "$lrow" '')"
  [ -f "$FLAG" ] && fail "N: landed-view Enter must drop the rename flag ($lrow)"
  case "$out" in *"rebind(?)"*) ;; *)
    fail "N: landed-view Enter dropped the arm without rebinding '?' — the cheatsheet key stays dead (issue #454, row $lrow)" "$out" ;;
  esac
  case "$out" in *"change-prompt(▸ )"*) ;; *)
    fail "N: landed-view Enter must restore the '▸ ' prompt it left relabelled ($lrow)" "$out" ;;
  esac
done
# …and a landed Enter with NO mode armed must stay exactly as it was — no stray
# prompt/rebind noise on the overwhelmingly common path.
printf 'landed
' > "$VIEW"
out="$(bash "$ENT" 'landed:99' '')"
case "$out" in *rebind*|*change-prompt*)
  fail "N: a landed Enter with nothing armed must not emit mode-undo actions" "$out" ;;
esac
printf '' > "$VIEW"
ok "N landed-view Enter undoes an armed rename, '?' rebound, and is inert otherwise"

# --- M. LEADING '-' -----------------------------------------------------------
bash "$REN" "$T" >/dev/null
bash "$ENT" "$T" '-dashy' >/dev/null
[ "$(wname "$T")" = '-dashy' ] || fail "M: a name starting with '-' must commit (tmux needs a '--')"
[ -f "$FLAG" ] && fail "M: the rename_target flag must be dropped"
ok "M a window name starting with '-' renames instead of tripping tmux flag parsing"

# --- P. TYPED TASK → seeded scratch (DEFERRED past the paste guard, #531) ------
# The typed-task spawn is now DEBOUNCED (issue #531): a lone Enter defers, then
# spawns via `dash-raw-session.sh --prompt-file <f>` (the query in a file, never on
# the argv). Drive it with a tiny guard so the deferred spawn lands fast, and give
# the backgrounded decider a moment before reading the log.
rm -f "$FLAG" "$RAW_LOG" "$C"/global/spawn_last_ms_*
out="$(FLEET_SPAWN_GUARD_MS=50 FLEET_SPAWN_GUARD_SLEEP=0.1 bash "$ENT" "$T" 'fix the flaky dash selftest')"
case "$out" in *clear-query*) ;; *) fail "P: a typed task must clear the query" "$out" ;; esac
case "$out" in *reload*) ;; *) fail "P: a typed task must reload the rows" "$out" ;; esac
# wait for the deferred spawn (guard 0.1s + slack)
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$RAW_LOG" ] && break; sleep 0.1; done
[ -s "$RAW_LOG" ] || fail "P: a typed task must (after the defer) spawn through dash-raw-session.sh" "$out"
argv="$(cat "$RAW_LOG")"
case "$argv" in *--prompt-file=*) ;; *) fail "P: the deferred spawn must hand the query over via --prompt-file" "$argv" ;; esac
pf="${argv#*--prompt-file=}"; pf="${pf%% *}"
[ "$(cat "$pf" 2>/dev/null)" = 'fix the flaky dash selftest' ] || fail "P: the prompt-file must hold the typed task verbatim" "$argv"
[ "$(wname "$T")" = '-dashy' ] || fail "P: a typed task must not rename the highlighted window"
ok "P Enter with a typed task defers, then spawns a seeded scratch (--prompt-file), clears the line"

# --- P2. BLANK TASK is a plain jump -------------------------------------------
rm -f "$RAW_LOG"
out="$(bash "$ENT" "$T" '   ')"
[ -f "$RAW_LOG" ] && fail "P2: a whitespace-only query must not spawn a scratch" "$(cat "$RAW_LOG")"
case "$out" in *clear-query*) ;; *) fail "P2: a blank query is the plain jump (clear-query)" "$out" ;; esac
ok "P2 a blank query is a plain jump, no spawn"

# --- Q. ESC with a typed task clears it; on an empty line it aborts -----------
out="$(bash "$ESC" 'half a thought')"
[ "$out" = clear-query ] || fail "Q: Esc over a half-typed task must just clear it" "$out"
out="$(bash "$ESC" '')"
[ "$out" = abort ] || fail "Q: Esc on an empty line must still abort (relaunch)" "$out"
ok "Q Esc clears a typed task, aborts only on an empty line"

# --- R. RENAME ARMED → the typed query is the name, not a task ----------------
rm -f "$RAW_LOG"
bash "$REN" "$T" >/dev/null
[ -f "$FLAG" ] || fail "R: precondition — ⌃e should have armed"
out="$(bash "$ENT" "$T" 'renamed-not-seeded')"
[ -f "$RAW_LOG" ] && fail "R: a typed query while rename is armed must NOT spawn a scratch" "$(cat "$RAW_LOG")"
[ "$(wname "$T")" = 'renamed-not-seeded' ] || fail "R: the armed rename must win over the typed-task path"
ok "R an armed rename owns the query line — no scratch spawn"

# --- L. SHELLCHECK ------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  sc="$(shellcheck -x "$BIN/dash-rename.sh" "$BIN/dash-enter.sh" "$BIN/dash-esc.sh" 2>&1)" || fail "L: rename/enter/esc not shellcheck-clean" "$sc"
  ok "L dash-rename.sh / dash-enter.sh / dash-esc.sh are shellcheck-clean"
else
  printf 'skip L shellcheck absent\n'
fi

printf 'selftest OK: dash ⌃e rename mode (%s assertions)\n' "$pass"
