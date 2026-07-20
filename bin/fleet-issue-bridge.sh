#!/bin/bash
# fleet-issue-bridge.sh — the issue-as-event-bus RECEIVER (issue #132).
#
# Turns a GitHub issue comment into the bound worker's NEXT TURN, so the issue is
# the single durable/auditable channel for driving a worker — steward→worker,
# external-collaborator→worker — replacing flaky `tmux send-keys` handbacks.
#
# ONE shared instance for the whole machine (like pr-refresh, NOT per-worker). Two
# ingress modes share ONE relay core:
#   • POLL (default, per-tick daemon) — the robust, no-inbound-port path. Each tick
#     lists new issue comments across every live fleet's repo via `gh api` with a
#     `since` watermark (reads are ~free), and relays the qualifying ones. Run from
#     launchd (com.claude-fleet.issue-bridge) / a systemd timer, ~15s cadence. Per
#     repo it runs TWO decoupled channels (issue #198) — a WORKER channel (repo-wide
#     comments minus the steward issue) and a STEWARD channel (the steward control
#     issue's own per-issue stream) — each with its OWN watermark + seen-set, so a
#     busy steward can no longer pin the worker watermark and starve worker relays,
#     and queued steward wakes COALESCE to current state on drain (no stale replay).
#   • --deliver (webhook) — read ONE GitHub `issue_comment` delivery JSON on stdin,
#     validate its HMAC (FLEET_ISSUE_BRIDGE_SECRET), and relay that one comment.
#     Wire it behind `gh webhook forward` / a cloudflared tunnel for sub-second
#     latency. See docs/ISSUE-BRIDGE.md.
#
# RELAY CORE (identical for both ingresses), for each new comment:
#   1. dedup      — skip if this comment id was already handled (redeliveries,
#                   poll/webhook overlap). GitHub redelivers on any non-2xx.
#   2. self/marker — SUPPRESS a fleet-internal comment, by EITHER signal. (a) the
#                   body carries `<!-- fleet:no-relay -->` (the intent flag
#                   bin/fleet-comment.sh --note stamps). (b) it is the bound worker
#                   talking to ITSELF — a `<!-- fleet:from role=worker … issue=<N> -->`
#                   provenance marker whose issue equals THIS comment's issue (the
#                   positive-self-ID backstop, issue #425). Worker+steward share the
#                   OWNER identity, so author-filtering can't separate them — (a) is
#                   the loop guard. (b) is the backstop for a worker comment that
#                   skipped the wrapper (raw `gh issue comment`) and so lacks (a):
#                   without it that comment passes the OWNER gate and is relayed back
#                   into the worker once (dedup only stops the SECOND relay, not the
#                   first). Steward `--to-worker` (role=steward, no issue=) and an
#                   external human (no fleet:from) are NOT matched by (b) — both relay.
#   3. gate       — relay only from a trusted author_association (default floor
#                   OWNER/MEMBER/COLLABORATOR). A comment becomes autonomous tool-use
#                   in a bypass-permissions worker ⇒ treat as RCE; never relay
#                   NONE/CONTRIBUTOR. Configurable via FLEET_ISSUE_BRIDGE_ASSOC_FLOOR.
#   4. target     — resolve the bound worker window by @issue across live fleets on
#                   this repo. Idle-gate on @claude_state: inject only when NOT
#                   `working` (queue a busy worker to a later tick). Also DEFER when
#                   the pane holds an un-submitted, half-typed input line — a human
#                   keystroke does NOT flip @claude_state, so pasting would prepend
#                   onto their text and submit the merged line (issue #191); treat a
#                   non-empty input row like a busy worker and retry next tick. Two-step
#                   paste injection (bracketed paste + a SEPARATE Enter) dodges the
#                   send-keys/bracketed-paste gotcha for multi-line bodies.
#   5. revive     — (opt-in FLEET_ISSUE_BRIDGE_REVIVE=1) if the issue is OPEN but its
#                   worker window is gone, re-spawn it via dash-issue-session.sh; the
#                   fresh worker's /fleet-claim reads the issue, comment and all.
#
# OFF BY DEFAULT — a fleet opts in with FLEET_ISSUE_BRIDGE=1. Un-gated relay on a
# PUBLIC repo is unsafe; the association gate is the headline control.
set -uo pipefail

MARKER='<!-- fleet:no-relay -->'
FROM_PREFIX='<!-- fleet:from '   # provenance marker prefix (issue #224/#332), read
                                 # by the self-authored backstop (issue #425)
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
STATE="${FLEET_ISSUE_BRIDGE_STATE_DIR:-$HOME/.config/claude-fleet/issue-bridge}"
mkdir -p "$STATE" 2>/dev/null || :
LEASE_DIR="${FLEET_DISPATCH_LEASE_DIR:-$HOME/.claude/leases}"

# Trusted author_association floor. GitHub emits one of OWNER > MEMBER >
# COLLABORATOR > CONTRIBUTOR > FIRST_TIME_CONTRIBUTOR > FIRST_TIMER > NONE. We
# relay only the listed set (verbatim match) — default: the three trusted tiers.
ASSOC_FLOOR="${FLEET_ISSUE_BRIDGE_ASSOC_FLOOR:-OWNER MEMBER COLLABORATOR}"
REVIVE="${FLEET_ISSUE_BRIDGE_REVIVE:-0}"
# Steward control issue (issue #146). A comment on a repo's FLEET_STEWARD_ISSUE
# drives that fleet's @steward hub pane instead of a bound worker window — so the
# steward becomes a bridge endpoint like a worker (an async operator↔steward
# channel + an event sink for the fleet watcher). It is a repo-specific NUMBER, so
# unlike ASSOC_FLOOR/REVIVE it must NEVER inherit across fleets: both ingresses
# resolve it per-repo via bridge_steward_issue_for_repo(), which reads each
# per-fleet <session>.conf uniformly — no fleet is "primary" (issue #180).
# STEWARD_ISSUE below is just the CURRENT repo's value (set by poll() per repo /
# deliver() per delivery); empty ⇒ no steward route (worker relay unchanged).
STEWARD_ISSUE=''
# Stuck-working threshold for the steward idle-gate (mirrors tmux-spinner.sh). The
# steward lives in the 'plan' hub, whose #{window_activity} is polluted by the
# co-resident dash pane, so the spinner's demote never fires there — the bridge
# instead judges a 'working' steward stale via @claude_state_ts (see
# bridge_steward_stale, which floors this to 120 for the steward escape — 0 disables
# the spinner's worker-demote, but disabling the steward escape would wedge/starve).
STUCK_SECS="${FLEET_STUCK_WORKING_SECS:-120}"
# Max CONSECUTIVE typing-defers before a relay is delivered anyway (issue #195).
# bridge_input_busy DEFERS a relay while the target's input row holds un-submitted
# text (issue #191) — right for a real mid-type, but UNBOUNDED: if a row ever reads
# non-empty PERSISTENTLY (a future TUI ghost/placeholder after ❯, a stuck/garbled
# render, a capture-pane quirk) the channel would defer FOREVER, silently — for the
# @steward control channel that means missed operator messages AND missed watcher
# wakes with no signal. So bound it, mirroring bridge_steward_stale's "never wedge
# forever" escape: after this many consecutive typing-defers of the SAME comment,
# deliver anyway + WARN. The cap must be GENEROUS (a real human pausing mid-type for
# minutes is respected) yet finite (no infinite wedge). Default 20 ≈ 5 min at the
# 15s poll. A garbled / non-positive value floors to 20 rather than DISABLING the
# bound (an unbounded defer is the exact failure this exists to prevent).
MAX_TYPING_DEFERS="${FLEET_BRIDGE_MAX_TYPING_DEFERS:-20}"
case "$MAX_TYPING_DEFERS" in ''|*[!0-9]*) MAX_TYPING_DEFERS=20 ;; esac
[ "$MAX_TYPING_DEFERS" -gt 0 ] 2>/dev/null || MAX_TYPING_DEFERS=20

now() { date +%s 2>/dev/null || echo 0; }
utcnow() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '1970-01-01T00:00:00Z'; }
log() { printf '%s issue-bridge: %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '--:--:--')" "$*" >&2; }

# --- relay decision primitives (pure; the selftest exercises these) ------------

# 0 if the comment body carries the no-relay marker (⇒ suppress), 1 otherwise.
bridge_marked() { case "$1" in *"$MARKER"*) return 0;; *) return 1;; esac; }

