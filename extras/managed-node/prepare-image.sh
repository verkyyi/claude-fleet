#!/bin/bash
# Prepare a build context from a signed release; tokens never enter the image.
# Usage: prepare-image.sh <hub> <release.pub> <40-character sha> <new-context-dir> [linux-amd64]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HUB=${1:-} KEY=${2:-} SHA=${3:-} DEST=${4:-} PLATFORM=${5:-linux-amd64}
if [ -z "$HUB" ] || [ ! -f "$KEY" ] || [ -z "$DEST" ] || [ -e "$DEST" ] \
    || ! printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{40}$'; then
  echo 'usage: prepare-image.sh <hub> <release.pub> <sha> <new-context-dir> [linux-amd64]' >&2
  exit 2
fi
mkdir -m 700 "$DEST" || exit 1
ccquota release fetch --hub "$HUB" --pubkey "$KEY" --artifacts --pinned --platform "$PLATFORM" \
  "$SHA" "$DEST/runtime" || exit 1
cp "$KEY" "$DEST/release.pub" || exit 1
cp "$HERE/Dockerfile" "$HERE/image-stage.py" "$DEST/" || exit 1
echo "Verified build context: $DEST ($PLATFORM, $SHA)"
