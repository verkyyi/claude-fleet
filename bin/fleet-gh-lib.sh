# fleet-gh-lib.sh — GitHub rate-limit detection + the REST fallback (issue #1042,
# EPIC #1262 C1; folds #946 #954).
#
# The account's GraphQL budget (5,000/hr, shared by every session on every login
# that uses the one token) runs out while REST keeps answering. Every `gh pr …` /
# `gh issue …` subcommand is GraphQL, so when it does, a worker could not merge a
# green PR (it parked ~50 min until the reset), fleet-pr-verdict.sh said "cannot
# read PR", dash-reap read a MERGED PR as unmerged, and the epic tick log could not
# be written. This file is the ONE place that:
#   * recognizes a limit from a call's OWN result — stderr / JSON text
#     (`graphql_rate_limit`, `API rate limit`, `secondary rate limit`). Never
#     `gh api rate_limit`: #946 #989 #1211 caught it reporting headroom while calls
#     were refused (EPIC #1262 共同约定 2);
#   * remembers it in a shared marker so the next caller skips the doomed call;
#   * does the same job over REST (`gh api repos/…`).
#
# SOURCED, not executed — like fleet-lib.sh it must not `set -u` / `pipefail`; it
# is safe under a `set -u` caller (every optional expansion is defaulted). It needs
# nothing else sourced first. GitHub helpers added by later EPIC members go HERE
# (共同约定 1), each in its own section.
#
# Marker (共同约定 3): $FLEET_STATE_DIR/gh-limit.<bucket>, bucket ∈ graphql | core |
# secondary; FLEET_STATE_DIR defaults to $FLEET_CONF_DIR/global. Content, one
# key=value per line:
#   reset=<epoch the limit is believed to lift>
#   source=<which caller saw it>
#   at=<epoch it was seen>
# Written tmp+rename (atomic); a marker whose reset has passed is simply ignored.
#
# Fault injection (共同约定 4): FLEET_GH_FAKE_LIMIT=<bucket>[,<bucket>…] (or `all`)
# makes that bucket read as limited WITHOUT calling gh and without writing the
# shared marker — so a test never manufactures a limit on the real account.
#
# Log: every limit seen, call skipped and fallback completed appends one line to
# $FLEET_GH_LOG (default <install>/logs/gh-limit.log) — the limited→fallback-ok
# interval is the EPIC's «longest a worker waits under a limit» metric.
#
# API
#   fleet_gh_limit_bucket <text>         print graphql|core|secondary if <text> is a
#                                        rate-limit refusal; rc 1 if it is not
#   fleet_gh_limited <bucket>            rc 0 (+ print reset epoch or `fake`) while
#                                        <bucket> or `secondary` is limited
#   fleet_gh_mark_limited <bucket> [reset] [source]
#   fleet_gh_run <bucket> <source> <gh args…>
#                                        run gh unless <bucket> is known-limited;
#                                        rc $FLEET_GH_LIMITED_RC (75) = rate-limited
#                                        (marked, logged) → take the fallback; any
#                                        other non-zero rc replays gh's stderr
#   fleet_gh_rest_pr_view <repo> <pr>    the six lines fleet-pr-verdict.sh reads
#   fleet_gh_rest_merge <repo> <pr> <method> [--delete-branch]
#   fleet_gh_rest_comment <repo> <issue> <body-file>   → prints the comment URL
#   fleet_gh_rest_issue_close <repo> <issue>
#   fleet_gh_merged_heads <repo> <branch>  merged-PR head refs (GraphQL → REST)

FLEET_GH_LIMITED_RC=75
_FLEET_GH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

fleet_gh_state_dir() {
  local d="${FLEET_STATE_DIR:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/global}"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null
  printf '%s' "$d"
}

fleet_gh_log() {  # fleet_gh_log <event> [k=v …] — best effort, never fails a caller
  local f="${FLEET_GH_LOG:-${_FLEET_GH_LIB_DIR:-.}/../logs/gh-limit.log}"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$f" 2>/dev/null
  return 0
}

fleet_gh_fake_limited() {
  case ",${FLEET_GH_FAKE_LIMIT:-}," in
    ,,) return 1 ;;
    *",${1:-},"*|*,all,*) return 0 ;;
  esac
  return 1
}

