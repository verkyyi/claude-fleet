#!/bin/bash
# fleet-comment.sh — the ONE sanctioned way for fleet tooling to comment on a
# bound issue when the issue-bridge (bin/fleet-issue-bridge.sh, issue #132) is in
# play. It stamps the loop-suppression marker so nothing the fleet writes to an
# issue loops back into the bound worker as a turn.
#
# The bridge relays every issue comment from a trusted author into the bound
# worker UNLESS the comment carries `<!-- fleet:no-relay -->`. Worker + steward
# share the OWNER identity, so author-filtering cannot separate them — the marker
# is the only reliable discriminator. This wrapper puts it on (or deliberately
# off) so no hand-written `gh issue comment` can accidentally feed a worker.
#
# Usage:
#   fleet-comment.sh <issue> --body "<text>"            # DEFAULT: record/no-relay
#   fleet-comment.sh <issue> --note --body "<text>"     # explicit no-relay
#   fleet-comment.sh <issue> --to-worker --body "<text>" # RELAYED into the worker
#   printf '%s' "$text" | fleet-comment.sh <issue> --note # body on stdin
#
# Modes:
#   --note       fleet-internal comment for the record/humans (worker progress,
#                PR links, steward triage) → stamped no-relay. THE DEFAULT: a
#                bare fleet comment must never accidentally drive a worker.
#   --to-worker  a message MEANT to become the worker's next turn (the steward's
#                handback, an instruction) → left UNMARKED so the bridge relays it
#                once. External/human commenters need no wrapper at all (their
#                comments are unmarked by default = relayed, subject to the gate).
#
# Repo resolution mirrors dash-issue-comment.sh: $CF_REPO wins, else this fleet's
# cached repo, else the global FLEET_REPO. Prints the created comment URL on
# success (like `gh issue comment`).
set -uo pipefail

MARKER='<!-- fleet:no-relay -->'

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

num='' body='' repo='' relay=0 have_body=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --note)      relay=0 ;;
    --to-worker) relay=1 ;;
    --body)      shift; body="${1:-}"; have_body=1 ;;
    --repo)      shift; repo="${1:-}" ;;
    -h|--help)   sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          printf 'fleet-comment: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)           num="${1//[^0-9]/}" ;;
  esac
  shift
done

[ -z "$num" ] && { printf 'fleet-comment: need an issue number\n' >&2; exit 2; }
# Body may come on stdin (a here-doc / pipe) when --body was not passed — lets a
# multi-line message be fed without shell-quoting gymnastics.
if [ "$have_body" -eq 0 ] && [ ! -t 0 ]; then body="$(cat)"; fi
[ -z "$body" ] && { printf 'fleet-comment: empty body — nothing to post\n' >&2; exit 2; }

repo="${repo:-${CF_REPO:-}}"
if [ -z "$repo" ]; then
  repo="${FLEET_REPO:-}"
  _r=$(fleet_repo_cached "$(fleet_current_session)"); [ -n "$_r" ] && repo="$_r"
fi
[ -z "$repo" ] && { printf 'fleet-comment: no repo resolved (set --repo or FLEET_REPO)\n' >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { printf 'fleet-comment: gh not on PATH\n' >&2; exit 1; }

# Stamp the marker for a record comment; leave a to-worker comment unmarked so the
# bridge relays it exactly once. The marker is an HTML comment → invisible in the
# rendered issue, but a verbatim substring the bridge greps for.
if [ "$relay" -eq 0 ]; then
  case "$body" in
    *"$MARKER"*) : ;;                    # already stamped (idempotent)
    *)           body="$body"$'\n\n'"$MARKER" ;;
  esac
fi

exec gh issue comment "$num" --repo "$repo" --body "$body"
