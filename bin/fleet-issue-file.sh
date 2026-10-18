#!/bin/bash
# fleet-issue-file.sh — the ONE channel every fleet actor files a GitHub issue
# through (issue #332). Consolidates the three historical issue-create sites
# — the backlog ⌃n / prefix+n filer (bin/dash-issue-new.sh), the dash new-session
# box (bin/dash-new-session.sh), and the operator's file+spawn op from the hub
# — behind one script with one body/label/provenance
# behaviour, so a change to how the fleet files an issue lives in a single place.
#
# Responsibilities, each a small testable step:
#   1. VALIDATE any requested labels against the FIXED canonical taxonomy —
#      fleet_labels_allowed in fleet-lib.sh (issue #333), the same set
#      bin/fleet-labels-seed.sh installs, NOT the repo's live label list. Reject an
#      off-taxonomy label UP FRONT with a clear message instead of an opaque `gh
#      issue create` failure, and reject it even if it has been minted in the
#      repo out of band (fixed seed, no minting). The check is deterministic +
#      offline (no gh read). No labels requested → no validation, so the
#      label-free ⌃n / new-session paths add nothing here.
#   1b. --breakage (issue #2078): the base branch is RED and this issue is its fix.
#      Fingerprint the breakage first — fleet_breakage_probe: the commit the red
#      streak started at + the first failed check + its first error line, sans
#      line numbers — and file ONE issue per fingerprint: a `<key>/` lock under
#      $FLEET_CONF_DIR/global/breakage serializes the same-second filers on this
#      machine (2 minutes, FLEET_BREAKAGE_LOCK_SECS), the `<!-- fleet:breakage
#      key=… -->` marker in the body is what a filer on another machine finds
#      (fleet_breakage_find, the REST open-issue list). Found one ⇒ a record-only
#      「同一故障，来自 …」 comment on it, its URL on stdout, exit 5, no spawn,
#      no bind. On 2026-10-07 three sessions filed #2039 #2040 #2041 and three
#      fixes inside 16 seconds for one duplicate route. --breakage-key K takes a
#      key already computed — every automatic filer (a watch, a probe, the train,
#      the nightly) names its fingerprint this way: `<channel>-<failed step>`,
#      NEVER a commit (issue #4271). A base that is not red files an ordinary
#      issue and says so.
#      ONE ISSUE PER FINGERPRINT, ACROSS SHAS (issue #4271): --fault-sha S /
#      --fault-link URL say where it is red THIS time (the probe's own: the
#      streak's first commit and its run). An open issue under the key gets ONE
#      「同一故障」 comment per new sha (`<!-- fleet:fault sha=S -->`; a sha already
#      on record adds nothing). None open but a closed one (not «not planned»):
#      when S contains the commit that closed it (fleet_fault_contains; closed by
#      hand: S newer than the close) it is REOPENED with a comment — the fix did
#      not hold; else S is an older version without the fix and it is only noted
#      there. Either way exit 5 and that URL, never a new issue.
#      NOT AUTOMATIC ANY MORE (issue #4271, replacing #2175's auto road): only
#      --breakage / --breakage-key make a filing a breakage. A person's or a
#      session's ordinary issue whose text says 「红」 is an ordinary issue —
#      #4268 (a release-gate design ticket) was taken as macOS / shard 6's breakage
#      and swallowed the next filing as 「同一故障」. The old auto knob is read
#      by nothing; --no-breakage still parses (a no-op).
#   2. STAMP the invisible `<!-- fleet:from role=… session=… issue=… -->`
#      provenance marker into the body via the shared fleet_from_marker helper —
#      the byte-identical marker bin/fleet-comment.sh puts on a comment (the
#      convention lives in fleet-lib.sh now; this reuses it, #224/#332).
#   2a. --rule N is accepted and ignored for one version (issue #4340: the dispatch
#      rule table is gone, nothing writes 「按规则 N 派发」 or a fleet:rule marker any
#      more; an old issue's marker is only text). # compat-1v: 下一批删
#   3. create, through the ticket door (`fleet-ticket.sh new --filed`; issue #3595) (title · body · labels · milestone). When no --milestone
#      is given and FLEET_DEFAULT_MILESTONE is set for the fleet, default to it —
#      auto-creating the milestone if absent — so nothing lands unsorted (issue
#      #433). Best-effort: milestone plumbing never wedges the fast path.
#   4. --parent N → link the new issue as a SUB-ISSUE of N (GitHub sub-issues API);
#      best-effort — a link failure never loses the just-filed issue.
#   5. --spawn → hand the new number to the UNCHANGED bin/dash-issue-session.sh
#      spawn choke point; its session caps + cross-machine pre-spawn dedup are the
#      "reuse pre-spawn dedup helpers" the channel leans on (a filer creates a
#      brand-new number, so there is nothing to dedup until the spawn).
#   5b. --bind → hand it to bin/fleet-bind.sh instead: the CALLING scratch session
#      becomes the worker for the issue it just filed, in place (issue #520). This
#      is the "refine in a scratch, then track it" path — the context is already in
#      this session, so spawning a second worker to re-ground it is pure waste.
#      Mutually exclusive with --spawn (bind THIS session or start another, never
#      both), and like --spawn a refusal leaves the issue FILED.
#   5c. any pane may --spawn, a worker's too (issue #4591 lifted #2960's refusal);
#      a NEW breakage a worker files WITHOUT --spawn spawns nobody (issue #4337): the
#      person is alerted (fleet-alerts.sh event breakage) and the worker's parent
#      session told (fleet-peer-send.sh, fid first) — that session may spawn its
#      fixer, else it waits for the person.
#
# Prints the created issue URL on stdout (exactly like GitHub's own create) so a
# caller can parse the trailing #number; all diagnostics + refusals go to stderr.
# Exit codes: 0 ok · 2 usage · 3 unknown label · 1 no-repo / create failure ·
# 4 --spawn with no live parent (issue #1355; filed first when the spawn said it) — so a
# caller records an honest FAIL rather than a false success ·
# 5 --breakage (or auto): the breakage already has an open issue — its URL is on stdout, a
# 「同一故障」 comment is on it, nothing was filed or spawned (issue #2078).
#
# Usage:
#   fleet-issue-file.sh --title T [--body B] [--label L,...]… [--priority pN] \
#                       [--parent N] [--from ROLE] [--milestone M] [--rule N] \
#                       [--repo R] [--spawn | --bind] [--breakage | --breakage-key K | --no-breakage] \
#                       [--fault-sha S] [--fault-link URL] \
#                       [--task T<n>] [--draft] [--pr-note TEXT]
#   --draft (issue #3715): a DRAFT-ONLY ticket — the body carries
#      `<!-- fleet:draft-only -->` (bin/fleet-draft.sh block): its worker opens a
#      draft PR, reports waiting and stops; fleet-pr-merge.sh refuses it until
#      `fleet-draft.sh approve <N>`. --pr-note TEXT (implies --draft) is what the
#      PR body must carry (「日报回复 <日期>#<n>」, `<!-- daily-plan -->`).
#      A --spawn of one keeps the default reap (merged): an open draft is never reaped.
#   --task T<n> (issue #3330): the hub's task record this issue is filed FOR — the
#      `task` tool opened it first; a development task then files
#      its issue here. The body says 「hub 任务 T<n>」, the issue is hung on the
#      record (bin/fleet-task-record.sh set --issue) and a --spawn carries --task to
#      the worker (stamped @task). No --task ⇒ byte for byte as before.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-gh-lib.sh"   # fleet_gh_write: every write below is queued (issue #1264)

