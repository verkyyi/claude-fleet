#!/bin/bash
# fleet-ticket.sh — the ONE door to a ticket (issue #2676, EPIC #2668 C8, 共同约定 6).
#
# A ticket is the abstraction; GitHub is its first backend. A ticket id reads
# `gh:<owner/name>#<N>`; `hub:<N>` is reserved for the hub backend of the next
# batch and refused here (exit 2). Every verb runs the fleet script that already
# owns that job — nothing here talks to GitHub on its own but `children`, `list`,
# `state` and `new`'s label check; the writes go through the one throttle (fleet_gh_write).
#
#   fleet-ticket.sh read     <id> [--json f,g] [--max-age S]   → fleet-gh.sh issue view (cache first)
#   fleet-ticket.sh comment  <id> [--to-worker|--note] [--close] (--body T | --body-file F)
#                                                              → fleet-comment.sh (marker + footer)
#   fleet-ticket.sh edit     <id> (--body T | --body-file F|-)    → gh issue edit --body via fleet_gh_write
#   fleet-ticket.sh state    <id> open|closed [--reason completed|not_planned]
#                                                              → gh issue reopen|close via fleet_gh_write
#   fleet-ticket.sh children <id>                              → one `gh:<repo>#<N>\t<state>` per sub-issue
#   fleet-ticket.sh list     --repo R [--label L] [--state open|closed|all] [--since YYYY-MM-DD] [--limit N]
#                                                              → one `gh:<repo>#<N>\t<state>` per ticket
#   fleet-ticket.sh evidence <id> <before|after|live|post|list|line|dir> [fleet-evidence.sh opts…]
#                                                              → fleet-evidence.sh --repo --issue
#   fleet-ticket.sh new      --repo R --title T [--body B] [--origin K] [--label L]
#                                                              → files a desk ticket, prints its id
#   fleet-ticket.sh parse    <id>                              → `<owner/name>\t<N>`
#
# `new` is the desk's filer (dash-raw-session.sh's no-code session): it files
# through fleet-issue-file.sh — the one filer channel, so the provenance marker
# and the label taxonomy apply — with the `desk` label (minted in the repo once
# if it lacks it), then registers ONE row on the hub (`POST
# /v1/fleet/tickets/register`, the node token read inside the subshell that runs
# curl — never exported, #1491). The hub keeps the registry row only (id · owner
# · title · state · backend · url · origin); the body and the thread stay on
# GitHub. No hub (CCQUOTA_FLEET≠1, no token, no answer) ⇒ not registered, the
# ticket stands all the same; the reason goes to stderr and the exit is 0.
#
# Exit: 0 ok · 1 the backend failed · 2 usage (a bad id, `hub:` reserved).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-gh-lib.sh"

