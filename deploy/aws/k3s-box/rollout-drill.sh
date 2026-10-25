#!/usr/bin/env bash
# The long-link drill on the box (task PNWW): a rolling restart of the hub with
# machines connected, read back from the hub's own records. Run on the k3s box
# as root, at a time nobody minds a one-second reconnect:
#
#   rollout-drill.sh [rounds]     (default 1)
#
# Before and after each round it counts the connected node links (GET /v1/nodes)
# and, after, reads the drops this round caused (GET /v1/fleet/link/stats): a
# hand-over is booked hub_shutdown by the replica that left and hub_restart by
# the one that took the link, with how long it was gone. PASS = every link that
# was connected is connected again within FLEET_DRILL_BACK_SECS (60) and the
# worst hub_restart gap is under FLEET_DRILL_GAP_MS (10000 — the hub counts a gap
# from the link's last beat, so it holds up to one heartbeat besides the
# reconnect itself). Changes nothing but the restart itself.
set -euo pipefail
rounds=${1:-1}
SECRETS_DIR=${SECRETS_DIR:-/etc/fleet-core/secrets}
BACK=${FLEET_DRILL_BACK_SECS:-60}
GAP=${FLEET_DRILL_GAP_MS:-10000}
k() { k3s kubectl "$@"; }
hub="http://$(k -n fleet-hub get svc ccquota-hub -o jsonpath='{.spec.clusterIP}')"
get() { # get <path>: the viewer token on curl's stdin, never an argv
  printf 'header = "Authorization: Bearer %s"\n' "$(cat "$SECRETS_DIR/viewer-token")" | curl -fsS -K - "$hub$1"
}
connected() { get /v1/nodes | python3 -c 'import json,sys; print(sum(1 for n in json.load(sys.stdin).get("nodes") or [] if n.get("connected")))'; }

for r in $(seq 1 "$rounds"); do
  before=$(connected)
  echo "round $r: $before link(s) connected; rolling deploy/ccquota-hub"
  k -n fleet-hub rollout restart deploy/ccquota-hub >/dev/null
  k -n fleet-hub rollout status deploy/ccquota-hub --timeout=10m >/dev/null
  now=0
  for _ in $(seq 1 "$BACK"); do
    now=$(connected)
    [ "$now" -ge "$before" ] && break
    sleep 1
  done
  [ "$now" -ge "$before" ] || { echo "FAIL round $r: $now of $before link(s) back after ${BACK}s"; exit 1; }
  worst=$(get '/v1/fleet/link/stats?days=1' | python3 -c '
import json, sys
st = json.load(sys.stdin)
print(max([(l.get("gap_by_cause") or {}).get("hub_restart", {}).get("max_ms", 0) for l in st.get("links") or []] or [0]))')
  echo "round $r: $now link(s) back; worst hub_restart gap today ${worst} ms"
  [ "$worst" -lt "$GAP" ] || { echo "FAIL round $r: a link was gone ${worst} ms (> ${GAP})"; exit 1; }
done
echo "PASS: $rounds rolling restart(s), every link back"