title='' body='' priority='' parent='' from='' milestone='' repo='' spawn=0 bind=0 task=''
draft=0 pr_note=''
breakage='' breakage_key='' bk_sha='' bk_check='' bk_line='' bk_rid='' bk_lock='' bk_held=0
fault_sha='' fault_link='' 
labels=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --title)     shift; title="${1:-}" ;;
    --body)      shift; body="${1:-}" ;;
    --label)     shift
                 # comma-split, trim each; --label may repeat and/or carry a list.
                 IFS=',' read -r -a _ls <<< "${1:-}"
                 for _l in ${_ls[@]+"${_ls[@]}"}; do
                   _l="${_l#"${_l%%[![:space:]]*}"}"; _l="${_l%"${_l##*[![:space:]]}"}"
                   [ -n "$_l" ] && labels+=("$_l")
                 done ;;
    --priority)  shift; priority="${1:-}" ;;
    --parent)    shift; parent="${1//[^0-9]/}" ;;
    --from)      shift; from="${1:-}" ;;
    --milestone) shift; milestone="${1:-}" ;;
    --rule)      shift ;;   # compat-1v: accepted, ignored (issue #4340)
    --task)      shift; task="${1:-}" ;;
    --repo)      shift; repo="${1:-}" ;;
    --spawn)     spawn=1 ;;
    --bind)      bind=1 ;;
    --breakage)  breakage=1 ;;
    --no-breakage) breakage=0 ;;
    --breakage-key) shift; breakage_key="${1:-}" ;;
    --fault-sha)  shift; fault_sha="${1:-}" ;;
    --fault-link) shift; fault_link="${1:-}" ;;
    --draft)     draft=1 ;;
    --pr-note)   shift; pr_note="${1:-}"; draft=1 ;;
    -h|--help)   sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    --*)         printf 'fleet-issue-file: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)           printf 'fleet-issue-file: unexpected argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

[ -z "$title" ] && { printf 'fleet-issue-file: --title is required\n' >&2; exit 2; }
if [ -n "$task" ]; then
  case "$task" in T[1-9]*) case "${task#T}" in *[!0-9]*) task=bad ;; esac ;; *) task=bad ;; esac
  [ "$task" = bad ] && { printf 'fleet-issue-file: --task must be a hub record T<n>\n' >&2; exit 2; }
