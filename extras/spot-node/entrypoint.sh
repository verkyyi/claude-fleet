#!/bin/bash
# spot-node-entrypoint — a SPOT execution node's main process (issue #1428),
# under tini. Joins the hub with the one-time code the hub put in the pod's
# environment, installs the fleet from the checkout baked into the image, then
# runs the ccquota agent in the FOREGROUND as this container's life: when the
# agent exits, the pod is done.
#
# Environment (set by the hub on the pod it creates):
#   CCQUOTA_HUB_URL   where the hub is reached from inside the cluster
#   FLEET_JOIN_CODE   the join code (one redemption, boot-window TTL)
#   FLEET_NODE_KIND   ephemeral — the hub stamps the kind from the code anyway;
#                     the join writes CCQUOTA_FLEET_NODE_KIND from the hub's
#                     answer, which is what makes SIGTERM a reclaim
#   FLEET_SPOT_ID     the hub's id for this node (for the logs)
#
# On SIGTERM (the kubelet's warning that the SPOT machine is going, or the
# hub's idle release) tini forwards the signal to the agent, which — because
# the node is ephemeral — tells the hub, runs bin/fleet-spot-evacuate.sh to
# move idle sessions off through the hub, and then exits. The pod's
# terminationGracePeriodSeconds (the hub's CCQUOTA_FLEET_SPOT_GRACE_SECONDS,
# 300) is the budget; CCQUOTA_FLEET_RECLAIM_SECS (240) is what the agent uses
# of it.
set -uo pipefail

log() { printf 'spot-node: %s\n' "$*"; }
: "${CCQUOTA_HUB_URL:?spot-node: CCQUOTA_HUB_URL is required}"
export HOME="${HOME:-/home/fleet}"
cd "$HOME" || exit 1
ENVF="$HOME/.config/claude-fleet/node.env"
FLEET_SRC="${FLEET_SRC:-/opt/claude-fleet}"
log "node ${FLEET_SPOT_ID:-?} (${FLEET_NODE_KIND:-fixed}) on $(hostname) → $CCQUOTA_HUB_URL"

if [ -f "$ENVF" ] && grep -q '^CCQUOTA_TOKEN=' "$ENVF"; then
  log "already joined (node.env present) — a restarted container keeps its identity"
else
  : "${FLEET_JOIN_CODE:?spot-node: FLEET_JOIN_CODE is required on first boot}"
  # --service none: the agent is THIS process, below, not a daemon the join
  # would start; --no-deps: baked into the image; --no-admin: a node has no
  # sudo and opens no accounts; --fleet-src: the checkout the image carries.
  # The agent binary comes from the hub's dist (so it always matches the
  # hub), with the baked /usr/local/bin/ccquota as the fallback the join
  # already knows.
  if ! "$FLEET_SRC/bin/fleet-node-join.sh" --hub "$CCQUOTA_HUB_URL" --token "$FLEET_JOIN_CODE" \
        --no-deps --no-admin --service none --fleet-src "$FLEET_SRC"; then
    log "join failed — exiting; the hub gives up on this pod at its boot timeout"
    exit 1
  fi
  # The code is spent; nothing else should read it.
  unset FLEET_JOIN_CODE
fi

# Default the git identity: a worker's commits need one, and a container
# has none.
git config --global user.name  >/dev/null 2>&1 || git config --global user.name "fleet spot node"
git config --global user.email >/dev/null 2>&1 || git config --global user.email "fleet-spot-node@localhost"

set -a
# shellcheck disable=SC1090
. "$ENVF"
set +a
case "${CCQUOTA_FLEET_NODE_KIND:-}" in
  ephemeral) log "ephemeral node: SIGTERM = reclaim (tell the hub, move idle sessions off, stop)" ;;
  *) log "WARN: the hub did not mark this node ephemeral — SIGTERM is a plain stop" ;;
esac
CCQ="$HOME/.local/bin/ccquota"
[ -x "$CCQ" ] || CCQ="$(command -v ccquota)"
log "agent: exec $CCQ agent (version $("$CCQ" version 2>/dev/null | head -n 1))"
exec "$CCQ" agent --state "$HOME/.ccquota"
