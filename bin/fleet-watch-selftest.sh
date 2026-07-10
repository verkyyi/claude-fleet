#!/bin/bash
# fleet-watch-selftest.sh — hermetic smoke test for bin/fleet-watch.sh (issue #147).
#
# Drives the watcher against a FAKE tmux + FAKE fleet-comment.sh + FAKE diskguard
# (no network, no tmux server, no real steward wake) and asserts its CORE contract:
#   • ZERO-TOKEN     the watcher issues no gh reads (there is no fake gh at all — a
#                    single gh call would fail `command -v gh` in the sealed PATH).
#   • FIRST-RUN SEED the very first tick seeds the keyset SILENTLY — an already-green
#                    PR at enable-time must NOT flood the steward with backfill.
#   • EDGE WAKE      a PR that goes green AFTER the seed produces exactly ONE wake,
#                    delivered to the steward issue via fleet-comment.sh --to-worker.
#   • DEDUP          the SAME green condition on the next tick produces NO new wake.
#
# Scenario: fleet "s1" (repo fake/repo → slug fake-repo), one worker window bound to
# issue #42 on branch issue-42 with an OPEN PR #100. @prci is read from $WORK/prci so
# the test can flip the CI glyph between ticks. Autofill is ON in the conf purely to
# SUPPRESS the slotfree event, isolating the PR-green edge under test.
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
printf '%s\n' "\$body" >> "$WAKE_LOG"
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

# --- fake tmux: answers every list-windows form the watcher + lib use ----------
# The big US-separated scan carries one worker (s1, issue-42, branch path, @prci read
# from $WORK/prci) plus a 'plan' hub row so s1 registers as a fleet. `tmux info`→0.
cat > "$WORK/fakepath/tmux" <<FAKE
#!/bin/bash
args="\$*"
US=\$(printf '\037')
prci=\$(cat "$WORK/prci" 2>/dev/null)
case "\$args" in
  info*) exit 0 ;;
  *@prci*pane_current_path*)   # the watcher's big scan
    printf 's1%splan%s%s%s%s%s%s%s%s/w/plan\n'      "\$US" "\$US" "\$US" "\$US" "\$US" "\$US" "\$US" "\$US" "\$US"
    printf 's1%s@1%sissue-42%s42%sworking%s%s%s/w/issue-42\n' "\$US" "\$US" "\$US" "\$US" "\$US" "\$prci" "\$US"
    ;;
  *'session_name'*'window_name'*)  # fleet_session_count / fleet_hub_sessions (space-sep)
    printf 's1 plan\ns1 issue-42\n' ;;
  *window_name*)                   # fleet_session_count_for s1
    printf 'plan\nissue-42\n' ;;
  *) : ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

# --- caches (what the collector + pr-refresh would have written) ---------------
printf 's1\tfake-repo\tfake/repo\n' > "$C/sessmap"
# git_<key> for /w/issue-42 — cache_key(/w/issue-42): '/'→_s, so "_sw_sissue-42".
# The branch carries a "+N" ahead suffix (a PR branch is always ahead of base, so
# the collector stamps it) — the watcher/pr-refresh strip only the +ahead/-behind
# tail, leaving "issue-42" to match the prmap headRefName.
key=$(printf '%s' "/w/issue-42" | sed -e 's/_/_u/g' -e 's|/|_s|g' -e 's/ /_w/g')
printf 'issue-42+3\tclean\n' > "$C/git_$key"
# prmap: branch issue-42 → OPEN PR #100 (ci/ready columns unused by the watcher —
# it reads the live @prci glyph from tmux, not this ci field).
printf 'issue-42\t#100\tOPEN\t…\t\n' > "$C/prmap_fake-repo"
: > "$C/prmap_fake-repo.ts"
printf 'Week 1\t#42\tverkyyi\tthe worker issue\n' > "$C/issues_fake-repo"
printf '42\t\n' > "$C/labels_fake-repo"

