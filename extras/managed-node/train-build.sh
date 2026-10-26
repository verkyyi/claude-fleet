#!/bin/bash
# Build and push the managed node image of one signed release, in the cluster
# (issue #3855): the release train's `node image` job runs it on the fleet-ack
# runner, beside the cluster's buildkitd — native amd64, ACR's VPC endpoint a
# hop away, and the hub too while it runs in that cluster (its Service).
#
# Usage: train-build.sh <hubs> <40-character sha> <image repo> <tools image> [<base image>]
#   <hubs>         one hub URL, or several in one argument separated by spaces,
#                  asked in order (the train: the hub's in-cluster Service when it
#                  has one, the hub it released to, then the hub's public names)
#   <image repo>   e.g. registry.example.com/acme/fleet-managed-node
#   <tools image>  the Dockerfile's `tools` stage as the train pushed it
#                  (<repo>:<tools-tag.sh>, best by digest)
#   <base image>   the Dockerfile's BASE as the train copied it (<repo>@<digest>,
#                  issue #4159); left out = the Dockerfile's Docker Hub default
#
# 1. The release's manifest is checked against the checkout's pinned root
#    (conf/release-keys/root.pub, fleet-release-verify.py — no ccquota needed),
#    and its ccquota-linux-amd64 is taken by the sha256 the signed manifest names.
# 2. prepare-image.sh, run with that ccquota, fetches and verifies the release
#    into a build context (the same road as a build by hand).
# 3. buildctl builds it on $BUILDKIT_HOST (TLS from $BUILDKIT_TLSDIR) with
#    TOOLS=<tools image> and the CN package mirrors, and pushes <repo>:<sha>;
#    the registry's own layer cache is <repo>:buildcache. Push credentials are
#    the caller's ~/.docker/config.json (the train's hub-acr step). A registry
#    that answered 5xx / did not resolve is tried again (3 tries, 30 s · 60 s
#    apart — issue #4159); any other failure is red at once.
#
# Which hub carries the bytes never matters: the manifest verifies against the
# pinned root and every artifact against the sha256 it signs, here and in
# ccquota — the transport is untrusted either way. So a hub that does not
# answer, or answers too slowly, is passed over for the next one. Every
# download is bounded (BREAK-IT train-hub-slow: two trains sat out the
# 45-minute job timeout on a hub serving 50 KB/s, silent, and held the lane):
# connect within FLEET_TRAIN_FETCH_CONNECT s (10), at least
# FLEET_TRAIN_FETCH_FLOOR bytes/s (204800) over every FLEET_TRAIN_FETCH_FLOOR_SECS
# (60), and the whole fetch (manifest, ccquota, the release) within
# FLEET_TRAIN_FETCH_SECS (720). Each download says its hub, size, time and rate;
# a hub dropped here is not handed to prepare-image.sh.
#
# Prints `image=<repo>:<sha>` and `digest=sha256:…` (also to $GITHUB_OUTPUT when
# set). Exit 0 pushed · 1 failed (the reason on stderr) · 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HUB=${1:-} SHA=${2:-} REPO=${3:-} TOOLS=${4:-} BASE=${5:-}
HUBS=''
for h in $HUB; do
  h=${h%/}
  case "$h" in http://*|https://*) ;; *) HUBS=''; break ;; esac
  case " $HUBS " in *" $h "*) ;; *) HUBS="$HUBS${HUBS:+ }$h" ;; esac
done
if [ -z "$HUBS" ] || [ -z "$REPO" ] || [ -z "$TOOLS" ] \
    || ! printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{40}$'; then
  echo 'usage: train-build.sh <hubs> <sha> <image repo> <tools image> [<base image>]' >&2
  exit 2
