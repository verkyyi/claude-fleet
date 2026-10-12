#!/bin/bash
# fleet-land.sh [--verdict] [-q] [--issue N] <repo> [<branch>]
#   — a repo the fleet lands ITSELF (issue #3602, EPIC #3570 C9): no pull request,
#   no forge; git, the repo's own check, and a fast-forward of the base.
#
# For a repo whose conf says FLEET_LAND=fleet (every FLEET_FORGE=none repo — an ssh
# bare repo, a GitLab, a local path — and any GitHub repo whose owner opted out of
# pull requests). bin/fleet-pr-verdict.sh / bin/fleet-pr-merge.sh hand such a repo
# here, so the worker's `pr_verdict` → `pr_merge` stay the same two tool calls and
# the same verdict words.
#
# MERGE (the default) — one run, start to end, never past a red:
#   1. LEASE   the repo's land lease (bin/fleet-land-lease.sh, the one the cleanup
#              and base-sync passes already take to move the base): one lander per
#              repo per machine; a second waits (FLEET_LAND_LEASE_WAIT, 300s), then
#              answers PENDING — call again.
#   2. FETCH   origin/<base>. Already on it (fleet_land_check) ⇒ MERGED.
#   3. REBASE  the branch onto the base's newest commit, in the session's worktree
#              (a temporary one when the branch has none). Uncommitted tracked
#              changes, or a conflict ⇒ CONFLICT (the rebase is aborted, nothing moved).
#   4. CHECK   the repo conf's FLEET_CHECK_CMD in that worktree, through the machine's
#              heavy-job queue (bin/fleet-heavy.sh), killed after FLEET_CHECK_TIMEOUT
#              (480s). Non-zero / timeout ⇒ FAILING, its last lines on stderr, the
#              base untouched. No command ⇒ lands anyway, the record says 没跑检查;
#              FLEET_CHECK_REQUIRED=1 ⇒ BLOCKED. A result is kept per (commit,
#              command), so a verdict's check is not run twice.
#   5. PUSH    the rebased tip to origin/<base> — a fast-forward or nothing. The
#              remote moved meanwhile ⇒ fetch and go again from 3, once; again ⇒
#              BEHIND. Refused for any other reason (protection, auth) ⇒ BLOCKED.
#   6. RECORD  fleet_landed_note (fleet_landed's ③) + one JSON line in
#              $FLEET_CONF_DIR/landed/<slug>.ndjson (repo · branch · tip · landed ·
#              base · check · secs · ts). The remote branch, if it was pushed, is
#              deleted — like `--delete-branch`.
#
# --verdict — the read (`pr_verdict`): MERGED · CONFLICT (would not rebase cleanly) ·
#   BEHIND (the base moved past the branch's fork — pr_merge rebases it itself) ·
#   BLOCKED (FLEET_CHECK_REQUIRED, no command) · FAILING / READY (the check run on
#   the tip as it stands). Never PENDING: the check runs in the read.
#
# The branch: <branch>, else `issue-<N>` for --issue N (the number pr_verdict /
# pr_merge were given), else the branch checked out in the current directory.
# stdout: one verdict token. Exit: 0 READY (verdict) / MERGED (merge) · 1 any other
# verdict · 2 error (repo not hosted, no checkout, no branch, base unreachable).
# Never calls gh.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-land-lease.sh"

mode=merge quiet=0 issue='' repo='' branch=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --verdict) mode=verdict ;;
    -q|--quiet) quiet=1 ;;
    --issue)   shift; issue="${1//[^0-9]/}" ;;
    -h|--help) sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)       printf 'fleet-land: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)         if [ -z "$repo" ]; then repo="$1"; else branch="$1"; fi ;;
  esac
  shift
done
note() { [ "$quiet" = 1 ] || printf 'fleet-land: %s\n' "$1" >&2; }
die() { printf 'fleet-land: %s\n' "$1" >&2; exit 2; }
say() { printf '%s\n' "$1"; [ -n "${2:-}" ] && note "$2"; [ "$1" = READY ] || [ "$1" = MERGED ] && exit 0; exit 1; }

