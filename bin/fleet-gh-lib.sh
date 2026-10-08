# shellcheck shell=bash
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
#   fleet_gh_write <gh args…>            run ONE write through the per-token queue
#                                        (issue #1264, below); gh's rc + output
#   fleet_gh_wrun <bucket> <source> <gh args…>
#                                        fleet_gh_run for a WRITE: same contract,
#                                        but the call goes through fleet_gh_write
#   fleet_wh_live / fleet_wh_mark / fleet_wh_sig
#                                        webhook event stamps (issue #1272, below)

FLEET_GH_LIMITED_RC=75
# A caller that already knows its bin/ (tmux-status.sh, every 5s) presets it: no fork.
_FLEET_GH_LIB_DIR="${_FLEET_GH_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"

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
  _fleet_gh_limited_any "${1:-graphql}" secondary
}

_fleet_gh_limited_any() {  # _fleet_gh_limited_any <bucket>… — first one limited wins
  local k f reset now
  now=$(date +%s)
  for k in "$@"; do
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

# A WRITE (fleet_gh_wrun) does not skip on a secondary marker: the write queue
# WAITS it out instead (issue #1264) — a skipped comment is a lost comment.
fleet_gh_run() {  # fleet_gh_run <bucket> <source> <gh args…>
  local b="${1:-graphql}" src="${2:-gh}" err rc errtxt hit runner=gh limited
  shift 2
  if [ "${_FLEET_GH_WRITE:-0}" = 1 ]; then
    runner=fleet_gh_write; _fleet_gh_limited_any "$b" >/dev/null && limited=1
  else
    fleet_gh_limited "$b" >/dev/null && limited=1
  fi
  if [ -n "${limited:-}" ]; then
    fleet_gh_log "skip bucket=$b source=$src"
    return "$FLEET_GH_LIMITED_RC"
  fi
  err=$(mktemp "${TMPDIR:-/tmp}/fleet-gh-err.XXXXXX") || { "$runner" "$@"; return $?; }
  "$runner" "$@" 2>"$err"; rc=$?
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
    # `macOS shard *` is not part of the merge gate (issue #2286) — dropped here
    # exactly as fleet-pr-verdict.sh's GraphQL fold drops it.
    runs=$(fleet_gh_run core pr-view api "repos/$repo/commits/$sha/check-runs?per_page=100" --jq '
             .check_runs[] | select((.name // "") | startswith("macOS shard") | not) |
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
  merged=$(fleet_gh_wrun core merge api -X PUT "repos/$repo/pulls/$pr/merge" \
             -f "merge_method=$method" -f "sha=$sha" --jq '.merged') || return $?
  [ "$merged" = true ] || return 1
  if [ "$del" = --delete-branch ] && [ -n "$ref" ] && [ "$same" = same ]; then
    fleet_gh_wrun core merge api -X DELETE "repos/$repo/git/refs/heads/$ref" >/dev/null \
      || printf 'fleet-gh: merged #%s, but deleting branch %s failed (harmless)\n' "$pr" "$ref" >&2
  fi
  return 0
}

fleet_gh_rest_comment() {  # fleet_gh_rest_comment <repo> <issue> <body-file>
  fleet_gh_wrun core comment api "repos/$1/issues/$2/comments" -F "body=@$3" --jq '.html_url'
}

fleet_gh_rest_issue_close() {  # fleet_gh_rest_issue_close <repo> <issue>
  fleet_gh_wrun core comment api -X PATCH "repos/$1/issues/$2" -f state=closed --jq '.html_url'
}

# Head refs of MERGED PRs for <branch> — the `gh pr list --state merged --head`
# answer dash-reap's merged-check reads, with the REST fallback. Same argv as the
# pre-#1042 call on the healthy path. REST's `head=` filter wants owner:branch;
# a fleet branch is pushed to the repo itself, so the owner is the repo's.
# `--at` (issue #1542) appends a TAB + the PR's mergedAt (ISO-8601 UTC) to each
# line, so the reaper can hand the liveness probe the merge time (#1329) without a
# second round-trip; without it the argv is byte for byte the pre-#1542 one.
# `--sha` (issue #1842) appends a TAB + the PR's head sha (after the mergedAt with
# `--at`), which fleet_reap_ok reads to keep a commit made after the merge.
fleet_gh_merged_heads() {  # fleet_gh_merged_heads <repo> <branch> [--at] [--sha]
  local repo="$1" branch="$2" out rc at=0 sha=0 o
  for o in "${3:-}" "${4:-}"; do case "$o" in --at) at=1 ;; --sha) sha=1 ;; esac; done
  local gq='.[].headRefName' gj=headRefName rq='.[] | select(.merged_at != null) | .head.ref'
  if [ "$at" = 1 ] || [ "$sha" = 1 ]; then
    gq='.[] | "\(.headRefName)'; gj=headRefName
    rq='.[] | select(.merged_at != null) | "\(.head.ref)'
    [ "$at" = 1 ] && { gq="$gq"'\t\(.mergedAt)'; gj=$gj,mergedAt; rq="$rq"'\t\(.merged_at)'; }
    [ "$sha" = 1 ] && { gq="$gq"'\t\(.headRefOid)'; gj=$gj,headRefOid; rq="$rq"'\t\(.head.sha)'; }
    gq="$gq\""; rq="$rq\""
  fi
  out=$(fleet_gh_run graphql reap -R "$repo" pr list --state merged --head "$branch" \
          --json "$gj" -q "$gq"); rc=$?
  if [ "$rc" -eq 0 ]; then [ -n "$out" ] && printf '%s\n' "$out"; return 0; fi
  [ "$rc" -eq "$FLEET_GH_LIMITED_RC" ] || return "$rc"
  out=$(fleet_gh_run core reap api "repos/$repo/pulls?state=closed&head=${repo%%/*}:$branch&per_page=100" \
          --jq "$rq") || return $?
  fleet_gh_log "fallback-ok op=merged-heads repo=$repo branch=$branch"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# --- write queue (issue #1264, EPIC #1262 C4) ---------------------------------
# At the end of a big batch a dozen workers + the hub write GitHub at once
# (comments, filings, PRs). GitHub's SECONDARY limit is about write *rate*, and it
# punishes a retry storm by extending the block — so every writer that hit it and
# retried at once lost its progress log / delivery comment. fleet_gh_write makes
# the writes of one token a queue:
#   * a per-token lock (one writer at a time) + a minimum gap between the START
#     of two writes (FLEET_GH_WRITE_GAP seconds, default 1, decimals ok);
#   * a secondary refusal is waited out BY THE LOCK HOLDER, lock held: it writes
#     the shared gh-limit.secondary marker, sleeps Retry-After (from the call's
#     own output — `gh api -i` prints headers; else 60→120→240, capped 300,
#     base FLEET_GH_WRITE_BACKOFF), and retries, at most 3 times. Everyone else is
#     queued on the lock behind it, so the whole token waits ONCE, together,
#     instead of each one retrying into a longer block. A writer that acquires the
#     lock while a marker someone else wrote still holds sleeps it out first.
#   * gh's exit code, stdout and stderr pass through unchanged (replayed after
#     the call, so a retried attempt's refusal is never printed).
# Lock: $FLEET_STATE_DIR/gh-write.<token-fp>.lock — a file holding the holder's
# pid, created atomically by hard link. No flock on macOS, so staleness is a pid
# check: a holder that was SIGKILLed leaves a file whose pid is dead, and the
# next waiter removes it. Point FLEET_STATE_DIR at one shared dir and logins that
# share a token share the queue. A waiter gives up after FLEET_GH_WRITE_LOCK_WAIT
# seconds (default 1200) and writes unqueued (logged) rather than lose the write.

_fleet_gh_now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local s="${EPOCHREALTIME%[.,]*}" u="${EPOCHREALTIME#*[.,]}"
    printf '%s' "$(( s * 1000 + 10#${u:0:3} ))"
  else
    perl -MTime::HiRes=time -e 'printf "%d", time()*1000' 2>/dev/null || printf '%s000' "$(date +%s)"
  fi
}

_fleet_gh_sleep_ms() { [ "${1:-0}" -gt 0 ] && sleep "$(awk -v m="$1" 'BEGIN{printf "%.3f", m/1000}')"; return 0; }

_fleet_gh_pid_alive() {  # another login's pid: kill -0 says EPERM, ps still sees it
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1
}

# Which token the write queue is for, without spending a gh call (a selftest's gh
# shim counts every argv): an env token is hashed; else gh's own config names the
# github.com user its stored token belongs to. One account ≡ one queue.
_fleet_gh_token_fp() {
  local t="${GH_TOKEN:-${GITHUB_TOKEN:-}}" fp
  if [ -z "$t" ]; then
    t=$(awk '/^[^ \t]/ { h = ($1 == "github.com:") } h && $1 == "user:" { print "user:" $2; exit }' \
          "${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml" 2>/dev/null)
  fi
  [ -n "$t" ] || { printf default; return 0; }
  fp=$(printf '%s' "$t" | { shasum 2>/dev/null || sha1sum; } | cut -c1-12)
  printf '%s' "${fp:-default}"
}

_fleet_gh_write_lock() {  # _fleet_gh_write_lock <lockfile> <pid> — rc 1 = gave up
  local l="$1" me="$2" tmp held again waited=0 limit
  limit="${FLEET_GH_WRITE_LOCK_WAIT:-1200}"; case "$limit" in ''|*[!0-9]*) limit=1200 ;; esac
  tmp="$l.$me"
  printf '%s\n' "$me" > "$tmp" 2>/dev/null || return 1
  # Polled with builtins only (read / kill -0): a queue of 20 waiters must not
  # fork-storm the box it is trying to be polite on.
  while :; do
    if ln "$tmp" "$l" 2>/dev/null; then rm -f "$tmp"; return 0; fi
    held=; read -r held 2>/dev/null < "$l"
    if [ -n "$held" ] && ! _fleet_gh_pid_alive "$held"; then
      # Re-read right before removing: only the dead holder's file goes.
      again=; read -r again 2>/dev/null < "$l"
      [ "$again" = "$held" ] && rm -f "$l" && fleet_gh_log "write-lock-stale pid=$held"
      continue
    fi
    if [ "$waited" -ge $((limit * 10)) ]; then
      rm -f "$tmp"; fleet_gh_log "write-lock-timeout waited=${limit}s holder=${held:-?}"
      return 1
    fi
    sleep 0.1; waited=$((waited + 1))
  done
}

_fleet_gh_write_unlock() {  # only our own lock — never a successor's
  local h=; read -r h 2>/dev/null < "$1"
  [ "$h" = "$2" ] && rm -f "$1"
  return 0
}

fleet_gh_write() {  # fleet_gh_write <gh args…>
  local d fp lock me locked=0 gap_ms last now dly out err rc tries=0 ra secs base reset src
  d=$(fleet_gh_state_dir); fp=$(_fleet_gh_token_fp)
  lock="$d/gh-write.$fp.lock"
  # OUR pid even inside a $(…) subshell (bash 3.2 has no BASHPID): the command
  # substitution's child execs sh, whose parent is this shell.
  me="${BASHPID:-$(exec sh -c 'printf %s "$PPID"')}"
  _fleet_gh_write_lock "$lock" "$me" && locked=1
  gap_ms=$(awk -v g="${FLEET_GH_WRITE_GAP:-1}" 'BEGIN{ if (g !~ /^[0-9]*[.]?[0-9]+$/) g=1; printf "%d", g*1000 }')
  base="${FLEET_GH_WRITE_BACKOFF:-60}"; case "$base" in ''|*[!0-9]*) base=60 ;; esac
  src="${0##*/}"
  out=$(mktemp "${TMPDIR:-/tmp}/fleet-ghw-out.XXXXXX") || { [ "$locked" = 1 ] && _fleet_gh_write_unlock "$lock" "$me"; gh "$@"; return $?; }
  err="$out.err"
  while :; do
    # Someone else's secondary refusal still holds → wait it out with them.
    if reset=$(_fleet_gh_limited_any secondary) && [ "$reset" != fake ]; then
      secs=$(( reset - $(date +%s) )); [ "$secs" -gt 900 ] && secs=900
      if [ "$secs" -gt 0 ]; then
        fleet_gh_log "secondary-wait secs=$secs source=$src cause=marker"
        sleep "$secs"
      fi
    fi
    last=$(cat "$d/gh-write.$fp.last" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
    now=$(_fleet_gh_now_ms); dly=$(( last + gap_ms - now ))
    [ "$dly" -gt "$gap_ms" ] && dly=$gap_ms        # a clock step never stalls the queue
    _fleet_gh_sleep_ms "$dly"
    _fleet_gh_now_ms > "$d/gh-write.$fp.last.$me" 2>/dev/null \
      && mv -f "$d/gh-write.$fp.last.$me" "$d/gh-write.$fp.last" 2>/dev/null
    gh "$@" >"$out" 2>"$err"; rc=$?
    [ "$rc" -eq 0 ] && break
    [ "$(fleet_gh_limit_bucket "$(cat "$err" "$out" 2>/dev/null)")" = secondary ] || break
    [ "$tries" -ge 3 ] && break
    ra=$(cat "$out" "$err" 2>/dev/null | tr -d '\r' | sed -n 's/^[Rr]etry-[Aa]fter: *\([0-9][0-9]*\).*/\1/p' | head -1)
    if [ -n "$ra" ]; then secs=$ra; else secs=$(( base << tries )); [ "$secs" -gt 300 ] && secs=300; fi
    tries=$((tries + 1))
    fleet_gh_mark_limited secondary "$(( $(date +%s) + secs ))" "$src"
    fleet_gh_log "secondary-wait secs=$secs source=$src try=$tries${ra:+ retry-after=$ra}"
    sleep "$secs"
  done
  [ "$locked" = 1 ] && _fleet_gh_write_unlock "$lock" "$me"
  [ "$tries" -gt 0 ] && [ "$rc" -eq 0 ] && fleet_gh_log "secondary-ok source=$src tries=$tries"
  cat "$out"; cat "$err" >&2; rm -f "$out" "$err"
  return "$rc"
}

fleet_gh_wrun() {  # fleet_gh_wrun <bucket> <source> <gh args…> — dynamic scope carries the flag
  local _FLEET_GH_WRITE=1
  fleet_gh_run "$@"
}

# --- C2 (#989): reading the limit back — the status bar, doctor and preflight ---
# These READ the marker (and FLEET_GH_FAKE_LIMIT); they never probe GitHub
# themselves (EPIC #1262 C2 接口约定). Forkless on the healthy path — the status
# bar renders through here every 5s per client (issue #888): the clock comes from
# fleet_now_pin's $_FLEET_NOW when the caller pinned one.

# fleet_gh_limit_rows — one `<bucket>\t<reset>\t<source>` line per bucket that is
# limited right now; <reset> is an epoch, or `fake` for an injected limit (which
# has no reset). No output, rc 1, when nothing is limited.
fleet_gh_limit_rows() {
  local now b f k v reset src out='' d
  d="${FLEET_STATE_DIR:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/global}"   # read-only: no mkdir
  now="${_FLEET_NOW:-}"; case "$now" in ''|*[!0-9]*) now=$(date +%s) ;; esac
  for b in graphql core secondary; do
    if fleet_gh_fake_limited "$b"; then
      out="$out$b	fake	FLEET_GH_FAKE_LIMIT
"
      continue
    fi
    f="$d/gh-limit.$b"
    [ -f "$f" ] || continue
    reset='' src=''
    while IFS='=' read -r k v; do
      case "$k" in reset) reset="$v" ;; source) src="$v" ;; esac
    done < "$f"
    case "$reset" in ''|*[!0-9]*) continue ;; esac
    [ "$reset" -gt "$now" ] || continue
    out="$out$b	$reset	${src:-?}