# 0 if the comment is the bound worker talking to ITSELF (issue #425): the body
# carries a `<!-- fleet:from role=worker … issue=<N> … -->` provenance marker whose
# issue equals <route_issue> (the issue this comment is being relayed TO). This is
# the positive-self-ID BACKSTOP for the no-relay marker — a worker's own comment
# posted WITHOUT the loop-safety flag (e.g. a raw `gh issue comment` that bypassed
# bin/fleet-comment.sh) would otherwise pass the OWNER gate and be injected back
# into that worker once (dedup only stops the SECOND relay, never the first). The
# steward's `--to-worker` (role=steward, and its hub pane has no @issue so the
# marker carries no issue=) and an external human (no fleet:from at all) are NOT
# matched, so both still relay. The issue= compare is space-anchored so issue=10
# never matches issue=100. Suppression is the SAFE direction — like the no-relay
# marker, a spoofed fleet:from can only make a comment more suppressed, never
# bypass the assoc gate to get relayed — so this runs before the gate, unguarded.
bridge_self_authored() {
  local body="$1" route_issue="$2" mk
  case "$body" in *"$FROM_PREFIX"*) ;; *) return 1 ;; esac
  mk=" ${body#*"$FROM_PREFIX"}"; mk="${mk%%-->*} "     # isolate the marker fields, space-pad both ends
  case "$mk" in *' role=worker '*) ;; *) return 1 ;; esac
  case "$mk" in *" issue=$route_issue "*) return 0 ;; *) return 1 ;; esac
}

# 0 if <assoc> is in the trusted floor, 1 otherwise. Word-boundary match against
# the space-separated ASSOC_FLOOR so "OWNER" never matches inside a longer token.
bridge_assoc_ok() {
  local a="$1" t
  for t in $ASSOC_FLOOR; do [ "$a" = "$t" ] && return 0; done
  return 1
}

