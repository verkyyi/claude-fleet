#!/bin/bash
# Build and push the managed node image of one signed release, in the cluster
# (issue #3855): the release train's `node image` job runs it on the fleet-ack
# runner, beside the cluster's buildkitd — native amd64, the hub and ACR's VPC
# endpoint both a hop away, nothing crossing the Pacific.
#
# Usage: train-build.sh <hub> <40-character sha> <image repo> <tools image>
#   <image repo>   e.g. registry-vpc.cn-shenzhen.aliyuncs.com/acme/fleet-managed-node
#   <tools image>  the Dockerfile's `tools` stage as the train pushed it
#                  (<repo>:<tools-tag.sh>, best by digest)
#
# 1. The release's manifest is checked against the checkout's pinned root
#    (conf/release-keys/root.pub, fleet-release-verify.py — no ccquota needed),
#    and its ccquota-linux-amd64 is taken by the sha256 the signed manifest names.
# 2. prepare-image.sh, run with that ccquota, fetches and verifies the release
#    into a build context (the same road as a build by hand).
# 3. buildctl builds it on $BUILDKIT_HOST (TLS from $BUILDKIT_TLSDIR) with
#    TOOLS=<tools image> and the CN package mirrors, and pushes <repo>:<sha>;
#    the registry's own layer cache is <repo>:buildcache. Push credentials are
#    the caller's ~/.docker/config.json (the train's hub-acr step).
#
# Prints `image=<repo>:<sha>` and `digest=sha256:…` (also to $GITHUB_OUTPUT when
# set). Exit 0 pushed · 1 failed (the reason on stderr) · 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HUB=${1:-} SHA=${2:-} REPO=${3:-} TOOLS=${4:-}
if [ -z "$HUB" ] || [ -z "$REPO" ] || [ -z "$TOOLS" ] \
    || ! printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{40}$'; then
  echo 'usage: train-build.sh <hub> <sha> <image repo> <tools image>' >&2
  exit 2
fi
HUB=${HUB%/}
: "${BUILDKIT_HOST:?train-build.sh: BUILDKIT_HOST is not set (the cluster buildkitd)}"
DEBIAN_MIRROR=${FLEET_IMAGE_DEBIAN_MIRROR-http://mirrors.aliyun.com/debian}
NPM_REGISTRY=${FLEET_IMAGE_NPM_REGISTRY-https://registry.npmmirror.com}
PIP_INDEX=${FLEET_IMAGE_PIP_INDEX-https://mirrors.aliyun.com/pypi/simple}

W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
step() { printf '[train-build] %s\n' "$*" >&2; }

step "release $SHA: manifest, checked against conf/release-keys/root.pub"
cp "$ROOT/conf/release-keys/root.pub" "$W/release.pub" || exit 1
curl -fsS --retry 3 -D "$W/h.txt" -o "$W/manifest.json" "$HUB/v1/fleet/release/$SHA" \
  || { echo "train-build.sh: the hub has no release $SHA" >&2; exit 1; }
sig=$(tr -d '\r' < "$W/h.txt" | sed -n 's/^[Xx]-[Cc]cquota-[Rr]elease-[Ss]ignature: //p' | head -n 1)
out=$(python3 -I "$ROOT/bin/fleet-release-verify.py" "$W/release.pub" "$W/manifest.json" "$sig" ccquota-linux-amd64) \
  || { echo "train-build.sh: release $SHA does not verify against the pinned root" >&2; exit 1; }
[ "$(printf '%s\n' "$out" | sed -n 1p | cut -d' ' -f1)" = "$SHA" ] \
  || { echo "train-build.sh: the hub answered another release for $SHA" >&2; exit 1; }
want=$(printf '%s\n' "$out" | sed -n 2p)
printf '%s' "$want" | grep -Eq '^[0-9a-f]{64}$' \
  || { echo "train-build.sh: release $SHA names no ccquota-linux-amd64" >&2; exit 1; }

step "ccquota-linux-amd64 by its signed sha256"
curl -fsS --retry 3 -o "$W/ccquota" "$HUB/v1/fleet/release/$SHA/artifacts/ccquota-linux-amd64" || exit 1
[ "$(sha256sum "$W/ccquota" | cut -d' ' -f1)" = "$want" ] \
  || { echo "train-build.sh: ccquota-linux-amd64 is not the bytes the release signed" >&2; exit 1; }
chmod 755 "$W/ccquota"

step "build context (prepare-image.sh)"
CCQUOTA="$W/ccquota" bash "$HERE/prepare-image.sh" "$HUB" "$W/release.pub" "$SHA" "$W/ctx" linux-amd64 >&2 \
  || exit 1

step "buildctl → $REPO:$SHA (TOOLS=$TOOLS)"
tls=(); [ -z "${BUILDKIT_TLSDIR:-}" ] || tls=(--tlsdir "$BUILDKIT_TLSDIR")
start=$(date +%s)
buildctl --addr "$BUILDKIT_HOST" ${tls[@]+"${tls[@]}"} build \
  --frontend dockerfile.v0 \
  --local context="$W/ctx" --local dockerfile="$W/ctx" \
  --opt platform=linux/amd64 \
  --opt build-arg:TOOLS="$TOOLS" \
  --opt build-arg:DEBIAN_MIRROR="$DEBIAN_MIRROR" \
  --opt build-arg:NPM_REGISTRY="$NPM_REGISTRY" \
  --opt build-arg:PIP_INDEX="$PIP_INDEX" \
  --output "type=image,name=$REPO:$SHA,push=true" \
  --import-cache "type=registry,ref=$REPO:buildcache" \
  --export-cache "type=registry,ref=$REPO:buildcache,mode=max" \
  --metadata-file "$W/meta.json" \
  --progress plain >&2 || { echo "train-build.sh: the build failed" >&2; exit 1; }
digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("containerimage.digest") or "")' "$W/meta.json")
printf '%s' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$' \
  || { echo "train-build.sh: pushed, but buildctl named no digest" >&2; exit 1; }
step "pushed in $(( $(date +%s) - start ))s"
printf 'image=%s:%s\ndigest=%s\n' "$REPO" "$SHA" "$digest"
[ -z "${GITHUB_OUTPUT:-}" ] || printf 'image=%s:%s\ndigest=%s\n' "$REPO" "$SHA" "$digest" >> "$GITHUB_OUTPUT"