"
  done
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# fleet_gh_limit_until — the epoch the LAST live limit lifts (`fake` when only an
# injected one is live); rc 1 when nothing is limited.
fleet_gh_limit_until() {
  local rows b r max='' fake=''
  rows=$(fleet_gh_limit_rows) || return 1
  while IFS='	' read -r b r _; do
    case "$r" in
      fake) fake=1 ;;
      *[!0-9]*|'') ;;
      *) { [ -z "$max" ] || [ "$r" -gt "$max" ]; } && max="$r" ;;
    esac
  done <<< "$rows"
  if [ -n "$max" ]; then printf '%s\n' "$max"; elif [ -n "$fake" ]; then echo fake; else return 1; fi
}

# fleet_gh_hhmm <epoch> — local HH:MM (BSD `date -r`, GNU `date -d @`).
fleet_gh_hhmm() { date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M' 2>/dev/null || printf '?'; }

# fleet_gh_rest_repo_perm <repo> — the REST read of what the preflight's GraphQL
# `gh repo view` asks: `<PERM>\t<default branch>\t<has_issues>`, PERM spelled the
# GraphQL way (ADMIN|MAINTAIN|WRITE|TRIAGE|READ) so one case judges both paths.
# rc $FLEET_GH_LIMITED_RC when REST is limited too.
fleet_gh_rest_repo_perm() {
  # shellcheck disable=SC2016
  fleet_gh_run core preflight api "repos/$1" --jq '
    [ (.permissions // {} |
        if .admin then "ADMIN" elif .maintain then "MAINTAIN" elif .push then "WRITE"
        elif .triage then "TRIAGE" elif .pull then "READ" else "" end),
      (.default_branch // ""), ((.has_issues // true) | tostring) ] | @tsv'
}

# --- R3 (#1271): one account, one set of background reads ----------------------
# Six logins on the mini share one GitHub account, and each ran the same
# collector / pr-refresh / issue-bridge reads — the same `gh issue list`, the same
# `gh pr list`, the same comment listing, six times over: the account's main
# amplifier (#1211). With FLEET_GH_SHARE=1 the logins that share a token elect ONE
# leader; only the leader fetches, publishes what it fetched, and every follower
# reads that copy instead of calling GitHub.
#
# Where: $FLEET_GH_SHARED_DIR (default /Users/Shared/.fleet-gh — every login can
# reach it), one subdir per token fingerprint (the same fp the write queue keys
# on). Both are 1777, so each login only ever writes files it OWNS:
#   <fp>/hb.<login>           since=<epoch its heartbeat run began>  hb=<last beat>
#   <fp>/pub.<login>/<slug>/  what that login published as leader (0755 / 0644)
# Election needs no lock and no cross-login write: the collector tick beats
# (fleet_gh_lead_tick); a beat more than FLEET_GH_LEADER_STALE old (default 180s =
# 3 ticks of 60s) is dead, and the leader is the live login with the OLDEST
# `since` (ties by name). So the incumbent keeps it while it beats, a newcomer
# never displaces it, and when it dies the next-oldest takes over within 3 ticks.
# A login whose fleet is idle beats only every idle-gated tick (300s) — stale by
# then — so it never leads for long.
#
# Followers adopt a copy only when it is fresh (each caller passes its max age):
# a stale or missing copy — the leader's daemon wedged, or the leader does not
# poll this repo (different repo sets share only the intersection) — means the
# follower fetches for itself, as before. Off (the default): no file, no fork,
# every login fetches — the historic behavior byte for byte.
#
# API
#   fleet_gh_share_on                     rc 0 when sharing is on
#   fleet_gh_share_root                   print <shared>/<fp> (created 1777)
#   fleet_gh_share_me                     this login's name (FLEET_GH_SHARE_ID seam)
#   fleet_gh_lead_tick                    beat; print the leader; rc 0 = we lead
#   fleet_gh_leader                       print the live leader; rc 1 = none / off
#   fleet_gh_should_fetch                 rc 0 = fetch from GitHub (off, or we lead,
#                                         or no live leader)
#   fleet_gh_publish <slug> <dir> <file>… leader: copy <dir>/<file>… to its pub dir
#   fleet_gh_adopt <slug> <maxage> <dir> <file>…
#                                         follower: copy the leader's <file>… into
#                                         <dir> when its FIRST file is ≤ maxage s
#                                         old; rc 1 = no fresh copy → fetch yourself

fleet_gh_share_on() { [ "${FLEET_GH_SHARE:-0}" = 1 ]; }

fleet_gh_share_me() {
  local u="${FLEET_GH_SHARE_ID:-${USER:-}}"
  [ -n "$u" ] || u=$(id -un 2>/dev/null)
  printf '%s' "${u//[^A-Za-z0-9._-]/_}"
}

fleet_gh_share_root() {
  local base="${FLEET_GH_SHARED_DIR:-/Users/Shared/.fleet-gh}" r
  r="$base/$(_fleet_gh_token_fp)"
  if [ ! -d "$r" ]; then
    mkdir -p "$base" 2>/dev/null && chmod 1777 "$base" 2>/dev/null
    mkdir -p "$r" 2>/dev/null && chmod 1777 "$r" 2>/dev/null
  fi
  [ -d "$r" ] || return 1
  printf '%s' "$r"
}

_fleet_gh_stale_secs() {
  local s="${FLEET_GH_LEADER_STALE:-180}"
  case "$s" in ''|*[!0-9]*) s=180 ;; esac
  printf '%s' "$s"
}

# _fleet_gh_hb_read <file> — sets _hb_since/_hb_beat (0 when unreadable)
_fleet_gh_hb_read() {
  local k v
  _hb_since=0 _hb_beat=0
  [ -f "$1" ] || return 1
  while IFS='=' read -r k v; do
    case "$k" in since) _hb_since="$v" ;; hb) _hb_beat="$v" ;; esac
  done < "$1" 2>/dev/null
  case "$_hb_since" in ''|*[!0-9]*) _hb_since=0 ;; esac
  case "$_hb_beat" in ''|*[!0-9]*) _hb_beat=0 ;; esac
  return 0
}

