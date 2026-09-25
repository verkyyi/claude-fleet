#!/bin/bash
# fleet-cleanup-multirepo-selftest.sh — cleanup stays inside its own repo (issue #791).
#
# One fleet hosting two repos, o/a and o/b, each with its OWN issue-12 worker
# (window + worktree). Real git, a real tmux server on a PRIVATE socket (PATH shim —
# never the live server), a fake `gh` that knows exactly one merged PR: o/a#101,
# head issue-12. Asserts:
#   A. helpers — fleet_issue_windows joins on (repo, issue); fleet_load_window_conf
#      loads the window's own repo and refuses unknown / @norepo windows with every
#      repo key unset; fleet_worktree_repo finds the hosted repo registering a path.
#   B. ONE CLEANUP TICK with o/a#101 merged: A's issue-12 window + worktree are
#      reaped; B's issue-12 window AND worktree survive; the unknown-repo #12 window
#      and the @norepo window survive.
#   C. fleet-cleanup.sh --repo refuses a repo the fleet does not host.
#   D. idle close runs each repo's pass against THAT repo's MAIN: B's done scratch
#      is a candidate (A's MAIN does not register it); an unknown-repo or @norepo
#      scratch is not.
#   E. SessionEnd on a window whose repo cannot be told closes the window and
#      touches no worktree of either repo.
#   F. degenerate — a fleet with no repos/ dir matches every @issue window, as before.
#
# The evidence line prints the sandbox's `#{@repo} #{@issue} #{window_name}` rows
# before and after the tick.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-cleanup-multirepo.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin" "$WORK/leases" "$WORK/tmp"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
# gh: one merged PR (o/a#101, head issue-12); every list is empty; all else fails.
cat > "$WORK/bin/gh" <<'EOF'
#!/bin/bash
repo=""; prev=""
for a in "$@"; do [ "$prev" = --repo ] || [ "$prev" = -R ] && repo="$a"; prev="$a"; done
case "$1 $2" in
  "pr view")
    [ "$repo" = o/a ] && [ "$3" = 101 ] || exit 1
    printf 'MERGED\t%s\tissue-12\t-\t2020-01-01T00:00:00Z\t%s\n' "$(cat "$GH_SHA_A")" "${GH_CLOSES_A:-o/a#12}" ;;
  "pr list") printf '[]\n' ;;
  "issue view")   # the bound-issue gate (issue #1156) — logged so the leg can check the join
    printf '%s %s\n' "$repo" "$3" >> "$GH_ISSUE_LOG"
    printf '%s\n' "${GH_ISSUE_STATE:-CLOSED}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/tmux" "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" GH_SHA_A="$WORK/sha-a" GH_ISSUE_LOG="$WORK/gh-issue.log"

cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
export FLEET_DISPATCH_LEASE_DIR="$WORK/leases" FLEET_LAND_LEASE_DIR="$WORK/leases"
export FLEET_HISTORY_LEDGER="$WORK/ledger.tsv" FLEET_TRASH_SWEEP_BUDGET=0
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_SESSION
. "$BIN/fleet-lib.sh"

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
eq()   { [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }

# --- two repos, each with an issue-12 worktree ----------------------------------
g() { git -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }
mkrepo() {   # $1=name → bare origin + base checkout at $WORK/main-$1
  g init -q --bare "$WORK/origin-$1.git"
  g clone -q "$WORK/origin-$1.git" "$WORK/main-$1"
  g -C "$WORK/main-$1" checkout -q -b master
  g -C "$WORK/main-$1" commit -q --allow-empty -m init
  g -C "$WORK/main-$1" push -q origin master
}
mkrepo a; mkrepo b
g -C "$WORK/main-a" worktree add -q -b issue-12 "$WORK/a-issue-12"
g -C "$WORK/main-b" worktree add -q -b issue-12 "$WORK/b-issue-12"
g -C "$WORK/main-b" worktree add -q -b scratch-5 "$WORK/b-scratch-5"
git -C "$WORK/a-issue-12" rev-parse HEAD > "$GH_SHA_A"

S=ft
mkdir -p "$FLEET_CONF_DIR/fleets/$S/repos"
cat > "$FLEET_CONF_DIR/fleets/$S/conf" <<EOF
FLEET_REPO="o/a"
FLEET_MAIN="$WORK/main-a"
FLEET_BASE_BRANCH="master"
FLEET_CLEANUP_MERGED_GRACE=0
FLEET_REAP_MIN_AGE=0
FLEET_REAP_IDLE_DONE_MIN=1
EOF
cat > "$FLEET_CONF_DIR/fleets/$S/repos/o-b.conf" <<EOF
FLEET_REPO="o/b"
FLEET_MAIN="$WORK/main-b"
FLEET_BASE_BRANCH="master"
EOF

# prmaps, one per repo (pr-refresh's layout): A's #12 merged, B's #12 open.
for r in o-a o-b; do mkdir -p "$FLEET_C/fleets/$r"; date +%s > "$FLEET_C/fleets/$r/prmap.ts"; done
printf 'issue-12\t#101\tMERGED\t\t\t%s\n' "$(cat "$GH_SHA_A")" > "$FLEET_C/fleets/o-a/prmap"
printf 'issue-12\t#201\tOPEN\t\t\t\n' > "$FLEET_C/fleets/o-b/prmap"

# --- the fleet's windows ----------------------------------------------------------
"$REAL_TMUX" -S "$SOCK" new-session -d -s "$S" -n plan -x 200 -y 50 || { echo "could not start isolated tmux" >&2; exit 1; }
old=$(( $(date +%s) - 7200 ))
mkwin() {   # $1=name $2=cwd, then option/value pairs → prints the window id
  local n="$1" d="$2" w; shift 2
  w=$(tmux new-window -d -P -F '#{window_id}' -t "$S" -n "$n" -c "$d")
  tmux set-option -w -t "$w" @claude_state "done"
  tmux set-option -w -t "$w" @claude_state_ts "$old"
  while [ "$#" -ge 2 ]; do tmux set-option -w -t "$w" "$1" "$2"; shift 2; done
  printf '%s' "$w"
}
wA=$(mkwin issue-12 "$WORK/a-issue-12" @issue 12 @repo o/a)
wB=$(mkwin issue-12 "$WORK/b-issue-12" @issue 12 @repo o/b)
wUNK=$(mkwin unk-12 "$WORK" @issue 12)
wNO=$(mkwin norepo "$HOME" @raw 1 @norepo 1)
# The notice the daemon shows one tick before it reaps (#565) — already served.
now=$(date +%s)
tmux set-option -w -t "$wA" @reap_key "merged:101:$(cat "$GH_SHA_A")"
tmux set-option -w -t "$wA" @reap_due $((now - 5))
tmux set-option -w -t "$wA" @reap_seen "$now"
tmux set-option -w -t "$wA" @reap_state_ts "$old"

rows() { tmux list-windows -t "$S" -F '#{@repo} #{@issue} #{window_name}'; }
has_win() { tmux list-windows -t "$S" -F '#{window_id}' | grep -qxF "$1"; }
registered() { git -C "$1" worktree list --porcelain | grep -qxF "worktree $2"; }

# --- A. helpers --------------------------------------------------------------------
eq "A: (o/a, 12) windows" "$(fleet_issue_windows "$S" o/a 12)" "$wA"
eq "A: (o/b, 12) windows" "$(fleet_issue_windows "$S" o/b 12)" "$wB"
eq "A: (o/zzz, 12) windows" "$(fleet_issue_windows "$S" o/zzz 12)" ""
got=$( fleet_load_window_conf "$S" "$wB" && printf '%s|%s' "$FLEET_REPO" "$FLEET_MAIN" )
eq "A: window conf for B's window" "$got" "o/b|$WORK/main-b"
got=$( fleet_load_window_conf "$S" "$wUNK"; printf '%s|%s|%s' "$?" "${FLEET_REPO-unset}" "${FLEET_MAIN-unset}" )
eq "A: unknown-repo window refused, keys unset" "$got" "1|unset|unset"
got=$( fleet_load_window_conf "$S" "$wNO"; printf '%s|%s' "$?" "${FLEET_MAIN-unset}" )
eq "A: @norepo window refused" "$got" "1|unset"
eq "A: worktree → repo" "$(fleet_worktree_repo "$S" "$WORK/b-issue-12")" "o/b	$WORK/main-b"
eq "A: base checkout is no worktree" "$(fleet_worktree_repo "$S" "$WORK/main-a")" ""
eq "A: resolved repo ignores the sessmap" "$( fleet_load_window_conf "$S" "$wB"; fleet_resolved_repo "$S" )" o/b

# --- A2. the bound-issue gate joins on (repo, issue) (issue #1156) -------------------
# o/a#101 closing o/b's #12 is NOT proof o/a#12 is done; the fallback read is o/a#12.
# Dry-run: it classifies without writing the notice B's tick depends on.
: > "$GH_ISSUE_LOG"
tok=$(GH_CLOSES_A='o/b#12' GH_ISSUE_STATE=OPEN FLEET_SESSION="$S" \
  bash "$BIN/fleet-cleanup.sh" 101 --repo o/a --auto --dry-run 2>/dev/null)
eq "A2: o/a#101 closing o/b#12 + o/a#12 OPEN" "$tok" "skip:issue-open"
eq "A2: issue read joined on (repo, issue)" "$(cat "$GH_ISSUE_LOG")" "o/a 12"

# --- B. one cleanup tick -------------------------------------------------------------
before=$(rows)
log=$(bash "$BIN/fleet-cleanup-daemon.sh" "$S" 2>&1)
after=$(rows)
printf 'evidence — before the tick:\n%s\nevidence — after the tick:\n%s\n' "$before" "$after"
has_win "$wA" && fail "B: A's issue-12 window survived the tick
$log"
registered "$WORK/main-a" "$WORK/a-issue-12" && fail "B: A's issue-12 worktree still registered"
has_win "$wB" || fail "B: B's issue-12 window was killed"
[ -d "$WORK/b-issue-12" ] && registered "$WORK/main-b" "$WORK/b-issue-12" || fail "B: B's issue-12 worktree lost"
has_win "$wUNK" || fail "B: the unknown-repo #12 window was killed"
has_win "$wNO" || fail "B: the @norepo window was killed"
case "$log" in *"cleaned:"*"PR #101"*) ;; *) fail "B: no cleaned token for o/a#101: $log" ;; esac
case "$log" in *"[o/b]"*) ;; *) fail "B: the o/b pass did not run: $log" ;; esac