fi
# A key is a lock directory's name and a marker token: one safe word.
# A sighting's where is a note, never a reason to lose the filing: a malformed
# one is dropped with a line on stderr.
case "$fault_sha" in
  ''|[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) fault_sha=x ;;
esac
case "$fault_sha" in *[!0-9a-f]*) printf 'fleet-issue-file: --fault-sha is not a commit sha — ignored\n' >&2; fault_sha='' ;; esac
case "$fault_link" in *[[:space:]]*) printf 'fleet-issue-file: --fault-link is not one URL — ignored\n' >&2; fault_link='' ;; esac
case "$breakage_key" in
  ''|*[!A-Za-z0-9._-]*) [ -n "$breakage_key" ] && { printf 'fleet-issue-file: --breakage-key must be [A-Za-z0-9._-]+ (got %s)\n' "$breakage_key" >&2; exit 2; } ;;
esac
# --spawn starts a NEW worker; --bind makes the CALLER one. Asking for both is a
# caller bug with no sane resolution, so refuse before filing anything.
[ "$spawn" = 1 ] && [ "$bind" = 1 ] \
  && { printf 'fleet-issue-file: --spawn and --bind are mutually exclusive\n' >&2; exit 2; }
# --spawn from a pane that lost $TMUX_PANE (issue #1355): the spawn cannot tell
# who its parent is and refuses with exit 4 — say so BEFORE filing, so the caller
# re-runs from its pane instead of leaving a filed issue with no worker behind.
[ "$spawn" = 1 ] && fleet_pane_lost \
  && { printf 'fleet-issue-file: --spawn needs the calling pane ($TMUX is set but $TMUX_PANE is not) — the worker would have no parent to report to; run it from your scratch/worker pane\n' >&2; exit 4; }
# A worker pane (issue #4591: it may spawn like any session). A breakage it files
# WITHOUT --spawn is announced to the person and its parent (5c below).
worker_seat=0
[ "$(fleet_pane_fmt '#{@fleet_role}' 2>/dev/null)" = worker ] && worker_seat=1

# --priority pN is sugar for the priority:pN LABEL (the backlog sorts by it). Only
# p0/p1/p2 exist; a bad value is a caller bug, so reject before touching the repo.
if [ -n "$priority" ]; then
  case "$priority" in
    p0|p1|p2) labels+=("priority:$priority") ;;
    *) printf 'fleet-issue-file: --priority must be p0, p1, or p2 (got %s)\n' "$priority" >&2; exit 2 ;;
  esac
fi

# Repo resolution: an explicit --repo wins, else $CF_REPO (passed through a popup),
# else the one rule (fleet_target_repo, issue #1943): the CALLING window's repo,
# else the fleet's only one — several and a hub / no-repo pane (issue #794) ⇒
# refuse, an issue belongs to one repo. Outside a fleet: the conf's FLEET_REPO.
repo="${repo:-${CF_REPO:-}}"
_fs=$(fleet_current_session)
if [ -z "$repo" ] && [ -n "$_fs" ]; then
  _rc=0; repo=$(fleet_target_repo "$_fs") || _rc=$?
  [ "$_rc" = 4 ] && { printf 'fleet-issue-file: this fleet hosts several repos and shows all — pass --repo <owner/name>\n' >&2; exit 1; }
fi
[ -n "$repo" ] || repo="${FLEET_REPO:-}"
[ -z "$repo" ] && { printf 'fleet-issue-file: no repo resolved (set --repo or FLEET_REPO)\n' >&2; exit 1; }
# Where its tickets live (issue #3595): every write below goes through the ticket
# door, bin/fleet-ticket.sh — GitHub for today's every repo, the hub for a
# FLEET_TICKETS=hub one (which never needs gh to file).
tk_home=$(fleet_ticket_home "$repo" "$_fs")
if [ "$tk_home" = hub ]; then tkb=hub; else tkb=gh; fi
[ "$tk_home" = hub ] || command -v gh >/dev/null 2>&1 || { printf 'fleet-issue-file: gh not on PATH\n' >&2; exit 1; }

# --- 1. validate labels against the canonical taxonomy (reject off-taxonomy) ---
# The allowed set is the FIXED fleet_labels_allowed taxonomy (issue #333), the
# same set bin/fleet-labels-seed.sh installs — NOT the repo's live label list. So
# no filer can file against a label that was minted in the repo out of band
# (fixed seed, no minting), the check is deterministic + offline (no gh read),
# and it holds identically for every filer including workers. Only when labels
# were requested — the label-free fast paths (⌃n / new-session) skip it entirely.
if [ "${#labels[@]}" -gt 0 ]; then
  allowed=$(fleet_labels_allowed)
  unknown=()
  for _l in ${labels[@]+"${labels[@]}"}; do
    printf '%s\n' "$allowed" | grep -Fxq -- "$_l" || unknown+=("$_l")
  done
  if [ "${#unknown[@]}" -gt 0 ]; then
    printf 'fleet-issue-file: off-taxonomy label(s): %s\n' "$(IFS=','; printf '%s' "${unknown[*]-}")" >&2
    printf 'fleet-issue-file: allowed labels: %s\n' "$(printf '%s' "$allowed" | paste -sd ',' -)" >&2
    exit 3
  fi
