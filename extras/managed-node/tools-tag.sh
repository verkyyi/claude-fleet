#!/bin/bash
# Print the tag of the Dockerfile's `tools` stage: tools-<16 hex of its text>.
# Usage: tools-tag.sh [<Dockerfile>]
#
# The release train pushes that stage once per text as <image>:<tag> from a
# GitHub-hosted runner, and the in-cluster build takes it by that name (#3855):
# a pin moved in the stage is a new tag, so a build never takes a stale copy.
set -euo pipefail
DF=${1:-"$(cd "$(dirname "$0")" && pwd)/Dockerfile"}
stage=$(awk '/^FROM .* AS tools$/ {on=1} /^FROM .* AS toolsrc$/ {on=0} on' "$DF")
[ -n "$stage" ] || { echo "tools-tag.sh: no 'FROM … AS tools' stage in $DF" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
  h=$(printf '%s\n' "$stage" | sha256sum)
else
  h=$(printf '%s\n' "$stage" | shasum -a 256)
fi
echo "tools-${h:0:16}"
