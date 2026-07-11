#!/bin/bash
# land-train.sh [--dry-run] [--method squash|merge|rebase] [pr...] — a serial,
# single-writer "land train" for a fleet repo with `strict:true` branch
# protection and NO merge queue. It lands a set of PRs ONE AT A TIME: only the
# PR at the head of the queue is ever made "hot" (update-branch + wait-for-green
# + merge), so each PR is tested exactly once against the base it actually lands
# on — O(N) CI instead of the O(N²) thundering herd you get from updating every
# PR in parallel every time the base moves.
#
# Design (see issue #62, folded onto bin/fleet-land.sh in issue #231):
#   queue = green+armed PRs  DIRTY / failing are pre-filtered out (or ejected)
#   for pr in queue:
#     fleet-land.sh pr       the SHARED, seat-agnostic lander does ONE lap:
#                            per-repo lease (steal-if-stale) → hold-through-green
#                            (update-branch if BEHIND, wait CLEAN) → re-validate
#                            + --match-head-commit → squash-merge → base pull
#                            --ff-only → history ledger → worktree/window teardown.
#
# The train no longer merges inline or leaves base-pull/cleanup to the caller: it
# is a thin batch driver over fleet-land.sh, so a train, a single /fleet-land, and
# a worker /fleet-land-self all run the EXACT same mechanic and interlock on the
# SAME per-repo land lease (no two landers advance the base branch at once). A bad
# PR never blocks the train: fleet-land.sh EJECTS it with a reason and the train
# continues. Nothing is force-anything; every mutation is a plain `gh`/`git` call
# against $FLEET_REPO / $FLEET_MAIN only. `--dry-run` prints the plan and each PR's
# current verdict and mutates nothing (and takes no lease).
#
# Env knobs (all optional) — forwarded to fleet-land.sh as its LAND_* knobs:
#   LAND_TRAIN_METHOD      squash|merge|rebase           (default squash)
#   LAND_TRAIN_POLL        seconds between state polls    (default 15)
#   LAND_TRAIN_PR_TIMEOUT  per-PR budget, seconds         (default 1800)
#   LAND_TRAIN_MAX_RETRY   bounded retries for behind/race (default 3)
#   LAND_TRAIN_LEASE_TTL   lease lifetime, seconds        (default 3600)
#   FLEET_LAND_LEASE_DIR   SHARED land-lock dir for ALL landers (default
#                          ~/.claude/leases) — one lock so every land path interlocks
#   LAND_TRAIN_LEASE_DIR   per-tool override of the lease dir (tests)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-land-lease.sh"

LANDER="$BIN/fleet-land.sh"
[ -x "$LANDER" ] || { printf 'land-train: %s not found/executable.\n' "$LANDER" >&2; exit 1; }

# --- args ---------------------------------------------------------------------
DRY=0
METHOD="${LAND_TRAIN_METHOD:-squash}"
PRS=()
usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}
# Add a PR arg, warning (not silently scrubbing) on non-numeric input: a fat-
# fingered "#65" / "65 " is accepted with a note; a genuinely non-numeric arg
# ("main", "--foo" that slipped past) is DROPPED loudly, never silently → "".
add_pr_arg() {
  local raw="$1" clean="${1//[^0-9]/}"
  if [ -z "$clean" ]; then
    printf 'land-train: ignoring non-numeric PR arg %s\n' "$raw" >&2; return
  fi
  [ "$raw" != "$clean" ] && printf 'land-train: reading PR arg %s as #%s\n' "$raw" "$clean" >&2
  PRS+=("$clean")
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    --method|-m)  shift; METHOD="${1:-squash}" ;;
    -h|--help)    usage 0 ;;
    --)           shift; while [ "$#" -gt 0 ]; do add_pr_arg "$1"; shift; done; break ;;
    -*)           printf 'land-train: unknown flag %s\n' "$1" >&2; usage 1 ;;
    *)            add_pr_arg "$1" ;;
  esac
  shift
done
case "$METHOD" in squash|merge|rebase) ;; *) printf 'land-train: bad --method %s\n' "$METHOD" >&2; exit 1 ;; esac

