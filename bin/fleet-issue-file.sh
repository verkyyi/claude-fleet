#!/bin/bash
# fleet-issue-file.sh — the ONE channel every fleet actor files a GitHub issue
# through (issue #332). Consolidates the three historical `gh issue create` sites
# — the backlog ⌃n / prefix+n filer (bin/dash-issue-new.sh), the dash new-session
# box (bin/dash-new-session.sh), and the operator's file+spawn op from the hub
# — behind one script with one body/label/provenance
# behaviour, so a change to how the fleet files an issue lives in a single place.
#
# Responsibilities, each a small testable step:
#   1. VALIDATE any requested labels against the FIXED canonical taxonomy —
#      fleet_labels_allowed in fleet-lib.sh (issue #333), the same set
#      bin/fleet-labels-seed.sh installs, NOT the live `gh label list`. Reject an
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
#      key already computed (a selftest, a caller holding the probe's answer).
#      A base that is not red files an ordinary issue and says so.
#   2. STAMP the invisible `<!-- fleet:from role=… session=… issue=… -->`
#      provenance marker into the body via the shared fleet_from_marker helper —
#      the byte-identical marker bin/fleet-comment.sh puts on a comment (the
#      convention lives in fleet-lib.sh now; this reuses it, #224/#332).
#   3. `gh issue create` (title · body · labels · milestone). When no --milestone
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
#
# Prints the created issue URL on stdout (exactly like `gh issue create`) so a
# caller can parse the trailing #number; all diagnostics + refusals go to stderr.
# Exit codes: 0 ok · 2 usage · 3 unknown label · 1 no-repo / create failure ·
# 4 --spawn with no live parent (issue #1355; filed first when the spawn said it) — so a
# caller records an honest FAIL rather than a false success ·
# 5 --breakage: the breakage already has an open issue — its URL is on stdout, a
# 「同一故障」 comment is on it, nothing was filed or spawned (issue #2078).
#
# Usage:
#   fleet-issue-file.sh --title T [--body B] [--label L,...]… [--priority pN] \
#                       [--parent N] [--from ROLE] [--milestone M] \
#                       [--repo R] [--spawn | --bind] [--breakage | --breakage-key K]
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-gh-lib.sh"   # fleet_gh_write: every write below is queued (issue #1264)

title='' body='' priority='' parent='' from='' milestone='' repo='' spawn=0 bind=0
breakage=0 breakage_key='' bk_sha='' bk_check='' bk_line='' bk_lock='' bk_held=0
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
    --repo)      shift; repo="${1:-}" ;;
    --spawn)     spawn=1 ;;
    --bind)      bind=1 ;;
    --breakage)  breakage=1 ;;
    --breakage-key) shift; breakage_key="${1:-}" ;;
    -h|--help)   sed -n '2,63p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)         printf 'fleet-issue-file: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)           printf 'fleet-issue-file: unexpected argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

[ -z "$title" ] && { printf 'fleet-issue-file: --title is required\n' >&2; exit 2; }
# A key is a lock directory's name and a marker token: one safe word.
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
command -v gh >/dev/null 2>&1 || { printf 'fleet-issue-file: gh not on PATH\n' >&2; exit 1; }

# --- 1. validate labels against the canonical taxonomy (reject off-taxonomy) ---
# The allowed set is the FIXED fleet_labels_allowed taxonomy (issue #333), the
# same set bin/fleet-labels-seed.sh installs — NOT the live `gh label list`. So
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

# --- 1b. one issue per breakage (issue #2078) -----------------------------------
# Only with --breakage / --breakage-key: an ordinary filing runs none of this —
# no probe, no lock, no list read (the drill's degenerate leg pins it).
if [ "$breakage" = 1 ] && [ -z "$breakage_key" ]; then
  # The base branch: the window's repo overlay (FLEET_BASE_BRANCH), else the
  # probe asks GitHub for the repo's default branch.
  if [ -z "${FLEET_BASE_BRANCH:-}" ] && [ -n "$_fs" ]; then
    fleet_load_repo_conf "$_fs" "$repo" 2>/dev/null
  fi
  _probe=$(fleet_breakage_probe "$repo" "${FLEET_BASE_BRANCH:-}"); _prc=$?
  case "$_prc" in
    0) IFS=$'\t' read -r breakage_key bk_sha bk_check bk_line <<EOF
