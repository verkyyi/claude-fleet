#!/usr/bin/env bash
# hub-deploy's render checks on the deployment's own overlays (claude-fleet#3630).
# Production's overlays (overlays/prod · updating/prod · credproxy/prod) live in
# a private deploy repo that hub-deploy lays over deploy/k8s (repo variable
# FLEET_DEPLOY_OVERLAY_REPO, ../../workflows/hub-deploy.yml) — so these checks run
# where that tree is: the deploy job after the overlay (--need-prod), and the PR
# check on the public tree, which skips them once the tree no longer carries
# overlays/prod.
#
#   render-check.sh [--need-prod] <k8s dir>   exit 0 = every render holds; 1 = one
#                                             does not (a ::error:: line says which)
#
# Needs kubectl (kustomize), yq, and release.sh beside it. $PLACEHOLDER is the
# image tag hub-deploy replaces (set-by-hub-deploy).
set -euo pipefail
need=0
[ "${1:-}" = --need-prod ] && { need=1; shift; }
k8s=${1:?usage: render-check.sh [--need-prod] <k8s dir>}
PLACEHOLDER=${PLACEHOLDER:-set-by-hub-deploy}
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
err() { echo "::error::$*"; exit 1; }
shape() { yq -o=json '.' "$1" | "$here/release.sh" shape -; }

# The base is the rolling shape whatever overlay sits on it (issue #2125).
kubectl kustomize "$k8s/base" > "$tmp/base.yaml"
[ "$(shape "$tmp/base.yaml")" = mode=postgres ] || { shape "$tmp/base.yaml"; err "the base is not the rolling shape"; }

if [ ! -f "$k8s/overlays/prod/kustomization.yaml" ]; then
  [ "$need" = 0 ] || err "no overlays/prod in $k8s — FLEET_DEPLOY_OVERLAY_REPO's k8s/ was not laid over it"
  echo "no overlays/prod in this tree (it comes from FLEET_DEPLOY_OVERLAY_REPO at deploy time) — prod render checks skipped"
  exit 0
fi

# The prod overlay renders, with exactly one placeholder tag, and nothing
# beyond what Role claudefleet-deployer may touch (the PodDisruptionBudget only
# once switched — deploy/k8s/README.md).
kubectl kustomize "$k8s/overlays/prod" > "$tmp/hub.yaml"
n=$(grep -c ":$PLACEHOLDER\$" "$tmp/hub.yaml" || true)
[ "$n" = 1 ] || err "expected one image tagged :$PLACEHOLDER, found $n"
for k in Deployment Service Ingress ConfigMap; do
  grep -q "^kind: $k\$" "$tmp/hub.yaml" || err "render has no $k"
done
extra=$(grep '^kind: ' "$tmp/hub.yaml" | grep -vE '^kind: (Deployment|Service|Ingress|PersistentVolumeClaim|PodDisruptionBudget|ConfigMap)$' || true)
[ -z "$extra" ] || err "the deploy role cannot apply: $extra"

# One whole shape, never a mix — two pods on one SQLite file is a corrupt
# database: prod as it is (the sqlite component), and prod as the switch leaves
# it (the component line deleted).
echo "prod: $(shape "$tmp/hub.yaml")"
sw="$tmp/sw"; mkdir "$sw"; cp -R "$k8s" "$sw/k8s"
if grep -q '^components:$' "$sw/k8s/overlays/prod/kustomization.yaml"; then
  sed -i.bak '/^components:$/,/^  - sqlite$/d' "$sw/k8s/overlays/prod/kustomization.yaml"
  kubectl kustomize "$sw/k8s/overlays/prod" > "$tmp/switched.yaml"
  [ "$(shape "$tmp/switched.yaml")" = mode=postgres ] || { shape "$tmp/switched.yaml"; err "prod without the sqlite component is not the rolling shape"; }
  echo "prod after the switch: mode=postgres"
fi

# The 正在更新 page renders, and the hub Ingress names its Service.
if [ -f "$k8s/updating/prod/kustomization.yaml" ]; then
  kubectl kustomize "$k8s/updating/prod" > "$tmp/updating.yaml"
  svc=$(yq 'select(.kind == "Service") | .metadata.name' "$tmp/updating.yaml")
  want=$(yq 'select(.kind == "Ingress") | .metadata.annotations."nginx.ingress.kubernetes.io/default-backend"' "$tmp/hub.yaml")
  [ "$svc" = "$want" ] || err "the hub Ingress's default-backend ($want) is not the updating Service ($svc)"
  for f in nginx.conf updating.html updating.json; do
    grep -q "^  $f: " "$tmp/updating.yaml" || err "the updating ConfigMap has no $f"
  done
else
  [ "$need" = 0 ] || err "no updating/prod in $k8s"
fi

# The cluster credential proxy (#1973) is applied by a person, never by the
# deploy job (deploy/k8s/credproxy/README.md) — but it must render.
if [ -f "$k8s/credproxy/prod/kustomization.yaml" ]; then
  kubectl kustomize "$k8s/credproxy/prod" > "$tmp/credproxy.yaml"
  n=$(grep -c ":$PLACEHOLDER\$" "$tmp/credproxy.yaml" || true)
  [ "$n" = 1 ] || err "credproxy: expected one image tagged :$PLACEHOLDER, found $n"
  grep -q 'value: https://' "$tmp/credproxy.yaml" || err "no relay URL in the credproxy prod render"
else
  [ "$need" = 0 ] || err "no credproxy/prod in $k8s"
fi
echo "render-check: ok ($k8s)"
