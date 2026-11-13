#!/usr/bin/env bash
# The 2026-11-13 outage, done on purpose (task N9GH). Run on the k3s box as
# root, at a time nobody minds a short wobble:
#
#   db-blackhole-drill.sh blackhole   the hub pods' OPEN connections to Postgres
#                                     go silent (iptables DROP on exactly those
#                                     sockets, in each pod's network namespace —
#                                     new connections pass, as on the day).
#                                     PASS = no /readyz answer took longer than
#                                     FLEET_DRILL_PROBE_SECS (3), and every pod
#                                     answers /readyz 200 and one real write
#                                     (POST /v1/deploy-probe) within
#                                     FLEET_DRILL_BACK_SECS (60), with no pod
#                                     restarted.
#   db-blackhole-drill.sh networkd    `systemctl restart systemd-networkd`, as
#                                     needrestart did. PASS = every pod's DB
#                                     connections from before are still there
#                                     after, and /readyz never failed.
#
# The rules live in a chain of their own (FLEET_N9GH) in each pod's namespace;
# they are removed at the end, and a systemd timer removes them anyway after
# FLEET_DRILL_MAX_SECS (300) if this script is killed. Changes nothing else.
set -euo pipefail
mode=${1:-blackhole}
BACK=${FLEET_DRILL_BACK_SECS:-60}
PROBE=${FLEET_DRILL_PROBE_SECS:-3}
MAX=${FLEET_DRILL_MAX_SECS:-300}
NS=${FLEET_DRILL_NS:-fleet-hub}
PORT=${FLEET_DRILL_DB_PORT:-5432}
CHAIN=FLEET_N9GH
k() { k3s kubectl "$@"; }
say() { printf '[drill] %s\n' "$*"; }
die() { say "FAIL: $*"; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root on the box"
command -v iptables >/dev/null || die "no iptables on the box"

# pods: name, IP, pid of the ccquota container (its network namespace), restarts
pods() {
  k -n "$NS" get pods -l app=ccquota-hub --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP} {.status.containerStatuses[0].containerID} {.status.containerStatuses[0].restartCount}{"\n"}{end}'
}
pid_of() { # pid_of <containerd://id>
  k3s crictl inspect --output go-template --template '{{.info.pid}}' "${1#containerd://}"
}
in_ns() { local pid=$1; shift; nsenter -t "$pid" -n "$@"; }
# db_ports <pid>: the local ports of the pod's established connections to Postgres
db_ports() {
  in_ns "$1" ss -Htn state established "( dport = :$PORT )" | awk '{ n = split($3, a, ":"); print a[n] }' | sort -n
}
# readyz <ip>: "<http code> <seconds>" of one /readyz, cut at PROBE+5 s
readyz() {
  curl -s -o /dev/null -m $((PROBE + 5)) -w '%{http_code} %{time_total}' "http://$1:8787/readyz" || true
}
write_ok() {
  [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST "http://$1:8787/v1/deploy-probe" || true)" = 200 ]
}

mapfile -t PODS < <(pods)
[ "${#PODS[@]}" -gt 0 ] || die "no running ccquota-hub pod in $NS"

unblock() {
  local p pid
  for p in "${PODS[@]}"; do
    read -r _ _ cid _ <<<"$p"
    pid=$(pid_of "$cid" 2>/dev/null) || continue
    in_ns "$pid" iptables -D OUTPUT -j "$CHAIN" 2>/dev/null || true
    in_ns "$pid" iptables -D INPUT -j "$CHAIN" 2>/dev/null || true
    in_ns "$pid" iptables -F "$CHAIN" 2>/dev/null || true
    in_ns "$pid" iptables -X "$CHAIN" 2>/dev/null || true
  done
}