[ -n "$repo" ] || die 'a repo is required'
repo=$(fleet_norm_repo "$repo")
slug=$(fleet_slug "$repo")

# The fleet hosting <repo>: this one, else the first that does (fleet_landed's rule).
sess=''
for s in ${FLEET_SESSION:-} $(fleet_current_session 2>/dev/null) $(fleet_each_conf | cut -f1); do
  fleet_repo_hosted "$s" "$repo" && { sess=$s; break; }
done
[ -n "$sess" ] || die "no fleet here hosts $repo"
cget() { fleet_repo_conf_get "$sess" "$repo" "$1"; }
root=$(cget FLEET_MAIN); base=$(cget FLEET_BASE_BRANCH); base=${base:-main}
check_cmd=$(cget FLEET_CHECK_CMD); check_req=$(cget FLEET_CHECK_REQUIRED)
check_to=$(cget FLEET_CHECK_TIMEOUT); case "$check_to" in ''|*[!0-9]*|0) check_to=480 ;; esac
[ -n "$root" ] && git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || die "no checkout for $repo (FLEET_MAIN=${root:-unset})"

if [ -z "$branch" ] && [ -n "$issue" ]; then branch="issue-$issue"; fi
if [ -z "$branch" ]; then
  branch=$(git symbolic-ref -q --short HEAD 2>/dev/null) || die 'no branch named, and this directory has none checked out'
fi
[ "$branch" != "$base" ] || die "$branch is the base branch itself — name the session's branch"
git -C "$root" rev-parse --verify -q "refs/heads/$branch^{commit}" >/dev/null || die "no branch $branch in $root"

gitq() { GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=10}" git "$@"; }
fetch_base() {
  gitq -C "$root" fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" >/dev/null 2>&1 || return 1
  B=$(git -C "$root" rev-parse --verify -q "origin/$base^{commit}") || return 1
}

ldir="$FLEET_CONF_DIR/landed"; cdir="$ldir/checks/$slug"
cmd_id=$(printf '%s' "$check_cmd" | git hash-object --stdin 2>/dev/null)
TMPWT=''
# shellcheck disable=SC2329  # the EXIT trap
on_exit() {
  [ -n "$TMPWT" ] && { git -C "$root" worktree remove --force "$TMPWT" >/dev/null 2>&1; rm -rf "$TMPWT"; }
  [ -n "${LEASE:-}" ] && land_lease_release "$LEASE"
}
trap on_exit EXIT

# worktree_for <commit> → the directory to rebase / check in: the branch's own
# worktree, else a temporary detached one at <commit>. rc 1 when it has
# uncommitted tracked changes.
WT=''
worktree_for() {
  WT=$(fleet_worktree_head "$root" "$branch" | cut -f1)
  if [ -z "$WT" ]; then
    if [ -z "$TMPWT" ]; then
      TMPWT=$(mktemp -d "${TMPDIR:-/tmp}/fleet-land.XXXXXX") || return 2
      rmdir "$TMPWT"
      git -C "$root" worktree add -q --detach "$TMPWT" "$1" >/dev/null 2>&1 || { TMPWT=''; return 2; }
    else
      git -C "$TMPWT" checkout -q --detach "$1" >/dev/null 2>&1 || return 2
    fi
    WT=$TMPWT
  fi
  [ -z "$(git -C "$WT" status --porcelain --untracked-files=no 2>/dev/null)" ]
}

