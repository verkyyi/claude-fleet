#!/bin/bash
# tmux-status-cache-selftest.sh — pins issue #890: the status bar's machine stats
# (container / CPU / MEM / DSK) are measured ONCE per interval for every attached
# client, through ${TMPDIR}/fleet-status.cache, instead of once per client.
#
#   cold, 5 concurrent callers   → measured once, all five print the same bar
#   fresh cache                  → printed verbatim, nothing measured
#   expired, 5 concurrent        → measured once; the rest print the old value
#   expired, lock held (live)    → old value at once, nothing measured
#   another install's key        → never shown; measured for this key
#   a dead holder's lock         → broken after the wait, bar still renders
#   FLEET_STATUS_CACHE_SECS=0    → measured every call, no cache written
#   output                       → byte-for-byte the pre-#890 bar
#
# ps / sysctl / vm_stat / free / df are shims with fixed readings; df logs every
# call (one per measurement on both OSes) and sleeps, so concurrent callers really
# overlap. No live tmux; TMPDIR is a sandbox.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/  /' >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1" "want: [$2]
 got: [$3]"; CHECKS=$((CHECKS+1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/status-cache-selftest.XXXXXX") || exit 2
[ -n "${KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT
T="$WORK/tmp"; CACHE="$T/fleet-status.cache"; mkdir -p "$T" "$WORK/bin" "$WORK/out"

sh_shim() { printf '#!/bin/sh\n%s\n' "$2" > "$WORK/bin/$1"; chmod +x "$WORK/bin/$1"; }
sh_shim ps      'printf "%%CPU\n12.0\n28.0\n"'
sh_shim sysctl  'printf "4\n8589934592\n16384\n"'
sh_shim vm_stat 'printf "Pages active:  100000.\nPages wired down:  50000.\nPages occupied by compressor:  50000.\n"'
sh_shim free    'printf "       total used\nMem:    8192 3125\n"'
sh_shim df      "echo df >> '$WORK/df.log'; sleep 0.5
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 1 1 104857600 1%% /\n'"
: > "$WORK/df.log"
measured() { local n; n=$(grep -c . "$WORK/df.log" 2>/dev/null); printf '%s' "${n:-0}"; }

bar() { TMPDIR="$T/" FLEET_ACCOUNTS_DIR="$WORK/acc" CCQUOTA_HUB_URL=http://127.0.0.1:9 \
        PATH="$WORK/bin:$PATH" bash "$BIN/tmux-status.sh" 2>/dev/null; }
# The machine segment is everything before the usage/alarm segments; Linux reads
# CPU from /proc/stat (not shimmable), so its figure is masked there.
seg() { local pre="${1%%DSK *}" rest s; rest="${1#"$pre"}"; s="$pre${rest%%G *}G "
        case "${OSTYPE:-}" in darwin*) ;; *) s=$(printf '%s' "$s" | sed -E 's/CPU #\[fg=#[0-9a-f]+\][0-9]+%/CPU #[fg=#9ece6a]10%/') ;; esac
        printf '%s' "$s"; }
WANT=' #[fg=#7aa2f7]CPU #[fg=#9ece6a]10% #[fg=#565f89]│ #[fg=#7aa2f7]MEM #[fg=#9ece6a]3.1G/8.0G #[fg=#565f89]│ #[fg=#7aa2f7]DSK #[fg=#9ece6a]100G '
MARK=' MARK-old-value '
KEY="|1|$T/|12"   # container | FLEET_STATUS_DISK | disk target (= TMPDIR) | floor
now() { date +%s; }
plant() { printf '%s\t%s\n%s\n' "$1" "${2:-$KEY}" "$MARK" > "$CACHE"; }
five() {   # five concurrent callers → $WORK/out/1..5
  local i; rm -f "$WORK/out/"*
  for i in 1 2 3 4 5; do bar > "$WORK/out/$i" & done; wait
}

# ---- cold start: five at once, one measurement, one answer
five
eq "cold: 5 concurrent callers measure once" 1 "$(measured)"
for i in 1 2 3 4 5; do eq "cold: caller $i prints the pre-#890 bar" "$WANT" "$(seg "$(cat "$WORK/out/$i")")"; done
[ -d "$CACHE.lock" ] && fail "cold: the lock outlived the measurement"
first=$(sed -n 2p "$CACHE"); eq "cold: the cache holds the rendered segment" "$WANT" "$(seg "$first")"

# ---- fresh: read through, nothing measured
out=$(bar); eq "fresh: nothing measured" 1 "$(measured)"
eq "fresh: same bar" "$WANT" "$(seg "$out")"
plant "$(now)"; out=$(bar)
case "$out" in "$MARK"*) CHECKS=$((CHECKS+1)) ;; *) fail "fresh: the cached segment must be printed verbatim" "$out" ;; esac
eq "fresh: a planted entry is not re-measured" 1 "$(measured)"

# ---- expired: one re-measurement, everyone else keeps the old value
plant $(( $(now) - 10 )); five
eq "expired: 5 concurrent callers measure once" 2 "$(measured)"
old=0
for i in 1 2 3 4 5; do
  o=$(cat "$WORK/out/$i")
  case "$o" in "$MARK"*) old=$((old+1)) ;; *) eq "expired: caller $i prints old or new, nothing else" "$WANT" "$(seg "$o")" ;; esac
done
[ "$old" -ge 1 ] || fail "expired: no caller served the old value while the holder measured"; CHECKS=$((CHECKS+1))
eq "expired: the cache is re-published" "$WANT" "$(seg "$(sed -n 2p "$CACHE")")"

# ---- expired while a live holder has the lock: old value, immediately
plant $(( $(now) - 7 )); mkdir "$CACHE.lock"
out=$(bar)
case "$out" in "$MARK"*) CHECKS=$((CHECKS+1)) ;; *) fail "held lock: the old value must be served" "$out" ;; esac
eq "held lock: nothing measured" 2 "$(measured)"
rmdir "$CACHE.lock"

# ---- another install / knob: never shown, measured for our key
plant "$(now)" "|1|/elsewhere/|12"; out=$(bar)
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

printf 'tmux-status-cache-selftest: OK (%d checks) — one measurement per interval for every client (issue #890)\n' "$CHECKS"
