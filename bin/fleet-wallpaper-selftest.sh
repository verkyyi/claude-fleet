#!/bin/bash
# fleet-wallpaper-selftest.sh — bin/fleet-wallpaper.sh (issue #4362): a headless
# managed Mac runs a static desktop, and the doctor's `wallpaper` row says when not.
#
#   A  not a managed machine: status --check says nothing (2), off refuses (1)
#   B  no display + the Aerial extension running for a login → WARN; off sets the
#      picture AS that login (launchctl asuser <uid> sudo -u <login>) exactly once,
#      turns its screen saver off, records it → PASS
#   C  the second pass (the daemon's next start) calls nothing; switched back by
#      hand → WARN naming it, still not changed again
#   D  a display connected (or unreadable) → nothing called; the row is PASS
#   E  FLEET_KEEP_WALLPAPER=1 (env or machine.env) / wallpaper.keep → nothing called
#   F  a set that reports no screen is not recorded (tried again); tick quiet when
#      nothing to do; off without root refuses
#   G  fleet-doctor.sh's `wallpaper` row, the machine daemon's `wallpaper` task and
#      the root core's `wallpaper-off` profile call this script
#
# Hermetic: fake ps / launchctl / display count over files in a temp dir; nothing
# touches a real login's desktop. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
WP="$BIN/fleet-wallpaper.sh"
st_sandbox "${TMPDIR:-/tmp}/wallpaper-selftest.XXXXXX"
st_tally

mkdir -p "$WORK/state" "$WORK/bin"
: > "$WORK/pic.png"
# launchctl asuser <uid> sudo -u <login> -H <cmd> …: logged; osascript answers
# $WORK/screens and (when it took) stops the login's Aerial rows
cat > "$WORK/bin/launchctl" <<EOF
#!/bin/bash
echo "\$*" >> "$WORK/calls"
case "\$7" in
  osascript) n=\$(cat "$WORK/screens"); [ "\$n" = 0 ] || grep -v " \$5 " "$WORK/ps" > "$WORK/ps.n"; [ -f "$WORK/ps.n" ] && mv "$WORK/ps.n" "$WORK/ps"; echo "\$n" ;;
esac
EOF
chmod +x "$WORK/bin/"*
wp() {
  FLEET_NODE_STATE="$WORK/state" FLEET_NODE_TEST=1 FLEET_WALLPAPER_LAUNCHCTL="$WORK/bin/launchctl" \
  FLEET_WALLPAPER_SUDO=sudo FLEET_WALLPAPER_OSASCRIPT=osascript FLEET_WALLPAPER_DEFAULTS=defaults \
  FLEET_WALLPAPER_PS="cat $WORK/ps" FLEET_WALLPAPER_DISPLAYS="cat $WORK/displays" \
  FLEET_WALLPAPER_IMAGE="$WORK/pic.png" bash "$WP" "$@"
}
aerial() {
  printf '88 _windowserver 6-02:45:31 6.9 /x/WindowServer\n' > "$WORK/ps"
  printf '501 frank 6-02:45:28 4.3 /x/WallpaperAerialsExtension.appex/Contents/MacOS/WallpaperAerialsExtension\n' >> "$WORK/ps"
  printf '501 frank 6-02:45:28 2.1 /x/VTDecoderXPCService\n' >> "$WORK/ps"
}
reset() { aerial; echo 0 > "$WORK/displays"; echo 1 > "$WORK/screens"; : > "$WORK/calls"; }
calls() { grep -c "$1" "$WORK/calls"; }

# A
reset
out=$(wp status --check); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && st_ok "A status --check off a managed machine: no row" || st_miss "A status rc=$rc out=[$out]"
wp off >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -s "$WORK/calls" ] && st_ok "A off refuses a person's own Mac" || st_miss "A off rc=$rc calls=[$(cat "$WORK/calls")]"
: > "$WORK/state/machine.env"

# B
reset
out=$(wp status --check); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'WallpaperAerialsExtension(frank) 4.3%' && printf '%s' "$out" | grep -q 'VTDecoderXPCService(frank) 2.1%' \
  && printf '%s' "$out" | grep -q 'fleet-wallpaper.sh off' && st_ok "B Aerial busy, no display → WARN naming both + the fix" || st_miss "B rc=$rc out=[$out]"
out=$(wp off --tick); rc=$?
if [ "$rc" = 0 ] && [ "$(calls osascript)" = 1 ] \
   && grep -q "^asuser 501 sudo -u frank -H osascript -l JavaScript -e " "$WORK/calls" \
   && grep -q "setDesktopImageURL" "$WORK/calls" && grep -qx "} $WORK/pic.png" "$WORK/calls" \
   && grep -qx "asuser 501 sudo -u frank -H defaults -currentHost write com.apple.screensaver idleTime -int 0" "$WORK/calls" \
   && [ -f "$WORK/state/wallpaper/frank" ] && printf '%s' "$out" | grep -q 'frank: dynamic → static'; then
  st_ok "B off: set once as frank in its GUI session, screen saver off, recorded, one line"