fi
# The agent label (issue #2562): both at once says nothing — refused before
# anything is filed; one rides the --spawn below as --agent, so a brand-new
# issue's worker never waits for the label to reach a cache.
spawn_agent=''
if [ "${#labels[@]}" -gt 0 ]; then
  spawn_agent=$(fleet_labels_agent "$(printf '%s\n' ${labels[@]+"${labels[@]}"})") \
    || { printf 'fleet-issue-file: agent:codex and agent:claude together — pick one\n' >&2; exit 2; }
fi

# --- 1b. one issue per breakage (issue #2078) -----------------------------------
# Only with --breakage / --breakage-key (issue #4271: a red word in the text no
# longer makes a breakage). An ordinary filing runs none of this — no probe, no
# lock, no list read (the drill's degenerate leg pins it).
if [ "$breakage" = 1 ] && [ -z "$breakage_key" ]; then
  # The base branch: the window's repo overlay (FLEET_BASE_BRANCH), else the
  # probe asks GitHub for the repo's default branch.
  if [ -z "${FLEET_BASE_BRANCH:-}" ] && [ -n "$_fs" ]; then
    fleet_load_repo_conf "$_fs" "$repo" 2>/dev/null
  fi
  # The probe reads GitHub's runs: only a repo with that forge has any (issue #3599).
  if [ "$(fleet_repo_forge "$repo" "$_fs")" = none ]; then _probe=''; _prc=9
  else _probe=$(fleet_breakage_probe "$repo" "${FLEET_BASE_BRANCH:-}"); _prc=$?; fi
  _row=''
  if [ "$_prc" = 0 ]; then
    # The row this filing is about: a red check its text names, else (the base
    # branch said red) the oldest red. Explicit --breakage with no match: the
    # oldest red all the same — the caller said it is the base branch's.
    _row=$(printf '%s\n' "$_probe" | fleet_breakage_pick "$title"$'\n'"$body" "${FLEET_BASE_BRANCH:-}")
    [ -n "$_row" ] || _row=${_probe%%$'\n'*}
  fi
  if [ -n "$_row" ]; then
    breakage_key=$(printf '%s' "$_row" | cut -f1); bk_sha=$(printf '%s' "$_row" | cut -f2)
    bk_check=$(printf '%s' "$_row" | cut -f3);   bk_line=$(printf '%s' "$_row" | cut -f4)
    bk_rid=$(printf '%s' "$_row" | cut -f6)
    [ -n "$fault_sha" ] || fault_sha="$bk_sha"
    case "$bk_rid" in ''|*[!0-9]*) ;; *) [ -n "$fault_link" ] || fault_link="https://github.com/$(fleet_norm_repo "$repo")/actions/runs/$bk_rid" ;; esac
    printf 'fleet-issue-file: breakage %s — %s @ %.7s: %s\n' "$breakage_key" "$bk_check" "$bk_sha" "$bk_line" >&2
  else
    case "$_prc" in
      0|1) printf 'fleet-issue-file: --breakage: no workflow on %s is red (its last finished run) — filing an ordinary issue\n' "${FLEET_BASE_BRANCH:-the default branch}" >&2 ;;
      9)   printf 'fleet-issue-file: --breakage: %s has no forge (FLEET_FORGE=none), so no runs to fingerprint — filing without one\n' "$repo" >&2 ;;
      *)   printf 'fleet-issue-file: --breakage: gh could not read the runs of %s — filing without a fingerprint\n' "${FLEET_BASE_BRANCH:-the default branch}" >&2 ;;
    esac
  fi
