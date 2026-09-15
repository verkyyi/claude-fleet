#!/bin/bash
# fleet-emit.sh — the fleet's ONE outbound channel for session lifecycle facts
# (issue #625). OFF by default: with no FLEET_EMIT_URL configured it does nothing,
# touches no disk, opens no socket.
#
# WHY THIS EXISTS
# The fleet is the only component that knows what a session was FOR — it binds a
# session to a GitHub issue, gives it a worktree, and watches the PR that comes out
# of it. A usage ledger downstream knows what each session COST, keyed by session
# id, with no idea which issue was being worked. The join between spend and outcome
# is one field, and this script is what puts it on the wire. It is an EMITTER only:
# the fleet stays a tmux product (issue #625 says so explicitly — a browser mirror
# of the dash would be strictly worse than the hooks that already flip a window's
# colour the instant its state changes; the cross-session, over-time view is a
# different product's job, and it only needs the fleet to emit).
#
# THE FOUR FACTS
#   session.start  a Claude session began in a fleet pane — the event that maps the
#                  ledger's session id to an issue. Emitted on EVERY SessionStart,
#                  `source` included: a /fleet-handoff cycle ends one session id and
#                  starts another on the SAME issue, and both halves of that spend
#                  belong to the issue.
#   session.bind   a scratch became the worker for issue N (bin/fleet-bind.sh). This
#                  transition MUST be emitted or every scratch that turned into real
#                  work is attributed to nothing.
#   session.pr     a PR for a session's branch was opened / merged / closed —
#                  diffed off the prmap the PR refresher already maintains.
#   session.end    how it ended. Two `via` values because two different things end:
#                    via=hook  a Claude session ended (SessionEnd) — carries the
#                              ledger's session id + the CLI's `reason`. `clear` is
#                              a handoff cycle, not the end of the work.
#                    via=reap  the FLEET session ended — the worktree was reaped, so
#                              the outcome is known (landed / closed-unlanded). This
#                              rides fleet_reap_record, the one choke point every
#                              reaper funnels through (SessionEnd hook, dash ⌃x, the
#                              cleanup daemon, ledger-watch).
#
# WHAT LEAVES THE MACHINE — the whole allowlist, enforced below by construction
#   event · ts · session (the fleet's own session name) · session_id · repo ·
#   issue · pr · branch · from_branch · source · reason · state · action ·
#   outcome · verdict
# Nothing else. No prompt or transcript content, no file paths, no window/issue
# TITLES (a scratch window is named by free operator text), no hostname or user
# (the charter scrub — identity is carried by the token, not the payload), no
# credentials. Every field is passed through a per-field charset filter before it
# reaches the JSON, so a value can neither smuggle structure nor carry anything
# outside its declared shape. See docs/EMIT.md.
#
# NEVER BLOCKS, NEVER FAILS A SESSION
# An emit is an append of one small file to a bounded spool, then a DETACHED drain.
# A dead endpoint is a silent no-op, never a stalled worker: the caller returns as
# soon as the file is written, the drain runs with a hard curl timeout in a process
# with every fd closed, and nothing ever retries in the foreground. The spool is
# capped (FLEET_EMIT_QUEUE_MAX, default 500) and drops the OLDEST on overflow, so a
# permanently dead endpoint costs a bounded amount of disk and keeps the FRESH
# events rather than wedging on stale ones. A 4xx is treated as permanent and the
# event is dropped — one malformed event must not wedge the queue forever.
#
# USAGE
#   fleet-emit.sh <event> [--session S] [--session-id ID] [--repo R] [--issue N]
#                 [--pr P] [--branch B] [--from-branch B] [--source S]
#                 [--reason R] [--state S] [--action A] [--outcome O]
#                 [--verdict V] [--via V] [--stdin-json]
#   fleet-emit.sh --flush            drain the spool now (what the detached kick runs)
#   fleet-emit.sh --queue-depth      print the number of spooled events (doctor)
#
#   --stdin-json   read the Claude Code hook payload on stdin and take session_id +
#                  source/reason from it. This is how the SessionStart/SessionEnd
#                  hooks call it: each hook command gets its own copy of the
#                  payload, so the emitter parses its own and no existing hook has
#                  to be rewritten to share one.
#
# Always exits 0 on the emit path — a hook must never be failed by telemetry. The
# maintenance paths (--flush, --queue-depth) exit 0 too; only a usage error is 2.
set -u

