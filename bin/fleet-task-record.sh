#!/bin/bash
# fleet-task-record.sh — the hub's task record, from a machine (issue #3330, EPIC #3178 ⑦).
#
# ⌘P writes a person's task as a hub record T<n> before it places the session
# (issue #3325). This is the same record from the fleet's own coordinators, with
# this login's NODE token (POST/GET <hub>/v1/node/tasks — read per call, never in
# the environment, never on an argv):
#
#   fleet-task-record.sh new --title T --token K [--via V] [--repo o/n] [--rule N]
#                     [--issue o/n#N] [--key K] [--worker-id W] [--state S]
#                     → `T<n>` on stdout. The same token twice is the same record.
#   fleet-task-record.sh get T<n>          → the record + its session's live word (JSON)
#   fleet-task-record.sh set T<n> [--asked TEXT] [--parked TEXT] [--clear asked|parked]
#                     [--issue o/n#N] [--pr o/n#N] [--key K] [--worker-id W]
#                     [--state S] [--note TEXT]
#   fleet-task-record.sh attach T<n> [<window>]
#                     → the record names the window's session (its key + worker_id)
#   fleet-task-record.sh dispatch --title T [--body-file F|-] [--repo o/n] [--rule N]
#                     [--spawn] [--reap P] [--agent A] [--draft] [--pr-note TEXT]
#                     → the orchestrator's `task` tool: the record FIRST (`T<n>` on
#                       stdout), then — a repo named, i.e. a development task —
#                       fleet-issue-file.sh --task T<n> (+ --spawn: its worker,
#                       stamped @task; the URL on stdout after the T); no repo +
#                       --spawn: a no-repo session given the words, stamped @task.
#                       No hub: a repo task is filed exactly as before (no T line),
#                       a no-repo one is refused (exit 3: file an issue instead).
#   fleet-task-record.sh epic-member <epic> <owner/name> <N> [<title>]
#                     → an EPIC member's read-only record (`T<n>` on stdout): its
#                       issue on it, `via` EPIC #<epic>, one per member (the token is
#                       the member); its live window is stamped @task and attached.
#                       /fleet-epic-run runs it after each spawn, beside the floor.
#   fleet-task-record.sh of [<window>]     → the window's @task (T<n>), rc 1 when none
#   fleet-task-record.sh find-issue o/n#N  → … the live window's @task working that issue
#
# Who calls it: the orchestrator's `task` tool (a record first, an issue only for
# a development task — fleet-issue-file.sh --task), the spawners (`--task`
# attaches the new window), the steward's ask / park (a question or a park on the
# record: a session with no issue writes them ONLY here, one with an issue mirrors
# them), an EPIC driver (each member's read-only record, fleet-epic-floor.sh), and
# fleet-await.sh (`T<n>` → the record's session).
#
# Exit: 0 done · 1 the hub refused or did not answer (stderr says which) · 2 usage
# · 3 not applicable — no hub here (CCQUOTA_FLEET off for this fleet, or no node
# token): nothing is sent, nothing printed, so every caller stays byte for byte
# what it was without a hub.
# Seams: FLEET_HUB_CURL (default curl), FLEET_HUB_TIMEOUT (default 10 s).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-task-record: %s\n' "$2" >&2; exit "$1"; }
usage() { die 2 "usage: fleet-task-record.sh new|get|set|attach|of|find-issue … (see the header)"; }

TREF_RE='^T[1-9][0-9]{0,9}$'
is_tref() { printf '%s' "${1:-}" | grep -Eq "$TREF_RE"; }

# applicable → rc 0 when this caller has a hub to write to: the calling fleet
# (when there is one) has the hub on, and a node token is here.
applicable() {
  local sess
  sess=$(fleet_current_session 2>/dev/null) || sess=''
  if [ -n "$sess" ]; then fleet_hub_on "$sess" || return 1; fi
  fleet_node_pair >/dev/null 2>&1
}

# call METHOD PATH [JSON] → the answer's body on stdout; rc 0 on HTTP 200.
call() {
  local m="$1" p="$2" body="${3:-}" pair url tok resp rc code
  pair=$(fleet_node_pair) || die 3 "no node token here"
  url=${pair%%	*}; tok=${pair#*	}
  resp=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" | \
    "${FLEET_HUB_CURL:-curl}" -sS --max-time "${FLEET_HUB_TIMEOUT:-10}" -K - -o - -w '\n%{http_code}' \
      -X "$m" -H 'Content-Type: application/json' ${body:+--data-binary "$body"} "$url$p" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ -n "$resp" ] || { printf 'fleet-task-record: hub unreachable (curl exit %s)\n' "$rc" >&2; return 1; }
  code=$(printf '%s\n' "$resp" | tail -n 1)
  printf '%s\n' "$resp" | sed '$d'
  case "$code" in
    200) return 0 ;;
    404|405) printf 'fleet-task-record: the hub said %s (%s)\n' "$code" "$p" >&2; return 1 ;;
    *) printf 'fleet-task-record: the hub refused (HTTP %s)\n' "$code" >&2; return 1 ;;
  esac
}

