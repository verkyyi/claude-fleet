#!/usr/bin/env bash
# fleet-client-badge.sh — the left end of the client's status bar: WHO IS SIGNED
# IN (issue #2365, overturning #1779's ⌂ <machine> · <terminal>). The bar holds
# three things — this login, the ⟳ slot, the keys of where the keyboard is — so
# while all is well this is the GitHub login alone:
#
#   verkyyi                        signed in, the hub answers (blue)
#   verkyyi · 入口连不上           (orange) a hub is set but cannot be asked
#   verkyyi · 入口不认这台电脑 · 请重新扫码（fleet login）
#                                  (orange) the hub answered 401: it refused this
#                                  machine's certificate (issue #2112) — scan again;
#                                  a tap on it runs fleet login
#   verkyyi                        (orange) nobody holds the client lease
#   a bar narrower than 60 columns: the login only, in its colour
#
# The login is the connection certificate's principal (`fleet login` — the GitHub
# login the hub signed it for: `ssh-keygen -L` on ${FLEET_CERT:-~/.ssh/fleet-cert}-cert.pub),
# else this computer's user (no hub, no certificate).
#
# conf/tmux-shell.conf: status-left "#(bash __BIN__/fleet-client-badge.sh cw=#{client_width})".
# The state is fleet-client-where.sh --json (state · hub) — never a second way to
# tell. It is asked at most every FLEET_CLIENT_BADGE_TTL seconds (10): the bar
# ticks every 2 s, so between asks this prints off the cached fields, and a width
# change still redraws at once. Every word is a fleet-ui-lang.sh key (badge_*);
# the colours are the palette's (orange = PAL_YELLOW).
#
# After it, the client's own update (issue #1781, fleet-client-update.sh's
# update.state): `✓ 已更新到 <commit>` (`✓ 已重新载入新文件` for a home with no .client-version, #2145) or the one-line failure for
# FLEET_CLIENT_UPDATE_SHOW seconds (60; 4 before #1829 — too short to notice) after it happened, and
# `新版已就绪 · 下次打开生效` for as long as a change waits for a restart.
#
# Seams (tests): FLEET_CLIENT_BADGE_WHERE_CMD (the where read),
# FLEET_CLIENT_BADGE_CACHE (the cache dir), FLEET_CLIENT_BADGE_LOGIN (the login),
# FLEET_CLIENT_BADGE_TTL.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

cw=''
for a in "$@"; do case "$a" in cw=*) cw=${a#cw=} ;; esac; done
case "$cw" in ''|*[!0-9]*) cw=999 ;; esac

. "$BIN/fleet-ui-lang.sh"
. "$BIN/fleet-palette.sh"
if fleet_palette_load "$BIN/../conf/fleet-palette.conf"; then
  OK="#[fg=$PAL_BLUE,bold]" WARN="#[fg=$PAL_YELLOW,bold]" DIM="#[fg=$PAL_DIM]"
else
  OK='' WARN='' DIM=''
fi

CDIR="${FLEET_CLIENT_BADGE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/shell/tmp}"
CF="$CDIR/badge.user.row"   # state · hub · login (#2365; badge.row was #1779's six fields)
TTL="${FLEET_CLIENT_BADGE_TTL:-10}"
case "$TTL" in ''|*[!0-9]*) TTL=10 ;; esac

fresh=0
if [ "$TTL" -gt 0 ] && [ -f "$CF" ]; then
  m=$(stat -c %Y "$CF" 2>/dev/null || stat -f %m "$CF" 2>/dev/null)   # GNU first: its `stat -f` is filesystem status, exit 0
  case "$m" in ''|*[!0-9]*) ;; *) [ $(( $(date +%s) - m )) -lt "$TTL" ] && fresh=1 ;; esac
