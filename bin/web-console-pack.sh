#!/bin/bash
# web-console-pack.sh — put the new console into the hub's build (#3925,
# EPIC #3923 C2).
#
#   web-console-pack.sh               copy extras/web-console/dist (committed,
#                                     rebuilt by its CI off the lockfile) into
#                                     tokenledger/web/console/ — gitignored but
#                                     its .gitkeep, emptied first, so nothing
#                                     stale rides along
#   web-console-pack.sh --out <dir>   the same, into <dir>
#
# The build has one directory per side: app/ (the member side, /app) and
# admin/ (the admin side, /admin), each an index.html and its assets/. The
# hub embeds web/console (web/embed.go) and serves /app/assets/ and
# /admin/assets/ off it (internal/api/app_mount.go), so a build packs first:
#
#   bin/fleet-client-pack.sh && bin/web-console-pack.sh && docker build -t ccquota tokenledger/
#
# No build yet (before the console's first page, C3) is not a failure: the
# script says so and leaves the directory empty — the hub then serves no new
# console (404), the old one as before.
#
# The theme the way-in pages wear (/signin, /fleet/login, /i/, the 404 —
# claude-fleet#3932) is packed every time, build or not: extras/fleet-theme's
# theme.css, fonts.css, fonts/*.woff2 and logo.svg go to tokenledger/web/theme/
# (gitignored but its .gitkeep), served at /app/assets/fleet-theme/.
#
#   web-console-pack.sh --theme-out <dir>   the theme into <dir>
#
# Exit: 0 ok (or nothing to pack) · 1 the build is broken · 2 usage.
set -euo pipefail
real="$0"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
DIST="$REPO/extras/web-console/dist"
OUT="$REPO/tokenledger/web/console"
THEME="$REPO/extras/fleet-theme"
THEME_OUT="$REPO/tokenledger/web/theme"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || { echo "web-console-pack: --out <dir>" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --theme-out) [ $# -ge 2 ] || { echo "web-console-pack: --theme-out <dir>" >&2; exit 2; }; THEME_OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "web-console-pack: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
case "$THEME_OUT" in /*) ;; *) THEME_OUT="$PWD/$THEME_OUT" ;; esac

# the theme, first: the way-in pages need it whether or not the console is built
mkdir -p "$THEME_OUT"
find "$THEME_OUT" -mindepth 1 ! -name .gitkeep -exec rm -rf {} + 2>/dev/null || true
mkdir -p "$THEME_OUT/fonts"
for f in theme.css fonts.css logo.svg; do
  [ -f "$THEME/$f" ] || { echo "web-console-pack: $THEME/$f is missing" >&2; exit 1; }
  cp "$THEME/$f" "$THEME_OUT/$f"
done
cp "$THEME"/fonts/*.woff2 "$THEME_OUT/fonts/"
if grep -Eq 'url\((["'"'"']?)https?:' "$THEME_OUT"/*.css; then
  echo "web-console-pack: $THEME_OUT loads from another origin" >&2; exit 1
fi
echo "web-console-pack: theme → $THEME_OUT"

mkdir -p "$OUT"
find "$OUT" -mindepth 1 ! -name .gitkeep -exec rm -rf {} + 2>/dev/null || true
if [ ! -f "$DIST/app/index.html" ] && [ ! -f "$DIST/admin/index.html" ]; then
  echo "web-console-pack: no build in $DIST yet — nothing packed"
  exit 0
fi
for side in app admin; do
  [ -d "$DIST/$side" ] || continue
  [ -f "$DIST/$side/index.html" ] || { echo "web-console-pack: $DIST/$side has no index.html" >&2; exit 1; }
  cp -R "$DIST/$side" "$OUT/$side"
done
# every byte is the console's own: no script, style or font from another origin
if grep -rEq '(src|href)="https?://' "$OUT"/*/index.html || grep -rEq 'fonts\.(googleapis|gstatic)\.com|cdn\.jsdelivr|unpkg\.com|cdnjs' "$OUT"; then
  echo "web-console-pack: $OUT loads from another origin" >&2; exit 1
fi
echo "web-console-pack: $OUT"
