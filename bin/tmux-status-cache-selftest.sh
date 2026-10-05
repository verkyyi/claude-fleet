#!/bin/bash
# tmux-status-cache-selftest.sh — pins issue #890: the status bar's one exec'd
# reading, the container's ●/○ (FLEET_STATUS_CONTAINER, `docker ps`), is measured
# ONCE per interval for every attached client, through ${TMPDIR}/fleet-status.cache,
# instead of once per client. Since issue #1616 负载 / 内存 / 盘 are no longer the
# bar's (fleet-alerts.sh raises them when red), so the bar measures nothing else
# — and with no container configured, nothing at all.
#
#   no container                 → no docker, no cache written, nothing drawn
#   cold, 5 concurrent callers   → measured once, all five print the same bar
#   fresh cache                  → printed verbatim, nothing measured
#   expired, 5 concurrent        → measured once; the rest print the old value
#   expired, lock held (live)    → old value at once, nothing measured
#   another container's key      → never shown; measured for this key
#   a dead holder's lock         → broken after the wait, bar still renders
#   FLEET_STATUS_CACHE_SECS=0    → measured every call, no cache written
#   running                      → nothing drawn (a running container wants no hand)
#
# docker is a shim that logs every call and sleeps, so concurrent callers really
# overlap. No live tmux; TMPDIR is a sandbox.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/  /' >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1" "want: [$2]
 got: [$3]"; CHECKS=$((CHECKS+1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/status-cache-selftest.XXXXXX") || exit 2
[ -n "${KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT
T="$WORK/tmp"; CACHE="$T/fleet-status.cache"; G="$T/.claude-dash/global"; mkdir -p "$T" "$G" "$WORK/bin" "$WORK/out"

# docker ps lists `other` (web is down) — or `web` once $WORK/up exists
printf '#!/bin/sh\necho docker >> "%s/docker.log"; sleep 0.5\n[ -e "%s/up" ] && echo web || echo other\n' "$WORK" "$WORK" > "$WORK/bin/docker"
chmod +x "$WORK/bin/docker"
: > "$WORK/docker.log"
measured() { local n; n=$(grep -c . "$WORK/docker.log" 2>/dev/null); printf '%s' "${n:-0}"; }

# The alerts file is planted (empty, fresh for FLEET_ALERTS_TTL=3600) so the
# producer adds nothing to the bar here.
: > "$G/alerts.ndjson"; date +%s > "$G/alerts.ndjson.ts"
bar() { FLEET_ALERTS_TTL=3600 TMPDIR="$T/" FLEET_ACCOUNTS_DIR="$WORK/acc" CCQUOTA_HUB_URL=http://127.0.0.1:9 \
        FLEET_STATUS_CONTAINER="${CTR-web}" PATH="$WORK/bin:$PATH" bash "$BIN/tmux-status.sh" 2>/dev/null; }
seg() { printf '%s' "$1"; }
WANT=' #[fg=#7aa2f7]web #[fg=#f7768e]○ '
FIELDS='=#[fg=#f7768e]○'
MARK='MARK-old-value'
KEY="v3|web"
now() { date +%s; }
plant() { printf '%s\t%s\n=%s\n' "$1" "${2:-$KEY}" "$MARK" > "$CACHE"; }
five() {   # five concurrent callers → $WORK/out/1..5
  local i; rm -f "$WORK/out/"*
  for i in 1 2 3 4 5; do bar > "$WORK/out/$i" & done; wait
}

# ---- no container: nothing measured, nothing written, nothing drawn
eq "no container: nothing drawn" "" "$(CTR='' bar)"
eq "no container: docker never runs" 0 "$(measured)"
[ -e "$CACHE" ] && fail "no container: a cache was written"; CHECKS=$((CHECKS+1))

# ---- cold start: five at once, one measurement, one answer
five
eq "cold: 5 concurrent callers measure once" 1 "$(measured)"
for i in 1 2 3 4 5; do eq "cold: caller $i prints web ○" "$WANT" "$(seg "$(cat "$WORK/out/$i")")"; done
[ -d "$CACHE.lock" ] && fail "cold: the lock outlived the measurement"
first=$(sed -n 2p "$CACHE"); eq "cold: the cache holds the value" "$FIELDS" "$first"

# ---- fresh: read through, nothing measured
out=$(bar); eq "fresh: nothing measured" 1 "$(measured)"
eq "fresh: same bar" "$WANT" "$(seg "$out")"
plant "$(now)"; out=$(bar)
case "$out" in *"$MARK"*) CHECKS=$((CHECKS+1)) ;; *) fail "fresh: the cached values must be printed verbatim" "$out" ;; esac
eq "fresh: a planted entry is not re-measured" 1 "$(measured)"

