#!/bin/bash
# fleet-train-prebuild.sh look   <repo> <tag> <sha>
# fleet-train-prebuild.sh verify <repo> <tag> <sha> <digest>
#   — the hub image the release train builds BESIDE its tests (issue #3867, EPIC
#   #3863 C4), and the check that the one it deploys is that one.
#
# The train's `hub build` (hub-deploy.yml, phase build) starts the moment the
# train boards, builds prod-<sha7> of TRAIN_SHA with the OCI label
# org.opencontainers.image.revision=<TRAIN_SHA> and pushes it; `hub / deploy`
# (phase deploy) runs only once the tests are green and builds nothing. Between
# the two the tag could be pushed over — a hand dispatch, an older train's build
# of the same sha7 — so the deploy refuses an image that is not the one its build
# reported (BREAK-IT train-prebuild-wrong-sha).
#
#   look    is <repo>:<tag> already TRAIN_SHA's? (a red train's build, kept in the
#           registry: the next train on the same sha deploys it as is). Prints
#           reuse=true|false and digest=<sha256:…> (also to $GITHUB_OUTPUT). An
#           image with another revision, or none, is reuse=false — never reused.
#   verify  <repo>:<tag> must resolve to <digest> (what this run's build pushed or
#           kept) AND carry revision <sha>: else exit 1 with the reason, and the
#           deploy stops before anything changes.
#
# Reads the registry with `docker buildx imagetools inspect` ($FLEET_IMAGETOOLS
# replaces `docker buildx imagetools`: the selftest's seam). No docker ⇒ look is
# reuse=false (a build then), verify is exit 2.
#
# Exit: 0 ok · 1 verify refused · 2 usage / cannot read the registry
set -uo pipefail
die() { printf 'fleet-train-prebuild: %s\n' "$*" >&2; exit 2; }
out() { printf '%s\n' "$@"; [ -z "${GITHUB_OUTPUT:-}" ] || printf '%s\n' "$@" >> "$GITHUB_OUTPUT"; }

cmd=${1:-}; repo=${2:-} tag=${3:-} sha=${4:-} want=${5:-}
case "$cmd" in look|verify) ;; *) die "usage: look <repo> <tag> <sha> | verify <repo> <tag> <sha> <digest>" ;; esac
[ -n "$repo" ] && [ -n "$tag" ] || die "$cmd: <repo> <tag> missing"
printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || die "$cmd: <sha> must be 40 hex, got '$sha'"
[ "$cmd" = look ] || printf '%s' "$want" | grep -Eq '^sha256:[0-9a-f]{64}$' || die "verify: <digest> must be sha256:<64 hex>, got '$want'"

if [ -n "${FLEET_IMAGETOOLS:-}" ]; then
  # shellcheck disable=SC2086  # the seam is a command line, word-split on purpose
  it() { $FLEET_IMAGETOOLS inspect "$@"; }
elif command -v docker >/dev/null 2>&1; then
  it() { docker buildx imagetools inspect "$@"; }
else
  [ "$cmd" = look ] || die "verify: no docker here to read $repo:$tag"
  out reuse=false digest=
  echo "look: no docker here — building" >&2
  exit 0
fi

# digest + revision of <repo>:<tag>; empty when the tag is not there
read_image() {
  digest=$(it "$repo:$tag" --format '{{json .Manifest}}' 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("digest") or "")' 2>/dev/null) || digest=""
  rev=""
  [ -z "$digest" ] || rev=$(it "$repo:$tag" --format '{{json .Image}}' 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
if "config" not in d and len(d) == 1:   # an index: {"linux/amd64": {...}}
    d = next(iter(d.values()))
print(((d.get("config") or {}).get("Labels") or {}).get("org.opencontainers.image.revision") or "")' 2>/dev/null) || rev=""
}
read_image

if [ "$cmd" = look ]; then
  if [ -n "$digest" ] && [ "$rev" = "$sha" ]; then
    out reuse=true "digest=$digest"
    echo "look: $repo:$tag is ${sha:0:7}'s already ($digest) — reused, nothing built" >&2
  else
    out reuse=false digest=
    if [ -z "$digest" ]; then echo "look: $repo:$tag is not there — building" >&2
    else echo "look: $repo:$tag is revision ${rev:-<none>}, not ${sha:0:7} — building over it" >&2; fi
  fi
  exit 0
fi

[ -n "$digest" ] || { echo "verify: $repo:$tag is not there (or the registry did not answer) — nothing deployed" >&2; exit 1; }
if [ "$digest" != "$want" ]; then
  echo "verify: $repo:$tag is $digest, not $want that this run's build pushed — another push overtook it; nothing deployed" >&2
  exit 1
fi
if [ "$rev" != "$sha" ]; then
  echo "verify: $repo:$tag ($digest) is revision ${rev:-<none>}, not the train's $sha — nothing deployed" >&2
  exit 1
fi
echo "verify: $repo:$tag = $digest, revision ${sha:0:7} — the image this run built"
