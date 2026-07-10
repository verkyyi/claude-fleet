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
#                    the channel can't wedge, a down hub DROPS terminally (so the
#                    watermark advances — no worker starvation), an empty-state
#                    (cold-boot) steward is still found, and without
#                    FLEET_STEWARD_ISSUE the same comment routes nowhere.
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
  info) [ -n "\$FAKE_TMUX_DOWN" ] && exit 1; exit 0 ;;
  list-windows)
    case "\$args" in
      *@claude_state*) printf 's1\t@1\tdone\t10\ns1\t@2\tworking\t11\n' ;;
      *window_name*)   printf 's1 plan\ns1 dash\n' ;;
    esac
    exit 0 ;;
  list-panes)   # emits @steward<TAB>session<TAB>pane<TAB>@claude_state<TAB>@claude_state_ts
                # (marker FIRST so empty state/ts trail). FAKE_NO_STEWARD ⇒ hub down;
                # FAKE_STEWARD_COLD ⇒ empty state/ts (cold boot); FAKE_STEWARD_WORKING_TS
                # ⇒ working stamped at <n>; else idle (done).
    if [ -n "\$FAKE_NO_STEWARD" ]; then :
    elif [ -n "\$FAKE_STEWARD_SESS1" ]; then printf '\t1\t%s\tworking\t0\n' '%12'  # NON-steward pane in a session named "1" (empty @steward, leading field)
    elif [ -n "\$FAKE_STEWARD_COLD" ]; then printf '1\ts1\t%s\t\t\n' '%9'
    elif [ -n "\$FAKE_STEWARD_WORKING_TS" ]; then printf '1\ts1\t%s\tworking\t%s\n' '%9' "\$FAKE_STEWARD_WORKING_TS"
    else printf '1\ts1\t%s\tdone\t0\n' '%9'; fi ;;
  capture-pane)  # emulate the Claude TUI: the LAST \`❯\` line is the live input
                 # row (index 2, so cursor_y=2 sits on it). FAKE_INPUT_ROW (raw,
                 # may embed \\033 escapes for a dim ghost) wins if set — used with
                 # FAKE_CURSOR to exercise the cursor/faint signals (issue #199);
                 # else FAKE_INPUT_TEXT is a plain half-typed line (issue #191);
                 # empty ⇒ empty input.
    if [ -n "\$FAKE_INPUT_ROW" ]; then
      printf 'a past user turn\n❯ some earlier prompt\n❯ %b\n  ████░░ 50%% status\n' "\$FAKE_INPUT_ROW"
    else
      printf 'a past user turn\n❯ some earlier prompt\n❯ %s\n  ████░░ 50%% status\n' "\$FAKE_INPUT_TEXT"
    fi ;;
  display-message)  # cursor probe: FAKE_CURSOR is "x y" (empty ⇒ unresolvable, so
                    # bridge_input_busy falls back to the faint-strip signal alone).
    printf '%s\n' "\$FAKE_CURSOR" ;;
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
  # Steward routing is now resolved PER-FLEET CONF (issue #180 dropped the global
  # PRIMARY_STEWARD_ISSUE short-circuit), so materialize the leg's FLEET_STEWARD_ISSUE
  # into fake/repo's per-fleet conf — exactly how production resolves it. The env
  # var stays the ergonomic per-leg toggle: set ⇒ the steward route resolves; unset
  # ⇒ no conf ⇒ no route (mirrors an install that never wired a steward issue).
  if [ -n "${FLEET_STEWARD_ISSUE:-}" ]; then
    printf 'FLEET_REPO="fake/repo"\nFLEET_ISSUE_BRIDGE=1\nFLEET_STEWARD_ISSUE=%s\n' \
      "$FLEET_STEWARD_ISSUE" > "$WORK/conf/fake.conf"
  else
    rm -f "$WORK/conf/fake.conf"
  fi
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
  FAKE_STEWARD_SESS1="${FAKE_STEWARD_SESS1:-}" \
  FAKE_STEWARD_COLD="${FAKE_STEWARD_COLD:-}" \
  FAKE_STEWARD_WORKING_TS="${FAKE_STEWARD_WORKING_TS:-}" \
  FAKE_TMUX_DOWN="${FAKE_TMUX_DOWN:-}" \
  FAKE_INPUT_TEXT="${FAKE_INPUT_TEXT:-}" \
  FAKE_INPUT_ROW="${FAKE_INPUT_ROW:-}" \
  FAKE_CURSOR="${FAKE_CURSOR:-}" \
  FLEET_BRIDGE_MAX_TYPING_DEFERS="${FLEET_BRIDGE_MAX_TYPING_DEFERS:-}" \
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

