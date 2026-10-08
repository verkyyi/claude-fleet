#!/bin/bash
# fleet-client-pack.sh — put the client the hub serves into its build (#1803).
#
#   fleet-client-pack.sh            copy every file the manifest lists, from
#                                   the repo, into the embed dir's pack/
#                                   (tokenledger/internal/api/fleetclient/pack/,
#                                   gitignored) — after emptying it, so a file
#                                   the manifest dropped never rides along
#   fleet-client-pack.sh --check    exit 0 when pack/ holds exactly the
#                                   manifest's files, each identical to the
#                                   repo's; else one line per drift, exit 1
#
# The repo keeps ONE copy of each client file — in bin/ conf/ hooks/ commands/
# skills/ mod/, where the selftests drive them. //go:embed cannot reach ../bin,
# so a hub build packs first, every time, never from a stale pack:
#
#   bin/fleet-client-pack.sh && docker build -t ccquota tokenledger/
#   bin/fleet-client-pack.sh && (cd tokenledger && go test ./...)
#
# The pack is a build input, never committed (only pack/doc.go is). A build with
# no pack still compiles — the hub then serves no client (fleetclient.Packed)
# and the Dockerfile refuses to build such an image.
#
# Which files: fleetclient/manifest — still the ONE list (bin/fleet-client-mirror.sh
# keeps its generated agent-bundle block current; the hub serves it at
# /install/manifest). Same bytes in ⇒ same /install/manifest and the same
# client_version on /version as when the files were committed copies.
#
# The static tmux (#2260): beside the client, pack/vendor/tmux-<platform> — the
# binary out of each archive conf/vendor-tmux.lock pins, SHA-256 checked, kept
# in ${XDG_CACHE_HOME:-~/.cache}/claude-fleet/vendor so a rebuild downloads
# nothing. The hub puts the one for the installer's platform into
# /install/bundle.tar.gz. A download that fails is a warning, never a failed
# pack: the bundle then carries no tmux and the installer fetches it itself
# (or falls back to Homebrew / apt). FLEET_PACK_VENDOR=0 skips it (offline
# builds, CI); --check never looks at vendor/.
#
# Exit: 0 ok · 1 drift (--check) · 2 no repo / manifest, or a listed file missing.
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
PACK="$CLIENT/pack"
[ -f "$MANIFEST" ] || { echo "fleet-client-pack: no manifest at $MANIFEST" >&2; exit 2; }

# listed — the manifest's paths (the installer's too: the hub fills it in and
# serves it at /install). Every line that is not blank or a comment.
listed() { awk '!/^[[:space:]]*#/ && NF { print $1 }' "$MANIFEST"; }

# sha256_of <file> — its SHA-256 hex (shasum on macOS, sha256sum on Linux)
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# pack_vendor — the static tmux of every platform conf/vendor-tmux.lock pins
pack_vendor() {
  [ "${FLEET_PACK_VENDOR:-1}" = 0 ] && return 0
  local lock="$REPO/conf/vendor-tmux.lock" cache plat sum url arc x n=0
  [ -f "$lock" ] || return 0
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/vendor"
  mkdir -p "$cache" "$PACK/vendor" || return 0
  while read -r plat sum url; do
    case "$plat" in ''|'#'*) continue ;; esac
    arc="$cache/$sum.tar.gz"
    if [ ! -f "$arc" ] || [ "$(sha256_of "$arc")" != "$sum" ]; then
      curl -fsSL --max-time 120 "$url" -o "$arc.part" 2>/dev/null && mv -f "$arc.part" "$arc" \
        || { rm -f "$arc.part"; echo "fleet-client-pack: WARN tmux $plat: download failed ($url) — the bundle carries no tmux for it" >&2; continue; }
    fi
    if [ "$(sha256_of "$arc")" != "$sum" ]; then
      rm -f "$arc"; echo "fleet-client-pack: WARN tmux $plat: SHA-256 mismatch — not packed" >&2; continue
    fi
    x="$(mktemp -d)"
    if tar -xzf "$arc" -C "$x" tmux 2>/dev/null && [ -f "$x/tmux" ]; then
      cp "$x/tmux" "$PACK/vendor/tmux-$plat" && chmod 0755 "$PACK/vendor/tmux-$plat" && n=$((n + 1))
    else
      echo "fleet-client-pack: WARN tmux $plat: no tmux in $url" >&2
    fi
    rm -rf "$x"
  done < "$lock"
  echo "packed the static tmux for $n platform(s) into pack/vendor/"
}

case "${1:-}" in
  --check)
    rc=0
    l="
$(listed)
"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ ! -f "$REPO/$p" ]; then echo "missing original: $p"; rc=1
      elif [ ! -f "$PACK/$p" ]; then echo "not packed: $p — run bin/fleet-client-pack.sh"; rc=1
      elif ! cmp -s "$REPO/$p" "$PACK/$p"; then echo "stale: pack/$p ≠ $p — run bin/fleet-client-pack.sh"; rc=1
      fi
    done <<EOT
$(listed)
EOT
    if [ -d "$PACK" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel="${f#"$PACK"/}"
        [ "$rel" = doc.go ] && continue
        case "$rel" in vendor/*) continue ;; esac
        case "$l" in *"
$rel
"*) ;; *) echo "unlisted: pack/$rel is not in the manifest — run bin/fleet-client-pack.sh"; rc=1 ;; esac
      done <<EOT
$(find "$PACK" -type f)
EOT
    fi
    exit "$rc" ;;
  '')
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ -f "$REPO/$p" ] || { echo "fleet-client-pack: $p is in the manifest but not in the repo" >&2; exit 2; }
    done <<EOT
$(listed)
EOT
    # empty it (keeping the tracked doc.go), then copy: a dropped file never stays
    mkdir -p "$PACK"
    find "$PACK" -mindepth 1 -maxdepth 1 ! -name doc.go -exec rm -rf {} +
    n=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      mkdir -p "$PACK/$(dirname "$p")"
      cp -p "$REPO/$p" "$PACK/$p"; n=$((n + 1))
    done <<EOT
$(listed)
EOT
    echo "packed $n file(s) into tokenledger/internal/api/fleetclient/pack/"
    pack_vendor ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
