#!/bin/bash
# fleet-issue-bridge-selftest.sh — hermetic smoke test for bin/fleet-issue-bridge.sh.
#
# Asserts the bridge's relay contract (issue #132) against a FAKE gh + tmux (no
# network, no tmux server, no real injection):
#   • RELAY          a trusted comment on an IDLE bound worker is injected once.
#   • MARKER         a body carrying `<!-- fleet:no-relay -->` is SUPPRESSED.
#   • ASSOCIATION    a NONE/CONTRIBUTOR comment is SUPPRESSED (the RCE gate).
#   • IDLE-GATE      a comment on a WORKING worker is QUEUED (not injected) and
#                    the watermark holds it for retry — while a LATER comment on
#                    an idle worker still relays (low-water-mark, no head-of-line).
#   • DEDUP          re-running relays nothing already handled.
#   • HMAC (--deliver) a correctly-signed delivery injects; a bad signature does
#                    NOT (and exits non-zero).
#   • STEWARD (#146)  a comment on FLEET_STEWARD_ISSUE relays into the @steward
#                    pane (not a worker), honoring the marker/assoc gates; a busy
#                    steward queues, a STALE 'working' (missed Stop) is escaped so
#                    the channel can't wedge, a down hub RETRIES (never drops), and
#                    without FLEET_STEWARD_ISSUE the same comment routes nowhere.
#
# The scenario (repo fake/repo): worker windows for #10 (idle=done) and #11
# (working). Comments, ascending: c100 #10 OWNER→relay, c101 #10 marker→suppress,
# c102 #10 NONE→suppress, c103 #11 OWNER→queued(busy), c104 #10 COLLABORATOR→relay.
# Expected injections after one poll: exactly two, both into #10 (c100, c104).
#
# Needs `jq` (the fake gh applies the bridge's real --jq through it) — SKIPs
# cleanly if jq is absent. The --deliver HMAC leg also needs python3; it SKIPs
# just that leg if python3 is missing.
#
# Exit 0 = pass. Non-zero = fail (prints the captured log + injection record).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-issue-bridge.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }

if ! command -v jq >/dev/null 2>&1; then
  printf 'selftest: jq not installed — SKIP (the fake gh needs it to apply --jq)\n' >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fib-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf" "$WORK/state" "$WORK/leases"
INJECT="$WORK/inject.log"; : > "$INJECT"
CANNED="$WORK/comments.json"

# The bridge + lib + fake spawn run from $WORK/bin so BIN resolves the fakes and
# ../fleet.conf is absent (env FLEET_REPO wins).
cp "$SRC" "$WORK/bin/fleet-issue-bridge.sh"
cp "$BIN/fleet-lib.sh" "$WORK/bin/fleet-lib.sh"
chmod +x "$WORK/bin/fleet-issue-bridge.sh"

# fake dash-issue-session.sh — never really spawns (revive is off in this test).
cat > "$WORK/bin/dash-issue-session.sh" <<'FAKE'
#!/bin/bash
exit 0
FAKE
chmod +x "$WORK/bin/dash-issue-session.sh"

# --- fake gh: `api … --jq <expr>` applies the real jq to $CANNED; `issue view`
#     answers OPEN (unused unless revive is on). -----------------------------
cat > "$WORK/fakepath/gh" <<FAKE
#!/bin/bash
if [ "\$1" = api ]; then
  expr=''
  while [ "\$#" -gt 0 ]; do case "\$1" in --jq) shift; expr="\$1";; esac; shift; done
  [ -n "\$expr" ] && jq -r "\$expr" "$CANNED"
  exit 0
fi
if [ "\$1" = issue ] && [ "\$2" = view ]; then echo OPEN; exit 0; fi
exit 0
FAKE
chmod +x "$WORK/fakepath/gh"

