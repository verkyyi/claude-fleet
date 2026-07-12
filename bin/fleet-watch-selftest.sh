#!/bin/bash
# fleet-watch-selftest.sh — hermetic smoke test for bin/fleet-watch.sh (issue #147),
# trimmed to the post-landing edge set (issue #279: only stuck / needs-rise / prod-alert
# remain — the PR-green, worker-opened-PR and free-slot edges were removed once landing
# retired in #277).
#
# Drives the watcher against a FAKE tmux + FAKE fleet-comment.sh + FAKE diskguard
# (no network, no tmux server, no real steward wake) and asserts its CORE contract:
#   • ZERO-TOKEN       the watcher issues no gh reads (there is no fake gh at all — a
#                      single gh call would fail `command -v gh` in the sealed PATH).
#   • FIRST-RUN SEED   the very first tick seeds the keyset SILENTLY — nothing firing at
#                      enable-time must NOT flood the steward with backfill.
#   • RETRY ON FAILURE an edge whose wake POST fails is NOT marked seen (persist only
#                      after a successful post), so it retries next tick (finding #1).
#   • EDGE WAKE        a worker that goes `looping` produces exactly ONE wake, delivered
#                      to the steward issue via fleet-comment.sh --to-worker.
#   • DEDUP            the SAME looping condition on the next tick produces NO new wake.
#   • CLEAR            when the worker recovers the stuck key clears (no wake for a loss).
#   • PROD-ALERT       a new prod-alert-labelled issue fires a first-response wake.
#   • NEEDS RISE       the needs-attention count rising fires a "N need attention" wake.
#
# Scenario: fleet "s1" (repo fake/repo → slug fake-repo), a 'plan' hub + one worker
# window bound to issue #42 whose @claude_state run() flips between ticks; the
# labels_<slug> cache carries #42's labels (run() flips prod-alert on/off).
#
# Exit 0 = pass. Non-zero = fail (prints the captured logs + wake record).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-watch.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fw-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf" "$WORK/leases" "$WORK/state"
C="$WORK/.claude-dash"; mkdir -p "$C"
WAKE_LOG="$WORK/wakes"; : > "$WAKE_LOG"

cp "$SRC" "$WORK/bin/fleet-watch.sh"
cp "$BIN/fleet-lib.sh" "$WORK/bin/fleet-lib.sh"
chmod +x "$WORK/bin/fleet-watch.sh"

# --- fake fleet-comment.sh: record the wake body; FAIL when $WORK/fail_wake exists
# (so the test can exercise the persist-only-after-successful-post retry path) -----
cat > "$WORK/bin/fleet-comment.sh" <<FAKE
#!/bin/bash
[ -f "$WORK/fail_wake" ] && exit 1
body=''
while [ "\$#" -gt 0 ]; do case "\$1" in --body) shift; body="\${1:-}";; esac; shift; done
# One delimiter line per post so nwakes() counts POSTS independently of the body
# format (issue #224 retired the "🛰️ fleet-watch — <slug>" header this used to key on).
printf '<<<wake-post>>>\n%s\n' "\$body" >> "$WAKE_LOG"
exit 0
FAKE
chmod +x "$WORK/bin/fleet-comment.sh"

# --- fake fleet-diskguard.sh: gate always open ---------------------------------
cat > "$WORK/bin/fleet-diskguard.sh" <<'FAKE'
#!/bin/bash
[ "${1:-}" = --gate ] && exit 0
exit 0
FAKE
chmod +x "$WORK/bin/fleet-diskguard.sh"

# --- fake tmux: answers `info` and the watcher's big US-separated window scan.
# The scan rows come from $WORK/scan (rewritten each tick by write_scan) so the test
# can flip @claude_state between ticks. PR state is no longer read (issue #279), so the
# scan carries no PR columns. `tmux info`→0 (server "up").
cat > "$WORK/fakepath/tmux" <<FAKE
#!/bin/bash
args="\$*"
case "\$args" in
  info*) exit 0 ;;
  *@claude_state*@raw*) cat "$WORK/scan" ;;   # the watcher's big worker scan
  *) : ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

# --- caches (what the collector would have written) ----------------------------
printf 's1\tfake-repo\tfake/repo\n' > "$C/sessmap"

# --- conf: watch ON, steward issue #999 ----------------------------------------
cat > "$WORK/conf/s1.conf" <<'CONF'
FLEET_REPO="fake/repo"
FLEET_WATCH=1
FLEET_STEWARD_ISSUE=999
CONF

US=$(printf '\037')
# Window scan: a 'plan' hub (name=plan → skipped) + a worker on issue #42. Fields
# (US-separated): session · window_id · window_name · @issue · @claude_state · @raw.
write_scan() { # $1 = worker @claude_state
  {
    printf '%s\n' "s1${US}@0${US}plan${US}${US}${US}"
    printf '%s\n' "s1${US}@1${US}issue-42${US}42${US}${1}${US}"
  } > "$WORK/scan"
}
# labels_<slug>: #42's label list ($1 = comma-separated labels, may be empty).
write_labels() { printf '42\t%s\n' "$1" > "$C/labels_fake-repo"; }