POLL="${LAND_TRAIN_POLL:-15}"
PR_TIMEOUT="${LAND_TRAIN_PR_TIMEOUT:-1800}"
MAX_RETRY="${LAND_TRAIN_MAX_RETRY:-3}"
LEASE_TTL="${LAND_TRAIN_LEASE_TTL:-3600}"
LEASE_DIR="${LAND_TRAIN_LEASE_DIR:-${FLEET_LAND_LEASE_DIR:-$HOME/.claude/leases}}"

# --- resolve the fleet repo (this fleet only — never a cwd default) -----------
FLEET_SESSION="${FLEET_SESSION:-$(fleet_current_session)}"
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
[ -z "$REPO" ] && { printf 'land-train: no repo resolved — run inside a fleet (FLEET_REPO unset).\n' >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { printf 'land-train: gh not found on PATH.\n' >&2; exit 1; }

# All human-facing progress goes to STDERR — land_one's result token is the ONLY
# thing on stdout, so `result=$(land_one …)` captures just that token and never
# the interleaved progress lines (fleet-land.sh follows the same convention, so
# its per-PR progress flows through to the user's terminal on stderr). This is the
# issue #68 discipline: never let note() pollute a captured result.
note() { printf '%s\n' "$*" >&2; }

# --- per-PR state read (dry-run preview only) ---------------------------------
# The REAL land is delegated to fleet-land.sh; this read is used solely to print
# the pre-flight plan. Prints TSV: state mergeable mergeStateStatus draft checks.
pr_fields() {
  gh pr view "$1" --repo "$REPO" \
    --json state,mergeable,mergeStateStatus,isDraft,statusCheckRollup \
    --jq '[.state, .mergeable, .mergeStateStatus,
           (if .isDraft then "DRAFT" else "-" end),
           ((.statusCheckRollup // []) |
             if length==0 then "none"
             elif any(.conclusion=="FAILURE" or .conclusion=="CANCELLED"
                      or .conclusion=="TIMED_OUT" or .conclusion=="ACTION_REQUIRED") then "fail"
             elif any(.status!="COMPLETED") then "pending"
             else "pass" end)] | @tsv' 2>/dev/null
}

# --- land ONE PR via the shared lander, mapping its token back to the train's
# merged | eject:<why> | skip:<why> vocabulary (so the run loop + summary below
# are unchanged). fleet-land.sh's per-PR progress prints on stderr and flows to
# the user; only its single stdout token is captured here.
land_one() {
  local num="$1" result
  result=$(LAND_METHOD="$METHOD" LAND_POLL="$POLL" LAND_MAX_HOLD="$PR_TIMEOUT" \
           LAND_MAX_RETRY="$MAX_RETRY" LAND_LEASE_TTL="$LEASE_TTL" \
           LAND_LEASE_DIR="$LEASE_DIR" \
           "$LANDER" "$num")
  case "$result" in
    landed:*)                                echo "merged" ;;
    eject:closed-unmerged)                   echo "skip:already-closed" ;;
    error:pr-not-found|error:pr-unreadable)  echo "skip:not-found" ;;
    eject:*)                                 echo "eject:${result#eject:}" ;;
    error:*)                                 echo "eject:${result#error:}" ;;
    *)                                       echo "eject:unknown-result-${result:-empty}" ;;
  esac
}

