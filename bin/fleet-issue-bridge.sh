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
#     launchd (com.claude-fleet.issue-bridge) / a systemd timer, ~15s cadence.
#   • --deliver (webhook) — read ONE GitHub `issue_comment` delivery JSON on stdin,
#     validate its HMAC (FLEET_ISSUE_BRIDGE_SECRET), and relay that one comment.
#     Wire it behind `gh webhook forward` / a cloudflared tunnel for sub-second
#     latency. See docs/ISSUE-BRIDGE.md.
#
# RELAY CORE (identical for both ingresses), for each new comment:
#   1. dedup      — skip if this comment id was already handled (redeliveries,
#                   poll/webhook overlap). GitHub redelivers on any non-2xx.
#   2. marker     — SUPPRESS if the body carries `<!-- fleet:no-relay -->`. Feed by
#                   default; only fleet-internal-not-for-worker comments are marked
#                   (bin/fleet-comment.sh --note stamps it). Worker+steward share the
#                   OWNER identity, so author-filtering can't separate them — the
#                   marker is the loop guard; dedup is the backstop.
#   3. gate       — relay only from a trusted author_association (default floor
#                   OWNER/MEMBER/COLLABORATOR). A comment becomes autonomous tool-use
#                   in a bypass-permissions worker ⇒ treat as RCE; never relay
#                   NONE/CONTRIBUTOR. Configurable via FLEET_ISSUE_BRIDGE_ASSOC_FLOOR.
#   4. target     — resolve the bound worker window by @issue across live fleets on
#                   this repo. Idle-gate on @claude_state: inject only when NOT
#                   `working` (queue a busy worker to a later tick). Two-step paste
#                   injection (bracketed paste + a SEPARATE Enter) dodges the
#                   send-keys/bracketed-paste gotcha for multi-line bodies.
#   5. revive     — (opt-in FLEET_ISSUE_BRIDGE_REVIVE=1) if the issue is OPEN but its
#                   worker window is gone, re-spawn it via dash-issue-session.sh; the
#                   fresh worker's /fleet-claim reads the issue, comment and all.
#
# OFF BY DEFAULT — a fleet opts in with FLEET_ISSUE_BRIDGE=1. Un-gated relay on a
# PUBLIC repo is unsafe; the association gate is the headline control.
set -uo pipefail

MARKER='<!-- fleet:no-relay -->'
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

now() { date +%s 2>/dev/null || echo 0; }
utcnow() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '1970-01-01T00:00:00Z'; }
log() { printf '%s issue-bridge: %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '--:--:--')" "$*" >&2; }

# --- relay decision primitives (pure; the selftest exercises these) ------------

# 0 if the comment body carries the no-relay marker (⇒ suppress), 1 otherwise.
bridge_marked() { case "$1" in *"$MARKER"*) return 0;; *) return 1;; esac; }

# 0 if <assoc> is in the trusted floor, 1 otherwise. Word-boundary match against
# the space-separated ASSOC_FLOOR so "OWNER" never matches inside a longer token.
bridge_assoc_ok() {
  local a="$1" t
  for t in $ASSOC_FLOOR; do [ "$a" = "$t" ] && return 0; done
  return 1
}

