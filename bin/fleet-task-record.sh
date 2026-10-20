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
#                     → the task's code on stdout's FIRST line (its ID's written
#                       code: K5F9 — a hub with `task_ids`, EPIC T644 C1), then
#                       `T<n>` (the old number, a read-only alias — compat-1v:
#                       下一批删); an older hub answers `T<n>` alone. The same
#                       token twice is the same record.
#   fleet-task-record.sh get <code|ID|T<n>> → the record + its session's live word
#                       (JSON); a code naming several tasks exits 1 — the hub's
#                       409 body (its candidates) on stdout, never a pick
#   fleet-task-record.sh children T<n>     → the record's children
#   fleet-task-record.sh mutate T<n>       ← a cancel of a record no window ever
#                       opened (fleet_task_control.py cancel, EPIC T497 C13), JSON on stdin
#   fleet-task-record.sh set T<n> [--asked TEXT] [--parked TEXT] [--clear asked|parked]
#                     [--issue o/n#N] [--pr o/n#N] [--key K] [--worker-id W]
#                     [--state S] [--note TEXT]
#   fleet-task-record.sh settle --repo o/n|--no-repo [--apply] [--drained]
#                     → end this owner's legacy records of a repo whose issue is
#                       closed and whose worker holds nothing (no lease, no open
#                       local start, not in inventory) — issue #4867. Dry unless
#                       --apply; the hub's JSON (settled · kept by reason · items)
#                       on stdout. A node never writes `closed` through `set`.
#                       --drained (the authority cutover, T479): the worker half
#                       alone — gone ⇒ closed even with its issue still open
#                       (GitHub not asked, the issue untouched); live ⇒ kept.
#                       --no-repo (issue #4963): this owner's records that name
#                       no repo (an EPIC driver's), the same two halves.
#                       Waits at least 90 s (the hub asks GitHub for up to 60 s,
#                       issue #4881), FLEET_HUB_TIMEOUT when that is longer.
#   fleet-task-record.sh reconcile [--before T<n>] [--apply] | --undo
#                     → bring this owner's records in line with what happened
#                       (EPIC T644 C6): every unfinished record whose ID already
#                       carries an ending result takes it; with --before, every
#                       unfinished record numbered below it that no live session
#                       holds is cancelled. Dry unless --apply; the hub's JSON
#                       (unfinished · ended · cancelled · kept · left · items).
#                       --undo puts every record it cancelled back.
#   fleet-task-record.sh attach T<n> [<window>]
#                     → the record names the window's session (its key + worker_id)
#   fleet-task-record.sh dispatch --title T [--body-file F|-] [--repo o/n]
#                     [--spawn] [--reap P] [--agent A] [--session S] [--origin O] [--via V] [--print]
#                     → the `task` tool: the record FIRST (`T<n>` on
#                       stdout), then — a repo named, i.e. a development task —
#                       + --spawn: its session in a worktree of that repo, bound
#                       to the record alone (no issue: dash-raw-session.sh --repo
#                       --task, reaped `merged` = the record closed — issue
#                       #4897); no repo + --spawn: a no-repo session given the
#                       words, stamped @task. No hub: exit 3, nothing made — the
#                       record is the only ticket (issue #4898). --session /
#                       --origin / --print go to dash-raw-session.sh (the fleet
#                       it opens in, whose it is, its window receipt after the
#                       T<n> line) — ⌘P's ⚡ row in a 看台 (issue #4965:
#                       `--origin hub --via ⌘P`, the person's own task — no
#                       parent session on the record).
#   fleet-task-record.sh of [<window>]     → the window's @task (T<n>), rc 1 when none
#   fleet-task-record.sh find-issue o/n#N  → … the live window's @task working that issue
#
# Who calls it: the `task` tool (the record is the ticket), the spawners (`--task`
# attaches the new window), a session's ask / park (a question or a park on the
# record: a session with no issue writes them ONLY here, one with an issue mirrors
# them), an EPIC driver (its parent task and the members it dispatches as child
# tasks — issue #4957), and fleet-await.sh (`T<n>` → the record's session).
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
# is_task_ref → a task's code (K5, #k5f9: a letter, then Crockford base32), its
# full ID (a lowercase UUID) or T<n> — what the hub's one resolver reads (EPIC
# T644 C1, store.ResolveFleetTask).
is_task_ref() {
  is_tref "${1:-}" && return 0
  printf '%s' "${1:-}" | grep -Eq '^#?[A-Za-z][0-9A-Za-z]{1,25}$|^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

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
  local m="$1" p="$2" body="${3:-}" pair url tok resp rc code why
  pair=$(fleet_node_pair) || die 3 "no node token here"
  url=${pair%%	*}; tok=${pair#*	}
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
    *) # The ID switch (EPIC T497 C6): the hub reads sessions by ID — the caller
       # takes the ID road, and this node writes the hub's word down.
       case "$resp" in *'"code":"ID_SWITCH"'*)
         printf 'on %s\n' "$(date +%s)" > "$FLEET_CONF_DIR/ids/.switch" 2>/dev/null || :
         printf 'fleet-task-record: ID_SWITCH — the hub reads sessions by ID now (HTTP %s)\n' "$code" >&2; return 1 ;;
       esac
       # The hub's own words ride along (EPIC T497 C16): a bare code hid a fence.
       why=$(printf '%s\n' "$resp" | sed '$d' | python3 -c 'import json,sys
try: print(" ".join(str(json.load(sys.stdin).get("error","")).split())[:300])
except Exception: pass' 2>/dev/null)
       printf 'fleet-task-record: the hub refused (HTTP %s)%s\n' "$code" "${why:+: $why}" >&2; return 1 ;;
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
  title='' bodyf='' repo='' spawn=0 reap='' agent='' as_agent='' tsess='' pwin='' origin='' via=编排
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
      --session) tsess="${2:-}"; shift ;;
      --origin) origin="${2:-}"; shift ;;
      --via) via="${2:-编排}"; shift ;;
      --print) pwin=--print ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$title" ] || usage
  applicable || die 3 "no hub here: a task has nowhere to be recorded (issue #4898)"
  body=''
  if [ "$bodyf" = - ]; then body=$(cat); elif [ -n "$bodyf" ]; then body=$(cat "$bodyf") || die 2 "cannot read $bodyf"; fi
  # One token per (caller, words): a session asking twice is one record.
  okey=$(fleet_origin_key 2>/dev/null) || okey=''
  tok="orch:${okey:-hub}:$(printf '%s\n%s' "$title" "$body" | shasum 2>/dev/null | cut -c1-16)"
  # A development task's session starts as the worker template, as
  # dash-issue-session.sh gives an issue worker (#3122): the shipped fleet-worker
  # when this login has it, else a plain session (issue #4897).
  if [ -n "$repo" ] && [ -z "$as_agent" ] && [ "$spawn" = 1 ] \
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
  {
    parent_wid=''; parent_task=''
    task_win=$(fleet_pane_fmt '#{window_id}')
    if [ -n "$task_win" ] && [ "$origin" != hub ]; then
      task_sess=$(fleet_current_session)
      parent_wid=$(fleet_worker_id "$task_sess" "$task_win")
      parent_task=$(fleet_pane_fmt '#{@task}')
    fi
    payload=$(python3 - "$dispatch" "$title" "$body" "$repo" "$reap" "$as_agent" "" "" "" "$parent_wid" "$parent_task" "$via" <<'JSON'
import json,sys
d,title,body,repo,reap,template,rule,draft,note,parent_session,parent_task,via=sys.argv[1:]
d=json.loads(d)
repo=repo.lower()
print(json.dumps(dict(authority_version=1, token=d["request_id"], title=title, via=via, repo=repo,
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
  }
  export FLEET_DISPATCH="$dispatch"
  # A development task the hub accepted is the record alone (issue #4897, EPIC
  # #4895 批 0): no GitHub issue — the session opens in its own worktree of the
  # repo, bound to T<n> (dash-raw-session.sh --repo --task stamps @task_flow), reads
  # the record, opens its PR, merges it on a green gate and closes the record with
  # its report; it is reaped once the record is closed (`merged`). Not --spawn: the
  # record waits (await T<n> names it).
  if [ -n "$repo" ]; then
    [ "$spawn" = 1 ] || exit 0
    pf=$(mktemp "${TMPDIR:-/tmp}/fleet-task-prompt.XXXXXX") || die 1 "no temp file"
    if [ -n "$body" ]; then printf '%s\n\n%s\n' "$title" "$body" > "$pf"; else printf '%s\n' "$title" > "$pf"; fi
    exec bash "$BIN/dash-raw-session.sh" --repo "$repo" --task "$t" --name "$title" --reap "${reap:-merged}" \
      ${as_agent:+--as "$as_agent"} ${agent:+--agent "$agent"} ${origin:+--origin "$origin"} $pwin "--prompt-file=$pf" ${tsess:+"$tsess"}
  fi
  [ "$spawn" = 1 ] || exit 0
  pf=$(mktemp "${TMPDIR:-/tmp}/fleet-task-prompt.XXXXXX") || die 1 "no temp file"
  printf '%s\n' "${body:-$title}" > "$pf"
  exec bash "$BIN/dash-raw-session.sh" --no-repo --task "$t" --name "$title" ${reap:+--reap "$reap"} \
    ${as_agent:+--as "$as_agent"} ${agent:+--agent "$agent"} ${origin:+--origin "$origin"} $pwin "--prompt-file=$pf" ${tsess:+"$tsess"}
fi

applicable || exit 3

if [ "$cmd" = authority ]; then
  pair=$(fleet_node_pair) || exit 3
  printf '%s\n' "${pair%%	*}"
  exit 0
fi
case "$cmd" in
  children)
    is_tref "${1:-}" || usage
    call GET "/v1/node/tasks/$1/children"
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
    short=$(printf '%s' "$out" | field short)
    [ -n "$short" ] && printf '%s\n' "$short"
    printf '%s\n' "$t" ;;
  get)
    is_task_ref "${1:-}" || usage
    call GET "/v1/node/tasks/${1#\#}" || exit 1 ;;
  settle)
    repo='' apply=false drained=false norepo=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="${2:-}"; shift ;;
        --no-repo) norepo=true ;;
        --apply) apply=true ;;
        --drained) drained=true ;;
        *) usage ;;
      esac
      shift
    done
    case "$norepo:$repo" in false:*/*|true:) ;; *) usage ;; esac
    # the hub reads GitHub for each issue within a 60 s budget (issue #4881)
    to=${FLEET_HUB_TIMEOUT:-10}
    case "$to" in ''|*[!0-9]*) to=90 ;; esac
    [ "$to" -ge 90 ] || to=90
    FLEET_HUB_TIMEOUT=$to call POST /v1/node/tasks/settle "$(python3 -c 'import json,sys; d={"repo":sys.argv[1],"apply":sys.argv[2]=="true"}; d.update({"drained":True} if sys.argv[3]=="true" else {}); d.update({"no_repo":True} if sys.argv[4]=="true" else {}); print(json.dumps(d))' "$repo" "$apply" "$drained" "$norepo")" || exit 1 ;;
  reconcile)
    apply=false before='' undo=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --before) before="${2:-}"; is_tref "$before" || usage; shift ;;
        --apply) apply=true ;;
        --undo) undo=true ;;
        *) usage ;;
      esac
      shift
    done
    call POST /v1/node/tasks/reconcile "$(python3 -c 'import json,sys; d={"apply":sys.argv[1]=="true"}; d.update({"before":sys.argv[2]} if sys.argv[2] else {}); d.update({"undo":True} if sys.argv[3]=="true" else {}); print(json.dumps(d))' "$apply" "$before" "$undo")" || exit 1 ;;
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
