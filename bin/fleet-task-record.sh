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
#                       (JSON); a code naming several tasks exits 2 — the hub's
#                       409 body (its candidates) on stdout, never a pick
#   Every <ref> below is the same three (the hub resolves it): the code is what a
#   person reads; `T<n>` is read for one more version (compat-1v: 下一批删).
#   fleet-task-record.sh resolve <ref>     → the task's code on the first line, its
#                       `T<n>` on the second (an older hub: `T<n>` alone) — the ONE
#                       local reader of a task reference (EPIC T644 C3). A code
#                       naming several tasks exits 2 with one stderr line per
#                       candidate (`K5H0 · title · state`), never a pick; none ⇒ 1.
#   fleet-task-record.sh code <ref>        → the task's written code (K5H0), off this
#                       login's book first (ids/task-codes.tsv — every answer that
#                       carries one writes it down), else the hub; rc 1 when no
#                       code is known (an older hub)
#   fleet-task-record.sh stop <T<n>>      ← {idempotency_key,evidence?} on stdin; durable Task stop
#   fleet-task-record.sh children <ref>    → the record's children
#   fleet-task-record.sh mutate <ref>      ← a cancel of a record no window ever
#                       opened (fleet_task_control.py cancel, EPIC T497 C13), JSON on stdin
#   fleet-task-record.sh set <ref> [--asked TEXT] [--parked TEXT] [--clear asked|parked]
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
#   fleet-task-record.sh attach <ref> [<window>]
#                     → the record names the window's session (its key + worker_id)
#                       set / attach print the task's code (else T<n>) on stdout
#   fleet-task-record.sh dispatch --title T [--body-file F|-] [--repo o/n]
#                     [--spawn] [--reap P] [--agent A] [--session S] [--origin O] [--via V] [--print]
#                     → the `task` tool: the record FIRST (a local text file the
#                       body names — ~/fleet-drafts/… — rides in it, T793:
#                       fleet_local_refs.py; what cannot is said on stderr) (its code, then
#                       `T<n>` on stdout — `T<n>` alone from an older hub), then — a repo named, i.e. a development task —
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
#                       parent session on the record). --blank (T652, EPIC
#                       T651 C1): a blank new session — the title is only its
#                       placeholder (「新会话」), no first turn is given, and each
#                       one is its own record (the token carries a nonce).
#   fleet-task-record.sh retitle T<n> --from F --title T
#                     → a blank session's record renamed ONCE (T652): from its
#                       placeholder F to its first prompt's first line T — the
#                       hub compares on F, so a second rename changes nothing.
#   fleet-task-record.sh respawn T<n> [--prev <ID>] [--redo] [--force] [--origin O] [--print] [<session>]
#                     → a record whose session never came up (or went down, its
#                       window gone) opened again on the SAME record (T642): its
#                       words, repo, agent and reap; the new ID continues --prev.
#                       --redo: a record that FAILED opened again for its next
#                       attempt (EPIC T644 C5 — a batch member's retry keeps its
#                       code; the window takes the task's ID, C2), its first turn
#                       saying so.
#                       A record whose session still runs (a window here carries
#                       it, or the hub sees it live elsewhere) is not opened again:
#                       「已在 <where> 跑」 on stderr, exit 0 (--force opens anyway —
#                       T847). The new window's parent is the record's own
#                       (--origin-wid), never the caller's, unless --origin says.
#                       FLEET_TASK_RESPAWN is the spawner seam.
#   fleet-task-record.sh revive <ref> [<window>]
#                     → a record its session's ID close ended (cancelled 「结束·没交回
#                       结果」) while a window here still carries that ID goes on:
#                       the ID reopened on that window, the hub puts the record back
#                       (T847). Refused (1) for a record ended by its result, or no
#                       window here carrying it.
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
# (and, for get / resolve, a code naming several tasks) · 3 not applicable — no hub here (CCQUOTA_FLEET off for this fleet, or no node
# token): nothing is sent, nothing printed, so every caller stays byte for byte
# what it was without a hub.
# Seams: FLEET_HUB_CURL (default curl), FLEET_HUB_TIMEOUT (default 10 s).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-task-record: %s\n' "$2" >&2; exit "$1"; }
usage() { die 2 "usage: fleet-task-record.sh new|get|resolve|code|set|retitle|attach|of|find-issue … (see the header)"; }

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
  # A separated login's broker pair is asked of the credential proxy (~0.25 s):
  # its being set up is the answer here (T992) — the call itself says
  # "no node token" (exit 3) if the proxy does not give one.
  if [ ! -r "$(fleet_node_env_file)" ] && _fleet_node_separated; then return 0; fi
  fleet_node_pair >/dev/null 2>&1
}