# json k=v … → one JSON object (k[]=v appends to a list); empty values dropped.
json() {
  python3 - "$@" <<'PY'
import json, sys
out = {}
for a in sys.argv[1:]:
    k, _, v = a.partition('=')
    if k.endswith('[]'):
        out.setdefault(k[:-2], []).append(v)
    elif v != '':
        out[k] = v
print(json.dumps(out, ensure_ascii=False))
PY
}

field() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d=(d or {}).get(k) if isinstance(d, dict) else None
print(d if d is not None else "")' "$1" 2>/dev/null; }

# win_of [<window>] → the window to read (the caller's own pane when none).
win_of() {
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  fleet_pane_fmt '#{window_id}'
}

cmd="${1:-}"; shift || true
case "$cmd" in
  of)
    w=$(win_of "${1:-}") || exit 1
    t=$(tmux display-message -p -t "$w" '#{@task}' 2>/dev/null) || exit 1
    is_tref "$t" || exit 1
    printf '%s\n' "$t"; exit 0 ;;
  find-issue)
    ref="${1:-}"
    case "$ref" in */*'#'[1-9]*) ;; *) usage ;; esac
    repo=${ref%#*}; num=${ref##*#}
    while IFS=$'\t' read -r wid iss wrepo t; do
      [ "$iss" = "$num" ] && is_tref "$t" || continue
      [ -z "$wrepo" ] || [ "$(printf '%s' "$wrepo" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$repo" | tr 'A-Z' 'a-z')" ] || continue
      printf '%s\n' "$t"; exit 0
    done <<EOF
$(fleet_lw '#{window_id}	#{@issue}	#{@repo}	#{@task}' 2>/dev/null)
EOF
    exit 1 ;;
esac

if [ "$cmd" = dispatch ]; then
  title='' bodyf='' repo='' rule='' spawn=0 reap='' agent='' draft='' pr_note=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="${2:-}"; shift ;;
      --body-file) bodyf="${2:-}"; shift ;;
      --repo) repo="${2:-}"; shift ;;
      --rule) rule="${2:-}"; shift ;;
      --spawn) spawn=1 ;;
      --reap) reap="${2:-}"; shift ;;
      --agent) agent="${2:-}"; shift ;;
      --draft) draft=--draft ;;   # issue #3715: a draft-only development task
      --pr-note) pr_note="${2:-}"; draft=--draft; shift ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$title" ] || usage
  [ -z "$draft" ] || [ -n "$repo" ] || die 2 "--draft needs --repo: a draft PR lives in a repo"
  body=''
  if [ "$bodyf" = - ]; then body=$(cat); elif [ -n "$bodyf" ]; then body=$(cat "$bodyf") || die 2 "cannot read $bodyf"; fi
  # One token per (caller, words): the orchestrator asking twice is one record.
  okey=$(fleet_origin_key 2>/dev/null) || okey=''
  tok="orch:${okey:-hub}:$(printf '%s\n%s' "$title" "$body" | shasum 2>/dev/null | cut -c1-16)"
  t=''
  if applicable; then
    t=$(bash "$0" new --title "$title" --token "$tok" --via 编排 ${repo:+--repo "$repo"} ${rule:+--rule "$rule"}) || exit $?
    printf '%s\n' "$t"
  elif [ -z "$repo" ]; then
    die 3 "no hub here: a task with no repo has nowhere to be recorded — file an issue instead (file_issue)"
  fi
  if [ -n "$repo" ]; then   # a development task: its issue, hung on the record
    sp=''; [ "$spawn" = 1 ] && sp=--spawn
    exec bash "$BIN/fleet-issue-file.sh" --title "$title" ${body:+--body "$body"} --repo "$repo" \
      ${rule:+--rule "$rule"} ${t:+--task "$t"} ${sp:+"$sp"} ${draft:+"$draft"} ${pr_note:+--pr-note "$pr_note"}
  fi
  [ "$spawn" = 1 ] || exit 0
  pf=$(mktemp "${TMPDIR:-/tmp}/fleet-task-prompt.XXXXXX") || die 1 "no temp file"
  printf '%s\n' "${body:-$title}" > "$pf"
  exec bash "$BIN/dash-raw-session.sh" --no-repo --task "$t" --name "$title" ${reap:+--reap "$reap"} \
    ${agent:+--as "$agent"} "--prompt-file=$pf"
fi

applicable || exit 3

case "$cmd" in
  new)
    title='' token='' via='' repo='' rule='' issue='' key='' wid='' state=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --title) title="${2:-}"; shift ;;
        --token) token="${2:-}"; shift ;;
        --via) via="${2:-}"; shift ;;
        --repo) repo="${2:-}"; shift ;;
        --rule) rule="${2:-}"; shift ;;
        --issue) issue="${2:-}"; shift ;;
        --key) key="${2:-}"; shift ;;
        --worker-id) wid="${2:-}"; shift ;;
        --state) state="${2:-}"; shift ;;
        *) usage ;;
      esac
      shift
    done
    [ -n "$title" ] && [ -n "$token" ] || usage
    rmark=''
    if [ -n "$rule" ]; then
      case "$rule" in *[!0-9]*) die 2 "--rule must be a rule number (got $rule)" ;; esac
      # the issue body's marker's words: `n=N v=<table version>` (issue #2786)
      rmark=$(python3 "$BIN/fleet-role.py" rules --mark "$rule" 2>/dev/null | sed -n 's/.*<!-- fleet:rule \(n=[0-9]* v=[0-9a-f]*\) -->.*/\1/p') \
        && [ -n "$rmark" ] || die 2 "--rule $rule: no such rule in the table (fleet-role.py rules)"
    fi
    out=$(call POST /v1/node/tasks "$(json token="$token" title="$title" via="$via" repo="$repo" rule="$rmark" \
            issue="$issue" key="$key" worker_id="$wid" state="$state")") || exit 1
    t=$(printf '%s' "$out" | field id)
    is_tref "$t" || die 1 "the hub's answer names no record"
    printf '%s\n' "$t" ;;
  get)
    is_tref "${1:-}" || usage
    call GET "/v1/node/tasks/$1" || exit 1 ;;
  set)
    is_tref "${1:-}" || usage
    t="$1"; shift
    args=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --asked) args+=("asked=${2:-}"); shift ;;
        --parked) args+=("parked=${2:-}"); shift ;;
        --note) args+=("note=${2:-}"); shift ;;
        --issue) args+=("issue=${2:-}"); shift ;;
        --pr) args+=("pr=${2:-}"); shift ;;
        --key) args+=("key=${2:-}"); shift ;;
        --worker-id) args+=("worker_id=${2:-}"); shift ;;
        --state) args+=("state=${2:-}"); shift ;;
        --clear) case "${2:-}" in asked|parked|note) args+=("clear[]=$2") ;; *) usage ;; esac; shift ;;
        *) usage ;;
      esac
      shift
    done
    [ "${#args[@]}" -gt 0 ] || usage
    call POST "/v1/node/tasks/$t" "$(json ${args[@]+"${args[@]}"})" >/dev/null || exit 1 ;;
  epic-member)
    epic="${1:-}" mrepo="${2:-}" n="${3:-}" title="${4:-}"
    case "$epic$n" in ''|*[!0-9]*) usage ;; esac
    case "$mrepo" in */*) ;; *) usage ;; esac
    t=$(bash "$0" new --title "${title:-#$n}" --token "epic:$mrepo#$n" --via "EPIC #$epic" --repo "$mrepo" \
          --issue "$mrepo#$n" --state open) || exit $?
    sess=$(fleet_current_session 2>/dev/null) || sess=''
    w=''
    [ -n "$sess" ] && w=$(fleet_win_for_key "$(fleet_okey_prefix "$sess" "$mrepo")issue-$n" 2>/dev/null) || w=''
    if [ -n "$w" ]; then
      tmux set-window-option -t "$w" @task "$t" 2>/dev/null
      bash "$0" attach "$t" "$w" || :
    fi
    printf '%s\n' "$t" ;;
  attach)
    is_tref "${1:-}" || usage
    t="$1"
    sess=$(fleet_current_session 2>/dev/null) || die 1 "no fleet session here"
    w=$(win_of "${2:-}") || die 1 "no window to attach"
    k=$(fleet_window_okey "$sess" "$w")
    wid=$(fleet_worker_id "$sess" "$w" 2>/dev/null) || wid=''
    [ -n "$k" ] || [ -n "$wid" ] || die 1 "window $w has no session key"
    call POST "/v1/node/tasks/$t" "$(json key="$k" worker_id="$wid" state=open)" >/dev/null || exit 1 ;;
  *) usage ;;
esac