# --- fake tmux: window table for find_window/fleet_for_repo; records injection --
# find_window format contains @claude_state; fleet_for_repo contains window_name.
# For the steward route (issue #146): bridge_find_steward does ONE `list-panes -a`
# returning session<TAB>pane_id<TAB>@claude_state<TAB>@claude_state_ts<TAB>@steward,
# so the fake yields s1's @steward=1 pane (%9) idle (state=done) — it resolves to
# session s1 → pane %9, idle.
cat > "$WORK/fakepath/tmux" <<FAKE
#!/bin/bash
args="\$*"
case "\$1" in
  info) exit 0 ;;
  list-windows)
    case "\$args" in
      *@claude_state*) printf 's1\t@1\tdone\t10\ns1\t@2\tworking\t11\n' ;;
      *window_name*)   printf 's1 plan\ns1 dash\n' ;;
    esac
    exit 0 ;;
  list-panes)   # s1's @steward pane. FAKE_NO_STEWARD ⇒ hub down (no row);
                # FAKE_STEWARD_WORKING_TS=<n> ⇒ working stamped at <n>; else idle.
    if [ -n "\$FAKE_NO_STEWARD" ]; then :
    elif [ -n "\$FAKE_STEWARD_WORKING_TS" ]; then printf 's1\t%s\tworking\t%s\t1\n' '%9' "\$FAKE_STEWARD_WORKING_TS"
    else printf 's1\t%s\tdone\t0\t1\n' '%9'; fi ;;
  set-buffer|paste-buffer|send-keys|delete-buffer)
    printf '%s\n' "\$args" >> "$INJECT" ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

