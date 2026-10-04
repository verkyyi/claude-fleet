#!/bin/bash
# fleet-client-mirror.sh — keep the hub's embedded client a byte-for-byte copy
# of bin/ + conf/ (issues #1470, #1486).
#
#   fleet-client-mirror.sh           copy every file the manifest lists into
#                                    tokenledger/internal/api/fleetclient/ (the
#                                    same bin/ + conf/ layout) and remove a copy
#                                    the manifest no longer lists
#   fleet-client-mirror.sh --check   exit 0 when every copy matches its original
#                                    and nothing unlisted sits under the embed
#                                    dir's bin/ or conf/; else one line per
#                                    drift on stdout, exit 1
#
# Why a copy at all: the hub's Docker build context is tokenledger/ alone, and
# //go:embed cannot reach ../bin. Which files: fleetclient/manifest — the ONE
# place the client's file set is maintained (the hub serves it at
# /install/manifest; bin/fleet-install.sh walks it). TestFleetClientMatchesBin
# (Go) and fleet-install-selftest.sh leg A (shell) assert exactly what --check
# asserts, so a forgotten mirror reds whichever CI the change reaches.
#
# Exit: 0 ok · 1 drift (--check) · 2 no repo / manifest beside this script.
set -uo pipefail
# $0 may be a symlink in a shadow bin/ (run-selftests.sh, #660): follow it to the
# live tree, where tokenledger/ is beside bin/.
real="$0"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
CLIENT="$REPO/tokenledger/internal/api/fleetclient"
MANIFEST="$CLIENT/manifest"
[ -f "$MANIFEST" ] || { echo "fleet-client-mirror: no manifest at $MANIFEST" >&2; exit 2; }

# listed — the manifest's paths (every line that is not blank or a comment;
# the `installer` tag is a second word and does not matter here).
listed() { awk '!/^[[:space:]]*#/ && NF { print $1 }' "$MANIFEST"; }
# unlisted — files under the embed dir's bin/ and conf/ the manifest does not name.
unlisted() {
  local f rel
  for f in "$CLIENT"/bin/* "$CLIENT"/conf/*; do
    [ -f "$f" ] || continue
    rel="${f#"$CLIENT"/}"
    listed | grep -qxF "$rel" || printf '%s\n' "$rel"
  done
}

case "${1:-}" in
  --check)
    rc=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ ! -f "$REPO/$p" ]; then echo "missing original: $p"; rc=1
      elif [ ! -f "$CLIENT/$p" ]; then echo "not mirrored: $p — run bin/fleet-client-mirror.sh"; rc=1
      elif ! cmp -s "$REPO/$p" "$CLIENT/$p"; then echo "differs: fleetclient/$p ≠ $p — run bin/fleet-client-mirror.sh"; rc=1
      fi
    done <<EOT
$(listed)
EOT
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      echo "unlisted: fleetclient/$p is not in the manifest — add it there or remove the copy"; rc=1
    done <<EOT
$(unlisted)
EOT
    exit "$rc" ;;
  '')
    n=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ -f "$REPO/$p" ] || { echo "fleet-client-mirror: $p is in the manifest but not in the repo" >&2; exit 2; }
      mkdir -p "$CLIENT/$(dirname "$p")"
      cp -p "$REPO/$p" "$CLIENT/$p"; n=$((n + 1))
    done <<EOT
$(listed)
EOT
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      rm -f "$CLIENT/$p"; echo "removed fleetclient/$p (no longer in the manifest)"
    done <<EOT
$(unlisted)
EOT
    echo "mirrored $n file(s) into tokenledger/internal/api/fleetclient/" ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