$_probe
EOF
       printf 'fleet-issue-file: breakage %s — %s @ %.7s: %s\n' "$breakage_key" "$bk_check" "$bk_sha" "$bk_line" >&2 ;;
    1) printf 'fleet-issue-file: --breakage: %s has no failed check at its head — not red; filing an ordinary issue\n' "${FLEET_BASE_BRANCH:-the default branch}" >&2 ;;
    *) printf 'fleet-issue-file: --breakage: gh could not read the checks of %s — filing without a fingerprint\n' "${FLEET_BASE_BRANCH:-the default branch}" >&2 ;;
  esac
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
      bk_existing="https://github.com/$repo/issues/$(tr -dc 0-9 < "$bk_lock/issue")"
    elif mkdir "$bk_lock" 2>/dev/null; then
      bk_held=1                                   # the holder gave up (its create failed): our turn
    else
      printf 'fleet-issue-file: another filing of breakage %s is in flight on this machine (%s) and gave no number in %ss — not filing a second one (exit 5)\n' "$breakage_key" "$bk_lock" "$_bk_wait" >&2
      exit 5
    fi
  fi
  if [ "$bk_held" = 1 ] && [ -z "$bk_existing" ]; then
    # Another machine may have filed it: the marker in an open issue's body.
    bk_existing=$(fleet_breakage_find "$repo" "$breakage_key") || bk_existing=''
    [ -n "$bk_existing" ] && printf '%s\n' "${bk_existing##*/}" > "$bk_lock/issue"
  fi
  if [ -n "$bk_existing" ]; then
    # 「我也碰到了」: a record-only comment (no-relay — the fixer's pane is not
    # interrupted by it), who from, then the URL and exit 5. Never spawn / bind.
    _role=$(fleet_from_role "$from")
    _who=$(fleet_origin_key 2>/dev/null); [ -n "$_who" ] || _who=$(fleet_current_session 2>/dev/null)
    # ${_who} braced: bash 3.2 under a C locale reads a following UTF-8 byte as
    # part of the name (`_who（`: unbound variable).
    _cb="同一故障，来自 ${_role}${_who:+（${_who}）}"$'\n\n'"$(fleet_from_marker "$_role" "$repo")"$'\n'"<!-- fleet:no-relay -->"
    _cnum="${bk_existing##*/}"
    if ! fleet_gh_write issue comment "$_cnum" --repo "$repo" --body "$_cb" >/dev/null 2>&1; then
      _cf=$(mktemp "${TMPDIR:-/tmp}/fleet-bk-comment.XXXXXX") && printf '%s' "$_cb" > "$_cf" \
        && fleet_gh_rest_comment "$repo" "$_cnum" "$_cf" >/dev/null 2>&1 \
        || printf 'fleet-issue-file: could not comment on %s\n' "$bk_existing" >&2
      rm -f "${_cf:-}"
    fi
    printf 'fleet-issue-file: breakage %s already has an open issue: %s — commented there, not filing (exit 5)\n' "$breakage_key" "$bk_existing" >&2
    printf '%s\n' "$bk_existing"
    exit 5
  fi
fi

# --- 2. stamp the fleet:from provenance marker into the body -------------------
# Invisible HTML comment, so the issue reads identically to the operator; it just
# records which fleet actor filed it, from which session/issue.
role=$(fleet_from_role "$from")
marker=$(fleet_from_marker "$role" "$repo")
if [ -n "$body" ]; then
  body="$body"$'\n\n'"$marker"
else
  body="$marker"
