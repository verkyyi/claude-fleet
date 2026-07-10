#!/bin/bash
# fleet-scout-selftest.sh — hermetic tests for the read-only scout shape (issue
# #148): the --scout spawn path (bin/dash-issue-session.sh) and the scout's
# self-destruct teardown (bin/fleet-scout-clean.sh). No network, no real repo, no
# tmux server — git/gh/tmux are faked on PATH.
#
# Part 1 — SPAWN (--scout): the seeded task prompt is a read-only investigation
#   (investigate + REPORT, no branch/PR/ship), the window is marked @scout, and a
#   NON-scout spawn keeps the normal ship prompt. --scout supersedes --self-land.
#   A convert-to-ship spawn while a scout still holds the issue is short-circuited
#   with an HONEST "a live scout holds it" message (not a bare "already spawned").
# Part 2 — TEARDOWN (fleet-scout-clean.sh): ordered self-destruct (kill window →
#   worktree remove → branch -d), --close closes the issue first, and it refuses
#   to (a) tear down the base checkout, (b) act on a non-@scout window, (c) --close
#   with no repo resolved, (d) run with no window-id.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SPAWN="$BIN/dash-issue-session.sh"
CLEAN="$BIN/fleet-scout-clean.sh"
[ -x "$SPAWN" ] || { echo "selftest: $SPAWN missing/not executable" >&2; exit 2; }
[ -x "$CLEAN" ] || { echo "selftest: $CLEAN missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scout-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/main/.git" "$WORK/fakebin" "$WORK/conf" "$WORK/dash"
SETOPT_LOG="$WORK/setopts"; NEWWIN_LOG="$WORK/newwins"; KILL_LOG="$WORK/kills"
CLOSE_LOG="$WORK/closes"; RUNSHELL_LOG="$WORK/runshell"; DISPLAY_LOG="$WORK/display"

# --- fake git: worktree/fetch/branch succeed; report branch + toplevel ---------
cat > "$WORK/fakebin/git" <<GITFAKE
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then shift 2; fi
case "\${1:-}" in
  rev-parse)
    case "\$*" in
      *--abbrev-ref*)   printf '%s\n' "\${GIT_BRANCH:-issue-77}" ;;
      *--show-toplevel*) pwd -P ;;
      *) printf 'deadbeef\n' ;;
    esac ;;
  *) : ;;   # fetch / worktree / branch → succeed silently
esac
exit 0
GITFAKE

# --- fake gh: issue title for the spawn; log issue close ----------------------
cat > "$WORK/fakebin/gh" <<GHFAKE
#!/bin/bash
case "\${1:-} \${2:-}" in
  "issue view")  printf 'Scout: probe the widget\n' ;;
  "issue close") printf '%s\n' "\${3:-}" >> "$CLOSE_LOG" ;;
  *) : ;;
esac
exit 0
GHFAKE

# --- fake tmux: query via -p; status text logged; new-window/kill/run-shell log -
# list-windows emits \$TMUX_LW (default none → no dedup); show-options answers the
# existing window's @scout via \$TMUX_SCOUT_OPT.
cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
case "\${1:-}" in
  display-message)
    case "\$*" in
      *-p*)
        case "\$*" in
          *window_id*)    echo "\${TMUX_WIN-@9}" ;;
          *@issue*)       echo "\${TMUX_ISSUE:-77}" ;;
          *@scout*)       echo "\${TMUX_SCOUT:-1}" ;;
          *session_name*) echo 'testsess' ;;
          *) echo '' ;;
        esac ;;
      *) shift; printf '%s\n' "\$*" >> "$DISPLAY_LOG" ;;   # status message text
    esac ;;
  list-windows)      [ -n "\${TMUX_LW:-}" ] && printf '%s\n' "\${TMUX_LW}" || : ;;
  show-options)      case "\$*" in *@scout*) echo "\${TMUX_SCOUT_OPT:-}" ;; *) echo '' ;; esac ;;
  new-window)        printf '%s\n' "\$*" >> "$NEWWIN_LOG"; echo "\${TMUX_WIN:-@9}" ;;
  set-window-option) printf '%s\n' "\$*" >> "$SETOPT_LOG" ;;
  select-window)     : ;;
  kill-window)       printf '%s\n' "\$*" >> "$KILL_LOG" ;;
  run-shell)         shift; [ "\${1:-}" = "-b" ] && shift; printf '%s\n' "\$*" >> "$RUNSHELL_LOG" ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/git" "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