BIN="$(cd "$(dirname "$0")" && pwd)"

# ── config resolution ─────────────────────────────────────────────────────────
# Same rule as every other hook-side read (issue #561): a hook inherits the pane's
# environment and NOTHING exports fleet.conf into it, so the conf must be LOADED.
# Global fleet.conf (sibling of bin/) → this fleet's overlay. FLEET_EMIT_URL/TOKEN
# are deliberately NOT in $_FLEET_GLOBAL_ONLY: fleets watch different repos and may
# well report to different endpoints, so the per-fleet overlay must win.
_emit_load_conf() {
  local sess="${1:-}"
  # fleet-lib sources the global fleet.conf on load (and honours
  # FLEET_SKIP_GLOBAL_CONF, which is what keeps the selftests install-independent),
  # so this is the whole global half — sourcing the conf again here would only
  # defeat that seam.
  # shellcheck source=/dev/null
  [ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh" >/dev/null 2>&1
  if [ -z "$sess" ] && [ -n "${TMUX:-}" ]; then
    sess=$(fleet_current_session 2>/dev/null)
  fi
  [ -n "$sess" ] && fleet_load_conf "$sess" >/dev/null 2>&1
  EMIT_SESSION="$sess"
  return 0
}

# Spool lives beside the other runtime caches. FLEET_EMIT_DIR is the test seam.
_emit_spool() {
  printf '%s' "${FLEET_EMIT_DIR:-${TMPDIR:-/tmp}/.claude-dash/emit}"
}

# ── field filters ─────────────────────────────────────────────────────────────
# Each field is reduced to its declared charset. This is the privacy allowlist AND
# the JSON safety rail in one: no quote, backslash, newline or control byte can
# survive, so the object below is valid JSON with no escaping pass, and a value can
# only ever be the shape its name promises.
_f_num()  { printf '%s' "${1:-}" | tr -cd '0-9'; }
_f_word() { printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9_.-'; }          # enums, ids, session names
_f_ref()  { printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9_./-'; }         # repo, branch (slash-bearing)

# ── one emit ──────────────────────────────────────────────────────────────────
EV=''; A_SESSION=''; A_SID=''; A_REPO=''; A_ISSUE=''; A_PR=''; A_BRANCH=''
A_FROM=''; A_SOURCE=''; A_REASON=''; A_STATE=''; A_ACTION=''; A_OUTCOME=''
A_VERDICT=''; A_VIA=''; READ_STDIN=0; MODE=emit

while [ "$#" -gt 0 ]; do
  case "$1" in
    --flush)        MODE=flush ;;
    --queue-depth)  MODE=depth ;;
    --stdin-json)   READ_STDIN=1 ;;
    --session)      A_SESSION="${2:-}"; shift ;;
    --session-id)   A_SID="${2:-}"; shift ;;
    --repo)         A_REPO="${2:-}"; shift ;;
    --issue)        A_ISSUE="${2:-}"; shift ;;
    --pr)           A_PR="${2:-}"; shift ;;
    --branch)       A_BRANCH="${2:-}"; shift ;;
    --from-branch)  A_FROM="${2:-}"; shift ;;
    --source)       A_SOURCE="${2:-}"; shift ;;
    --reason)       A_REASON="${2:-}"; shift ;;
    --state)        A_STATE="${2:-}"; shift ;;
    --action)       A_ACTION="${2:-}"; shift ;;
    --outcome)      A_OUTCOME="${2:-}"; shift ;;
    --verdict)      A_VERDICT="${2:-}"; shift ;;
    --via)          A_VIA="${2:-}"; shift ;;
    -h|--help)      sed -n '2,78p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)            printf 'fleet-emit: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)              [ -z "$EV" ] && EV="$1" ;;
  esac
  shift
done

SPOOL=$(_emit_spool)

# ── --queue-depth ─────────────────────────────────────────────────────────────
if [ "$MODE" = depth ]; then
  n=0
  [ -d "$SPOOL" ] && n=$(find "$SPOOL" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -cd '0-9')
  printf '%s\n' "${n:-0}"
  exit 0
fi