# --- canned comments (ascending updated_at) ------------------------------------
MARK='<!-- fleet:no-relay -->'
cat > "$CANNED" <<JSON
[
 {"id":100,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T00:00:01Z","body":"please do X"},
 {"id":101,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T00:00:02Z","body":"record only $MARK"},
 {"id":102,"author_association":"NONE","user":{"login":"rando"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T00:00:03Z","body":"sneaky rm -rf"},
 {"id":103,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/11","updated_at":"2026-07-09T00:00:04Z","body":"for the busy one"},
 {"id":104,"author_association":"COLLABORATOR","user":{"login":"pal"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T00:00:05Z","body":"another instruction"}
]
JSON

# pre-seed the watermark so the FIRST run processes (an unseeded run just seeds).
printf '2026-07-09T00:00:00Z\n' > "$WORK/state/bridge_fake-repo.since"

runbridge() {
  # Forward SECRET/SIG from this call's prefix-assignment env into the child bash
  # (a prefix assignment to a shell FUNCTION isn't exported to its grandchildren).
  PATH="$WORK/fakepath:$PATH" \
  FLEET_ISSUE_BRIDGE=1 FLEET_REPO="fake/repo" \
  FLEET_CONF_DIR="$WORK/conf" \
  FLEET_ISSUE_BRIDGE_STATE_DIR="$WORK/state" \
  FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
  FLEET_ISSUE_BRIDGE_REVIVE=0 \
  FLEET_STEWARD_ISSUE="${FLEET_STEWARD_ISSUE:-}" \
  FAKE_NO_STEWARD="${FAKE_NO_STEWARD:-}" \
  FAKE_STEWARD_WORKING_TS="${FAKE_STEWARD_WORKING_TS:-}" \
  FLEET_ISSUE_BRIDGE_SECRET="${FLEET_ISSUE_BRIDGE_SECRET:-}" \
  FLEET_DELIVERY_SIG="${FLEET_DELIVERY_SIG:-}" \
    bash "$WORK/bin/fleet-issue-bridge.sh" "$@" 2>>"$WORK/log"
}

fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- log ---\n' >&2; cat "$WORK/log" >&2 2>/dev/null
         printf -- '--- inject ---\n' >&2; cat "$INJECT" >&2 2>/dev/null; exit 1; }

# ============================== poll leg =======================================
: > "$WORK/log"
runbridge --poll || fail "poll run exited non-zero"

# exactly two Enter submissions (one per relayed comment)
enters=$(grep -c 'send-keys -t @1 Enter' "$INJECT" 2>/dev/null || echo 0)
[ "$enters" = 2 ] || fail "expected 2 injections into @1, got $enters"
# the two relayed bodies are present, the suppressed/queued ones are not
grep -qF 'please do X' "$INJECT"        || fail "c100 (OWNER, idle) should relay"
grep -qF 'another instruction' "$INJECT" || fail "c104 (COLLABORATOR, idle) should relay"
grep -qF 'record only' "$INJECT"    && fail "c101 (no-relay marker) must be suppressed"
grep -qF 'sneaky' "$INJECT"         && fail "c102 (NONE assoc) must be suppressed"
grep -qF 'for the busy one' "$INJECT" && fail "c103 (worker WORKING) must be queued, not injected"

# seen set: relayed+suppressed are recorded; the queued (busy) one is NOT.
SEEN="$WORK/state/bridge_fake-repo.seen"
for id in 100 101 102 104; do grep -qxF "$id" "$SEEN" || fail "c$id should be marked seen"; done
grep -qxF 103 "$SEEN" && fail "c103 (queued busy) must NOT be marked seen (retry next tick)"
# c103 is queued (pending), so the watermark must be HELD at its pre-tick value
# (GitHub's ?since= is exclusive — advancing to c103's own timestamp would never
# re-list it). Here that pre-tick value is the seed 00:00:00Z.
[ "$(cat "$WORK/state/bridge_fake-repo.since")" = '2026-07-09T00:00:00Z' ] \
  || fail "watermark must be held (not advanced) while a comment is queued"

# DEDUP: a second identical poll injects nothing new (all handled/seen; c103 still
# busy → still queued, still no inject).
: > "$INJECT"
runbridge --poll || fail "second poll run exited non-zero"
[ -s "$INJECT" ] && [ "$(grep -c 'Enter' "$INJECT")" != 0 ] && fail "second poll must not re-inject (dedup)"

printf 'selftest: poll leg PASS (relay/marker/assoc/idle-gate/dedup)\n' >&2

# ============================== --deliver HMAC leg =============================
if ! command -v python3 >/dev/null 2>&1; then
  printf 'selftest: python3 absent — SKIP the --deliver HMAC leg\n' >&2
  printf 'selftest PASS\n'; exit 0
fi

SECRET="s3cr3t"
PAYLOAD='{"action":"created","issue":{"number":10},"comment":{"id":900,"author_association":"OWNER","user":{"login":"boss"},"body":"delivered via webhook"}}'
GOODSIG="sha256=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" 2>/dev/null | awk '{print $NF}')"

# correct signature → injects, exits 0
: > "$INJECT"
printf '%s' "$PAYLOAD" | FLEET_ISSUE_BRIDGE_SECRET="$SECRET" FLEET_DELIVERY_SIG="$GOODSIG" \
  runbridge --deliver || fail "--deliver with a valid HMAC exited non-zero"
grep -qF 'delivered via webhook' "$INJECT" || fail "valid delivery should inject into @1"

# wrong signature → NO injection, non-zero exit
: > "$INJECT"
if printf '%s' "$PAYLOAD" | FLEET_ISSUE_BRIDGE_SECRET="$SECRET" FLEET_DELIVERY_SIG="sha256=deadbeef" \
     runbridge --deliver; then
  fail "--deliver with a BAD HMAC must exit non-zero"
fi
grep -qF 'delivered via webhook' "$INJECT" && fail "a bad-HMAC delivery must NOT inject"

# FAIL CLOSED: no secret configured → refuse (never relay an unverifiable body).
: > "$INJECT"
if printf '%s' "$PAYLOAD" | FLEET_ISSUE_BRIDGE_SECRET="" FLEET_DELIVERY_SIG="$GOODSIG" \
     runbridge --deliver; then
  fail "--deliver with NO secret must exit non-zero (fail closed)"
fi
grep -qF 'delivered via webhook' "$INJECT" && fail "an unsigned/no-secret delivery must NOT inject"

# ===================== steward control-issue leg (issue #146) ==================
# A comment on the repo's FLEET_STEWARD_ISSUE (here #20) must relay into the
# @steward=1 pane (%9), NOT a worker window — and still honor the marker + assoc
# gates. Fresh state so the earlier watermark/seen don't interfere.
rm -f "$WORK/state/bridge_fake-repo.seen"
printf '2026-07-09T01:00:00Z\n' > "$WORK/state/bridge_fake-repo.since"
cat > "$CANNED" <<JSON
[
 {"id":200,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/20","updated_at":"2026-07-09T01:00:01Z","body":"ping steward"},
 {"id":201,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/20","updated_at":"2026-07-09T01:00:02Z","body":"steward note $MARK"},
 {"id":202,"author_association":"NONE","user":{"login":"rando"},"issue_url":"https://api.github.com/repos/fake/repo/issues/20","updated_at":"2026-07-09T01:00:03Z","body":"untrusted poke"}
]
JSON
: > "$INJECT"
FLEET_STEWARD_ISSUE=20 runbridge --poll || fail "steward-route poll exited non-zero"

# exactly one Enter into the steward pane (%9), carrying the trusted comment.
senters=$(grep -c 'send-keys -t %9 Enter' "$INJECT" 2>/dev/null || echo 0)
[ "$senters" = 1 ] || fail "expected 1 injection into the steward pane %9, got $senters"
grep -qF 'ping steward' "$INJECT"    || fail "c200 (OWNER, steward issue) should relay to the steward"
grep -qF 'steward inbox' "$INJECT"   || fail "the steward injection should carry the steward-inbox header"
grep -qF 'steward note' "$INJECT"    && fail "c201 (no-relay marker) must be suppressed"
grep -qF 'untrusted poke' "$INJECT"  && fail "c202 (NONE assoc) must be suppressed"
# a worker window (@1/@2) must NOT be driven by a steward-issue comment
grep -qF 'send-keys -t @1' "$INJECT" && fail "steward-issue comment must not inject into a worker window"

# HUB DOWN: a steward-issue comment with NO @steward pane must be RETRIED (return 3),
# never dropped — so it lands when the hub returns. Assert the trusted comment
# (c200) is neither injected nor marked seen (the watermark holds it for next tick).
rm -f "$WORK/state/bridge_fake-repo.seen"
printf '2026-07-09T01:00:00Z\n' > "$WORK/state/bridge_fake-repo.since"
: > "$INJECT"
FAKE_NO_STEWARD=1 FLEET_STEWARD_ISSUE=20 runbridge --poll || fail "hub-down poll exited non-zero"
[ -s "$INJECT" ] && [ "$(grep -c 'Enter' "$INJECT")" != 0 ] && fail "hub-down: nothing should be injected"
grep -qxF 200 "$WORK/state/bridge_fake-repo.seen" 2>/dev/null \
  && fail "hub-down: c200 must NOT be marked seen (retry when the hub returns)"

# STEWARD BUSY (fresh @claude_state_ts): a working steward queues the comment — not
# injected, not marked seen (retry next tick).
rm -f "$WORK/state/bridge_fake-repo.seen"
printf '2026-07-09T01:00:00Z\n' > "$WORK/state/bridge_fake-repo.since"
: > "$INJECT"
FAKE_STEWARD_WORKING_TS="$(date +%s)" FLEET_STEWARD_ISSUE=20 runbridge --poll \
  || fail "steward-busy poll exited non-zero"
[ -s "$INJECT" ] && [ "$(grep -c 'Enter' "$INJECT")" != 0 ] && fail "steward-busy: must not inject into a working steward"
grep -qxF 200 "$WORK/state/bridge_fake-repo.seen" 2>/dev/null \
  && fail "steward-busy: c200 must NOT be marked seen (queued for retry)"

# STEWARD STALE (missed Stop — @claude_state=working stamped long ago): the idle-gate
# must ESCAPE and relay, so the co-resident-dash-pane pollution can't wedge the
# channel. ts=0 ⇒ age ≫ FLEET_STUCK_WORKING_SECS ⇒ stale ⇒ relay.
rm -f "$WORK/state/bridge_fake-repo.seen"
printf '2026-07-09T01:00:00Z\n' > "$WORK/state/bridge_fake-repo.since"
: > "$INJECT"
FAKE_STEWARD_WORKING_TS=0 FLEET_STEWARD_ISSUE=20 runbridge --poll \
  || fail "steward-stale poll exited non-zero"
[ "$(grep -c 'send-keys -t %9 Enter' "$INJECT" 2>/dev/null || echo 0)" = 1 ] \
  || fail "steward-stale: a stale 'working' must be escaped and relayed (channel must not wedge)"

# WITHOUT FLEET_STEWARD_ISSUE, the same comment on #20 has no worker window and
# no steward route → it must be dropped (gone), never injected anywhere.
rm -f "$WORK/state/bridge_fake-repo.seen"
printf '2026-07-09T01:00:00Z\n' > "$WORK/state/bridge_fake-repo.since"
: > "$INJECT"
runbridge --poll || fail "no-steward-issue poll exited non-zero"
[ -s "$INJECT" ] && [ "$(grep -c 'Enter' "$INJECT")" != 0 ] \
  && fail "with no FLEET_STEWARD_ISSUE, a #20 comment must not inject anywhere"

printf 'selftest PASS: relay core + idle-gate + dedup + HMAC (+fail-closed) + steward-route (relay/busy/stale/hub-down/no-config) verified\n'
exit 0