else st_miss "B off rc=$rc out=[$out] calls=[$(tr '\n' '|' < "$WORK/calls")]"; fi
out=$(wp status --check); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'changed once: frank' && st_ok "B after off: PASS naming the change" || st_miss "B after rc=$rc out=[$out]"

# C
: > "$WORK/calls"
out=$(wp off --tick); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s "$WORK/calls" ] && st_ok "C second pass: nothing called, quiet" || st_miss "C rc=$rc out=[$out] calls=[$(cat "$WORK/calls")]"
aerial
out=$(wp off --tick); rc=$?
[ "$rc" = 0 ] && [ ! -s "$WORK/calls" ] && st_ok "C switched back by hand: not changed again" || st_miss "C back rc=$rc calls=[$(cat "$WORK/calls")]"
out=$(wp status --check); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "Switched back by hand.*(frank)" && st_ok "C switched back → WARN, left as the person's choice" || st_miss "C status rc=$rc out=[$out]"
rm -rf "$WORK/state/wallpaper"

# D
for n in 1 '?'; do
  reset; echo "$n" > "$WORK/displays"
  out=$(wp off); rc=$?
  [ "$rc" = 0 ] && [ ! -s "$WORK/calls" ] && [ ! -e "$WORK/state/wallpaper/frank" ] && printf '%s' "$out" | grep -q 'display is connected' \
    && st_ok "D displays=$n: nothing touched" || st_miss "D displays=$n rc=$rc out=[$out] calls=[$(cat "$WORK/calls")]"
  out=$(wp status --check); rc=$?
  [ "$rc" = 0 ] && st_ok "D displays=$n: row PASS" || st_miss "D status rc=$rc out=[$out]"
done

# E
reset
out=$(FLEET_KEEP_WALLPAPER=1 wp off); rc=$?
[ "$rc" = 0 ] && [ ! -s "$WORK/calls" ] && st_ok "E FLEET_KEEP_WALLPAPER=1 (env): nothing touched" || st_miss "E env rc=$rc calls=[$(cat "$WORK/calls")]"
echo 'FLEET_KEEP_WALLPAPER=1' > "$WORK/state/machine.env"
out=$(wp off --tick); rc=$?
out2=$(wp status --check); rc2=$?
[ "$rc" = 0 ] && [ ! -s "$WORK/calls" ] && [ "$rc2" = 0 ] && printf '%s' "$out2" | grep -q 'kept' \
  && st_ok "E FLEET_KEEP_WALLPAPER=1 (machine.env): nothing touched, PASS «kept»" || st_miss "E conf rc=$rc/$rc2 out=[$out2]"
: > "$WORK/state/machine.env"; : > "$WORK/state/wallpaper.keep"
wp off --tick >/dev/null
[ ! -s "$WORK/calls" ] && st_ok "E wallpaper.keep: nothing touched" || st_miss "E keep calls=[$(cat "$WORK/calls")]"
rm -f "$WORK/state/wallpaper.keep"

# F
reset; echo 0 > "$WORK/screens"
wp off --tick >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -e "$WORK/state/wallpaper/frank" ] && [ "$(calls defaults)" = 0 ] \
  && st_ok "F no screen took it: failed, not recorded (tried again)" || st_miss "F rc=$rc rec=$(ls "$WORK/state/wallpaper" 2>/dev/null)"
reset; : > "$WORK/ps"
out=$(wp off --tick); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s "$WORK/calls" ] && st_ok "F tick with no Aerial running is quiet" || st_miss "F quiet rc=$rc out=[$out]"
if [ "$(id -u)" != 0 ]; then
  out=$(FLEET_NODE_STATE="$WORK/state" FLEET_WALLPAPER_PS="cat $WORK/ps" bash "$WP" off 2>&1); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'needs root' && st_ok "F off without root refuses" || st_miss "F root rc=$rc out=[$out]"
fi

# G
grep -q '/fleet-wallpaper.sh"' "$BIN/fleet-doctor.sh" && grep -q '_nwall" status --check' "$BIN/fleet-doctor.sh" && grep -q 'warn wallpaper' "$BIN/fleet-doctor.sh" \
  && st_ok "G doctor's wallpaper row reads status --check" || st_miss "G doctor has no wallpaper row"
grep -q '"fleet-wallpaper.sh"), "off", "--tick"' "$BIN/fleet-node-supervisor.py" && grep -q '"profile": "wallpaper-off"' "$BIN/fleet-node-supervisor.py" \
  && st_ok "G the machine daemon's wallpaper task runs off --tick (core: wallpaper-off)" || st_miss "G no wallpaper task in the supervisor"
grep -q '"wallpaper-off": ("fleet-wallpaper.sh", \["off", "--tick"\])' "$BIN/fleet-node-core.py" \
  && st_ok "G the root core's power profile wallpaper-off runs it" || st_miss "G no wallpaper-off profile in the core"

st_done
