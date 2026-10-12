#!/bin/bash
# fleet-ticket.sh — the ONE door to a ticket (issues #2676, #3595; EPIC #3570 C2,
# 共同约定 1–2).
#
# A ticket is (repo, number). Its id says where it lives: `gh:<owner/name>#<N>` on
# GitHub, `hub:<owner/name>#<N>` on the hub (C1's /v1/fleet/tickets). A repo has
# ONE home — its repo conf's FLEET_TICKETS=hub|github (`fleet_ticket_home`, unset =
# github, byte for byte as before) — and `id` mints the id from it. Every verb on a
# hub ticket runs bin/fleet_ticket.py (the python door, the only hub client: the
# node token read in the subshell that runs it, never exported — #1491); every
# verb on a gh ticket runs here exactly as it always did, the writes through the
# one throttle (fleet_gh_write). Nothing else in the fleet should spell a ticket
# write: bin/no-direct-gh-selftest.sh counts who still does.
#
#   fleet-ticket.sh read     <id> [--json f,g] [--max-age S]   → fleet-gh.sh issue view (cache first)
#   fleet-ticket.sh comment  <id> [--to-worker|--note] [--close] (--body T | --body-file F)
#                                                              → fleet-comment.sh (marker + footer)
#   fleet-ticket.sh edit     <id> (--body T | --body-file F|-)    → the body, replaced whole
#   fleet-ticket.sh state    <id> open|closed [--reason completed|not_planned]
#   fleet-ticket.sh children <id>                              → one `<id>\t<state>` per sub-ticket
#   fleet-ticket.sh parent   <id>                              → the parent's id (1 = none)
#   fleet-ticket.sh list     --repo R [--label L] [--state open|closed|all] [--since YYYY-MM-DD] [--limit N]
#                                                              → one `<id>\t<state>` per ticket
#   fleet-ticket.sh evidence <id> <before|after|live|post|list|line|dir> [fleet-evidence.sh opts…]
#   fleet-ticket.sh new      --repo R --title T [--body B] [--origin K] [--label L]
#                                                              → files a desk ticket, prints `<id>\t<url>`
#   fleet-ticket.sh claim    <id> [--by WHO] [--release]       → `claimed\t<who>` | released (3 = taken)
#   fleet-ticket.sh label    add|rm <id> <label>…              → the ticket's labels, comma-joined
#   fleet-ticket.sh priority <id> p0|p1|p2|p3|none
#   fleet-ticket.sh link     <parent-id> <child-id> [--remove] → hang a sub-ticket on a ticket
#   fleet-ticket.sh id       <owner/name> <N>                  → the id, by the repo's home
#   fleet-ticket.sh home     <owner/name>                      → hub | github
#   fleet-ticket.sh url      <id>                              → where a person opens it
#   fleet-ticket.sh parse    <id>                              → `<owner/name>\t<N>`
#
# The writing wrappers' raw steps (they compose the body; the door only carries it):
#   fleet-ticket.sh post <id> (--body T | --body-file F)       → one comment as given, its URL (fleet-comment.sh)
#   fleet-ticket.sh close <id>                                 → closed, nothing printed (fleet-comment.sh --close)
#   fleet-ticket.sh new --filed --repo R --title T [--body-file F] [--label L]… [--milestone M]
#                                                              → the created ticket's URL (fleet-issue-file.sh)
#   fleet-ticket.sh milestone <owner/name> <title>             → ensure a GitHub milestone (hub: none, exit 1)
#   fleet-ticket.sh find --repo R --marker S                   → `<id>\t<url>` of an open ticket carrying S
#
# `new` (no --filed) is the desk's filer (dash-raw-session.sh's no-code session):
# it files through fleet-issue-file.sh — the one filer channel, so the provenance
# marker and the label taxonomy apply — with the `desk` label (minted in a GitHub
# repo once if it lacks it), then, for a gh ticket, registers ONE row on the hub
# (`POST /v1/fleet/tickets/register`). A hub ticket is the hub's already. No hub
# (CCQUOTA_FLEET≠1, no token, no answer) ⇒ not registered, the ticket stands all
# the same; the reason goes to stderr and the exit is 0.
#
# Exit: 0 ok · 1 the backend failed · 2 usage (a bad id) · 3 claim conflict ·
# 4 the hub is not reachable (no answer, or no node token).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-gh-lib.sh"

