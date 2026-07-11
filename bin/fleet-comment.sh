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
#   fleet-comment.sh <issue> --from <role> --body "..." # force the footer's role
#   fleet-comment.sh <issue> --no-footer --body "..."   # suppress the footer
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
# Footer (issue #224): every posted comment gets a per-role SENDER footer so a
# reader can tell which fleet actor posted it, even though all comments share the
# one gh account. Two parts, appended just before the exec (idempotent, re-stamp
# safe):
#   • a visible EM-DASH signature line — NO EMOJI, the role WORD carries identity:
#       — fleet · <role> · <context>          (context = #<issue> when the sender is
#                                               issue-bound, else the fleet slug)
#   • an invisible machine marker for tooling:
#       <!-- fleet:from role=<role> session=<slug> issue=<n> -->
# Role resolution: explicit --from <role> wins → else auto-detect (steward via the
# FLEET_SEAT env / fleet_seat(); worker/scout via fleet_seat() + the @scout window
# marker) → else the generic word 'fleet'. The footer identifies role + fleet ONLY
# — never $(hostname), $USER, or any other private identifier (the charter scrub).
# --no-footer is an escape hatch that drops the signature+marker but NEVER the
# no-relay loop-safety marker (that stays independent, verbatim, and last).
#
# Repo resolution mirrors dash-issue-comment.sh: $CF_REPO wins, else this fleet's
# cached repo, else the global FLEET_REPO. Prints the created comment URL on
# success (like `gh issue comment`).
set -uo pipefail

MARKER='<!-- fleet:no-relay -->'
FROM_PREFIX='<!-- fleet:from '   # footer machine-marker prefix (issue #224)
NL=$'\n'

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

# Which fleet ROLE is posting? Explicit --from wins (honoured verbatim so a caller
# can force it); else auto-detect the seat — steward via the durable FLEET_SEAT env
# (exported by steward-session.sh, survives a Bash-tool subshell) or fleet_seat();
# worker vs scout via fleet_seat() + the @scout window marker — else the generic
# word 'fleet'. Pure env + one cheap tmux read; only the WORD carries identity.
resolve_role() {
  [ -n "${from:-}" ] && { printf '%s' "$from"; return; }
  [ "${FLEET_SEAT:-}" = steward ] && { printf 'steward'; return; }
  local seat scout
  seat=$(fleet_seat 2>/dev/null)
  case "$seat" in
    steward) printf 'steward'; return ;;
    worker)
      scout=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@scout}' 2>/dev/null)
      case "$scout" in ''|0) printf 'worker' ;; *) printf 'scout' ;; esac
      return ;;
  esac
  printf 'fleet'
}

num='' body='' repo='' relay=0 have_body=0 from='' no_footer=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --note)      relay=0 ;;
    --to-worker) relay=1 ;;
    --body)      shift; body="${1:-}"; have_body=1 ;;
    --repo)      shift; repo="${1:-}" ;;
    --from)      shift; from="${1:-}" ;;
    --no-footer) no_footer=1 ;;
    -h|--help)   sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# --- per-role sender footer (issue #224) -------------------------------------
# Assemble the footer TAIL once, then append it under one blank line so the block
# reads: <body> · <blank> · <visible signature> · <fleet:from marker> · [no-relay].
# Order matters: the no-relay loop-safety marker (bin/fleet-issue-bridge.sh greps
# it as a verbatim substring) must stay LAST for a --note/default comment.
role=$(resolve_role)
# Context = the SENDER's own binding: a worker/scout window carries @issue → '#<n>'
# + marker issue=<n>; otherwise (steward hub, watcher/dash daemon) fall to the fleet
# slug/session name — repo-derived, so NO private identifier leaks (charter scrub).
f_issue=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}' 2>/dev/null)
f_issue="${f_issue//[^0-9]/}"
f_session=$(fleet_current_session 2>/dev/null)
[ -z "$f_session" ] && f_session=$(fleet_slug "$repo" 2>/dev/null)
if [ -n "$f_issue" ]; then f_ctx="#$f_issue"; else f_ctx="$f_session"; fi

# Visible signature — em-dash, no emoji. The generic 'fleet' role would double the
# brand word ('fleet · fleet'), so collapse it to just '— fleet · <ctx>'.
if [ "$role" = fleet ]; then
  vis="— fleet${f_ctx:+ · $f_ctx}"
else
  vis="— fleet · $role${f_ctx:+ · $f_ctx}"
fi
# Invisible machine marker (greppable by tooling; independent of loop-safety).
mk="${FROM_PREFIX}role=$role"
[ -n "$f_session" ] && mk="$mk session=$f_session"
[ -n "$f_issue" ]   && mk="$mk issue=$f_issue"
mk="$mk -->"

tail=''
# Footer is idempotent: skip if the body already carries a fleet:from marker.
if [ "$no_footer" -eq 0 ]; then
  case "$body" in
    *"$FROM_PREFIX"*) : ;;
    *)                tail="$vis$NL$mk" ;;
  esac
fi
# no-relay: only a --note/default record comment gets it; --to-worker stays
# relayable. Idempotent, and appended LAST so it satisfies the bridge's contract.
if [ "$relay" -eq 0 ]; then
  case "$body" in
    *"$MARKER"*) : ;;
    *)           if [ -n "$tail" ]; then tail="$tail$NL$MARKER"; else tail="$MARKER"; fi ;;
  esac
fi
[ -n "$tail" ] && body="$body$NL$NL$tail"

exec gh issue comment "$num" --repo "$repo" --body "$body"
