#!/bin/bash
# dash-issue-async-spawn-selftest.sh — hermetic tests for the NON-BLOCKING backlog
# spawn in bin/dash-issue-session.sh (issue #303).
#
# The backlog Enter used to run the spawn synchronously, so the multi-second
# `git worktree add` full checkout froze the fzf popup on a big monorepo. --async
# keeps the synchronous GATE (cap / dedup / claim-at-spawn — so refusals are
# immediate) but hands the slow tail (worktree add + `new-window`) to the tmux
# server via `run-shell -b`, returning at once. The detached helper is a TAIL-ONLY
# re-invocation of THIS script (FLEET_SPAWN_TAIL carries the session + selects
# tail-only mode; --title carries the resolved name). git/gh/tmux are faked on PATH
# and LOG their calls so we can assert exactly which ops ran where. The real
# dash-issue-session.sh + its sibling fleet-lib.sh run unmodified.
#
#   REFUSE  --async + a CLAIMED issue → refuse IMMEDIATELY, no run-shell, no spawn.
#   CAP     --async + the global session cap reached → refuse, no run-shell, no spawn.
#   DISPATCH --async + FREE issue → returns fast, acks "spawning #N", claims AT SPAWN
#            (synchronous, authoritative), dispatches `run-shell -b` re-invoking the
#            tail (FLEET_SPAWN_TAIL + --title) and does NOT worktree-add / new-window
#            in the foreground.
#   TAIL    the tail-only re-entry materializes: worktree add + new-window NAMED from
#            --title + @issue bound; it neither re-claims (gate skipped) nor re-dispatches.
#   TAILFAIL a backgrounded worktree-add failure emits "spawn failed for #N: …".
#   SYNC    NO --async → today's synchronous behavior (worktree add + new-window
#            inline, no run-shell dispatch) is unchanged.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured logs).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SPAWN="$BIN/dash-issue-session.sh"
[ -x "$SPAWN" ] || { echo "selftest: $SPAWN missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/async-spawn-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2
         [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2
         printf -- '--- gh log ---\n%s\n--- tmux log ---\n%s\n--- git log ---\n%s\n--- run-shell log ---\n%s\n--- display ---\n%s\n' \
           "$(cat "$GH_LOG" 2>/dev/null)" "$(cat "$TMUX_LOG" 2>/dev/null)" \
           "$(cat "$GIT_LOG" 2>/dev/null)" "$(cat "$RUNSHELL_LOG" 2>/dev/null)" \
           "$(cat "$DISPLAY_LOG" 2>/dev/null)" >&2
         exit 1; }

mkdir -p "$WORK/main/.git" "$WORK/fakebin" "$WORK/conf" "$WORK/dash"
GH_LOG="$WORK/gh.log"; TMUX_LOG="$WORK/tmux.log"; GIT_LOG="$WORK/git.log"
DISPLAY_LOG="$WORK/display.log"; RUNSHELL_LOG="$WORK/runshell.log"

# --- fake git: worktree/branch ops LOGGED; `worktree add` FAILS when GIT_WT_FAIL=1 -
cat > "$WORK/fakebin/git" <<GITFAKE
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then shift 2; fi
case "\${1:-}" in
  worktree)
    printf 'git %s\n' "\$*" >> "$GIT_LOG"
    case "\$*" in *"worktree add"*) [ "\${GIT_WT_FAIL:-0}" = 1 ] && exit 1 ;; esac ;;
  branch) printf 'git %s\n' "\$*" >> "$GIT_LOG" ;;
  rev-parse) case "\$*" in *--show-toplevel*) pwd -P ;; *) printf 'deadbeef\n' ;; esac ;;
  *) : ;;   # fetch / remote → succeed silently
esac
exit 0
GITFAKE

# --- fake gh: LOG every call; answer the claim-ledger reads from env ----------------
cat > "$WORK/fakebin/gh" <<GHFAKE
#!/bin/bash
printf 'gh %s\n' "\$*" >> "$GH_LOG"
case "\$*" in
  *"issue view"*"--json assignees,state"*) printf '%s\n' "\${CLAIM_STATE:-0	OPEN}" ;;
  *"issue view"*"--json title"*)           printf '%s\n' "\${GH_TITLE:-Some Issue}" ;;
  *"pr list"*)                             printf '%s\n' "\${PR_COUNT:-0}" ;;
  *"issue edit"*)                          : ;;
  *"api user"*)                            printf 'me\n' ;;
  *) : ;;
esac
exit 0
GHFAKE