# ---- expired: one re-measurement, everyone else keeps the old value
plant $(( $(now) - 10 )); five
eq "expired: 5 concurrent callers measure once" 2 "$(measured)"
old=0
for i in 1 2 3 4 5; do
  o=$(cat "$WORK/out/$i")
  case "$o" in *"$MARK"*) old=$((old+1)) ;; *) eq "expired: caller $i prints old or new, nothing else" "$WANT" "$(seg "$o")" ;; esac
done
[ "$old" -ge 1 ] || fail "expired: no caller served the old value while the holder measured"; CHECKS=$((CHECKS+1))
eq "expired: the cache is re-published" "$FIELDS" "$(sed -n 2p "$CACHE")"

# ---- expired while a live holder has the lock: old value, immediately
plant $(( $(now) - 7 )); mkdir "$CACHE.lock"
out=$(bar)
case "$out" in *"$MARK"*) CHECKS=$((CHECKS+1)) ;; *) fail "held lock: the old value must be served" "$out" ;; esac
eq "held lock: nothing measured" 2 "$(measured)"
rmdir "$CACHE.lock"

# ---- another install / knob: never shown, measured for our key
plant "$(now)" "v3|db"; out=$(bar)
eq "foreign key: measured for this key" 3 "$(measured)"
eq "foreign key: its value is never shown" "$WANT" "$(seg "$out")"
case "$(sed -n 1p "$CACHE")" in *"	$KEY") CHECKS=$((CHECKS+1)) ;; *) fail "foreign key: the cache was not re-keyed" "$(cat "$CACHE")" ;; esac

# ---- a dead holder's lock, no usable cache: wait, break it, still render
rm -f "$CACHE"; mkdir "$CACHE.lock"
s0=$SECONDS; out=$(bar)
eq "dead lock: the bar still renders" "$WANT" "$(seg "$out")"
[ -d "$CACHE.lock" ] && fail "dead lock: not broken"
[ $((SECONDS - s0)) -le 10 ] || fail "dead lock: waited $((SECONDS - s0))s"; CHECKS=$((CHECKS+2))
bar >/dev/null; [ -s "$CACHE" ] || fail "dead lock: the next caller must publish again"; CHECKS=$((CHECKS+1))

# ---- sharing off
rm -f "$CACHE"; n=$(measured)
FLEET_STATUS_CACHE_SECS=0 bar >/dev/null; FLEET_STATUS_CACHE_SECS=0 bar >/dev/null
eq "FLEET_STATUS_CACHE_SECS=0: every call measures" $((n + 2)) "$(measured)"
[ -e "$CACHE" ] && fail "FLEET_STATUS_CACHE_SECS=0 wrote a cache"; CHECKS=$((CHECKS+1))

# ---- running: nothing to say, and the empty value still caches
rm -f "$CACHE"; touch "$WORK/up"; n=$(measured)
eq "running: nothing drawn" "" "$(bar)"
eq "running: the cache holds an empty value" "=" "$(sed -n 2p "$CACHE")"
eq "running: …which is read through, not re-measured" "" "$(bar)"
eq "running: measured once" $((n + 1)) "$(measured)"

printf 'tmux-status-cache-selftest: OK (%d checks) — one container measurement per interval for every client (issue #890), none without one (#1616)\n' "$CHECKS"
