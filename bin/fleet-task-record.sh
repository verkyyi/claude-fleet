#!/bin/bash
# fleet-task-record.sh — the hub's task record, from a machine (issue #3330, EPIC #3178 ⑦).
#
# ⌘P writes a person's task as a hub record T<n> before it places the session
# (issue #3325). This is the same record from the fleet's own coordinators, with
# this login's NODE token (POST/GET <hub>/v1/node/tasks — read per call, never in
# the environment, never on an argv):
#
#   fleet-task-record.sh new --title T --token K [--via V] [--repo o/n]
#                     [--issue o/n#N] [--key K] [--worker-id W] [--state S]
#                     → `T<n>` on stdout. The same token twice is the same record.
#   fleet-task-record.sh get T<n>          → the record + its session's live word (JSON)
#   fleet-task-record.sh children T<n>     → accepted parent generation + children
#   fleet-task-record.sh report T<n>       ← fenced report JSON on stdin
#   fleet-task-record.sh mutate T<n>       ← fenced lifecycle command JSON on stdin
#   fleet-task-record.sh set T<n> [--asked TEXT] [--parked TEXT] [--clear asked|parked]
#                     [--issue o/n#N] [--pr o/n#N] [--key K] [--worker-id W]
#                     [--state S] [--note TEXT]
#   fleet-task-record.sh settle --repo o/n [--apply]
#                     → end this owner's legacy records of a repo whose issue is
#                       closed and whose worker holds nothing (no lease, no open
#                       local start, not in inventory) — issue #4867. Dry unless
#                       --apply; the hub's JSON (settled · kept by reason · items)
#                       on stdout. A node never writes `closed` through `set`.
#                       Waits at least 90 s (the hub asks GitHub for up to 60 s,
#                       issue #4881), FLEET_HUB_TIMEOUT when that is longer.
#   fleet-task-record.sh attach T<n> [<window>]
#                     → the record names the window's session (its key + worker_id)
#   fleet-task-record.sh dispatch --title T [--body-file F|-] [--repo o/n]
#                     [--spawn] [--reap P] [--agent A] [--draft] [--pr-note TEXT]
#                     → the `task` tool: the record FIRST (`T<n>` on
#                       stdout), then — a repo named, i.e. a development task —
#                       + --spawn: its session in a worktree of that repo, bound
#                       to the record alone (no issue: dash-raw-session.sh --repo
#                       --task, reaped `merged` = the record closed — issue
#                       #4897); no repo + --spawn: a no-repo session given the
#                       words, stamped @task. Still filed as an issue
#                       (fleet-issue-file.sh --task T<n>, the URL after the T):
#                       --draft, FLEET_TASK_ISSUE=1, and no hub (no T line —
#                       a no-repo one is refused there, exit 3).
#   fleet-task-record.sh epic-member <epic> <owner/name> <N> [<title>]
#                     → an EPIC member's read-only record (`T<n>` on stdout): its
#                       issue on it, `via` EPIC #<epic>, one per member (the token is
#                       the member); its live window is stamped @task and attached.
#                       /fleet-epic-run runs it after each spawn, beside the floor.
#   fleet-task-record.sh of [<window>]     → the window's @task (T<n>), rc 1 when none
#   fleet-task-record.sh find-issue o/n#N  → … the live window's @task working that issue
#
# Who calls it: the `task` tool (a record first, an issue only for
# a development task — fleet-issue-file.sh --task), the spawners (`--task`
# attaches the new window), a session's ask / park (a question or a park on the
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
  [ -z "${FLEET_TASK_RECOVERY_URL:-}" ] || [ "$url" = "$FLEET_TASK_RECOVERY_URL" ] || die 1 "task authority changed; reconciliation required"
  # signed once this login has a key (issue #3710), else the token
  resp=$(printf 'header = "Authorization: %s"\n' "$(fleet_node_auth "$m" "$url$p" "$tok")" | \
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
  title='' bodyf='' repo='' spawn=0 reap='' agent='' as_agent='' draft='' pr_note=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="${2:-}"; shift ;;
      --body-file) bodyf="${2:-}"; shift ;;
      --repo) repo="${2:-}"; shift ;;
      --spawn) spawn=1 ;;
      --reap) reap="${2:-}"; shift ;;
      --agent)
        [ -z "$agent" ] || [ "$agent" = "${2:-}" ] || die 2 "contradictory --agent values"
        case "${2:-}" in claude|codex) agent=$2 ;; *) die 2 "--agent must be claude or codex; use --as for an agent definition" ;; esac
        shift ;;
      --as) as_agent="${2:-}"; shift ;;
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
  # One token per (caller, words): a session asking twice is one record.
  okey=$(fleet_origin_key 2>/dev/null) || okey=''
  tok="orch:${okey:-hub}:$(printf '%s\n%s' "$title" "$body" | shasum 2>/dev/null | cut -c1-16)"
  # A development task's session starts as the worker template, as
  # dash-issue-session.sh gives an issue worker (#3122): the shipped fleet-worker
  # when this login has it, else a plain session (issue #4897).
  if [ -n "$repo" ] && [ -z "$as_agent" ] && [ -z "$draft" ] && [ "$spawn" = 1 ] && [ "${FLEET_TASK_ISSUE:-0}" != 1 ] \
     && python3 "$BIN/fleet-agent-def.py" launch fleet-worker --dir "${FLEET_MAIN:-$PWD}" \
          --for "${agent:-${FLEET_AGENT:-claude}}" >/dev/null 2>&1; then
    as_agent=fleet-worker
  fi
  # Resolve the definition's provider before acceptance, independently of its
  # tools/body. Explicit --agent wins. Every retry retains the full input.
  template=''
  if [ -n "$as_agent" ]; then
    as_for=claude; [ "${agent:-${FLEET_AGENT:-claude}}" = codex ] && as_for=codex   # #4726
    kv=$(python3 "$BIN/fleet-agent-def.py" launch "$as_agent" --dir "${FLEET_MAIN:-$PWD}" --for "$as_for") || exit 2
    template=$(printf '%s\n' "$kv" | awk -F'\t' '$1 == "agent" {print $2; exit}')
  fi
  dispatch=$(python3 "$BIN/fleet_dispatch.py" ${agent:+--agent "$agent"} --template "$template" --default "${FLEET_AGENT:-}" --request-id "$tok") || exit 2
  t=''
  if applicable; then
    parent_wid=''; parent_task=''
    task_win=$(fleet_pane_fmt '#{window_id}')
    if [ -n "$task_win" ]; then
      task_sess=$(fleet_current_session)
      parent_wid=$(fleet_worker_id "$task_sess" "$task_win")
      parent_task=$(fleet_pane_fmt '#{@task}')
    fi
    payload=$(python3 - "$dispatch" "$title" "$body" "$repo" "$reap" "$as_agent" "" "$draft" "$pr_note" "$parent_wid" "$parent_task" <<'JSON'
import json,sys
d,title,body,repo,reap,template,rule,draft,note,parent_session,parent_task=sys.argv[1:]
d=json.loads(d)
repo=repo.lower()
print(json.dumps(dict(authority_version=1, token=d["request_id"], title=title, via="编排", repo=repo,
    requested_agent=d["requested_agent"], resolved_agent=d["resolved_agent"], parent_session=parent_session, parent_task=parent_task,
    request_payload=dict(dispatch=d,title=title,body=body,repo=repo,reap=reap,template=template,rule=rule,draft=draft,pr_note=note))))
JSON
    ) || exit 2
    accepted=$(call POST /v1/node/tasks "$payload") || exit 1
    t=$(printf '%s' "$accepted" | field id)
    is_tref "$t" || die 1 "the hub's answer names no accepted record"
    dispatch=$(python3 - "$dispatch" "$accepted" <<'JSON'
import json,sys
d,t=map(json.loads,sys.argv[1:])
if t.get("authority_version") != 1 or t.get("requested_agent") != d["requested_agent"] or t.get("resolved_agent") != d["resolved_agent"]:
    sys.exit("hub did not accept the requested provider contract")
d.update(task=t["id"],generation=t["generation"],attempt_id=t["attempt_id"])
print(json.dumps(d,separators=(",", ":")))
JSON
    ) || exit 1
    printf '%s\n' "$t"
  elif [ -z "$repo" ]; then
    die 3 "no hub here: a task with no repo has nowhere to be recorded — file an issue instead (file_issue)"
  fi
  export FLEET_DISPATCH="$dispatch"
  # A development task the hub accepted is the record alone (issue #4897, EPIC
  # #4895 批 0): no GitHub issue — the session opens in its own worktree of the
  # repo, bound to T<n> (dash-raw-session.sh --repo --task stamps @task_flow), reads
  # the record, opens its PR, merges it on a green gate and closes the record with
  # its report; it is reaped once the record is closed (`merged`). Not --spawn: the
  # record waits (await T<n> names it). Kept on the issue road for one batch: a
  # draft-only task (its mark lives in an issue body, #3715), no hub (no T), and
  # FLEET_TASK_ISSUE=1 — the old road, deleted in 批 1.
  if [ -n "$repo" ] && [ -n "$t" ] && [ -z "$draft" ] && [ "${FLEET_TASK_ISSUE:-0}" != 1 ]; then
    [ "$spawn" = 1 ] || exit 0
    pf=$(mktemp "${TMPDIR:-/tmp}/fleet-task-prompt.XXXXXX") || die 1 "no temp file"
    if [ -n "$body" ]; then printf '%s\n\n%s\n' "$title" "$body" > "$pf"; else printf '%s\n' "$title" > "$pf"; fi
    exec bash "$BIN/dash-raw-session.sh" --repo "$repo" --task "$t" --name "$title" --reap "${reap:-merged}" \
      ${as_agent:+--as "$as_agent"} ${agent:+--agent "$agent"} "--prompt-file=$pf"
  fi
  if [ -n "$repo" ]; then   # a development task: its issue, hung on the record
    sp=''; [ "$spawn" = 1 ] && sp=--spawn
    exec bash "$BIN/fleet-issue-file.sh" --title "$title" ${body:+--body "$body"} --repo "$repo" \
      ${t:+--task "$t"} ${sp:+"$sp"} ${draft:+"$draft"} ${pr_note:+--pr-note "$pr_note"}
  fi
  [ "$spawn" = 1 ] || exit 0
  pf=$(mktemp "${TMPDIR:-/tmp}/fleet-task-prompt.XXXXXX") || die 1 "no temp file"
  printf '%s\n' "${body:-$title}" > "$pf"
  exec bash "$BIN/dash-raw-session.sh" --no-repo --task "$t" --name "$title" ${reap:+--reap "$reap"} \
    ${as_agent:+--as "$as_agent"} ${agent:+--agent "$agent"} "--prompt-file=$pf"
