#!/bin/bash
# dash-migrate-selftest.sh — the dash's migrate key (⌃l, issue #873).
#
# bin/dash-migrate.sh is the tap-first front of `fleet-migrate.sh --force-bg`:
# its popup shows fleet-migrate's OWN dry-run and only a `y` dispatches the real
# move. Pinned here, on a DEDICATED tmux server (-L label, never the live one)
# with a fake fleet-migrate that logs its argv:
#   1. a header / landed row is a silent no-op;
#   2. a window with no Claude process is refused — no dry-run, no move;
#   3. the popup prints the plan (target account + the background commands) and
#      `y` dispatches `--session <fleet> --force-bg --toast <window-id>` detached;
#   4. `n` cancels — the dry-run ran, the move did not;
#   5. a plan with no move (every account benched, #567) offers no `y` at all.
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
fail() { printf 'dash-migrate selftest FAIL: %s\n' "$1" >&2; exit 1; }
command -v tmux >/dev/null 2>&1 && command -v perl >/dev/null 2>&1 \
  || { echo 'dash-migrate selftest: OK (tmux/perl absent — skipped)'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-migrate-selftest.XXXXXX")" || exit 2
LBL="dmtest-$$-$RANDOM"
TM() { tmux -L "$LBL" "$@"; }
cleanup() { tmux -L "$LBL" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT; trap 'exit 130' INT TERM HUP

ln -s "$(command -v perl)" "$WORK/claude"
cat > "$WORK/fake-migrate" <<EOS
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/calls"
if [ "\${1:-}" = whoami ]; then echo acctA; exit 0; fi
case " \$* " in
  *' --dry-run '*)
    if [ -n "\${FAKE_NOMOVE:-}" ]; then echo "  – w (@x): nowhere to move (acctA → acctA, benched too) — skipped"
    else echo "  ↻ w (@x) [acctA → acctB] would /exit pid 1 and resume abc… in /w"
         echo "    would stop 1 background command(s):"; echo "      4242  npm run dev  (cwd /w/web)"; fi ;;
esac
EOS
chmod +x "$WORK/fake-migrate"
export FLEET_DASH_MIGRATE_BIN="$WORK/fake-migrate"
cat > "$WORK/fake-manual-sub" <<'EOS'
#!/bin/bash
case "$1" in
  list) printf 'Account\t5h\t7d\tStatus\nacctA\t10%%\t20%%\tavailable\nacctB\t3%%\t89%%\tmanual confirmation (above 85%% auto limit)\nacctC\t1%%\t95%%\tat 95%% limit\n' ;;
  check) case "$3" in acctB) echo 'manual sub: acctB  5h 3% · 7d 89% — manual confirmation (above 85% auto limit)' ;; *) echo 'manual sub: target unavailable' >&2; exit 1 ;; esac ;;
esac
EOS
chmod +x "$WORK/fake-manual-sub"
export FLEET_DASH_MANUAL_SUB_BIN="$WORK/fake-manual-sub"

TM new-session -d -s "$LBL" -n dash 'sleep 600' || fail "isolated server"
wc=$(TM new-window -d -t "$LBL": -n worker -P -F '#{window_id}' "$WORK/claude -e 'sleep 600'") || fail "claude window"
wn=$(TM new-window -d -t "$LBL": -n plain -P -F '#{window_id}' 'sleep 600') || fail "plain window"
sleep 1
SP=$(TM display-message -p '#{socket_path}')
run() { env TMUX="$SP,0,0" bash "$BIN/dash-migrate.sh" "$@" 2>&1; }

# 1. no-op rows
: > "$WORK/calls"
run hdr >/dev/null; run 'landed:abc' >/dev/null; run '' >/dev/null
[ ! -s "$WORK/calls" ] || fail "a header/landed/empty row must be a no-op: $(cat "$WORK/calls")"

# 2. no Claude under the pane
run "$wn" confirm >/dev/null
[ ! -s "$WORK/calls" ] || fail "a window without Claude must be refused before any dry-run: $(cat "$WORK/calls")"

# 3. y → the plan is shown, the real move is dispatched detached
out=$(FLEET_DASH_MIGRATE_ANSWER=y run "$wc" confirm)
printf '%s' "$out" | grep -q 'acctA → acctB' || fail "the popup must show the target account: $out"
printf '%s' "$out" | grep -q 'npm run dev' || fail "the popup must list the background commands: $out"
printf '%s' "$out" | grep -q '\[y\] migrate' || fail "the popup must offer y: $out"
grep -q -- "--session $LBL --dry-run --force-bg $wc" "$WORK/calls" || fail "the popup must show fleet-migrate's own --force-bg dry-run: $(cat "$WORK/calls")"
for _ in $(seq 1 30); do grep -q -- '--toast' "$WORK/calls" && break; sleep 0.2; done
grep -qx -- "--session $LBL --force-bg --toast $wc" "$WORK/calls" || fail "y must dispatch --force-bg --toast <window-id>: $(cat "$WORK/calls")"

# 4. n → cancelled
: > "$WORK/calls"
FLEET_DASH_MIGRATE_ANSWER=n run "$wc" confirm >/dev/null; sleep 1
grep -q -- '--dry-run' "$WORK/calls" || fail "n: the dry-run still shows"
! grep -q -- '--toast' "$WORK/calls" || fail "n must not move anything: $(cat "$WORK/calls")"

# 5. no move available → no y offered, nothing dispatched
: > "$WORK/calls"
out=$(FAKE_NOMOVE=1 FLEET_DASH_MIGRATE_ANSWER=y run "$wc" confirm); sleep 1
printf '%s' "$out" | grep -q 'No move available' || fail "a refused plan must say so: $out"
! printf '%s' "$out" | grep -q '\[y\] migrate' || fail "a refused plan must offer no y: $out"
! grep -q -- '--toast' "$WORK/calls" || fail "a refused plan must dispatch nothing: $(cat "$WORK/calls")"

# 6. Sidebar picker shows quotas, pins the chosen target in both preview and move.
: > "$WORK/calls"
out=$(FLEET_DASH_MIGRATE_TARGET=acctB FLEET_DASH_MIGRATE_ANSWER=y run "$wc" choose-confirm)
printf '%s' "$out" | grep -q '7d 89%' || fail "picker must show live quota: $out"
printf '%s' "$out" | grep -q 'manual confirmation' || fail "picker must disclose the 85–95% exception: $out"
grep -q -- "--target-account acctB --dry-run --force-bg $wc" "$WORK/calls" || fail "picker preview must pin chosen account: $(cat "$WORK/calls")"
for _ in $(seq 1 30); do grep -q -- '--target-account acctB --force-bg --toast' "$WORK/calls" && break; sleep 0.2; done
grep -q -- "--target-account acctB --force-bg --toast $wc" "$WORK/calls" || fail "picker move must pin chosen account: $(cat "$WORK/calls")"

# 7. Same-source and blocked choices must never preview or move.
: > "$WORK/calls"
FLEET_DASH_MIGRATE_TARGET=acctA FLEET_DASH_MIGRATE_ANSWER=y run "$wc" choose-confirm >/dev/null
! grep -q -- '--dry-run' "$WORK/calls" || fail "same account must not preview"
: > "$WORK/calls"
FLEET_DASH_MIGRATE_TARGET=acctC FLEET_DASH_MIGRATE_ANSWER=y run "$wc" choose-confirm >/dev/null
! grep -q -- '--dry-run' "$WORK/calls" || fail "95% target must not preview"

echo 'dash-migrate selftest: OK'
