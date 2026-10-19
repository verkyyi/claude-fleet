#!/bin/bash
# fleet-client-mirror.sh — keep the hub's client manifest honest (issues
# #1470, #1486, #1725; retired to this in #1803; #4826).
#
#   fleet-client-mirror.sh           take out a leftover generated agent bundle
#                                    block (#4826), then say the manifest is current
#   fleet-client-mirror.sh --check   exit 0 when every path the manifest lists
#                                    exists in the repo, every tag is one it
#                                    knows and no agent bundle rides in it;
#                                    else one line per drift on stdout, exit 1
#
# There is no copy to mirror any more (#1803): the repo keeps ONE copy of each
# client file, and a hub build packs the manifest's files into the embed dir
# (bin/fleet-client-pack.sh). Which files: fleetclient/manifest — the ONE place
# the client's file set is maintained (the hub serves it at /install/manifest;
# bin/fleet-install.sh walks it). TestFleetClientMatchesBin (Go) and
# fleet-install-selftest.sh leg A (shell) assert what --check asserts.
#
# The Agent configuration package (issue #1725) used to ride the same list, as
# a block generated from conf/agent-bundle.manifest. It is 承载's now (issue
# #4826, EPIC #4823 decision 1): `fleet host on` installs it with the whole
# tree, so the client manifest carries none — --check reds a block that comes
# back, a plain run takes it out.
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

BEGIN='# --- agent bundle: generated from conf/agent-bundle.manifest by bin/fleet-client-mirror.sh — do not edit (#1725) ---'
END='# --- end agent bundle ---'

# listed — the manifest's paths (every line that is not blank or a comment;
# the `installer` / `served` tag is a second word and does not matter here).
listed() { awk '!/^[[:space:]]*#/ && NF { print $1 }' "$MANIFEST"; }
# badtags — a line whose second word is no tag the hub and the installer know
badtags() { awk '!/^[[:space:]]*#/ && NF > 1 && $2 != "installer" && $2 != "served" { print $1 " " $2 }' "$MANIFEST"; }

case "${1:-}" in
  --check)
    rc=0
    grep -qxF "$BEGIN" "$MANIFEST" \
      && { echo "stale: the manifest still carries the agent bundle block — 承载's since #4826; run bin/fleet-client-mirror.sh"; rc=1; }
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ -f "$REPO/$p" ] || { echo "missing original: $p is in the manifest but not in the repo"; rc=1; }
    done <<EOT
$(listed)
EOT
    while IFS= read -r t; do
      [ -n "$t" ] && { echo "unknown tag: $t (installer · served)"; rc=1; }
    done <<EOT
$(badtags)
EOT
    # a committed copy is the two-copies era coming back (#1803)
    for d in bin conf hooks commands skills mod; do
      [ -e "$CLIENT/$d" ] && { echo "copy: fleetclient/$d/ — the repo keeps one copy; a build packs it (bin/fleet-client-pack.sh)"; rc=1; }
    done
    exit "$rc" ;;
  '')
    if grep -qxF "$BEGIN" "$MANIFEST"; then
      awk -v b="$BEGIN" -v e="$END" '$0 == b { on = 1; next } on && $0 == e { on = 0; next } !on { print }' "$MANIFEST" > "$MANIFEST.tmp" \
        && mv -f "$MANIFEST.tmp" "$MANIFEST"
      echo "took the agent bundle block out of the manifest (#4826)"
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ -f "$REPO/$p" ] || { echo "fleet-client-mirror: $p is in the manifest but not in the repo" >&2; exit 2; }
    done <<EOT
$(listed)
EOT
    echo "manifest current: $(listed | wc -l | tr -d ' ') path(s)" ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
