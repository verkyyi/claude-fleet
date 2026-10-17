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
WP="$BIN/fleet-wallpaper.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wallpaper-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
FAILS=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

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
[ "$rc" = 2 ] && [ -z "$out" ] && ok "A status --check off a managed machine: no row" || bad "A status rc=$rc out=[$out]"
wp off >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -s "$WORK/calls" ] && ok "A off refuses a person's own Mac" || bad "A off rc=$rc calls=[$(cat "$WORK/calls")]"
: > "$WORK/state/machine.env"

# B
reset
out=$(wp status --check); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'WallpaperAerialsExtension(frank) 4.3%' && printf '%s' "$out" | grep -q 'VTDecoderXPCService(frank) 2.1%' \
  && printf '%s' "$out" | grep -q 'fleet-wallpaper.sh off' && ok "B Aerial busy, no display → WARN naming both + the fix" || bad "B rc=$rc out=[$out]"
out=$(wp off --tick); rc=$?
if [ "$rc" = 0 ] && [ "$(calls osascript)" = 1 ] \
   && grep -q "^asuser 501 sudo -u frank -H osascript -l JavaScript -e " "$WORK/calls" \
   && grep -q "setDesktopImageURL" "$WORK/calls" && grep -qx "} $WORK/pic.png" "$WORK/calls" \
   && grep -qx "asuser 501 sudo -u frank -H defaults -currentHost write com.apple.screensaver idleTime -int 0" "$WORK/calls" \
   && [ -f "$WORK/state/wallpaper/frank" ] && printf '%s' "$out" | grep -q 'frank: dynamic → static'; then
  ok "B off: set once as frank in its GUI session, screen saver off, recorded, one line"
else bad "B off rc=$rc out=[$out] calls=[$(tr '\n' '|' < "$WORK/calls")]"; fi
out=$(wp status --check); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'changed once: frank' && ok "B after off: PASS naming the change" || bad "B after rc=$rc out=[$out]"

# C
: > "$WORK/calls"
out=$(wp off --tick); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s "$WORK/calls" ] && ok "C second pass: nothing called, quiet" || bad "C rc=$rc out=[$out] calls=[$(cat "$WORK/calls")]"
aerial
out=$(wp off --tick); rc=$?
[ "$rc" = 0 ] && [ ! -s "$WORK/calls" ] && ok "C switched back by hand: not changed again" || bad "C back rc=$rc calls=[$(cat "$WORK/calls")]"
out=$(wp status --check); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "Switched back by hand.*(frank)" && ok "C switched back → WARN, left as the person's choice" || bad "C status rc=$rc out=[$out]"
rm -rf "$WORK/state/wallpaper"

# D
for n in 1 '?'; do
  reset; echo "$n" > "$WORK/displays"
  out=$(wp off); rc=$?
  [ "$rc" = 0 ] && [ ! -s "$WORK/calls" ] && [ ! -e "$WORK/state/wallpaper/frank" ] && printf '%s' "$out" | grep -q 'display is connected' \
    && ok "D displays=$n: nothing touched" || bad "D displays=$n rc=$rc out=[$out] calls=[$(cat "$WORK/calls")]"
  out=$(wp status --check); rc=$?
  [ "$rc" = 0 ] && ok "D displays=$n: row PASS" || bad "D status rc=$rc out=[$out]"
done

# E
reset
out=$(FLEET_KEEP_WALLPAPER=1 wp off); rc=$?
[ "$rc" = 0 ] && [ ! -s "$WORK/calls" ] && ok "E FLEET_KEEP_WALLPAPER=1 (env): nothing touched" || bad "E env rc=$rc calls=[$(cat "$WORK/calls")]"
echo 'FLEET_KEEP_WALLPAPER=1' > "$WORK/state/machine.env"
out=$(wp off --tick); rc=$?
out2=$(wp status --check); rc2=$?
[ "$rc" = 0 ] && [ ! -s "$WORK/calls" ] && [ "$rc2" = 0 ] && printf '%s' "$out2" | grep -q 'kept' \
  && ok "E FLEET_KEEP_WALLPAPER=1 (machine.env): nothing touched, PASS «kept»" || bad "E conf rc=$rc/$rc2 out=[$out2]"
: > "$WORK/state/machine.env"; : > "$WORK/state/wallpaper.keep"
wp off --tick >/dev/null
[ ! -s "$WORK/calls" ] && ok "E wallpaper.keep: nothing touched" || bad "E keep calls=[$(cat "$WORK/calls")]"
rm -f "$WORK/state/wallpaper.keep"

# F
reset; echo 0 > "$WORK/screens"
wp off --tick >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -e "$WORK/state/wallpaper/frank" ] && [ "$(calls defaults)" = 0 ] \
  && ok "F no screen took it: failed, not recorded (tried again)" || bad "F rc=$rc rec=$(ls "$WORK/state/wallpaper" 2>/dev/null)"
reset; : > "$WORK/ps"
out=$(wp off --tick); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s "$WORK/calls" ] && ok "F tick with no Aerial running is quiet" || bad "F quiet rc=$rc out=[$out]"
if [ "$(id -u)" != 0 ]; then
  out=$(FLEET_NODE_STATE="$WORK/state" FLEET_WALLPAPER_PS="cat $WORK/ps" bash "$WP" off 2>&1); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'needs root' && ok "F off without root refuses" || bad "F root rc=$rc out=[$out]"
fi

# G
grep -q '/fleet-wallpaper.sh"' "$BIN/fleet-doctor.sh" && grep -q '_nwall" status --check' "$BIN/fleet-doctor.sh" && grep -q 'warn wallpaper' "$BIN/fleet-doctor.sh" \
  && ok "G doctor's wallpaper row reads status --check" || bad "G doctor has no wallpaper row"
grep -q '"fleet-wallpaper.sh"), "off", "--tick"' "$BIN/fleet-node-supervisor.py" && grep -q '"profile": "wallpaper-off"' "$BIN/fleet-node-supervisor.py" \
  && ok "G the machine daemon's wallpaper task runs off --tick (core: wallpaper-off)" || bad "G no wallpaper task in the supervisor"
grep -q '"wallpaper-off": ("fleet-wallpaper.sh", \["off", "--tick"\])' "$BIN/fleet-node-core.py" \
  && ok "G the root core's power profile wallpaper-off runs it" || bad "G no wallpaper-off profile in the core"

[ "$FAILS" = 0 ] && echo "fleet-wallpaper-selftest: all passed" || { echo "fleet-wallpaper-selftest: $FAILS failed"; exit 1; }