# --- C. --repo must be hosted ----------------------------------------------------------
tok=$(FLEET_SESSION="$S" bash "$BIN/fleet-cleanup.sh" 101 --repo o/zzz --dry-run 2>/dev/null)
eq "C: unhosted --repo" "$tok" "error:no-repo"

# --- D. idle close uses each repo's own MAIN -----------------------------------------------
wS=$(mkwin scratch-5 "$WORK/b-scratch-5" @raw 1 @worktree "$WORK/b-scratch-5")
tmux set-window-option -u -t "$wS" @repo 2>/dev/null
wNS=$(mkwin norepo-2 "$HOME" @raw 1 @norepo 1 @worktree "$WORK/b-scratch-5")
# Its origin is a local bare repo, so @repo cannot be derived: an UNKNOWN-repo
# window, which no automatic pass may close.
out=$(bash "$BIN/fleet-cleanup-idle.sh" "$S" --limit 4 --dry-run 2>&1)
case "$out" in *"would-reap-idle:$wS"*) fail "D: an unknown-repo scratch was offered for idle close" ;; esac
case "$out" in *"would-reap-idle:$wNS"*) fail "D: a @norepo window was offered for idle close" ;; esac
tmux set-option -w -t "$wS" @repo o/b
now=$(date +%s)   # the idle notice (#565), already served
tmux set-option -w -t "$wS" @reap_key "idle:$(git -C "$WORK/b-scratch-5" rev-parse HEAD)"
tmux set-option -w -t "$wS" @reap_due $((now - 5))
tmux set-option -w -t "$wS" @reap_seen "$now"
tmux set-option -w -t "$wS" @reap_state_ts "$old"
out=$(bash "$BIN/fleet-cleanup-idle.sh" "$S" --limit 4 --dry-run 2>&1)
case "$out" in *"would-reap-idle:$wS"*) ;; *) fail "D: B's stamped idle scratch not a candidate: $out" ;; esac
tmux kill-window -t "$wS"; tmux kill-window -t "$wNS"

# --- E. SessionEnd on an unknown-repo window ---------------------------------------------------
( export TMUX="$SOCK,1,0"; bash "$BIN/session-end-hook.sh" --exec worker "$S" "$wUNK" 12 ) >/dev/null 2>&1
has_win "$wUNK" && fail "E: SessionEnd left the unknown-repo window open"
registered "$WORK/main-b" "$WORK/b-issue-12" || fail "E: SessionEnd on an unknown window touched B's worktree"

# --- F. degenerate: no repos/ dir -------------------------------------------------------------
D=fd
mkdir -p "$FLEET_CONF_DIR/fleets/$D"
printf 'FLEET_REPO="o/a"\nFLEET_MAIN="%s"\n' "$WORK/main-a" > "$FLEET_CONF_DIR/fleets/$D/conf"
tmux new-session -d -s "$D" -n plan
d1=$(tmux new-window -d -P -F '#{window_id}' -t "$D" -n x); tmux set-option -w -t "$d1" @issue 7
d2=$(tmux new-window -d -P -F '#{window_id}' -t "$D" -n y); tmux set-option -w -t "$d2" @issue 7
tmux set-option -w -t "$d2" @repo o/other
eq "F: degenerate matches every @issue window" "$(fleet_issue_windows "$D" o/a 7 | tr '\n' ' ')" "$d1 $d2 "
got=$( fleet_load_window_conf "$D" "$d2"; printf '%s|%s' "$?" "$FLEET_MAIN" )
eq "F: degenerate window conf is the fleet conf" "$got" "0|$WORK/main-a"
fleet_has_repo_overlays "$D" && fail "F: fd reported multi-repo"

[ "$FAILS" -eq 0 ] && { echo "fleet-cleanup-multirepo-selftest: PASS"; exit 0; }
echo "fleet-cleanup-multirepo-selftest: $FAILS failure(s)" >&2; exit 1