# Classify a gh error text. Secondary first (its message also says "rate limit"),
# then GraphQL (gh prints `GraphQL: API rate limit …`; the raw JSON carries
# `graphql_rate_limit` / "type":"RATE_LIMIT"), else any other rate limit is core.
fleet_gh_limit_bucket() {
  local t="${1:-}"
  case "$t" in
    *[Ss]econdary\ rate\ limit*)                        echo secondary ;;
    *graphql_rate_limit*|*GraphQL:*[Rr]ate\ limit*|*'"RATE_LIMIT"'*) echo graphql ;;
    *[Rr]ate\ limit\ exceeded*|*[Rr]ate\ limit\ already\ exceeded*) echo core ;;
    *) return 1 ;;
  esac
}

fleet_gh_limited() {  # fleet_gh_limited <bucket>
  local b="${1:-graphql}" k f reset now
  now=$(date +%s)
  for k in "$b" secondary; do
    if fleet_gh_fake_limited "$k"; then echo fake; return 0; fi
    f="$(fleet_gh_state_dir)/gh-limit.$k"
    [ -f "$f" ] || continue
    reset=$(sed -n 's/^reset=//p' "$f" 2>/dev/null | head -1)
    case "$reset" in ''|*[!0-9]*) continue ;; esac
    [ "$reset" -gt "$now" ] && { echo "$reset"; return 0; }
  done
  return 1
}

# Without a reset from the response, hold the marker FLEET_GH_LIMIT_HOLD_SECS
# (default 600s; 60s for secondary). Holding only skips the doomed GraphQL call —
# the REST fallback still runs — so a short hold costs one refused call per hold.
fleet_gh_mark_limited() {  # fleet_gh_mark_limited <bucket> [reset-epoch] [source]
  local b="${1:-graphql}" reset="${2:-}" src="${3:-${0##*/}}" now d tmp hold
  case "$b" in graphql|core|secondary) ;; *) return 1 ;; esac
  now=$(date +%s)
  hold="${FLEET_GH_LIMIT_HOLD_SECS:-600}"; [ "$b" = secondary ] && hold=60
  case "$hold" in ''|*[!0-9]*) hold=600 ;; esac
  case "$reset" in ''|*[!0-9]*) reset=$((now + hold)) ;; esac
  d=$(fleet_gh_state_dir)
  tmp="$d/.gh-limit.$b.$$"
  printf 'reset=%s\nsource=%s\nat=%s\n' "$reset" "${src//[$'\n']/ }" "$now" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$d/gh-limit.$b" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

fleet_gh_run() {  # fleet_gh_run <bucket> <source> <gh args…>
  local b="${1:-graphql}" src="${2:-gh}" err rc errtxt hit
  shift 2
  if fleet_gh_limited "$b" >/dev/null; then
    fleet_gh_log "skip bucket=$b source=$src"
    return "$FLEET_GH_LIMITED_RC"
  fi
  err=$(mktemp "${TMPDIR:-/tmp}/fleet-gh-err.XXXXXX") || { gh "$@"; return $?; }
  gh "$@" 2>"$err"; rc=$?
  if [ "$rc" -eq 0 ]; then rm -f "$err"; return 0; fi
  errtxt=$(cat "$err" 2>/dev/null)
  if hit=$(fleet_gh_limit_bucket "$errtxt"); then
    rm -f "$err"
    fleet_gh_mark_limited "$hit" '' "$src"
    fleet_gh_log "limited bucket=$hit source=$src"
    return "$FLEET_GH_LIMITED_RC"
  fi
  cat "$err" >&2; rm -f "$err"
  return "$rc"
}

# --- REST equivalents ---------------------------------------------------------