run() { # $1 = worker state, $2 = #42 labels, $3 = log file
  write_scan "$1"
  write_labels "$2"
  TMPDIR="$WORK" \
  PATH="$WORK/fakepath:$PATH" \
  FLEET_CONF_DIR="$WORK/conf" \
  FLEET_WATCH_STATE_DIR="$WORK/state" \
  FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
    bash "$WORK/bin/fleet-watch.sh" s1 >>"$3" 2>&1
}

fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- log ---\n' >&2; cat "$WORK/log" 2>/dev/null >&2
         printf -- '--- wakes (%s post(s)) ---\n' "$(nwakes)" >&2; cat "$WAKE_LOG" >&2
         exit 1; }

# Count wake POSTS (not lines): the fake recorder writes one <<<wake-post>>> delimiter
# per post, so this is robust to the multi-line body (the per-role footer is added by
# the real fleet-comment.sh, which is faked out here — issue #224).
nwakes() { grep -c '<<<wake-post>>>' "$WAKE_LOG" 2>/dev/null || true; }  # grep -c already prints 0

KEYS="$WORK/conf/fleets/s1/watch/keys"
: > "$WORK/log"

# tick 1 — worker WORKING, no prod-alert: nothing firing → SEED silently, 0 wakes.
run "working" "" "$WORK/log"
[ "$(nwakes)" -eq 0 ] || fail "first run must SEED silently (0 wakes), got $(nwakes)"
grep -q 'first run — seeded' "$WORK/log" || fail "first run should log a seed line"

# tick 2 — worker goes LOOPING but the WAKE POST FAILS: the edge must NOT be marked
# seen, so no state advance and it will retry (review finding #1).
touch "$WORK/fail_wake"
run "looping" "" "$WORK/log"
[ "$(nwakes)" -eq 0 ] || fail "wake post failed — nothing should be recorded"
grep -q 'state NOT advanced' "$WORK/log" || fail "a failed wake should log that state was not advanced"
grep -qxF 'stuck:fake-repo:42' "$KEYS" 2>/dev/null \
  && fail "a FAILED wake must NOT persist the stuck key (else it never retries)"

# tick 3 — still looping, wake now SUCCEEDS: the retried edge fires exactly once.
rm -f "$WORK/fail_wake"
run "looping" "" "$WORK/log"
n=$(grep -c 'looks stuck' "$WAKE_LOG")
[ "$n" -eq 1 ] || fail "retried stuck edge must produce exactly ONE wake, got $n"
grep -q '#42 looks stuck (looping) — investigate?' "$WAKE_LOG" || fail "stuck wake body/format wrong"
# coalescing marker (issue #198): the wake stamps its per-line subject so the
# issue-bridge can collapse superseded wakes on drain. Each edge kind is its own
# distinct subject (the PR-lifecycle shared subject was removed with the PR edges).
grep -qF '<!-- fleet:wake stuck:fake-repo:42 -->' "$WAKE_LOG" \
  || fail "stuck wake must stamp the stuck:<slug>:<iss> coalescing subject marker"

# tick 4 — still looping: DEDUP, no additional wake.
before=$(nwakes)
run "looping" "" "$WORK/log"
after=$(nwakes)
[ "$after" -eq "$before" ] || fail "persistent stuck must NOT re-wake (dedup); wakes $before -> $after"

# tick 5 — worker recovers to WORKING: the stuck key clears (no wake for a loss).
before=$(nwakes)
run "working" "" "$WORK/log"
after=$(nwakes)
[ "$after" -eq "$before" ] || fail "a cleared stuck must NOT wake; wakes $before -> $after"
grep -qxF 'stuck:fake-repo:42' "$KEYS" 2>/dev/null \
  && fail "stuck should clear from the keyset once the worker recovers"

# tick 6 — #42 gains the prod-alert label: prodalert fires a first-response wake.
before=$(nwakes)
run "working" "prod-alert" "$WORK/log"
after=$(nwakes)
[ "$after" -eq "$((before + 1))" ] || fail "a new prod-alert issue must fire prodalert; wakes $before -> $after"
grep -q 'prod-alert #42 filed — first-response?' "$WAKE_LOG" || fail "prodalert wake body/format wrong"

# tick 7 — prod-alert clears AND the worker goes to NEEDS: needs rises 0→1 (one wake);
# the prodalert key clears with no wake for the loss → exactly ONE new wake, the rise.
before=$(nwakes)
run "needs" "" "$WORK/log"
after=$(nwakes)
[ "$after" -eq "$((before + 1))" ] || fail "a needs-attention RISE must fire exactly one wake; wakes $before -> $after"
grep -q '1 window(s) need attention' "$WAKE_LOG" || fail "needs-rise wake body/format wrong"

printf 'selftest PASS: seed → failed-wake-retry → stuck wake → dedup → clear → prod-alert → needs-rise\n'
exit 0