# --- build the queue ----------------------------------------------------------
SKIPPED_PRE=()   # dropped before the train (dirty/failing/draft at discovery)
if [ "${#PRS[@]}" -eq 0 ]; then
  # Auto-discover: open, non-draft, GREEN PRs — regardless of auto-merge arming
  # (issue #73). This fleet's workers /fleet-ship and leave PRs for the steward to
  # /fleet-land; they never arm auto-merge, so an armed-only filter made no-arg
  # discovery a dead path (reported "nothing to do" even with landable PRs open).
  # No-arg /fleet-land-train now means "drain the ready queue" — the batch complement
  # to single-PR /fleet-land. Pre-filter the ones that would only eject (DIRTY /
  # CONFLICTING / required-check-failing / draft) so the queue is the PRs with a
  # real shot; PENDING PRs stay queued (they may go green). Ascending = FIFO.
  while IFS=$'\t' read -r n verdict; do
    [ -z "$n" ] && continue
    case "$verdict" in
      queue) PRS+=("$n") ;;
      *)     SKIPPED_PRE+=("#$n ($verdict)") ;;
    esac
  done < <(
    # jq expressions use $-bound variables ($c/$ck) — single-quoted on purpose.
    # shellcheck disable=SC2016
    gh pr list --repo "$REPO" --state open --limit 100 \
      --json number,isDraft,mergeable,mergeStateStatus,statusCheckRollup \
      --jq '.[] |
            (.statusCheckRollup // []) as $c |
            (if $c|length==0 then "none"
             elif ($c|any(.conclusion=="FAILURE" or .conclusion=="CANCELLED"
                          or .conclusion=="TIMED_OUT" or .conclusion=="ACTION_REQUIRED")) then "fail"
             elif ($c|any(.status!="COMPLETED")) then "pending" else "pass" end) as $ck |
            (.number|tostring) + "\t" + (
              if .isDraft then "draft"
              elif .mergeable=="CONFLICTING" or .mergeStateStatus=="DIRTY" then "dirty"
              elif (.mergeStateStatus=="BLOCKED" and $ck=="fail") then "failing"
              else "queue" end)' 2>/dev/null | sort -t'	' -k1,1n
  )
fi

if [ "${#PRS[@]}" -eq 0 ]; then
  note "land-train: nothing to do for $REPO — no open + non-draft + green PRs."
  [ "${#SKIPPED_PRE[@]}" -gt 0 ] && note "  pre-filtered: ${SKIPPED_PRE[*]}"
  exit 0
fi

note "land-train: repo=$REPO  queue=[${PRS[*]}]  method=$METHOD$([ "$DRY" = 1 ] && echo '  (dry-run)')"
[ "${#SKIPPED_PRE[@]}" -gt 0 ] && note "  pre-filtered (not queued): ${SKIPPED_PRE[*]}"

# --- dry-run: print the plan + each PR's current verdict, mutate nothing -------
# The verdict fold is the SHARED land_classify (bin/fleet-land-lease.sh) — the same
# taxonomy fleet-land.sh gates on, so the preview matches what the real land will do.
if [ "$DRY" = 1 ]; then
  note "  plan (serial, one PR hot at a time):"
  pos=0
  for num in "${PRS[@]}"; do
    pos=$((pos + 1))
    fields=$(pr_fields "$num")
    if [ -z "$fields" ]; then note "    $pos. #$num — not found"; continue; fi
    IFS=$'\t' read -r st mg ms dr ck <<<"$fields"
    cls=$(land_classify "$st" "$mg" "$ms" "$dr" "$ck")
    case "$cls" in
      READY)    act="merge now" ;;
      BEHIND)   act="update-branch → wait green → merge" ;;
      PENDING)  act="wait for checks → merge" ;;
      CONFLICT) act="EJECT (needs human rebase)" ;;
      FAILING)  act="EJECT (required check failed)" ;;
      BLOCKED)  act="EJECT (review required)" ;;
      DRAFT)    act="EJECT (draft)" ;;
      GONE)     act="skip (already closed)" ;;
      *)        act="$cls" ;;
    esac
    note "    $pos. #$num  [$ms/$ck]  → $act"
  done
  exit 0
fi

# --- run the train ------------------------------------------------------------
# No batch-level lease here: fleet-land.sh takes the SHARED per-repo land lease per
# PR (and holds it through that PR's green-wait), so the train stays single-writer
# at the merge while interlocking with /fleet-land + /fleet-land-self on one lock.
MERGED=(); EJECTED=(); SKIPPED=()
for num in "${PRS[@]}"; do
  note "▶ #$num"
  result=$(land_one "$num")
  case "$result" in
    merged)  MERGED+=("#$num");            note "  ✓ #$num merged" ;;
    eject:*) EJECTED+=("#$num (${result#eject:})"); note "  ✗ #$num ejected — ${result#eject:}" ;;
    skip:*)  SKIPPED+=("#$num (${result#skip:})");  note "  · #$num skipped — ${result#skip:}" ;;
  esac
done

# --- summary ------------------------------------------------------------------
note ""
note "land-train summary ($REPO):"
note "  merged:  ${#MERGED[@]}${MERGED:+  ${MERGED[*]}}"
note "  ejected: ${#EJECTED[@]}${EJECTED:+  ${EJECTED[*]}}"
note "  skipped: ${#SKIPPED[@]}${SKIPPED:+  ${SKIPPED[*]}}"
[ "${#EJECTED[@]}" -gt 0 ] && note "  → ejected PRs need a human (rebase / fix checks), then re-run land-train."
exit 0