# ============ half-typed input idle-gate leg (issue #191) ======================
# A human typing an UN-SUBMITTED line into an IDLE worker does NOT flip
# @claude_state, so the input-content check must DEFER the relay (preserve the
# partial) rather than prepend+submit onto it — then deliver once the line clears.
rm -f "$WORK/state/bridge_fake-repo.seen"
printf '2026-07-09T02:00:00Z\n' > "$WORK/state/bridge_fake-repo.since"
cat > "$CANNED" <<JSON
[
 {"id":300,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T02:00:01Z","body":"deliver me when the line is clear"}
]
JSON
# (a) idle worker + half-typed line → DEFER: no inject, not seen, watermark held.
: > "$INJECT"
FAKE_INPUT_TEXT='git lo' runbridge --poll || fail "typing-gate poll exited non-zero"
[ -s "$INJECT" ] && [ "$(grep -c 'Enter' "$INJECT")" != 0 ] \
  && fail "typing-gate: a relay must NOT inject onto a half-typed input line"
grep -qxF 300 "$WORK/state/bridge_fake-repo.seen" 2>/dev/null \
  && fail "typing-gate: c300 must NOT be marked seen while deferred (retry next tick)"
[ "$(cat "$WORK/state/bridge_fake-repo.since")" = '2026-07-09T02:00:00Z' ] \
  || fail "typing-gate: watermark must be held while the relay is deferred"
# (b) line cleared (empty input) → the deferred relay now delivers, marked seen.
: > "$INJECT"
runbridge --poll || fail "typing-gate cleared poll exited non-zero"
grep -qF 'deliver me when the line is clear' "$INJECT" \
  || fail "typing-gate: once the input is empty the deferred relay must deliver"
grep -qxF 300 "$WORK/state/bridge_fake-repo.seen" 2>/dev/null \
  || fail "typing-gate: the delivered comment must be marked seen"
printf 'selftest: input-content idle-gate leg PASS (defer half-typed, deliver when clear)\n' >&2

# ============ ghost-autosuggestion vs typed input (issue #199) =================
# The input row is capture line 3 (0-based row 2). `❯ ` occupies cols 0-1, so
# input-start = col 2. Claude draws a DIM ghost autosuggestion in that row when the
# input is empty but leaves the cursor parked at input-start (col 2) — it must be
# read as EMPTY (deliver), where the old "any text after ❯" test wedged forever.
# Genuinely-typed text advances the cursor past input-start (or is non-dim) — DEFER.
# ghost() asserts a fresh comment DELIVERS for the given input row + cursor;
# typed() asserts it DEFERS. Each resets state so the low-water-mark is clean.
ghost_id=400
ghost_expect() {  # <verb: deliver|defer> <input-row> <cursor|""> <label>
  local verb="$1" row="$2" cur="$3" label="$4"
  ghost_id=$((ghost_id + 1))
  rm -f "$WORK/state/bridge_fake-repo.seen"
  printf '2026-07-09T03:00:00Z\n' > "$WORK/state/bridge_fake-repo.since"
  cat > "$CANNED" <<JSON
[
 {"id":$ghost_id,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T03:00:01Z","body":"ghost probe $ghost_id"}
]
JSON
  : > "$INJECT"
  FAKE_INPUT_ROW="$row" FAKE_CURSOR="$cur" runbridge --poll || fail "ghost-leg [$label] poll exited non-zero"
  local injected=no
  [ -s "$INJECT" ] && [ "$(grep -c 'Enter' "$INJECT")" != 0 ] && injected=yes
  case "$verb" in
    deliver) [ "$injected" = yes ] || fail "ghost-leg [$label]: must DELIVER (relay was wedged)" ;;
    defer)   [ "$injected" = no  ] || fail "ghost-leg [$label]: must DEFER (would clobber typed input)" ;;
  esac
}
G=$'\033'   # ESC, for building realistic SGR-styled ghost rows
# DELIVER — a dim ghost with cursor parked at input-start, across the encodings a
# real Claude TUI actually emits (a brittle span-regex strip would miss most):
ghost_expect deliver "${G}[2mThe steward will land it via /land${G}[0m"  '2 2' "bare dim \\e[2m…\\e[0m"
ghost_expect deliver "${G}[2;38;5;244mThe steward will land it${G}[0m"   '2 2' "combined dim+256 \\e[2;38;5;244m"
ghost_expect deliver "${G}[2;90msome gray ghost text${G}[22m"           '2 2' "combined dim+color, \\e[22m off"
ghost_expect deliver "${G}[2m${G}[38;5;244mghost then color${G}[0m"     '2 2' "dim then SEPARATE color SGR"
ghost_expect deliver "${G}[2mghost via bare reset${G}[m"                '2 2' "\\e[m bare-reset terminator"
# DELIVER on the awk fallback ALONE — cursor unresolvable (old tmux / copy-mode),
# so the faint-state parse is the only signal and must still see the ghost as dim:
ghost_expect deliver "${G}[2;38;5;244mThe steward will land it${G}[0m"   ''   "combined dim, NO cursor (awk fallback)"
# DEFER — genuinely typed input in each of the two independent ways:
ghost_expect defer   'git lo'                                           '8 2' "typed, cursor past input-start"
ghost_expect defer   'git lo'                                           ''    "typed, NO cursor (awk sees non-dim)"
ghost_expect defer   'git lo'                                           '2 2' "typed then Home-to-col-0 (non-dim)"
# DEFER — real text colored with a 256/truecolor code whose value tokens contain a
# literal '2' must NOT be misread as the dim (SGR 2) attribute:
ghost_expect defer   "${G}[38;5;2mreal green text${G}[0m"               ''    "256-color idx 2 is NOT dim"
printf 'selftest: ghost-autosuggestion leg PASS (deliver ghost across encodings, defer typed/edited/colored)\n' >&2

