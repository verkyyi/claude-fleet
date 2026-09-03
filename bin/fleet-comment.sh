#!/bin/bash
# fleet-comment.sh — the ONE sanctioned way for fleet tooling to comment on a
# bound issue when the issue-bridge (bin/fleet-issue-bridge.sh, issue #132) is in
# play. It stamps the loop-suppression marker so nothing the fleet writes to an
# issue loops back into the bound worker as a turn.
#
# The bridge relays every issue comment from a trusted author into the bound
# worker UNLESS the comment carries `<!-- fleet:no-relay -->`. Every fleet actor
# shares the OWNER identity, so author-filtering cannot separate them — the marker
# is the only reliable discriminator. This wrapper puts it on (or deliberately
# off) so no hand-written `gh issue comment` can accidentally feed a worker.
#
# ⚠️ THE ONE MISTAKE THIS TOOL INVITES: the default is RECORD-ONLY. A bare call
# posts a comment the bound worker will NEVER see. If you are writing an
# INSTRUCTION for a worker, you want `--to-worker` (or SendMessage, below) — a
# bare call will look like it worked (URL printed, exit 0) and deliver nothing.
# Since issue #489 the script says which of the two happened on stderr; read it.
#
# Picking a channel for agent → worker traffic:
#   • SendMessage (preferred for instructions) — direct to the worker's session,
#     immediate, returns a delivery receipt, and no bridge gate can silently drop
#     it. Use when you just need the worker to act.
#   • `--to-worker` — use when the instruction ALSO belongs in the issue record
#     (an audit trail the operator/next worker will read). Still subject to the
#     bridge's assoc gate and self-authored suppression.
#   • default/`--note` — the comment is FOR THE RECORD (progress, PR links,
#     findings). Not a delivery mechanism.
#
# Usage:
#   fleet-comment.sh <issue> --body "<text>"            # DEFAULT: record/no-relay
#   fleet-comment.sh <issue> --body-file <path|->       # body from a file / stdin
#   fleet-comment.sh <issue> --note --body "<text>"     # explicit no-relay
#   fleet-comment.sh <issue> --to-worker --body "<text>" # RELAYED into the worker
#   fleet-comment.sh <issue> --from <role> --body "..." # force the footer's role
#   fleet-comment.sh <issue> --no-footer --body "..."   # suppress the footer
#   fleet-comment.sh <issue> --close --body "<text>"    # marked comment, THEN close
#   printf '%s' "$text" | fleet-comment.sh <issue> --note # body on stdin
#
# Modes:
#   --note       fleet-internal comment for the record/humans (worker progress,
#                PR links, operator triage) → stamped no-relay. THE DEFAULT: a
#                bare fleet comment must never accidentally drive a worker.
#   --to-worker  a message MEANT to become the worker's next turn (the operator's
#                handback, an instruction) → left UNMARKED so the bridge relays it
#                once. External/human commenters need no wrapper at all (their
#                comments are unmarked by default = relayed, subject to the gate).
#   --close      close the issue AFTER posting the (marked) comment — the wrapper
#                for a no-PR wrap-up. A bare `gh issue close --comment` posts an
#                UNMARKED comment the bridge relays straight back into the closing
#                worker's own pane (issue #486); this keeps the close comment on
#                the marker rail. Composes with the mode flags (default --note).
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
# Role resolution: explicit --from <role> wins → else auto-detect (operator via the
# FLEET_HUB env the hub pane exports; worker via fleet_seat()) → else the generic
# word 'fleet'. The footer identifies role + fleet ONLY
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

# Which fleet ROLE is posting? Resolved by the shared fleet_from_role (issue #332
# extracted it to fleet-lib.sh so the issue-filer channel stamps the same marker):
# explicit --from wins, else FLEET_HUB / fleet_seat(), else the generic 'fleet'.
resolve_role() { fleet_from_role "${from:-}"; }

