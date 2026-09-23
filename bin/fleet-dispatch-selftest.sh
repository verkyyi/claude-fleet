#!/bin/bash
# fleet-dispatch-selftest.sh — hermetic smoke test for bin/fleet-dispatch.sh.
#
# Asserts the dispatcher's core contract (issues #70, #421) against a FAKE gh +
# tmux (no network, no tmux server, no real spawns):
#   • LABEL GATE       ONLY issues carrying the `autofill` label are eligible — a
#                      high-priority issue WITHOUT the label is never spawned
#                      (issue #421: autofill is opt-in per issue, not whole-backlog).
#   • PRIORITY ORDER   priority:p0 spawns before p1 before unlabeled.
#   • RATE-LIMIT       at most min(headroom, MAX_PER_TICK) spawns per tick.
#   • PER-FLEET CAP    FLEET_MAX_SESSIONS bounds the fill independent of global.
#   • ELIGIBILITY      assigned / blocked issues are never
#                      spawned even when they carry `autofill`. (Assigned is also
#                      the cross-machine pre-filter for issue #258: with
#                      FLEET_PRESPAWN_DEDUP the spawn claims AT SPAWN, so a peer's
#                      claim shows as an assignee → the "claimed elsewhere" skip.)
#   • MULTI-REPO       (#799) every armed hosted repo dispatches, with --repo,
#                      under the fleet's one cap + tick budget, per-repo lease.
#   • ANTI-COLLISION   an issue with a live window is skipped even if it is the
#                      highest-priority pick — matched by @issue binding AND by a
#                      bare "issue-<N>" window name (dash-issue-session's own dedup).
#
# The scenario: one fleet "s1" running two workers — issue-10 (bound via @issue)
# and issue-15 (slug-named window, @issue cleared) — cap 5, 2 spawns/tick.
# Backlog (all p0 unless noted; `autofill` unless noted):
#   #10 live via @issue, #15 live via slug name, #20 p1, #25 p0 NO autofill,
#   #30 p0 assigned, #35 p0 blocked, #50 autofill-only.
# Live count = 2 → slots = min(6,3,2)=2.
# Expected spawns, in order: #20 (p1) then #50 (unlabeled tier) — every eligible
# p0 is live / assigned / blocked / un-opted-in, so the two
# free slots fall to the next tiers.
#
# Needs `jq` (the fake gh applies the dispatcher's real --jq filter through it) —
# SKIPs cleanly if jq is absent, so it never fails a jq-less box.
#
# Exit 0 = pass. Non-zero = fail (prints the captured log + spawn record).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-dispatch.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }

if ! command -v jq >/dev/null 2>&1; then
  printf 'selftest: jq not installed — SKIP (the fake gh needs it to apply --jq)\n' >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fd-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf" "$WORK/leases"
SPAWN_LOG="$WORK/spawns"; : > "$SPAWN_LOG"
CANNED="$WORK/issues.json"

# The dispatcher + lib run from $WORK/bin so BIN resolves the fake spawn + gate
# scripts sitting next to them (both are invoked as "$BIN/<name>").
cp "$SRC" "$WORK/bin/fleet-dispatch.sh"
cp "$BIN/fleet-lib.sh" "$WORK/bin/fleet-lib.sh"
chmod +x "$WORK/bin/fleet-dispatch.sh"

# --- fake dash-issue-session.sh: record "<num>" per spawn, never really spawn ---
cat > "$WORK/bin/dash-issue-session.sh" <<FAKE
#!/bin/bash
printf '%s\n' "\$1" >> "$SPAWN_LOG"
exit 0
FAKE
chmod +x "$WORK/bin/dash-issue-session.sh"

# --- fake fleet-diskguard.sh: gate always open ---
cat > "$WORK/bin/fleet-diskguard.sh" <<'FAKE'
#!/bin/bash
[ "${1:-}" = --gate ] && exit 0
exit 0
FAKE
chmod +x "$WORK/bin/fleet-diskguard.sh"

# --- fake gh: only `issue list … --jq <expr>`, applied to $CANNED via real jq ---
cat > "$WORK/fakepath/gh" <<FAKE
#!/bin/bash
expr=''
while [ "\$#" -gt 0 ]; do
  case "\$1" in --jq) shift; expr="\$1" ;; esac
  shift
done
[ -n "\$expr" ] && jq -r "\$expr" "$CANNED"
exit 0
FAKE
chmod +x "$WORK/fakepath/gh"

