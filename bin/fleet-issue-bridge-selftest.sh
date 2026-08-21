#!/bin/bash
# fleet-issue-bridge-selftest.sh — hermetic smoke test for bin/fleet-issue-bridge.sh.
#
# Asserts the bridge's relay contract (issue #132) against a FAKE gh + tmux (no
# network, no tmux server, no real injection):
#   • RELAY          a trusted comment on an IDLE bound worker is injected once.
#   • MARKER         a body carrying `<!-- fleet:no-relay -->` is SUPPRESSED.
#   • SELF (#425)    an OWNER comment carrying `<!-- fleet:from role=worker
#                    issue=<N> -->` on issue N (a worker's own comment that skipped
#                    the no-relay wrapper) is SUPPRESSED — the positive self-ID
#                    backstop, so it is never relayed back into that worker. A
#                    role=worker marker with NO issue= field is also suppressed
#                    (#483, unattributable), while a DIFFERENT issue= (genuine
#                    cross-worker mail) still relays.
#   • ASSOCIATION    a NONE/CONTRIBUTOR comment is SUPPRESSED (the RCE gate).
#   • IDLE-GATE      a comment on a WORKING worker is QUEUED (not injected) and
#                    the watermark holds it for retry — while a LATER comment on
#                    an idle worker still relays (low-water-mark, no head-of-line).
#   • DEDUP          re-running relays nothing already handled.
#   • HMAC (--deliver) a correctly-signed delivery injects; a bad signature does
#                    NOT (and exits non-zero).
#
# The scenario (repo fake/repo): worker windows for #10 (idle=done) and #11
# (working). Comments, ascending: c100 #10 OWNER→relay, c101 #10 marker→suppress,
# c102 #10 NONE→suppress, c103 #11 OWNER→queued(busy), c104 #10 COLLABORATOR→relay,
# c105 #10 OWNER+fleet:from-role=worker-issue=10→suppress(self), c106 #10
# OWNER+fleet:from-role=worker-NO-issue=→suppress(self, issue #483), c107 #10
# OWNER+fleet:from-role=worker-issue=11→relay (cross-worker). Expected injections
# after one poll: exactly three, all into #10 (c100, c104, c107).
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
cat > "$WORK/fakepath/tmux" <<FAKE
#!/bin/bash
# real tmux accepts a global -L/-S <socket> before the subcommand; each fleet now
# runs on its own named socket (issue #159), so fleet_sockets + the injectors
# prepend one. Strip it so the dispatch below still sees the verb in \$1.
if [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; then shift 2; fi
args="\$*"
case "\$1" in
  info) [ -n "\$FAKE_TMUX_DOWN" ] && exit 1; exit 0 ;;
  # fleet_sockets liveness probe (issue #159): mirror info's down-switch so the
  # "tmux down" test also makes fleet_sockets empty (the poll gate keys off it).
  has-session) [ -n "\$FAKE_TMUX_DOWN" ] && exit 1; exit 0 ;;
  list-windows)
    case "\$args" in
      *@claude_state*) printf 's1\t@1\tdone\t10\ns1\t@2\tworking\t11\n' ;;
      *window_name*)   printf 's1 plan\ns1 dash\n' ;;
    esac
    exit 0 ;;
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
# Each fleet is a conf named after its session/socket (issue #159): fleet_sockets
# keys the socket off the conf BASENAME (not its repo), so this makes the "s1"
# fleet discoverable. FLEET_REPO="" (explicitly empty) OVERRIDES the ambient
# FLEET_REPO in the conf-sourcing subshell, so bridge_sess_for_slug does NOT
# resolve fake-repo→s1 — the bridge's per-fleet state (issue #181) therefore stays
# on the legacy flat path this test asserts. (bridge_find_window still resolves the
# window via the global FLEET_REPO env, which the resolver falls through to.)
printf 'FLEET_REPO=""\n' > "$WORK/conf/s1.conf"