# --- fake tmux: -p queries answered; new-window / set-window-option / run-shell /
#     display / has-session / list-windows LOGGED or synthesized. CAP_FULL=1 makes
#     the estate scan report one live fleet at capacity (a 'dash' hub + a worker).
cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; then shift 2; fi
case "\${1:-}" in
  display-message)
    case "\$*" in
      *-p*) case "\$*" in
              *window_id*)    echo "\${TMUX_WIN:-@9}" ;;
              *session_name*) echo 'testsess' ;;
              *) echo '' ;;
            esac ;;
      *) shift; printf '%s\n' "\$*" >> "$DISPLAY_LOG" ;;
    esac ;;
  has-session)  exit 0 ;;                                   # any configured fleet is "live"
  list-windows)
    case "\$*" in
      *-a*) [ "\${CAP_FULL:-0}" = 1 ] && printf '%s\n' 'testsess dash' 'testsess issue-99' ;;
      *) : ;;                                               # local dedup: no existing window
    esac ;;
  show-options)      echo '' ;;
  new-window)        printf 'new-window %s\n' "\$*" >> "$TMUX_LOG"; echo "\${TMUX_WIN:-@9}" ;;
  set-window-option) printf 'set-window-option %s\n' "\$*" >> "$TMUX_LOG" ;;
  run-shell)         printf 'run-shell %s\n' "\$*" >> "$RUNSHELL_LOG" ;;
  kill-window)       printf 'kill-window %s\n' "\$*" >> "$TMUX_LOG" ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/git" "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

# Run the real spawn in a clean per-fleet dir; scenario knobs come in via env.
run_spawn() { # $@ = args to dash-issue-session.sh
  : > "$GH_LOG"; : > "$TMUX_LOG"; : > "$GIT_LOG"; : > "$DISPLAY_LOG"; : > "$RUNSHELL_LOG"
  rm -rf "$WORK/dash/.claude-dash"
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
    "$SPAWN" "$@" >"$WORK/spawn.out" 2>"$WORK/spawn.err"
  echo $? > "$WORK/spawn.rc"
}
rc()          { cat "$WORK/spawn.rc"; }
gh_has()      { grep -qF -- "$1" "$GH_LOG"; }
tmux_has()    { grep -qF -- "$1" "$TMUX_LOG"; }
git_has()     { grep -qF -- "$1" "$GIT_LOG"; }
runshell_has(){ grep -qF -- "$1" "$RUNSHELL_LOG"; }
display_has() { grep -qiF -- "$1" "$DISPLAY_LOG"; }

# The pre-spawn dedup default is ON: make sure a stray value can't mask that.
unset FLEET_PRESPAWN_DEDUP FLEET_SPAWN_TAIL FLEET_SPAWN_FOCUS

# ===== REFUSE: --async + a CLAIMED issue ⇒ refuse in the foreground, no dispatch ====
CLAIM_STATE=$'1\tOPEN' run_spawn 303 --async
[ "$(rc)" != 0 ]                        || fail "REFUSE a claimed issue must refuse (non-zero) even with --async"
runshell_has 'run-shell'                && fail "REFUSE must NOT dispatch the background tail for a claimed issue"
git_has 'worktree add'                  && fail "REFUSE must NOT create a worktree for a claimed issue"
tmux_has 'new-window'                   && fail "REFUSE must NOT spawn a window for a claimed issue"
display_has 'already claimed elsewhere' || fail "REFUSE should announce 'already claimed elsewhere'"
ok "REFUSE --async + claimed → immediate refuse, no run-shell / worktree / window"

# ===== CAP: --async + the global session cap reached ⇒ refuse before dispatch =======
# Configure one live fleet (legacy flat conf) so fleet_sockets yields it, and make
# the estate scan report it AT capacity (hub + one worker) against a cap of 1.
: > "$WORK/conf/testsess.conf"
CLAIM_STATE=$'0\tOPEN' CAP_FULL=1 FLEET_GLOBAL_MAX_SESSIONS=1 run_spawn 303 --async
[ "$(rc)" != 0 ]                        || fail "CAP at-capacity must refuse (non-zero) even with --async" "$(cat "$WORK/spawn.err")"
runshell_has 'run-shell'                && fail "CAP must NOT dispatch the background tail when at capacity"
git_has 'worktree add'                  && fail "CAP must NOT create a worktree when at capacity"
tmux_has 'new-window'                   && fail "CAP must NOT spawn a window when at capacity"
display_has 'at capacity'               || fail "CAP should announce the capacity refusal"
rm -f "$WORK/conf/testsess.conf"
ok "CAP --async + cap reached → immediate refuse, no run-shell / worktree / window"

