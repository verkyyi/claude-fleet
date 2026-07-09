#!/bin/bash
# merge-train.sh [--dry-run] [--method squash|merge|rebase] [pr...] — a serial,
# single-writer "merge train" for a fleet repo with `strict:true` branch
# protection and NO merge queue. It merges a set of PRs ONE AT A TIME: only the
# PR at the head of the queue is ever made "hot" (update-branch + wait-for-green
# + merge), so each PR is tested exactly once against the master it actually
# lands on — O(N) CI instead of the O(N²) thundering herd you get from updating
# every PR in parallel every time master moves.
#
# Design (see issue #62):
#   lease acquire            one train per repo (advisory file lock, steal-if-stale)
#   queue = green+armed PRs  DIRTY / failing are pre-filtered out (or ejected)
#   for pr in queue:
#     update-branch pr       only when it's this PR's turn (never the tail early)
#     wait green+up-to-date  poll until CLEAN; eject on conflict / check-fail / timeout
#     merge pr               --match-head-commit guards the head-sha race
#   lease release            (EXIT trap)
#
# A bad PR never blocks the train: it is EJECTED with a reason and the train
# continues. Nothing is force-anything; every mutation is a plain `gh` call
# against $FLEET_REPO only (never a cwd-default repo). `--dry-run` prints the
# plan and current per-PR state and mutates nothing (and takes no lease).
#
# Env knobs (all optional):
#   MERGE_TRAIN_METHOD      squash|merge|rebase           (default squash)
#   MERGE_TRAIN_POLL        seconds between state polls    (default 15)
#   MERGE_TRAIN_PR_TIMEOUT  per-PR budget, seconds         (default 1800)
#   MERGE_TRAIN_MAX_RETRY   bounded retries for behind/race (default 3)
#   MERGE_TRAIN_LEASE_TTL   lease lifetime, seconds        (default 3600)
#   MERGE_TRAIN_LEASE_DIR   lease dir            (default ~/.claude/leases)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

# --- args ---------------------------------------------------------------------
DRY=0
METHOD="${MERGE_TRAIN_METHOD:-squash}"
PRS=()
usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}
# Add a PR arg, warning (not silently scrubbing) on non-numeric input: a fat-
# fingered "#65" / "65 " is accepted with a note; a genuinely non-numeric arg
# ("main", "--foo" that slipped past) is DROPPED loudly, never silently → "".
add_pr_arg() {
  local raw="$1" clean="${1//[^0-9]/}"
  if [ -z "$clean" ]; then
    printf 'merge-train: ignoring non-numeric PR arg %s\n' "$raw" >&2; return
  fi
  [ "$raw" != "$clean" ] && printf 'merge-train: reading PR arg %s as #%s\n' "$raw" "$clean" >&2
  PRS+=("$clean")
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    --method|-m)  shift; METHOD="${1:-squash}" ;;
    -h|--help)    usage 0 ;;
    --)           shift; while [ "$#" -gt 0 ]; do add_pr_arg "$1"; shift; done; break ;;
    -*)           printf 'merge-train: unknown flag %s\n' "$1" >&2; usage 1 ;;
    *)            add_pr_arg "$1" ;;
  esac
  shift
done
case "$METHOD" in squash|merge|rebase) ;; *) printf 'merge-train: bad --method %s\n' "$METHOD" >&2; exit 1 ;; esac

POLL="${MERGE_TRAIN_POLL:-15}"
PR_TIMEOUT="${MERGE_TRAIN_PR_TIMEOUT:-1800}"
MAX_RETRY="${MERGE_TRAIN_MAX_RETRY:-3}"
LEASE_TTL="${MERGE_TRAIN_LEASE_TTL:-3600}"
LEASE_DIR="${MERGE_TRAIN_LEASE_DIR:-$HOME/.claude/leases}"