# call METHOD PATH [JSON] → the answer's body on stdout; rc 0 on HTTP 200.
task_record_curl() {
  local body="$1" mode="$2"; shift 2
  # Preserve the existing argv contract: URL is last, including for curl
  # wrappers supplied by self-hosted installations and the transport fixtures.
  local url="${!#}"
  set -- "${@:1:$(($# - 1))}"
  if [ "$mode" = body-pipe ]; then
    # Fresh pipe on each attempt, including forwarder -> direct fallback.
    # Auth remains curl's stdin config, large proofs never enter exec argv.
    "$@" --data-binary @/dev/fd/3 "$url" 3< <(printf '%s' "$body")
  else
    "$@" ${body:+--data-binary "$body"} "$url"
  fi
}
call() {
  local m="$1" p="$2" body="${3:-}" pair url tok resp rc code why
  # One interpreter for the whole call (T992, bin/fleet_node_http.py): the pair,
  # the signature and the request in-process — this road's fleet_node_pair (a
  # Python for the token) + fleet_node_auth (another to sign) + curl was ~1 s a
  # call. A seam (FLEET_HUB_CURL) or FLEET_NODE_HTTP=0 keeps the road below.
  if [ -z "${FLEET_HUB_CURL:-}" ] && [ "${FLEET_NODE_HTTP:-1}" != 0 ] && [ -f "$BIN/fleet_node_http.py" ]; then
    resp=$(printf '%s' "$body" | python3 "$BIN/fleet_node_http.py" call "$m" "$p"); rc=$?
    case "$rc" in
      0) ;;
      3) die 3 "no node token here" ;;
      *) printf 'fleet-task-record: hub unreachable (fleet_node_http exit %s)\n' "$rc" >&2; return 1 ;;
    esac
  else
  pair=$(fleet_node_pair) || die 3 "no node token here"
  url=${pair%%	*}; tok=${pair#*	}
  # signed once this login has a key (issue #3710), else the token
  # The agent's warm road first (issue T672): one round trip on its kept
  # connection; nobody there (curl 7) or its own refusal ⇒ the direct one.
  # Only a remote https hub: a login's own broker (http://127.0.0.1:…/hub) is
  # already local, and the forwarder serves the hub, not it.
  local sock=''; case "$url" in https://*) sock=$(fleet_hub_sock) ;; esac
  if [ -n "$sock" ]; then
    resp=$(printf 'header = "Authorization: %s"\n' "$(fleet_node_auth "$m" "$url$p" "$tok")" | \
      task_record_curl "$body" "${4:-}" "${FLEET_HUB_CURL:-curl}" -sS --max-time "${FLEET_HUB_TIMEOUT:-10}" -K - -o - -w '\n%{http_code}' --unix-socket "$sock" \
        -H "X-Fleet-Hub: $url" -H "Host: $(printf '%s' "${url#*://}" | cut -d/ -f1)" -X "$m" -H 'Content-Type: application/json' \
        "http://${url#*://}$p" 2>/dev/null); rc=$?   # plain on the socket: the agent holds the TLS
    case "$rc:$resp" in 7:*|0:hubfwd:\ this\ forwarder*|0:hubfwd:\ not\ a\ path*) sock='' ;; esac
  fi
  [ -n "$sock" ] || { resp=$(printf 'header = "Authorization: %s"\n' "$(fleet_node_auth "$m" "$url$p" "$tok")" | \
    task_record_curl "$body" "${4:-}" "${FLEET_HUB_CURL:-curl}" -sS --max-time "${FLEET_HUB_TIMEOUT:-10}" -K - -o - -w '\n%{http_code}' \
      -X "$m" -H 'Content-Type: application/json' "$url$p" 2>/dev/null); rc=$?; }
  [ "$rc" -eq 0 ] && [ -n "$resp" ] || { printf 'fleet-task-record: hub unreachable (curl exit %s)\n' "$rc" >&2; return 1; }
  fi
  code=$(printf '%s\n' "$resp" | tail -n 1)
  printf '%s\n' "$resp" | sed '$d'
  case "$code" in
    200|202) return 0 ;;
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

