#!/bin/bash
# web-chat-pack.sh — put the website's /chat page into the hub's build (#3646,
# EPIC #3642 C4).
#
#   web-chat-pack.sh               build extras/web-chat/ui for the website
#                                  (`vite build --mode site`: base /chat/, its API
#                                  the entry's /v1/chat, the site's top bar) into
#                                  tokenledger/web/dist/chat/ — gitignored, emptied
#                                  first, so nothing stale rides along
#   web-chat-pack.sh --out <dir>   the same, into <dir>
#
# The repo keeps ONE source of the page, extras/web-chat/ui — the same one
# ui/dist (the conversation service's own copy, committed) is built from. The
# hub embeds web/dist whole (web/embed.go), so a build packs first, like the
# client (bin/fleet-client-pack.sh):
#
#   bin/fleet-client-pack.sh && bin/web-chat-pack.sh && docker build -t ccquota tokenledger/
#
# A binary built without it serves no /chat (the page says so, 404). Needs node
# (npm ci off the lockfile — nothing fetched that the lockfile does not pin).
#
# Exit: 0 ok · 1 the build failed · 2 usage / no repo / no npm.
set -euo pipefail
real="$0"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
UI="$REPO/extras/web-chat/ui"
OUT="$REPO/tokenledger/web/dist/chat"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || { echo "web-chat-pack: --out <dir>" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "web-chat-pack: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -f "$UI/package-lock.json" ] || { echo "web-chat-pack: no $UI/package-lock.json" >&2; exit 2; }
command -v npm >/dev/null 2>&1 || { echo "web-chat-pack: npm not found (the page is built with node)" >&2; exit 2; }
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

cd "$UI"
[ -d node_modules ] || npm ci --no-audit --no-fund >&2 || exit 1
rm -rf "$OUT"
npx --no-install tsc -p . >&2 || exit 1
npx --no-install vite build --mode site --outDir "$OUT" --emptyOutDir >&2 || exit 1
[ -f "$OUT/index.html" ] || { echo "web-chat-pack: no index.html in $OUT" >&2; exit 1; }
# every byte is the page's own: no script, style or font from another origin
if grep -rEq '(src|href)="https?://' "$OUT/index.html" || grep -rEq 'fonts\.(googleapis|gstatic)\.com|cdn\.jsdelivr|unpkg\.com|cdnjs' "$OUT"; then
  echo "web-chat-pack: $OUT loads from another origin" >&2; exit 1
fi
echo "web-chat-pack: $OUT"