# One directory per fleet (issue #181): the dedup set + watermark move to
# fleets/<sess>/bridge/{seen,since}. The bridge is repo-native (keyed by slug), so
# bridge_sess_for_slug resolves the slug→session from the configured confs; a slug
# with no configured fleet (a bare FLEET_REPO) keeps the legacy flat
# issue-bridge/bridge_<slug>.* file. bridge_state_file DUAL-READS: a legacy file
# already in place is used until the migrator moves it, so the dedup/watermark set
# is never split across the land→migrate window. Single-entry memo keeps the
# conf scan off the per-comment hot path (poll/deliver handle one slug at a time).
_BR_SLUG='' _BR_SESS=''
bridge_sess_for_slug() {
  local want="$1" sess conf rp found=''
  [ -n "$want" ] || return 0
  [ "$want" = "$_BR_SLUG" ] && { printf '%s' "$_BR_SESS"; return; }
  while IFS=$'\t' read -r sess conf; do
    rp=$( . "$conf" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    [ "$(fleet_slug "$(fleet_norm_repo "$rp")")" = "$want" ] && { found="$sess"; break; }
  done < <(fleet_each_conf)
  _BR_SLUG="$want"; _BR_SESS="$found"
  printf '%s' "$found"
}
# $1=slug $2=kind (seen|since|steward.seen|steward.since|typing.<cid>) → the state
# file path (new per-fleet layout, else legacy). The CHANNEL split (issue #198)
# rides the $2 kind: the steward channel passes steward.seen/steward.since so its
# bookkeeping co-locates with the worker's under the same fleets/<sess>/bridge/ dir.
bridge_state_file() {
  local slug="$1" kind="$2" sess new old="$STATE/bridge_$1.$2"
  sess=$(bridge_sess_for_slug "$slug")
  if [ -n "$sess" ]; then
    new="$FLEET_CONF_DIR/fleets/$sess/bridge/$kind"
    [ -f "$new" ] && { printf '%s' "$new"; return; }
    [ -f "$old" ] && { printf '%s' "$old"; return; }   # dual-read a legacy file in place
    mkdir -p "$FLEET_CONF_DIR/fleets/$sess/bridge" 2>/dev/null
    printf '%s' "$new"; return
  fi
  mkdir -p "$STATE" 2>/dev/null
  printf '%s' "$old"
}

# dedup set, one file per fleet (capped so it can't grow without bound). Split by
# CHANNEL (issue #198): the worker relay and the steward control-issue each get
# their OWN seen-set (and watermark), so a busy steward can't pin the worker's
# progress. $3 = channel: "" (worker, default) or "steward" → routed through
# bridge_state_file as the seen/steward.seen kind, so both land in the #181 layout.
bridge_seen_file() {
  case "${2:-}" in
    ?*) bridge_state_file "$1" "$2.seen" ;;
    *)  bridge_state_file "$1" seen ;;
  esac
}
bridge_seen_has()  { grep -qxF "$2" "$(bridge_seen_file "$1" "${3:-}")" 2>/dev/null; }
bridge_seen_add() {
  local f; f=$(bridge_seen_file "$1" "${3:-}")
  printf '%s\n' "$2" >> "$f" 2>/dev/null || return 0
  # trim to the most recent 2000 ids (ids only grow, so tail keeps the newest)
  if [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -n 2000 "$f" > "$f.$$" 2>/dev/null && mv "$f.$$" "$f" 2>/dev/null || rm -f "$f.$$" 2>/dev/null
  fi
}

# Per-comment consecutive-typing-defer counter (issue #195) — one small file per
# (repo slug, comment id), holding an integer tick count. Routed through
# bridge_state_file (issue #181) so a counter co-locates with the fleet's seen/since
# under fleets/<sess>/bridge/typing.<cid> (dual-reading a legacy flat file), never
# split off into the flat $STATE dir. Keyed EXACTLY like the dedup seen-set (per slug
# + per cid) so one wedged pane's counter can NEVER force-deliver another comment's
# queue. The counter is reset when the comment is marked SEEN (bridge_seen_add's
# terminal callers — relayed | suppressed | dropped | dup), which reaps it on EVERY
# terminal path (incl. the window-gone drop), not only on a clean delivery; a
# still-queued (rc 3) comment is not seen, so its counter persists across ticks.
bridge_typing_file() { bridge_state_file "$1" "typing.$2"; }
# Increment + persist the counter, echo the new value. FAIL SAFE: if the count
# can't be persisted (unwritable/full state dir), an UN-trackable defer is exactly
# the silent wedge #195 exists to prevent — so echo MAX_TYPING_DEFERS+1, forcing the
# deliver-anyway path rather than a forever-1 that never trips the bound.
bridge_typing_bump() {
  local f n; f=$(bridge_typing_file "$1" "$2")
  n=$(cat "$f" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  printf '%s\n' "$n" > "$f" 2>/dev/null || { printf '%s' "$((MAX_TYPING_DEFERS + 1))"; return 0; }
  printf '%s' "$n"
}
bridge_typing_reset() { rm -f "$(bridge_typing_file "$1" "$2")" 2>/dev/null || :; }

# The bounded half-typed-input gate (issue #191 + #195), shared by the worker and
# @steward relay paths so their wedge behavior can't drift. rc 3 = KEEP DEFERRING
# (input row holds un-submitted text and we're still within the defer budget); rc 0 =
# DELIVER (row is clear, OR the budget is spent → deliver anyway + a WARNING log, the
# safety valve). Args: pane slug cid. NOTE a `working` interlude deliberately does
# NOT reset the counter (the caller gates that BEFORE calling this) — resetting on
# working would let a pane flapping working/idle with a stuck input row dodge the
# bound forever, the exact wedge #195 forbids; the residual bias is toward delivering
# a tick early, which is the fail-safe direction.
bridge_typing_gate() {  # $1=sock $2=pane $3=slug $4=cid  (sock: per-fleet socket, issue #159)
  bridge_input_busy "$1" "$2" || return 0               # input clear → deliver
  local n; n=$(bridge_typing_bump "$3" "$4")
  [ "$n" -le "$MAX_TYPING_DEFERS" ] && return 3         # within budget → keep deferring
  log "input-check: $2 input row non-empty for $n ticks — delivering to avoid a wedge"
  return 0                                              # budget spent → deliver anyway
}

# base64 decode, portable across GNU (-d) and BSD (-D). One helper so the poll and
# --deliver paths can't drift.
bridge_b64d() { printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }

# Per-repo single-writer lease — the SAME lock for the poll tick AND a concurrent
# --deliver, so the two ingresses can never interleave a bridge_seen_has→inject→
# bridge_seen_add and double-relay one comment. mkdir is the atomic lock; a
# SIGKILL'd holder can't run its cleanup, so steal a lease dir older than 120s (a
# normal handler is sub-second). rc 0 = acquired.
bridge_lease_path() { printf '%s/issue-bridge-%s.lock' "$LEASE_DIR" "$1"; }
bridge_lease_acquire() { # $1 = lease path
  local lease="$1" age
  mkdir -p "$LEASE_DIR" 2>/dev/null
  mkdir "$lease" 2>/dev/null && return 0
  # Unknown age (both stat variants failed) → treat as stale (echo 0) and steal,
  # rather than 0-age-never-steal which would deadlock the repo on a lost cleanup.
  age=$(( $(now) - $(stat -f %m "$lease" 2>/dev/null || stat -c %Y "$lease" 2>/dev/null || echo 0) ))
  if [ "$age" -ge 120 ]; then
    rm -rf "$lease" 2>/dev/null
    mkdir "$lease" 2>/dev/null && { log "stole stale lease $(basename "$lease") (age ${age}s)"; return 0; }
  fi
  return 1
}

# Resolve the live worker window bound to <issue> on <repo>. Prints
# "session<TAB>window_id<TAB>@claude_state" for the first match, empty if none.
# A window matches when @issue == the number AND its session resolves to <repo>
# (cached sessmap slug), so a same-numbered issue in another fleet never collides.
bridge_find_window() {
  local issue="$1" repo="$2" want_slug sess win st bissue slug
  want_slug=$(fleet_slug "$(fleet_norm_repo "$repo")")
  while IFS=$'\t' read -r sess win st bissue; do
    [ "$bissue" = "$issue" ] || continue
    slug=$(fleet_slug_cached "$sess")
    # Cold cache (no sessmap entry yet) → don't blindly trust the @issue-number
    # match: a DIFFERENT fleet may have its own same-numbered issue open, and
    # injecting there would drive the wrong worker. Resolve the session's repo live
    # (a git fork, but only on the cold-cache path) and require it to match.
    [ -z "$slug" ] && slug=$(fleet_slug "$(fleet_resolve_repo_for_session "$sess")")
    if [ "$slug" = "$want_slug" ]; then
      printf '%s\t%s\t%s' "$sess" "$win" "$st"; return 0
    fi
  done < <(fleet_list_windows_all '#{session_name}'$'\t''#{window_id}'$'\t''#{@claude_state}'$'\t''#{@issue}')
  return 0
}

# Resolve the live steward hub pane for <repo-slug> (issue #146). Prints
# "session<TAB>pane_id<TAB>@claude_state<TAB>@claude_state_ts" for the first fleet
# whose repo matches, empty if none. The steward lives in the 'plan' hub (no
# @issue), so it can't be found by @issue like a worker — instead we scan every
# pane once (mirroring bridge_find_window's single list-windows), keep the
# @steward=1 pane, and match its session to <repo> by the SAME slug logic
# (cached sessmap, cold-cache live fallback so a same-numbered control issue in
# another fleet never collides). @claude_state / @claude_state_ts are WINDOW
# options but resolve at pane scope, and the steward is the only Claude session in
# the plan window — so they drive the idle-gate (state) and its staleness escape
# (ts), all from one tmux fork (no separate fleet_steward_pane + display-message).
bridge_find_steward() {
  local want_slug="$1" sess pane st ts slug   # caller passes the ALREADY-computed slug
  # `read` with a whitespace IFS (tab is one) collapses runs and strips leading /
  # trailing empties, so we must NOT rely on it to test a possibly-empty field. Do
  # the @steward filter in awk with an EXPLICIT FS=tab (which keeps every empty
  # field, so $1 is exactly @steward — a non-steward pane, or even a session named
  # "1", can never shift into a false marker match). awk emits the kept panes as
  # session<TAB>pane<TAB>state<TAB>ts; session/pane are always non-empty and the
  # possibly-empty state/ts trail, so the read below is safe.
  while IFS=$'\t' read -r sess pane st ts; do
    [ -n "$sess" ] || continue
    slug=$(fleet_slug_cached "$sess")
    [ -z "$slug" ] && slug=$(fleet_slug "$(fleet_resolve_repo_for_session "$sess")")
    if [ "$slug" = "$want_slug" ]; then
      printf '%s\t%s\t%s\t%s' "$sess" "$pane" "$st" "$ts"; return 0
    fi
  done < <(
    # Each fleet is its own tmux server now (issue #159): fan the @steward-pane
    # scan out across every live fleet socket, then filter as before.
    for _sock in $(fleet_sockets); do
      tmux -L "$_sock" list-panes -a -F '#{@steward}'$'\t''#{session_name}'$'\t''#{pane_id}'$'\t''#{@claude_state}'$'\t''#{@claude_state_ts}' 2>/dev/null
    done | awk -F'\t' '$1=="1"{print $2"\t"$3"\t"$4"\t"$5}')
  return 0
}

# 0 if a 'working' steward state stamped at <ts> is STALE (a missed Stop hook), so
# the idle-gate must NOT wedge on it. A live steward turn re-stamps @claude_state_ts
# on every tool call (set-claude-state.sh), so a stamp older than STUCK_SECS means
# the turn ended without a Stop — the plan window's polluted #{window_activity}
# keeps the spinner from demoting it, so the bridge self-heals here instead. This is
# also what BOUNDS the busy-queue: without it a stuck 'working' would return 3 every
# tick and pin the watermark like the hub-down case. 1 if fresh, unstamped/garbled,
# or STUCK_SECS=0 (⇒ treat as genuinely busy, queue it).
# CAVEAT: @claude_state_ts is coarse (only re-stamped per tool call, not mid-call),
# so a steward inside ONE tool call longer than STUCK_SECS (e.g. a long-running
# command) reads as stale and gets the comment delivered mid-call. Claude Code
# QUEUES injected input during a turn (it doesn't interrupt the tool), so the wake is
# processed when the long call finishes — degraded latency, not corruption — and the
# alternative (no escape) is a permanently wedged channel, which is worse.
bridge_steward_stale() {
  local ts="$1" age secs="${STUCK_SECS:-120}" nowv
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  # STUCK_SECS=0 means "spinner: never demote a stuck worker" — but for the STEWARD
  # escape, never-escape = a wedged, watermark-pinning, worker-starving channel. So
  # a non-positive / garbled value floors to 120 here (the escape always applies)
  # rather than disabling it.
  case "$secs" in ''|*[!0-9]*) secs=120 ;; esac
  [ "$secs" -gt 0 ] || secs=120
  nowv=$(now)
  # If the clock is unreadable (now() fell back to 0) or age comes out negative, we
  # can't trust the freshness read — bias to STALE (escape/relay) rather than risk
  # wedging the channel + pinning the watermark on a bad clock.
  [ "$nowv" -gt 0 ] 2>/dev/null || return 0
  age=$(( nowv - ts ))
  [ "$age" -lt 0 ] && return 0
  [ "$age" -ge "$secs" ]
}

# THE steward-issue resolver: map a repo → its FLEET_STEWARD_ISSUE, or empty. The
# SINGLE source both ingresses use, so poll() and --deliver can never diverge on
# which fleet's steward issue wins — and a repo-specific number NEVER leaks across
# fleets. All fleets are equal (issue #180 — no "primary" short-circuit): it maps
# uniformly by iterating the per-fleet <session>.conf files. Each conf is sourced
# with BOTH FLEET_STEWARD_ISSUE and FLEET_REPO UNSET FIRST, so a steward issue
# counts only when THAT conf sets its own repo AND issue (never the global values
# the subshell would otherwise inherit — a bare `${FLEET_STEWARD_ISSUE:-}`/
# `${FLEET_REPO:-}` doesn't prevent that). Every real <session>.conf sets FLEET_REPO
# (fleet-up.sh writes it), so this is safe; a hand-written conf that sets only
# FLEET_STEWARD_ISSUE is correctly ignored rather than mis-attributed to any repo.
bridge_steward_issue_for_repo() {
  local repo="$1" want_slug cf line rp si _s
  want_slug=$(fleet_slug "$(fleet_norm_repo "$repo")")
  while IFS=$'\t' read -r _s cf; do
    [ -f "$cf" ] || continue
    line=$( unset FLEET_STEWARD_ISSUE FLEET_REPO   # count only if THIS conf sets both
            . "$cf" >/dev/null 2>&1
            [ "${FLEET_ISSUE_BRIDGE:-0}" = 1 ] && printf '%s\t%s' \
              "${FLEET_REPO:-}" "${FLEET_STEWARD_ISSUE:-}" )
    [ -z "$line" ] && continue
    IFS=$'\t' read -r rp si <<EOF
$line
EOF
    [ -n "$si" ] && [ "$(fleet_slug "$(fleet_norm_repo "$rp")")" = "$want_slug" ] \
      && { printf '%s' "$si"; return 0; }
  done < <(fleet_each_conf)
  return 0
}

# 0 if the pane's Claude TUI input line holds UN-SUBMITTED text a human typed — so
# a relay must DEFER rather than bracketed-paste-prepend onto their partial and
# submit the merged line (issue #191). 1 if the input line is empty (safe to
# deliver) OR the prompt row / cursor can't be resolved (capture-pane failed / no
# `❯` row found — a parse miss ⇒ fall back to deliver; NEVER wedge the queue on a
# bad read). A human keystroke doesn't flip @claude_state, so this input-content
# check is the ONLY thing standing between an idle-but-being-typed-into pane and an
# accidental prepend+submit. It stays a PURE busy/clear read; the defer it triggers
# is BOUNDED at the callsite (issue #195, bridge_typing_gate) so a persistently
# busy read — one the cursor/faint heuristics below don't resolve to a ghost —
# degrades to delivery, not a silent dead channel.
#
# The Claude TUI renders the live input on a `❯ `-anchored row. PAST user turns
# render the same glyph higher in the scrollback and the status footer below it
# carries none, so the LAST `❯` line is the input row.
#
# But Claude also draws a DIM "ghost" autosuggestion in that same row when the
# input is EMPTY, and plain `capture-pane -p` returns the ghost as ordinary text —
# so the naive "any text after ❯ ⇒ busy" test read a ghost as a half-typed line and
# deferred FOREVER (the ghost can't be cleared — there's nothing in the buffer to
# delete), wedging the relay (issue #199). Text is "real input" only if it is to
# the LEFT of the cursor OR not faint-styled; two signals encode that, and busy ⟺
# EITHER fires (a faint ghost is rejected by BOTH):
#   • PRIMARY (cursor, style-agnostic): the slice of the input row from input-start
#     up to cursor_x, stripped, is non-empty. A ghost never enters the buffer, so
#     the cursor stays parked at input-start ⇒ empty slice ⇒ deliver.
#   • SECONDARY (faint-strip): remove dim (SGR 2) runs from the input row, then
#     empty-check the remainder. Directly semantic (Claude marks ghosts faint) and
#     catches the rare "typed then Home-to-col-0" case the cursor slice alone misses
#     (cursor at input-start yet real text sits to its right).
# A defensive trailing `│` strip covers a bordered-input rendering.
bridge_input_busy() {
  local sock="$1" win="$2" cap lineno irow erow plain esc cx cy prefix istart n after left eafter
  # -e keeps the SGR spans so the faint (ghost) runs stay distinguishable. -L "$sock":
  # the pane lives on its fleet's OWN server (issue #159), so read the RIGHT socket or
  # #191/#199's typing-gate silently no-ops (wrong-socket capture fails → safe fallback).
  cap=$(tmux -L "$sock" capture-pane -t "$win" -e -p 2>/dev/null) \
    || { log "input-check: capture-pane failed for $win — proceeding (fallback)"; return 1; }
  # The live input row is the LAST `❯` row; its 1-based line no. maps to the
  # 0-based pane row (== cursor_y when the cursor sits on it).
  lineno=$(printf '%s\n' "$cap" | grep -n '❯' | tail -n1 | cut -d: -f1)
  [ -n "$lineno" ] || { log "input-check: no prompt row in $win — proceeding (fallback)"; return 1; }
  irow=$((lineno - 1))
  erow=$(printf '%s\n' "$cap" | sed -n "${lineno}p")
  esc=$(printf '\033')
  plain=$(printf '%s' "$erow" | sed -E "s/${esc}\[[0-9;]*m//g")   # all SGR stripped

  # PRIMARY (fast, style-agnostic) — typed text to the LEFT of the cursor is real
  # input, period. `❯` is 1 display column, so input-start = its column + 2 (`❯ `);
  # the slice [input-start, cursor_x) is the typed buffer (the ghost always renders
  # to the RIGHT of the cursor). Non-empty ⇒ busy. This is only ever allowed to
  # ASSERT busy — an empty slice falls through to the faint check below, so a ghost
  # (cursor parked at input-start) is decided by SECONDARY, and a "typed then
  # Home-to-col-0" edit (cursor at input-start, real text to its right) is still
  # caught there. (The prompt prefix is single-width — ASCII/box-drawing — so a
  # char count equals its display-column count; a wide-char prefix would desync it,
  # but SECONDARY still backstops.)
  read -r cx cy <<EOF
$(tmux -L "$sock" display-message -p -t "$win" '#{cursor_x} #{cursor_y}' 2>/dev/null)
EOF
  if [ -n "$cx" ] && [ -n "$cy" ] && [ "$cx" -ge 0 ] 2>/dev/null && [ "$cy" = "$irow" ]; then
    prefix=${plain%%❯*}                            # text left of the glyph (borders/pad)
    istart=$(( ${#prefix} + 2 ))                   # column where typed input begins
    n=$(( cx - istart ))                           # typed columns to the left of the cursor
    if [ "$n" -gt 0 ]; then
      after=${plain#*❯}; after=${after# }          # input region (drop the ❯'s trailing space)
      left=$(printf '%s' "$after" | cut -c1-"$n")
      left=$(printf '%s' "$left" | sed -e 's/│[[:space:]]*$//' -e 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -n "$left" ] && return 0                   # real typed text before the cursor ⇒ busy
    fi
  fi

  # SECONDARY (robust, faint-aware) — is there any NON-DIM real text after `❯`?
  # Claude marks the ghost autosuggestion faint (SGR 2), so a genuine mid-type has
  # non-dim glyphs while a ghost has only dim ones. A regex strip of dim SPANS is
  # brittle (combined openers `\e[2;90m`, dim-then-color, varied `\e[0m|\e[22m|\e[m`
  # terminators all evade it — and a missed strip re-wedges the relay, issue #199),
  # so we PARSE the SGR state instead: walk the row after `❯`, track whether dim is
  # active (param 2 on; 0/22/bare-reset off), and flag busy on the first non-dim
  # printable ASCII char. Non-ASCII bytes (the `❯`/`│`/box glyphs, or the dim ghost)
  # are ignored, so borders never false-trip it. This is also the sole signal when
  # the cursor is unresolvable (old tmux / copy-mode / a wrapped continuation row).
  eafter=${erow#*❯}                                # after the glyph, SGR spans intact
  # LC_ALL=C ⇒ byte-oriented scan (no multibyte decode of the ghost / `│` / box
  # glyphs, so no towc warning and `[!-~]` is exactly printable ASCII).
  printf '%s' "$eafter" | LC_ALL=C awk -v ESC="$esc" '
    { s=$0; n=length(s); i=1; dim=0; busy=0
      while (i<=n) {
        c=substr(s,i,1)
        if (c==ESC && substr(s,i+1,1)=="[") {       # an SGR (…m) sequence — update dim
          j=i+2; p=""
          while (j<=n && substr(s,j,1)!="m") { p=p substr(s,j,1); j++ }
          if (p=="") dim=0                          # bare \e[m == reset
          else { k=split(p,a,";"); t=1
                 while (t<=k) {                      # walk params, honoring 38/48/58 extended color
                   v=a[t]
                   if (v=="38"||v=="48"||v=="58") {  # skip its VALUE tokens so a color index/RGB
                     if (a[t+1]=="5") t+=3           # `38;5;N`  — 1 index token
                     else if (a[t+1]=="2") t+=5      # `38;2;R;G;B` — 3 rgb tokens
                     else t+=1                       # (`2` here is RGB selector, not dim)
                     continue }
                   if (v=="0"||v=="22") dim=0; else if (v=="2") dim=1
                   t++ } }
          i=j+1; continue
        }
        if (dim==0 && c ~ /[!-~]/) { busy=1; break } # non-dim printable ASCII ⇒ real input
        i++
      }
      exit (busy?0:1) }'                            # rc 0 ⇒ mid-type ⇒ defer; rc 1 ⇒ empty/ghost ⇒ deliver
}

# Two-step injection: bracketed paste of the (possibly multi-line) text, then a
# SEPARATE Enter to submit. A single `send-keys -l` treats embedded newlines as
# Enters (submitting the first line early) — the bracketed-paste gotcha; pasting
# via a buffer with -p brackets the whole body as ONE paste, and the standalone
# Enter is what actually submits the turn.
# Args: <socket> <window-id> <text>. The worker window lives on its fleet's own
# tmux server (issue #159), so every op names that fleet's -L socket.
bridge_inject() {
  local sock="$1" win="$2" text="$3" buf="fleet-relay-$$"
  tmux -L "$sock" set-buffer -b "$buf" -- "$text" 2>/dev/null || return 1
  tmux -L "$sock" paste-buffer -t "$win" -b "$buf" -d -p 2>/dev/null || { tmux -L "$sock" delete-buffer -b "$buf" 2>/dev/null; return 1; }
  # FLEET_ALLOW_SENDKEYS=1: this IS the sanctioned issue-bridge, exempt from the
  # send-keys rail (issue #437). Prefixed (not exported) so a revive spawn below
  # never inherits the hatch and loses its own shell-guard belt.
  FLEET_ALLOW_SENDKEYS=1 tmux -L "$sock" send-keys -t "$win" Enter 2>/dev/null || return 1
  return 0
}

# Find a live fleet session serving <repo> (for a revive spawn). Prints the
# session name or empty. A fleet session owns a 'plan'/'dash' hub window.
bridge_fleet_for_repo() {
  local repo="$1" want_slug s
  want_slug=$(fleet_slug "$(fleet_norm_repo "$repo")")
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    [ "$(fleet_slug_cached "$s")" = "$want_slug" ] && { printf '%s' "$s"; return 0; }
  done < <(fleet_hub_sessions)
  return 0
}

# THE RELAY CORE. Args: repo slug issue comment_id assoc author body.
# Prints one status token (for the log + the selftest) and returns:
#   0  handled terminally (relayed|revived|suppress:*|gone|dup) → caller marks seen
#   3  queued (target busy) → caller must NOT mark seen; retry next tick
bridge_relay() {
  local repo="$1" slug="$2" issue="$3" cid="$4" assoc="$5" author="$6" body="$7"
  # Which channel's seen-set governs this comment? A comment on the steward control
  # issue is tracked in the steward seen-set, everything else in the worker one
  # (issue #198) — so the caller's mark-seen (below / in deliver()) must match.
  local chan=''
  [ -n "$STEWARD_ISSUE" ] && [ "$issue" = "$STEWARD_ISSUE" ] && chan=steward
  if bridge_seen_has "$slug" "$cid" "$chan"; then echo "dup"; return 0; fi
  if bridge_marked "$body"; then echo "suppress:marker"; return 0; fi
  if bridge_self_authored "$body" "$issue"; then echo "suppress:self"; return 0; fi
  if ! bridge_assoc_ok "$assoc"; then echo "suppress:assoc($assoc)"; return 0; fi

  # Steward control-issue route (issue #146): a comment on THIS repo's
  # FLEET_STEWARD_ISSUE drives the @steward hub pane, not a bound worker window.
  # Same gates already applied above (dedup/marker/assoc) — the steward's own
  # notes carry the no-relay marker (bin/fleet-comment.sh --note) so they never
  # loop back into itself. Idle-gated on the hub window's @claude_state like a
  # worker, but with a STALENESS ESCAPE (a stuck 'working' from a missed Stop is
  # relayed anyway) so a genuinely-idle-but-mislabelled steward can't wedge the
  # channel; a missing pane drops terminally (see the tail of this block).
  if [ -n "$STEWARD_ISSUE" ] && [ "$issue" = "$STEWARD_ISSUE" ]; then
    local shit ssess span sst sts
    shit=$(bridge_find_steward "$slug")
    if [ -n "$shit" ]; then
      IFS=$'\t' read -r ssess span sst sts <<EOF
$shit
EOF
      # Idle-gate like a worker, but escape a STALE 'working' (missed Stop) so the
      # channel can't wedge — the plan window's activity is polluted by the dash
      # pane, so the spinner never demotes it (see bridge_steward_stale). Queuing a
      # genuinely-busy steward (return 3) holds the repo watermark exactly as a busy
      # worker does — a pre-existing property of the single per-repo watermark, not
      # new here. The DEFAULT steward is "quiet until asked" (steward-session.sh), so
      # this is normally a brief turn; a custom always-busy steward could hold it
      # longer, and the stale escape above bounds even that once ts ages out.
      if [ "$sst" = working ] && ! bridge_steward_stale "$sts"; then
        echo "queued-busy(steward#$issue)"; return 3
      fi
      # Same half-typed-input protection as a worker (issue #191), BOUNDED (issue
      # #195): the operator types into the @steward pane too and a keystroke doesn't
      # flip its state, so defer while the input row holds text — but only up to the
      # budget, then deliver anyway so a persistently non-empty read can't wedge this
      # control channel forever. The counter is reaped when the comment is marked seen.
      # ssess == the fleet's socket label (issue #159) — the gate reads the steward
      # pane on its own server.
      if ! bridge_typing_gate "$(fleet_socket "$ssess")" "$span" "$slug" "$cid"; then echo "queued-typing(steward#$issue)"; return 3; fi
      local smsg
      smsg="[steward inbox — issue #$issue — comment from @${author:-someone}]"$'\n\n'"$body"
      # ssess == the fleet's socket label (issue #159): inject into that server.
      if bridge_inject "$(fleet_socket "$ssess")" "$span" "$smsg"; then echo "relayed(steward#${issue}->${ssess})"; return 0; fi
      # Pane resolved but a tmux op failed — transient; retry next tick.
      echo "inject-failed(steward#$issue) — will retry"; return 3
    fi
    # No steward pane for this repo THIS tick — QUEUE (retry), not drop. Pre-#198
    # this dropped terminally because a held SHARED watermark would starve worker
    # relays; now the steward channel is decoupled (its own per-issue watermark +
    # --paginate in poll_steward_channel), so retrying can't starve workers and it
    # survives a transient absence (the hub mid-respawn — a /clear, a restart) that a
    # drop would silently lose. On the poll path the steward watermark simply holds;
    # on --deliver this returns EX_TEMPFAIL so a redelivery / the poll backstop lands
    # it once the hub is up. (A present-but-stuck steward is handled above via the
    # stale escape, so this branch is truly "no pane", not "busy".)
    echo "queued(steward#$issue: no @steward pane yet)"; return 3
  fi

  local hit sess win st
  hit=$(bridge_find_window "$issue" "$repo")
  if [ -n "$hit" ]; then
    sess=$(printf '%s' "$hit" | cut -f1)
    win=$(printf '%s' "$hit" | cut -f2)
    st=$(printf '%s' "$hit" | cut -f3)
    if [ "$st" = working ]; then echo "queued-busy(#$issue)"; return 3; fi
    # A human keystroke doesn't set @claude_state, so an idle worker being typed
    # into is a live prepend-and-submit target — defer while the input row holds an
    # un-submitted line so the partial is preserved (issue #191), BOUNDED by the
    # defer budget (issue #195) so a persistently non-empty read can't wedge the
    # channel forever. The counter is reaped when the comment is marked seen.
    # sess == the fleet's socket label (issue #159) — the gate reads the worker pane
    # on its own server.
    if ! bridge_typing_gate "$(fleet_socket "$sess")" "$win" "$slug" "$cid"; then echo "queued-typing(#$issue)"; return 3; fi
    local msg
    msg="[issue #$issue — comment from @${author:-someone}]"$'\n\n'"$body"
    # sess == the fleet's socket label (issue #159): inject into that server.
    if bridge_inject "$(fleet_socket "$sess")" "$win" "$msg"; then echo "relayed(#${issue}->${sess})"; return 0; fi
    # The window still exists (we just resolved it) but a tmux op failed — a
    # TRANSIENT error. Return the retry code so the comment is NOT marked seen and
    # is re-attempted next tick, rather than silently dropped. (If the window is
    # truly gone, the next tick takes the revive/gone path instead.)
    echo "inject-failed(#$issue) — will retry"; return 3
  fi

  # No live window. Revive (opt-in) if the issue is OPEN and a fleet serves it.
  if [ "$REVIVE" = 1 ]; then
    local state target
    state=$(gh issue view "$issue" --repo "$repo" --json state -q .state 2>/dev/null)
    if [ "$state" = OPEN ]; then
      target=$(bridge_fleet_for_repo "$repo")
      if [ -n "$target" ]; then
        if "$BIN/dash-issue-session.sh" "$issue" "$target" >/dev/null 2>&1; then
          echo "revived(#${issue}->${target})"; return 0
        fi
        echo "revive-failed(#$issue)"; return 0
      fi
      echo "gone(#$issue: no fleet for repo)"; return 0
    fi
    echo "gone(#$issue: not open)"; return 0
  fi
  echo "gone(#$issue: no live worker; revive off)"; return 0
}

# =========================== ingress: --deliver ================================
# Read one webhook delivery JSON on stdin, verify HMAC, relay the single comment.
# The raw signature comes from $FLEET_DELIVERY_SIG (the X-Hub-Signature-256 header
# the forwarder passes through). python3 does the HMAC + JSON extraction in one
# pass over the raw bytes (jq can't HMAC; openssl can't parse JSON) and prints the
# TSV the relay core consumes; a bad signature exits non-zero with NO relay.
deliver() {
  command -v python3 >/dev/null 2>&1 || { log "--deliver needs python3"; exit 2; }
  local secret="${FLEET_ISSUE_BRIDGE_SECRET:-}" sig="${FLEET_DELIVERY_SIG:-}" row PY
  # FAIL CLOSED: the webhook path drives a bypass-permissions worker, so an
  # unsigned/unverifiable delivery must be REFUSED, never relayed. Without a secret
  # the HMAC can't be checked — reject rather than trust an attacker-settable body.
  [ -z "$secret" ] && { log "--deliver: FLEET_ISSUE_BRIDGE_SECRET unset — refusing unsigned webhook delivery"; exit 1; }
  # The parser reads the RAW delivery on stdin — so it must run via `python3 -c`,
  # NOT `python3 - <<HEREDOC` (a heredoc would BE python's stdin, hiding the body).
  PY=$(cat <<'PYEOF'
import sys, os, hmac, hashlib, json, base64
raw = sys.stdin.buffer.read()
secret = os.environ.get("FLEET_SECRET", "")
sig = os.environ.get("FLEET_SIG", "")
if secret:
    want = "sha256=" + hmac.new(secret.encode(), raw, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(want, sig or ""):
        sys.stderr.write("HMAC mismatch\n"); sys.exit(4)
try:
    d = json.loads(raw or b"{}")
except Exception as e:
    sys.stderr.write("bad JSON: %s\n" % e); sys.exit(5)
if d.get("action") not in (None, "created"):   # only new comments drive a turn
    sys.exit(6)
c = d.get("comment") or {}
i = d.get("issue") or {}
cid = c.get("id"); num = i.get("number")
if cid is None or num is None:
    sys.stderr.write("not an issue_comment delivery\n"); sys.exit(7)
b64 = base64.b64encode((c.get("body") or "").encode()).decode()
print("\t".join([str(cid), c.get("author_association") or "NONE",
                 (c.get("user") or {}).get("login") or "", str(num), b64]))
PYEOF
  )
  row=$(FLEET_SECRET="$secret" FLEET_SIG="$sig" python3 -c "$PY") \
    || { log "delivery rejected (HMAC/parse) — not relaying"; exit 1; }

  local repo="${FLEET_REPO:-}" cid assoc author num b64 body slug lease
  IFS=$'\t' read -r cid assoc author num b64 <<EOF
$row
EOF
  [ -z "$repo" ] && { log "--deliver: FLEET_REPO unset — cannot resolve repo"; exit 1; }
  # tmux down = no target resolvable (every window/pane lookup returns empty, so a
  # relay would take a terminal 'gone' drop and lose the delivery). Treat as
  # TRANSIENT: exit EX_TEMPFAIL so the comment is NOT marked seen and a redelivery /
  # the poll backstop re-tries it once tmux is back — mirrors poll()'s tmux guard,
  # which exits without advancing its watermark. (issue #146)
  tmux info >/dev/null 2>&1 || { log "deliver #$num c$cid: tmux not running — retry"; exit 75; }
  body=$(bridge_b64d "$b64")
  slug=$(fleet_slug "$(fleet_norm_repo "$repo")")
  # Steward route (issue #146): resolve the steward issue for THIS delivery's repo
  # via the shared resolver — never the global value blindly (a shared webhook
  # serves many repos, and the primary's issue must not leak onto another repo).
  STEWARD_ISSUE=$(bridge_steward_issue_for_repo "$repo")
  # Take the per-repo lease so this delivery can't interleave with a poll tick
  # (or another delivery) and double-relay the same comment. Held for the whole
  # relay+seen; released on exit. A held lease ⇒ retry (EX_TEMPFAIL).
  lease=$(bridge_lease_path "$slug")
  bridge_lease_acquire "$lease" || { log "deliver #$num c$cid: bridge busy (lease held) — retry"; exit 75; }
  trap 'rm -rf "$lease" 2>/dev/null' EXIT
  local out
  out=$(bridge_relay "$repo" "$slug" "$num" "$cid" "$assoc" "$author" "$body"); local rc=$?
  log "deliver #$num c$cid: $out"
  if [ "$rc" -eq 3 ]; then
    # Worker busy at delivery time. A webhook is one-shot, so DON'T mark it seen —
    # exit non-zero (EX_TEMPFAIL) so a redelivery-capable ingress re-sends it, and
    # the poll daemon (if running) picks it up as the backstop.
    exit 75
  fi
  # Mark seen in the SAME channel bridge_relay's dup-check reads (issue #198): a
  # steward-control-issue delivery goes in the steward seen-set, everything else in
  # the worker one — so a webhook delivery and the poll steward channel agree.
  local chan=''
  [ -n "$STEWARD_ISSUE" ] && [ "$num" = "$STEWARD_ISSUE" ] && chan=steward
  bridge_seen_add "$slug" "$cid" "$chan"   # terminal (relayed|revived|suppressed|dup)
  bridge_typing_reset "$slug" "$cid"       # reap any typing counter on the terminal path (issue #195)
  exit 0
}

# =========================== ingress: poll (default) ===========================
# Per repo, TWO independent channels (issue #198), each with its OWN watermark +
# seen-set so one can't head-of-line-block the other:
#   • WORKER  — the repo-wide comment stream MINUS the steward control issue.
#   • STEWARD — the steward control issue's OWN per-issue stream, coalesced on drain.
# poll_repo takes the single per-repo lease once and runs both under it.
poll_repo() {
  local repo="$1" slug lease
  slug=$(fleet_slug "$(fleet_norm_repo "$repo")")
  # Single-writer per repo — the SAME lock a concurrent --deliver takes, so the two
  # ingresses can't double-relay a comment (see bridge_lease_acquire). Held across
  # BOTH channels for this repo.
  lease=$(bridge_lease_path "$slug")
  bridge_lease_acquire "$lease" || { log "$slug: another bridge run holds the lease — skip"; return 0; }
  # shellcheck disable=SC2064  # expand $lease now so the trap removes THIS lease
  trap "rm -rf '$lease' 2>/dev/null" RETURN

  # One-time watermark migration (issue #198): before the split there was ONE shared
  # watermark. If the steward channel has none yet but the (formerly shared) worker
  # watermark exists, INHERIT its position — otherwise the steward channel would seed
  # to NOW and skip any steward wake that was queued (steward busy) under the old
  # shared mark at the daemon upgrade. Must run BEFORE poll_worker_channel, which
  # advances the worker watermark past those same comments this very tick.
  if [ -n "$STEWARD_ISSUE" ]; then
    local wsince ssince
    wsince=$(bridge_state_file "$slug" since)          # routed through #181's layout
    ssince=$(bridge_state_file "$slug" steward.since)
    [ ! -f "$ssince" ] && [ -f "$wsince" ] && cp "$wsince" "$ssince" 2>/dev/null
  fi

  poll_worker_channel "$repo" "$slug"
  [ -n "$STEWARD_ISSUE" ] && poll_steward_channel "$repo" "$slug" "$STEWARD_ISSUE"
  return 0
}

# WORKER channel: repo-wide comments EXCEPT the steward control issue, which has its
# own channel (below). Own watermark bridge_<slug>.since + worker seen-set. Skipping
# steward-issue comments here is THE decoupling (issue #198): a busy steward returns
# rc=3 only in ITS channel, so it can never set `pending` here and pin the worker
# watermark — which, with the non-paginated per_page=100 fetch, would otherwise
# silently starve workers once >100 comments accrue past the pinned mark.
poll_worker_channel() {
  local repo="$1" slug="$2" since rows sincef
  sincef=$(bridge_state_file "$slug" since)
  since=$(cat "$sincef" 2>/dev/null)
  # First run: seed to NOW so enabling the bridge never floods with history.
  [ -z "$since" ] && { utcnow > "$sincef"; log "$slug: first run — worker watermark seeded, no backfill"; return 0; }

  # shellcheck disable=SC2016  # $-vars below are jq bindings, not shell
  rows=$(gh api -H "Accept: application/vnd.github+json" \
    "repos/$repo/issues/comments?since=$since&per_page=100&sort=updated&direction=asc" \
    --jq '.[] | [ (.id|tostring), .author_association, (.user.login // ""),
                  (.issue_url|split("/")|last), .updated_at, (.body|@base64) ] | @tsv' \
    2>/dev/null) || { log "$slug: gh api failed — skip this tick"; return 0; }

  local cid assoc author num updated b64 body out rc
  local pending='' max_ts='' n=0
  while IFS=$'\t' read -r cid assoc author num updated b64; do
    [ -z "$cid" ] && continue
    max_ts="$updated"; n=$((n + 1))
    # Steward control-issue comments belong to the steward channel — skip them here
    # so a busy steward never pins the WORKER watermark (issue #198). They still let
    # max_ts advance (harmless: the steward channel tracks them via its own mark).
    [ -n "$STEWARD_ISSUE" ] && [ "$num" = "$STEWARD_ISSUE" ] && continue
    bridge_seen_has "$slug" "$cid" && continue
    body=$(bridge_b64d "$b64")
    out=$(bridge_relay "$repo" "$slug" "$num" "$cid" "$assoc" "$author" "$body"); rc=$?
    [ "$out" = dup ] || log "$slug #$num c$cid: $out"
    if [ "$rc" -eq 3 ]; then
      pending=1                                          # a comment awaits a busy worker
    else
      bridge_seen_add "$slug" "$cid"
      bridge_typing_reset "$slug" "$cid"                 # reap any typing counter on the terminal path
    fi
  done <<EOF
$rows
EOF

  # Advance the watermark ONLY when nothing is still queued. GitHub's ?since= is
  # EXCLUSIVE ("updated after"), so we must NOT set the watermark to a queued
  # comment's own timestamp — it would never be re-listed. Instead, when anything
  # is pending we leave the watermark untouched (at its pre-tick value): next tick
  # re-lists everything since then, the already-relayed ones are skipped by the
  # seen-set, and the queued one is retried. When all clear, jump past the newest.
  if [ -z "$pending" ] && [ -n "$max_ts" ]; then
    printf '%s\n' "$max_ts" > "$sincef"
  fi
  [ "$n" -gt 0 ] && log "$slug: examined $n comment(s)$([ -n "$pending" ] && printf ' (some queued — watermark held)')"
  return 0
}

# STEWARD channel (issue #198): the steward control issue's comments on their OWN
# per-issue endpoint + OWN watermark/seen-set, decoupled from the worker channel.
# A busy steward pins ONLY this watermark; a worker flood on the repo can never bury
# steward wakes (separate per-issue fetch — no repo-wide 100-comment truncation).
#
# COALESCE-ON-DRAIN: when a queue of steward wakes finally drains to an IDLE steward,
# superseded/duplicate wakes are collapsed to ONE line per subject (newest wins), so
# the steward wakes to CURRENT state, not a temporal replay of "PR green ×3". The
# subject of each watcher-wake line is read from the trailing `<!-- fleet:wake … -->`
# marker (fleet-watch stamps subjects in the same order as the `- ` lines); a comment
# that isn't a parseable watcher wake (an operator note) is kept whole under a unique
# subject so it is NEVER dropped.
poll_steward_channel() {
  local repo="$1" slug="$2" sissue="$3" since rows sincef
  sincef=$(bridge_state_file "$slug" steward.since)
  since=$(cat "$sincef" 2>/dev/null)
  [ -z "$since" ] && { utcnow > "$sincef"; log "$slug: first run — steward watermark seeded, no backfill"; return 0; }

  # Per-ISSUE list endpoint (naturally scoped + immune to the repo-wide page cap).
  # It has no sort/direction params — default order is created-asc; we compute max_ts
  # as the lexicographic MAX of updated_at (ISO-8601 sorts lexically) rather than
  # trusting last-row order. `--paginate` follows Link headers so a long HOLD (a
  # down/misconfigured hub) can't leave newer wakes stranded past a 100-comment page;
  # the `since` watermark keeps a normally-draining channel to a single page.
  # shellcheck disable=SC2016  # $-vars below are jq bindings, not shell
  rows=$(gh api --paginate -H "Accept: application/vnd.github+json" \
    "repos/$repo/issues/$sissue/comments?since=$since&per_page=100" \
    --jq '.[] | [ (.id|tostring), .author_association, (.user.login // ""),
                  (.issue_url|split("/")|last), .updated_at, (.body|@base64) ] | @tsv' \
    2>/dev/null) || { log "$slug: steward gh api failed — skip this tick"; return 0; }

  # First pass: suppress (marker/assoc → mark seen terminally) and collect trusted
  # candidates. Each candidate expands into one or more coalescing entries; parallel
  # arrays E_SUBJ/E_TEXT hold (subject, display-line) in arrival order.
  local cid assoc author num updated b64 body
  local max_ts='' n=0
  local -a E_SUBJ=() E_TEXT=() CAND_CIDS=()
  while IFS=$'\t' read -r cid assoc author num updated b64; do
    [ -z "$cid" ] && continue
    [ "$num" = "$sissue" ] || continue          # defensive: endpoint already scopes
    [[ "$updated" > "$max_ts" ]] && max_ts="$updated"
    n=$((n + 1))
    bridge_seen_has "$slug" "$cid" steward && continue
    body=$(bridge_b64d "$b64")
    if bridge_marked "$body"; then
      bridge_seen_add "$slug" "$cid" steward; log "$slug #$sissue c$cid: suppress:marker"; continue
    fi
    if ! bridge_assoc_ok "$assoc"; then
      bridge_seen_add "$slug" "$cid" steward; log "$slug #$sissue c$cid: suppress:assoc($assoc)"; continue
    fi
    CAND_CIDS+=("$cid")
    # Expand into (subject, line) entries. A watcher wake carries a trailing
    # `<!-- fleet:wake <subj1> <subj2> … -->` marker whose subjects align, in order,
    # with the body's `- ` lines. If the marker is absent or its subject count does
    # not match the line count (an operator note, or a format we don't recognize),
    # keep the whole comment as one opaque entry under a unique subject.
    local wmark keys line
    wmark=$(printf '%s\n' "$body" | grep -F '<!-- fleet:wake ' | head -n1)
    if [ -n "$wmark" ]; then
      keys=$(printf '%s' "$wmark" | sed -n 's/.*<!-- fleet:wake \(.*\)-->.*/\1/p')
      local -a wlines=() wsubs=()
      while IFS= read -r line; do case "$line" in "- "*) wlines+=("$line");; esac; done <<WEOF
$body
WEOF
      for line in $keys; do wsubs+=("$line"); done
      if [ "${#wlines[@]}" -gt 0 ] && [ "${#wlines[@]}" -eq "${#wsubs[@]}" ]; then
        local wi=0
        while [ "$wi" -lt "${#wlines[@]}" ]; do
          E_SUBJ+=("${wsubs[$wi]}"); E_TEXT+=("${wlines[$wi]}"); wi=$((wi + 1))
        done
      else
        E_SUBJ+=("op:$cid"); E_TEXT+=("@${author:-someone}: $body")
      fi
    else
      E_SUBJ+=("op:$cid"); E_TEXT+=("@${author:-someone}: $body")
    fi
  done <<EOF
$rows
EOF

  # Nothing to deliver (all seen or suppressed): advance past the newest, done.
  if [ "${#CAND_CIDS[@]}" -eq 0 ]; then
    [ -n "$max_ts" ] && printf '%s\n' "$max_ts" > "$sincef"
    [ "$n" -gt 0 ] && log "$slug: steward examined $n comment(s), none to deliver"
    return 0
  fi

  # Resolve the steward pane + idle-gate (the SAME rails bridge_relay's steward
  # branch uses for the --deliver path).
  local shit ssess span sst sts
  shit=$(bridge_find_steward "$slug")
  if [ -z "$shit" ]; then
    # No @steward pane THIS tick — HOLD (don't mark seen, don't advance) and retry.
    # Pre-#198 this dropped terminally, because a held SHARED watermark would starve
    # worker relays; now the steward channel has its OWN watermark, so holding costs
    # nothing but a cheap per-issue re-fetch and survives a transient absence — the
    # common case is the hub mid-respawn (a /clear, a restart), where a drop would
    # silently lose every queued wake (the watcher's edges are deduped, so they never
    # re-fire). A genuinely down/misconfigured hub just re-holds each tick until it's
    # back; --paginate above keeps that bounded.
    log "$slug: steward — no @steward pane yet, ${#CAND_CIDS[@]} held (retry next tick)"
    return 0
  fi
  IFS=$'\t' read -r ssess span sst sts <<EOF
$shit
EOF
  # Busy / mid-turn / mid-type → HOLD (don't mark seen, don't advance): retry next
  # tick. This pins ONLY the steward watermark — worker relays already advanced.
  if [ "$sst" = working ] && ! bridge_steward_stale "$sts"; then
    log "$slug: steward busy — ${#CAND_CIDS[@]} queued (steward watermark held)"; return 0
  fi
  # Half-typed-input defer (issue #191), BOUNDED (issue #195) so a persistently
  # non-empty steward input row can't wedge this control channel forever. The batch
  # drains atomically, so the typing counter is keyed to the CHANNEL (steward.<issue>),
  # not a per-comment id whose value would churn as new wakes arrive; it's reaped on a
  # clean drain below. Budget spent ⇒ bridge_typing_gate returns 0 (deliver anyway +
  # a WARN), so the coalesced digest is delivered rather than the channel wedging.
  local tkey="steward.$sissue"
  # ssess == the fleet's socket label (issue #159): the gate reads the steward pane
  # on its own server (else #191/#199's typing check silently no-ops).
  if ! bridge_typing_gate "$(fleet_socket "$ssess")" "$span" "$slug" "$tkey"; then
    log "$slug: steward typing — ${#CAND_CIDS[@]} queued (steward watermark held)"; return 0
  fi

  # IDLE → coalesce: keep the NEWEST entry per subject. Walk arrival order in reverse
  # (newest first) emitting a subject once; then reverse the survivors back to
  # chronological order for the digest.
  local -a OUT=()
  local seen_subj=' ' j=$(( ${#E_SUBJ[@]} - 1 )) sj
  while [ "$j" -ge 0 ]; do
    sj="${E_SUBJ[$j]}"
    case "$seen_subj" in *" $sj "*) j=$((j - 1)); continue;; esac
    seen_subj="$seen_subj$sj "
    OUT+=("${E_TEXT[$j]}")
    j=$((j - 1))
  done

  local nsub="${#OUT[@]}" nent="${#E_SUBJ[@]}" hdr digest k
  hdr="[steward inbox — issue #$sissue"
  [ "$nsub" -lt "$nent" ] && hdr="$hdr — ${#CAND_CIDS[@]} update(s) coalesced to $nsub subject(s)"
  hdr="$hdr]"
  digest="$hdr"
  k=$(( ${#OUT[@]} - 1 ))               # OUT is newest-first; emit oldest-first
  while [ "$k" -ge 0 ]; do digest="$digest"$'\n'"${OUT[$k]}"; k=$((k - 1)); done

  if bridge_inject "$(fleet_socket "$ssess")" "$span" "$digest"; then
    local c
    for c in "${CAND_CIDS[@]}"; do bridge_seen_add "$slug" "$c" steward; done
    bridge_typing_reset "$slug" "$tkey"          # reap the channel typing counter (issue #195)
    [ -n "$max_ts" ] && printf '%s\n' "$max_ts" > "$sincef"
    log "$slug: steward drain → ${ssess} (${#CAND_CIDS[@]} comment(s) → $nsub subject(s))"
  else
    # Pane resolved but a tmux op failed — transient; hold + retry next tick.
    log "$slug: steward inject-failed — will retry (watermark held)"
  fi
  return 0
}

poll() {
  command -v gh >/dev/null 2>&1 || { log "gh not on PATH — nothing to poll"; exit 0; }
  # Each fleet is its own tmux server now (issue #159) — "is tmux up" means "is any
  # fleet live", which fleet_sockets answers without a single shared server.
  [ -n "$(fleet_sockets)" ] || { log "no live fleet — nothing to relay into"; exit 0; }

  # Repo set: every ENABLED fleet's repo, each with ITS OWN gate/revive knobs. A
  # fleet enables the bridge in its conf (FLEET_ISSUE_BRIDGE=1); mirror pr-refresh's
  # cheap resolution — the primary FLEET_REPO (global knobs), plus each per-fleet
  # conf that opts in (its per-fleet FLEET_ISSUE_BRIDGE_ASSOC_FLOOR/…_REVIVE).
  declare -a REPOS R_FLOOR R_REVIVE; local seen=' '
  queue() { # $1=repo $2=assoc-floor $3=revive
    local rp="$1" sg; [ -z "$rp" ] && return
    sg=$(fleet_slug "$(fleet_norm_repo "$rp")")
    case "$seen" in *" $sg "*) return;; esac
    seen="$seen$sg "; REPOS+=("$rp"); R_FLOOR+=("$2"); R_REVIVE+=("$3")
  }

  # Global opt-in covers the primary repo (global knobs).
  [ "${FLEET_ISSUE_BRIDGE:-0}" = 1 ] && [ -n "${FLEET_REPO:-}" ] \
    && queue "$FLEET_REPO" "$ASSOC_FLOOR" "$REVIVE"
  # Per-fleet confs opt in individually, each carrying its own floor/revive. Source
  # in a subshell and emit repo<TAB>floor<TAB>revive so the values can't leak. (The
  # steward issue is NOT threaded here — it is a repo-specific number resolved
  # per-repo below via bridge_steward_issue_for_repo, the SAME resolver --deliver
  # uses, so the two ingresses can't diverge and the value can never leak/dedup-drop.)
  local _s cf
  while IFS=$'\t' read -r _s cf; do
    [ -f "$cf" ] || continue
    local line rp fl rv
    line=$( . "$cf" >/dev/null 2>&1
            [ "${FLEET_ISSUE_BRIDGE:-0}" = 1 ] && printf '%s\t%s\t%s' \
              "${FLEET_REPO:-}" \
              "${FLEET_ISSUE_BRIDGE_ASSOC_FLOOR:-$ASSOC_FLOOR}" \
              "${FLEET_ISSUE_BRIDGE_REVIVE:-$REVIVE}" )
    [ -z "$line" ] && continue
    IFS=$'\t' read -r rp fl rv <<EOF
$line
EOF
    queue "$rp" "$fl" "$rv"
  done < <(fleet_each_conf)

  if [ "${#REPOS[@]}" -eq 0 ]; then
    log "no fleet has FLEET_ISSUE_BRIDGE=1 — nothing to do"; exit 0
  fi
  local i=0
  while [ "$i" -lt "${#REPOS[@]}" ]; do
    ASSOC_FLOOR="${R_FLOOR[$i]}"; REVIVE="${R_REVIVE[$i]}"   # per-fleet gate/revive
    # Resolved per-repo via the SAME resolver --deliver uses (one source, no
    # divergence, leak-proof). This re-scans the confs per repo — O(#repos·#confs)
    # cheap subshells per ~15s tick — a deliberate trade of a tiny cost for keeping
    # one resolver rather than threading a second parsed value through queue().
    STEWARD_ISSUE=$(bridge_steward_issue_for_repo "${REPOS[$i]}")
    poll_repo "${REPOS[$i]}"
    i=$((i + 1))
  done
  exit 0
}

# =============================== dispatch ======================================
case "${1:-}" in
  --deliver)          deliver ;;
  --poll|'')          poll ;;
  -h|--help)          sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'fleet-issue-bridge: unknown arg %s (use --poll or --deliver)\n' "$1" >&2; exit 2 ;;
esac