# --- fake tmux: answers the three list-windows forms the dispatcher/lib use ----
# s1 owns plan/dash/backlog hubs + two worker windows: issue-10 (@issue=10) and
# issue-15 (slug-named, @issue cleared). Check @issue FIRST — the @issue form's
# -F string also contains window_name. A literal tab separates the @issue form.
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
args="$*"
case "$args" in
  *'@issue'*)     printf '%b' "\tplan\n\tdash\n\tbacklog\n10\tissue-10\n\tissue-15\n" ;;  # @issue<tab>name
  *session_name*) printf 's1 plan\ns1 dash\ns1 backlog\ns1 issue-10\ns1 issue-15\n' ;;    # global count
  *window_name*)  printf 'plan\ndash\nbacklog\nissue-10\nissue-15\n' ;;                    # one session
  *)              : ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

# --- per-fleet conf: autofill ON, per-fleet cap 5, 2 spawns/tick ---
cat > "$WORK/conf/s1.conf" <<CONF
FLEET_REPO="fake/repo"
FLEET_AUTOFILL=1
FLEET_MAX_SESSIONS=5
FLEET_GLOBAL_MAX_SESSIONS=8
FLEET_AUTOFILL_MAX_PER_TICK=2
CONF

# --- canned backlog ---
cat > "$CANNED" <<'JSON'
[
  {"number":10,"labels":[{"name":"priority:p0"},{"name":"autofill"}],"assignees":[]},
  {"number":15,"labels":[{"name":"priority:p0"},{"name":"autofill"}],"assignees":[]},
  {"number":20,"labels":[{"name":"priority:p1"},{"name":"autofill"}],"assignees":[]},
  {"number":25,"labels":[{"name":"priority:p0"}],"assignees":[]},
  {"number":30,"labels":[{"name":"priority:p0"},{"name":"autofill"}],"assignees":[{"login":"someone"}]},
  {"number":35,"labels":[{"name":"priority:p0"},{"name":"autofill"},{"name":"blocked"}],"assignees":[]},
  {"number":50,"labels":[{"name":"autofill"}],"assignees":[]}
]
JSON

# --- run ----------------------------------------------------------------------
LOG="$WORK/log"
PATH="$WORK/fakepath:$PATH" \
FLEET_CONF_DIR="$WORK/conf" \
FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
  bash "$WORK/bin/fleet-dispatch.sh" s1 >"$WORK/stdout" 2>"$LOG" || {
    printf 'selftest: dispatcher exited non-zero\n' >&2; cat "$LOG" >&2; exit 1;
  }

got=$(tr '\n' ' ' < "$SPAWN_LOG" | sed 's/ *$//')
want="20 50"

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- log ---\n' >&2; cat "$LOG" >&2
         printf -- '--- spawns: [%s] want [%s] ---\n' "$got" "$want" >&2; exit 1; }

[ "$got" = "$want" ] || fail "spawn set/order wrong"

# defence-in-depth explicit assertions (redundant with the exact match, but they
# pin the WHY if the match ever drifts):
grep -qxF 20 "$SPAWN_LOG" || fail "#20 (p1, autofill) should have spawned"
grep -qxF 50 "$SPAWN_LOG" || fail "#50 (autofill, no priority) should have spawned as the 2nd slot"
grep -qxF 10 "$SPAWN_LOG" && fail "#10 has a live @issue window — must NOT spawn"
grep -qxF 15 "$SPAWN_LOG" && fail "#15 has a live issue-15 window (slug) — must NOT spawn"
grep -qxF 25 "$SPAWN_LOG" && fail "#25 lacks the autofill label (not opted in, #421) — must NOT spawn"
grep -qxF 30 "$SPAWN_LOG" && fail "#30 is assigned (== claimed elsewhere, #258) — must NOT spawn"
grep -qxF 35 "$SPAWN_LOG" && fail "#35 is blocked (autofill-excluded even with the label) — must NOT spawn"