run_spawn() { # $@ = args to dash-issue-session.sh (env: TMUX_LW / TMUX_SCOUT_OPT)
  : > "$SETOPT_LOG"; : > "$NEWWIN_LOG"; : > "$DISPLAY_LOG"
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_C="$WORK/dash" FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" \
  FLEET_BASE_BRANCH="master" \
    "$SPAWN" "$@" >"$WORK/spawn.out" 2>"$WORK/spawn.err"
}

# ============================ Part 1: --scout spawn ===========================
# 1a. --scout seeds a READ-ONLY investigation prompt (no branch/PR/ship).
run_spawn 77 --scout
TF="$WORK/dash/.claude-dash/task_issue-77.txt"
[ -f "$TF" ] || fail "1a scout task file not written ($TF)" "$(cat "$WORK/spawn.err")"
task="$(cat "$TF")"
case "$task" in *"READ-ONLY scout"*) ;; *) fail "1a scout prompt missing 'READ-ONLY scout'" "$task" ;; esac
case "$task" in *"do NOT implement"*) ;; *) fail "1a scout prompt missing 'do NOT implement'" "$task" ;; esac
case "$task" in *"open NO PR"*|*"Never open a PR"*) ;; *) fail "1a scout prompt should forbid a PR" "$task" ;; esac
case "$task" in *"/fleet-scout-report"*) ;; *) fail "1a scout prompt missing /fleet-scout-report closing move" "$task" ;; esac
case "$task" in *"/fleet-ship"*) fail "1a scout prompt must NOT tell it to /fleet-ship" "$task" ;; *) ;; esac
# the shared claim ritual is present (the dedup refactor kept it)
case "$task" in *"/fleet-claim"*) ;; *) fail "1a scout prompt lost the /fleet-claim ritual" "$task" ;; esac
ok "1a --scout seeds a read-only investigate+report prompt (with the claim ritual)"

# 1b. the scout window is marked @scout.
grep -q '@scout 1' "$SETOPT_LOG" || fail "1b scout window not marked @scout" "$(cat "$SETOPT_LOG")"
grep -q '@issue 77' "$SETOPT_LOG" || fail "1b scout window not bound @issue" "$(cat "$SETOPT_LOG")"
ok "1b --scout marks the window @scout (and binds @issue)"

# 1c. a NORMAL spawn (no --scout) keeps the ship prompt and no @scout marker.
run_spawn 77
task="$(cat "$WORK/dash/.claude-dash/task_issue-77.txt")"
case "$task" in *"/fleet-ship"*) ;; *) fail "1c normal spawn should seed /fleet-ship" "$task" ;; esac
case "$task" in *"READ-ONLY scout"*) fail "1c normal spawn must NOT be a scout prompt" "$task" ;; *) ;; esac
case "$task" in *"/fleet-claim"*) ;; *) fail "1c normal spawn lost the /fleet-claim ritual" "$task" ;; esac
grep -q '@scout' "$SETOPT_LOG" && fail "1c normal spawn must NOT set @scout" "$(cat "$SETOPT_LOG")"
ok "1c normal spawn keeps the ship prompt, no @scout (shared claim ritual intact)"

