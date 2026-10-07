#!/bin/bash
# fleet-gh.sh — read an issue / PR / PR's checks from the fleet's local copy first,
# GitHub only when that copy is too old (issue #1263, EPIC #1262 C3).
#
#   fleet-gh.sh issue view <N> [--repo R] [--json f1,f2] [--max-age S]
#   fleet-gh.sh pr view    <N> [--repo R] [--json f1,f2] [--max-age S]
#   fleet-gh.sh pr checks  <N> [--repo R] [--json f1,f2] [--max-age S]
#
# The daemons already poll GitHub for every repo a fleet hosts — the collector
# every ~60-90s (open issues), pr-refresh every ~15s (every PR's state + CI) — and
# 18-30 workers were re-fetching the same facts with `gh issue view` / `gh pr view`
# on the one shared GraphQL budget, so a limit stopped everyone at once (#954).
# This reads those caches; it never WRITES one (the collector / pr-refresh stay the
# single writers).
#
# Output is always ONE JSON object: the requested fields under the names
# `gh … --json` uses, plus
#   _source  cache | gh | rest      where the answer came from
#   _age     seconds since that copy was fetched (0 for a live read)
# so `fleet-gh.sh issue view 5 --json title,state | jq -r .title` works whatever
# the source. Order of attempts:
#   1. cache — served only when EVERY requested field is in it and it is no older
#      than --max-age (default 120s for an issue, 30s for a PR / checks; 0 = skip):
#        issue  the spawn snapshot of THIS worktree's issue (fleet-issue-cache.py:
#               number title state url body labels comments; ≤120s by design), else
#               the collector's open-issue list (fleets/<slug>/issues + labels:
#               number title state labels milestone, assignees unless clipped).
#               An issue missing from the list (closed, never existed) is a miss,
#               never a guess.
#        pr     fleets/<slug>/prmap: number headRefName state mergeCommit.
#        checks the prmap's CI column → the rollup `bucket` only.
#      Age = the cache FILE's mtime (each is replaced by mv on a good fetch), not
#      its .ts stamp — the daemons stamp .ts on a FAILED fetch too.
#      pr / checks with this repo's webhook forward live (issue #1272): an older
#      prmap still serves while no delivery for #N has landed since it was
#      written — the event stamps fleet-webhook.sh leaves — up to
#      FLEET_GH_WH_MAX_AGE (300s). A change, not a clock, is what makes it stale.
#   2. gh — `gh issue view|pr view|pr checks <N> --repo R --json <fields>`, through
#      fleet_gh_run (fleet-gh-lib.sh): a known GraphQL limit skips the doomed call.
#   3. rest — on a GraphQL limit, the same fields over `gh api repos/…`. A field
#      REST has no equivalent for comes back null, named on stderr.
#
# Keyed by (repo, N), never a bare number: the cache dir is the repo's slug, so a
# 2-repo fleet never answers repo A's #5 with repo B's. Repo: --repo, else
# $CF_REPO, else (a 2+ repo fleet) the calling window's repo, else this fleet's
# cached repo, else FLEET_REPO — as bin/fleet-issue-file.sh resolves it.
#
# `pr checks`: no --json → {bucket} (pass | fail | pending | none — the rollup, same
# fold as the dash's CI glyph). With --json → also `checks`, one row per check with
# those fields (gh / rest only — the cache holds the rollup, not the rows).
#
# Defaults without --json: issue → number,title,state · pr → number,headRefName,state.
# Exit: 0 answered · 1 gh/rest failed (its stderr replayed) · 2 usage / no repo /
# no gh. Without jq on PATH it runs plain `gh` with your arguments (no cache).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-gh-lib.sh"

die() { printf 'fleet-gh: %s\n' "$1" >&2; exit 2; }

[ "$#" -ge 2 ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
case "$1 $2" in
  "issue view") kind=issue ;;
  "pr view")    kind="pr" ;;
  "pr checks")  kind=checks ;;
  -h*|--help*)  sed -n '2,54p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unsupported: $1 $2 (issue view | pr view | pr checks)" ;;
esac
sub1=$1 sub2=$2; shift 2
N='' repo='' fields='' max_age='' JSON_GIVEN=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|-R) shift; repo="${1:-}" ;;
    --json)    shift; fields="${1:-}"; JSON_GIVEN=1 ;;
    --max-age) shift; max_age="${1:-}" ;;
    -h|--help) sed -n '2,54p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown flag $1" ;;
    *)         N="${1##*/}"; N="${N#\#}" ;;   # 12, #12, or a …/issues/12 URL
  esac
  shift
