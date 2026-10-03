#!/bin/bash
# fleet-gh-write-selftest.sh — the per-token GitHub write queue (issue #1264,
# EPIC #1262 C4): fleet_gh_write in bin/fleet-gh-lib.sh.
#
#   QUEUE      20 concurrent writers all succeed; no two gh calls overlap, and
#              every call STARTS ≥ FLEET_GH_WRITE_GAP after the one before it.
#   SECONDARY  the shim refuses call #5 with a secondary limit + `Retry-After: 3`:
#              the holder waits once (lock held), every other writer waits with
#              it, all 20 still succeed — and the log has exactly ONE wait line.
#   PASSTHRU   a non-limit failure: gh's rc / stdout / stderr unchanged, no retry.
#   BACKOFF    no Retry-After → FLEET_GH_WRITE_BACKOFF<<try; gives up after 3
#              retries with gh's own refusal and rc.
#   MARKER     a write WAITS out another caller's secondary marker
#              (fleet_gh_wrun) where a read skips it (fleet_gh_run → 75).
#   STALE      a holder SIGKILLed mid-write leaves no lock behind for long: the
#              next writer sees the dead pid and proceeds.
#
# `gh` is a PATH shim; never touches the network or the real account.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ghwrite-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

export FLEET_STATE_DIR="$WORK/state" FLEET_GH_LOG="$WORK/gh-limit.log" FLEET_CONF_DIR="$WORK/conf"
export GH_TOKEN=selftest-token FLEET_GH_WRITE_GAP=0.3 SHIM="$WORK/shim"
unset FLEET_GH_FAKE_LIMIT
mkdir -p "$WORK/fakebin" "$SHIM"

# The shim: one line per call in $SHIM/calls
#   "<n> <start-ms> <end-ms> <queue-start-ms> <args>"
# queue-start is the start the queue itself stamped for this call (its .last
# file) — the clock the GAP is enforced on, free of the shim's own start-up jitter.
# $SHIM/mode picks the behaviour; `secondary-at N` refuses the N-th call once.
cat > "$WORK/fakebin/gh" <<'SH'
#!/bin/bash
ms() { perl -MTime::HiRes=time -e 'printf "%d", time()*1000'; }
t0=$(ms)
echo $$ > "$SHIM/pid"
mkdir "$SHIM/busy" 2>/dev/null || echo overlap >> "$SHIM/overlap"
n=$(( $(wc -l < "$SHIM/calls" 2>/dev/null || echo 0) + 1 ))
mode=$(cat "$SHIM/mode" 2>/dev/null)
q=$(cat "$FLEET_STATE_DIR"/gh-write.*.last 2>/dev/null | head -1)
out() { sleep 0.05; rmdir "$SHIM/busy"; echo "$n $t0 $(ms) ${q:-0} $*" >> "$SHIM/calls"; }
case "$mode" in
  "secondary-at $n")
    out "$@"; printf 'gh: You have exceeded a secondary rate limit. (HTTP 403)\nRetry-After: 3\n' >&2; exit 1 ;;
  secondary-noheader-once)
    echo nh > "$SHIM/mode"; out "$@"; echo 'gh: You have exceeded a secondary rate limit. (HTTP 403)' >&2; exit 1 ;;
  secondary-always)
    out "$@"; printf 'gh: You have exceeded a secondary rate limit. (HTTP 403)\nRetry-After: 1\n' >&2; exit 1 ;;
  notfound)
    out "$@"; echo 'partial-stdout'; echo 'HTTP 404: Not Found' >&2; exit 7 ;;
  slow)
    rmdir "$SHIM/busy"; sleep 30; exit 0 ;;
esac
out "$@"; echo "ok ${*: -1}"
SH
chmod +x "$WORK/fakebin/gh"
export PATH="$WORK/fakebin:$PATH"

# shellcheck source=/dev/null
. "$BIN/fleet-gh-lib.sh"