# --- #563: a worker PARKED on Claude Code's trust dialog is reported, once, as `needs` ---
# The fake tmux now also answers the sweep's list-windows form (matched FIRST — its
# -F string contains `@issue` too) and capture-pane per window. Four windows show
# the dialog text on screen; only @1 qualifies: issue-bound, @claude_state EMPTY
# (no hook ever fired — the parked signature), not yet reported. @2 is a live
# worker whose screen merely contains the words (a worker editing the fix itself),
# @3 is a panel, @4 was already reported last tick.
TMUX_LOG="$WORK/tmuxlog"; : > "$TMUX_LOG"
cat > "$WORK/fakepath/tmux" <<FAKE
#!/bin/bash
args="\$*"
case "\$args" in
  *set-window-option*) printf '%s\n' "\$args" >> "$TMUX_LOG" ;;   # first: its argv names @trust_stuck too
  *trust_stuck*)  printf '%b' "@1\t10\t\t\tissue-10\n@2\t15\tworking\t\tissue-15\n@3\t\t\t\tplan\n@4\t20\t\t1\tissue-20\n" ;;
  *capture-pane*) printf ' Accessing workspace:\n /Users/x/proj-issue-N\n Quick safety check: Is this a project you created or one you trust?\n ❯ 1. Yes, I trust this folder\n   2. No, exit\n' ;;
  *'@issue'*)     printf '%b' "\tplan\n\tdash\n\tbacklog\n10\tissue-10\n\tissue-15\n" ;;
  *session_name*) printf 's1 plan\ns1 dash\ns1 backlog\ns1 issue-10\ns1 issue-15\n' ;;
  *window_name*)  printf 'plan\ndash\nbacklog\nissue-10\nissue-15\n' ;;
  *)              : ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"
: > "$SPAWN_LOG"; LOG2="$WORK/log2"
PATH="$WORK/fakepath:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
  bash "$WORK/bin/fleet-dispatch.sh" s1 >/dev/null 2>"$LOG2" || { printf 'selftest: dispatcher (sweep run) exited non-zero\n' >&2; cat "$LOG2" >&2; exit 1; }
fail2() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- log ---\n' >&2; cat "$LOG2" >&2; printf -- '--- tmux ---\n' >&2; cat "$TMUX_LOG" >&2; exit 1; }
[ "$(grep -c 'PARKED at Claude Code' "$LOG2")" = 1 ] || fail2 "#563 exactly ONE parked worker must be logged"
grep -q '#10 (issue-10, @1) is PARKED' "$LOG2" || fail2 "#563 the log line must name the issue, window and id"
grep -q 'fleet-trust.sh grant --main' "$LOG2" || fail2 "#563 the log line must carry the fix"
grep -q 'set-window-option -t @1 @claude_state needs' "$TMUX_LOG" || fail2 "#563 the parked window must be stamped needs (red on the dash)"
grep -q 'set-window-option -t @1 @trust_stuck 1' "$TMUX_LOG" || fail2 "#563 the parked window must be marked reported (once-only)"
grep -q -- '-L s1 set-window-option -t @1' "$TMUX_LOG" || fail2 "#563 stamps must go to THIS fleet's socket (-L <session>)"
grep -q -- '-t @2 ' "$TMUX_LOG" && fail2 "#563 a LIVE worker (@claude_state set) must never be flagged for words on its screen"
grep -q -- '-t @3 ' "$TMUX_LOG" && fail2 "#563 a panel (no @issue) must never be flagged"
grep -q -- '-t @4 ' "$TMUX_LOG" && fail2 "#563 an already-reported window must not be re-stamped"
grep -qxF 20 "$SPAWN_LOG" || fail2 "#563 the sweep must not change what gets spawned (slot stays counted, dispatch proceeds)"
# --dry-run never stamps anything
: > "$TMUX_LOG"
PATH="$WORK/fakepath:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
  bash "$WORK/bin/fleet-dispatch.sh" --dry-run s1 >/dev/null 2>"$WORK/log3"
grep -q 'PARKED' "$WORK/log3" && fail2 "#563 --dry-run must not sweep"
[ -s "$TMUX_LOG" ] && fail2 "#563 --dry-run must not stamp windows"

# --- #683: a refusal's REASON reaches the log, and its CLASS decides skip-vs-stop ---
# The real spawn prints its reason on stderr and exits 2 (at capacity) / 3
# (claimed elsewhere) / 1 (infra). The fake now does the same per issue number:
# #20 is claimed (a peer won the race) → the dispatcher must SKIP it and go on to
# #50, which spawns; the log names the reason, not a generic "cap/dup race".
cat > "$WORK/bin/dash-issue-session.sh" <<FAKE
#!/bin/bash
case "\$1" in
  20) printf 'dash-issue-session: #20 already claimed elsewhere (assigned) — not spawning; --force overrides a stale claim\n' >&2; exit 3 ;;
esac
printf '%s\n' "\$1" >> "$SPAWN_LOG"
exit 0
FAKE
: > "$SPAWN_LOG"; : > "$TMUX_LOG"; LOG4="$WORK/log4"
PATH="$WORK/fakepath:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
  bash "$WORK/bin/fleet-dispatch.sh" s1 >/dev/null 2>"$LOG4" || { printf 'selftest: dispatcher (claimed run) exited non-zero\n' >&2; cat "$LOG4" >&2; exit 1; }