# ===== DISPATCH: --async + FREE issue ⇒ fast return, claim SYNC, tail backgrounded ==
CLAIM_STATE=$'0\tOPEN' PR_COUNT=0 FLEET_PRESPAWN_DEDUP=1 run_spawn 303 --async
[ "$(rc)" = 0 ]                         || fail "DISPATCH a free issue should return 0 fast under --async" "$(cat "$WORK/spawn.err")"
gh_has '--add-assignee'                 || fail "DISPATCH must still claim AT SPAWN synchronously (the anti-collision rail stays sync)"
display_has 'spawning #303'             || fail "DISPATCH should ack 'spawning #303…' synchronously"
runshell_has 'run-shell'                || fail "DISPATCH must hand the slow tail to run-shell -b"
runshell_has '-b'                       || fail "DISPATCH must background the tail (run-shell -b)"
runshell_has 'FLEET_SPAWN_TAIL='        || fail "DISPATCH's backgrounded command must carry FLEET_SPAWN_TAIL (tail-only re-entry)"
runshell_has 'dash-issue-session.sh'    || fail "DISPATCH's backgrounded command must re-invoke THIS script"
runshell_has '--title'                  || fail "DISPATCH must pass --title so the window is still named from content"
git_has 'worktree add'                  && fail "DISPATCH must NOT run the worktree add in the FOREGROUND (that is the frozen tail)"
tmux_has 'new-window'                   && fail "DISPATCH must NOT run new-window in the FOREGROUND"
ok "DISPATCH --async + free → fast rc0, claim sync, run-shell -b re-invokes the tail (FLEET_SPAWN_TAIL + --title), no foreground checkout"

# ===== TAIL: the tail-only re-entry materializes the worktree + named window ========
# FLEET_SPAWN_TAIL both selects tail-only mode and names the fleet; --title flows to
# the window name. The gate (cap/dedup/claim) is SKIPPED — this ran in the foreground.
FLEET_SPAWN_TAIL=testsess run_spawn 303 --title 'Async Spawn Rocks'
[ "$(rc)" = 0 ]                         || fail "TAIL the re-entry should materialize + exit 0" "$(cat "$WORK/spawn.err")"
git_has 'worktree add'                  || fail "TAIL must run the (backgrounded) git worktree add"
tmux_has 'new-window'                   || fail "TAIL must create the window"
tmux_has 'async-spawn-rocks'            || fail "TAIL must name the window from --title (kebab of 'Async Spawn Rocks')"
tmux_has '@issue 303'                   || fail "TAIL must bind the window to the issue (@issue 303)"
gh_has '--add-assignee'                 && fail "TAIL must NOT re-claim — the gate already claimed in the foreground"
runshell_has 'run-shell'                && fail "TAIL must NOT re-dispatch (no nested run-shell)"
ok "TAIL re-entry → worktree add + new-window named from --title + @issue bound, no re-claim / re-dispatch"

# ===== TAILFAIL: a backgrounded worktree-add failure reports the failure ============
FLEET_SPAWN_TAIL=testsess GIT_WT_FAIL=1 run_spawn 303 --title 'Boom'
[ "$(rc)" != 0 ]                        || fail "TAILFAIL a failed worktree add must exit non-zero"
display_has 'spawn failed for #303: worktree add' || fail "TAILFAIL must report 'spawn failed for #303: worktree add'"
tmux_has 'new-window'                   && fail "TAILFAIL must NOT spawn a window after the worktree add failed"
ok "TAILFAIL backgrounded worktree-add failure → 'spawn failed for #303: worktree add', no window"

# ===== SYNC: NO --async ⇒ today's synchronous behavior is unchanged =================
CLAIM_STATE=$'0\tOPEN' PR_COUNT=0 FLEET_PRESPAWN_DEDUP=1 run_spawn 303
[ "$(rc)" = 0 ]                         || fail "SYNC a free issue should spawn synchronously (exit 0)" "$(cat "$WORK/spawn.err")"
git_has 'worktree add'                  || fail "SYNC must run the worktree add inline"
tmux_has 'new-window'                   || fail "SYNC must spawn the window inline"
tmux_has '@issue 303'                   || fail "SYNC must bind @issue inline"
runshell_has 'run-shell'                && fail "SYNC must NOT dispatch run-shell (no --async)"
ok "SYNC no --async → worktree add + new-window inline (unchanged), no run-shell"

printf '\nselftest OK: %s assertions passed (non-blocking backlog spawn, issue #303)\n' "$pass"
exit 0