fleet_gh_leader() {
  fleet_gh_share_on || return 1
  local r f now stale best='' bs=0 who _hb_since _hb_beat
  r=$(fleet_gh_share_root) || return 1
  now=$(date +%s); stale=$(_fleet_gh_stale_secs)
  for f in "$r"/hb.*; do
    [ -f "$f" ] || continue
    _fleet_gh_hb_read "$f" || continue
    [ $((now - _hb_beat)) -le "$stale" ] || continue
    who="${f##*/hb.}"
    if [ -z "$best" ] || [ "$_hb_since" -lt "$bs" ] \
       || { [ "$_hb_since" -eq "$bs" ] && [[ "$who" < "$best" ]]; }; then
      best="$who"; bs="$_hb_since"
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

fleet_gh_lead_tick() {
  fleet_gh_share_on || return 0
  local r me f now stale since tmp lead _hb_since _hb_beat
  r=$(fleet_gh_share_root) || return 0
  me=$(fleet_gh_share_me); f="$r/hb.$me"
  now=$(date +%s); stale=$(_fleet_gh_stale_secs)
  since=$now
  _fleet_gh_hb_read "$f" && [ $((now - _hb_beat)) -le "$stale" ] && [ "$_hb_since" -gt 0 ] && since=$_hb_since
  tmp="$r/.hb.$me.$$"
  printf 'since=%s\nhb=%s\n' "$since" "$now" > "$tmp" 2>/dev/null \
    && chmod 644 "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  lead=$(fleet_gh_leader) || return 0
  printf '%s\n' "$lead"
  if [ "$lead" = "$me" ]; then
    [ -f "$r/.lead.$me" ] || { : > "$r/.lead.$me" 2>/dev/null; fleet_gh_log "share-lead login=$me"; }
    return 0
  fi
  [ -f "$r/.lead.$me" ] && { rm -f "$r/.lead.$me"; fleet_gh_log "share-follow login=$me leader=$lead"; }
  return 1
}

fleet_gh_should_fetch() {
  fleet_gh_share_on || return 0
  local lead
  lead=$(fleet_gh_leader) || return 0
  [ "$lead" = "$(fleet_gh_share_me)" ]
}

fleet_gh_publish() {  # fleet_gh_publish <slug> <dir> <file>…
  fleet_gh_share_on || return 0
  local slug="$1" src="$2" r d f
  shift 2
  r=$(fleet_gh_share_root) || return 0
  d="$r/pub.$(fleet_gh_share_me)/$slug"
  [ -d "$d" ] || { mkdir -p "$d" 2>/dev/null && chmod 755 "$r/pub.$(fleet_gh_share_me)" "$d" 2>/dev/null; }
  for f in "$@"; do
    [ -f "$src/$f" ] || continue
    cp "$src/$f" "$d/.$f.$$" 2>/dev/null && chmod 644 "$d/.$f.$$" 2>/dev/null \
      && mv -f "$d/.$f.$$" "$d/$f" 2>/dev/null
    rm -f "$d/.$f.$$" 2>/dev/null
  done
  return 0
}

fleet_gh_adopt() {  # fleet_gh_adopt <slug> <maxage> <dir> <file>…
  fleet_gh_share_on || return 1
  local slug="$1" maxage="$2" dst="$3" r lead s f mt now
  shift 3
  lead=$(fleet_gh_leader) || return 1
  [ "$lead" = "$(fleet_gh_share_me)" ] && return 1
  r=$(fleet_gh_share_root) || return 1
  s="$r/pub.$lead/$slug"
  [ -f "$s/$1" ] || return 1
  # GNU stat FIRST: `stat -f %m` on GNU means "filesystem status" and exits 0
  mt=$(stat -c %Y "$s/$1" 2>/dev/null || stat -f %m "$s/$1" 2>/dev/null)
  case "$mt" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $((now - mt)) -le "$maxage" ] || return 1
  mkdir -p "$dst" 2>/dev/null
  for f in "$@"; do
    [ -f "$s/$f" ] || continue
    cp "$s/$f" "$dst/.$f.adopt.$$" 2>/dev/null && mv -f "$dst/.$f.adopt.$$" "$dst/$f" 2>/dev/null
    rm -f "$dst/.$f.adopt.$$" 2>/dev/null
  done
  return 0
}