# ============ max-typing-defer safety valve leg (issue #195) ====================
# The #191 typing-defer is UNBOUNDED: a row that reads non-empty PERSISTENTLY would
# defer forever, silently. The safety valve caps it — after N consecutive typing-
# defers of the SAME comment, deliver anyway + WARN; a counter that clears before N
# resets so a real partial is never penalized. Drive it with a tiny cap (N=3) for
# speed. State persists in $WORK/state across polls, so the counter accrues.
TYPING_MAX=3
# (a) PERSISTENT non-empty input → defer N times, then deliver-anyway on the (N+1)th
#     with a WARNING; the per-comment counter accrues across ticks.
rm -f "$WORK/state/bridge_fake-repo.seen" "$WORK"/state/bridge_fake-repo.typing.* 2>/dev/null
printf '2026-07-09T03:00:00Z\n' > "$WORK/state/bridge_fake-repo.since"
cat > "$CANNED" <<JSON
[
 {"id":400,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T03:00:01Z","body":"deliver me even if the input wedges"}
]
JSON
CNT="$WORK/state/bridge_fake-repo.typing.400"
i=1
while [ "$i" -le "$TYPING_MAX" ]; do
  : > "$INJECT"
  FLEET_BRIDGE_MAX_TYPING_DEFERS="$TYPING_MAX" FAKE_INPUT_TEXT='git lo' \
    runbridge --poll || fail "max-defer poll (defer #$i) exited non-zero"
  [ -s "$INJECT" ] && [ "$(grep -c 'Enter' "$INJECT")" != 0 ] \
    && fail "max-defer: relay must still DEFER on tick $i (≤ N), not inject"
  grep -qxF 400 "$WORK/state/bridge_fake-repo.seen" 2>/dev/null \
    && fail "max-defer: c400 must NOT be seen while deferred (tick $i)"
  [ "$(cat "$CNT" 2>/dev/null)" = "$i" ] \
    || fail "max-defer: per-comment counter must be $i after $i defers, got $(cat "$CNT" 2>/dev/null)"
  i=$((i + 1))
done
# (N+1)th tick, input STILL non-empty → deliver anyway + WARN, counter reset.
: > "$INJECT"; : > "$WORK/log"
FLEET_BRIDGE_MAX_TYPING_DEFERS="$TYPING_MAX" FAKE_INPUT_TEXT='git lo' \
  runbridge --poll || fail "max-defer deliver-anyway poll exited non-zero"
grep -qF 'deliver me even if the input wedges' "$INJECT" \
  || fail "max-defer: after N defers the relay must deliver anyway (avoid a wedge)"
grep -qF 'delivering to avoid a wedge' "$WORK/log" \
  || fail "max-defer: the deliver-anyway must emit the WARNING log"
grep -qxF 400 "$WORK/state/bridge_fake-repo.seen" 2>/dev/null \
  || fail "max-defer: the force-delivered comment must be marked seen"
[ -e "$CNT" ] && fail "max-defer: the per-comment counter must be reset (removed) on delivery"

# (b) SHORT-LIVED partial (clears before N) → normal deliver + counter reset, no warn.
rm -f "$WORK/state/bridge_fake-repo.seen" "$WORK"/state/bridge_fake-repo.typing.* 2>/dev/null
printf '2026-07-09T03:10:00Z\n' > "$WORK/state/bridge_fake-repo.since"
cat > "$CANNED" <<JSON
[
 {"id":401,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T03:10:01Z","body":"short pause then deliver clean"}
]
JSON
CNT2="$WORK/state/bridge_fake-repo.typing.401"
# two defers (< N=3), input non-empty
i=1
while [ "$i" -le 2 ]; do
  : > "$INJECT"
  FLEET_BRIDGE_MAX_TYPING_DEFERS="$TYPING_MAX" FAKE_INPUT_TEXT='half' \
    runbridge --poll || fail "max-defer(b) poll (defer #$i) exited non-zero"
  i=$((i + 1))
done
[ "$(cat "$CNT2" 2>/dev/null)" = 2 ] || fail "max-defer(b): counter must be 2 before the line clears"
# input clears → normal deliver, counter reset, and NO deliver-anyway warning.
: > "$INJECT"; : > "$WORK/log"
FLEET_BRIDGE_MAX_TYPING_DEFERS="$TYPING_MAX" runbridge --poll \
  || fail "max-defer(b) cleared poll exited non-zero"
grep -qF 'short pause then deliver clean' "$INJECT" \
  || fail "max-defer(b): once the line clears the deferred relay must deliver normally"
grep -qxF 401 "$WORK/state/bridge_fake-repo.seen" 2>/dev/null \
  || fail "max-defer(b): the cleanly-delivered comment must be marked seen"
[ -e "$CNT2" ] && fail "max-defer(b): the counter must be reset when the input clears"
grep -qF 'delivering to avoid a wedge' "$WORK/log" \
  && fail "max-defer(b): a clean clear-before-N delivery must NOT emit the wedge warning"

# (c) WINDOW-GONE terminal path must REAP an orphaned counter (issue #195 review):
# a comment deferred a few times (counter file exists), then its window vanishes,
# must be dropped (seen) AND have its .typing.<cid> file reaped — no state-dir leak.
rm -f "$WORK/state/bridge_fake-repo.seen" "$WORK"/state/bridge_fake-repo.typing.* 2>/dev/null
printf '2026-07-09T03:20:00Z\n' > "$WORK/state/bridge_fake-repo.since"
printf '2\n' > "$WORK/state/bridge_fake-repo.typing.402"   # a stale counter from prior defers
cat > "$CANNED" <<JSON
[
 {"id":402,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/99","updated_at":"2026-07-09T03:20:01Z","body":"my worker window is gone"}
]
JSON
: > "$INJECT"
FLEET_BRIDGE_MAX_TYPING_DEFERS="$TYPING_MAX" runbridge --poll || fail "gone-reap poll exited non-zero"
grep -qxF 402 "$WORK/state/bridge_fake-repo.seen" 2>/dev/null \
  || fail "gone-reap: a comment with no live window must be marked seen (dropped)"
[ -e "$WORK/state/bridge_fake-repo.typing.402" ] \
  && fail "gone-reap: the orphaned per-comment counter must be reaped on the terminal drop"

# (d) FAIL SAFE: an UN-persistable counter (unwritable state dir) must DELIVER anyway
# rather than defer forever on a stuck-at-1 count (issue #195 review). Skip as root
# (a read-only dir is still writable to root, masking the failure).
if [ "$(id -u 2>/dev/null)" != 0 ]; then
  rm -f "$WORK/state/bridge_fake-repo.seen" "$WORK"/state/bridge_fake-repo.typing.* 2>/dev/null
  printf '2026-07-09T03:30:00Z\n' > "$WORK/state/bridge_fake-repo.since"
  cat > "$CANNED" <<JSON
[
 {"id":403,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T03:30:01Z","body":"deliver despite an unwritable state dir"}
]
JSON
  : > "$INJECT"
  chmod 500 "$WORK/state"
  FLEET_BRIDGE_MAX_TYPING_DEFERS="$TYPING_MAX" FAKE_INPUT_TEXT='git lo' runbridge --poll; rc=$?
  chmod 700 "$WORK/state"
  [ "$rc" = 0 ] || fail "fail-safe poll exited non-zero ($rc)"
  grep -qF 'deliver despite an unwritable state dir' "$INJECT" \
    || fail "fail-safe: an un-persistable counter must deliver anyway, not defer forever"
fi
printf 'selftest: max-typing-defer leg PASS (bounded defer: force-deliver+warn after N, reset on clear, gone-reap, fail-safe)\n' >&2

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

# TMUX DOWN: a validly-signed delivery arriving while tmux is down must RETRY
# (exit 75, EX_TEMPFAIL) — never inject, never mark the comment seen — so a
# redelivery / the poll backstop can land it once tmux is back (issue #146).
: > "$INJECT"
printf '%s' "$PAYLOAD" | FAKE_TMUX_DOWN=1 FLEET_ISSUE_BRIDGE_SECRET="$SECRET" FLEET_DELIVERY_SIG="$GOODSIG" \
  runbridge --deliver; rc=$?
[ "$rc" = 75 ] || fail "--deliver with tmux down must exit 75 (retry), got $rc"
grep -qF 'delivered via webhook' "$INJECT" && fail "a tmux-down delivery must NOT inject"

# ===================== steward control-issue leg (issue #146) ==================
# A comment on the repo's FLEET_STEWARD_ISSUE (here #20) must relay into the
# @steward=1 pane (%9), NOT a worker window — and still honor the marker + assoc
# gates. The steward channel now has its OWN watermark/seen-set (issue #198), so
# seed BOTH the worker and steward watermarks. The seen files are kept PRESENT-but-
# EMPTY (`: >`, not rm) so bridge_state_file dual-reads the legacy flat path (issue
# #181) — the leg assertions below read those flat paths, not the per-fleet dir.
seed_steward() {  # reset the steward channel's own watermark + seen-set for a leg
  # Clear any per-fleet bridge state (issue #181 layout) — e.g. a typing counter a
  # prior leg wrote there — so each leg starts clean and the flat files below win the
  # dual-read.
  rm -rf "$WORK/conf/fleets/fake/bridge" 2>/dev/null
  : > "$WORK/state/bridge_fake-repo.seen"
  : > "$WORK/state/bridge_fake-repo.steward.seen"
  printf '2026-07-09T01:00:00Z\n' > "$WORK/state/bridge_fake-repo.since"
  printf '2026-07-09T01:00:00Z\n' > "$WORK/state/bridge_fake-repo.steward.since"
}
SSEEN="$WORK/state/bridge_fake-repo.steward.seen"
seed_steward
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

seed_steward
: > "$INJECT"
FAKE_STEWARD_SESS1=1 FLEET_STEWARD_ISSUE=20 runbridge --poll || fail "steward-sess1 poll exited non-zero"
[ -s "$INJECT" ] && [ "$(grep -c 'Enter' "$INJECT")" != 0 ] \
  && fail "session-named-1: a non-steward pane must not be misread as the steward and injected"

# COLD BOOT: a steward pane with EMPTY @claude_state (marker-first field order must
# survive the empty trailing fields) is idle → the comment relays. Guards the
# IFS-collapse misparse regression.
seed_steward
: > "$INJECT"
FAKE_STEWARD_COLD=1 FLEET_STEWARD_ISSUE=20 runbridge --poll || fail "steward-cold poll exited non-zero"
[ "$(grep -c 'send-keys -t %9 Enter' "$INJECT" 2>/dev/null || echo 0)" = 1 ] \
  || fail "steward-cold: an empty-@claude_state steward must still be found (idle) and relayed"

# STEWARD BUSY (fresh @claude_state_ts): a working steward queues the comment — not
# injected, not marked seen (retry next tick).
seed_steward
: > "$INJECT"
FAKE_STEWARD_WORKING_TS="$(date +%s)" FLEET_STEWARD_ISSUE=20 runbridge --poll \
  || fail "steward-busy poll exited non-zero"
[ -s "$INJECT" ] && [ "$(grep -c 'Enter' "$INJECT")" != 0 ] && fail "steward-busy: must not inject into a working steward"
grep -qxF 200 "$SSEEN" 2>/dev/null \
  && fail "steward-busy: c200 must NOT be marked seen (queued for retry)"
# The steward watermark must be HELD while the wake is queued (issue #198) — else
# next tick's exclusive ?since= would skip the un-delivered comment.
[ "$(cat "$WORK/state/bridge_fake-repo.steward.since")" = '2026-07-09T01:00:00Z' ] \
  || fail "steward-busy: the steward watermark must be held while a wake is queued"

# STEWARD STALE (missed Stop — @claude_state=working stamped long ago): the idle-gate
# must ESCAPE and relay, so the co-resident-dash-pane pollution can't wedge the
# channel. ts=0 ⇒ age ≫ FLEET_STUCK_WORKING_SECS ⇒ stale ⇒ relay.
seed_steward
: > "$INJECT"
FAKE_STEWARD_WORKING_TS=0 FLEET_STEWARD_ISSUE=20 runbridge --poll \
  || fail "steward-stale poll exited non-zero"
[ "$(grep -c 'send-keys -t %9 Enter' "$INJECT" 2>/dev/null || echo 0)" = 1 ] \
  || fail "steward-stale: a stale 'working' must be escaped and relayed (channel must not wedge)"

# STEWARD half-typed input (issue #191): the operator types into the @steward pane
# too, and a keystroke doesn't flip its state — so an idle steward with a non-empty
# input row must DEFER (no inject, c200 not marked seen), mirroring the worker gate.
seed_steward
: > "$INJECT"
FAKE_INPUT_TEXT='half typed' FLEET_STEWARD_ISSUE=20 runbridge --poll \
  || fail "steward-typing poll exited non-zero"
[ -s "$INJECT" ] && [ "$(grep -c 'send-keys -t %9 Enter' "$INJECT")" != 0 ] \
  && fail "steward-typing: a relay must NOT inject onto the steward's half-typed line"
grep -qxF 200 "$SSEEN" 2>/dev/null \
  && fail "steward-typing: c200 must NOT be marked seen while deferred (retry next tick)"

# STEWARD typing defer is BOUNDED (issue #195 composed with #198): a persistently
# non-empty steward input row must not wedge the control channel forever. With a tiny
# cap N=2 and a persistent partial, the channel defers twice then FORCE-DELIVERS the
# coalesced digest + WARNs on the 3rd tick. The typing counter is channel-level (keyed
# steward.<issue>, not per-cid) so it accrues across ticks as new wakes arrive, and is
# reaped on the forced drain — this is the exact interaction the rebase had to preserve.
seed_steward
SMAX=2; i=1
while [ "$i" -le "$SMAX" ]; do
  : > "$INJECT"
  FLEET_BRIDGE_MAX_TYPING_DEFERS="$SMAX" FAKE_INPUT_TEXT='typing…' FLEET_STEWARD_ISSUE=20 \
    runbridge --poll || fail "steward-bound poll (defer #$i) exited non-zero"
  grep -q 'send-keys -t %9 Enter' "$INJECT" 2>/dev/null \
    && fail "steward-bound: must DEFER on tick $i (≤ N), not inject"
  grep -qxF 200 "$SSEEN" 2>/dev/null \
    && fail "steward-bound: c200 must NOT be seen while deferred (tick $i)"
  i=$((i + 1))
done
: > "$INJECT"; : > "$WORK/log"
FLEET_BRIDGE_MAX_TYPING_DEFERS="$SMAX" FAKE_INPUT_TEXT='typing…' FLEET_STEWARD_ISSUE=20 \
  runbridge --poll || fail "steward-bound deliver-anyway poll exited non-zero"
grep -qF 'ping steward' "$INJECT" \
  || fail "steward-bound: after N defers the steward wake must deliver anyway (avoid a wedge)"
grep -qF 'delivering to avoid a wedge' "$WORK/log" \
  || fail "steward-bound: the force-deliver must emit the WARNING log"
grep -qxF 200 "$SSEEN" 2>/dev/null \
  || fail "steward-bound: the force-delivered wake must be marked seen"
printf 'selftest: steward-bound leg PASS (steward typing-defer bounded — force-deliver+warn after N)\n' >&2

# WITHOUT FLEET_STEWARD_ISSUE, the same comment on #20 has no worker window and
# no steward route → it must be dropped (gone), never injected anywhere.
: > "$WORK/state/bridge_fake-repo.seen"   # keep present (empty) so bridge dual-reads the legacy path (issue 181)
printf '2026-07-09T01:00:00Z\n' > "$WORK/state/bridge_fake-repo.since"
: > "$INJECT"
runbridge --poll || fail "no-steward-issue poll exited non-zero"
[ -s "$INJECT" ] && [ "$(grep -c 'Enter' "$INJECT")" != 0 ] \
  && fail "with no FLEET_STEWARD_ISSUE, a #20 comment must not inject anywhere"

printf 'selftest: steward-route leg PASS (relay/busy/stale/cold/hub-down/typing/no-config, per-channel watermark)\n' >&2

# ================ per-channel decoupling (issue #198, acceptance A) =============
# THE headline fix: a BUSY steward must not block a fresh WORKER relay on the same
# repo. The steward (issue #20) is `working` and its wake queues in the STEWARD
# channel; meanwhile a brand-new worker comment on #10 (idle worker @1) must still
# relay via the independent WORKER channel. Old single-watermark: the busy steward
# would pin the shared watermark and the worker comment would sit queued too.
seed_steward
cat > "$CANNED" <<JSON
[
 {"id":400,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/20","updated_at":"2026-07-09T01:00:01Z","body":"🛰️ fleet-watch — fake-repo\n\n- PR #196 (#181) green — /land 196?\n\n<!-- fleet:wake fake-repo:196 -->"},
 {"id":401,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T01:00:02Z","body":"worker do this now"}
]
JSON
: > "$INJECT"
FAKE_STEWARD_WORKING_TS="$(date +%s)" FLEET_STEWARD_ISSUE=20 runbridge --poll \
  || fail "decouple poll exited non-zero"
# the worker comment relayed into @1 despite the busy steward
grep -qF 'worker do this now' "$INJECT" \
  || fail "decouple: a busy steward must NOT block a fresh worker relay (per-channel watermark)"
grep -qxF 401 "$WORK/state/bridge_fake-repo.seen" 2>/dev/null \
  || fail "decouple: the relayed worker comment must be marked seen in the WORKER channel"
# the steward wake was NOT injected (steward busy) and NOT marked seen (queued)
grep -q 'send-keys -t %9 Enter' "$INJECT" 2>/dev/null \
  && fail "decouple: the busy steward must not be injected into"
grep -qxF 400 "$SSEEN" 2>/dev/null \
  && fail "decouple: the queued steward wake must NOT be marked seen (retry next tick)"
# and the steward watermark held while the WORKER watermark advanced past c401
[ "$(cat "$WORK/state/bridge_fake-repo.steward.since")" = '2026-07-09T01:00:00Z' ] \
  || fail "decouple: steward watermark must hold while its wake is queued"
[ "$(cat "$WORK/state/bridge_fake-repo.since")" = '2026-07-09T01:00:02Z' ] \
  || fail "decouple: worker watermark must advance independently of the busy steward"
printf 'selftest: decoupling leg PASS (busy steward, worker still relayed)\n' >&2

# ================ coalesce-on-drain (issue #198, acceptance B) ==================
# THREE queued wakes for the SAME PR (#168) drain to an IDLE steward as ONE line
# (the newest), not a 3× replay. Distinct attempt tags let us assert newest-wins.
seed_steward
cat > "$CANNED" <<JSON
[
 {"id":500,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/20","updated_at":"2026-07-09T01:00:01Z","body":"🛰️ fleet-watch — fake-repo\n\n- PR #168 green (attempt one)\n\n<!-- fleet:wake fake-repo:168 -->"},
 {"id":501,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/20","updated_at":"2026-07-09T01:00:02Z","body":"🛰️ fleet-watch — fake-repo\n\n- PR #168 green (attempt two)\n\n<!-- fleet:wake fake-repo:168 -->"},
 {"id":502,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/20","updated_at":"2026-07-09T01:00:03Z","body":"🛰️ fleet-watch — fake-repo\n\n- PR #168 green (attempt three)\n\n<!-- fleet:wake fake-repo:168 -->"}
]
JSON
: > "$INJECT"
FLEET_STEWARD_ISSUE=20 runbridge --poll || fail "coalesce poll exited non-zero"
# exactly ONE injection into the steward pane
[ "$(grep -c 'send-keys -t %9 Enter' "$INJECT" 2>/dev/null || echo 0)" = 1 ] \
  || fail "coalesce: 3 same-PR wakes must drain as exactly ONE injection"
# it carries the NEWEST wake and drops the superseded ones
grep -qF 'attempt three' "$INJECT" || fail "coalesce: the delivered wake must be the newest (attempt three)"
grep -qF 'attempt one' "$INJECT"   && fail "coalesce: superseded wake (attempt one) must be dropped"
grep -qF 'attempt two' "$INJECT"   && fail "coalesce: superseded wake (attempt two) must be dropped"
# all three comments are marked seen (no re-delivery next tick)
for id in 500 501 502; do grep -qxF "$id" "$SSEEN" 2>/dev/null || fail "coalesce: c$id must be marked seen after drain"; done
printf 'selftest: coalesce-on-drain leg PASS (3 same-PR wakes → 1, newest wins)\n' >&2

# ============ subject keying: kind-distinct vs PR-lifecycle (issue #198) ========
# Two edges that share a GitHub number but are SEMANTICALLY DISTINCT (a stuck worker
# on a prod-alert issue #60) must NOT collapse — dropping one would silently lose a
# decision-worthy wake. The ONLY deliberate cross-kind collapse is the PR lifecycle:
# a `propened` then a `prgreen` for one PR (both subject `pr:<slug>:<num>`) collapse
# to the newer (green/land) wake. c600 carries the distinct pair; c601/c602 the PR
# pair. Idle steward drains all in one digest.
seed_steward
cat > "$CANNED" <<JSON
[
 {"id":600,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/20","updated_at":"2026-07-09T01:00:01Z","body":"🛰️ fleet-watch — fake-repo\n\n- prod-alert #60 filed — first-response?\n- #60 looks stuck (looping) — investigate?\n\n<!-- fleet:wake prodalert:fake-repo:60 stuck:fake-repo:60 -->"},
 {"id":601,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/20","updated_at":"2026-07-09T01:00:02Z","body":"🛰️ fleet-watch — fake-repo\n\n- #7 shipped PR #70 — review?\n\n<!-- fleet:wake pr:fake-repo:70 -->"},
 {"id":602,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/20","updated_at":"2026-07-09T01:00:03Z","body":"🛰️ fleet-watch — fake-repo\n\n- PR #70 (#7) green — /land 70?\n\n<!-- fleet:wake pr:fake-repo:70 -->"}
]
JSON
: > "$INJECT"
FLEET_STEWARD_ISSUE=20 runbridge --poll || fail "subject-keying poll exited non-zero"
# distinct kinds on #60 both survive (no false collapse)
grep -qF 'prod-alert #60 filed' "$INJECT" \
  || fail "subject-keying: a prod-alert edge must not be collapsed away by a same-number stuck edge"
grep -qF '#60 looks stuck' "$INJECT" \
  || fail "subject-keying: a stuck edge must not be collapsed away by a same-number prod-alert edge"
# PR lifecycle #70 collapses to the newest (green ≻ shipped-for-review)
grep -qF 'PR #70 (#7) green — /land 70?' "$INJECT" \
  || fail "subject-keying: the newest PR-lifecycle wake (green) must survive"
grep -qF 'shipped PR #70' "$INJECT" \
  && fail "subject-keying: the superseded PR-lifecycle wake (shipped) must be collapsed"
printf 'selftest: subject-keying leg PASS (kind-distinct kept, PR-lifecycle collapsed)\n' >&2

# ============ steward watermark migration at cutover (issue #198) ===============
# Before the split there was ONE shared watermark. On the first tick after the daemon
# upgrade, the steward channel must INHERIT the old shared watermark (bridge_<slug>.
# since) rather than seed to NOW — else a steward wake that was queued under the old
# mark (steward busy at cutover) is skipped forever. Set ONLY the worker .since to an
# old time, remove ONLY .steward.since, and a newer steward wake must still deliver.
# Keep the seen files present-empty so bridge_state_file dual-reads the flat path
# (issue #181); .steward.since ABSENT is what triggers the migration under test.
rm -rf "$WORK/conf/fleets/fake/bridge" 2>/dev/null
: > "$WORK/state/bridge_fake-repo.seen"
: > "$WORK/state/bridge_fake-repo.steward.seen"
rm -f "$WORK/state/bridge_fake-repo.steward.since"
printf '2026-07-09T03:00:00Z\n' > "$WORK/state/bridge_fake-repo.since"   # old SHARED mark
cat > "$CANNED" <<JSON
[
 {"id":800,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/20","updated_at":"2026-07-09T03:00:05Z","body":"queued under the old shared mark"}
]
JSON
: > "$INJECT"
FLEET_STEWARD_ISSUE=20 runbridge --poll || fail "migration poll exited non-zero"
grep -qF 'queued under the old shared mark' "$INJECT" \
  || fail "migration: a steward wake under the OLD shared watermark must be inherited, not seed-to-now-skipped"
# end-to-end proof it processed: the inherited-then-delivered wake is marked seen.
grep -qxF 800 "$SSEEN" 2>/dev/null \
  || fail "migration: the inherited-and-delivered wake must be marked seen"
printf 'selftest: watermark-migration leg PASS (steward channel inherits the old shared mark)\n' >&2

# ============ steward-issue resolver: no cross-fleet leak (issue #146/#180) =====
# bridge_steward_issue_for_repo must map a repo → its OWN FLEET_STEWARD_ISSUE and
# NEVER inherit another fleet's value (the subtle bug where a conf-sourcing subshell
# inherits the global). All fleets are equal (issue #180 — the PRIMARY_* snapshot +
# short-circuit are gone), so EVERY fleet — including what used to be the "primary" —
# is just a per-fleet <session>.conf. Extract the real function body and exercise it
# against those confs.
RES_CONF="$WORK/resconf"; mkdir -p "$RES_CONF"
printf 'FLEET_REPO="me/alpha"\nFLEET_ISSUE_BRIDGE=1\nFLEET_STEWARD_ISSUE=20\n' > "$RES_CONF/alpha.conf"
printf 'FLEET_REPO="me/other"\nFLEET_ISSUE_BRIDGE=1\n' > "$RES_CONF/other.conf"
printf 'FLEET_REPO="me/beta"\nFLEET_ISSUE_BRIDGE=1\nFLEET_STEWARD_ISSUE=77\n' > "$RES_CONF/beta.conf"
(
  set -uo pipefail
  . "$BIN/fleet-lib.sh"
  FLEET_CONF_DIR="$RES_CONF"
  : "$FLEET_CONF_DIR"  # read via the eval below (opaque to shellcheck)
  eval "$(awk '/^bridge_steward_issue_for_repo\(\) \{/,/^}/' "$SRC")"
  [ "$(bridge_steward_issue_for_repo me/alpha)" = 20 ] || { echo "resolver: me/alpha should resolve its OWN 20" >&2; exit 1; }
  [ -z "$(bridge_steward_issue_for_repo me/other)" ]   || { echo "resolver: me/other (no own issue) must NOT inherit another fleet's (cross-fleet leak)" >&2; exit 1; }
  [ "$(bridge_steward_issue_for_repo me/beta)" = 77 ]  || { echo "resolver: me/beta should resolve its OWN 77" >&2; exit 1; }
  [ -z "$(bridge_steward_issue_for_repo me/nope)" ]    || { echo "resolver: unknown repo should be empty" >&2; exit 1; }
) || fail "steward-issue resolver leaked / mis-resolved across fleets"
# A conf that sets FLEET_STEWARD_ISSUE but NOT its own FLEET_REPO must be ignored,
# not mis-attributed to another fleet's repo: me/alpha must keep its own 20, never
# the rogue conf's 99.
printf 'FLEET_ISSUE_BRIDGE=1\nFLEET_STEWARD_ISSUE=99\n' > "$RES_CONF/norepo.conf"
(
  set -uo pipefail
  . "$BIN/fleet-lib.sh"
  FLEET_CONF_DIR="$RES_CONF"
  : "$FLEET_CONF_DIR"
  eval "$(awk '/^bridge_steward_issue_for_repo\(\) \{/,/^}/' "$SRC")"
  [ "$(bridge_steward_issue_for_repo me/alpha)" = 20 ] \
    || { echo "resolver: a repo-less conf's steward issue must NOT clobber another fleet's" >&2; exit 1; }
) || fail "steward-issue resolver mis-attributed a repo-less conf across fleets"
printf 'selftest: resolver leg PASS (no cross-fleet steward-issue leak, no primary)\n' >&2

# --- per-fleet state layout (issue #181): bridge_state_file must resolve the dedup/
# watermark to fleets/<sess>/bridge/{seen,since} when the slug maps to a configured
# fleet, dual-read a legacy flat file in place, and fall back to the flat
# issue-bridge/ path only when no fleet owns the slug. Unit-test the resolver
# directly (extract the real functions), so it's deterministic w.r.t. the fakes.
(
  set -uo pipefail
  # shellcheck source=/dev/null
  . "$BIN/fleet-lib.sh"
  FLEET_CONF_DIR="$WORK/conf"; STATE="$WORK/state"
  : "$FLEET_CONF_DIR" "$STATE"   # read via the eval'd functions below (opaque to shellcheck)
  rm -rf "$WORK/conf/fleets" "$WORK/state"
  printf 'FLEET_REPO="fake/repo"\nFLEET_ISSUE_BRIDGE=1\n' > "$WORK/conf/fake.conf"
  eval "$(awk '/^bridge_sess_for_slug\(\) \{/,/^}/' "$SRC")"
  eval "$(awk '/^bridge_state_file\(\) \{/,/^}/'   "$SRC")"
  _BR_SLUG=''; _BR_SESS=''
  got=$(bridge_state_file fake-repo seen)
  [ "$got" = "$WORK/conf/fleets/fake/bridge/seen" ] \
    || { echo "layout: bridge_state_file should resolve to fleets/<sess>/bridge/ (got $got)" >&2; exit 1; }
  # dual-read: a legacy flat file present is returned in place (until the migrator moves it)
  mkdir -p "$WORK/state"; : > "$WORK/state/bridge_fake-repo.since"; _BR_SLUG=''; _BR_SESS=''
  gots=$(bridge_state_file fake-repo since)
  [ "$gots" = "$WORK/state/bridge_fake-repo.since" ] \
    || { echo "layout: a legacy flat file must be dual-read in place (got $gots)" >&2; exit 1; }
  # a slug with NO configured fleet → flat issue-bridge/ fallback
  rm -f "$WORK/conf/fake.conf"; rm -rf "$WORK/conf/fleets"; _BR_SLUG=''; _BR_SESS=''
  gotn=$(bridge_state_file other-repo seen)
  [ "$gotn" = "$WORK/state/bridge_other-repo.seen" ] \
    || { echo "layout: an unconfigured slug must fall to the flat path (got $gotn)" >&2; exit 1; }
) || fail "per-fleet bridge state layout (issue #181) resolution wrong"
printf 'selftest: layout leg PASS (per-fleet bridge state under fleets/<sess>/bridge/ + dual-read + flat fallback — issue #181)\n' >&2

printf 'selftest PASS: relay core + idle-gate + input-content-gate + ghost-detect + max-typing-defer + dedup + HMAC (+fail-closed) + steward-route (relay/busy/stale/cold/hub-down/typing/no-config) + resolver-no-leak + per-fleet-layout verified\n'
exit 0
