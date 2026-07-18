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
  for p in "$WORK"/*state*/forwards/*.pid; do
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

# A no-op stub for a refresher a test does NOT want to observe. The catch-up on
# (re)connect (issue #410) fires PR_REFRESH_CMD + ISSUES_REFRESH_CMD on every
# forward (re)spawn, so tests asserting forward LIFECYCLE (reconcile/reap/backoff)
# rather than the catch-up itself point those seams here to stay hermetic.
NOOP="$WORK/noop.sh"; printf '#!/bin/sh\nexit 0\n' > "$NOOP"; chmod +x "$NOOP"

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
# A no-hooks stub keeps every reconcile pass hermetic: wh_spawn_forward reaps the
# repo's forwarder hook before launching (issue #391), and without this stub that
# would fall through to a real `gh api` call. Empty output ⇒ nothing to reap.
NOHOOKS="$WORK/hooks-none.sh"; printf '#!/bin/sh\nexit 0\n' > "$NOHOOKS"; chmod +x "$NOHOOKS"
recon() { FLEET_CONF_DIR="$CD" FLEET_WEBHOOK_STATE_DIR="$RST" FLEET_WH_FORWARD_CMD="$WORK/fakefwd.sh" \
            FLEET_WH_HOOKS_LIST_CMD="$NOHOOKS" \
            FLEET_PR_REFRESH_CMD="$NOOP" FLEET_ISSUES_REFRESH_CMD="$NOOP" \
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

# --- REAP ORPHANED FORWARDER HOOK (issue #391) ------------------------------
# Before each (re)spawn the daemon lists the repo's hooks and DELETEs any whose
# config.url host is the relay (an orphan a slept host left registered) — leaving a
# user's OWN webhook (different host) untouched. Stub the list + delete gh calls and
# assert exactly the forwarder hook id is deleted.
DELLOG="$WORK/del.log"; : > "$DELLOG"
cat > "$WORK/hooks-list.sh" <<EOF
#!/bin/sh
# id \t active \t last_code \t config_url — a dead forwarder hook + a user's own hook
printf '111\tfalse\t404\thttps://webhook-forwarder.github.com/hook\n'
printf '222\ttrue\t200\thttps://ci.example.com/webhook\n'
EOF
chmod +x "$WORK/hooks-list.sh"
cat > "$WORK/hook-del.sh" <<EOF
#!/bin/sh
echo "\$2" >> "$DELLOG"   # record the deleted hook id (arg 2)
EOF
chmod +x "$WORK/hook-del.sh"
RPST="$WORK/rpstate"
FLEET_CONF_DIR="$CD" FLEET_WEBHOOK_STATE_DIR="$RPST" \
  FLEET_WH_FORWARD_CMD="$WORK/fakefwd.sh" \
  FLEET_WH_HOOKS_LIST_CMD="$WORK/hooks-list.sh" \
  FLEET_WH_HOOK_DEL_CMD="$WORK/hook-del.sh" \
  FLEET_PR_REFRESH_CMD="$NOOP" FLEET_ISSUES_REFRESH_CMD="$NOOP" \
  bash "$WH" --reconcile alpha >/dev/null 2>&1
eq 'reap deletes ONLY the forwarder hook (leaves the user hook)' "$(tr '\n' ' ' < "$DELLOG")" '111 '

# --- RESTART BACKOFF (issue #391) -------------------------------------------
# A forward that keeps dying (a persistent create failure) must back off, not
# hot-loop. We simulate a death by KILLING a long-lived fake forward (and waiting
# for it to reap — a self-exiting fake would linger as a zombie that `kill -0`
# still reports alive). With BASE huge, one recorded death sets a far-future
# deadline, so the next reconcile SKIPS the respawn (pid + fail count unchanged).
BST="$WORK/bstate"
brecon() { FLEET_CONF_DIR="$CD" FLEET_WEBHOOK_STATE_DIR="$BST" FLEET_WH_FORWARD_CMD="$WORK/fakefwd.sh" \
             FLEET_WH_HOOKS_LIST_CMD="$NOHOOKS" FLEET_WH_BACKOFF_BASE=3600 FLEET_WH_BACKOFF_CAP=7200 \
             FLEET_PR_REFRESH_CMD="$NOOP" FLEET_ISSUES_REFRESH_CMD="$NOOP" \
             bash "$WH" --reconcile alpha >/dev/null 2>&1; }
wait_dead() { local n; for n in $(seq 1 40); do kill -0 "$1" 2>/dev/null || return 0; done; }
brecon                                            # pass 1: first spawn (long-lived, alive)
b1=$(cat "$BST/forwards/acme-widgets.pid")
kill "$b1" 2>/dev/null; wait_dead "$b1"           # simulate its death
brecon                                            # pass 2: dead → record death #1, respawn
eq 'first death is counted' "$(cat "$BST/forwards/acme-widgets.fails" 2>/dev/null)" 1
b2=$(cat "$BST/forwards/acme-widgets.pid")
kill "$b2" 2>/dev/null; wait_dead "$b2"           # kill the respawn too
brecon                                            # pass 3: within deadline → SKIP respawn
eq 'backoff skips respawn (pid unchanged)' "$(cat "$BST/forwards/acme-widgets.pid" 2>/dev/null)" "$b2"
eq 'backoff skip does not recount the death'  "$(cat "$BST/forwards/acme-widgets.fails" 2>/dev/null)" 1
# a forward that recovers (seen ALIVE) clears the backoff state, starting fresh.
printf '0' > "$BST/forwards/acme-widgets.until"   # expire the deadline so a respawn is allowed
brecon                                            # deadline past → respawns a live fake, records death #2
brecon                                            # now sees it alive → clears .fails/.until
[ -f "$BST/forwards/acme-widgets.fails" ] && fail 'alive forward did not clear .fails'; ok
[ -f "$BST/forwards/acme-widgets.until" ] && fail 'alive forward did not clear .until'; ok

# --- CATCH-UP COLLECT ON (RE)CONNECT (issue #410) ---------------------------
# Every forward (re)spawn pairs with ONE kick of BOTH single-writers (pr-refresh
# + collect --issues) for that repo, so events missed while it was down (sleep /
# blip — gh webhook forward never replays them) are reconciled the instant it
# returns. Wire the recorders and assert both fire with the right repo on the first
# connect AND again on a restart after a death — and NOT while it's already alive
# (no reconnect ⇒ no catch-up).
CST="$WORK/cstate"; CREC="$WORK/catchup.log"; : > "$CREC"
cat > "$WORK/catchup-rec.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$CREC"
EOF
chmod +x "$WORK/catchup-rec.sh"
crecon() { FLEET_CONF_DIR="$CD" FLEET_WEBHOOK_STATE_DIR="$CST" FLEET_WH_FORWARD_CMD="$WORK/fakefwd.sh" \
             FLEET_WH_HOOKS_LIST_CMD="$NOHOOKS" \
             FLEET_PR_REFRESH_CMD="$WORK/catchup-rec.sh" FLEET_ISSUES_REFRESH_CMD="$WORK/catchup-rec.sh" \
             bash "$WH" --reconcile alpha >/dev/null 2>&1; }
crecon                                            # first connect → catch-up fires
grep -qx -- '--repo acme/widgets'   "$CREC" || fail 'catch-up did not kick pr-refresh on first connect'; ok
grep -qx -- '--issues acme/widgets' "$CREC" || fail 'catch-up did not kick collect --issues on first connect'; ok
: > "$CREC"; crecon                               # forward already alive → NO reconnect, NO catch-up
eq 'no catch-up when forward already alive' "$(cat "$CREC")" ''
cwp=$(cat "$CST/forwards/acme-widgets.pid"); kill "$cwp" 2>/dev/null; wait_dead "$cwp"
: > "$CREC"; crecon                               # restart after a death → catch-up fires again
grep -qx -- '--repo acme/widgets'   "$CREC" || fail 'catch-up did not re-kick pr-refresh on reconnect'; ok
grep -qx -- '--issues acme/widgets' "$CREC" || fail 'catch-up did not re-kick collect on reconnect'; ok

# --- WAKE DETECTION (issue #410) --------------------------------------------
# The supervisor idles in short chunks and infers a host SUSPEND from the gap
# between how long it asked to sleep and how much wall-clock actually passed (bash
# has no monotonic clock). Source the daemon (its dispatch is source-guarded, so a
# source does NOT start the supervisor) to unit-test the pure decision wh_is_wake,
# then drive wh_sleep_or_wake with a scripted clock + an instant fake sleep to prove
# an uneventful idle returns 0 and a simulated suspend returns early (1).
SRCST="$WORK/srcstate"
( FLEET_WEBHOOK_STATE_DIR="$SRCST" FLEET_WEBHOOK_WAKE_SLACK=5 . "$WH" 2>/dev/null
  wh_is_wake 5 6  && exit 20    # +1s jitter, well under slack → NOT wake
  wh_is_wake 5 9  && exit 21    # +4s, still under slack(5) → NOT wake
  wh_is_wake 5 10 || exit 22    # +5s == slack → wake
  wh_is_wake 5 999 || exit 23   # huge gap → wake
  exit 0 )
case $? in
  0)  ok ;;
  20) fail 'wh_is_wake false-fired on +1s jitter' ;;
  21) fail 'wh_is_wake false-fired on +4s jitter' ;;
  22) fail 'wh_is_wake missed a +5s (==slack) suspend' ;;
  23) fail 'wh_is_wake missed a large suspend gap' ;;
  *)  fail 'wh_is_wake unit test errored' ;;
esac

# a virtual clock + instant fake sleep: normally advance the clock by exactly the
# chunk; with the suspend marker present, add a big one-shot jump (host slept).
CLK="$WORK/clock"; MARK="$WORK/suspend.mark"
cat > "$WORK/fakesleep.sh" <<EOF
#!/bin/sh
c=\$(cat "$CLK" 2>/dev/null); case "\$c" in ''|*[!0-9]*) c=0;; esac
adv="\$1"
[ -f "$MARK" ] && { adv=\$(( adv + 3600 )); rm -f "$MARK"; }
echo \$(( c + adv )) > "$CLK"
EOF
chmod +x "$WORK/fakesleep.sh"
# export (not a command-prefix): FLEET_WH_NOW_FILE is read by now() at CALL time
# inside wh_sleep_or_wake, so it must stay live past the `. "$WH"` source line.
wsw() { (
  export FLEET_WEBHOOK_STATE_DIR="$SRCST" FLEET_WH_NOW_FILE="$CLK" FLEET_WH_SLEEP_CMD="$WORK/fakesleep.sh" \
         FLEET_WEBHOOK_RESCAN=30 FLEET_WEBHOOK_WAKE_TICK=5 FLEET_WEBHOOK_WAKE_SLACK=5
  . "$WH"
  wh_sleep_or_wake
) 2>/dev/null; }
echo 1000 > "$CLK"; rm -f "$MARK"; wsw
eq 'uneventful idle returns 0 (no wake)'          "$?" 0
echo 1000 > "$CLK"; : > "$MARK"; wsw
eq 'suspend across a chunk returns 1 (early wake)' "$?" 1

printf 'selftest PASS: %d assertions (routing · no-write · HMAC · selection · reconcile · reap · backoff · catch-up · wake)\n' "$pass"
exit 0
