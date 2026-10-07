#!/usr/bin/env bash
# The rolling-release drill (claude-fleet#2125, EPIC #2119 C6) on a kind
# cluster: two hub replicas on Postgres, a probe hitting /healthz + a write
# once a second from inside the cluster, and every way a pod goes away —
# three releases of a new image, a deleted pod, a release that never gets
# ready and hub-deploy's rollback of it. The verdict is the probe's: every
# second 2xx (downtime_seconds=0), or red.
#
#   drill.sh <tag> <tag> <tag> <tag> <broken tag>
#
# The first tag is the starting release, the next three the releases; the
# broken tag is an image that exits at start (the rollback's subject). All
# already loaded into the kind cluster (hub-rolling.yml builds them). Needs
# kubectl on the kind context, ssh-keygen, openssl, yq.
set -euo pipefail
[ $# = 5 ] || { sed -n '2,17p' "$0" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
REL="$ROOT/.github/actions/hub-release"
NS=hub-e2e
START=$1 BAD=$5; shift; RELEASES=("$1" "$2" "$3")
K() { kubectl -n "$NS" "$@"; }
step() { echo; echo "== $*"; }
render() { kubectl kustomize "$HERE" | sed "s#:set-by-hub-deploy\$#:$1#"; }
ready2() { # both replicas Ready on <tag>, within 3 minutes
  local _ n
  for _ in $(seq 1 90); do
    n=$(K get pod -l app=ccquota-hub -o json | jq --arg i "ccquota:$1" \
      '[.items[] | select(.metadata.deletionTimestamp == null) | select(.spec.containers[0].image == $i)
        | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')
    [ "$n" = 2 ] && return 0
    sleep 2
  done
  K get pod -o wide; return 1
}
tmp=$(mktemp -d)

step "the database, the Secrets, the hub on $START"
kubectl create namespace "$NS"
K apply -f "$HERE/postgres.yaml"
K rollout status deploy/postgres --timeout=3m
ssh-keygen -q -t ed25519 -N '' -C drill-ca -f "$tmp/ca"
K create secret generic ccquota --from-literal=viewer-token="$(openssl rand -hex 16)"
K create secret generic ccquota-ssh-ca --from-file=ca="$tmp/ca"
K create secret generic ccquota-fleet-cred-key --from-literal=key="$(openssl rand -base64 32)"
K create secret generic ccquota-db \
  --from-literal=db-url='postgres://postgres:drill-only@postgres:5432/postgres?sslmode=disable' \
  --from-literal=replica-token="$(openssl rand -hex 16)"
render "$START" > "$tmp/hub.yaml"
shape=$(yq -o=json '.' "$tmp/hub.yaml" | "$REL/release.sh" shape -)
[ "$shape" = mode=postgres ] || { echo "the kind render is not the rolling shape: $shape"; exit 1; }
K apply -f "$tmp/hub.yaml"
K rollout status deploy/ccquota-hub --timeout=5m
ready2 "$START"

step "the probe, from inside the cluster"
K create configmap probe --from-file=probe.sh="$REL/probe.sh"
K apply -f "$HERE/prober.yaml"
K wait --for=condition=Ready pod/prober --timeout=2m
sleep 5
K logs prober | grep -q . && { echo "the probe failed before anything changed:"; K logs prober; exit 1; }

for tag in "${RELEASES[@]}"; do
  step "release $tag (rolling)"
  render "$tag" | K apply -f -
  K rollout status deploy/ccquota-hub --timeout=5m
  ready2 "$tag"
  sleep 3
done
live=${RELEASES[2]}

step "delete one replica (a node drain, an eviction, a person's delete)"
victim=$(K get pod -l app=ccquota-hub -o name | head -1)
K delete "$victim" --wait=true
ready2 "$live"
sleep 3

step "a release that never gets ready ($BAD) — hub-deploy's rollback"
render "$BAD" | K apply -f -
if K rollout status deploy/ccquota-hub --timeout=60s; then
  echo "a release whose pods exit at start finished its rollout"; exit 1
fi
K get pod -l app=ccquota-hub -o wide
# what hub-deploy's «Roll back to the live image» does
K set image deploy/ccquota-hub "ccquota=ccquota:$live"
K rollout status deploy/ccquota-hub --timeout=5m
ready2 "$live"
sleep 3

step "the verdict"
K exec prober -- touch /tmp/stop
for _ in $(seq 1 20); do K logs prober | tail -1 | grep -q '^probes=' && break; sleep 1; done
K logs prober | tee "$tmp/probe.log" | grep '^DOWN' || true
last=$(tail -1 "$tmp/probe.log")
echo "$last"
case "$last" in
  "probes="*" downtime_seconds=0 write_unsupported=0") ;;
  *) echo "::error::the hub was down during the drill: $last"; exit 1 ;;
esac
n=${last#probes=}; n=${n%% *}
[ "$n" -ge 60 ] || { echo "::error::only $n probes — the drill did not run long enough to mean anything"; exit 1; }
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || {
  echo "## 滚动发布演练（kind · 两份入口 + Postgres）"
  echo
  echo "三次发布（${RELEASES[*]}）· 删掉一份 pod · 一次起不来的发布（$BAD）+ 回退到 $live"
  echo
  echo "\`$last\`"
} >> "$GITHUB_STEP_SUMMARY"
echo "drill: ok — $last"