fi
if [ "$fresh" = 0 ]; then
  # one line: state hub login, \037-separated (not a tab: IFS whitespace would
  # fold an empty field into its neighbour)
  row=$(${FLEET_CLIENT_BADGE_WHERE_CMD:-bash "$BIN/fleet-client-where.sh" --json} 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except ValueError:
    d = {}
f = lambda k: " ".join(str(d.get(k) or "").split())
print("\x1f".join([f("state") or "unknown", f("hub") or "down"]))
' 2>/dev/null)
  [ -n "$row" ] || row=$(printf 'unknown\037down')
  login=${FLEET_CLIENT_BADGE_LOGIN:-}
  if [ -z "$login" ]; then
    # the certificate's first principal — `Principals:` then one indented line each
    login=$(ssh-keygen -L -f "${FLEET_CERT:-$HOME/.ssh/fleet-cert}-cert.pub" 2>/dev/null \
      | awk '/^[[:space:]]*Principals:/ { p = 1; next } p { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }')
  fi
  [ -n "$login" ] || login=$(id -un 2>/dev/null)
  row="$row"$'\037'"${login:-?}"
  mkdir -p "$CDIR" 2>/dev/null
  { printf '%s\n' "$row" > "$CF.$$" && mv -f "$CF.$$" "$CF"; } 2>/dev/null || rm -f "$CF.$$" 2>/dev/null
else
  row=$(head -n 1 "$CF" 2>/dev/null)
fi

IFS=$'\037' read -r st hub login <<EOF
$row
EOF

col=$OK key=badge_user_fmt
if [ "$hub" = down ]; then
  col=$WARN; key=badge_hubdown_fmt
elif [ "$hub" = refused ]; then
  col=$WARN; key=badge_hubrefused_fmt
elif [ "$st" != active ]; then
  col=$WARN
fi
[ "$cw" -lt 60 ] && key=badge_user_fmt

text=$(fleet_ui_t "$key" "${login:-?}")
if [ "$key" = badge_hubrefused_fmt ]; then
  # one tap scans again (conf/tmux-shell.conf's MouseDown1Status, `rescan`)
  printf '#[range=user|rescan]%s %s #[norange]#[default]%s│' "$col" "${text//#/##}" "$DIM"
else
  printf '%s %s #[default]%s│' "$col" "${text//#/##}" "$DIM"
fi

# --- the client's own update (issue #1781): one more segment, or nothing
UST="${FLEET_CLIENT_UPDATE_STATE:-${FLEET_SHELL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/shell}/update.state}"
[ -s "$UST" ] || exit 0
SHOW="${FLEET_CLIENT_UPDATE_SHOW:-60}"
case "$SHOW" in ''|*[!0-9]*) SHOW=60 ;; esac
# the bar ticks every 2 s: an old state that waits for nothing is no read at all
m=$(stat -c %Y "$UST" 2>/dev/null || stat -f %m "$UST" 2>/dev/null)   # GNU first, as above
case "$m" in ''|*[!0-9]*) m=0 ;; esac
[ $(( $(date +%s) - m )) -lt "$SHOW" ] || grep -q '"phase": "later"' "$UST" 2>/dev/null || exit 0
urow=$(python3 -c '
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
f = lambda k: " ".join(str(d.get(k) or "").split())
age = int(time.time()) - int(d.get("at") or 0)
print("\x1f".join([f("phase"), str(age), (f("commit") or f("to"))[:12], f("why")]))
' "$UST" 2>/dev/null)
IFS=$'\037' read -r uph uage uto uwhy <<EOF
$urow
EOF
case "$uage" in ''|*[!0-9]*) uage=999999 ;; esac
utext=''; ucol=$OK
case "$uph" in
  done)   [ "$uage" -lt "$SHOW" ] && utext=$(fleet_ui_t badge_updated_fmt "${uto:-?}") ;;
  reloaded) [ "$uage" -lt "$SHOW" ] && utext=$(fleet_ui_t badge_reloaded) ;;   # no .client-version (#2145)
  failed) [ "$uage" -lt "$SHOW" ] && { utext=$(fleet_ui_t badge_update_failed_fmt "${uwhy:-?}"); ucol=$WARN; } ;;
  later)  utext=$(fleet_ui_t badge_update_later); ucol=$WARN ;;
esac
[ -n "$utext" ] && printf '%s %s #[default]%s│' "$ucol" "${utext//#/##}" "$DIM"
exit 0