# The book of codes (EPIC T644 C3): `T<n><TAB><code><TAB><ID>` per task this login
# heard a code for, so a report header or a verdict names a task by its code
# without asking the hub again — a task's written code is its for life.
CODES="${FLEET_ID_DIR:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/ids}/task-codes.tsv"   # fleet_id.py task_code reads it
# remember <answer JSON> → book the record's code (a {task:…} answer or a bare record)
remember() {
  python3 -c 'import json, os, re, sys
path, raw = sys.argv[1], sys.argv[2]
try:
    d = json.loads(raw)
except ValueError:
    sys.exit(0)
t = d.get("task") if isinstance(d, dict) and isinstance(d.get("task"), dict) else d
if not isinstance(t, dict):
    sys.exit(0)
ref, short, fid = t.get("id") or "", t.get("short") or "", t.get("fid") or ""
if not re.match(r"^T[1-9][0-9]{0,9}$", ref):
    ref = t.get("task") or ""
if not (re.match(r"^T[1-9][0-9]{0,9}$", ref) and re.match(r"^[A-Z][0-9A-Z]{1,25}$", short)):
    sys.exit(0)
have = open(path).read().splitlines() if os.path.exists(path) else []
if any(l.split("\t")[:1] == [ref] for l in have):
    sys.exit(0)
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "a") as f:
    f.write("%s\t%s\t%s\n" % (ref, short, fid))' "$CODES" "$1" 2>/dev/null || :
}
# booked <T<n>|code> → that task's booked code; rc 1 when the book has none
booked() {
  [ -f "$CODES" ] || return 1
  awk -F'\t' -v r="$1" -v u="$(printf '%s' "${1#\#}" | tr 'a-z' 'A-Z')" \
    '$1 == r || $2 == u { print $2; f = 1; exit } END { exit !f }' "$CODES"
}
# code_line <answer JSON> → the record's code, else its T<n> (an older hub)
code_line() {
  local c
  c=$(printf '%s' "$1" | field task.short); [ -n "$c" ] || c=$(printf '%s' "$1" | field short)
  [ -n "$c" ] || c=$(printf '%s' "$1" | field task.id); [ -n "$c" ] || c=$(printf '%s' "$1" | field id)
  printf '%s\n' "$c"
}
# ambiguous <body> → rc 0 when it is the hub's 409 AMBIGUOUS, one stderr line per
# candidate (code · title · state)
ambiguous() {
  case "$1" in *'"code":"AMBIGUOUS"'*) ;; *) return 1 ;; esac
  printf '%s' "$1" | python3 -c 'import json,sys
try:
    for c in json.load(sys.stdin).get("candidates") or []:
        print("fleet-task-record: %s · %s · %s" % (c.get("short") or c.get("task") or c.get("id"), c.get("title", ""), c.get("state", "")))
