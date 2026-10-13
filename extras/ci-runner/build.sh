#!/bin/bash
# Build and push the fleet-ci-runner image (issue #3864) when its tag is new.
# Usage: build.sh <image repo> [--force]
#   <image repo>  e.g. registry.example.com/acme/fleet-ci-runner
#
# Runs in the cluster, on a fleet-ack runner (.github/workflows/ci-runner-image.yml):
# buildctl on $BUILDKIT_HOST (TLS from $BUILDKIT_TLSDIR), the repo root as the
# context, extras/ci-runner/Dockerfile, pushed as <repo>:<tag.sh> with the
# registry's own layer cache at <repo>:buildcache. Push and pull credentials are
# the caller's ~/.docker/config.json (the workflow's hub-acr step). A tag already
# in the registry is a look and nothing built — unless --force.
#
# Prints `image=<repo>:<tag>`, `digest=sha256:…` and `built=true|false` (also to
# $GITHUB_OUTPUT when set). Exit 0 · 1 failed (the reason on stderr) · 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REPO=${1:-} FORCE=${2:-}
[ -n "$REPO" ] && { [ -z "$FORCE" ] || [ "$FORCE" = --force ]; } \
  || { echo 'usage: build.sh <image repo> [--force]' >&2; exit 2; }
TAG=$(bash "$HERE/tag.sh" "$ROOT") || exit 1
out() {
  printf '%s\n' "$@"
  [ -z "${GITHUB_OUTPUT:-}" ] || printf '%s\n' "$@" >> "$GITHUB_OUTPUT"
}

# The registry's answer for <repo>:<tag>: its digest, or nothing (absent / unreadable).
remote_digest() {
  python3 -I - "$REPO" "$TAG" <<'PY'
import base64, json, os, re, sys, urllib.request, urllib.error
repo, tag = sys.argv[1], sys.argv[2]
host, name = repo.split("/", 1)
try:
    auths = json.load(open(os.path.expanduser("~/.docker/config.json"))).get("auths", {})
    basic = (auths.get(host) or {}).get("auth", "")
except Exception:
    basic = ""
url = "https://%s/v2/%s/manifests/%s" % (host, name, tag)
accept = ", ".join(["application/vnd.oci.image.index.v1+json", "application/vnd.oci.image.manifest.v1+json",
                    "application/vnd.docker.distribution.manifest.v2+json",
                    "application/vnd.docker.distribution.manifest.list.v2+json"])
def head(h):
    r = urllib.request.Request(url, method="HEAD", headers=dict(h, Accept=accept))
    return urllib.request.urlopen(r, timeout=20)
try:
    try:
        resp = head({})
    except urllib.error.HTTPError as e:
        if e.code != 401:
            raise
        ch = e.headers.get("WWW-Authenticate", "")
        kv = dict(re.findall(r'(\w+)="([^"]*)"', ch))
        q = "%s?service=%s&scope=%s" % (kv["realm"], kv.get("service", ""), kv.get("scope", "repository:%s:pull" % name))
        tr = urllib.request.Request(q, headers={"Authorization": "Basic " + basic} if basic else {})
        tok = json.load(urllib.request.urlopen(tr, timeout=20))
        resp = head({"Authorization": "Bearer " + (tok.get("token") or tok.get("access_token", ""))})
    print(resp.headers.get("Docker-Content-Digest", ""))
except Exception:
    pass
PY
}

have=$(remote_digest)
if [ -n "$have" ] && [ "$FORCE" != --force ]; then
  echo "[ci-runner] $REPO:$TAG is already there ($have) — nothing built" >&2
  out "image=$REPO:$TAG" "digest=$have" "built=false"
  exit 0
fi
: "${BUILDKIT_HOST:?build.sh: BUILDKIT_HOST is not set (the cluster buildkitd)}"
tls=(); [ -z "${BUILDKIT_TLSDIR:-}" ] || tls=(--tlsdir "$BUILDKIT_TLSDIR")
meta=$(mktemp) || exit 1
trap 'rm -f "$meta"' EXIT
start=$(date +%s)
echo "[ci-runner] buildctl → $REPO:$TAG" >&2
buildctl --addr "$BUILDKIT_HOST" ${tls[@]+"${tls[@]}"} build \
  --frontend dockerfile.v0 \
  --local context="$ROOT" --local dockerfile="$HERE" \
  --opt filename=Dockerfile \
  --opt platform=linux/amd64 \
  --opt build-arg:TAG="$TAG" \
  --output "type=image,name=$REPO:$TAG,push=true" \
  --import-cache "type=registry,ref=$REPO:buildcache" \
  --export-cache "type=registry,ref=$REPO:buildcache,mode=max" \
  --metadata-file "$meta" \
  --progress plain >&2 || { echo "build.sh: the build failed" >&2; exit 1; }
digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("containerimage.digest") or "")' "$meta")
printf '%s' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$' \
  || { echo "build.sh: pushed, but buildctl named no digest" >&2; exit 1; }
echo "[ci-runner] pushed in $(( $(date +%s) - start ))s" >&2
out "image=$REPO:$TAG" "digest=$digest" "built=true"