fi
: "${BUILDKIT_HOST:?train-build.sh: BUILDKIT_HOST is not set (the cluster buildkitd)}"
DEBIAN_MIRROR=${FLEET_IMAGE_DEBIAN_MIRROR-http://mirrors.aliyun.com/debian}
NPM_REGISTRY=${FLEET_IMAGE_NPM_REGISTRY-https://registry.npmmirror.com}
PIP_INDEX=${FLEET_IMAGE_PIP_INDEX-https://mirrors.aliyun.com/pypi/simple}
FETCH_SECS=${FLEET_TRAIN_FETCH_SECS:-720}
CONNECT=${FLEET_TRAIN_FETCH_CONNECT:-10}
FLOOR=${FLEET_TRAIN_FETCH_FLOOR:-204800}
FLOOR_SECS=${FLEET_TRAIN_FETCH_FLOOR_SECS:-60}
DEADLINE=$(( $(date +%s) + FETCH_SECS ))

W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
step() { printf '[train-build] %s\n' "$*" >&2; }
fail() {   # the one red line; on GitHub's runner an annotation
  if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::error::train-build.sh: %s\n' "$*" >&2
  else printf 'train-build.sh: %s\n' "$*" >&2; fi
}
warn() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::warning::train-build.sh: %s\n' "$*" >&2; else step "$*"; fi
}
mbps() { awk -v b="$1" 'BEGIN { if (b >= 1048576) printf "%.2f MB/s", b / 1048576; else printf "%.0f KB/s", b / 1024 }'; }
mb() { awk -v b="$1" 'BEGIN { if (b >= 1048576) printf "%.1f MB", b / 1048576; else printf "%.0f KB", b / 1024 }'; }
left() { echo $(( DEADLINE - $(date +%s) )); }
DROPPED=''   # hubs that failed a download: not asked again
dropped() { case " $DROPPED " in *" $1 "*) return 0 ;; esac; return 1; }

# get <url> <out> <cap seconds> [curl flags…]: one bounded download. Sets GOT
# (`<size> in <secs>s (<rate>)`), or WHY (what stopped it, with the rate) and 1.
get() {
  local url=$1 out=$2 cap=$3 mt w rc code size secs rate
  shift 3
  mt=$(left); [ "$mt" -le "$cap" ] || mt=$cap
  if [ "$mt" -le 0 ]; then WHY="not asked: the ${FETCH_SECS}s bound was spent"; return 1; fi
  w=$(curl -fsS --connect-timeout "$CONNECT" --speed-limit "$FLOOR" --speed-time "$FLOOR_SECS" --max-time "$mt" \
    -w '%{http_code} %{size_download} %{time_total} %{speed_download}' -o "$out" "$@" "$url" 2>"$W/curl.err"); rc=$?
  read -r code size secs rate <<< "$w"
  secs=${secs%.*}
  GOT="$(mb "${size:-0}") in ${secs:-0}s ($(mbps "${rate:-0}"))"
  WHY=''
  [ "$rc" = 0 ] && return 0
  case "$rc" in
    28) WHY="too slow: $(mb "${size:-0}") in ${secs:-?}s at $(mbps "${rate:-0}") (the floor is $(mbps "$FLOOR") over ${FLOOR_SECS}s, the cap ${mt}s)" ;;
    22) WHY="HTTP ${code:-?}" ;;
    6|7) WHY="no connection ($(tr -d '\n' < "$W/curl.err"))" ;;
    *) WHY="curl exit $rc at $(mbps "${rate:-0}") ($(tr -d '\n' < "$W/curl.err"))" ;;
  esac
  return 1
}

cp "$ROOT/conf/release-keys/root.pub" "$W/release.pub" || exit 1
MHUB='' tried=''
for hub in $HUBS; do
  step "release $SHA: manifest from $hub, checked against conf/release-keys/root.pub"
  if get "$hub/v1/fleet/release/$SHA" "$W/manifest.json" 60 --retry 2 --retry-delay 2 -D "$W/h.txt"; then
    step "manifest from $hub: $GOT"
    MHUB=$hub; break
  fi
  warn "$hub: no manifest for $SHA, $WHY"
  tried="$tried${tried:+; }$hub: $WHY"; DROPPED="$DROPPED $hub"
done
[ -n "$MHUB" ] || { fail "no hub answered release $SHA: $tried"; exit 1; }
sig=$(tr -d '\r' < "$W/h.txt" | sed -n 's/^[Xx]-[Cc]cquota-[Rr]elease-[Ss]ignature: //p' | head -n 1)
out=$(python3 -I "$ROOT/bin/fleet-release-verify.py" "$W/release.pub" "$W/manifest.json" "$sig" ccquota-linux-amd64) \
  || { fail "release $SHA from $MHUB does not verify against the pinned root"; exit 1; }
[ "$(printf '%s\n' "$out" | sed -n 1p | cut -d' ' -f1)" = "$SHA" ] \
  || { fail "$MHUB answered another release for $SHA"; exit 1; }
want=$(printf '%s\n' "$out" | sed -n 2p)
printf '%s' "$want" | grep -Eq '^[0-9a-f]{64}$' \
  || { fail "release $SHA names no ccquota-linux-amd64"; exit 1; }