# --- webhook event stamps: wait on a change, not a clock (issue #1272, R4) -------
# fleet-webhook.sh --route already hears every pull_request / check_run /
# check_suite / status delivery for a forwarded repo. Besides kicking pr-refresh it
# now leaves a STAMP per PR it names — so a waiter (fleet-pr-verdict.sh --wait,
# fleet-gh.sh pr checks) reads GitHub only when something changed, plus one
# confirming read at the end, instead of one read every 15-20s.
#   <state>/events/<slug>/pr-<N>   a delivery naming PR #N (pull_request, or a
#                                  check_run/check_suite's pull_requests[])
#   <state>/events/<slug>/repo     a PR-class delivery naming NO PR (a `status`
#                                  event, a fork PR's check_suite) — and every
#                                  forward (re)connect, since `gh webhook forward`
#                                  never replays what it missed while down
# Content: `<epoch> <event> <id>` — the id makes every write a new value, so a
# waiter compares contents, never mtimes. Written tmp+rename.
# <state> is the webhook daemon's own dir (FLEET_WEBHOOK_STATE_DIR, default
# ~/.config/claude-fleet/webhook — per login, like the daemon).
#
# AVAILABLE (fleet_wh_live) = the handler AND this repo's forward are running.
# Anything else — no daemon, a repo not opted in, a forward mid-restart — and the
# waiter polls exactly as before. A live forward that misses a delivery costs
# freshness only: every waiter still re-reads on a long backstop.
#
#   fleet_wh_state_dir                   the webhook state dir
#   fleet_wh_live <repo>                 rc 0 while deliveries for <repo> arrive
#   fleet_wh_mark <repo> <key> <event>   write one stamp (key: pr-<N> | repo)
#   fleet_wh_sig <repo> <pr>             one line that changes whenever a delivery
#                                        for <pr> (or for the repo) lands
fleet_wh_state_dir() { printf '%s' "${FLEET_WEBHOOK_STATE_DIR:-$HOME/.config/claude-fleet/webhook}"; }