except Exception:
    pass' >&2 || :
  return 0
}

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
  title='' bodyf='' repo='' spawn=0 reap='' agent='' as_agent='' tsess='' pwin='' origin='' via=编排 blank=0
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
      --blank) blank=1 ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$title" ] || usage
  [ "$blank" = 0 ] || [ -z "$bodyf" ] || die 2 "--blank takes no words"
  # a dispatch that opens its session is clocked from here when no ↵ came with it
  # (T716, fleet_timing.py): every stage to its agent's input box under one run
  if [ "$spawn" = 1 ] && [ -z "${FLEET_TIMING_T0:-}" ]; then
    FLEET_TIMING_T0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time()' 2>/dev/null) && export FLEET_TIMING_T0
  fi
  applicable || die 3 "no hub here: a task has nowhere to be recorded (issue #4898)"
  body=''
  if [ "$bodyf" = - ]; then body=$(cat); elif [ -n "$bodyf" ]; then body=$(cat "$bodyf") || die 2 "cannot read $bodyf"; fi
  # The local files the words name travel WITH them (T793): the session may be
  # placed on another machine (T742), where ~/fleet-drafts/… is not. What cannot
  # come (not here, too big) is said on stderr and in the body — never dropped.
  if [ -n "$body" ]; then
    cbody=$(printf '%s\n' "$body" | python3 "$BIN/fleet_local_refs.py" carry 2>"${TMPDIR:-/tmp}/fleet-carry.$$") && body=$cbody
    while IFS= read -r ln; do
      [ -n "$ln" ] && printf 'fleet-task-record: %s — 会话在别的机器上读不到它\n' "$ln" >&2
    done < "${TMPDIR:-/tmp}/fleet-carry.$$"
    rm -f "${TMPDIR:-/tmp}/fleet-carry.$$"
  fi
  # One token per (caller, words): a session asking twice is one record.
  okey=$(fleet_origin_key 2>/dev/null) || okey=''
  tok="orch:${okey:-hub}:$(printf '%s\n%s' "$title" "$body" | shasum 2>/dev/null | cut -c1-16)"
  # a blank session's words are only its placeholder: every open is its own record
  [ "$blank" = 0 ] || tok="$tok-$(date +%s)$$"
  # A development task's session starts as the worker template, as
  # dash-issue-session.sh gives an issue worker (#3122): the shipped fleet-worker
  # when this login has it, else a plain session (issue #4897).
  # The file is read ONCE a start (T716): the probe's answer is the launch's, and
  # it rides to the spawner (FLEET_AS_KV, keyed by FLEET_AS_KV_FOR) so
  # dash-raw-session.sh does not read it again.
  as_for=claude; [ "${agent:-${FLEET_AGENT:-claude}}" = codex ] && as_for=codex   # #4726
  # looked for where the session will run — the repo's main checkout, as the
  # spawner looks (T992: from $PWD the two never matched, and dash-raw-session.sh
  # read the file a second time)
  asdir=${FLEET_MAIN:-}
  if [ -z "$asdir" ] && [ -n "$repo" ]; then
    asdir=$( s=${tsess:-$(fleet_current_session 2>/dev/null)}
             [ -n "$s" ] && fleet_load_repo_conf "$s" "$(fleet_target_repo "$s" "$repo" 2>/dev/null || printf %s "$repo")" >/dev/null 2>&1 \
               && printf '%s' "${FLEET_MAIN:-}" )
  fi
  asdir=${asdir:-$PWD}
  kv=''
  if [ -n "$repo" ] && [ -z "$as_agent" ] && [ "$spawn" = 1 ] \
     && kv=$(python3 "$BIN/fleet-agent-def.py" launch fleet-worker --dir "$asdir" \
          --for "$as_for" 2>/dev/null); then
    as_agent=fleet-worker
  fi
  # Resolve the definition's provider before acceptance, independently of its
  # tools/body. Explicit --agent wins. Every retry retains the full input.
  template=''
  if [ -n "$as_agent" ]; then
    [ -n "$kv" ] || kv=$(python3 "$BIN/fleet-agent-def.py" launch "$as_agent" --dir "$asdir" --for "$as_for") || exit 2
    template=$(printf '%s\n' "$kv" | awk -F'\t' '$1 == "agent" {print $2; exit}')
    FLEET_AS_KV=$kv FLEET_AS_KV_FOR="$as_agent	$as_for	$asdir"
    export FLEET_AS_KV FLEET_AS_KV_FOR
  fi
  t=''
  {
    # the dispatch and the record's payload in ONE interpreter (T992: they were
    # fleet_dispatch.py + a payload `python3 -` — two starts, ~0.2 s): line 1 the
    # dispatch (fleet_dispatch.resolve, its CLI's own call), line 2 the payload
    both=$(python3 - "$BIN" "$agent" "$template" "${FLEET_AGENT:-}" "$tok" "$title" "$body" "$repo" "$reap" "$as_agent" "$via" <<'JSON'
import json,sys
sys.path.insert(0, sys.argv[1])
import fleet_dispatch
agent,template,default,tok,title,body,repo,reap,as_agent,via=sys.argv[2:]
try:
    d=fleet_dispatch.resolve([agent] if agent else [], template, "", default, None, tok)
except (ValueError, TypeError) as e:
    sys.exit("fleet_dispatch: %s" % e)
repo=repo.lower()
print(json.dumps(d, separators=(",", ":")))
print(json.dumps(dict(authority_version=1, token=d["request_id"], title=title, via=via, repo=repo,
    requested_agent=d["requested_agent"], resolved_agent=d["resolved_agent"],
    request_payload=dict(dispatch=d,title=title,body=body,repo=repo,reap=reap,template=as_agent,rule="",draft="",pr_note="")),
    ensure_ascii=False))   # the hub reads 16 KB: UTF-8 words, not \uXXXX (half the bytes — T661)
JSON
    ) || exit 2
    dispatch=${both%%$'\n'*}; payload=${both#*$'\n'}
    accepted=$(call POST /v1/node/tasks "$payload") || exit 1
    # the answer read in ONE interpreter (T992: `field` ×3, the contract check
    # and `remember` were five starts, ~0.4 s): T<n>, its code, its ID, the
    # accepted dispatch — and the code booked as `remember` books it
    got=$(python3 - "$dispatch" "$accepted" "$CODES" <<'JSON'
import json,os,re,sys
d,raw,codes=sys.argv[1:]
d=json.loads(d)
try:
    t=json.loads(raw)
except ValueError:
    t={}
tid=t.get("id") if isinstance(t, dict) else None
if not (isinstance(tid, str) and re.match(r"^T[1-9][0-9]{0,9}$", tid)):
    print(""); sys.exit(0)
if t.get("authority_version") != 1 or t.get("requested_agent") != d["requested_agent"] or t.get("resolved_agent") != d["resolved_agent"]:
    sys.exit("hub did not accept the requested provider contract")
d.update(task=t["id"],generation=t["generation"],attempt_id=t["attempt_id"])
short, fid = t.get("short") or "", t.get("fid") or ""
print(tid); print(short if isinstance(short, str) else ""); print(fid if isinstance(fid, str) else "")
print(json.dumps(d,separators=(",", ":")))
if re.match(r"^[A-Z][0-9A-Z]{1,25}$", short or ""):
    try:
        have = open(codes).read().splitlines() if os.path.exists(codes) else []
        if not any(l.split("\t")[:1] == [tid] for l in have):
            os.makedirs(os.path.dirname(codes), exist_ok=True)
            with open(codes, "a") as f:
                f.write("%s\t%s\t%s\n" % (tid, short, fid))
    except OSError:
        pass
JSON
    ) || exit 1
    { IFS= read -r t; IFS= read -r short; IFS= read -r tfid; IFS= read -r dispatch; } <<EOF
$got
EOF
    is_tref "$t" || die 1 "the hub's answer names no accepted record"
    # the task's code first (EPIC T644 C3), then T<n>; an older hub: T<n> alone
    [ -n "$short" ] && printf '%s\n' "$short"
    printf '%s\n' "$t"
    # a new session is clocked from its ↵ (T684): the hub's record is `record`
    # (T716 — `placed` is the placement's answer, dash-raw-session.sh)
    fleet_timing_at record
  }
  export FLEET_DISPATCH="$dispatch"
  # The task's own ID (EPIC T644 C1) rides to the spawner, bound to THIS record: its
  # first window goes by it (C2, fleet_task_fid) without asking the hub again.
  fleet_is_fid "$tfid" && export FLEET_TASK_FID="$t=$tfid"
  # A development task the hub accepted is the record alone (issue #4897, EPIC
  # #4895 批 0): no GitHub issue — the session opens in its own worktree of the
  # repo, bound to T<n> (dash-raw-session.sh --repo --task stamps @task_flow), reads
  # the record, opens its PR, merges it on a green gate and closes the record with
  # its report; it is reaped once the record is closed (`merged`). Not --spawn: the
  # record waits (await T<n> names it).
  if [ -n "$repo" ]; then
    [ "$spawn" = 1 ] || exit 0
    pfa=--placeholder
    if [ "$blank" = 0 ]; then
      pf=$(mktemp "${TMPDIR:-/tmp}/fleet-task-prompt.XXXXXX") || die 1 "no temp file"
      if [ -n "$body" ]; then printf '%s\n\n%s\n' "$title" "$body" > "$pf"; else printf '%s\n' "$title" > "$pf"; fi
      pfa="--prompt-file=$pf"
    fi
    exec bash "$BIN/dash-raw-session.sh" --repo "$repo" --task "$t" --name "$title" --reap "${reap:-merged}" \
      ${as_agent:+--as "$as_agent"} ${agent:+--agent "$agent"} ${origin:+--origin "$origin"} $pwin ${pfa:+"$pfa"} ${tsess:+"$tsess"}
  fi
  [ "$spawn" = 1 ] || exit 0
  pfa=--placeholder
  if [ "$blank" = 0 ]; then
    pf=$(mktemp "${TMPDIR:-/tmp}/fleet-task-prompt.XXXXXX") || die 1 "no temp file"
    printf '%s\n' "${body:-$title}" > "$pf"
    pfa="--prompt-file=$pf"
  fi
  exec bash "$BIN/dash-raw-session.sh" --no-repo --task "$t" --name "$title" ${reap:+--reap "$reap"} \
    ${as_agent:+--as "$as_agent"} ${agent:+--agent "$agent"} ${origin:+--origin "$origin"} $pwin ${pfa:+"$pfa"} ${tsess:+"$tsess"}
fi

# respawn T<n> [--prev <ID>] [--redo] [--origin O] [--print] [<fleet session>] (T642): a
# record whose session never came up — or went down with its window gone — opened
# AGAIN, on the SAME record: the words, repo, agent file, provider and reap policy
# it was dispatched with, the new window's ID continuing <ID> (--prev) so a batch
# reads it as the next baton of the same member. Never a new T<n>. What
# `fleet-epic-tick.py`'s and `await`'s hint names (fleet_id.start_hint). --redo
# (EPIC T644 C5): a record that failed — by its ID's result, never a cancel or a
# refusal — is the retry's record too, so the member keeps its code; its window
# takes the task's ID and opens its next attempt (dash-raw-session.sh, C2), and the
# hub's write-through lets that attempt's end replace the failure (C6).
if [ "$cmd" = respawn ]; then
  t="${1:-}"; is_task_ref "$t" || usage; shift   # its code too (EPIC T644 C3)
  prev='' origin='' pwin='' tsess='' redo=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --prev) prev="${2:-}"; shift ;;
      --redo) redo=1 ;;
      --force) force=1 ;;
      --origin) origin="${2:-}"; shift ;;
      --print) pwin=--print ;;
      -*) usage ;;
      *) tsess="$1" ;;
    esac
    shift
  done
  [ -z "$prev" ] || fleet_is_fid "$prev" || die 2 "--prev wants a full ID"
  applicable || die 3 "no hub here: no record to respawn"
  got=$(call GET "/v1/node/tasks/${t#\#}") || exit 1
  remember "$got"; t=$(printf '%s' "$got" | field task.id); is_tref "$t" || die 1 "the hub's answer names no record"
  plan=$(printf '%s' "$got" | python3 -c '
import json, sys
d = json.load(sys.stdin); t = d.get("task") or {}
redo = sys.argv[1] == "1"
if t.get("authority_version") != 1:
    sys.exit("not an authoritative task record")
if redo and t.get("outcome") not in ("failed", "exited"):
    sys.exit("the record has not failed (%s): --redo restarts a failed one" % (t.get("outcome") or "still open"))
if t.get("outcome") and not redo:
    sys.exit("the record is over (%s): nothing to respawn" % t["outcome"])
raw = t.get("request_payload") or {}
p = json.loads(raw) if isinstance(raw, str) and raw else (raw if isinstance(raw, dict) else {})
disp = dict(p.get("dispatch") or {})
if disp:
    disp.update(task=t["id"], generation=t.get("generation", 1), attempt_id=t.get("attempt_id", ""))
agent = t.get("resolved_agent") if t.get("resolved_agent") in ("claude", "codex") else ""
# its session, as the hub last saw it on ANY machine (T847): a live one is not respawned
lv = d.get("live") if isinstance(d.get("live"), dict) else {}
live = "-"
if lv and not lv.get("stale") and lv.get("state") not in ("exited", "", None):
    live = (lv.get("key") or "?") + "@" + (t.get("machine") or "?")
print("\t".join([" ".join((t.get("title") or "-").split()), (p.get("repo") or t.get("repo") or "-").lower(), p.get("reap") or "-",
                 p.get("template") or "-", agent or "-", json.dumps(disp, separators=(",", ":")) if disp else "-",
                 t.get("fid") or "-", live]))
print(p.get("body") or "", end="")' "$redo") || die 1 "$t: cannot respawn"
  IFS=$'\t' read -r r_title r_repo r_reap r_as r_agent r_disp r_fid r_live <<< "$(printf '%s\n' "$plan" | head -n 1)"
  r_body=$(printf '%s\n' "$plan" | sed '1d')
  # One record, one window (T847): a record whose session still runs — a window
  # here, or the hub's live word for it on another machine — is answered with
  # where it runs, never a second window (a copy shares its ID; the copy's reap
  # ended the record). --force opens one anyway.
  if [ "$force" = 0 ]; then
    [ "$r_fid" = - ] && r_fid=''
    if run=$(fleet_task_running "$t" "$r_fid"); then
      printf 'fleet-task-record: %s 已在 %s:%s 跑 — 不再开窗（--force 照开）\n' "$t" "${run%%	*}" "${run#*	}" >&2
      [ -z "$pwin" ] || tmux -L "${run%%	*}" display-message -p -t "${run#*	}" '#{window_id}	#{window_name}	#{@worktree}	#{@fleet_id}' 2>/dev/null
      exit 0
    fi
    if [ "$r_live" != - ]; then
      printf 'fleet-task-record: %s 已在 %s 跑（hub 的在线记录）— 不再开窗（--force 照开）\n' "$t" "$r_live" >&2
      exit 0
    fi
  fi
  pf=$(mktemp "${TMPDIR:-/tmp}/fleet-task-prompt.XXXXXX") || die 1 "no temp file"
  [ "$r_title" = - ] && r_title=$t
  if [ -n "$r_body" ]; then printf '%s\n\n%s\n' "$r_title" "$r_body" > "$pf"; else printf '%s\n' "$r_title" > "$pf"; fi
  if [ "$redo" = 1 ]; then
    r_code=$(printf '%s' "$got" | field task.short); [ -n "$r_code" ] || r_code=$t
    printf '\n这是重试：同一个任务 %s 的下一次，上一次失败了——先读它的结果（fleet-id.sh get %s）再动手。\n' "$r_code" "$r_code" >> "$pf"
  fi
  [ "$r_disp" = - ] || export FLEET_DISPATCH="$r_disp"
  ra=(--task "$t" --name "$r_title")
  if [ "$r_repo" = - ]; then ra=(--no-repo ${ra[@]+"${ra[@]}"}); [ "$r_reap" = - ] || ra+=(--reap "$r_reap")
  else ra=(--repo "$r_repo" ${ra[@]+"${ra[@]}"} --reap "$( [ "$r_reap" = - ] && echo merged || echo "$r_reap")"); fi
  [ "$r_as" = - ] || ra+=(--as "$r_as")
  [ "$r_agent" = - ] || ra+=(--agent "$r_agent")
  [ -z "$prev" ] || ra+=(--prev "$prev")
  # Explicit --origin remains a legacy spawner option for this slice; never
  # restore a relationship from historical Task columns.
  [ -z "$origin" ] || ra+=(--origin "$origin")
  [ -z "$pwin" ] || ra+=("$pwin")
  ra+=("--prompt-file=$pf")
  [ -z "$tsess" ] || ra+=("$tsess")
  exec bash "${FLEET_TASK_RESPAWN:-$BIN/dash-raw-session.sh}" ${ra[@]+"${ra[@]}"}
fi
# revive <ref> [<window>] (T847): a record its session's ID CLOSE ended (cancelled,
# 「结束·没交回结果」) while a window here still carries that ID — a copy opened on
# the same record shared the ID, and the copy's reap closed it — goes on: the ID's
# ledger takes one `reopened` event naming that window (fleet_id.py revive), pushed
# now; the hub clears the close and puts the record back to the state it had. Only
# that end is undone: a record ended by its result, or one no window here carries,
# is refused (exit 1), a record still open is said and left (exit 0).
if [ "$cmd" = revive ]; then
  t="${1:-}"; is_task_ref "$t" || usage
  wsel="${2:-}"
  case "$wsel" in ''|@[0-9]*) ;; *) usage ;; esac
  applicable || die 3 "no hub here: no record to revive"
  got=$(call GET "/v1/node/tasks/${t#\#}") || exit 1
  remember "$got"
  IFS=$'\t' read -r t fid state outcome obs <<< "$(printf '%s' "$got" | python3 -c '