fail4() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- log ---\n' >&2; cat "$LOG4" >&2; printf -- '--- spawns ---\n' >&2; cat "$SPAWN_LOG" >&2; exit 1; }
grep -qxF 20 "$SPAWN_LOG" && fail4 "#683 the claimed issue must not count as spawned"
grep -qxF 50 "$SPAWN_LOG" || fail4 "#683 a CLAIMED refusal (exit 3) takes the issue, not the slot — the tick must go on to #50"
grep -q 'skip #20 (p1) — #20 already claimed elsewhere (assigned)' "$LOG4" || fail4 "#683 the log must carry the spawn's stderr reason for the skip"
grep -q 'cap/dup race' "$LOG4" && fail4 "#683 the generic 'cap/dup race' guess must be gone — the reason is known now"

# Capacity and infrastructure failures stop the tick. Log every attempt so the
# test catches trying #50 even if that second failure produces no useful output.
cat > "$WORK/bin/dash-issue-session.sh" <<FAKE
#!/bin/bash
printf '%s\n' "\$1" >> "$SPAWN_LOG"
printf 'stdout-must-not-enter-the-log\n'
printf 'dash-issue-session: %s\n' "\$SPAWN_REASON" >&2
exit "\$SPAWN_RC"
FAKE
for spawn_rc in 2 1; do
  reason='fleet at capacity (2/2 sessions) — not spawning'
  [ "$spawn_rc" = 1 ] && reason='spawn failed for #20: new-window'
  : > "$SPAWN_LOG"; LOG5="$WORK/log5"
  PATH="$WORK/fakepath:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
  SPAWN_RC="$spawn_rc" SPAWN_REASON="$reason" \
    bash "$WORK/bin/fleet-dispatch.sh" s1 >/dev/null 2>"$LOG5" || { cat "$LOG5" >&2; fail "dispatcher refusal run exited non-zero"; }
  [ "$(cat "$SPAWN_LOG")" = 20 ] || fail "#683 rc=$spawn_rc must stop after the first attempt"
  grep -qF "spawn of #20 refused (rc=$spawn_rc: $reason) — stop this tick" "$LOG5" \
    || { cat "$LOG5" >&2; fail "#683 log must retain both class and stderr reason"; }
  grep -q 'stdout-must-not-enter-the-log' "$LOG5" && fail "#683 capture stderr only"
done

# #730: one Claude quota measurement, applied only to Claude fleets. Check both
# iteration orders so a held first fleet cannot abort dispatch for the second.
cat > "$WORK/bin/fleet-quotaguard.sh" <<FAKE
#!/bin/sh
printf 'gate\n' >> "$WORK/quota-calls"
echo 'Claude quota hold' >&2
exit 3
FAKE
chmod +x "$WORK/bin/fleet-quotaguard.sh"
cp "$WORK/conf/s1.conf" "$WORK/conf/s2.conf"
printf 'FLEET_AGENT=codex\n' >> "$WORK/conf/s2.conf"
cat > "$WORK/bin/dash-issue-session.sh" <<FAKE
#!/bin/sh
printf '%s %s\n' "\$1" "\$2" >> "$SPAWN_LOG"
FAKE
for order in 's1 s2' 's2 s1'; do
  : > "$SPAWN_LOG"; : > "$WORK/quota-calls"
  # shellcheck disable=SC2086  # deliberate: two fleet names
  PATH="$WORK/fakepath:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
    bash "$WORK/bin/fleet-dispatch.sh" $order >/dev/null 2>"$LOG2" || fail2 "mixed-agent dispatch failed"
  [ "$(cat "$SPAWN_LOG")" = "$(printf '20 s2\n50 s2')" ] \
    || fail2 "Claude quota must hold s1 while Codex s2 still spawns (order: $order)"
  [ "$(wc -l < "$WORK/quota-calls" | tr -d ' ')" = 1 ] \
    || fail2 "the shared quota measurement must run only once per tick"
  grep -q 's1: Claude quota gate closed' "$LOG2" || fail2 "quota log must name the held Claude fleet"