_fleet_wh_slug() {
  if command -v fleet_slug >/dev/null 2>&1; then fleet_slug "$1"
  else printf '%s' "$1" | tr '/' '-' | tr -cd '[:alnum:]._-'; fi
}

_fleet_wh_pid_live() {  # _fleet_wh_pid_live <pidfile>
  local p
  p=$(cat "$1" 2>/dev/null) || return 1
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null
}

fleet_wh_live() {  # fleet_wh_live <repo>
  local d; d=$(fleet_wh_state_dir)
  [ -n "${1:-}" ] || return 1
  _fleet_wh_pid_live "$d/handler.pid" && _fleet_wh_pid_live "$d/forwards/$(_fleet_wh_slug "$1").pid"
}

fleet_wh_mark() {  # fleet_wh_mark <repo> <key> <event>
  local d tmp
  case "${2:-}" in repo|pr-[0-9]*) ;; *) return 1 ;; esac
  d="$(fleet_wh_state_dir)/events/$(_fleet_wh_slug "${1:-}")"
  mkdir -p "$d" 2>/dev/null || return 1
  tmp="$d/.$2.$$"
  printf '%s %s %s.%s\n' "$(date +%s)" "${3:-event}" "$$" "${RANDOM:-0}" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$d/$2" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

fleet_wh_sig() {  # fleet_wh_sig <repo> <pr>
  local d; d="$(fleet_wh_state_dir)/events/$(_fleet_wh_slug "${1:-}")"
  printf '%s|%s\n' "$(cat "$d/pr-${2:-}" 2>/dev/null)" "$(cat "$d/repo" 2>/dev/null)"
}