# run_check <commit> → sets CHECK (pass · fail · timeout · none) and CHECK_SECS;
# the result is kept per (commit, command).
CHECK='' CHECK_SECS=0
run_check() {
  local c=$1 f t0 rc
  CHECK_SECS=0
  [ -n "$check_cmd" ] || { CHECK=none; return 0; }
  f="$cdir/$c.$cmd_id"
  if [ -f "$f" ]; then
    CHECK=$(cut -f1 "$f"); CHECK_SECS=$(cut -f2 "$f"); note "check on ${c:0:12}: $CHECK (kept)"
    check_tail "$f"; return 0
  fi
  mkdir -p "$cdir" 2>/dev/null
  note "check on ${c:0:12}: $check_cmd (≤${check_to}s, in $WT)"
  t0=$(date +%s)
  # shellcheck disable=SC2016  # python source, not shell
  ( cd "$WT" && "$BIN/fleet-heavy.sh" --label "land:$slug" --wait 60 -- python3 -c '
import os, signal, subprocess, sys
p = subprocess.Popen(["bash", "-c", sys.argv[2]], start_new_session=True)
try:
    sys.exit(p.wait(timeout=int(sys.argv[1])))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL); p.wait(); sys.exit(124)
' "$check_to" "$check_cmd" ) > "$f.log" 2>&1 < /dev/null
  rc=$?
  CHECK_SECS=$(( $(date +%s) - t0 ))
  case "$rc" in 0) CHECK=pass ;; 124) CHECK=timeout ;; *) CHECK=fail ;; esac
  printf '%s\t%s\n' "$CHECK" "$CHECK_SECS" > "$f"
  [ "$CHECK" = pass ] || note "check $CHECK (exit $rc, ${CHECK_SECS}s)"
  check_tail "$f"
}
# check_tail <result file> — a red check's last lines, for the session to read.
check_tail() {
  case "$CHECK" in fail|timeout) [ "$quiet" != 1 ] || return 0 ;; *) return 0 ;; esac
  note "the check's last lines (${1}.log):"
  tail -n 30 "$1.log" 2>/dev/null | sed 's/^/  | /' >&2
}

json_s() { printf '"%s"' "$(printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r\t')"; }
record() {  # record <tip> <landed>
  local tip=$1 new=$2 now; now=$(date +%s)
  fleet_landed_note "$repo" "$branch" "$new" "$new" "$now"
  [ "$tip" = "$new" ] || fleet_landed_note "$repo" "$branch" "$tip" "$new" "$now"
  mkdir -p "$ldir" 2>/dev/null
  printf '{"repo":%s,"branch":%s,"tip":%s,"landed":%s,"base":%s,"check":%s,"cmd":%s,"secs":%s,"ts":%s,"by":%s}\n' \
    "$(json_s "$repo")" "$(json_s "$branch")" "$(json_s "$tip")" "$(json_s "$new")" "$(json_s "$base")" \
    "$(json_s "$CHECK")" "$(json_s "$check_cmd")" "${CHECK_SECS:-0}" "$now" "$(json_s "$sess")" \
    >> "$ldir/$slug.ndjson"
}

# ---------------------------------------------------------------- verdict ----
B=''
if [ "$mode" = verdict ]; then
  fetch_base || die "cannot fetch $base from $repo's origin"
  tip=$(git -C "$root" rev-parse "refs/heads/$branch")
  fleet_land_check "$root" "$tip" "$B" >/dev/null && say MERGED "$branch is already on $base"
  git -C "$root" merge-tree --write-tree --no-messages "$B" "$tip" >/dev/null 2>&1; mt=$?
  [ "$mt" -eq 1 ] && say CONFLICT "$branch conflicts with $base — rebase on origin/$base and resolve"
  git -C "$root" merge-base --is-ancestor "$B" "$tip" 2>/dev/null \
    || say BEHIND "$base moved past $branch's fork — pr_merge rebases it onto $base and re-runs the check"
  [ -z "$check_cmd" ] && [ "$check_req" = 1 ] \
    && say BLOCKED "$repo requires a check (FLEET_CHECK_REQUIRED=1) and has no FLEET_CHECK_CMD — its owner sets one"
  worktree_for "$tip"; wr=$?
  [ "$wr" -eq 2 ] && die "cannot open a worktree for $branch"
  if [ "$wr" -eq 1 ] && [ -n "$check_cmd" ]; then
    say CONFLICT "$WT has uncommitted changes — commit them first"
  fi
  run_check "$tip"
  case "$CHECK" in
    pass) say READY "$branch passes the check and fast-forwards $base — pr_merge lands it" ;;
    none) say READY "$branch fast-forwards $base — no check registered (没跑检查); pr_merge lands it" ;;
    *)    say FAILING "$branch's check is $CHECK — fix it, never land red" ;;
  esac
