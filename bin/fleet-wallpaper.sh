#!/bin/bash
# fleet-wallpaper.sh — a headless managed Mac runs a STATIC desktop (issue #4362,
# EPIC #4354 C8).
#
# A dynamic (Aerial) desktop on a Mac mini with no display attached costs ~10–15%
# of a core all day — WallpaperAerialsExtension decoding video through
# VTDecoderXPCService, WindowServer compositing it — and nobody sees it (mini2,
# 2026-10-15). So on a managed Mac with NO display connected, each login running
# the Aerial extension gets the system's own solid-colour picture and its screen
# saver off, ONCE: a login changed before (<state>/wallpaper/<login>) is never
# changed again — switched back by hand, it is the person's choice, and only the
# doctor's `wallpaper` row says so (发起人拍板 1, 2026-10-15).
#
#   fleet-wallpaper.sh off [--tick]     root: converge; one line per login changed.
#                                       --tick (the machine daemon's task) is quiet
#                                       when nothing changed
#   fleet-wallpaper.sh status [--check] any login: one line. --check exit 0 fine ·
#                                       1 WARN (WallpaperAerialsExtension /
#                                       VTDecoderXPCService busy, no display) · 2 not
#                                       a managed Mac (no row)
#
# The change runs AS the login, in its GUI session (`launchctl asuser <uid> sudo -u
# <login>`): osascript's JavaScript bridge calls NSWorkspace setDesktopImageURL for
# every screen — no Apple Event, so no Automation prompt that nobody could answer
# on a headless machine — then `defaults -currentHost write com.apple.screensaver
# idleTime 0`. A display connected (or system_profiler unreadable) ⇒ nothing is
# touched. Not a managed machine (no <state>/machine.env) ⇒ off refuses — a
# person's own Mac is theirs. Kept: FLEET_KEEP_WALLPAPER=1 (the environment or
# <state>/machine.env), or <state>/wallpaper.keep.
#
# Env (sandbox seams): FLEET_NODE_STATE (/var/db/fleet-node) · FLEET_NODE_TEST=1
# (no root needed) · FLEET_WALLPAPER_PS (a command printing `uid user etime pcpu
# command` rows) · FLEET_WALLPAPER_DISPLAYS (a command printing how many displays
# are connected) · FLEET_WALLPAPER_LAUNCHCTL · FLEET_WALLPAPER_SUDO ·
# FLEET_WALLPAPER_OSASCRIPT · FLEET_WALLPAPER_DEFAULTS · FLEET_WALLPAPER_IMAGE (the
# static picture) · FLEET_WALLPAPER_HOT_PCT (1) · FLEET_WALLPAPER_HOT_SECS (600)
# Exit: see above · 2 usage
set -uo pipefail

PROG=fleet-wallpaper
STATE="${FLEET_NODE_STATE:-/var/db/fleet-node}"
LAUNCHCTL="${FLEET_WALLPAPER_LAUNCHCTL:-launchctl}"
SUDO="${FLEET_WALLPAPER_SUDO:-/usr/bin/sudo}"
OSASCRIPT="${FLEET_WALLPAPER_OSASCRIPT:-/usr/bin/osascript}"
DEFAULTS="${FLEET_WALLPAPER_DEFAULTS:-/usr/bin/defaults}"
IMAGE="${FLEET_WALLPAPER_IMAGE:-/System/Library/Desktop Pictures/Solid Colors/Black.png}"
HOT_PCT="${FLEET_WALLPAPER_HOT_PCT:-1}"
HOT_SECS="${FLEET_WALLPAPER_HOT_SECS:-600}"
DONE="$STATE/wallpaper"
FIX="sudo ~/.claude/fleet/bin/fleet-wallpaper.sh off"
# every screen's picture through NSWorkspace (no Apple Event); prints how many took it
JXA='ObjC.import("AppKit");
function run(argv) {
  var u = $.NSURL.fileURLWithPath(argv[0]), ws = $.NSWorkspace.sharedWorkspace,
      s = $.NSScreen.screens, n = 0;
  for (var i = 0; i < s.count; i++)
    if (ws.setDesktopImageURLForScreenOptionsError(u, s.objectAtIndex(i), $.NSDictionary.dictionary, null)) n++;
  return String(n);
}'

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

managed() { [ -e "$STATE/machine.env" ]; }

kept() {
  [ "${FLEET_KEEP_WALLPAPER:-}" = 1 ] && return 0
  [ -e "$STATE/wallpaper.keep" ] && return 0
  grep -qE '^(export )?FLEET_KEEP_WALLPAPER=["'\'']?1["'\'']?$' "$STATE/machine.env" 2>/dev/null
}

# procs — `uid user etime pcpu name` for every running process (name = basename)
procs() {
  if [ -n "${FLEET_WALLPAPER_PS:-}" ]; then sh -c "$FLEET_WALLPAPER_PS"
  else ps -axo uid=,user=,etime=,pcpu=,comm= 2>/dev/null; fi | awk '{ n = $5; sub(/.*\//, "", n); print $1, $2, $3, $4, n }'
}

# aerial — `uid user` once per person running the Aerial wallpaper extension
aerial() {
  procs | awk '$5 == "WallpaperAerialsExtension" && $1 + 0 >= 500 && !seen[$1]++ { print $1, $2 }'
}