# 1d. --scout supersedes --self-land (a scout has no PR to land).
run_spawn 77 --scout --self-land
task="$(cat "$WORK/dash/.claude-dash/task_issue-77.txt")"
case "$task" in *"READ-ONLY scout"*) ;; *) fail "1d --scout must win over --self-land" "$task" ;; esac
case "$task" in *"/fleet-land-self"*) fail "1d scout prompt must not carry the self-land tail" "$task" ;; *) ;; esac
ok "1d --scout supersedes --self-land"

# 1e. convert-to-ship: a worker spawn while a live SCOUT holds #77 short-circuits
# (shared worktree) with an HONEST message — not a bare "already spawned".
TMUX_LW="77 @3" TMUX_SCOUT_OPT=1 run_spawn 77
[ -s "$NEWWIN_LOG" ] && fail "1e must not create a second window while a scout holds #77" "$(cat "$NEWWIN_LOG")"
grep -qi 'scout' "$DISPLAY_LOG" || fail "1e dedup message should name the live scout" "$(cat "$DISPLAY_LOG")"
grep -qi 'already spawned' "$DISPLAY_LOG" && fail "1e must NOT show a bare 'already spawned' for a scout" "$(cat "$DISPLAY_LOG")"
ok "1e worker-vs-live-scout dedup gives an honest message"

# 1f. a NON-scout existing window keeps the plain 'already spawned' message.
TMUX_LW="77 @3" TMUX_SCOUT_OPT="" run_spawn 77
grep -qi 'already spawned' "$DISPLAY_LOG" || fail "1f a non-scout dup should say 'already spawned'" "$(cat "$DISPLAY_LOG")"
ok "1f non-scout dup keeps the plain already-spawned message"

# ======================= Part 2: fleet-scout-clean teardown ===================
run_clean() { # $1=cwd ; rest=args ; CLEAN_ENV[] overrides (TMUX_WIN/TMUX_SCOUT/…)
  local cwd="$1"; shift
  # `env` (not bash assignments) so an EXPANDED "${CLEAN_ENV[@]}" is parsed as
  # NAME=VALUE rather than run as a command word.
  ( cd "$cwd" && env PATH="$WORK/fakebin:$PATH" FLEET_CONF_DIR="$WORK/conf" \
      FLEET_REPO="${CLEAN_REPO-acme/widgets}" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
      TMUX_ISSUE=77 GIT_BRANCH=issue-77 "${CLEAN_ENV[@]}" \
      "$CLEAN" "$@" ) >"$WORK/clean.out" 2>"$WORK/clean.err"
}
WT="$WORK/main-issue-77"; mkdir -p "$WT"
CLEAN_ENV=(TMUX_SCOUT=1)

# 2a. dry-run prints an ORDERED teardown: kill-window → worktree remove → branch -d.
run_clean "$WT" --dry-run
tok="$(cat "$WORK/clean.out")"
case "$tok" in dry:*) ;; *) fail "2a expected a dry:<cmd> token, got '$tok'" "$(cat "$WORK/clean.err")" ;; esac
printf '%s\n' "$tok" | grep -Eq 'kill-window .*worktree remove --force .*branch -d ' \
  || fail "2a teardown ordering wrong (kill-window → worktree remove → branch -d)" "$tok"
case "$tok" in *"issue-77"*) ;; *) fail "2a teardown should target issue-77 worktree/branch" "$tok" ;; esac
ok "2a teardown is ordered + uses safe branch -d (kill-window → worktree remove → branch -d)"

# 2b. --close closes the issue before teardown; plain run does not.
: > "$CLOSE_LOG"; run_clean "$WT" --close --dry-run
[ -s "$CLOSE_LOG" ] && fail "2b --close under --dry-run must not close the issue" "$(cat "$CLOSE_LOG")"
: > "$RUNSHELL_LOG"; : > "$CLOSE_LOG"; run_clean "$WT" --close
grep -qx 77 "$CLOSE_LOG" || fail "2b --close (live) should close issue #77" "$(cat "$WORK/clean.err")"
grep -Eq 'kill-window .*worktree remove --force' "$RUNSHELL_LOG" \
  || fail "2b live teardown did not run the detached self-destruct" "$(cat "$RUNSHELL_LOG")"