fi
bk_existing=''
if [ -n "$breakage_key" ]; then
  _bk_wait="${FLEET_BREAKAGE_WAIT:-30}"; _bk_ttl="${FLEET_BREAKAGE_LOCK_SECS:-120}"
  case "$_bk_wait" in ''|*[!0-9]*) _bk_wait=30 ;; esac
  case "$_bk_ttl" in ''|*[!0-9]*) _bk_ttl=120 ;; esac
  bk_lock="$(fleet_breakage_lock_dir)/$breakage_key"
  mkdir -p "${bk_lock%/*}" 2>/dev/null
  # A lock older than the TTL is nobody's: drop it; GitHub (below) is the memory then.
  if [ -d "$bk_lock" ]; then
    _m=$(stat -c %Y "$bk_lock" 2>/dev/null || stat -f %m "$bk_lock" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - _m )) -gt "$_bk_ttl" ] && rm -rf "$bk_lock"
  fi
  if mkdir "$bk_lock" 2>/dev/null; then
    bk_held=1
  else
    # Someone on this machine is filing this breakage right now: wait for its number.
    _t=0
    while [ ! -s "$bk_lock/issue" ] && [ -d "$bk_lock" ] && [ "$_t" -lt $((_bk_wait * 10)) ]; do sleep 0.1; _t=$((_t + 1)); done
    if [ -s "$bk_lock/issue" ]; then
      bk_existing=$(bash "$BIN/fleet-ticket.sh" url "$tkb:$(fleet_norm_repo "$repo")#$(tr -dc 0-9 < "$bk_lock/issue")")
    elif mkdir "$bk_lock" 2>/dev/null; then
      bk_held=1                                   # the holder gave up (its create failed): our turn
    else
      printf 'fleet-issue-file: another filing of breakage %s is in flight on this machine (%s) and gave no number in %ss — not filing a second one (exit 5)\n' "$breakage_key" "$bk_lock" "$_bk_wait" >&2
      exit 5
    fi
  fi
  if [ "$bk_held" = 1 ] && [ -z "$bk_existing" ]; then
    # Another machine may have filed it: the marker in an open issue's body.
    if [ "$tk_home" = hub ]; then
      bk_existing=$(bash "$BIN/fleet-ticket.sh" find --repo "$repo" --marker "$(fleet_breakage_marker "$breakage_key")" 2>/dev/null) \
        && bk_existing=${bk_existing#*	} || bk_existing=''
    else
      bk_existing=$(fleet_breakage_find "$repo" "$breakage_key") || bk_existing=''
    fi
    [ -n "$bk_existing" ] && printf '%s\n' "${bk_existing##*/}" > "$bk_lock/issue"
  fi
  # None open: a CLOSED issue under the key (issue #4271) — GitHub tickets only
  # (the hub's door finds open ones). Red again on a version that contains the
  # commit that closed it ⇒ the fix did not hold: reopen it. Red on an older
  # version (a probe still testing the stable before the fix) ⇒ note it there.
  bk_closed='' bk_reopen=0 bk_fix=''
  if [ "$bk_held" = 1 ] && [ -z "$bk_existing" ] && [ "$tk_home" != hub ]; then
    _cl=$(fleet_fault_find_closed "$(fleet_norm_repo "$repo")" "$breakage_key") || _cl=''
    if [ -n "$_cl" ]; then
      bk_closed="${_cl%%	*}"; _closed_at="${_cl#*	}"
      bk_existing=$(bash "$BIN/fleet-ticket.sh" url "$tkb:$(fleet_norm_repo "$repo")#$bk_closed")
      [ -n "$bk_existing" ] || bk_existing="https://github.com/$(fleet_norm_repo "$repo")/issues/$bk_closed"
      if [ -z "$fault_sha" ]; then
        bk_reopen=1                                  # nothing says it is an old version: red is red
      elif bk_fix=$(fleet_fault_fix_commit "$(fleet_norm_repo "$repo")" "$bk_closed"); then
        fleet_fault_contains "$(fleet_norm_repo "$repo")" "$bk_fix" "$fault_sha" && bk_reopen=1
      else
        fleet_fault_after_close "$(fleet_norm_repo "$repo")" "$fault_sha" "$_closed_at" && bk_reopen=1
      fi
      if [ "$bk_reopen" = 1 ]; then
        bash "$BIN/fleet-ticket.sh" state "$tkb:$(fleet_norm_repo "$repo")#$bk_closed" open >/dev/null 2>&1 \
          || { printf 'fleet-issue-file: could not reopen %s\n' "$bk_existing" >&2; bk_reopen=0; }
      fi
      printf '%s\n' "$bk_closed" > "$bk_lock/issue"
    fi
  fi
  if [ -n "$bk_existing" ]; then
    # 「我也碰到了」: a record-only comment (no-relay — the fixer's pane is not
    # interrupted by it), who from, where (the sha + link), then the URL and exit
    # 5. Never spawn / bind. One comment per sha: a sha already on record (the
    # body it was filed with, an earlier comment) adds nothing.
    _cnum="${bk_existing##*/}"; _seen=0
    [ -n "$fault_sha" ] && [ "$tk_home" != hub ] && [ "$bk_reopen" = 0 ] \
      && fleet_fault_seen "$(fleet_norm_repo "$repo")" "$_cnum" "$fault_sha" && _seen=1
    if [ "$_seen" = 0 ]; then
      _role=$(fleet_from_role "$from")
      _who=$(fleet_origin_key 2>/dev/null); [ -n "$_who" ] || _who=$(fleet_current_session 2>/dev/null)
      # ${_who} braced: bash 3.2 under a C locale reads a following UTF-8 byte as
      # part of the name (`_who（`: unbound variable).
      _where=''
      [ -n "$fault_sha" ] && _where="：\`$(printf '%.7s' "$fault_sha")\` 上仍红${fault_link:+ — $fault_link}"
      _head="同一故障${_where}，来自 ${_role}${_who:+（${_who}）}"
      if [ "$bk_reopen" = 1 ]; then
        _head="重开：修复${bk_fix:+ \`$(printf '%.7s' "$bk_fix")\`} 之后的版本${fault_sha:+ \`$(printf '%.7s' "$fault_sha")\`} 复测仍红，修复没有生效${fault_link:+ — $fault_link}（来自 ${_role}${_who:+（${_who}）}，issue #4271：同一指纹不开新单）"
      elif [ -n "$bk_closed" ]; then
        _head="已关的同一故障在旧版本${fault_sha:+ \`$(printf '%.7s' "$fault_sha")\`} 上仍红${fault_link:+ — $fault_link}——这个版本不含修复${bk_fix:+ \`$(printf '%.7s' "$bk_fix")\`}，不重开（来自 ${_role}${_who:+（${_who}）}）"
      fi
      _cb="$_head"$'\n\n'"$(fleet_from_marker "$_role" "$repo")"$'\n'"<!-- fleet:no-relay -->"
      [ -n "$fault_sha" ] && _cb="$_cb"$'\n'"<!-- fleet:fault sha=$fault_sha -->"
      _cf=$(mktemp "${TMPDIR:-/tmp}/fleet-bk-comment.XXXXXX") && printf '%s' "$_cb" > "$_cf" \
        && bash "$BIN/fleet-ticket.sh" post "$tkb:$(fleet_norm_repo "$repo")#$_cnum" --body-file "$_cf" >/dev/null 2>&1 \
        || printf 'fleet-issue-file: could not comment on %s\n' "$bk_existing" >&2
      rm -f "${_cf:-}"
    fi
    if [ "$bk_reopen" = 1 ]; then
      printf 'fleet-issue-file: breakage %s: reopened %s — red again on a version with its fix, not filing (exit 5)\n' "$breakage_key" "$bk_existing" >&2
    elif [ -n "$bk_closed" ]; then
      printf 'fleet-issue-file: breakage %s: its issue %s is closed and %.7s predates the fix — noted there, not reopened, not filing (exit 5)\n' "$breakage_key" "$bk_existing" "$fault_sha" >&2
    elif [ "$_seen" = 1 ]; then
      printf 'fleet-issue-file: breakage %s already has an open issue: %s — %.7s is already on record there, not filing (exit 5)\n' "$breakage_key" "$bk_existing" "$fault_sha" >&2
    else
      printf 'fleet-issue-file: breakage %s already has an open issue: %s — commented there, not filing (exit 5)\n' "$breakage_key" "$bk_existing" >&2
    fi
    printf '%s\n' "$bk_existing"
    exit 5
  fi
fi

# --- 2. stamp the fleet:from provenance marker into the body -------------------
# Invisible HTML comment, so the issue reads identically to the operator; it just
# records which fleet actor filed it, from which session/issue.
role=$(fleet_from_role "$from")
marker=$(fleet_from_marker "$role" "$repo")
if [ -n "$task" ]; then   # the hub's record it was filed for (issue #3330)
  if [ -n "$body" ]; then body="$body"$'\n\n'"hub 任务 $task"; else body="hub 任务 $task"; fi
fi
if [ "$draft" = 1 ]; then   # draft-only (issue #3715): the mark + the PR note, one source
  _db=$(bash "$BIN/fleet-draft.sh" block --pr-note "$pr_note")
  if [ -n "$body" ]; then body="$body"$'\n\n'"$_db"; else body="$_db"; fi
fi
if [ -n "$body" ]; then
  body="$body"$'\n\n'"$marker"
else
  body="$marker"
fi
if [ -n "$breakage_key" ]; then
  # What the operator reads to tell two breakages apart, then the marker.
  _fp=''
  [ -n "$bk_check" ] && _fp="故障指纹：\`$bk_check\` @ \`$(printf '%.7s' "$bk_sha")\`${bk_line:+ — $bk_line}"$'\n'
  [ -z "$bk_check" ] && [ -n "$fault_sha" ] \
    && _fp="故障指纹：\`$breakage_key\`，首次见于 \`$(printf '%.7s' "$fault_sha")\`${fault_link:+ — $fault_link}（同一指纹以后只追加评论，issue #4271）"$'\n'
  body="$body"$'\n\n'"$_fp$(fleet_breakage_marker "$breakage_key")"
  [ -n "$fault_sha" ] && body="$body"$'\n'"<!-- fleet:fault sha=$fault_sha -->"
fi

# --- 2b. default milestone: guarantee every filing gets one (issue #433) --------
# A fleet opts in by setting FLEET_DEFAULT_MILESTONE (empty/unset = off, current
# behaviour unchanged). The knob lives in this fleet's per-fleet conf, which our
# callers (bin/dash-issue-new.sh, the hub) source with fleet_load_conf — but
# that DOESN'T export, so as a spawned child we wouldn't inherit it. Load this
# fleet's conf ourselves to pick it up; an already-set env value (a test, an
# explicit export) wins and skips the load. An explicit --milestone always wins.
if [ -z "${FLEET_DEFAULT_MILESTONE+set}" ]; then
  fleet_load_conf "$(fleet_current_session)" 2>/dev/null
fi
# A hub repo has no milestones: the knob is GitHub's.
if [ -z "$milestone" ] && [ -n "${FLEET_DEFAULT_MILESTONE:-}" ] && [ "$tk_home" != hub ]; then
  default_ms="$FLEET_DEFAULT_MILESTONE"
  # Ensure the milestone exists so the create's --milestone can't fail on a
  # missing one: the door POSTs it idempotently (a 422 "already_exists" just
  # means it's already there — it confirms via the list). BEST-EFFORT (issue
  # #297): on ANY failure WARN and file WITHOUT a milestone rather than wedge the
  # fast path — ⌃n must never fail to file because of milestone plumbing.
  if bash "$BIN/fleet-ticket.sh" milestone "$repo" "$default_ms" >/dev/null 2>&1; then
    milestone="$default_ms"
  else
    printf 'fleet-issue-file: could not ensure milestone %s — filing without one\n' \
      "$default_ms" >&2
  fi
fi

# --- 3. create -----------------------------------------------------------------
# A title is the issue's USE from the person's side, ≤ 20 汉字 (issue #2545): the
# sidebar names a worker after it. A long one, or one that opens on a script
# name, gets one hint line on stderr — never a refusal. A breakage title is the
# filer's own fixed shape and says nothing.
if [ "$breakage" != 1 ]; then
  _tw=$(S="$title" perl -CO -MEncode -e 'my $w = 0; for (split //, decode_utf8($ENV{S})) {
    $w += (/\p{East_Asian_Width=Wide}|\p{East_Asian_Width=Fullwidth}/ ? 2 : 1) } print $w' 2>/dev/null) || _tw=0
  _tw1=${title%%[ ：:（(]*}
  case "$_tw1" in
    fleet-*|bin/*|*.sh|*.py)
      printf 'fleet-issue-file: hint: the title opens on a script name — say what it is FOR (「每日推送没跑成」); put the script in the body (issue #2545)\n' >&2 ;;
    *) [ "${_tw:-0}" -gt 40 ] \
         && printf 'fleet-issue-file: hint: the title is %s columns — keep it to one use, ≤ 20 汉字 (「mac-a 开不了会话」); details go in the body (issue #2545)\n' "$_tw" >&2 ;;
  esac
fi
_bf=$(mktemp "${TMPDIR:-/tmp}/fleet-issue-body.XXXXXX") || exit 1
printf '%s' "$body" > "$_bf"
create_args=(--repo "$repo" --title "$title" --body-file "$_bf")
[ -n "$milestone" ] && create_args+=(--milestone "$milestone")
if [ "${#labels[@]}" -gt 0 ]; then
  for _l in ${labels[@]+"${labels[@]}"}; do create_args+=(--label "$_l"); done
fi
# The door's write step (fleet-ticket.sh new --filed): GitHub's create through the
# write throttle, or the hub's POST — the URL on stdout either way.
_task_linked=0
if [ -n "$task" ]; then
  url=$(python3 "$BIN/fleet_task_ticket.py" "$task" "$tkb" "${create_args[@]}"); _crc=$?
  if [ "$_crc" = 0 ]; then _task_linked=1
  elif [ "$_crc" = 3 ]; then
    url=$(bash "$BIN/fleet-ticket.sh" new --filed "${create_args[@]}" 2>/dev/null); _crc=$?
  fi
else
  url=$(bash "$BIN/fleet-ticket.sh" new --filed "${create_args[@]}" 2>/dev/null); _crc=$?
fi
rm -f "$_bf"
[ "$_crc" = 0 ] \
  || { [ -z "$url" ] || printf '%s\n' "$url"
       if [ -n "$task" ]; then printf 'fleet-issue-file: task %s filing/association incomplete; no spawn; retry the same dispatch\n' "$task" >&2
       elif [ "$tk_home" = hub ]; then printf 'fleet-issue-file: the hub would not open the ticket in %s (exit %s)\n' "$repo" "$_crc" >&2
       else printf 'fleet-issue-file: gh issue create failed in %s\n' "$repo" >&2; fi   # no-gh-ok: a message
       [ "$bk_held" = 1 ] && rm -rf "$bk_lock"   # a waiter may take the breakage over
       [ "$_crc" = 4 ] && exit 4
       exit 1; }
[ -z "$url" ] && { printf 'fleet-issue-file: gh issue create returned no URL\n' >&2; [ "$bk_held" = 1 ] && rm -rf "$bk_lock"; exit 1; }   # no-gh-ok: a message
printf '%s\n' "$url"                          # stdout = the URL (like gh), for the caller
num="${url##*/}"; num="${num//[^0-9]/}"
# The number is what the same-second filers on this machine are waiting for.
[ "$bk_held" = 1 ] && [ -n "$num" ] && printf '%s\n' "$num" > "$bk_lock/issue"

# --- 4. --parent: link as a sub-issue (best-effort) ----------------------------
# The sub-issues API keys off the child's numeric DATABASE id (not its #number),
# so resolve that first. A failure here NEVER loses the filed issue — it just
# stays standalone and we say so on stderr.
if [ -n "$parent" ] && [ -n "$num" ]; then
  _nr=$(fleet_norm_repo "$repo")
  if bash "$BIN/fleet-ticket.sh" link "$tkb:$_nr#$parent" "$tkb:$_nr#$num" >/dev/null 2>&1; then
    printf 'fleet-issue-file: linked #%s as a sub-issue of #%s\n' "$num" "$parent" >&2
  else
    printf 'fleet-issue-file: could not link #%s under #%s — filed standalone\n' "$num" "$parent" >&2
  fi
fi

# --- 4b. --task: hang the issue on the hub's record (issue #3330) ---------------
# Best-effort: a hub that is down loses the link, never the filed issue.
if [ -n "$task" ] && [ -n "$num" ] && [ "$_task_linked" != 1 ]; then
  bash "$BIN/fleet-task-record.sh" set "$task" --issue "$repo#$num" >/dev/null 2>&1; _trc=$?
  case "$_trc" in
    0) printf 'fleet-issue-file: #%s hung on hub record %s\n' "$num" "$task" >&2 ;;
    3) ;;
    *) printf 'fleet-issue-file: could not hang #%s on hub record %s\n' "$num" "$task" >&2 ;;
  esac
