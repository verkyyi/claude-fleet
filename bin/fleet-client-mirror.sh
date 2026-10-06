#!/bin/bash
# fleet-client-mirror.sh — keep the hub's client manifest current (issues
# #1470, #1486, #1725; retired to this in #1803).
#
#   fleet-client-mirror.sh           rewrite the manifest's generated agent
#                                    bundle block from conf/agent-bundle.manifest
#   fleet-client-mirror.sh --check   exit 0 when that block is current and every
#                                    path the manifest lists exists in the repo;
#                                    else one line per drift on stdout, exit 1
#
# There is no copy to mirror any more (#1803): the repo keeps ONE copy of each
# client file, and a hub build packs the manifest's files into the embed dir
# (bin/fleet-client-pack.sh). Which files: fleetclient/manifest — the ONE place
# the client's file set is maintained (the hub serves it at /install/manifest;
# bin/fleet-install.sh walks it). TestFleetClientMatchesBin (Go) and
# fleet-install-selftest.sh leg A (shell) assert what --check asserts.
#
# The Agent configuration package (issue #1725) rides the same list: its files
# are conf/agent-bundle.manifest's, expanded by bin/fleet-agent-bundle.py into a
# GENERATED block at the end of the manifest (between the `agent bundle` marker
# lines — never edit it by hand). A plain run rewrites the block; --check reds a
# block that no longer matches the expansion, like any other drift.
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
# bundle_block — the generated block: the package's files the hand-kept part of
# the manifest does not list already, in the package's order.
bundle_block() {
  local hand files
  hand="$(awk -v b="$BEGIN" '$0 == b { exit } !/^[[:space:]]*#/ && NF { print $1 }' "$MANIFEST")"
  files="$(python3 "$REPO/bin/fleet-agent-bundle.py" files --root "$REPO")" || return 1
  printf '%s\n' "$BEGIN"
  printf '%s\n' "$files" | grep -vxF -f <(printf '%s\n' "$hand") || true
  printf '%s\n' "$END"
}
# current_block — the block as the manifest holds it now (empty when absent).
current_block() { awk -v b="$BEGIN" -v e="$END" '$0 == b { on = 1 } on { print } $0 == e { on = 0 }' "$MANIFEST"; }

# listed — the manifest's paths (every line that is not blank or a comment;
# the `installer` tag is a second word and does not matter here).
listed() { awk '!/^[[:space:]]*#/ && NF { print $1 }' "$MANIFEST"; }

case "${1:-}" in
  --check)
    rc=0
    if ! want="$(bundle_block)"; then
      echo "agent bundle: bin/fleet-agent-bundle.py files failed"; rc=1
    elif [ "$want" != "$(current_block)" ]; then
      echo "stale: the manifest's agent bundle block ≠ conf/agent-bundle.manifest — run bin/fleet-client-mirror.sh"; rc=1
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ -f "$REPO/$p" ] || { echo "missing original: $p is in the manifest but not in the repo"; rc=1; }
    done <<EOT
$(listed)
EOT
    # a committed copy is the two-copies era coming back (#1803)
    for d in bin conf hooks commands skills mod; do
      [ -e "$CLIENT/$d" ] && { echo "copy: fleetclient/$d/ — the repo keeps one copy; a build packs it (bin/fleet-client-pack.sh)"; rc=1; }
    done
    exit "$rc" ;;
  '')
    want="$(bundle_block)" || { echo "fleet-client-mirror: bin/fleet-agent-bundle.py files failed" >&2; exit 2; }
    if [ "$want" != "$(current_block)" ]; then
      { awk -v b="$BEGIN" '$0 == b { exit } { print }' "$MANIFEST"; printf '%s\n' "$want"; } > "$MANIFEST.tmp" \
        && mv -f "$MANIFEST.tmp" "$MANIFEST"
      echo "rewrote the manifest's agent bundle block"
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