num='' body='' repo='' relay=0 have_body=0 from='' no_footer=0 do_close=0 f=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --note)      relay=0 ;;
    --to-worker) relay=1 ;;
    --close)     do_close=1 ;;
    # gh-compatible spellings (issue #528). hooks/bash-guard.py rewrites a raw
    # gh issue-comment onto this wrapper verbatim, and a human reaching for the
    # wrapper types what gh taught them; the old `-*) unknown flag` catch-all
    # turned both into a SECOND failure right after the first one (--body-file
    # alone accounted for 13 of them). Accept gh's short forms and --body-file.
    --body|-b)   shift; body="${1:-}"; have_body=1 ;;
    --body-file|-F)
                 shift; f="${1:-}"
                 if [ "$f" = "-" ]; then body="$(cat)"; else
                   [ -r "$f" ] || { printf 'fleet-comment: cannot read body file %s\n' "$f" >&2; exit 2; }
                   body="$(cat -- "$f")"
                 fi
                 have_body=1 ;;
    --repo|-R)   shift; repo="${1:-}" ;;
    --from)      shift; from="${1:-}" ;;
    --no-footer) no_footer=1 ;;
    -h|--help)   sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
# Context = the SENDER's own binding: a worker window carries @issue → '#<n>'
# + marker issue=<n>; otherwise (the operator hub, a dash daemon) fall to the fleet
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
# Built by the shared fleet_from_marker (issue #332) so a filed issue's body and a
# posted comment carry the byte-identical `<!-- fleet:from … -->` provenance.
mk=$(fleet_from_marker "$role" "$repo")

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

# DELIVERY VERDICT (issue #489) — the two modes post identically-shaped comments
# whose SEMANTICS are opposite (archive vs drive-the-worker), and both used to
# print just the URL and exit 0. An agent that wanted `--to-worker` but called
# bare got a success-looking result and a silently-undelivered instruction (one
# real incident: five consecutive instructions to four workers, all suppressed,
# all reported upstream as "delivered"). So SAY which one happened, and — in the
# one case where the mistake is most likely and most costly (a live worker is
# bound to this issue, yet the comment is record-only) — say it loudly.
# stderr only: stdout stays exactly the `gh` URL so callers parsing it are unaffected.
comment_verdict() {
  if [ "$relay" -eq 1 ]; then
    printf 'fleet-comment: 已发并将转达 #%s 的 worker（bridge 下轮拾取；仍受 assoc 门与自发抑制约束）\n' "$num" >&2
    return 0
  fi
  printf 'fleet-comment: 已发（记录模式 · 不会送达 worker；要驱动 worker 用 --to-worker）\n' >&2
  # Loud warning only when a live worker is actually bound to this issue. Best
  # effort: no tmux / not in a fleet session ⇒ silent (never fail the post).
  local sess=''
  command -v tmux >/dev/null 2>&1 && sess=$(fleet_current_session 2>/dev/null)
  if [ -n "$sess" ]; then
    if tmux -L "$(fleet_socket "$sess")" list-panes -s -t "$sess" -F '#{@issue}' 2>/dev/null \
         | grep -qx "$num"; then
      printf '⚠️  #%s 上有活跃 worker，但本条是记录模式，它不会看到。\n' "$num" >&2
      printf '   要下达指令：--to-worker，或直接用 SendMessage 投给该 worker 会话（即时、有送达回执）。\n' >&2
    fi
  fi
}

# --close: comment first (marked), THEN close — so the wrap-up note exists even if
# the close itself fails, and the bridge never sees an unmarked close comment (#486).
if [ "$do_close" -eq 1 ]; then
  gh issue comment "$num" --repo "$repo" --body "$body" || exit "$?"
  comment_verdict
  exec gh issue close "$num" --repo "$repo"
fi
gh issue comment "$num" --repo "$repo" --body "$body" || exit "$?"
comment_verdict
