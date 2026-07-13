#!/bin/bash
# dash-restore-session-selftest.sh — hermetic tests for bin/dash-restore-session.sh,
# the one-key "restore a landed session into a new window" path (issue #228).
#
# No network, no real repo, no tmux server: the real script + fleet-lib.sh are
# symlinked into a temp bin, fleet-history.sh is STUBBED to emit a controlled
# resume verdict ($VERDICT), and a fake `tmux` logs new-window/set-window-option/
# display-message/select-window so we can assert exactly what gets spawned. (The
# reconstruct/verdict-routing logic itself is covered by fleet-history-selftest.sh.)
#
#   A. target→key parsing (--plan): landed:issue:N→N, landed:P→#P, live/hdr→empty
#   B. RESUME (issue key)   → new-window(-n resume-N, -c <worktree>), @issue N, @restored 1
#   C. RESUME (#PR key)     → new-window(-n resume-N, -c <worktree>), NO @issue, @restored 1
#   D. FROM-PR              → new-window(-n resume-prN, -c FLEET_MAIN), @restored 1, NO @issue
#   E. REVIEW-ONLY          → NO new-window, a display-message
#   F. non-landed target    → NO new-window, a hint message
#   G. cap refusal          → NO new-window, a capacity message
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
RST="$BIN/dash-restore-session.sh"
LIB="$BIN/fleet-lib.sh"
for f in "$RST" "$LIB"; do
  [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/restore-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf" "$WORK/main/.git" "$WORK/wt" "$WORK/tmp/.claude-dash"
NEWWIN_LOG="$WORK/newwin"; OPTS_LOG="$WORK/opts"; DISPLAY_LOG="$WORK/display"; SELECT_LOG="$WORK/select"; RS_LOG="$WORK/runshell"

ln -s "$RST" "$WORK/bin/dash-restore-session.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"

# --- stub fleet-history.sh: emit the verdict the test wants (tab-delimited) ------
cat > "$WORK/bin/fleet-history.sh" <<'HISTFAKE'
#!/bin/bash
# only `resume` is exercised; print $VERDICT verbatim (already tab-delimited).
printf '%b\n' "${VERDICT:-REVIEW-ONLY\tstub}"
HISTFAKE
chmod +x "$WORK/bin/fleet-history.sh"

# --- fake tmux: strip -L/-S <sock>; answer session_name; LOG + EXECUTE run-shell
# (so the backgrounded reconstruct tail, issue #304, actually runs and its
# new-window/setopt/select are observable, mirroring real `run-shell -b`); log the
# mutations. ------------------------------------------------------------------
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  run-shell)
    [ "${1:-}" = "-b" ] && shift
    printf '%s\n' "$1" >> "$RS_LOG"          # prove the reconstruct was backgrounded
    sh -c "$1" ;;                            # mirror real run-shell: actually run it
  display-message)
    case "$*" in
      *-p*) case "$*" in *session_name*) echo "${SESS_NAME:-testsess}";; *) echo "";; esac ;;
      *)    printf '%s\n' "$*" >> "$DISPLAY_LOG" ;;
    esac ;;
  list-windows)      printf '%s\n' "${WINS:-}" ;;               # -F window_name for the cap count
  new-window)        printf 'NEWWIN %s\n' "$*" >> "$NEWWIN_LOG"; echo '@9' ;;
  set-window-option) printf 'SETOPT %s\n' "$*" >> "$OPTS_LOG" ;;
  select-window)     printf 'SELECT %s\n' "$*" >> "$SELECT_LOG" ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/tmux"

# run the restorer with a given target. Per-case env (VERDICT, WINS, caps, focus)
# is passed as a prefix on the call so the child bash inherits it.
run_restore() {
  : > "$NEWWIN_LOG"; : > "$OPTS_LOG"; : > "$DISPLAY_LOG"; : > "$SELECT_LOG"; : > "$RS_LOG"
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" \
  FLEET_GLOBAL_MAX_SESSIONS="${FLEET_GLOBAL_MAX_SESSIONS:-0}" \
  DISPLAY_LOG="$DISPLAY_LOG" NEWWIN_LOG="$NEWWIN_LOG" OPTS_LOG="$OPTS_LOG" SELECT_LOG="$SELECT_LOG" RS_LOG="$RS_LOG" \
    bash "$WORK/bin/dash-restore-session.sh" "$@" >"$WORK/out" 2>"$WORK/err"
}

# ============================ A: --plan parsing =============================
[ "$(bash "$WORK/bin/dash-restore-session.sh" --plan 'landed:issue:9')" = "9" ] \
  || fail "A landed:issue:9 should resolve to key 9"
[ "$(bash "$WORK/bin/dash-restore-session.sh" --plan 'landed:70')" = "#70" ] \
  || fail "A landed:70 should resolve to key #70"
[ -z "$(bash "$WORK/bin/dash-restore-session.sh" --plan 'fleet:2')" ] \
  || fail "A a live-row target must resolve to no key"
[ -z "$(bash "$WORK/bin/dash-restore-session.sh" --plan 'hdr')" ] \
  || fail "A the header target must resolve to no key"
ok "A target→key parsing (landed:issue:N→N, landed:P→#P, live/hdr→none)"

# ============================ B: RESUME (issue key) =========================
VERDICT="RESUME\t$WORK/wt\tsid-abc\tclaude --resume sid-abc --fork-session" \
  FLEET_MAX_SESSIONS=0 FLEET_SPAWN_FOCUS=1 run_restore 'landed:issue:9'