# ── --flush: drain the spool ──────────────────────────────────────────────────
# Single-instance (an atomic mkdir lock), oldest-first, one curl per event with a
# hard timeout. Stops at the first RETRYABLE failure and leaves the rest spooled —
# the next emit's kick retries. Never sleeps, never loops on a dead endpoint.
if [ "$MODE" = flush ]; then
  _emit_load_conf "$A_SESSION"
  URL="${FLEET_EMIT_URL:-}"
  [ -n "$URL" ] || exit 0
  [ -d "$SPOOL" ] || exit 0
  command -v curl >/dev/null 2>&1 || exit 0

  LOCK="$SPOOL/.flush.lock"
  mkdir "$LOCK" 2>/dev/null || exit 0        # another drain owns it — it will take ours too
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

  TOK="${FLEET_EMIT_TOKEN:-}"
  TMO="${FLEET_EMIT_TIMEOUT:-5}"; case "$TMO" in ''|*[!0-9]*) TMO=5 ;; esac

  # The glob expands sorted and the names are epoch-prefixed, so this is oldest-first.
  for p in "$SPOOL"/*.json; do
    [ -f "$p" ] || continue          # also catches the no-match literal glob
    if [ -n "$TOK" ]; then
      code=$(curl -sS -o /dev/null -w '%{http_code}' -m "$TMO" -X POST \
               -H 'Content-Type: application/json' \
               -H "Authorization: Bearer $TOK" \
               --data-binary @"$p" "$URL" 2>/dev/null)
    else
      code=$(curl -sS -o /dev/null -w '%{http_code}' -m "$TMO" -X POST \
               -H 'Content-Type: application/json' \
               --data-binary @"$p" "$URL" 2>/dev/null)
    fi
    case "$code" in
      2*)     rm -f "$p" 2>/dev/null ;;              # delivered
      4*)     rm -f "$p" 2>/dev/null ;;              # permanent: a bad event must not wedge the queue
      *)      exit 0 ;;                              # 5xx / network / timeout: leave spooled, stop
    esac
  done
  exit 0
fi

# ── the emit path ─────────────────────────────────────────────────────────────
[ -n "$EV" ] || { printf 'fleet-emit: usage: fleet-emit.sh <event> [--flag value …]\n' >&2; exit 2; }

# A HEADLESS claude is not this pane's session (issue #571): a `claude -p` helper
# inherits the pane's TMUX/TMUX_PANE *and* the global hooks, so its SessionStart /
# SessionEnd land here too. Only the TUI owns the pane; anything else would emit a
# phantom session against this issue. Unset (an older CLI, a selftest's `env -i`,
# or a non-hook caller like fleet-bind) ⇒ TUI.
case "${CLAUDE_CODE_ENTRYPOINT:-cli}" in cli) : ;; *) exit 0 ;; esac

# The Claude Code hook payload, when we were handed one. Read BEFORE the conf load
# so a tty-less caller can never hang here, and parsed with the same sed idiom the
# other hooks use (bin/session-end-hook.sh, bin/handoff-latch-reset-hook.sh) —
# there is no jq dependency anywhere on the hook path.
if [ "$READ_STDIN" = 1 ] && [ ! -t 0 ]; then
  _payload=$(cat 2>/dev/null)
  [ -z "$A_SID" ] && A_SID=$(printf '%s' "$_payload" \
    | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
  [ -z "$A_SOURCE" ] && A_SOURCE=$(printf '%s' "$_payload" \
    | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p' | head -n1)
  [ -z "$A_REASON" ] && A_REASON=$(printf '%s' "$_payload" \
    | sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p' | head -n1)
fi

_emit_load_conf "$A_SESSION"
URL="${FLEET_EMIT_URL:-}"
# THE OFF RAIL. No endpoint configured ⇒ emit nothing: no spool dir, no file, no
# network, no behaviour change. The fleet's value is that it works on a laptop with
# nothing else installed, and this must stay true.
[ -n "$URL" ] || exit 0

# Fill in what the pane knows and the caller didn't say. Hooks run INSIDE the pane,
# so bare tmux is correct (the socket rail: $TMUX already names this fleet's server).
[ -z "$A_SESSION" ] && A_SESSION="${EMIT_SESSION:-}"
[ -z "$A_REPO" ] && A_REPO="${FLEET_REPO:-}"
if [ -n "${TMUX_PANE:-}" ]; then
  [ -z "$A_ISSUE" ] && A_ISSUE=$(tmux display-message -p -t "$TMUX_PANE" '#{@issue}' 2>/dev/null)
  # A scratch has no @issue, and its branch is the `scratch-<K>` slug its worktree
  # is named after — the same resolution fleet-bind.sh and the SessionEnd hook use.
  if [ -z "$A_BRANCH" ] && [ -z "$(_f_num "$A_ISSUE")" ]; then
    _wt=$(tmux display-message -p -t "$TMUX_PANE" '#{@worktree}' 2>/dev/null)
    [ -z "$_wt" ] && _wt=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_current_path}' 2>/dev/null)
    A_BRANCH=$(fleet_scratch_key "$_wt" 2>/dev/null)
  fi
fi
# A bound issue names its branch by construction (one worktree, one issue, one PR),
# so this holds for a caller outside tmux too — a daemon that knows only the number.
if [ -z "$A_BRANCH" ]; then
  _i=$(_f_num "$A_ISSUE"); [ -n "$_i" ] && A_BRANCH="issue-$_i"
fi

# ── build the object ──────────────────────────────────────────────────────────
# Every value has already been reduced to its charset, so no escaping pass is
# needed and none is possible to get wrong. Empty fields are OMITTED rather than
# sent as null — a consumer reads "absent" the same way and the line stays small.
EV=$(printf '%s' "$EV" | tr -cd 'a-z.')
json="{\"event\":\"$EV\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
_add_word() { local v; v=$(_f_word "${2:-}"); [ -n "$v" ] && json="$json,\"$1\":\"$v\""; }
_add_ref()  { local v; v=$(_f_ref  "${2:-}"); [ -n "$v" ] && json="$json,\"$1\":\"$v\""; }
_add_num()  { local v; v=$(_f_num  "${2:-}"); [ -n "$v" ] && json="$json,\"$1\":$v"; }
_add_word session    "$A_SESSION"
_add_word session_id "$A_SID"
_add_ref  repo       "$A_REPO"
_add_num  issue      "$A_ISSUE"
_add_num  pr         "$A_PR"
_add_ref  branch     "$A_BRANCH"
_add_ref  from_branch "$A_FROM"
_add_word via        "$A_VIA"
_add_word source     "$A_SOURCE"
_add_word reason     "$A_REASON"
_add_word state      "$A_STATE"
_add_word action     "$A_ACTION"
_add_word outcome    "$A_OUTCOME"
_add_word verdict    "$A_VERDICT"
json="$json}"

# ── spool it ──────────────────────────────────────────────────────────────────
mkdir -p "$SPOOL" 2>/dev/null || exit 0
# One file per event: an append is a single create, so concurrent hooks across
# every window of every fleet can never interleave or lose each other's writes,
# and the drain can delete exactly what it delivered. The epoch prefix is what
# makes a plain name sort oldest-first.
f="$SPOOL/$(date -u +%s)-$$-${RANDOM:-0}.json"
printf '%s\n' "$json" > "$f" 2>/dev/null || exit 0

# Bound the queue: keep the NEWEST cap events, drop the oldest. A permanently dead
# endpoint costs a fixed amount of disk, and what survives is the fresh tail rather
# than a wedge of stale events nobody will want.
CAP="${FLEET_EMIT_QUEUE_MAX:-500}"; case "$CAP" in ''|*[!0-9]*) CAP=500 ;; esac
if [ "$CAP" -gt 0 ]; then
  # Count, then drop exactly the overflow off the FRONT of the sorted (=
  # oldest-first) glob. `head -n -N` would say this in one line but it is a GNU
  # extension BSD head rejects, and this runs on macOS as much as Linux.
  _n=0
  for _p in "$SPOOL"/*.json; do [ -f "$_p" ] && _n=$((_n + 1)); done
  if [ "$_n" -gt "$CAP" ]; then
    _drop=$(( _n - CAP ))
    for _p in "$SPOOL"/*.json; do
      [ "$_drop" -gt 0 ] || break
      [ -f "$_p" ] || continue
      rm -f "$_p" 2>/dev/null; _drop=$(( _drop - 1 ))
    done
  fi
fi

# ── kick the drain, DETACHED ──────────────────────────────────────────────────
# Every fd closed and fully backgrounded: the caller (a hook, a reaper, a daemon)
# returns immediately and can never be held open by a slow endpoint. This is the
# "never retry into the foreground" rail.
if command -v curl >/dev/null 2>&1; then
  ( "$BIN/fleet-emit.sh" --flush --session "$A_SESSION" >/dev/null 2>&1 </dev/null & ) >/dev/null 2>&1
fi
exit 0