die() { printf 'fleet-ticket: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '15,42p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# ticket_parse <id> → `<owner/name>\t<N>`; rc 2 = not a ticket id. The backend is
# the id's own prefix (`ticket_backend`).
ticket_parse() {
  local id="${1:-}" repo n
  case "$id" in
    gh:?*/?*#[0-9]*)  id=${id#gh:}; repo=${id%%#*}; n=${id##*#} ;;
    hub:?*/?*#[0-9]*) id=${id#hub:}; repo=${id%%#*}; n=${id##*#} ;;
    *) printf 'fleet-ticket: %s is not a ticket id — write gh:<owner/name>#<N> or hub:<owner/name>#<N>\n' "${id:-(empty)}" >&2
       return 2 ;;
  esac
  case "$n" in ''|*[!0-9]*) printf 'fleet-ticket: %s — the number is not a number\n' "$1" >&2; return 2 ;; esac
  case "$repo" in */*/*|*[!A-Za-z0-9._/-]*) printf 'fleet-ticket: %s — not an owner/name repo\n' "$1" >&2; return 2 ;; esac
  printf '%s\t%s\n' "$repo" "$n"
}
ticket_backend() { case "${1:-}" in hub:*) printf hub ;; *) printf gh ;; esac; }

# hub <verb> <args…> — the python door, inside the subshell that loads the node
# token (never exported to the caller, #1491). It never comes back here.
hub() { ( _fleet_hub_env; exec python3 "$BIN/fleet_ticket.py" --backend hub "$@" ); }

# repo_home <repo> → hub | github (fleet_ticket_home: the repo conf's FLEET_TICKETS).
repo_home() { fleet_ticket_home "$1"; }

# opt_repo <args…> → the value of --repo among them.
opt_repo() {
  while [ "$#" -gt 0 ]; do
    case "$1" in --repo) printf '%s' "${2:-}"; return ;; --repo=*) printf '%s' "${1#--repo=}"; return ;; esac
    shift
  done
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

  home)
    r=$(fleet_norm_repo "${1:-}"); [ -n "$r" ] || die "home: say <owner/name>" 2
    repo_home "$r"; echo ;;

  id)
    r=$(fleet_norm_repo "${1:-}"); n="${2:-}"
    [ -n "$r" ] || die "id: say <owner/name> <N>" 2
    case "$n" in ''|*[!0-9]*) die "id: the number is not a number" 2 ;; esac
    if [ "$(repo_home "$r")" = hub ]; then printf 'hub:%s#%s\n' "$r" "$n"; else printf 'gh:%s#%s\n' "$r" "$n"; fi ;;

  url)
    p=$(ticket_parse "${1:-}") || exit 2
    if [ "$(ticket_backend "$1")" = hub ]; then
      u=$(_fleet_hub_env; printf '%s' "${CCQUOTA_HUB_URL:-}")
      [ -n "$u" ] || die "url: no hub address here (node.env)" 4
      printf '%s/fleet/tickets/%s/%s\n' "${u%/}" "${p%%	*}" "${p#*	}"
    else
      printf 'https://github.com/%s/issues/%s\n' "${p%%	*}" "${p#*	}"
    fi ;;

  read)
    p=$(ticket_parse "${1:-}") || exit 2
    [ "$(ticket_backend "$1")" = hub ] && { hub read "$@"; exit $?; }
    shift
    exec bash "$BIN/fleet-gh.sh" issue view "${p#*	}" --repo "${p%%	*}" "$@" ;;

  comment)
    p=$(ticket_parse "${1:-}") || exit 2
    b=$(ticket_backend "$1"); shift
    FLEET_TICKET_BACKEND=$b exec bash "$BIN/fleet-comment.sh" "${p#*	}" --repo "${p%%	*}" "$@" ;;

  post)
    # The raw comment (fleet-comment.sh composed it). GitHub: GraphQL, then REST
    # when the budget is spent (issue #1042), through the write queue (#1264).
    p=$(ticket_parse "${1:-}") || exit 2
    [ "$(ticket_backend "$1")" = hub ] && { hub post "$@"; exit $?; }
    shift
    num="${p#*	}"; repo="${p%%	*}"; pbody=''; pfile=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --body)      pbody="${2-}"; shift; [ "$#" -gt 0 ] && shift ;;
        --body-file) pfile="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        *) die "post: unknown argument '$1'" 2 ;;
      esac
    done
    if [ -n "$pfile" ]; then
      [ -r "$pfile" ] || die "post: cannot read $pfile" 2
      pbody=$(cat "$pfile"; printf x); pbody=${pbody%x}
    fi
    [ -n "$pbody" ] || die "post: empty body" 2
    out=$(fleet_gh_wrun graphql comment issue comment "$num" --repo "$repo" --body "$pbody"); rc=$?
    if [ "$rc" -eq 0 ]; then [ -n "$out" ] && printf '%s\n' "$out"; exit 0; fi
    [ "$rc" -eq "$FLEET_GH_LIMITED_RC" ] || exit "$rc"
    tmp=$(mktemp "${TMPDIR:-/tmp}/fleet-comment.XXXXXX") || exit 1
    printf '%s' "$pbody" > "$tmp"
    out=$(fleet_gh_rest_comment "$repo" "$num" "$tmp"); rc=$?
    rm -f "$tmp"
    [ "$rc" -eq 0 ] || exit "$rc"
    printf 'fleet-comment: GraphQL rate-limited — posted via REST\n' >&2
    fleet_gh_log "fallback-ok op=comment repo=$repo issue=$num"
    [ -n "$out" ] && printf '%s\n' "$out"
    exit 0 ;;

  close)
    p=$(ticket_parse "${1:-}") || exit 2
    [ "$(ticket_backend "$1")" = hub ] && { hub close "$1" >/dev/null; exit $?; }
    num="${p#*	}"; repo="${p%%	*}"
    fleet_gh_wrun graphql comment issue close "$num" --repo "$repo"; rc=$?
    [ "$rc" -eq "$FLEET_GH_LIMITED_RC" ] || exit "$rc"
    fleet_gh_rest_issue_close "$repo" "$num" >/dev/null || exit $?
    printf 'fleet-comment: GraphQL rate-limited — closed #%s via REST\n' "$num" >&2
    fleet_gh_log "fallback-ok op=close repo=$repo issue=$num"
    exit 0 ;;

  state)
    p=$(ticket_parse "${1:-}") || exit 2
    [ "$(ticket_backend "$1")" = hub ] && { hub state "$@"; exit $?; }
    shift
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
    p=$(ticket_parse "${1:-}") || exit 2
    [ "$(ticket_backend "$1")" = hub ] && { hub edit "$@"; exit $?; }
    shift
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
    [ "$(ticket_backend "$1")" = hub ] && { hub children "$1"; exit $?; }
    out=$(fleet_sub_issues "${p%%	*}" "${p#*	}") || die "could not read the sub-issues of gh:${p%%	*}#${p#*	}"
    [ -n "$out" ] || exit 0
    printf '%s\n' "$out" | awk -F'\t' 'NF >= 3 { printf "gh:%s#%s\t%s\n", $1, $2, tolower($3) }' ;;

  parent)
    # The ticket this one hangs under (issue #3599): GitHub's sub-issue parent,
    # the hub's parent field. Nothing hangs it ⇒ exit 1, nothing printed.
    p=$(ticket_parse "${1:-}") || exit 2
    [ "$(ticket_backend "$1")" = hub ] && { hub parent "$1"; exit $?; }
    out=$(gh api "repos/${p%%	*}/issues/${p#*	}/parent" \
            --jq '"\(.repository_url | sub("^.*/repos/"; ""))\t\(.number)"' 2>/dev/null) || exit 1
    pr=$(fleet_norm_repo "${out%%	*}"); pn="${out##*	}"
    case "$pn" in ''|*[!0-9]*) exit 1 ;; esac
    [ -n "$pr" ] || exit 1
    printf 'gh:%s#%s\n' "$pr" "$pn" ;;

  list)
    # Tickets of one repo by label / state / last update (the daily brief's
    # 默认拍板 reader walks the `epic` ones, issue #2679). A read: plain gh.
    r=$(fleet_norm_repo "$(opt_repo "$@")")
    [ -n "$r" ] && [ "$(repo_home "$r")" = hub ] && { hub list "$@"; exit $?; }
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
    case " $* " in *" --filed "*)
      # The filer's write step (fleet-issue-file.sh composed title, body, labels).
      r=$(fleet_norm_repo "$(opt_repo "$@")")
      [ -n "$r" ] && [ "$(repo_home "$r")" = hub ] && { hub new "$@"; exit $?; }
      # --body-file becomes --body in its own place: gh gets the argv it always got.
      cargs=()
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --filed) shift ;;
          --body-file)
            [ -r "${2:-}" ] || die "new: cannot read ${2:-}" 2
            nb=$(cat "$2"; printf x); cargs+=(--body "${nb%x}"); shift 2 ;;
          --repo|--title|--body|--label|--milestone) cargs+=("$1" "${2-}"); shift; [ "$#" -gt 0 ] && shift ;;
          *) die "new --filed: unknown argument '$1'" 2 ;;
        esac
      done
      fleet_gh_write issue create ${cargs[@]+"${cargs[@]}"}
      exit $? ;;
    esac
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
    if [ "$(repo_home "$repo")" = hub ]; then
      # The hub numbers it and holds all of it: filed through the filer (marker,
      # taxonomy), nothing to register.
      url=$(bash "$BIN/fleet-issue-file.sh" --repo "$repo" --title "$title" --body "$tbody" \
              ${label:+--label "$label"} --no-breakage); rc=$?
      [ "$rc" = 0 ] || die "new: filing in $repo failed" "$([ "$rc" = 4 ] && echo 4 || echo 1)"
      n=${url##*/}
      case "$n" in ''|*[!0-9]*) die "new: the filer returned no ticket URL ($url)" ;; esac
      printf 'hub:%s#%s\t%s\n' "$repo" "$n" "$url"
      exit 0
    fi
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

  claim)
    # GitHub has no atomic claim: the assignee IS the claim (issue #283), taken
    # when nobody else holds it. The hub's is atomic (409 + who → exit 3).
    p=$(ticket_parse "${1:-}") || exit 2
    [ "$(ticket_backend "$1")" = hub ] && { hub claim "$@"; exit $?; }
    shift; release=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --release) release=1; shift ;;
        --by) shift; [ "$#" -gt 0 ] && shift ;;   # GitHub's claimant is the gh login
        *) die "claim: unknown argument '$1'" 2 ;;
      esac
    done
    num="${p#*	}"; repo="${p%%	*}"
    if [ "$release" = 1 ]; then
      fleet_gh_write issue edit "$num" --repo "$repo" --remove-assignee @me >/dev/null || die "could not release the ticket"
      printf 'released\n'; exit 0
    fi
    me=$(gh api user -q .login 2>/dev/null) || die "claim: gh cannot say who this login is"
    holders=$(bash "$BIN/fleet-gh.sh" issue view "$num" --repo "$repo" --json assignees --max-age 0 2>/dev/null \
                | python3 -c 'import json,sys; print(",".join(a.get("login","") for a in (json.load(sys.stdin).get("assignees") or [])))' 2>/dev/null) \
      || die "claim: could not read the ticket"
    case ",$holders," in
      ",,"|*",$me,"*) ;;
      *) printf 'fleet-ticket: claimed by %s\n' "$holders" >&2; exit 3 ;;
    esac
    case ",$holders," in *",$me,"*) ;; *)
      fleet_gh_write issue edit "$num" --repo "$repo" --add-assignee @me >/dev/null || die "could not claim the ticket" ;;
    esac
    printf 'claimed\t%s\n' "$me" ;;

  label)
    op="${1:-}"; tid="${2:-}"
    case "$op" in add|rm) ;; *) die "label: say add|rm <id> <label>…" 2 ;; esac
    p=$(ticket_parse "$tid") || exit 2
    [ "$#" -ge 3 ] || die "label: name a label" 2
    [ "$(ticket_backend "$tid")" = hub ] && { hub label "$@"; exit $?; }
    shift 2
    ls=$(IFS=,; printf '%s' "$*")
    if [ "$op" = add ]; then fl=--add-label; else fl=--remove-label; fi
    fleet_gh_write issue edit "${p#*	}" --repo "${p%%	*}" "$fl" "$ls" >/dev/null || die "could not change the labels"
    gh issue view "${p#*	}" --repo "${p%%	*}" --json labels -q '[.labels[].name] | join(",")' ;;

  priority)
    tid="${1:-}"; want="${2:-}"
    p=$(ticket_parse "$tid") || exit 2
    case "$want" in p0|p1|p2|p3|none) ;; *) die "priority: say p0|p1|p2|p3|none" 2 ;; esac
    [ "$(ticket_backend "$tid")" = hub ] && { hub priority "$tid" "$want"; exit $?; }
    cur=$(gh issue view "${p#*	}" --repo "${p%%	*}" --json labels -q '.labels[].name' 2>/dev/null | grep '^priority:' | paste -sd, -) || cur=''
    pargs=()
    [ -n "$cur" ] && pargs+=(--remove-label "$cur")
    [ "$want" != none ] && pargs+=(--add-label "priority:$want")
    if [ "${#pargs[@]}" -gt 0 ]; then
      fleet_gh_write issue edit "${p#*	}" --repo "${p%%	*}" ${pargs[@]+"${pargs[@]}"} >/dev/null || die "could not set the priority"
    fi
    printf '%s\n' "$want" ;;

  link)
    # GitHub's sub-issues API keys off the child's numeric DATABASE id, not its
    # number (the filer's --parent, issue #335).
    pid="${1:-}"; cid="${2:-}"; rm_=0
    [ "${3:-}" = --remove ] && rm_=1
    pp=$(ticket_parse "$pid") || exit 2
    cp=$(ticket_parse "$cid") || exit 2
    [ "$(ticket_backend "$pid")" = hub ] && { hub link "$@"; exit $?; }
    [ "$(ticket_backend "$cid")" = gh ] || die "link: a GitHub ticket's children are GitHub tickets" 2
    cr="${cp%%	*}"
    child_id=$(gh api "repos/${cr%%/*}/${cr#*/}/issues/${cp#*	}" -q '.id' 2>/dev/null)
    [ -n "$child_id" ] || die "link: could not read $cid"
    pr="${pp%%	*}"
    if [ "$rm_" = 1 ]; then
      fleet_gh_write api --method DELETE "repos/${pr%%/*}/${pr#*/}/issues/${pp#*	}/sub_issue" -F sub_issue_id="$child_id" >/dev/null 2>&1 \
        || die "could not take $cid off $pid"
      printf 'unlinked\n'
    else
      fleet_gh_write api --method POST "repos/${pr%%/*}/${pr#*/}/issues/${pp#*	}/sub_issues" -F sub_issue_id="$child_id" >/dev/null 2>&1 \
        || die "could not hang $cid on $pid"
      printf 'linked\n'
    fi ;;

  milestone)
    # A GitHub milestone, created when missing (the filer's default milestone,
    # issue #433). A hub repo has none: exit 1, nothing said.
    r=$(fleet_norm_repo "${1:-}"); ms="${2:-}"
    [ -n "$r" ] && [ -n "$ms" ] || die "milestone: say <owner/name> <title>" 2
    [ "$(repo_home "$r")" = hub ] && exit 1
    if fleet_gh_write api --method POST "repos/${r%%/*}/${r#*/}/milestones" \
          -f title="$ms" -f state=open >/dev/null 2>&1; then
      printf '%s\n' "$ms"                          # freshly created
    elif gh api "repos/${r%%/*}/${r#*/}/milestones" --paginate -q '.[].title' 2>/dev/null \
          | grep -Fxq -- "$ms"; then
      printf '%s\n' "$ms"                          # already existed (create 422'd)
    else
      exit 1
    fi ;;

  find)
    r=$(fleet_norm_repo "$(opt_repo "$@")")
    [ -n "$r" ] || die "find: --repo is required" 2
    [ "$(repo_home "$r")" = hub ] && { hub find "$@"; exit $?; }
    mk=''
    while [ "$#" -gt 0 ]; do
      case "$1" in --marker) mk="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;; *) shift ;; esac
    done
    [ -n "$mk" ] || die "find: --marker is required" 2
    rows=$(gh api "repos/${r%%/*}/${r#*/}/issues?state=open&per_page=100&sort=created&direction=desc" \
             --jq '.[] | select(.pull_request == null) | "\(.number)\t\(.body // "" | gsub("[\r\n]"; " "))"' 2>/dev/null) || exit 1
    n=$(printf '%s\n' "$rows" | grep -F -- "$mk" | head -1 | cut -f1)
    case "$n" in ''|*[!0-9]*) exit 1 ;; esac
    printf 'gh:%s#%s\thttps://github.com/%s/issues/%s\n' "$r" "$n" "$r" "$n" ;;

  -h|--help|help) usage ;;
  *) die "unknown verb '$verb' — read|comment|edit|state|children|parent|list|evidence|new|claim|label|priority|link|id|home|url|parse" 2 ;;
esac