fi
if [ -n "$breakage_key" ]; then
  # What the operator reads to tell two breakages apart, then the marker.
  _fp=''
  [ -n "$bk_check" ] && _fp="故障指纹：\`$bk_check\` @ \`$(printf '%.7s' "$bk_sha")\`${bk_line:+ — $bk_line}"$'\n'
  body="$body"$'\n\n'"$_fp$(fleet_breakage_marker "$breakage_key")"
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
if [ -z "$milestone" ] && [ -n "${FLEET_DEFAULT_MILESTONE:-}" ]; then
  default_ms="$FLEET_DEFAULT_MILESTONE"
  owner="${repo%%/*}"; name="${repo#*/}"
  # Ensure the milestone exists so `gh issue create --milestone` can't fail on a
  # missing one: idempotently POST it (a 422 "already_exists" just means it's
  # already there — confirm via the list). BEST-EFFORT (issue #297): on ANY
  # failure WARN and file WITHOUT a milestone rather than wedge the fast path —
  # ⌃n must never fail to file because of milestone plumbing.
  if fleet_gh_write api --method POST "repos/$owner/$name/milestones" \
        -f title="$default_ms" -f state=open >/dev/null 2>&1; then
    milestone="$default_ms"                       # freshly created
  elif gh api "repos/$owner/$name/milestones" --paginate -q '.[].title' 2>/dev/null \
        | grep -Fxq -- "$default_ms"; then
    milestone="$default_ms"                       # already existed (create 422'd)
  else
    printf 'fleet-issue-file: could not ensure milestone %s — filing without one\n' \
      "$default_ms" >&2
  fi
fi

# --- 3. create -----------------------------------------------------------------
create_args=(--repo "$repo" --title "$title" --body "$body")
[ -n "$milestone" ] && create_args+=(--milestone "$milestone")
if [ "${#labels[@]}" -gt 0 ]; then
  for _l in ${labels[@]+"${labels[@]}"}; do create_args+=(--label "$_l"); done
fi
url=$(fleet_gh_write issue create "${create_args[@]}" 2>/dev/null) \
  || { printf 'fleet-issue-file: gh issue create failed in %s\n' "$repo" >&2
       [ "$bk_held" = 1 ] && rm -rf "$bk_lock"   # a waiter may take the breakage over
       exit 1; }
[ -z "$url" ] && { printf 'fleet-issue-file: gh issue create returned no URL\n' >&2; [ "$bk_held" = 1 ] && rm -rf "$bk_lock"; exit 1; }
printf '%s\n' "$url"                          # stdout = the URL (like gh), for the caller
num="${url##*/}"; num="${num//[^0-9]/}"
# The number is what the same-second filers on this machine are waiting for.
[ "$bk_held" = 1 ] && [ -n "$num" ] && printf '%s\n' "$num" > "$bk_lock/issue"

# --- 4. --parent: link as a sub-issue (best-effort) ----------------------------
# The sub-issues API keys off the child's numeric DATABASE id (not its #number),
# so resolve that first. A failure here NEVER loses the filed issue — it just
# stays standalone and we say so on stderr.
if [ -n "$parent" ] && [ -n "$num" ]; then
  owner="${repo%%/*}"; name="${repo#*/}"
  child_id=$(gh api "repos/$owner/$name/issues/$num" -q '.id' 2>/dev/null)
  if [ -n "$child_id" ] && fleet_gh_write api --method POST \
        "repos/$owner/$name/issues/$parent/sub_issues" -F sub_issue_id="$child_id" >/dev/null 2>&1; then
    printf 'fleet-issue-file: linked #%s as a sub-issue of #%s\n' "$num" "$parent" >&2
  else
    printf 'fleet-issue-file: could not link #%s under #%s — filed standalone\n' "$num" "$parent" >&2
  fi
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
  bash "$BIN/dash-issue-session.sh" "$num" --title "$title" --repo "$repo"; _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf 'fleet-issue-file: filed #%s but the spawn was refused — it is on the backlog\n' "$num" >&2
    # 4 = no live parent (issue #1355): not a backlog-and-move-on refusal — the
    # caller must re-spawn from a pane that can be reported to. The URL is out.
    [ "$_rc" = 4 ] && exit 4
  fi
fi

# --- 5b. --bind: promote the CALLING scratch into this issue's worker ----------
# fleet-bind.sh owns the rails (scratch-only, dedup, claim, branch rename) and
# reports its own refusal. Like --spawn, a refusal must NOT lose the just-filed
# issue: say so on stderr and still exit 0 with the URL already on stdout.
if [ "$bind" = 1 ] && [ -n "$num" ]; then
  bash "$BIN/fleet-bind.sh" "$num" --title "$title" \
    || printf 'fleet-issue-file: filed #%s but the bind was refused — it is on the backlog\n' "$num" >&2
fi
exit 0