# hot — `name(user) pcpu%` for a dynamic-wallpaper process at ≥ HOT_PCT for ≥ HOT_SECS
hot() {
  procs | awk -v pct="$HOT_PCT" -v secs="$HOT_SECS" '
    function age(e,   d, p, n, s, i) {
      d = 0; if (index(e, "-")) { d = substr(e, 1, index(e, "-") - 1); e = substr(e, index(e, "-") + 1) }
      n = split(e, p, ":"); s = 0
      for (i = 1; i <= n; i++) s = s * 60 + p[i]
      return d * 86400 + s }
    $5 ~ /^(WallpaperAerialsExtension|VTDecoderXPCService)$/ && $4 + 0 >= pct && age($3) >= secs {
      printf "%s%s(%s) %s%%", (n++ ? ", " : ""), $5, $2, $4 }'
}

# hot_users — the users a busy dynamic-wallpaper process runs as
hot_users() {
  procs | awk -v pct="$HOT_PCT" '$5 ~ /^(WallpaperAerialsExtension|VTDecoderXPCService)$/ && $4 + 0 >= pct && !seen[$2]++ { print $2 }'
}

# displays — how many displays are connected; `?` when it cannot tell
displays() {
  if [ -n "${FLEET_WALLPAPER_DISPLAYS:-}" ]; then sh -c "$FLEET_WALLPAPER_DISPLAYS"; return; fi
  system_profiler -json SPDisplaysDataType 2>/dev/null | /usr/bin/python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("?"); sys.exit()
print(sum(len(g.get("spdisplays_ndrvs") or []) for g in d.get("SPDisplaysDataType") or []))'
}

# changed — the logins this machine changed once, `login (date)` comma-joined
changed() {
  local f out=""
  for f in "$DONE"/*; do
    [ -f "$f" ] || continue
    out="${out:+$out, }$(basename "$f") ($(sed -n 's/^changed_at=//p' "$f" | cut -c1-10))"
  done
  printf '%s' "$out"
}

cmd_status() {
  local check="${1:-}" ht n u back="" ch
  if ! managed; then
    [ -n "$check" ] || echo "wallpaper  not a managed machine ($STATE/machine.env missing) — left as it is"
    return 2
  fi
  ch=$(changed)
  if kept; then
    echo "dynamic desktop kept on (FLEET_KEEP_WALLPAPER=1 / $STATE/wallpaper.keep — the machine's choice)"; return 0
  fi
  ht=$(hot)
  if [ -z "$ht" ]; then
    echo "static desktop — no dynamic-wallpaper process busy${ch:+; changed once: $ch}"; return 0
  fi
  n=$(displays)
  if [ "$n" != 0 ]; then
    echo "a display is connected (${n}) — the desktop is left as it is (busy: $ht)"; return 0
  fi
  for u in $(hot_users); do [ -f "$DONE/$u" ] && back="${back:+$back, }$u"; done
  if [ -n "$back" ]; then
    echo "dynamic desktop busy with no display — $ht. Switched back by hand after the fleet changed it once ($back): left as the person's choice; to change it again, delete $DONE/<login> and run \`$FIX\`"
  else
    echo "dynamic desktop busy with no display — $ht. The machine daemon changes it within the hour; now: \`$FIX\`"
  fi
  return 1
}

cmd_off() {
  local tick="${1:-}" uid user n todo="" rc=0 out
  managed || { echo "$PROG: not a managed machine ($STATE/machine.env missing) — refusing to change a person's desktop" >&2; return 1; }
  if [ "$(id -u)" != 0 ] && [ "${FLEET_NODE_TEST:-}" != 1 ]; then
    echo "$PROG: off needs root — $FIX" >&2; return 1
  fi
  if kept; then
    [ -n "$tick" ] || echo "wallpaper  kept (FLEET_KEEP_WALLPAPER=1 / $STATE/wallpaper.keep)"
    return 0
  fi
  while read -r uid user; do
    [ -n "$user" ] || continue
    [ -f "$DONE/$user" ] && continue
    todo="${todo}${uid} ${user}
"
  done <<EOF
$(aerial)
EOF
  if [ -z "$todo" ]; then
    [ -n "$tick" ] || echo "wallpaper  nothing to change (no dynamic desktop running, or changed once already)"
    return 0
  fi
  n=$(displays)
  if [ "$n" != 0 ]; then
    [ -n "$tick" ] || echo "wallpaper  a display is connected (${n}) — left as it is"
    return 0
  fi
  [ -f "$IMAGE" ] || { echo "$PROG: no static picture at $IMAGE" >&2; return 1; }
  mkdir -p "$DONE" || return 1
  while read -r uid user; do
    [ -n "$user" ] || continue
    out=$("$LAUNCHCTL" asuser "$uid" "$SUDO" -u "$user" -H "$OSASCRIPT" -l JavaScript -e "$JXA" "$IMAGE" 2>&1)
    case "$out" in
      ''|0|*[!0-9]*)
        echo "$PROG: $user: could not set the static picture (${out:-no screen}) — tried again next pass" >&2
        rc=1; continue ;;
    esac
    "$LAUNCHCTL" asuser "$uid" "$SUDO" -u "$user" -H "$DEFAULTS" -currentHost write com.apple.screensaver idleTime -int 0 >/dev/null 2>&1 \
      || echo "$PROG: $user: could not turn the screen saver off" >&2
    printf 'changed_at=%s\nimage=%s\nscreens=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$IMAGE" "$out" > "$DONE/$user"
    echo "wallpaper  $user: dynamic → static ($(basename "$IMAGE"), $out screen(s)), screen saver off — not changed again"
  done <<EOF
$todo
EOF
  return "$rc"
}

case "${1:-}" in
  status) shift; case "${1:-}" in ''|--check) cmd_status "${1:-}" ;; *) usage >&2; exit 2 ;; esac ;;
  off) shift; case "${1:-}" in ''|--tick) cmd_off "${1:-}" ;; *) usage >&2; exit 2 ;; esac ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
