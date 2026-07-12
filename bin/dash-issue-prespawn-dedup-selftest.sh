#!/bin/bash
# dash-issue-prespawn-dedup-selftest.sh — hermetic tests for the cross-machine
# pre-spawn GitHub-claim dedup in bin/dash-issue-session.sh (issue #258).
#
# The local tmux dedup only sees ONE machine's server, so two fleets on different
# machines / same repo can both spawn issue-<N>. FLEET_PRESPAWN_DEDUP=1 makes the
# spawn consult the shared GitHub issue as a claim ledger, claim AT SPAWN, and
# tie-break a simultaneous race. No network, no real repo, no tmux server — git/gh/
# tmux are faked on PATH (same shape as dash-issue-session-prompt-selftest.sh) and
# LOG their calls so we can assert which ops ran. The real dash-issue-session.sh +
# its sibling fleet-comment.sh/fleet-lib.sh run unmodified.
#
#   DEF  flag UNSET ⇒ dedup is ACTIVE (ON by default): an assigned issue is refused.
#   OPT  FLEET_PRESPAWN_DEDUP=0 ⇒ opt-out: NO claim gh calls; the window still spawns.
#   A    flag on + assignee present            → refuse, no claim, no spawn.
#   B    flag on + a ▶ claiming comment present → refuse, no claim, no spawn.
#   C    flag on + issue CLOSED                 → refuse, no claim, no spawn.
#   D    flag on + an open PR on issue-<N>      → refuse (in-flight elsewhere).
#   E    flag on + FREE issue                   → claims (assignee + ▶ marker) THEN spawns.
#   F    flag on + tie-break: an EARLIER foreign ▶ claiming comment → self-reap + refuse.
#   G    flag on + --force despite an assignee  → spawns, skipping the check + claim.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured logs).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SPAWN="$BIN/dash-issue-session.sh"
[ -x "$SPAWN" ] || { echo "selftest: $SPAWN missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/prespawn-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2
         [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2
         printf -- '--- gh log ---\n%s\n--- tmux log ---\n%s\n--- git log ---\n%s\n--- display ---\n%s\n' \
           "$(cat "$GH_LOG" 2>/dev/null)" "$(cat "$TMUX_LOG" 2>/dev/null)" \
           "$(cat "$GIT_LOG" 2>/dev/null)" "$(cat "$DISPLAY_LOG" 2>/dev/null)" >&2
         exit 1; }

mkdir -p "$WORK/main/.git" "$WORK/fakebin" "$WORK/conf" "$WORK/dash"
GH_LOG="$WORK/gh.log"; TMUX_LOG="$WORK/tmux.log"; GIT_LOG="$WORK/git.log"; DISPLAY_LOG="$WORK/display.log"

# --- fake git: fetch/worktree/branch succeed; worktree+branch ops are LOGGED -------
cat > "$WORK/fakebin/git" <<GITFAKE
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then shift 2; fi
case "\${1:-}" in
  worktree|branch) printf 'git %s\n' "\$*" >> "$GIT_LOG" ;;   # add / remove / prune / branch -D
  rev-parse)       case "\$*" in *--show-toplevel*) pwd -P ;; *) printf 'deadbeef\n' ;; esac ;;
  *) : ;;   # fetch / remote → succeed silently
esac
exit 0
GITFAKE

# --- fake gh: LOG every call; answer the claim-ledger reads + writes from env -------
# CLAIM_STATE  = "<assignee_count>\t<state>\t<claiming_comment_count>" (the check read)
# PR_COUNT     = open-PR count on issue-<N>                            (the PR probe)
# MY_CLAIM_URL = the URL `gh issue comment` prints (its REST id is our tie token)
# CLAIM_URLS   = newline-separated ▶ claiming comment URLs             (the tie-break read)
cat > "$WORK/fakebin/gh" <<GHFAKE
#!/bin/bash
printf 'gh %s\n' "\$*" >> "$GH_LOG"
case "\$*" in
  *"issue view"*"--json assignees,state,comments"*) printf '%s\n' "\${CLAIM_STATE:-0	OPEN	0}" ;;
  *"issue view"*"--json comments"*)                 printf '%s\n' "\${CLAIM_URLS:-}" ;;
  *"issue view"*"--json title"*)                    printf '%s\n' "\${GH_TITLE:-Some Issue}" ;;
  *"pr list"*)                                       printf '%s\n' "\${PR_COUNT:-0}" ;;
  *"issue comment"*)                                 printf '%s\n' "\${MY_CLAIM_URL:-https://github.com/acme/widgets/issues/258#issuecomment-200}" ;;
  *"issue edit"*)                                    : ;;
  *"api user"*)                                      printf 'me\n' ;;
  *) : ;;