# --- resolve the fleet repo (this fleet only — never a cwd default) -----------
FLEET_SESSION=$(fleet_current_session)
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
[ -z "$REPO" ] && { printf 'merge-train: no repo resolved — run inside a fleet (FLEET_REPO unset).\n' >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { printf 'merge-train: gh not found on PATH.\n' >&2; exit 1; }

# All human-facing progress goes to STDERR — process_pr's result token is the
# ONLY thing on stdout, so `result=$(process_pr …)` captures just that token and
# never the interleaved progress lines. (issue #68: note() on stdout polluted
# the capture → every `case "$result"` missed → summary counts stuck at 0.)
note() { printf '%s\n' "$*" >&2; }

# --- lease: one train per repo -----------------------------------------------
LEASE="$LEASE_DIR/merge-train-$(fleet_slug "$REPO").lock"
LEASE_HELD=0
lease_acquire() {
  mkdir -p "$LEASE_DIR" 2>/dev/null
  local now ttl me holder exp
  now=$(date +%s); ttl="$LEASE_TTL"
  me="${FLEET_SESSION:-$USER}:$$@$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
  if mkdir "$LEASE" 2>/dev/null; then
    printf '%s\n%s\n' "$me" "$((now + ttl))" > "$LEASE/holder"
    LEASE_HELD=1; return 0
  fi
  holder=$(sed -n 1p "$LEASE/holder" 2>/dev/null)
  exp=$(sed -n 2p "$LEASE/holder" 2>/dev/null); exp="${exp//[^0-9]/}"; exp="${exp:-0}"
  if [ "$now" -ge "$exp" ]; then           # stale → steal
    rm -rf "$LEASE" 2>/dev/null
    if mkdir "$LEASE" 2>/dev/null; then
      printf '%s\n%s\n' "$me" "$((now + ttl))" > "$LEASE/holder"
      LEASE_HELD=1; note "merge-train: stole stale lease (was ${holder:-?})"; return 0
    fi
  fi
  printf 'merge-train: a train is already running for %s (held by %s) — one train per repo.\n' \
    "$REPO" "${holder:-?}" >&2
  return 1
}
# Release the lease on EXIT *and* on Ctrl-C / kill — otherwise a signal mid-run
# leaves the lockdir until the TTL steal (a ~1h block on the next run). Idempotent
# (LEASE_HELD flips to 0), so the INT/TERM path re-triggering EXIT is a no-op.
# shellcheck disable=SC2329  # invoked indirectly via the trap lines below
lease_release() { [ "$LEASE_HELD" = 1 ] && rm -rf "$LEASE" 2>/dev/null; LEASE_HELD=0; }
trap lease_release EXIT
trap 'lease_release; exit 130' INT
trap 'lease_release; exit 143' TERM

# --- PR state -----------------------------------------------------------------
# Prints TSV: state  mergeable  mergeStateStatus  draftflag  checks  headOid
# checks ∈ pass|fail|pending|none (fold of statusCheckRollup, required+optional).
pr_fields() {
  gh pr view "$1" --repo "$REPO" \
    --json state,mergeable,mergeStateStatus,isDraft,statusCheckRollup,headRefOid \
    --jq '[.state, .mergeable, .mergeStateStatus,
           (if .isDraft then "DRAFT" else "-" end),
           ((.statusCheckRollup // []) |
             if length==0 then "none"
             elif any(.conclusion=="FAILURE" or .conclusion=="CANCELLED"
                      or .conclusion=="TIMED_OUT" or .conclusion=="ACTION_REQUIRED") then "fail"
             elif any(.status!="COMPLETED") then "pending"
             else "pass" end),
           .headRefOid] | @tsv' 2>/dev/null
}

# Fold (state,mergeable,mss,draft,checks) → one verdict the loop switches on.
#   GONE     not open (already merged/closed)      → skip
#   DRAFT    draft                                 → eject
#   CONFLICT CONFLICTING / DIRTY                   → eject (needs human rebase)
#   FAILING  a REQUIRED check is red               → eject
#   BLOCKED  mergeable-blocked, checks green (review required / other) → eject
#   BEHIND   out of date w/ base                   → update-branch, then wait
#   PENDING  checks still running / unknown        → wait
#   READY    green + up to date                    → merge
classify() {
  local st="$1" mg="$2" ms="$3" dr="$4" ck="$5"
  [ "$st" != OPEN ]     && { echo GONE;     return; }
  [ "$dr" = DRAFT ]     && { echo DRAFT;    return; }
  [ "$mg" = CONFLICTING ] && { echo CONFLICT; return; }
  case "$ms" in
    DIRTY)          echo CONFLICT ;;
    BEHIND)         echo BEHIND ;;
    CLEAN|HAS_HOOKS) echo READY ;;
    UNSTABLE)       echo READY ;;  # mergeable: at worst a NON-required check is red (a required red ⇒ BLOCKED)
    BLOCKED)        case "$ck" in fail) echo FAILING ;; pending|none) echo PENDING ;; *) echo BLOCKED ;; esac ;;
    *)              case "$ck" in fail) echo FAILING ;; *) echo PENDING ;; esac ;;  # UNKNOWN → give CI a beat
  esac
}