case $mode in
blackhole)
  # the guaranteed cleanup: a timer outside this shell, set before any rule
  self=$(readlink -f "$0")
  systemd-run --quiet --unit "fleet-n9gh-drill-cleanup-$$" --on-active="$MAX" \
    /bin/bash -c "FLEET_DRILL_NS=$NS '$self' unblock" >/dev/null || die "could not arm the cleanup timer"
  trap unblock EXIT
  t0=$(date +%s)
  for p in "${PODS[@]}"; do
    read -r name ip cid _ <<<"$p"
    pid=$(pid_of "$cid")
    ports=$(db_ports "$pid")
    [ -n "$ports" ] || die "$name holds no connection to :$PORT (is the hub on Postgres?)"
    in_ns "$pid" iptables -N "$CHAIN"
    for lp in $ports; do
      in_ns "$pid" iptables -A "$CHAIN" -p tcp --sport "$lp" --dport "$PORT" -j DROP
      in_ns "$pid" iptables -A "$CHAIN" -p tcp --dport "$lp" --sport "$PORT" -j DROP
    done
    in_ns "$pid" iptables -I OUTPUT -j "$CHAIN"
    in_ns "$pid" iptables -I INPUT -j "$CHAIN"
    say "$name ($ip): blackholed $(echo "$ports" | wc -w | tr -d ' ') open connection(s) to :$PORT"
  done
  worst=0; fails=0
  declare -A back=()
  while :; do
    now=$(date +%s); el=$((now - t0))
    for p in "${PODS[@]}"; do
      read -r name ip _ _ <<<"$p"
      [ -n "${back[$name]:-}" ] && continue
      read -r code secs <<<"$(readyz "$ip")"
      ms=$(awk -v s="${secs:-99}" 'BEGIN { printf "%d", s * 1000 }')
      [ "$ms" -gt "$worst" ] && worst=$ms
      [ "$code" = 200 ] || fails=$((fails + 1))
      if [ "$code" = 200 ] && write_ok "$ip"; then
        back[$name]=$el
        say "$name: /readyz 200 and a write served ${el}s after the blackhole"
      fi
    done
    [ "${#back[@]}" -eq "${#PODS[@]}" ] && break
    [ "$el" -lt "$BACK" ] || break
    sleep 1
  done
  unblock; trap - EXIT
  systemctl stop "fleet-n9gh-drill-cleanup-$$.timer" 2>/dev/null || true
  mapfile -t AFTER < <(pods)
  for p in "${PODS[@]}"; do
    read -r name _ _ r0 <<<"$p"
    r1=$(printf '%s\n' "${AFTER[@]}" | awk -v n="$name" '$1 == n { print $4 }')
    [ "$r1" = "$r0" ] || die "$name restarted (restarts $r0 → ${r1:-gone})"
    [ -n "${back[$name]:-}" ] || die "$name not serving ${BACK}s after the blackhole"
  done
  say "worst /readyz answer ${worst} ms; ${fails} not-ready answer(s) on the way"
  [ "$worst" -le $((PROBE * 1000)) ] || die "a /readyz answer took ${worst} ms (> ${PROBE}s): it hung behind a dead connection"
  say "PASS: every pod serving again within ${BACK}s, no restart"
  ;;
networkd)
  nft list table ip fleet_pod_snat >/dev/null 2>&1 \
    || die "no pod egress SNAT (fleet-pod-snat.service): a networkd restart would drop every open pod connection — run bootstrap.sh host first"
  declare -A before=()
  for p in "${PODS[@]}"; do
    read -r name _ cid _ <<<"$p"
    before[$name]=$(db_ports "$(pid_of "$cid")" | tr '\n' ' ')
    [ -n "${before[$name]// }" ] || die "$name holds no connection to :$PORT"
  done
  say "restarting systemd-networkd"
  systemctl restart systemd-networkd
  fails=0
  for _ in $(seq 1 30); do
    for p in "${PODS[@]}"; do
      read -r name ip _ _ <<<"$p"
      read -r code _ <<<"$(readyz "$ip")"
      [ "$code" = 200 ] || { fails=$((fails + 1)); say "$name: /readyz $code"; }
    done
    sleep 1
  done
  for p in "${PODS[@]}"; do
    read -r name ip cid _ <<<"$p"
    write_ok "$ip" || die "$name: a write failed after the networkd restart"
    now=" $(db_ports "$(pid_of "$cid")" | tr '\n' ' ')"
    kept=0
    for lp in ${before[$name]}; do case $now in *" $lp "*) kept=$((kept + 1)) ;; esac; done
    say "$name: $kept of $(echo "${before[$name]}" | wc -w | tr -d ' ') DB connection(s) from before still open"
    [ "$kept" -gt 0 ] || die "$name lost every DB connection it had"
  done
  [ "$fails" -eq 0 ] || die "$fails /readyz answer(s) were not 200 in the 30 s after the restart"
  ip route | grep -q 'cni0\|flannel' || die "the pod network's routes are gone from the host"
  say "PASS: networkd restarted, DB connections kept, /readyz 200 throughout"
  ;;
unblock) unblock ;;
*) die "usage: db-blackhole-drill.sh [blackhole|networkd]" ;;
esac