# --- canned comments (ascending updated_at) ------------------------------------
MARK='<!-- fleet:no-relay -->'
cat > "$CANNED" <<JSON
[
 {"id":100,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T00:00:01Z","body":"please do X"},
 {"id":101,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T00:00:02Z","body":"record only $MARK"},
 {"id":102,"author_association":"NONE","user":{"login":"rando"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T00:00:03Z","body":"sneaky rm -rf"},
 {"id":103,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/11","updated_at":"2026-07-09T00:00:04Z","body":"for the busy one"},
 {"id":104,"author_association":"COLLABORATOR","user":{"login":"pal"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T00:00:05Z","body":"another instruction"},
 {"id":105,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T00:00:06Z","body":"worker self note, no no-relay flag\n\n<!-- fleet:from role=worker session=fake-repo issue=10 -->"},
 {"id":106,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T00:00:07Z","body":"unattributable worker note, no issue field\n\n<!-- fleet:from role=worker session=fake-repo -->"},
 {"id":107,"author_association":"OWNER","user":{"login":"boss"},"issue_url":"https://api.github.com/repos/fake/repo/issues/10","updated_at":"2026-07-09T00:00:08Z","body":"cross-worker instruction from eleven\n\n<!-- fleet:from role=worker session=fake-repo issue=11 -->"}
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

# exactly three Enter submissions (one per relayed comment: c100, c104, c107)
enters=$(grep -c 'send-keys -t @1 Enter' "$INJECT" 2>/dev/null || echo 0)
[ "$enters" = 3 ] || fail "expected 3 injections into @1, got $enters"
# the two relayed bodies are present, the suppressed/queued ones are not
grep -qF 'please do X' "$INJECT"        || fail "c100 (OWNER, idle) should relay"
grep -qF 'another instruction' "$INJECT" || fail "c104 (COLLABORATOR, idle) should relay"
grep -qF 'record only' "$INJECT"    && fail "c101 (no-relay marker) must be suppressed"
grep -qF 'sneaky' "$INJECT"         && fail "c102 (NONE assoc) must be suppressed"
grep -qF 'for the busy one' "$INJECT" && fail "c103 (worker WORKING) must be queued, not injected"
# c105 carries `<!-- fleet:from role=worker issue=10 -->` on ITS OWN issue (#10) but
# NO no-relay flag — the self-authored backstop (issue #425) must suppress it, so a
# worker comment that skipped fleet-comment.sh isn't relayed back into itself. It is
# OWNER (passes the assoc gate), proving it's the self-ID check — not the gate — that
# stops it. Without the backstop it would be a THIRD injection into @1.
grep -qF 'worker self note' "$INJECT" && fail "c105 (self-authored, fleet:from issue=10) must be suppressed"
# c106 is `role=worker` with NO issue= field (issue #483): unattributable — it can't
# prove it is NOT the bound worker's own comment, so it must be suppressed. c107 is
# genuine cross-worker mail (`role=worker issue=11` on issue #10 — worker 11 driving
# worker 10) and must still RELAY — proving the #483 hardening keys on the MISSING
# field, not on role=worker itself.
grep -qF 'unattributable worker note' "$INJECT" && fail "c106 (role=worker, no issue= field) must be suppressed (issue #483)"
grep -qF 'cross-worker instruction from eleven' "$INJECT" || fail "c107 (cross-worker, issue=11 → #10) must relay"

# seen set: relayed+suppressed are recorded; the queued (busy) one is NOT.
SEEN="$WORK/state/bridge_fake-repo.seen"
for id in 100 101 102 104 105 106 107; do grep -qxF "$id" "$SEEN" || fail "c$id should be marked seen"; done
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
ghost_expect deliver "${G}[2mThe operator will land it via gh pr merge${G}[0m"  '2 2' "bare dim \\e[2m…\\e[0m"
ghost_expect deliver "${G}[2;38;5;244mThe operator will land it${G}[0m"   '2 2' "combined dim+256 \\e[2;38;5;244m"
ghost_expect deliver "${G}[2;90msome gray ghost text${G}[22m"           '2 2' "combined dim+color, \\e[22m off"
ghost_expect deliver "${G}[2m${G}[38;5;244mghost then color${G}[0m"     '2 2' "dim then SEPARATE color SGR"
ghost_expect deliver "${G}[2mghost via bare reset${G}[m"                '2 2' "\\e[m bare-reset terminator"
# DELIVER on the awk fallback ALONE — cursor unresolvable (old tmux / copy-mode),
# so the faint-state parse is the only signal and must still see the ghost as dim:
ghost_expect deliver "${G}[2;38;5;244mThe operator will land it${G}[0m"   ''   "combined dim, NO cursor (awk fallback)"
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

printf 'selftest PASS: relay core + idle-gate + input-content-gate + ghost-detect + max-typing-defer + dedup + HMAC (+fail-closed) + per-fleet-layout verified\n'
exit 0