# --- run one PR through the train. Prints "merged" | "eject:<why>" | "skip:<why>".
process_pr() {
  # Two independent, bounded budgets: one for BEHIND update-branch retries, one
  # for merge head-sha-race retries. A single shared counter (issue #73) let one
  # failure mode burn the other's budget under mixed churn — each mode now gets
  # its own MAX_RETRY.
  local num="$1" behind_retry=0 merge_retry=0 fields cls st mg ms dr ck oid out
  SECONDS=0
  while [ "$SECONDS" -lt "$PR_TIMEOUT" ]; do
    fields=$(pr_fields "$num")
    [ -z "$fields" ] && { echo "skip:not-found"; return; }
    IFS=$'\t' read -r st mg ms dr ck oid <<<"$fields"
    cls=$(classify "$st" "$mg" "$ms" "$dr" "$ck")
    case "$cls" in
      GONE)     echo "skip:already-closed"; return ;;
      DRAFT)    echo "eject:draft"; return ;;
      CONFLICT) echo "eject:conflict-needs-rebase"; return ;;
      FAILING)  echo "eject:required-check-failed"; return ;;
      BLOCKED)  echo "eject:blocked-review-required"; return ;;
      BEHIND)
        behind_retry=$((behind_retry + 1))
        if [ "$behind_retry" -gt "$MAX_RETRY" ]; then echo "eject:stuck-behind"; return; fi
        note "  #$num behind master — update-branch (attempt $behind_retry/$MAX_RETRY)"
        gh pr update-branch "$num" --repo "$REPO" >/dev/null 2>&1 || true
        sleep "$(backoff "$behind_retry")" ;;
      PENDING)
        note "  #$num checks pending — waiting ${POLL}s"
        sleep "$POLL" ;;
      READY)
        note "  #$num green + up to date — merging (--$METHOD)"
        if out=$(gh pr merge "$num" --repo "$REPO" "--$METHOD" \
                   --match-head-commit "$oid" 2>&1); then
          echo "merged"; return
        fi
        merge_retry=$((merge_retry + 1))
        if [ "$merge_retry" -gt "$MAX_RETRY" ]; then
          echo "eject:merge-failed"; return
        fi
        note "  #$num merge lost the head-sha race — retry $merge_retry/$MAX_RETRY (${out##*$'\n'})"
        sleep "$(backoff "$merge_retry")" ;;
    esac
  done
  echo "eject:timeout-${PR_TIMEOUT}s"
}

# capped exponential backoff (POLL, 2·POLL, … ≤ 60s)
backoff() { local b=$(( POLL * $1 )); [ "$b" -gt 60 ] && b=60; printf '%s' "$b"; }

# --- build the queue ----------------------------------------------------------
SKIPPED_PRE=()   # dropped before the train (dirty/failing/draft at discovery)
if [ "${#PRS[@]}" -eq 0 ]; then
  # Auto-discover: open, non-draft, GREEN PRs — regardless of auto-merge arming
  # (issue #73). This fleet's workers /ship and leave PRs for the steward to
  # /land; they never arm auto-merge, so an armed-only filter made no-arg
  # discovery a dead path (reported "nothing to do" even with landable PRs open).
  # No-arg /merge-train now means "drain the ready queue" — the batch complement
  # to single-PR /land. Pre-filter the ones that would only eject (DIRTY /
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
  note "merge-train: nothing to do for $REPO — no open + non-draft + green PRs."
  [ "${#SKIPPED_PRE[@]}" -gt 0 ] && note "  pre-filtered: ${SKIPPED_PRE[*]}"
  exit 0
fi

note "merge-train: repo=$REPO  queue=[${PRS[*]}]  method=$METHOD$([ "$DRY" = 1 ] && echo '  (dry-run)')"
[ "${#SKIPPED_PRE[@]}" -gt 0 ] && note "  pre-filtered (not queued): ${SKIPPED_PRE[*]}"

# --- dry-run: print the plan + each PR's current verdict, mutate nothing -------
if [ "$DRY" = 1 ]; then
  note "  plan (serial, one PR hot at a time):"
  pos=0
  for num in "${PRS[@]}"; do
    pos=$((pos + 1))
    fields=$(pr_fields "$num")
    if [ -z "$fields" ]; then note "    $pos. #$num — not found"; continue; fi
    IFS=$'\t' read -r st mg ms dr ck oid <<<"$fields"
    cls=$(classify "$st" "$mg" "$ms" "$dr" "$ck")
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
lease_acquire || exit 1

MERGED=(); EJECTED=(); SKIPPED=()
for num in "${PRS[@]}"; do
  note "▶ #$num"
  result=$(process_pr "$num")
  case "$result" in
    merged)  MERGED+=("#$num");            note "  ✓ #$num merged" ;;
    eject:*) EJECTED+=("#$num (${result#eject:})"); note "  ✗ #$num ejected — ${result#eject:}" ;;
    skip:*)  SKIPPED+=("#$num (${result#skip:})");  note "  · #$num skipped — ${result#skip:}" ;;
  esac
done

# --- summary ------------------------------------------------------------------
note ""
note "merge-train summary ($REPO):"
note "  merged:  ${#MERGED[@]}${MERGED:+  ${MERGED[*]}}"
note "  ejected: ${#EJECTED[@]}${EJECTED:+  ${EJECTED[*]}}"
note "  skipped: ${#SKIPPED[@]}${SKIPPED:+  ${SKIPPED[*]}}"
[ "${#EJECTED[@]}" -gt 0 ] && note "  → ejected PRs need a human (rebase / fix checks), then re-run merge-train."
exit 0
