#!/bin/bash
# fleet-node-image-key.sh <git dir> <rev> — what the managed node image of <rev>
# is made of, as one digest (issue #4818): when it equals the image key of the
# commit stable's `node image` was built for, the release train re-tags that
# image for the new release instead of building another one (2+ minutes after
# the release, on the critical path of a pod following stable).
#
# The image's runtime is only a SEED (#3212): a pod copies it onto its volume on
# its first boot and from then on the machine updater moves `current` to stable,
# so a seed one release older is what every running pod had a minute ago. What
# a reused image must NOT get wrong is what runs before that update — so the key
# is, read from git (no checkout needed):
#   * extras/managed-node/          the recipe: Dockerfile, image-stage.py (the
#                                   boot), devnet/, the build scripts
#   * conf/release-keys/            the root the seed and every update verify by
#   * release.json                  the pinned ccquota / Claude Code / Codex / tmux
#   * the node source               bin/fleet-src-digest.py <dir> <rev>: what the
#                                   seed's ccquota is built from (shared/ + agent/)
#   * the node's root-run programs  bin/fleet-node-*.{py,sh}, bin/fleet_node_*.py,
#                                   bin/fleet-credsep.py, bin/fleet-release-verify.py,
#                                   bin/fleet_ed25519.py — the boot, the updater
#                                   and what they call (selftests left out)
# Anything else in the release (the rest of bin/, conf/, docs) the updater
# replaces on the pod's first tick.
#
# sha256 over "<path> <git blob id>\n" per file, sorted, then "node-src <digest>".
# Prints the hex key. Exit 0 · 2 usage / git cannot read <rev>.
set -uo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
[ "$#" = 2 ] || { echo 'usage: fleet-node-image-key.sh <git dir> <rev>' >&2; exit 2; }
dir=$1 rev=$2
git -C "$dir" rev-parse -q --verify "$rev^{commit}" >/dev/null 2>&1 \
  || { echo "fleet-node-image-key: $rev is not a commit in $dir" >&2; exit 2; }
files=$(git -C "$dir" ls-tree -r --full-tree "$rev" -- extras/managed-node conf/release-keys release.json bin 2>/dev/null) \
  || { echo "fleet-node-image-key: cannot list $rev" >&2; exit 2; }
src=$(python3 "$BIN/fleet-src-digest.py" "$dir" "$rev") \
  || { echo "fleet-node-image-key: no node source digest for $rev" >&2; exit 2; }
{
  printf '%s\n' "$files" | awk -F'\t' '
    { split($1, m, " "); p = $2 }
    m[2] != "blob" { next }
    p ~ /selftest/ { next }
    p ~ /^extras\/managed-node\// || p ~ /^conf\/release-keys\// || p == "release.json" ||
    p ~ /^bin\/fleet-node-[^\/]*\.(py|sh)$/ || p ~ /^bin\/fleet_node_[^\/]*\.py$/ ||
    p == "bin/fleet-credsep.py" || p == "bin/fleet-release-verify.py" || p == "bin/fleet_ed25519.py" {
      print p " " m[3]
    }' | LC_ALL=C sort
  printf 'node-src %s\n' "$src"
} | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1
