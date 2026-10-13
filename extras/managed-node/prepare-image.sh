#!/bin/bash
# Prepare a build context from a signed release; tokens never enter the image.
# Usage: prepare-image.sh <hub> <release.pub> <40-character sha> <new-context-dir> [linux-amd64]
#
# The context must hold every artifact image-stage.py's `stage` takes — each
# tool and its helpers (#3017: codex-code-mode-host). `need` is that one list;
# it is checked here, so a context that would fail inside `docker build` fails
# now. A ccquota older than #3017 drops helpers from `--pinned`
# (issue #3554): then the release is fetched again whole and checked again.
# CCQUOTA names the ccquota to run (default: the one on PATH).
#
# Then, on any machine (Apple Silicon included — the classic builder takes a
# cached arm64 base for --platform linux/amd64, which Rosetta cannot run):
#   docker buildx build --platform linux/amd64 --load -t <image>:<sha> <context-dir>
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HUB=${1:-} KEY=${2:-} SHA=${3:-} DEST=${4:-} PLATFORM=${5:-linux-amd64}
if [ -z "$HUB" ] || [ ! -f "$KEY" ] || [ -z "$DEST" ] || [ -e "$DEST" ] \
    || ! printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{40}$'; then
  echo 'usage: prepare-image.sh <hub> <release.pub> <sha> <new-context-dir> [linux-amd64]' >&2
  exit 2
fi
case "$PLATFORM" in
  linux-amd64|linux-arm64) ARCH=${PLATFORM#linux-} ;;
  *) echo "prepare-image.sh: the image is linux-amd64 or linux-arm64, not $PLATFORM" >&2; exit 2 ;;
esac
CCQ=${CCQUOTA:-ccquota}

# missing <runtime-dir>: the artifacts stage wants that the context lacks
missing() {
  local n
  python3 -I "$HERE/image-stage.py" need "$1" "$ARCH" | while IFS= read -r n; do
    [ -f "$1/.release/artifacts/$n" ] || printf '%s\n' "$n"
  done
}

mkdir -m 700 "$DEST" || exit 1
"$CCQ" release fetch --hub "$HUB" --pubkey "$KEY" --artifacts --pinned --platform "$PLATFORM" \
  "$SHA" "$DEST/runtime" || exit 1
lack=$(missing "$DEST/runtime") || exit 1
if [ -n "$lack" ]; then
  printf 'prepare-image.sh: %s --pinned left out: %s — fetching the whole release instead\n' \
    "$("$CCQ" version 2>/dev/null | head -n 1)" "$(printf '%s' "$lack" | tr '\n' ' ')" >&2
  rm -rf "$DEST/runtime" || exit 1
  "$CCQ" release fetch --hub "$HUB" --pubkey "$KEY" --artifacts "$SHA" "$DEST/runtime" || exit 1
  lack=$(missing "$DEST/runtime") || exit 1
  if [ -n "$lack" ]; then
    printf 'prepare-image.sh: release %s carries no %s — the image cannot be built from it\n' \
      "$SHA" "$(printf '%s' "$lack" | tr '\n' ' ')" >&2
    exit 1
  fi
  # only what the image takes stays: the other platforms' artifacts go
  keep=$(python3 -I "$HERE/image-stage.py" need "$DEST/runtime" "$ARCH")
  for f in "$DEST/runtime/.release/artifacts"/*; do
    [ -e "$f" ] || continue
    printf '%s\n' "$keep" | grep -qxF "$(basename "$f")" || rm -f "$f"
  done
fi
cp "$KEY" "$DEST/release.pub" || exit 1
cp "$HERE/Dockerfile" "$HERE/image-stage.py" "$DEST/" || exit 1
cp -R "$HERE/devnet" "$DEST/devnet" || exit 1
echo "Verified build context: $DEST ($PLATFORM, $SHA)"
echo "Build: docker buildx build --platform linux/$ARCH --load -t <image>:$SHA $DEST"