# The same six lines fleet-pr-verdict.sh's GraphQL read emits — state, mergeable,
# mergeStateStatus, draft, checks, auto-merge — so one fold (land_verdict) judges
# both paths. REST's lowercase enums map 1:1 onto the GraphQL ones. The check
# fold mirrors the GraphQL statusCheckRollup one: check-runs + the combined
# commit status; none / fail / pending / pass. A MERGED/CLOSED PR skips the check
# reads (the verdict ignores them) — two calls saved under a budget squeeze.
fleet_gh_rest_pr_view() {  # fleet_gh_rest_pr_view <repo> <pr>
  local repo="$1" pr="$2" row st mg ms dr sha am runs stats ck
  # shellcheck disable=SC2016
  row=$(fleet_gh_run core pr-view api "repos/$repo/pulls/$pr" --jq '
          (if .merged then "MERGED" elif .state=="closed" then "CLOSED" else "OPEN" end),
          (if .mergeable==true then "MERGEABLE" elif .mergeable==false then "CONFLICTING" else "UNKNOWN" end),
          ((.mergeable_state // "") | ascii_upcase),
          (if .draft then "DRAFT" else "" end),
          (.head.sha // ""),
          (if .auto_merge then "AUTO" else "" end)') || return $?
  [ -n "$row" ] || return 1
  { read -r st; read -r mg; read -r ms; read -r dr; read -r sha; read -r am; } <<< "$row"
  ck=none
  if [ "$st" = OPEN ] && [ -n "$sha" ]; then
    runs=$(fleet_gh_run core pr-view api "repos/$repo/commits/$sha/check-runs?per_page=100" --jq '
             .check_runs[] |
             if (.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled"
                 or .conclusion=="action_required") then "fail"
             elif .status!="completed" then "pending" else "pass" end') || return $?
    stats=$(fleet_gh_run core pr-view api "repos/$repo/commits/$sha/status" --jq '
             .statuses[] |
             if (.state=="failure" or .state=="error") then "fail"
             elif .state=="pending" then "pending" else "pass" end') || return $?
    runs="$runs
$stats"
    if   printf '%s\n' "$runs" | grep -qx fail;    then ck=fail
    elif printf '%s\n' "$runs" | grep -qx pending; then ck=pending
    elif printf '%s\n' "$runs" | grep -qx pass;    then ck=pass
    fi
  fi
  printf '%s\n' "$st" "$mg" "$ms" "$dr" "$ck" "$am"
}

# Merge over REST, pinned to the head sha it reads (a push that lands between the
# read and the PUT makes GitHub refuse rather than merge unverified code), and
# delete the head branch ONLY after GitHub says merged — never on a failed merge
# (issue #544). The caller owns the green gate: this function merges, it does not
# judge (bin/fleet-pr-merge.sh reads the verdict first).
fleet_gh_rest_merge() {  # fleet_gh_rest_merge <repo> <pr> <method> [--delete-branch]
  local repo="$1" pr="$2" method="${3:-squash}" del="${4:-}" head sha ref same merged
  # shellcheck disable=SC2016
  head=$(fleet_gh_run core merge api "repos/$repo/pulls/$pr" \
           --jq '(.head.sha // ""), (.head.ref // ""), (if .head.repo.full_name == .base.repo.full_name then "same" else "" end)') || return $?
  { read -r sha; read -r ref; read -r same; } <<< "$head"
  [ -n "$sha" ] || return 1
  merged=$(fleet_gh_run core merge api -X PUT "repos/$repo/pulls/$pr/merge" \
             -f "merge_method=$method" -f "sha=$sha" --jq '.merged') || return $?
  [ "$merged" = true ] || return 1
  if [ "$del" = --delete-branch ] && [ -n "$ref" ] && [ "$same" = same ]; then
    fleet_gh_run core merge api -X DELETE "repos/$repo/git/refs/heads/$ref" >/dev/null \
      || printf 'fleet-gh: merged #%s, but deleting branch %s failed (harmless)\n' "$pr" "$ref" >&2
  fi
  return 0
}

fleet_gh_rest_comment() {  # fleet_gh_rest_comment <repo> <issue> <body-file>
  fleet_gh_run core comment api "repos/$1/issues/$2/comments" -F "body=@$3" --jq '.html_url'
}

fleet_gh_rest_issue_close() {  # fleet_gh_rest_issue_close <repo> <issue>
  fleet_gh_run core comment api -X PATCH "repos/$1/issues/$2" -f state=closed --jq '.html_url'
}

# Head refs of MERGED PRs for <branch> — the `gh pr list --state merged --head`
# answer dash-reap's merged-check reads, with the REST fallback. Same argv as the
# pre-#1042 call on the healthy path. REST's `head=` filter wants owner:branch;
# a fleet branch is pushed to the repo itself, so the owner is the repo's.
fleet_gh_merged_heads() {  # fleet_gh_merged_heads <repo> <branch>
  local repo="$1" branch="$2" out rc
  out=$(fleet_gh_run graphql reap -R "$repo" pr list --state merged --head "$branch" \
          --json headRefName -q '.[].headRefName'); rc=$?
  if [ "$rc" -eq 0 ]; then [ -n "$out" ] && printf '%s\n' "$out"; return 0; fi
  [ "$rc" -eq "$FLEET_GH_LIMITED_RC" ] || return "$rc"
  out=$(fleet_gh_run core reap api "repos/$repo/pulls?state=closed&head=${repo%%/*}:$branch&per_page=100" \
          --jq '.[] | select(.merged_at != null) | .head.ref') || return $?
  fleet_gh_log "fallback-ok op=merged-heads repo=$repo branch=$branch"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}
