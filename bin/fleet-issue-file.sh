#!/bin/bash
# fleet-issue-file.sh — the ONE channel every fleet actor files a GitHub issue
# through (issue #332). Consolidates the three historical `gh issue create` sites
# — the backlog ⌃n / prefix+n filer (bin/dash-issue-new.sh), the dash new-session
# box (bin/dash-new-session.sh), and the steward's file+spawn op
# (commands/fleet-steward.md) — behind one script with one body/label/provenance
# behaviour, so a change to how the fleet files an issue lives in a single place.
#
# Responsibilities, each a small testable step:
#   1. VALIDATE any requested labels against this repo's canonical set — the live
#      `gh label list`. Reject an unknown label UP FRONT with a clear message
#      instead of an opaque `gh issue create` failure. No labels requested → no gh
#      read and no validation, so the label-free ⌃n / new-session paths add no
#      round-trip here. (When the taxonomy is codified — issue #333 — the repo's
#      labels ARE that canonical set, so this validator needs no change.)
#   2. STAMP the invisible `<!-- fleet:from role=… session=… issue=… -->`
#      provenance marker into the body via the shared fleet_from_marker helper —
#      the byte-identical marker bin/fleet-comment.sh puts on a comment (the
#      convention lives in fleet-lib.sh now; this reuses it, #224/#332).
#   3. `gh issue create` (title · body · labels · milestone).
#   4. --parent N → link the new issue as a SUB-ISSUE of N (GitHub sub-issues API);
#      best-effort — a link failure never loses the just-filed issue.
#   5. --spawn → hand the new number to the UNCHANGED bin/dash-issue-session.sh
#      spawn choke point; its session caps + cross-machine pre-spawn dedup are the
#      "reuse pre-spawn dedup helpers" the channel leans on (a filer creates a
#      brand-new number, so there is nothing to dedup until the spawn).
#
# Prints the created issue URL on stdout (exactly like `gh issue create`) so a
# caller can parse the trailing #number; all diagnostics + refusals go to stderr.
# Exit codes: 0 ok · 2 usage · 3 unknown label · 1 no-repo / create failure — so a
# caller records an honest FAIL rather than a false success.
#
# Usage:
#   fleet-issue-file.sh --title T [--body B] [--label L,...]… [--priority pN] \
#                       [--parent N] [--from ROLE] [--milestone M] \
#                       [--repo R] [--spawn]
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

title='' body='' priority='' parent='' from='' milestone='' repo='' spawn=0
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
    -h|--help)   sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)         printf 'fleet-issue-file: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)           printf 'fleet-issue-file: unexpected argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

[ -z "$title" ] && { printf 'fleet-issue-file: --title is required\n' >&2; exit 2; }

# --priority pN is sugar for the priority:pN LABEL (the backlog sorts by it). Only
# p0/p1/p2 exist; a bad value is a caller bug, so reject before touching the repo.
if [ -n "$priority" ]; then
  case "$priority" in
    p0|p1|p2) labels+=("priority:$priority") ;;
    *) printf 'fleet-issue-file: --priority must be p0, p1, or p2 (got %s)\n' "$priority" >&2; exit 2 ;;
  esac
fi

# Repo resolution mirrors bin/fleet-comment.sh / bin/dash-issue-new.sh: an explicit
# --repo wins, else $CF_REPO (passed through a popup), else this fleet's cached
# repo, else the global FLEET_REPO.
repo="${repo:-${CF_REPO:-}}"
if [ -z "$repo" ]; then
  repo="${FLEET_REPO:-}"
  _r=$(fleet_repo_cached "$(fleet_current_session)"); [ -n "$_r" ] && repo="$_r"
fi
[ -z "$repo" ] && { printf 'fleet-issue-file: no repo resolved (set --repo or FLEET_REPO)\n' >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { printf 'fleet-issue-file: gh not on PATH\n' >&2; exit 1; }

# --- 1. validate labels against the canonical set (reject unknown) -------------
# Only when labels were requested — the label-free fast paths skip the gh read.
if [ "${#labels[@]}" -gt 0 ]; then
  valid=$(gh label list --repo "$repo" --limit 200 --json name -q '.[].name' 2>/dev/null)
  if [ -n "$valid" ]; then
    unknown=()
    for _l in "${labels[@]}"; do
      printf '%s\n' "$valid" | grep -Fxq -- "$_l" || unknown+=("$_l")
    done
    if [ "${#unknown[@]}" -gt 0 ]; then
      printf 'fleet-issue-file: unknown label(s): %s\n' "$(IFS=','; printf '%s' "${unknown[*]}")" >&2
      printf 'fleet-issue-file: valid labels: %s\n' "$(printf '%s' "$valid" | paste -sd ',' -)" >&2
      exit 3
    fi
  fi
  # else: the label set was unreadable (gh down / repo has no labels) — skip
  # validation and let `gh issue create` be the backstop rather than FALSE-reject
  # during an outage, mirroring the pre-spawn dedup's degrade-to-proceed stance.
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

# --- 3. create -----------------------------------------------------------------
create_args=(--repo "$repo" --title "$title" --body "$body")
[ -n "$milestone" ] && create_args+=(--milestone "$milestone")
if [ "${#labels[@]}" -gt 0 ]; then
  for _l in "${labels[@]}"; do create_args+=(--label "$_l"); done
fi
url=$(gh issue create "${create_args[@]}" 2>/dev/null) \
  || { printf 'fleet-issue-file: gh issue create failed in %s\n' "$repo" >&2; exit 1; }
[ -z "$url" ] && { printf 'fleet-issue-file: gh issue create returned no URL\n' >&2; exit 1; }
printf '%s\n' "$url"                          # stdout = the URL (like gh), for the caller
num="${url##*/}"; num="${num//[^0-9]/}"

# --- 4. --parent: link as a sub-issue (best-effort) ----------------------------
# The sub-issues API keys off the child's numeric DATABASE id (not its #number),
# so resolve that first. A failure here NEVER loses the filed issue — it just
# stays standalone and we say so on stderr.
if [ -n "$parent" ] && [ -n "$num" ]; then
  owner="${repo%%/*}"; name="${repo#*/}"
  child_id=$(gh api "repos/$owner/$name/issues/$num" -q '.id' 2>/dev/null)
  if [ -n "$child_id" ] && gh api --method POST \
        "repos/$owner/$name/issues/$parent/sub_issues" -F sub_issue_id="$child_id" >/dev/null 2>&1; then
    printf 'fleet-issue-file: linked #%s as a sub-issue of #%s\n' "$num" "$parent" >&2
  else
    printf 'fleet-issue-file: could not link #%s under #%s — filed standalone\n' "$num" "$parent" >&2
  fi
fi

# --- 5. --spawn: hand to the unchanged spawn choke point -----------------------
# dash-issue-session.sh owns the caps + cross-machine pre-spawn dedup and toasts
# its own outcome; a cap/dedup refusal leaves the issue FILED (files-without-
# spawning), so its non-zero exit must not fail the create.
if [ "$spawn" = 1 ] && [ -n "$num" ]; then
  bash "$BIN/dash-issue-session.sh" "$num" --title "$title" || true
fi
exit 0