done
printf 'ok   Claude quota holds only Claude fleets, independent of dispatch order\n'
# The native Codex gate is separately opt-in and receives this fleet overlay.
cat > "$WORK/bin/fleet-codex-account.sh" <<FAKE
#!/bin/sh
[ "\$*" = 'gate --session s2' ] || exit 9
printf 'Codex native quota hold\n'
exit 1
FAKE
chmod +x "$WORK/bin/fleet-codex-account.sh"
printf 'FLEET_CODEX_QUOTA_GATE=1\n' >> "$WORK/conf/s2.conf"
: > "$SPAWN_LOG"
PATH="$WORK/fakepath:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
  bash "$WORK/bin/fleet-dispatch.sh" s2 >/dev/null 2>"$LOG2" || fail2 'Codex gate run failed'
[ ! -s "$SPAWN_LOG" ] || fail2 'native Codex hold must block Codex autofill'
grep -q 's2: Codex quota gate closed.*Codex native quota hold' "$LOG2" || fail2 'native quota reason missing'

# --- #799: a multi-repo fleet autofills EVERY armed repo, under ONE pair of caps ---
# Fleet m hosts o/a (the fleet conf, FLEET_AUTOFILL=1), o/b (overlay, inherits the
# fleet's 1) and o/c (overlay, FLEET_AUTOFILL=0 — opted out). One live worker,
# o/a#10; fleet cap 4 → 3 free slots. The fake gh answers per --repo. Merged order:
# within a tier the repos interleave least-loaded first (o/a has 1 live, o/b 0), so
# o/b#11, o/b#13, o/a#11 — and o/a#12 waits for the cap, o/c#7 is never touched.
rm -f "$WORK/bin/fleet-quotaguard.sh"   # the #730 leg's closed gate
MC="$WORK/mconf"; mkdir -p "$MC/fleets/m/repos"
cat > "$MC/fleets/m/conf" <<CONF
FLEET_REPO="o/a"
FLEET_AUTOFILL=1
FLEET_MAX_SESSIONS=4
FLEET_GLOBAL_MAX_SESSIONS=0
FLEET_AUTOFILL_MAX_PER_TICK=9
CONF
printf 'FLEET_REPO="o/b"\n' > "$MC/fleets/m/repos/o-b.conf"
printf 'FLEET_REPO="o/c"\nFLEET_AUTOFILL=0\n' > "$MC/fleets/m/repos/o-c.conf"
mkdir -p "$WORK/canned"
printf '%s' '[{"number":10,"labels":[{"name":"autofill"}],"assignees":[]},
 {"number":11,"labels":[{"name":"autofill"}],"assignees":[]},
 {"number":12,"labels":[{"name":"autofill"}],"assignees":[]}]' > "$WORK/canned/o-a.json"
printf '%s' '[{"number":11,"labels":[{"name":"autofill"}],"assignees":[]},
 {"number":13,"labels":[{"name":"autofill"}],"assignees":[]},
 {"number":14,"labels":[],"assignees":[]}]' > "$WORK/canned/o-b.json"
printf '%s' '[{"number":7,"labels":[{"name":"autofill"}],"assignees":[]}]' > "$WORK/canned/o-c.json"
GH_LOG="$WORK/ghlog"; : > "$GH_LOG"
cat > "$WORK/fakepath/gh" <<FAKE
#!/bin/bash
expr=''; repo=''
while [ "\$#" -gt 0 ]; do
  case "\$1" in --jq) shift; expr="\$1" ;; --repo) shift; repo="\$1" ;; esac
  shift
done
printf '%s\n' "\$repo" >> "$GH_LOG"
[ -n "\$expr" ] && jq -r "\$expr" "$WORK/canned/\$(printf '%s' "\$repo" | tr / -).json"
exit 0
FAKE
# One live worker, o/a#10 (@1). Match the lib's forms before the generic ones.
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
args="$*"
case "$args" in
  *set-window-option*|*trust_stuck*|*capture-pane*) : ;;
  *'@repo'*)       case "$args" in *'-t @1 '*) printf 'o/a||\n' ;; *) printf '||\n' ;; esac ;;
  *'window_id}|'*) printf '@0||plan\n@1|10|issue-10\n' ;;
  *'@issue'*)      printf '%b' "\tplan\n10\tissue-10\n" ;;
  *session_name*)  printf 'm plan\nm issue-10\n' ;;
  *window_name*)   printf 'plan\nissue-10\n' ;;
  *)               : ;;
esac
exit 0
FAKE
cat > "$WORK/bin/dash-issue-session.sh" <<FAKE
#!/bin/bash
printf '%s\n' "\$*" >> "$SPAWN_LOG"
exit 0
FAKE
LOG6="$WORK/log6"
run_m() { PATH="$WORK/fakepath:$PATH" FLEET_CONF_DIR="$MC" FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
            bash "$WORK/bin/fleet-dispatch.sh" "$@" m >/dev/null 2>"$LOG6"; }