fi

# --- 5. --spawn: hand to the unchanged spawn choke point -----------------------
# dash-issue-session.sh owns the caps + cross-machine pre-spawn dedup and reports
# its own refusal (toast + a stderr reason, issue #683 — that line passes through
# to our caller untouched); a cap/dedup refusal leaves the issue FILED (files-
# without-spawning), so its non-zero exit must not fail the create. Like --bind
# below, say on stderr that the number is on the backlog, so a headless caller
# that only reads the URL on stdout still learns no worker took it.
if [ "$spawn" = 1 ] && [ -n "$num" ]; then
  # The spawn always names the repo the issue was filed in (issues #789, #1943).
  bash "$BIN/dash-issue-session.sh" "$num" --title "$title" --repo "$repo" ${spawn_agent:+--agent "$spawn_agent"} ${task:+--task "$task"}; _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf 'fleet-issue-file: filed #%s but the spawn was refused — it is on the backlog\n' "$num" >&2
    # 4 = no live parent (issue #1355): not a backlog-and-move-on refusal — the
    # caller must re-spawn from a pane that can be reported to. The URL is out.
    [ "$_rc" = 4 ] && exit 4
    [ "$_task_linked" = 1 ] && exit "$_rc"
  fi
fi

# --- 5b. --bind: promote the CALLING scratch into this issue's worker ----------
# fleet-bind.sh owns the rails (scratch-only, dedup, claim, branch rename) and
# reports its own refusal. Like --spawn, a refusal must NOT lose the just-filed
# issue: say so on stderr and still exit 0 with the URL already on stdout.
if [ "$bind" = 1 ] && [ -n "$num" ]; then
  # --fresh (issue #2235): we filed it a moment ago — no claim to check for.
  bash "$BIN/fleet-bind.sh" "$num" --title "$title" --fresh \
    || printf 'fleet-issue-file: filed #%s but the bind was refused — it is on the backlog\n' "$num" >&2