import json, sys
t = (json.load(sys.stdin).get("task") or {})
print("\t".join((str(t.get(k) or "-")) for k in ("id", "fid", "state", "outcome", "observation")))')"
  is_tref "$t" || die 1 "the hub's answer names no record"
  fleet_is_fid "$fid" || die 1 "$t has no ID of its own: nothing to revive"
  if [ "$outcome" = - ]; then printf '%s\n' "$t"; printf 'fleet-task-record: %s is still open (%s) — nothing to revive\n' "$t" "$state" >&2; exit 0; fi
  case "$state:$obs" in
    "cancelled:id_closed:$fid:"*) ;;
    *) die 1 "$t ended $outcome ($obs) — only an end its ID's close made is revived" ;;
  esac
  # the window named, else the first carrying the ID whose agent has not exited
  if [ -n "$wsel" ]; then w=$(fleet_task_windows '' "$fid" | awk -F'\t' -v w="$wsel" '$2 == w { print $2; exit }')
  else w=$(fleet_task_windows '' "$fid" | awk -F'\t' '$3 != "exited" { print $2; exit }'); fi
  [ -n "$w" ] || die 1 "no window here carries $t's ID ${fid}${wsel:+ as $wsel} — revive it on the machine that runs it"
  FLEET_ID_PUSH=0 python3 "$BIN/fleet_id.py" revive "$fid" --window "$w" >/dev/null || exit 1
  bash "$BIN/fleet-id.sh" push "$fid" >/dev/null 2>&1
  got=$(call GET "/v1/node/tasks/$t") || exit 1
  remember "$got"
  state=$(printf '%s' "$got" | field task.state)
  [ "$state" != cancelled ] || die 1 "$t: the ID is reopened here but the hub still says cancelled (fleet-id.sh push $fid, then look again)"
  code_line "$got" 2>/dev/null || printf '%s\n' "$t"
  printf 'fleet-task-record: %s 恢复为 %s — 由 %s 接着跑\n' "$t" "$state" "$w" >&2
  exit 0