fi

applicable || exit 3

if [ "$cmd" = authority ]; then
  pair=$(fleet_node_pair) || exit 3
  printf '%s\n' "${pair%%	*}"
  exit 0
fi
# The original HTTP adapter remains the only credential reader. Recovery stores
# receipts in control/state.sqlite3 and calls this raw road, never a second API.
case "$cmd" in
  get|report|mutate|stopped)
    if [ "${FLEET_TASK_RECOVERY_RAW:-0}" != 1 ]; then
      is_tref "${1:-}" || usage
      exec python3 "$BIN/fleet_task_recovery.py" "$cmd" "$1"
    fi ;;
esac

case "$cmd" in
  children)
    is_tref "${1:-}" || usage
    call GET "/v1/node/tasks/$1/children"
    exit $? ;;
  report)
    is_tref "${1:-}" || usage
    report=$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))') || exit 2
    call POST "/v1/node/tasks/$1/reports" "$report"
    exit $? ;;
  mutate)
    is_tref "${1:-}" || usage
    mutation=$(python3 -c 'import json,sys; print(json.dumps({"authority_version":1,"mutation":json.load(sys.stdin)}))') || exit 2
    call POST "/v1/node/tasks/$1" "$mutation"
    exit $? ;;
  new)
    title='' token='' via='' repo='' issue='' key='' wid='' state=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --title) title="${2:-}"; shift ;;
        --token) token="${2:-}"; shift ;;
        --via) via="${2:-}"; shift ;;
        --repo) repo="${2:-}"; shift ;;
        --issue) issue="${2:-}"; shift ;;
        --key) key="${2:-}"; shift ;;
        --worker-id) wid="${2:-}"; shift ;;
        --state) state="${2:-}"; shift ;;
        *) usage ;;
      esac
      shift
    done
    [ -n "$title" ] && [ -n "$token" ] || usage
    out=$(call POST /v1/node/tasks "$(json token="$token" title="$title" via="$via" repo="$repo" \
            issue="$issue" key="$key" worker_id="$wid" state="$state")") || exit 1
    t=$(printf '%s' "$out" | field id)
    is_tref "$t" || die 1 "the hub's answer names no record"
    printf '%s\n' "$t" ;;
  get)
    is_tref "${1:-}" || usage
    call GET "/v1/node/tasks/$1" || exit 1 ;;
  settle)
    repo='' apply=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="${2:-}"; shift ;;
        --apply) apply=true ;;
        *) usage ;;
      esac
      shift
    done
    case "$repo" in */*) ;; *) usage ;; esac
    # the hub reads GitHub for each issue within a 60 s budget (issue #4881)
    to=${FLEET_HUB_TIMEOUT:-10}
    case "$to" in ''|*[!0-9]*) to=90 ;; esac
    [ "$to" -ge 90 ] || to=90
    FLEET_HUB_TIMEOUT=$to call POST /v1/node/tasks/settle "$(python3 -c 'import json,sys; print(json.dumps({"repo":sys.argv[1],"apply":sys.argv[2]=="true"}))' "$repo" "$apply")" || exit 1 ;;
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
