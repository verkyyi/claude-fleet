#!/bin/sh
# The availability probe (claude-fleet#2125, EPIC #2119 C6): once a second,
# GET <url>/healthz and POST <url>/v1/deploy-probe (one real database write);
# a second in which either is not 2xx — a 503, the 正在更新 page, a refused or
# timed-out connection — is a second down. It runs for the whole release
# (hub-deploy starts it before the apply, stops it after the health check /
# rollback) and in the kind drill (.github/workflows/hub-rolling.yml, from a pod
# inside the cluster). POSIX sh + curl only: the drill runs it in a curl image.
#
#   probe.sh <base url> <stop file> [max secs]
#
# Stops when <stop file> exists or after [max secs] (default 3600 — a kill-proof
# deadline of its own), then prints its verdict as the LAST line:
#   probes=<n> downtime_seconds=<s> write_unsupported=<n>
# Each failing probe prints one `DOWN …` line before it. A 404 from the write
# probe is an image older than the endpoint (the first release that ships it):
# counted apart as write_unsupported, not as down — unless PROBE_STRICT=1 (the
# drill, where every image has it).
u=${1%/}; stop=$2; max=${3:-3600}
[ -n "$u" ] && [ -n "$stop" ] || { echo "usage: probe.sh <base url> <stop file> [max secs]" >&2; exit 2; }
start=$(date +%s); n=0; down=0; wu=0
while [ ! -e "$stop" ] && [ $(( $(date +%s) - start )) -lt "$max" ]; do
  t=$(date +%s)
  h=$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$u/healthz" 2>/dev/null) || true
  w=$(curl -s -o /dev/null -w '%{http_code}' -m 2 -X POST "$u/v1/deploy-probe" 2>/dev/null) || true
  bad=''
  case "$h" in 2??) ;; *) bad=1 ;; esac
  case "$w" in
    2??) ;;
    404) if [ "${PROBE_STRICT:-0}" = 1 ]; then bad=1; else wu=$((wu + 1)); fi ;;
    *) bad=1 ;;
  esac
  n=$((n + 1))
  e=$(date +%s)
  if [ -n "$bad" ]; then
    s=$((e - t)); [ "$s" -ge 1 ] || s=1   # a probe that hung 4 s is 4 s down
    down=$((down + s))
    echo "DOWN $(date -u +%H:%M:%S) healthz=${h:-000} write=${w:-000} (${s}s)"
  fi
  while [ "$(date +%s)" -le "$t" ]; do sleep 0.2; done
done
echo "probes=$n downtime_seconds=$down write_unsupported=$wu"