reset_shim() { rm -rf "${SHIM:?}"/* "$FLEET_STATE_DIR"/gh-limit.* "$FLEET_GH_LOG"; printf '%s\n' "${1:-}" > "$SHIM/mode"; : > "$SHIM/calls"; }

# ===== QUEUE + SECONDARY ======================================================
reset_shim "secondary-at 5"
t_start=$(date +%s)
for i in $(seq 1 20); do
  ( out=$(fleet_gh_write api repos/acme/w/issues/1/comments -f "body=w$i" 2>"$WORK/err.$i"); \
    echo "$? $out" > "$WORK/res.$i" ) &
done
wait
t_total=$(( $(date +%s) - t_start ))

okc=0
for i in $(seq 1 20); do
  [ "$(cat "$WORK/res.$i")" = "0 ok body=w$i" ] && okc=$((okc+1))
  [ -s "$WORK/err.$i" ] && fail "writer $i: a waited-out retry must not leak its refusal" "$(cat "$WORK/err.$i")"
done
[ "$okc" -eq 20 ] || fail "all 20 concurrent writers succeed ($okc/20)" "$(cat "$WORK"/res.*)"
calls=$(wc -l < "$SHIM/calls" | tr -d ' ')
[ "$calls" -eq 21 ] || fail "20 writes + 1 refused attempt = 21 gh calls (got $calls)" "$(cat "$SHIM/calls")"
ok "20 concurrent fleet_gh_write: all succeeded ($okc/20, $calls gh calls)"

[ -e "$SHIM/overlap" ] && fail "two gh writes overlapped — the queue is not exclusive"
min_gap=$(sort -n -k4 "$SHIM/calls" | awk 'NR>1 { g=$4-p; if (m=="" || g<m) m=g } { p=$4 } END { print m }')
[ "$min_gap" -ge 300 ] || fail "every write starts ≥ GAP (300ms) after the last (min ${min_gap}ms)" "$(cat "$SHIM/calls")"
ok "no overlap; min start-to-start gap ${min_gap}ms ≥ GAP 300ms"

waits=$(grep -c 'secondary-wait' "$FLEET_GH_LOG")
[ "$waits" -eq 1 ] || fail "exactly ONE unified wait in the log (got $waits)" "$(cat "$FLEET_GH_LOG")"
grep -q 'secondary-wait secs=3 .*retry-after=3' "$FLEET_GH_LOG" || fail "the wait honours Retry-After: 3" "$(cat "$FLEET_GH_LOG")"
t5=$(awk '$1==5 { print $3 }' "$SHIM/calls"); t6=$(awk '$1==6 { print $2 }' "$SHIM/calls")
[ $((t6 - t5)) -ge 2900 ] || fail "nobody writes during the Retry-After window (call 6 was $((t6 - t5))ms after the refusal)"
ok "secondary at call #5: one wait of 3s for everyone (next write +$((t6 - t5))ms), log: $waits wait line"

# ===== PASSTHRU ===============================================================
reset_shim notfound
out=$(fleet_gh_write api repos/acme/w/issues/9 2>"$WORK/err"); rc=$?
[ "$rc" -eq 7 ] && [ "$out" = partial-stdout ] && [ "$(cat "$WORK/err")" = 'HTTP 404: Not Found' ] \
  || fail "gh's rc/stdout/stderr pass through" "rc=$rc out=$out err=$(cat "$WORK/err")"
[ "$(wc -l < "$SHIM/calls" | tr -d ' ')" -eq 1 ] || fail "a non-limit failure is never retried"
ok "non-limit failure: rc 7, stdout and stderr unchanged, one call"

# ===== BACKOFF + give-up ======================================================
reset_shim secondary-noheader-once
export FLEET_GH_WRITE_BACKOFF=1
out=$(fleet_gh_write api x -f body=nh 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = 'ok body=nh' ] || fail "no-header secondary retried after backoff" "rc=$rc out=$out"
grep -q 'secondary-wait secs=1 .*try=1$' "$FLEET_GH_LOG" || fail "no Retry-After → backoff base" "$(cat "$FLEET_GH_LOG")"
reset_shim secondary-always
out=$(fleet_gh_write api x -f body=never 2>"$WORK/err"); rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'secondary rate limit' "$WORK/err"; } || fail "gives up with gh's refusal" "rc=$rc $(cat "$WORK/err")"
[ "$(wc -l < "$SHIM/calls" | tr -d ' ')" -eq 4 ] || fail "1 try + 3 retries, no more" "$(cat "$SHIM/calls")"
unset FLEET_GH_WRITE_BACKOFF
ok "no Retry-After → exponential backoff; gives up after 3 retries with gh's rc + refusal"

# ===== MARKER: write waits, read skips ========================================
reset_shim ''
fleet_gh_mark_limited secondary "$(( $(date +%s) + 2 ))" other-writer
fleet_gh_run core read api x >/dev/null 2>&1; rc=$?
[ "$rc" -eq "$FLEET_GH_LIMITED_RC" ] || fail "a READ skips under a secondary marker (rc $rc)"
s=$(date +%s)
out=$(fleet_gh_wrun core write api x -f body=m 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = 'ok body=m' ] || fail "a WRITE waits the marker out, then posts" "rc=$rc out=$out"
[ $(( $(date +%s) - s )) -ge 1 ] || fail "the write actually waited"
grep -q 'secondary-wait .*cause=marker' "$FLEET_GH_LOG" || fail "marker wait logged" "$(cat "$FLEET_GH_LOG")"
ok "another caller's secondary marker: fleet_gh_run skips (75), fleet_gh_wrun waits and posts"

# ===== STALE lock =============================================================
reset_shim slow
bash -c '. "$1"; fleet_gh_write api slow' _ "$BIN/fleet-gh-lib.sh" >/dev/null 2>&1 &
holder=$!
lock=
for _ in $(seq 1 100); do
  lock=$(ls "$FLEET_STATE_DIR"/gh-write.*.lock 2>/dev/null)
  [ -s "$SHIM/pid" ] && [ -n "$lock" ] && break; sleep 0.05
done
[ "$(cat "$lock" 2>/dev/null)" = "$holder" ] || fail "the lock names its holder's pid" "lock=$(cat "$lock" 2>/dev/null) holder=$holder"
kill -9 "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
kill "$(cat "$SHIM/pid")" 2>/dev/null
echo '' > "$SHIM/mode"
s=$(date +%s)
out=$(fleet_gh_write api x -f body=after 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = 'ok body=after' ] || fail "a write after a SIGKILLed holder succeeds" "rc=$rc out=$out"
[ $(( $(date +%s) - s )) -le 3 ] || fail "…promptly, not after the lock timeout"
grep -q "write-lock-stale pid=$holder" "$FLEET_GH_LOG" || fail "stale lock logged" "$(cat "$FLEET_GH_LOG")"
[ -e "$lock" ] && fail "no lock left behind after the write" "$(cat "$lock")"
ok "holder SIGKILLed mid-write: its lock is recognised dead and cleared; next write proceeds"

printf -- '--- summary ---\n'
printf 'concurrent writers: 20, succeeded: %d, gh calls: %d (1 refused)\n' "$okc" "$calls"
printf 'min start-to-start gap: %sms (GAP 300ms), wall %ss\n' "$min_gap" "$t_total"
printf 'secondary-rate-limit waits in the log: %d (Retry-After: 3, shared by all 20)\n' "$waits"
printf 'PASS fleet-gh-write-selftest (%d checks)\n' "$pass"