fi
# A code the book already holds needs no hub (and works where none answers now).
if [ "$cmd" = code ] && is_task_ref "${1:-}" && c=$(booked "$1"); then printf '%s\n' "$c"; exit 0; fi

applicable || exit 3

if [ "$cmd" = authority ]; then
  pair=$(fleet_node_pair) || exit 3
  printf '%s\n' "${pair%%	*}"
  exit 0
fi
case "$cmd" in
  stop)
    is_tref "${1:-}" || usage
    payload=$(python3 -c 'import json,sys; x=json.load(sys.stdin); assert isinstance(x,dict); print(json.dumps(x,separators=(",",":")))') || exit 2
    call POST "/v1/node/tasks/$1/stop" "$payload"
    exit $? ;;
  execution-list)
    call GET /v1/node/tasks/executions
    exit $? ;;
  execution-get)
    is_tref "${1:-}" || usage
    call GET "/v1/node/tasks/$1/execution"
    exit $? ;;
  execution-start)
    is_tref "${1:-}" || usage
    call GET "/v1/node/tasks/$1/execution/start"
    exit $? ;;
  execution-claim)
    is_tref "${1:-}" || usage
    payload=$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),separators=(",",":")))') || exit 2
    call POST "/v1/node/tasks/$1/execution/claim" "$payload"
    exit $? ;;
  execution-exit)
    is_tref "${1:-}" || usage
    payload=$(python3 -c 'import json,sys
raw=sys.stdin.buffer.read((1<<20)+1)
if len(raw)>(1<<20) or not isinstance(json.loads(raw),dict): sys.exit(2)
sys.stdout.buffer.write(raw)') || exit 2
    call POST "/v1/node/tasks/$1/execution/exit" "$payload" body-pipe
    exit $? ;;
  children)
    is_task_ref "${1:-}" || usage
    call GET "/v1/node/tasks/${1#\#}/children"
    exit $? ;;
  mutate)
    is_task_ref "${1:-}" || usage
    mutation=$(python3 -c 'import json,sys; print(json.dumps({"authority_version":1,"mutation":json.load(sys.stdin)}))') || exit 2
    call POST "/v1/node/tasks/${1#\#}" "$mutation"
    exit $? ;;
  resolve|code)
    is_task_ref "${1:-}" || usage
    # the book answers a task it has heard a code for — no hub round trip
    if is_tref "$1" && c=$(booked "$1"); then printf '%s\n%s\n' "$c" "$1"; exit 0; fi
    out=$(call GET "/v1/node/tasks/${1#\#}" 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then
      ambiguous "$out" && { printf 'fleet-task-record: %s names more than one task — name it longer\n' "$1" >&2; exit 2; }
      printf 'fleet-task-record: no task answers to %s\n' "$1" >&2; exit 1
    fi
    remember "$out"
    t=$(printf '%s' "$out" | field task.id); short=$(printf '%s' "$out" | field task.short)
    is_tref "$t" || die 1 "the hub's answer names no record"
    if [ "$cmd" = code ]; then [ -n "$short" ] || exit 1; printf '%s\n' "$short"; exit 0; fi
    [ -n "$short" ] && printf '%s\n' "$short"
    printf '%s\n' "$t" ;;
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
    remember "$out"
    short=$(printf '%s' "$out" | field short)
    [ -n "$short" ] && printf '%s\n' "$short"
    printf '%s\n' "$t" ;;
  get)
    is_task_ref "${1:-}" || usage
    out=$(call GET "/v1/node/tasks/${1#\#}"); rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -ne 0 ]; then [ "$rc" = 3 ] && exit 3; ambiguous "$out" 2>/dev/null && exit 2; exit 1; fi
    remember "$out" ;;
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
    is_task_ref "${1:-}" || usage
    t="${1#\#}"; shift
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
    out=$(call POST "/v1/node/tasks/$t" "$(json ${args[@]+"${args[@]}"})") || exit $?
    remember "$out"; code_line "$out" ;;
  retitle)
    # a blank session's record (T652): placeholder → its first prompt's first line, once
    is_task_ref "${1:-}" || usage
    t="${1#\#}"; shift
    from='' to=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --from) from="${2:-}"; shift ;;
        --title) to="${2:-}"; shift ;;
        *) usage ;;
      esac
      shift
    done
    [ -n "$from" ] && [ -n "$to" ] || usage
    call POST "/v1/node/tasks/$t" "$(python3 -c 'import json,sys
print(json.dumps({"authority_version": 1, "mutation": {"kind": "retitle", "idempotency_key": "retitle-" + sys.argv[1],
    "from": sys.argv[2], "title": sys.argv[3]}}, ensure_ascii=False))' "$t" "$from" "$to")" >/dev/null || exit 1 ;;
  attach)
    is_task_ref "${1:-}" || usage
    t="${1#\#}"
    sess=$(fleet_current_session 2>/dev/null) || die 1 "no fleet session here"
    w=$(win_of "${2:-}") || die 1 "no window to attach"
    k=$(fleet_window_okey "$sess" "$w")
    wid=$(fleet_worker_id "$sess" "$w" 2>/dev/null) || wid=''
    [ -n "$k" ] || [ -n "$wid" ] || die 1 "window $w has no session key"
    out=$(call POST "/v1/node/tasks/$t" "$(json key="$k" worker_id="$wid" state=open)") || exit $?
    remember "$out"; code_line "$out" ;;
  *) usage ;;
esac