esac
exit 0
GHFAKE

# --- fake tmux: -p queries answered; new-window / kill-window / display LOGGED ------
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
  list-windows)      : ;;                                   # no existing windows → no local dedup hit
  show-options)      echo '' ;;
  new-window)        printf 'new-window %s\n' "\$*" >> "$TMUX_LOG"; echo "\${TMUX_WIN:-@9}" ;;
  kill-window)       printf 'kill-window %s\n' "\$*" >> "$TMUX_LOG" ;;
  set-window-option) : ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/git" "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

# Run the real spawn in a clean per-fleet dir; scenario knobs come in via env.
run_spawn() { # $@ = args to dash-issue-session.sh
  : > "$GH_LOG"; : > "$TMUX_LOG"; : > "$GIT_LOG"; : > "$DISPLAY_LOG"
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
display_has() { grep -qiF -- "$1" "$DISPLAY_LOG"; }

# The default is ON: make sure a stray value from this shell can't mask that.
unset FLEET_PRESPAWN_DEDUP

# ===== DEF: flag UNSET ⇒ dedup is ACTIVE (ON by default) ===========================
# An assigned issue must be refused even with NO FLEET_PRESPAWN_DEDUP set — the
# cross-machine claim ledger is the default now (issue #258 follow-up).
CLAIM_STATE=$'1\tOPEN\t0' run_spawn 258
[ "$(rc)" != 0 ]                                 || fail "DEF (unset) must dedup by default — an assigned issue refuses"
tmux_has 'new-window'                            && fail "DEF (unset) must NOT spawn a claimed issue"
display_has 'already claimed elsewhere'          || fail "DEF should announce 'already claimed elsewhere'"
ok "DEF (flag unset) runs the dedup — ON by default"

# ===== OPT: FLEET_PRESPAWN_DEDUP=0 ⇒ opt-out fast path: no claim calls, still spawns =
CLAIM_STATE=$'1\tOPEN\t0' FLEET_PRESPAWN_DEDUP=0 run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "OPT (=0) should spawn even an assigned issue (dedup off)" "$(cat "$WORK/spawn.err")"
gh_has 'assignees,state,comments'                && fail "OPT (=0) must NOT run the claim-ledger read"
gh_has '--add-assignee'                          && fail "OPT (=0) must NOT claim (assign)"
gh_has 'issue comment'                           && fail "OPT (=0) must NOT post a ▶ claiming comment"
tmux_has 'new-window'                            || fail "OPT (=0) should still spawn the window"
ok "OPT (FLEET_PRESPAWN_DEDUP=0) is the zero-gh opt-out — no claim calls, window spawns"

# ===== A: assignee present ⇒ refuse ================================================
CLAIM_STATE=$'1\tOPEN\t0' FLEET_PRESPAWN_DEDUP=1 run_spawn 258
[ "$(rc)" != 0 ]                                 || fail "A an assigned issue must refuse (non-zero exit)"
tmux_has 'new-window'                            && fail "A must NOT spawn a window for a claimed issue"
gh_has '--add-assignee'                          && fail "A must NOT claim an already-claimed issue"
display_has 'already claimed elsewhere'          || fail "A should announce 'already claimed elsewhere'"
ok "A assignee present → refuse + no spawn"

# ===== B: a ▶ claiming comment present ⇒ refuse ===================================
CLAIM_STATE=$'0\tOPEN\t1' FLEET_PRESPAWN_DEDUP=1 run_spawn 258
[ "$(rc)" != 0 ]                                 || fail "B a ▶ claiming comment must refuse"
tmux_has 'new-window'                            && fail "B must NOT spawn for a ▶ claiming-marked issue"
ok "B ▶ claiming comment present → refuse + no spawn"

# ===== C: issue CLOSED ⇒ refuse ===================================================
CLAIM_STATE=$'0\tCLOSED\t0' FLEET_PRESPAWN_DEDUP=1 run_spawn 258
[ "$(rc)" != 0 ]                                 || fail "C a CLOSED issue must refuse"
tmux_has 'new-window'                            && fail "C must NOT spawn for a closed/merged issue"
ok "C closed/merged issue → refuse + no spawn"

# ===== D: an open PR on issue-<N> ⇒ refuse ========================================
CLAIM_STATE=$'0\tOPEN\t0' PR_COUNT=1 FLEET_PRESPAWN_DEDUP=1 run_spawn 258
[ "$(rc)" != 0 ]                                 || fail "D an open PR (in flight) must refuse"
tmux_has 'new-window'                            && fail "D must NOT spawn when a PR is already open elsewhere"
ok "D open PR on issue-<N> → refuse + no spawn"

# ===== E: FREE issue ⇒ claim (assignee + marker) THEN spawn =======================
CLAIM_STATE=$'0\tOPEN\t0' PR_COUNT=0 \
  MY_CLAIM_URL='https://github.com/acme/widgets/issues/258#issuecomment-200' \
  CLAIM_URLS='https://github.com/acme/widgets/issues/258#issuecomment-200' \
  FLEET_PRESPAWN_DEDUP=1 run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "E a free issue should claim + spawn (exit 0)" "$(cat "$WORK/spawn.err")"
gh_has '--add-assignee'                          || fail "E a free issue must claim the assignee AT SPAWN"
gh_has 'issue comment'                           || fail "E a free issue must post the ▶ claiming marker AT SPAWN"
tmux_has 'new-window'                            || fail "E a free issue must spawn the window after claiming"
tmux_has 'kill-window'                           && fail "E winning the tie-break must NOT self-reap the window"
ok "E free issue → claims (assignee + ▶ marker) THEN spawns, no rollback"

# ===== F: tie-break — an EARLIER foreign ▶ claiming ⇒ self-reap + refuse ===========
# The check passes (free at read time); we claim (our REST id 200) + create the
# window; the re-read finds a foreign claim with an EARLIER id (100) → we lost.
CLAIM_STATE=$'0\tOPEN\t0' PR_COUNT=0 \
  MY_CLAIM_URL='https://github.com/acme/widgets/issues/258#issuecomment-200' \
  CLAIM_URLS=$'https://github.com/acme/widgets/issues/258#issuecomment-100\nhttps://github.com/acme/widgets/issues/258#issuecomment-200' \
  FLEET_PRESPAWN_DEDUP=1 run_spawn 258
[ "$(rc)" != 0 ]                                 || fail "F losing the tie-break must refuse (non-zero exit)"
tmux_has 'new-window'                            || fail "F the window is created BEFORE the tie-break re-read"
tmux_has 'kill-window'                           || fail "F a lost tie-break must self-reap (kill) the window"
git_has 'worktree remove'                        || fail "F a lost tie-break must remove the worktree"
git_has 'branch -D'                              || fail "F a lost tie-break must drop the just-created branch"
display_has 'rolled back'                        || fail "F should announce the rollback"
ok "F earlier foreign ▶ claiming → self-reap window/worktree/branch + refuse"

# ===== G: --force spawns despite an assignee, skipping check + claim ===============
CLAIM_STATE=$'1\tOPEN\t0' FLEET_PRESPAWN_DEDUP=1 run_spawn 258 --force
[ "$(rc)" = 0 ]                                  || fail "G --force should spawn despite a claim (exit 0)" "$(cat "$WORK/spawn.err")"
gh_has 'assignees,state,comments'                && fail "G --force must SKIP the claim-ledger check"
gh_has '--add-assignee'                          && fail "G --force must SKIP claim-at-spawn"
tmux_has 'new-window'                            || fail "G --force must spawn the window"
ok "G --force/--reclaim spawns past a stale claim, skipping the check + claim"

printf '\nselftest OK: %s assertions passed (cross-machine pre-spawn dedup, issue #258)\n' "$pass"
exit 0