ok "2b --close closes the issue, then runs the detached teardown"

: > "$CLOSE_LOG"; : > "$RUNSHELL_LOG"; run_clean "$WT"
[ -s "$CLOSE_LOG" ] && fail "2b(2) a plain run must NOT close the issue" "$(cat "$CLOSE_LOG")"
grep -Eq 'kill-window' "$RUNSHELL_LOG" || fail "2b(2) plain run should still tear down" "$(cat "$RUNSHELL_LOG")"
ok "2b(2) plain run tears down but leaves the issue open"

# 2c. refuse to tear down the base checkout itself.
: > "$RUNSHELL_LOG"
run_clean "$WORK/main"; rc=$?
[ "$rc" -ne 0 ] || fail "2c must refuse when run from the base checkout" "$(cat "$WORK/clean.err")"
grep -qi 'base checkout' "$WORK/clean.err" || fail "2c refusal should name the base checkout" "$(cat "$WORK/clean.err")"
[ -s "$RUNSHELL_LOG" ] && fail "2c must NOT tear down when refusing" "$(cat "$RUNSHELL_LOG")"
ok "2c refuses to tear down the base checkout"

# 2d. refuse on a NON-@scout window (a normal worker may have unpushed work).
: > "$RUNSHELL_LOG"; CLEAN_ENV=(TMUX_SCOUT=0)
run_clean "$WT"; rc=$?
[ "$rc" -ne 0 ] || fail "2d must refuse on a non-@scout window" "$(cat "$WORK/clean.err")"
grep -qi 'not marked @scout' "$WORK/clean.err" || fail "2d refusal should cite the @scout marker" "$(cat "$WORK/clean.err")"
[ -s "$RUNSHELL_LOG" ] && fail "2d must NOT tear down a non-scout window" "$(cat "$RUNSHELL_LOG")"
ok "2d refuses on a non-@scout window (no unpushed-work loss)"

# 2d(2). --force overrides the @scout guard.
: > "$RUNSHELL_LOG"; CLEAN_ENV=(TMUX_SCOUT=0)
run_clean "$WT" --force; rc=$?
grep -Eq 'kill-window' "$RUNSHELL_LOG" || fail "2d(2) --force should tear down despite no @scout" "$(cat "$WORK/clean.err")"
ok "2d(2) --force overrides the @scout guard"

# 2e. --close with NO repo resolved refuses (rather than orphan the issue open).
: > "$RUNSHELL_LOG"; CLEAN_ENV=(TMUX_SCOUT=1)
CLEAN_REPO="" run_clean "$WT" --close; rc=$?
[ "$rc" -ne 0 ] || fail "2e --close with no repo must refuse" "$(cat "$WORK/clean.err")"
[ -s "$RUNSHELL_LOG" ] && fail "2e must NOT tear down when --close can't reach the repo" "$(cat "$RUNSHELL_LOG")"
ok "2e --close with no repo refuses (issue not orphaned)"

# 2f. no window-id resolvable → refuse (don't run an unkillable-window teardown).
: > "$RUNSHELL_LOG"; CLEAN_ENV=(TMUX_SCOUT=1 TMUX_WIN=)
run_clean "$WT"; rc=$?
[ "$rc" -ne 0 ] || fail "2f must refuse with no window-id" "$(cat "$WORK/clean.err")"
[ -s "$RUNSHELL_LOG" ] && fail "2f must NOT tear down with no window-id" "$(cat "$RUNSHELL_LOG")"
ok "2f no window-id → refuse (no broken-ordering teardown)"

printf '\nselftest OK: %s assertions passed (scout spawn + teardown)\n' "$pass"
exit 0