done
case "$N" in ''|*[!0-9]*) die "an issue/PR number is required" ;; esac
[ -n "$max_age" ] || { [ "$kind" = issue ] && max_age=120 || max_age=30; }
case "$max_age" in *[!0-9]*) die "--max-age must be whole seconds (got $max_age)" ;; esac

repo="${repo:-${CF_REPO:-}}"
_fs=$(fleet_current_session)
# The one rule (issue #1943): the calling window's repo, else the fleet's only
# one; several and no window repo ⇒ refuse rather than guess.
if [ -z "$repo" ] && [ -n "$_fs" ]; then
  _rc=0; repo=$(fleet_target_repo "$_fs") || _rc=$?
  [ "$_rc" = 4 ] && die "this fleet hosts several repos — pass --repo <owner/name>"
fi
[ -n "$repo" ] || repo="${FLEET_REPO:-}"   # outside a fleet: the conf's
[ -n "$repo" ] || die "no repo resolved (set --repo or FLEET_REPO)"
repo=$(fleet_norm_repo "$repo")

if ! command -v jq >/dev/null 2>&1; then
  command -v gh >/dev/null 2>&1 || die "gh not on PATH"
  set -- "$sub1" "$sub2" "$N" --repo "$repo"
  [ -n "$fields" ] && set -- "$@" --json "$fields"
  exec gh "$@"
fi

if [ -z "$fields" ]; then
  case "$kind" in issue) fields=number,title,state ;; pr) fields=number,headRefName,state ;; esac
fi
fields="${fields// /}"
# JSON array of the requested names, for jq's field pick
want=$(jq -nc --arg f "$fields" '$f | split(",") | map(select(length>0))')

# has_all <space-separated available fields> — every requested field is in it
has_all() {
  local f
  for f in ${fields//,/ }; do
    case " $1 " in *" $f "*) ;; *) return 1 ;; esac
  done
  return 0
}
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
NOW=$(date +%s)
FD="$FLEET_C/fleets/$(fleet_slug "$repo")"

# emit <source> <age> — stdin: an object holding at least the requested fields
emit() {
  jq -c --argjson w "$want" --arg s "$1" --argjson a "$2" '
    with_entries(select(.key as $k | ($w | index($k)) != null or $k == "checks" or $k == "bucket"))
    + {_source: $s, _age: $a}'
}

# --- 1. the cache -------------------------------------------------------------
cache_issue() {
  local snap age line mil asg title labels have
  # the spawn snapshot — only THIS worktree's own issue, ≤120s old by construction
  if has_all "number title state url body labels comments" \
     && snap=$(python3 "$BIN/fleet-issue-cache.py" json "$PWD" "$repo" "$N" 2>/dev/null); then
    age=$(printf '%s' "$snap" | jq -r .age)
    if [ "$age" -le "$max_age" ]; then
      printf '%s' "$snap" | jq -c '.issue' | emit cache "$age"; return 0
    fi
  fi
  [ -f "$FD/issues" ] || return 1
  age=$(( NOW - $(mtime "$FD/issues") )); [ "$age" -lt 0 ] && age=0
  [ "$age" -le "$max_age" ] || return 1
  # milestone<TAB>#num<TAB>assignee<TAB>title (a tab inside a title stays in it)
  line=$(awk -F'\t' -v n="#$N" '$2==n {print; exit}' "$FD/issues" 2>/dev/null)
  [ -n "$line" ] || return 1
  mil="${line%%$'\t'*}"; line="${line#*$'\t'}"; line="${line#*$'\t'}"
  asg="${line%%$'\t'*}"; title="${line#*$'\t'}"
  have="number title state milestone"
  # the collector clips the joined logins to 10 chars: a 10-char value may be cut
  [ "${#asg}" -lt 10 ] && have="$have assignees"
  labels=''
  if [ -f "$FD/labels" ] && [ $(( NOW - $(mtime "$FD/labels") )) -le "$max_age" ]; then
    labels=$(awk -F'\t' -v n="$N" '$1==n {print $2; f=1; exit} END {exit !f}' "$FD/labels" 2>/dev/null) \
      && have="$have labels"
  fi
  has_all "$have" || return 1
  jq -nc --argjson n "$N" --arg t "$title" --arg m "$mil" --arg a "$asg" --arg l "$labels" '
    {number: $n, title: $t, state: "OPEN",
     milestone: (if $m == "· no milestone" or $m == "" then null else {title: $m} end),
     assignees: (if $a == "·" or $a == "" then [] else ($a | split(",") | map({login: .})) end),
     labels: ($l | split(",") | map(select(length>0) | {name: .}))}' | emit cache "$age"
}

