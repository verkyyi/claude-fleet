#!/bin/bash
# fleet-webhook-selftest.sh — hermetic tests for bin/fleet-webhook.sh (issue #315).
# No gh, no tmux, no network: the targeted refreshers and the `gh webhook forward`
# launcher are stubbed via the daemon's env seams (FLEET_PR_REFRESH_CMD /
# FLEET_ISSUES_REFRESH_CMD / FLEET_WH_FORWARD_CMD), and deliveries are fed to
# `--route` on stdin.
#
# Asserts the issue's verification contract:
#   • ROUTING     pull_request/check_run/check_suite/status → pr-refresh --repo <repo>;
#                 issues → collect --issues <repo>; unknown event → no kick. RIGHT repo.
#   • NO WRITE    the --route path NEVER writes prmap/issues itself (it invokes the
#                 single-writer owner, stubbed here → no cache files appear).
#   • HMAC        with a secret set, a bad X-Hub-Signature-256 is refused (no kick);
#                 a correct one passes.
#   • SELECTION   --desired lists opted-in repos, DEDUPED; FLEET_WEBHOOK=0 → excluded.
#   • RECONCILE   one forward per desired repo; a killed forward is restarted next
#                 pass; a repo that opts out has its forward reaped.
#
# python3 is required by --route (HMAC + JSON extraction), matching the daemon; if it
# is absent the whole test SKIPs cleanly (exit 0), per the runner convention.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WH="$BIN/fleet-webhook.sh"
[ -f "$WH" ] || { printf 'selftest: %s not found\n' "$WH" >&2; exit 2; }

if ! command -v python3 >/dev/null 2>&1; then
  printf 'fleet-webhook-selftest: python3 absent — SKIP\n' >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-webhook-selftest.XXXXXX")" || exit 2