fi

# --- 5c. a worker's breakage filed without --spawn: the person and the parent told --
# Nobody spawns its fixer by itself any more (issue #4337, EPIC #4333 拍板 3): the
# person gets one breakage alert, the worker's parent session one message (an
# session may spawn it), and the issue waits — no
# queue. A parent that cannot be told is said on stderr; the filing stands.
if [ "$worker_seat" = 1 ] && [ "$spawn" != 1 ] && [ -n "$breakage_key" ] && [ -n "$num" ]; then
  _bt=$(printf '%s' "$title" | tr '\t\n' '  ')
  bash "$BIN/fleet-alerts.sh" event breakage \
    "fleet: base red — $repo#$num filed ($_bt); nobody spawned its fixer: spawn it, or ask a session to" \
    >/dev/null 2>&1 \
    || printf 'fleet-issue-file: #%s filed, but the breakage alert could not be raised\n' "$num" >&2
  _pt=''
  [ -n "$_fs" ] && _pt=$(fleet_parent_addr "$_fs" "${TMUX_PANE:-}")
  if [ -n "$_pt" ]; then
    _ps=$(printf '[breakage] the base is red — filed %s#%s: %s\nNobody spawned its fixer. Spawn it (spawn issue %s), or tell the person.\n' \
            "$repo" "$num" "$_bt" "$num" | bash "$BIN/fleet-peer-send.sh" "$_pt" - 2>&1 | head -n 1)
    printf 'fleet-issue-file: #%s — nobody spawns its fixer; the person alerted, parent told: %s\n' "$num" "$_ps" >&2
  else
    printf 'fleet-issue-file: #%s — nobody spawns its fixer; the person alerted (no parent session to tell)\n' "$num" >&2
  fi
fi
exit 0