# wh_current <cache-mtime> <age> — an older copy is still CURRENT when the
# webhook is forwarding this repo and no delivery for #N (or the repo) landed
# since that copy was written — 10s of margin for a fetch already in flight when
# the event came — up to FLEET_GH_WH_MAX_AGE (default 300s) (issue #1272).
wh_current() {
  local cap="${FLEET_GH_WH_MAX_AGE:-300}" st e
  case "$cap" in ''|*[!0-9]*) cap=300 ;; esac
  [ "$2" -le "$cap" ] && fleet_wh_live "$repo" || return 1
  st=$(fleet_wh_sig "$repo" "$N")
  for e in "${st%%|*}" "${st#*|}"; do
    e=${e%% *}; case "$e" in ''|*[!0-9]*) continue ;; esac
    [ $((e + 10)) -le "$1" ] || return 1
  done
  return 0
}

# prmap: branch<TAB>#num<TAB>state<TAB>ci<TAB>ready<TAB>merge-sha
prmap_row() {
  local age mt
  [ -f "$FD/prmap" ] || return 1
  mt=$(mtime "$FD/prmap"); age=$(( NOW - mt )); [ "$age" -lt 0 ] && age=0
  [ "$age" -le "$max_age" ] || wh_current "$mt" "$age" || return 1
  PR_ROW=$(awk -F'\t' -v n="#$N" '$2==n {print; exit}' "$FD/prmap" 2>/dev/null)
  [ -n "$PR_ROW" ] || return 1
  PR_AGE=$age
}

cache_pr() {
  has_all "number headRefName state mergeCommit" || return 1
  prmap_row || return 1
  printf '%s\n' "$PR_ROW" | jq -Rc --argjson n "$N" 'split("\t") |
    {number: $n, headRefName: .[0], state: .[2],
     mergeCommit: (if (.[5] // "") == "" then null else {oid: .[5]} end)}' | emit cache "$PR_AGE"
}

cache_checks() {
  [ -z "$JSON_GIVEN" ] || return 1      # rows were asked for — the cache has none
  prmap_row || return 1
  printf '%s\n' "$PR_ROW" | jq -Rc 'split("\t") | .[3] as $c |
    {bucket: (if $c == "✓" then "pass" elif $c == "✗" then "fail"
              elif $c == "…" then "pending" else "none" end)}' | emit cache "$PR_AGE"
}

if [ "$max_age" -gt 0 ]; then
  case "$kind" in
    issue)  cache_issue  && exit 0 ;;
    pr)     cache_pr     && exit 0 ;;
    checks) cache_checks && exit 0 ;;
  esac
fi

# --- 2. gh (GraphQL) ----------------------------------------------------------
command -v gh >/dev/null 2>&1 || die "gh not on PATH"
ERR=$(mktemp "${TMPDIR:-/tmp}/fleet-gh-err.XXXXXX") || exit 1
trap 'rm -f "$ERR"' EXIT

# the rollup over gh's own bucket vocabulary (pass fail pending skipping cancel)
# shellcheck disable=SC2016
AGG='def agg: map(.bucket) as $b |
  if ($b|length) == 0 then "none"
  elif ($b|index("fail")) != null or ($b|index("cancel")) != null then "fail"
  elif ($b|index("pending")) != null then "pending" else "pass" end;'

if [ "$kind" = checks ]; then
  qf="${fields:+$fields,}bucket"
  out=$(fleet_gh_run graphql fleet-gh pr checks "$N" --repo "$repo" --json "$qf" 2>"$ERR"); rc=$?
  # gh pr checks exits 8 while pending and 1 when one failed — the JSON is the answer
  if [ "$rc" -ne "$FLEET_GH_LIMITED_RC" ] && printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s' "$out" | jq -c --argjson w "$want" "$AGG"'
      {bucket: agg} + (if ($w|length) > 0 then
        {checks: map(with_entries(select(.key as $k | ($w|index($k)) != null)))} else {} end)' | emit gh 0
    exit 0
  fi
  if [ "$rc" -ne "$FLEET_GH_LIMITED_RC" ] && grep -q 'no checks reported' "$ERR"; then
    if [ -n "$JSON_GIVEN" ]; then printf '{"bucket":"none","checks":[]}'; else printf '{"bucket":"none"}'; fi | emit gh 0
    exit 0
  fi
else
  out=$(fleet_gh_run graphql fleet-gh "$sub1" "$sub2" "$N" --repo "$repo" --json "$fields" 2>"$ERR"); rc=$?
  if [ "$rc" -eq 0 ]; then printf '%s' "$out" | emit gh 0; exit 0; fi
fi
if [ "$rc" -ne "$FLEET_GH_LIMITED_RC" ]; then cat "$ERR" >&2; exit 1; fi