step "ccquota-linux-amd64 by its signed sha256"
CHUB=''
for hub in $HUBS; do
  dropped "$hub" && continue
  if get "$hub/v1/fleet/release/$SHA/artifacts/ccquota-linux-amd64" "$W/ccquota" 300; then
    step "ccquota-linux-amd64 from $hub: $GOT"
    CHUB=$hub; break
  fi
  warn "$hub: ccquota-linux-amd64 $WHY, trying the next hub"
  tried="$tried${tried:+; }$hub: $WHY"; DROPPED="$DROPPED $hub"
done
[ -n "$CHUB" ] || { fail "no hub delivered ccquota-linux-amd64 of $SHA: $tried"; exit 1; }
[ "$(sha256sum "$W/ccquota" | cut -d' ' -f1)" = "$want" ] \
  || { fail "ccquota-linux-amd64 from $CHUB is not the bytes the release signed"; exit 1; }
chmod 755 "$W/ccquota"

# prepare-image.sh: the hub that just carried ccquota first, then the rest not dropped
PHUBS=$CHUB
for hub in $HUBS; do [ "$hub" = "$CHUB" ] || dropped "$hub" || PHUBS="$PHUBS $hub"; done
step "build context (prepare-image.sh) from $PHUBS, within $(left)s"
[ "$(left)" -gt 0 ] || { fail "the ${FETCH_SECS}s fetch bound was spent before the release itself"; exit 1; }
FLEET_IMAGE_FETCH_SECS=$(left) FLEET_IMAGE_FETCH_FLOOR=$FLOOR FLEET_IMAGE_FETCH_FLOOR_SECS=$FLOOR_SECS \
  CCQUOTA="$W/ccquota" bash "$HERE/prepare-image.sh" "$PHUBS" "$W/release.pub" "$SHA" "$W/ctx" linux-amd64 >&2 \
  || { fail "no build context for $SHA (prepare-image.sh above names each hub and its rate)"; exit 1; }

step "buildctl → $REPO:$SHA (TOOLS=$TOOLS${BASE:+ BASE=$BASE})"
tls=(); [ -z "${BUILDKIT_TLSDIR:-}" ] || tls=(--tlsdir "$BUILDKIT_TLSDIR")
base=(); [ -z "$BASE" ] || base=(--opt "build-arg:BASE=$BASE")
start=$(date +%s)
try=1
while :; do
  buildctl --addr "$BUILDKIT_HOST" ${tls[@]+"${tls[@]}"} build \
    --frontend dockerfile.v0 \
    --local context="$W/ctx" --local dockerfile="$W/ctx" \
    --opt platform=linux/amd64 \
    --opt build-arg:TOOLS="$TOOLS" ${base[@]+"${base[@]}"} \
    --opt build-arg:DEBIAN_MIRROR="$DEBIAN_MIRROR" \
    --opt build-arg:NPM_REGISTRY="$NPM_REGISTRY" \
    --opt build-arg:PIP_INDEX="$PIP_INDEX" \
    --output "type=image,name=$REPO:$SHA,push=true" \
    --import-cache "type=registry,ref=$REPO:buildcache" \
    --export-cache "type=registry,ref=$REPO:buildcache,mode=max" \
    --metadata-file "$W/meta.json" \
    --progress plain 2>&1 | tee "$W/build.log" >&2
  [ "${PIPESTATUS[0]}" -ne 0 ] || break
  if [ "$try" -lt 3 ] && grep -Eq 'failed to resolve source metadata|unexpected status from (HEAD|GET) request.*: 5[0-9][0-9]|(502|503|504) (Bad Gateway|Service Unavailable|Gateway Time-?out)|TLS handshake timeout|i/o timeout' "$W/build.log"; then
    step "a registry did not answer (try $try of 3) — again in $((try * 30))s"
    sleep $((try * 30)); try=$((try + 1)); continue
  fi
  echo "train-build.sh: the build failed" >&2; exit 1
done
digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("containerimage.digest") or "")' "$W/meta.json")
printf '%s' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$' \
  || { echo "train-build.sh: pushed, but buildctl named no digest" >&2; exit 1; }
step "pushed in $(( $(date +%s) - start ))s"
printf 'image=%s:%s\ndigest=%s\n' "$REPO" "$SHA" "$digest"
[ -z "${GITHUB_OUTPUT:-}" ] || printf 'image=%s:%s\ndigest=%s\n' "$REPO" "$SHA" "$digest" >> "$GITHUB_OUTPUT"