# --- conf: watch ON, steward issue #999, autofill ON (suppresses slotfree) -----
cat > "$WORK/conf/s1.conf" <<'CONF'
FLEET_REPO="fake/repo"
FLEET_WATCH=1
FLEET_STEWARD_ISSUE=999
FLEET_AUTOFILL=1
FLEET_GLOBAL_MAX_SESSIONS=8
CONF

run() { # $1 = @prci glyph for this tick, $2 = log file
  printf '%s' "$1" > "$WORK/prci"
  TMPDIR="$WORK" \
  PATH="$WORK/fakepath:$PATH" \
  FLEET_CONF_DIR="$WORK/conf" \
  FLEET_WATCH_STATE_DIR="$WORK/state" \
  FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
    bash "$WORK/bin/fleet-watch.sh" s1 >>"$2" 2>&1
}

fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- log ---\n' >&2; cat "$WORK/log" 2>/dev/null >&2
         printf -- '--- wakes (%s post(s)) ---\n' "$(nwakes)" >&2; cat "$WAKE_LOG" >&2
         exit 1; }

# Count wake POSTS (not lines): each post is a multi-line comment led by one header.
nwakes() { grep -c 'fleet-watch — ' "$WAKE_LOG" 2>/dev/null || true; }  # grep -c already prints 0

: > "$WORK/log"

# tick 1 — PR OPEN but CI still running ("…"): SEED, no wake.
run "…" "$WORK/log"
[ "$(wc -l < "$WAKE_LOG")" -eq 0 ] || fail "first run must SEED silently (0 wakes), got $(wc -l < "$WAKE_LOG")"
grep -q 'first run — seeded' "$WORK/log" || fail "first run should log a seed line"

# tick 2 — PR goes green (@prci="✓") but the WAKE POST FAILS: the edge must NOT be
# marked seen, so no state advance and it will retry (review finding #1).
touch "$WORK/fail_wake"
run "✓" "$WORK/log"
[ "$(nwakes)" -eq 0 ] || fail "wake post failed — nothing should be recorded"
grep -q 'state NOT advanced' "$WORK/log" || fail "a failed wake should log that state was not advanced"
grep -qxF 'prgreen:fake-repo:100' "$WORK/state/watch_fake-repo.keys" \
  && fail "a FAILED wake must NOT persist the prgreen key (else it never retries)"

# tick 3 — still green, wake now SUCCEEDS: the retried edge fires exactly once.
rm -f "$WORK/fail_wake"
run "✓" "$WORK/log"
n=$(grep -c 'green — /land' "$WAKE_LOG")
[ "$n" -eq 1 ] || fail "retried PR-green must produce exactly ONE green wake, got $n"
grep -q 'PR #100 (#42) green — /land 100?' "$WAKE_LOG" || fail "green wake body/format wrong"
grep -q 'shipped PR #100' "$WAKE_LOG" && fail "propened was seeded — must not re-wake"

# tick 4 — still green: DEDUP, no additional wake.
before=$(nwakes)
run "✓" "$WORK/log"
after=$(nwakes)
[ "$after" -eq "$before" ] || fail "persistent green must NOT re-wake (dedup); wakes $before -> $after"

# tick 5 — CI regresses to "✗": prgreen clears from the keyset (no wake for a loss).
run "✗" "$WORK/log"
grep -qxF 'prgreen:fake-repo:100' "$WORK/state/watch_fake-repo.keys" \
  && fail "prgreen should clear from the keyset once the PR is no longer green"

# tick 6 — PR goes green again but BEHIND base (@prci="✓↑", the common active-fleet
# glyph): prgreen must fire again, with the behind-base message (finding #2).
before=$(nwakes)
run "✓↑" "$WORK/log"
after=$(nwakes)
[ "$after" -eq "$((before + 1))" ] || fail "a decorated green (✓↑) must fire prgreen; wakes $before -> $after"
grep -q 'PR #100 (#42) green (behind base) — /land 100?' "$WAKE_LOG" \
  || fail "behind-base green wake body/format wrong"

printf 'selftest PASS: seed → failed-wake-retry → one green wake → dedup → clear → decorated-green re-fires\n'
exit 0