# dedup set, one file per repo slug (capped so it can't grow without bound).
bridge_seen_file() { printf '%s/bridge_%s.seen' "$STATE" "$1"; }
bridge_seen_has()  { grep -qxF "$2" "$(bridge_seen_file "$1")" 2>/dev/null; }
bridge_seen_add() {
  local f; f=$(bridge_seen_file "$1")
  printf '%s\n' "$2" >> "$f" 2>/dev/null || return 0
  # trim to the most recent 2000 ids (ids only grow, so tail keeps the newest)
  if [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -n 2000 "$f" > "$f.$$" 2>/dev/null && mv "$f.$$" "$f" 2>/dev/null || rm -f "$f.$$" 2>/dev/null
  fi
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
    # No sessmap entry yet (single-fleet install / cold cache) → trust the match.
    if [ -z "$slug" ] || [ "$slug" = "$want_slug" ]; then
      printf '%s\t%s\t%s' "$sess" "$win" "$st"; return 0
    fi
  done < <(tmux list-windows -a -F '#{session_name}'$'\t''#{window_id}'$'\t''#{@claude_state}'$'\t''#{@issue}' 2>/dev/null)
  return 0
}

# Two-step injection: bracketed paste of the (possibly multi-line) text, then a
# SEPARATE Enter to submit. A single `send-keys -l` treats embedded newlines as
# Enters (submitting the first line early) — the bracketed-paste gotcha; pasting
# via a buffer with -p brackets the whole body as ONE paste, and the standalone
# Enter is what actually submits the turn.
bridge_inject() {
  local win="$1" text="$2" buf="fleet-relay-$$"
  tmux set-buffer -b "$buf" -- "$text" 2>/dev/null || return 1
  tmux paste-buffer -t "$win" -b "$buf" -d -p 2>/dev/null || { tmux delete-buffer -b "$buf" 2>/dev/null; return 1; }
  tmux send-keys -t "$win" Enter 2>/dev/null || return 1
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
  done < <(tmux list-windows -a -F '#{session_name} #{window_name}' 2>/dev/null | awk \
    '{ if ($2=="plan" || $2=="dash") f[$1]=1 } END { for (x in f) print x }')
  return 0
}

# THE RELAY CORE. Args: repo slug issue comment_id assoc author body.
# Prints one status token (for the log + the selftest) and returns:
#   0  handled terminally (relayed|revived|suppress:*|gone|dup) → caller marks seen
#   3  queued (target busy) → caller must NOT mark seen; retry next tick
bridge_relay() {
  local repo="$1" slug="$2" issue="$3" cid="$4" assoc="$5" author="$6" body="$7"
  if bridge_seen_has "$slug" "$cid"; then echo "dup"; return 0; fi
  if bridge_marked "$body"; then echo "suppress:marker"; return 0; fi
  if ! bridge_assoc_ok "$assoc"; then echo "suppress:assoc($assoc)"; return 0; fi

  local hit sess win st
  hit=$(bridge_find_window "$issue" "$repo")
  if [ -n "$hit" ]; then
    sess=$(printf '%s' "$hit" | cut -f1)
    win=$(printf '%s' "$hit" | cut -f2)
    st=$(printf '%s' "$hit" | cut -f3)
    if [ "$st" = working ]; then echo "queued-busy(#$issue)"; return 3; fi
    local msg
    msg="[issue #$issue — comment from @${author:-someone}]"$'\n\n'"$body"
    if bridge_inject "$win" "$msg"; then echo "relayed(#${issue}->${sess})"; return 0; fi
    echo "inject-failed(#$issue)"; return 0
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

  local repo="${FLEET_REPO:-}" cid assoc author num b64 body slug
  IFS=$'\t' read -r cid assoc author num b64 <<EOF
$row
EOF
  [ -z "$repo" ] && { log "--deliver: FLEET_REPO unset — cannot resolve repo"; exit 1; }
  body=$(printf '%s' "$b64" | base64 -d 2>/dev/null || printf '%s' "$b64" | base64 -D 2>/dev/null)
  slug=$(fleet_slug "$(fleet_norm_repo "$repo")")
  local out
  out=$(bridge_relay "$repo" "$slug" "$num" "$cid" "$assoc" "$author" "$body"); local rc=$?
  log "deliver #$num c$cid: $out"
  if [ "$rc" -eq 3 ]; then
    # Worker busy at delivery time. A webhook is one-shot, so DON'T mark it seen —
    # exit non-zero (EX_TEMPFAIL) so a redelivery-capable ingress re-sends it, and
    # the poll daemon (if running) picks it up as the backstop.
    exit 75
  fi
  bridge_seen_add "$slug" "$cid"   # terminal (relayed|revived|suppressed|dup)
  exit 0
}

# =========================== ingress: poll (default) ===========================
# Per-repo: list comments updated since our watermark, relay the new ones, then
# advance the watermark to the low-water mark (earliest still-queued comment, so a
# busy worker's comment is retried without re-relaying the ones after it).
poll_repo() {
  local repo="$1" slug since rows lease
  slug=$(fleet_slug "$(fleet_norm_repo "$repo")")
  local sincef="$STATE/bridge_$slug.since"
  since=$(cat "$sincef" 2>/dev/null)
  # First run: seed to NOW so enabling the bridge never floods with history.
  [ -z "$since" ] && { utcnow > "$sincef"; log "$slug: first run — watermark seeded, no backfill"; return 0; }

  # Single-writer per repo (poll tick vs a concurrent --deliver): skip if held.
  # A SIGKILL'd tick can't run its RETURN trap, so steal a lease dir older than
  # 120s (a normal tick is sub-second) — otherwise one crash deadlocks the repo.
  lease="$LEASE_DIR/issue-bridge-$slug.lock"
  mkdir -p "$LEASE_DIR" 2>/dev/null
  if ! mkdir "$lease" 2>/dev/null; then
    local age
    age=$(( $(now) - $(stat -f %m "$lease" 2>/dev/null || stat -c %Y "$lease" 2>/dev/null || now) ))
    if [ "$age" -ge 120 ]; then
      rm -rf "$lease" 2>/dev/null
      mkdir "$lease" 2>/dev/null || { log "$slug: lease contended — skip"; return 0; }
      log "$slug: stole stale lease (age ${age}s)"
    else
      log "$slug: another bridge run holds the lease — skip"; return 0
    fi
  fi
  # shellcheck disable=SC2064  # expand $lease now so the trap removes THIS lease
  trap "rm -rf '$lease' 2>/dev/null" RETURN

  # shellcheck disable=SC2016  # $-vars below are jq bindings, not shell
  rows=$(gh api -H "Accept: application/vnd.github+json" \
    "repos/$repo/issues/comments?since=$since&per_page=100&sort=updated&direction=asc" \
    --jq '.[] | [ (.id|tostring), .author_association, (.user.login // ""),
                  (.issue_url|split("/")|last), .updated_at, (.body|@base64) ] | @tsv' \
    2>/dev/null) || { log "$slug: gh api failed — skip this tick"; return 0; }

  local cid assoc author num updated b64 body out rc
  local min_pending='' max_ts='' n=0
  while IFS=$'\t' read -r cid assoc author num updated b64; do
    [ -z "$cid" ] && continue
    max_ts="$updated"; n=$((n + 1))
    bridge_seen_has "$slug" "$cid" && continue
    body=$(printf '%s' "$b64" | base64 -d 2>/dev/null || printf '%s' "$b64" | base64 -D 2>/dev/null)
    out=$(bridge_relay "$repo" "$slug" "$num" "$cid" "$assoc" "$author" "$body"); rc=$?
    [ "$out" = dup ] || log "$slug #$num c$cid: $out"
    if [ "$rc" -eq 3 ]; then
      [ -z "$min_pending" ] && min_pending="$updated"   # rows ascending ⇒ earliest pending
    else
      bridge_seen_add "$slug" "$cid"
    fi
  done <<EOF
$rows
EOF

  # Advance the watermark: to the earliest queued comment if any (so it retries),
  # else past the newest comment we saw. Never move it backwards.
  if [ -n "$min_pending" ]; then
    printf '%s\n' "$min_pending" > "$sincef"
  elif [ -n "$max_ts" ]; then
    printf '%s\n' "$max_ts" > "$sincef"
  fi
  [ "$n" -gt 0 ] && log "$slug: examined $n comment(s)"
  return 0
}

poll() {
  command -v gh >/dev/null 2>&1 || { log "gh not on PATH — nothing to poll"; exit 0; }
  tmux info >/dev/null 2>&1 || { log "tmux not running — nothing to relay into"; exit 0; }

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
  # in a subshell and emit repo<TAB>floor<TAB>revive so the values can't leak.
  if [ -d "$FLEET_CONF_DIR" ]; then
    for cf in "$FLEET_CONF_DIR"/*.conf; do
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
    done
  fi

  if [ "${#REPOS[@]}" -eq 0 ]; then
    log "no fleet has FLEET_ISSUE_BRIDGE=1 — nothing to do"; exit 0
  fi
  local i=0
  while [ "$i" -lt "${#REPOS[@]}" ]; do
    ASSOC_FLOOR="${R_FLOOR[$i]}"; REVIVE="${R_REVIVE[$i]}"   # per-fleet gate/revive
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