die() { printf 'fleet-ticket: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '9,23p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# ticket_parse <id> → `<owner/name>\t<N>`; rc 2 = not an id this batch reads.
ticket_parse() {
  local id="${1:-}" repo n
  case "$id" in
    hub:*) printf 'fleet-ticket: %s — the hub backend (hub:N) is reserved for the next batch; only gh:<owner/name>#<N> reads here\n' "$id" >&2
           return 2 ;;
    gh:?*/?*#[0-9]*) id=${id#gh:}; repo=${id%%#*}; n=${id##*#} ;;
    *) printf 'fleet-ticket: %s is not a ticket id — write gh:<owner/name>#<N>\n' "${id:-(empty)}" >&2
       return 2 ;;
  esac
  case "$n" in ''|*[!0-9]*) printf 'fleet-ticket: %s — the number is not a number\n' "$1" >&2; return 2 ;; esac
  case "$repo" in */*/*|*[!A-Za-z0-9._/-]*) printf 'fleet-ticket: %s — not an owner/name repo\n' "$1" >&2; return 2 ;; esac
  printf '%s\t%s\n' "$repo" "$n"
}

# ticket_register <id> <title> <url> <origin> — one row on the hub; never fatal.
ticket_register() {
  local id="$1" title="$2" url="$3" origin="$4" body resp code why
  if [ "${CCQUOTA_FLEET:-0}" != 1 ]; then
    printf 'fleet-ticket: not registered — the hub module is off (CCQUOTA_FLEET≠1)\n' >&2; return 0
  fi
  if why=$(_fleet_hub_creds_missing); then
    printf 'fleet-ticket: not registered — %s\n' "$why" >&2; return 0
  fi
  body=$(python3 -c '
import json, sys
id_, title, url, origin = sys.argv[1:5]
print(json.dumps({"id": id_, "backend": "gh", "title": title, "state": "open",
                  "url": url, "origin": origin}, ensure_ascii=False))' "$id" "$title" "$url" "$origin") || return 0
  resp=$(_fleet_hub_env
    "${FLEET_HUB_CURL:-curl}" -sS --max-time "${FLEET_HUB_TIMEOUT:-10}" -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${CCQUOTA_TOKEN:-}" -H 'Content-Type: application/json' \
      -X POST --data-binary "$body" "${CCQUOTA_HUB_URL%/}/v1/fleet/tickets/register" 2>/dev/null)
  code=${resp:-000}
  case "$code" in
    200|201) printf 'fleet-ticket: registered %s on the hub\n' "$id" >&2 ;;
    404|405) printf 'fleet-ticket: not registered — the hub has no /v1/fleet/tickets/register yet (HTTP %s)\n' "$code" >&2 ;;
    *)       printf 'fleet-ticket: not registered — the hub answered HTTP %s\n' "$code" >&2 ;;
  esac
  return 0
}

verb="${1:-}"; [ -n "$verb" ] || usage; shift

case "$verb" in
  parse)
    ticket_parse "${1:-}" || exit 2 ;;

  read)
    p=$(ticket_parse "${1:-}") || exit 2; shift
    exec bash "$BIN/fleet-gh.sh" issue view "${p#*	}" --repo "${p%%	*}" "$@" ;;

  comment)
    p=$(ticket_parse "${1:-}") || exit 2; shift
    exec bash "$BIN/fleet-comment.sh" "${p#*	}" --repo "${p%%	*}" "$@" ;;

  state)
    p=$(ticket_parse "${1:-}") || exit 2; shift
    want="${1:-}"; shift 2>/dev/null || :
    reason=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reason)   reason="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        --reason=*) reason="${1#--reason=}"; shift ;;
        *) die "state: unknown argument '$1'" 2 ;;
      esac
    done
    case "$reason" in ''|completed|not_planned) ;; *) die "state: --reason is completed or not_planned" 2 ;; esac
    case "$want" in
      open)   fleet_gh_write issue reopen "${p#*	}" --repo "${p%%	*}" >/dev/null || die "could not reopen ${1:-the ticket}" ;;
      closed) fleet_gh_write issue close "${p#*	}" --repo "${p%%	*}" ${reason:+--reason "${reason/_/ }"} >/dev/null \
                || die "could not close the ticket" ;;
      *) die "state: say open or closed" 2 ;;
    esac
    printf '%s\n' "$want" ;;

  edit)
    # A desk ticket's body is its list (the steward's 「待你动手」, issue #2672):
    # replaced whole, through the one write throttle.
    p=$(ticket_parse "${1:-}") || exit 2; shift
    ebody=''; efile=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --body)      ebody="${2-}"; efile=''; shift; [ "$#" -gt 0 ] && shift ;;
        --body-file) efile="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        *) die "edit: unknown argument '$1'" 2 ;;
      esac
    done
    if [ "$efile" = - ]; then ebody=$(cat); efile=''; fi
    [ -z "$efile" ] || [ -r "$efile" ] || die "edit: cannot read $efile" 2
    if [ -z "$efile" ]; then
      [ -n "$ebody" ] || die "edit: say --body or --body-file" 2
      efile=$(mktemp "${TMPDIR:-/tmp}/fleet-ticket-edit.XXXXXX") || die "edit: no temp file"
      printf '%s\n' "$ebody" > "$efile"
      fleet_gh_write issue edit "${p#*	}" --repo "${p%%	*}" --body-file "$efile" >/dev/null; rc=$?
      rm -f "$efile"
    else
      fleet_gh_write issue edit "${p#*	}" --repo "${p%%	*}" --body-file "$efile" >/dev/null; rc=$?
    fi
    [ "$rc" = 0 ] || die "could not edit the ticket"
    printf 'edited\n' ;;

  children)
    p=$(ticket_parse "${1:-}") || exit 2
    out=$(fleet_sub_issues "${p%%	*}" "${p#*	}") || die "could not read the sub-issues of gh:${p%%	*}#${p#*	}"
    [ -n "$out" ] || exit 0
    printf '%s\n' "$out" | awk -F'\t' 'NF >= 3 { printf "gh:%s#%s\t%s\n", $1, $2, tolower($3) }' ;;

  list)
    # Tickets of one repo by label / state / last update (the daily brief's
    # 默认拍板 reader walks the `epic` ones, issue #2679). A read: plain gh.
    repo=''; label=''; lstate=open; since=''; limit=100
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo)  repo="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        --label) label="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        --state) lstate="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        --since) since="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        --limit) limit="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        *) die "list: unknown argument '$1'" 2 ;;
      esac
    done
    repo=$(fleet_norm_repo "$repo")
    [ -n "$repo" ] || die "list: --repo is required" 2
    case "$lstate" in open|closed|all) ;; *) die "list: --state is open, closed or all" 2 ;; esac
    case "$since" in ''|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) die "list: --since is YYYY-MM-DD" 2 ;; esac
    case "$limit" in ''|*[!0-9]*) die "list: --limit is a number" 2 ;; esac
    out=$(gh issue list --repo "$repo" --state "$lstate" --limit "$limit" ${label:+--label "$label"} \
            ${since:+--search "updated:>=$since"} --json number,state -q '.[] | "\(.number)\t\(.state)"') \
      || die "could not list the tickets of $repo"
    [ -n "$out" ] || exit 0
    printf '%s\n' "$out" | awk -F'\t' -v r="$repo" 'NF >= 2 { printf "gh:%s#%s\t%s\n", r, $1, tolower($2) }' ;;

  evidence)
    p=$(ticket_parse "${1:-}") || exit 2; shift
    sub="${1:-}"; [ -n "$sub" ] || die "evidence: say before|after|live|post|list|line|dir" 2
    shift
    exec bash "$BIN/fleet-evidence.sh" "$sub" --repo "${p%%	*}" --issue "${p#*	}" "$@" ;;

  new)
    repo=''; title=''; tbody=''; origin=''; label=desk
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo)    repo="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        --title)   title="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        --body)    tbody="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        --origin)  origin="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        --label)   label="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        *) die "new: unknown argument '$1'" 2 ;;
      esac
    done
    repo=$(fleet_norm_repo "$repo")
    [ -n "$repo" ] || die "new: --repo is required" 2
    [ -n "${title//[[:space:]]/}" ] || die "new: --title is required" 2
    # The label exists in the repo, or the create would fail: mint it once (the
    # canonical row — fleet_labels_canonical — is its colour and words).
    if [ -n "$label" ] && ! gh label list --repo "$repo" --limit 200 --json name -q '.[].name' 2>/dev/null | grep -qxF -- "$label"; then
      row=$(fleet_labels_canonical | awk -F'|' -v l="$label" '$1 == l { print; exit }')
      [ -n "$row" ] && fleet_gh_write label create "$label" --repo "$repo" \
        --color "$(printf '%s' "$row" | cut -d'|' -f2)" --description "$(printf '%s' "$row" | cut -d'|' -f3)" >/dev/null 2>&1 || :
    fi
    url=$(bash "$BIN/fleet-issue-file.sh" --repo "$repo" --title "$title" --body "$tbody" \
            ${label:+--label "$label"} --no-breakage) || die "new: filing in $repo failed"
    n=${url##*/}
    case "$n" in ''|*[!0-9]*) die "new: the filer returned no issue URL ($url)" ;; esac
    id="gh:$repo#$n"
    ticket_register "$id" "$title" "$url" "$origin"
    printf '%s\t%s\n' "$id" "$url" ;;

  -h|--help|help) usage ;;
  *) die "unknown verb '$verb' — read|comment|edit|state|children|list|evidence|new|parse" 2 ;;
esac