fi

# ------------------------------------------------------------------ merge ----
LEASE="${LAND_LEASE_DIR:-${FLEET_LAND_LEASE_DIR:-$HOME/.claude/leases}}/land-$slug.lock"
lw=${FLEET_LAND_LEASE_WAIT:-300}; case "$lw" in ''|*[!0-9]*) lw=300 ;; esac
SECONDS=0
until land_lease_acquire "$LEASE" "${LAND_LEASE_TTL:-3600}" "land:$sess:$branch:$$@$(land_lease_host)"; do
  if [ "$SECONDS" -ge "$lw" ]; then
    h=$(land_lease_holder "$LEASE"); LEASE=''
    say PENDING "another landing holds $repo's lease (${h:-?}) — call again"
  fi
  sleep 2
done

[ -z "$check_cmd" ] && [ "$check_req" = 1 ] \
  && say BLOCKED "$repo requires a check (FLEET_CHECK_REQUIRED=1) and has no FLEET_CHECK_CMD — its owner sets one"
tip0=$(git -C "$root" rev-parse "refs/heads/$branch")
tries=0
while :; do
  tries=$((tries + 1))
  fetch_base || die "cannot fetch $base from $repo's origin"
  tip=$(git -C "$root" rev-parse "refs/heads/$branch")
  if fleet_land_check "$root" "$tip" "$B" >/dev/null; then say MERGED "$branch is already on $base"; fi
  worktree_for "$tip"; wr=$?
  [ "$wr" -eq 2 ] && die "cannot open a worktree for $branch"
  [ "$wr" -eq 1 ] && say CONFLICT "$WT has uncommitted changes — commit them, then pr_merge again"
  if ! git -C "$root" merge-base --is-ancestor "$B" "$tip" 2>/dev/null; then
    if ! git -C "$WT" -c core.editor=true rebase -q "$B" >/dev/null 2>&1; then
      git -C "$WT" rebase --abort >/dev/null 2>&1
      say CONFLICT "$branch does not rebase cleanly onto origin/$base — rebase it by hand, resolve, then pr_merge again"
    fi
    new=$(git -C "$WT" rev-parse HEAD)
    [ "$WT" = "$TMPWT" ] && git -C "$root" update-ref "refs/heads/$branch" "$new" "$tip"
    note "rebased $branch onto origin/$base (${B:0:12}) → ${new:0:12}"
  else
    new=$tip
  fi
  run_check "$new"
  case "$CHECK" in pass|none) ;; *) say FAILING "$branch's check is $CHECK on ${new:0:12} — $base not moved; fix it and pr_merge again" ;; esac
  if out=$(gitq -C "$root" push -q origin "$new:refs/heads/$base" 2>&1); then break; fi
  B0=$B
  fetch_base || die "cannot fetch $base from $repo's origin"
  if [ "$B" = "$B0" ]; then
    note "push refused: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
    say BLOCKED "origin refused the fast-forward of $base (not a race: $base did not move) — not yours to force"
  fi
  [ "$tries" -ge 2 ] && say BEHIND "$base moved twice while landing — pr_merge again"
  note "$base moved while landing — going again on the newest"
done

record "$tip0" "$new"
gitq -C "$root" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 \
  && gitq -C "$root" push -q origin --delete "$branch" >/dev/null 2>&1
case "$CHECK" in
  none) say MERGED "$branch landed on $base at ${new:0:12} — 没跑检查 (no FLEET_CHECK_CMD)" ;;
  *)    say MERGED "$branch landed on $base at ${new:0:12} — check passed (${CHECK_SECS}s)" ;;
esac