fail6() { printf 'selftest FAIL: #799 %s\n' "$1" >&2; printf -- '--- log ---\n' >&2; cat "$LOG6" >&2
          printf -- '--- spawns ---\n' >&2; cat "$SPAWN_LOG" >&2; exit 1; }
: > "$SPAWN_LOG"
run_m || fail6 'dispatcher exited non-zero'
[ "$(cat "$SPAWN_LOG")" = "$(printf '11 m --repo o/b --origin autofill\n13 m --repo o/b --origin autofill\n11 m --repo o/a --origin autofill')" ] \
  || fail6 'labelled issues in BOTH repos must dispatch, interleaved, each with its own --repo, capped at the fleet headroom (3)'
grep -q 'skip o/a#10 (p3) — window already bound' "$LOG6" || fail6 'a live o/a#10 must be skipped by (repo, N)'
grep -q 'spawned o/b#11 (p3) --repo o/b' "$LOG6" || fail6 'the log must name the repo and the --repo it spawned with'
grep -q 'm: o/c: autofill off' "$LOG6" || fail6 'a repo whose overlay sets FLEET_AUTOFILL=0 is skipped, and says so'
grep -qx 'o/c' "$GH_LOG" && fail6 'an opted-out repo must cost no gh call'
ls "$WORK/leases" | grep -q 'dispatch-' && fail6 'every per-repo lease must be released on exit'
# The per-tick budget is the FLEET's, not per repo: 1/tick → exactly one spawn.
: > "$SPAWN_LOG"
sed -i.bak 's/^FLEET_AUTOFILL_MAX_PER_TICK=9$/FLEET_AUTOFILL_MAX_PER_TICK=1/' "$MC/fleets/m/conf"
run_m || fail6 'per-tick run exited non-zero'
[ "$(wc -l < "$SPAWN_LOG" | tr -d ' ')" = 1 ] || fail6 'MAX_PER_TICK bounds the whole fleet, not each repo'
sed -i.bak 's/^FLEET_AUTOFILL_MAX_PER_TICK=1$/FLEET_AUTOFILL_MAX_PER_TICK=9/' "$MC/fleets/m/conf"
# A repo whose lease another dispatcher holds sits the tick out; the others go on.
mkdir -p "$WORK/leases/dispatch-o-b.lock"
printf 'someone-else\n%s\n' "$(( $(date +%s) + 600 ))" > "$WORK/leases/dispatch-o-b.lock/holder"
: > "$SPAWN_LOG"
run_m || fail6 'lease run exited non-zero'
grep -q -- '--repo o/b' "$SPAWN_LOG" && fail6 'o/b is leased elsewhere — it must not spawn'
grep -q '^11 m --repo o/a' "$SPAWN_LOG" || fail6 "o/a must still dispatch while o/b's lease is held"
grep -q 'm: o/b: another dispatcher holds the lease' "$LOG6" || fail6 'the held lease must be logged per repo'
[ "$(sed -n 1p "$WORK/leases/dispatch-o-b.lock/holder")" = someone-else ] || fail6 "never release another holder's lease"
rm -rf "$WORK/leases/dispatch-o-b.lock"
# Fleet off, one overlay on: only that repo autofills.
sed -i.bak 's/^FLEET_AUTOFILL=1$/FLEET_AUTOFILL=0/' "$MC/fleets/m/conf"
printf 'FLEET_AUTOFILL=1\n' >> "$MC/fleets/m/repos/o-b.conf"
: > "$SPAWN_LOG"
run_m || fail6 'overlay-only run exited non-zero'
[ "$(cut -d' ' -f1-4 "$SPAWN_LOG" | tr '\n' ' ')" = '11 m --repo o/b 13 m --repo o/b ' ] \
  || fail6 'fleet FLEET_AUTOFILL=0 + o/b overlay =1 → only o/b dispatches'
printf 'ok   multi-repo: every armed repo dispatches with --repo under one fleet cap + tick budget; per-repo opt-out and lease (#799)\n'


printf 'selftest PASS: spawned [%s] in priority order — label-gated, under caps + eligibility + anti-collision; a trust-dialog-parked worker is reported once as needs (#563); a refusal logs its stderr reason and exit 3 skips / exit 2 stops (#683)\n' "$got"
exit 0