grep -q -- '-n resume-9\b' "$NEWWIN_LOG"    || fail "B window not named resume-9" "$(cat "$NEWWIN_LOG")$(cat "$WORK/err")"
grep -q -- "-c $WORK/wt" "$NEWWIN_LOG"       || fail "B window not opened in the reconstructed worktree" "$(cat "$NEWWIN_LOG")"
grep -q -- '--resume sid-abc' "$NEWWIN_LOG"  || fail "B window should run claude --resume sid-abc" "$(cat "$NEWWIN_LOG")"
grep -q 'SETOPT .*@issue 9' "$OPTS_LOG"      || fail "B resuming by issue should bind @issue 9" "$(cat "$OPTS_LOG")"
grep -q 'SETOPT .*@restored 1' "$OPTS_LOG"   || fail "B a restored window should be marked @restored 1" "$(cat "$OPTS_LOG")"
grep -q 'SELECT .*@9' "$SELECT_LOG"          || fail "B FLEET_SPAWN_FOCUS=1 should jump to the restored window" "$(cat "$SELECT_LOG")"
# The reconstruct+spawn must be BACKGROUNDED (issue #304): dispatched via run-shell
# -b as an --exec-bg re-exec, so ⌃o / Enter-in-landed returns before the worktree add.
grep -q -- '--exec-bg' "$RS_LOG"             || fail "B reconstruct must be dispatched via run-shell -b (--exec-bg)" "$(cat "$RS_LOG")"
ok "B RESUME(issue) → resume-9 window in the worktree, @issue+@restored set, backgrounded"

# ============================ C: RESUME (#PR key) ==========================
VERDICT="RESUME\t$WORK/wt\tsid-xyz\tclaude --resume sid-xyz --fork-session" \
  FLEET_MAX_SESSIONS=0 run_restore 'landed:70'
grep -q -- '-n resume-70\b' "$NEWWIN_LOG"    || fail "C window not named resume-70" "$(cat "$NEWWIN_LOG")"
grep -q 'SETOPT .*@issue' "$OPTS_LOG"        && fail "C resuming by #PR has no issue to bind" "$(cat "$OPTS_LOG")"
grep -q 'SETOPT .*@restored 1' "$OPTS_LOG"   || fail "C a #PR restore should still be marked @restored 1" "$(cat "$OPTS_LOG")"
ok "C RESUME(#PR) → resume-70 window, @restored set, NO @issue"

# ============================ D: FROM-PR ===================================
VERDICT="FROM-PR\t70\tclaude --from-pr 70 --fork-session" \
  FLEET_MAX_SESSIONS=0 run_restore 'landed:70'
grep -q -- '-n resume-pr70\b' "$NEWWIN_LOG"  || fail "D window not named resume-pr70" "$(cat "$NEWWIN_LOG")"
grep -q -- "-c $WORK/main" "$NEWWIN_LOG"      || fail "D from-pr window should run in FLEET_MAIN" "$(cat "$NEWWIN_LOG")"
grep -q -- '--from-pr 70' "$NEWWIN_LOG"       || fail "D window should run claude --from-pr 70" "$(cat "$NEWWIN_LOG")"
grep -q 'SETOPT .*@restored 1' "$OPTS_LOG"    || fail "D a from-pr restore should be marked @restored 1" "$(cat "$OPTS_LOG")"
grep -q 'SETOPT .*@issue' "$OPTS_LOG"         && fail "D from-pr binds no @issue" "$(cat "$OPTS_LOG")"
ok "D FROM-PR → resume-pr70 window in FLEET_MAIN, @restored set"

# ============================ E: REVIEW-ONLY ===============================
VERDICT="REVIEW-ONLY\tno resumable worktree and no PR" \
  FLEET_MAX_SESSIONS=0 run_restore 'landed:issue:9'
[ -s "$NEWWIN_LOG" ] && fail "E REVIEW-ONLY must NOT create a window" "$(cat "$NEWWIN_LOG")"
grep -qi 'nothing resumable' "$DISPLAY_LOG"  || fail "E REVIEW-ONLY should surface a 'nothing resumable' message" "$(cat "$DISPLAY_LOG")"
ok "E REVIEW-ONLY → no window, an explanatory message"

# ============================ F: non-landed target =========================
VERDICT="RESUME\t$WORK/wt\tsid\tclaude --resume sid --fork-session" \
  FLEET_MAX_SESSIONS=0 run_restore 'fleet-claude-fleet:2'
[ -s "$NEWWIN_LOG" ] && fail "F a live-row target must NOT create a window" "$(cat "$NEWWIN_LOG")"
grep -qi 'not a landed session' "$DISPLAY_LOG" || fail "F a non-landed target should hint about the landed view" "$(cat "$DISPLAY_LOG")"
ok "F a live-row target is a no-op with a hint"

# ============================ G: cap refusal ===============================
# per-fleet cap of 1 with one live non-panel worker ⇒ refuse before spawning.
VERDICT="RESUME\t$WORK/wt\tsid\tclaude --resume sid --fork-session" \
  WINS=$'plan\nworker-1' FLEET_MAX_SESSIONS=1 run_restore 'landed:issue:9'
[ -s "$NEWWIN_LOG" ] && fail "G a cap refusal must NOT create a window" "$(cat "$NEWWIN_LOG")"
grep -qi 'capacity' "$DISPLAY_LOG"           || fail "G cap refusal should surface a capacity message" "$(cat "$DISPLAY_LOG")"
ok "G restore honours the session cap (refuses, no window)"

printf '\nselftest OK: %s assertions passed (restore landed session → new window, #228)\n' "$pass"
exit 0