cleanup() {
  # kill any fake forwards this test spawned (unique path → safe), then the dir.
  local p
  for p in "$WORK"/state*/forwards/*.pid "$WORK"/rstate/forwards/*.pid; do
    [ -f "$p" ] || continue
    kill "$(cat "$p" 2>/dev/null)" 2>/dev/null || :
  done
  pkill -f "$WORK/fakefwd.sh" 2>/dev/null || :
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# Isolate every env knob the daemon reads (a stray value from the caller's shell
# must never bleed into the assertions).
unset FLEET_WEBHOOK FLEET_WEBHOOK_PORT FLEET_WEBHOOK_SECRET FLEET_WEBHOOK_EVENTS \
      FLEET_WEBHOOK_RESCAN FLEET_DELIVERY_SIG 2>/dev/null || :

pass=0
ok()   { pass=$((pass+1)); }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq()   { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; ok; }

# A recorder stub standing in for a targeted refresher: append its argv to $REC.
REC="$WORK/rec.log"
cat > "$WORK/recorder.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$REC"
EOF
chmod +x "$WORK/recorder.sh"

# route DELIVERY_JSON EVENT [SECRET] [SIG] — feed one delivery to --route with the
# recorders wired in, into a FRESH state dir + cache TMPDIR (debounce off).
route() {
  local body="$1" event="$2" secret="${3:-}" sig="${4:-}" sd
  sd="$WORK/rt.$RANDOM.$RANDOM"; mkdir -p "$sd/cache"
  printf '%s' "$body" | \
    TMPDIR="$sd/cache" \
    FLEET_WEBHOOK_DEBOUNCE=0 \
    FLEET_WEBHOOK_STATE_DIR="$sd/state" \
    FLEET_WEBHOOK_SECRET="$secret" \
    FLEET_DELIVERY_SIG="$sig" \
    FLEET_PR_REFRESH_CMD="$WORK/recorder.sh" \
    FLEET_ISSUES_REFRESH_CMD="$WORK/recorder.sh" \
    bash "$WH" --route --event "$event" >/dev/null 2>&1
  # export for the NO-WRITE assertion (the caller inspects this cache dir)
  LAST_CACHE="$sd/cache"
}

PR_BODY='{"repository":{"full_name":"acme/widgets"},"pull_request":{"number":42}}'
ISS_BODY='{"repository":{"full_name":"acme/widgets"},"issue":{"number":7}}'
CR_BODY='{"repository":{"full_name":"acme/widgets"},"check_run":{"id":9}}'
ST_BODY='{"repository":{"full_name":"acme/widgets"},"state":"success"}'

# --- ROUTING ----------------------------------------------------------------
: > "$REC"; route "$PR_BODY" pull_request
eq 'pull_request → pr-refresh --repo' "$(cat "$REC")" '--repo acme/widgets'
: > "$REC"; route "$CR_BODY" check_run
eq 'check_run → pr-refresh --repo'    "$(cat "$REC")" '--repo acme/widgets'
: > "$REC"; route "$ST_BODY" status
eq 'status → pr-refresh --repo'       "$(cat "$REC")" '--repo acme/widgets'
: > "$REC"; route "$PR_BODY" check_suite     # check_suite reuses the PR-shaped body fine
eq 'check_suite → pr-refresh --repo'  "$(cat "$REC")" '--repo acme/widgets'
: > "$REC"; route "$ISS_BODY" issues
eq 'issues → collect --issues'        "$(cat "$REC")" '--issues acme/widgets'
: > "$REC"; route "$PR_BODY" workflow_run     # not in our event set
eq 'unknown event → no kick'          "$(cat "$REC")" ''
: > "$REC"; route "$PR_BODY" ping              # ping is a no-op ack
eq 'ping → no kick'                   "$(cat "$REC")" ''

# right repo, not a hardcoded one
: > "$REC"; route '{"repository":{"full_name":"other/proj"},"pull_request":{"number":1}}' pull_request
eq 'routes the payload repo'          "$(cat "$REC")" '--repo other/proj'

# --- NO DIRECT CACHE WRITE --------------------------------------------------
# The route path invokes the (stubbed) owner and must not itself write prmap/issues.
: > "$REC"; route "$PR_BODY" pull_request
n=$(find "$LAST_CACHE" -type f \( -name 'prmap*' -o -name 'issues*' \) 2>/dev/null | wc -l | tr -d ' ')
eq 'route writes NO cache itself' "$n" 0
: > "$REC"; route "$ISS_BODY" issues
n=$(find "$LAST_CACHE" -type f \( -name 'prmap*' -o -name 'issues*' \) 2>/dev/null | wc -l | tr -d ' ')
eq 'route (issues) writes NO cache itself' "$n" 0

# --- HMAC -------------------------------------------------------------------
SIG_GOOD="sha256=$(printf '%s' "$PR_BODY" | python3 -c '
import sys,hmac,hashlib
print(hmac.new(b"topsecret", sys.stdin.buffer.read(), hashlib.sha256).hexdigest())')"
: > "$REC"; route "$PR_BODY" pull_request topsecret "sha256=deadbeef"
eq 'HMAC bad signature → refused (no kick)' "$(cat "$REC")" ''
: > "$REC"; route "$PR_BODY" pull_request topsecret "$SIG_GOOD"
eq 'HMAC good signature → kicks'            "$(cat "$REC")" '--repo acme/widgets'

# --- SELECTION (--desired): opt-in filter + dedup ---------------------------
CD="$WORK/conf"; mkdir -p "$CD/fleets/alpha" "$CD/fleets/beta" "$CD/fleets/gamma" "$CD/fleets/delta"
printf 'FLEET_REPO=acme/widgets\nFLEET_WEBHOOK=1\n' > "$CD/fleets/alpha/conf"
printf 'FLEET_REPO=acme/widgets\nFLEET_WEBHOOK=1\n' > "$CD/fleets/beta/conf"   # same repo → dedup
printf 'FLEET_REPO=acme/gadgets\nFLEET_WEBHOOK=0\n' > "$CD/fleets/gamma/conf"  # opted out
printf 'FLEET_REPO=acme/gizmos\nFLEET_WEBHOOK=1\n'  > "$CD/fleets/delta/conf"
desired=$(FLEET_CONF_DIR="$CD" bash "$WH" --desired alpha beta gamma delta 2>/dev/null | sort | tr '\n' ' ')
eq 'desired = opted-in, deduped, no opt-outs' "$desired" 'acme/gizmos acme/widgets '

# --- RECONCILE: start / restart / reap --------------------------------------
cat > "$WORK/fakefwd.sh" <<'EOF'
#!/bin/sh
exec sleep 600
EOF
chmod +x "$WORK/fakefwd.sh"
RST="$WORK/rstate"
recon() { FLEET_CONF_DIR="$CD" FLEET_WEBHOOK_STATE_DIR="$RST" FLEET_WH_FORWARD_CMD="$WORK/fakefwd.sh" \
            bash "$WH" --reconcile alpha beta gamma delta >/dev/null 2>&1; }

recon
nf=$(find "$RST/forwards" -name '*.pid' 2>/dev/null | wc -l | tr -d ' ')
eq 'one forward per opted-in repo (deduped)' "$nf" 2
[ -f "$RST/forwards/acme-widgets.pid" ] || fail 'no forward pidfile for acme-widgets'; ok
[ -f "$RST/forwards/acme-gizmos.pid" ]  || fail 'no forward pidfile for acme-gizmos'; ok
wp=$(cat "$RST/forwards/acme-widgets.pid")
kill -0 "$wp" 2>/dev/null || fail 'widgets forward not alive after reconcile'; ok

# kill it → next reconcile restarts (new pid, alive)
kill "$wp" 2>/dev/null; for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$wp" 2>/dev/null || break; done
recon
wp2=$(cat "$RST/forwards/acme-widgets.pid")
[ "$wp2" != "$wp" ] || fail 'reconcile did not restart the killed forward (pid unchanged)'; ok
kill -0 "$wp2" 2>/dev/null || fail 'restarted forward not alive'; ok

# opt delta out → its forward is reaped next reconcile
gp=$(cat "$RST/forwards/acme-gizmos.pid")
printf 'FLEET_REPO=acme/gizmos\nFLEET_WEBHOOK=0\n' > "$CD/fleets/delta/conf"
recon
[ -f "$RST/forwards/acme-gizmos.pid" ] && fail 'opted-out repo still has a forward pidfile'; ok
kill -0 "$gp" 2>/dev/null && fail 'opted-out forward process still alive'; ok

printf 'selftest PASS: %d assertions (routing · no-write · HMAC · selection · reconcile)\n' "$pass"
exit 0