# --- 3. REST (GraphQL limited) ------------------------------------------------
rest() { fleet_gh_run core fleet-gh api "$@" 2>"$ERR" || { cat "$ERR" >&2; exit 1; }; }
nulls() {  # warn about requested fields REST could not supply
  local miss
  miss=$(jq -r --argjson w "$want" '. as $o | [$w[] | . as $k | select(($o | has($k)) | not)] | join(",")' <<< "$1")
  [ -n "$miss" ] && printf 'fleet-gh: not available over REST (null): %s\n' "$miss" >&2
  return 0
}
# shellcheck disable=SC2016
COMMON='labels: [(.labels // [])[] | {name, color, description}],
  assignees: [(.assignees // [])[] | {login}],
  author: (if .user then {login: .user.login} else null end),
  createdAt: .created_at, updatedAt: .updated_at, closedAt: .closed_at,
  milestone: (if .milestone then {title: .milestone.title, number: .milestone.number,
              description: .milestone.description, dueOn: .milestone.due_on} else null end)'

case "$kind" in
  issue)
    obj=$(rest "repos/$repo/issues/$N" | jq -c '{number, title, body: (.body // ""), url: .html_url,
      state: (.state | ascii_upcase), stateReason: ((.state_reason // "") | ascii_upcase),
      '"$COMMON"'}') || exit 1
    case ",$fields," in *,comments,*)
      cm=$(rest "repos/$repo/issues/$N/comments?per_page=100" | jq -c '[.[] |
            {author: {login: .user.login}, body, createdAt: .created_at, url: .html_url}]') || exit 1
      obj=$(jq -c --argjson c "$cm" '. + {comments: $c}' <<< "$obj") ;;
    esac ;;
  pr|checks)
    obj=$(rest "repos/$repo/pulls/$N" | jq -c '{number, title, body: (.body // ""), url: .html_url,
      state: (if .merged then "MERGED" elif .state == "closed" then "CLOSED" else "OPEN" end),
      headRefName: .head.ref, headRefOid: .head.sha, baseRefName: .base.ref, isDraft: .draft,
      mergeable: (if .mergeable == true then "MERGEABLE" elif .mergeable == false then "CONFLICTING" else "UNKNOWN" end),
      mergeStateStatus: ((.mergeable_state // "") | ascii_upcase),
      mergedAt: .merged_at, mergeCommit: (if .merged then {oid: .merge_commit_sha} else null end),
      autoMergeRequest: (if .auto_merge then {mergeMethod: ((.auto_merge.merge_method // "") | ascii_upcase)} else null end),
      additions, deletions, changedFiles: .changed_files,
      '"$COMMON"'}') || exit 1 ;;
esac

if [ "$kind" = checks ]; then
  sha=$(jq -r '.headRefOid // ""' <<< "$obj")
  [ -n "$sha" ] || { printf 'fleet-gh: no head sha for PR #%s\n' "$N" >&2; exit 1; }
  # gh pr checks' row shape: a check-run's state is its conclusion once complete
  runs=$(rest "repos/$repo/commits/$sha/check-runs?per_page=100" | jq -c '[.check_runs[] |
    ((if .status == "completed" then (.conclusion // "") else .status end) | ascii_upcase) as $s |
    {name, state: $s, link: (.html_url // .details_url // ""), workflow: "",
     startedAt: .started_at, completedAt: .completed_at, description: (.output.title // ""), event: "",
     bucket: (if $s == "SUCCESS" then "pass" elif $s == "SKIPPED" or $s == "NEUTRAL" then "skipping"
              elif $s == "CANCELLED" then "cancel"
              elif ($s == "FAILURE" or $s == "ERROR" or $s == "TIMED_OUT" or $s == "ACTION_REQUIRED"
                    or $s == "STARTUP_FAILURE") then "fail" else "pending" end)}]') || exit 1
  stats=$(rest "repos/$repo/commits/$sha/status" | jq -c '[.statuses[] |
    {name: .context, state: (.state | ascii_upcase), link: (.target_url // ""), workflow: "",
     startedAt: .created_at, completedAt: .updated_at, description: (.description // ""), event: "",
     bucket: (if .state == "success" then "pass" elif .state == "pending" then "pending" else "fail" end)}]') || exit 1
  # shellcheck disable=SC2016
  jq -nc --argjson r "$runs" --argjson s "$stats" --argjson w "$want" "$AGG"'
    ($r + $s) as $all |
    {bucket: ($all | agg)} + (if ($w|length) > 0 then
      {checks: ($all | map(with_entries(select(.key as $k | ($w|index($k)) != null))))} else {} end)' | emit rest 0
else
  nulls "$obj"
  jq -c --argjson w "$want" '. as $o | reduce $w[] as $k ({}; . + {($k): $o[$k]})' <<< "$obj" | emit rest 0
fi
fleet_gh_log "fallback-ok op=fleet-gh-$kind repo=$repo n=$N"
exit 0
