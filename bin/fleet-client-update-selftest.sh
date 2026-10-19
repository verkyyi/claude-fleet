#!/bin/bash
# fleet-client-update-selftest.sh — the client keeps up with its hub by itself
# (issue #1722): bin/fleet-client-update.sh (start / stage / doctor) and the
# pieces that read what it writes (bin/fleet, fleet-lib.sh's hub-defaults.conf),
# against a fake hub reached over
# file:// — /version, /v1/fleet/client-settings and /install are files — so no
# port is bound. HOME is a sandbox.
#
# Legs:
#   A. degenerate  no .client-version (a checkout, a --no-hub install) → start
#                  exits 0 and asks nothing, writes nothing; bin/fleet still
#                  dispatches as before
#   B. same        the hub's client_version = ours → 0, nothing staged; the
#                  team's defaults land in hub-defaults.conf, a bad key / value
#                  dropped; sourced in the readers' order a key fleet.conf sets
#                  and an exported one both win over the hub's
#   C. behind      compat ok → 0 at once, a background stage into
#                  <home>.versions/<v> (.next names it); the next start switches
#                  (exit 3, 「已更新到 <commit>」): <home> becomes a link to it, the
#                  old plain-dir home adopted as <home>.versions/<old> (.prev) —
#                  at the first start (#1829), the note written
#   D. below min   → staged + switched before opening: exit 3, 已更新到 …
#   E. fails       below min and the installer fails → exit 0, one 更新失败
#                  line, the home untouched
#   F. no hub      the hub out of reach → exit 0, nothing changed; and the
#                  hourly throttle: a second start inside it asks nothing
#   G. off         FLEET_CLIENT_AUTO_UPDATE=0 → no stage; the defaults still land
#   H. doctor      `doctor` prints one PASS/WARN/INFO row naming 版本 · 入口 ·
#                  证书 (the thin client needs no tmux here, issue #3008); `fleet doctor` on a client-only home prints it as
#                  the `fleet` row (the `client` row before #1806); no installed client → INFO
#   I. bin/fleet   a staged client is switched by `fleet` itself, which then runs
#                  the NEW bin/fleet's client (once — FLEET_CLIENT_UPDATED); staged at the
#                  old <home>.next, it is taken over as a version first
#   J. carry+tidy  (issue #4827) a switch keeps what is the person's — a file
#                  they put in and a fleet file they edited that the new version
#                  drops — and leaves the fleet's unchanged one behind
#                  (installed.list); a version dir past the current + .prev and
#                  a staging dir a crashed run left go at the next start
#   K. poll        (issue #4916) the connected 看台's ask: the hourly stamp does not
#                  hold it; same version → 0, nothing staged; behind → staged in
#                  the foreground, exit 10, the home untouched (start switches);
#                  FLEET_CLIENT_AUTO_UPDATE=0 → 0, nothing staged
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-client-update-selftest.XXXXXX") || exit 2
trap 'tmux -L "fcu$$" kill-server 2>/dev/null; rm -rf "${WORK:?}"' EXIT INT TERM HUP
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

export HOME="$WORK/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share"
export FLEET_SHELL_SESSION="fcu$$"   # never the operator's running client
export FLEET_NODE_STATE="$WORK/no-node"   # a device, even when this runs on a managed machine
unset FLEET_SHELL_CACHE FLEET_CLIENT_UPDATE_STATE
unset FLEET_CONF_DIR FLEET_HUB_URL CCQUOTA_HUB_URL FLEET_CLIENT_ROOT FLEET_CLIENT_STATE FLEET_CLIENT_UPDATED FLEET_CLIENT_AUTO_UPDATE FLEET_CLIENT_CHECK_SECS FLEET_UI_LANG FLEET_SHELL_PREFIX FLEET_SHELL
CONF="$XDG_CONFIG_HOME/claude-fleet"
ROOT="$XDG_DATA_HOME/claude-fleet"
STATE="$XDG_CACHE_HOME/claude-fleet/client"
HUBD="$WORK/hub"
HUB="file://$HUBD"
mkdir -p "$CONF" "$HUBD/v1/fleet" "$HUBD/new"

# install_client <version> [compat] — a fresh "installed" home: the real
# update script + a stand-in fleet, and the mark the installer writes
install_client() {
  rm -rf "$ROOT" "$ROOT.next" "$ROOT.prev" "$ROOT.next.lock" "$ROOT.versions" "$STATE"
  mkdir -p "$ROOT/bin"
  cp "$BIN/fleet-client-update.sh" "$BIN/fleet-versions-lib.sh" "$ROOT/bin/"   # the switch ships beside it (#1900)
  printf '#!/bin/sh\necho OLD\n' > "$ROOT/bin/fleet"; chmod +x "$ROOT/bin/fleet"
  printf 'version=%s\ncompat=%s\ncommit=c0ffee1\nhub=%s\n' "$1" "${2:-1}" "$HUB" > "$ROOT/.client-version"
}
# hub <client_version> <compat> <min> [commit]
hub() {
  printf '{"version":"prod-%s","commit":"%s","client_version":"%s","client_compat":%s,"min_client_compat":%s}\n' \
    "${4:-beef002}" "${4:-beef002}" "$1" "$2" "$3" > "$HUBD/version"
}
# the hub's installer: copies the new client into FLEET_INSTALL_HOME, with
# the mark; $HUBD/fail makes it fail
cat > "$HUBD/install" <<'SH'
#!/bin/sh
d=${FLEET_HUB_URL#file://}
[ -f "$d/fail" ] && { echo "boom: the hub's files are broken" >&2; exit 1; }
mkdir -p "$FLEET_INSTALL_HOME/bin"
cp "$d/new/"* "$FLEET_INSTALL_HOME/bin/"
chmod +x "$FLEET_INSTALL_HOME/bin/"*
v=$(sed -n 's/.*"client_version":"\([^"]*\)".*/\1/p' "$d/version")
c=$(sed -n 's/.*"commit":"\([^"]*\)".*/\1/p' "$d/version")
printf 'version=%s\ncompat=1\ncommit=%s\nhub=%s\n' "$v" "$c" "$FLEET_HUB_URL" > "$FLEET_INSTALL_HOME/.client-version"
SH
cp "$BIN/fleet-client-update.sh" "$BIN/fleet-versions-lib.sh" "$HUBD/new/"
printf '#!/bin/sh\necho NEW "$@"\n' > "$HUBD/new/fleet"
printf 'FLEET_HUB_URL=%s\n' "$HUB" > "$CONF/fleet.conf"
cat > "$HUBD/v1/fleet/client-settings" <<'JSON'
{"settings":{"FLEET_UI_LANG":"en","FLEET_SHELL_PREFIX":"C-a","FLEET_SHELL_WIDTH":"40","FLEET_HUB_URL":"https://evil.example","FLEET_NODE_ALIASES":"it's","FLEET_SHELL_WARM":"ghp_abcdefabcdef"},"keys":[]}
JSON

start() { bash "$ROOT/bin/fleet-client-update.sh" start 2>"$WORK/err"; }
stamp_old() { [ -f "$STATE/checked" ] && echo 0 > "$STATE/checked"; }

# --- A. degenerate ---------------------------------------------------------
install_client v1; rm -f "$ROOT/.client-version"; hub v2 1 1
start; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$STATE" ] && [ ! -e "$CONF/hub-defaults.conf" ] && [ ! -s "$WORK/err" ]; then
  ok "A no .client-version: exit 0, asked nothing, wrote nothing"
else bad "A degenerate: rc=$rc state=$(ls "$STATE" 2>&1) err=$(cat "$WORK/err")"; fi

# --- B. same version + the team's defaults ---------------------------------
install_client v1; hub v1 1 1
start; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$ROOT.next" ]; then ok "B same version: exit 0, nothing staged"
else bad "B same: rc=$rc next=$(ls "$ROOT.next" 2>&1)"; fi
hd="$CONF/hub-defaults.conf"
if [ -f "$hd" ] && grep -q "FLEET_UI_LANG='en'" "$hd" && grep -q "FLEET_SHELL_PREFIX='C-a'" "$hd" \
   && ! grep -q 'FLEET_HUB_URL\|FLEET_NODE_ALIASES\|FLEET_SHELL_WARM\|evil\|ghp_' "$hd"; then
  ok "B hub-defaults.conf: whitelisted keys written, address / unquotable / secret-shaped dropped"
else bad "B hub-defaults.conf: $(cat "$hd" 2>&1)"; fi
grep -q '不合规' "$WORK/err" && ok "B a dropped key is named on stderr" || bad "B no note for the dropped keys: $(cat "$WORK/err")"
# the readers' order: hub-defaults first, fleet.conf after → this computer wins
printf 'FLEET_SHELL_PREFIX=C-x\n' >> "$CONF/fleet.conf"
got=$( . "$hd"; . "$CONF/fleet.conf"; printf '%s|%s|%s' "$FLEET_UI_LANG" "$FLEET_SHELL_PREFIX" "$FLEET_SHELL_WIDTH" )
[ "$got" = "en|C-x|40" ] && ok "B a key fleet.conf sets wins over the hub's (C-x, not C-a); a gap is filled (en, 40)" \
  || bad "B precedence: $got"
got=$( FLEET_UI_LANG=zh; . "$hd"; printf '%s' "$FLEET_UI_LANG" )
[ "$got" = zh ] && ok "B an exported value wins over the hub's" || bad "B env precedence: $got"
# fleet-lib.sh reads it first too (a node's readers), and never as a fleet
got=$( FLEET_CONF_DIR="$CONF"; export FLEET_CONF_DIR; unset _FLEET_GLOBAL_CONF_SOURCED FLEET_SKIP_GLOBAL_CONF
       . "$BIN/fleet-lib.sh" >/dev/null 2>&1; printf '%s|%s|' "${FLEET_UI_LANG:-}" "${FLEET_SHELL_PREFIX:-}"; fleet_each_conf | cut -f1 | tr '\n' ' ' )
case "$got" in "en|C-x|"*hub-defaults*) bad "B fleet-lib lists hub-defaults.conf as a fleet: $got" ;;
  "en|C-x|"*) ok "B fleet-lib.sh: hub-defaults read first (en), fleet.conf wins (C-x), not a fleet" ;;
  *) bad "B fleet-lib.sh: $got" ;; esac
# the hub changes a default this computer set: still ours
sed -i.bak 's/"C-a"/"C-q"/' "$HUBD/v1/fleet/client-settings"; rm -f "$HUBD/v1/fleet/client-settings.bak"
stamp_old; start
got=$( . "$hd"; . "$CONF/fleet.conf"; printf '%s' "$FLEET_SHELL_PREFIX" )
grep -q "C-q" "$hd" && [ "$got" = C-x ] && ok "B the hub's default moves (C-q): this computer's C-x still reads C-x" \
  || bad "B hub default moved: file=$(grep PREFIX "$hd") got=$got"
sed -i.bak '/FLEET_SHELL_PREFIX=C-x/d' "$CONF/fleet.conf"; rm -f "$CONF/fleet.conf.bak"

# --- C. behind, compatible: background stage, switch on the next start -----
install_client v1; hub v2 1 1 beef002
start; rc=$?
if [ "$rc" = 0 ] && grep -q '后台取' "$WORK/err"; then ok "C behind: exit 0 at once, 「后台取，下次启动生效」"
else bad "C behind: rc=$rc err=$(cat "$WORK/err")"; fi
V="$ROOT.versions"
for _ in $(seq 1 50); do [ -f "$V/v2/.staged" ] && break; sleep 0.2; done
[ -f "$V/v2/.staged" ] && [ "$(cat "$V/.next" 2>/dev/null)" = v2 ] \
  && ok "C the background stage landed in <home>.versions/v2 (.next)" || bad "C no stage: $(cat "$STATE/stage.log" 2>&1) $(ls -a "$V" 2>&1)"
grep -q OLD "$ROOT/bin/fleet" && ok "C this start still runs the old client" || bad "C switched too early"
# nothing running: the plain-dir home is adopted at once (issue #1829), not on its first switch
[ -L "$ROOT" ] && [ "$(cd "$ROOT" && pwd -P)" = "$(cd "$V/v1" && pwd -P)" ] \
  && ok "C the plain-dir home adopted as <home>.versions/v1 + the link" || bad "C not adopted: $(ls -la "$XDG_DATA_HOME") $(ls -a "$V")"
start; rc=$?
if [ "$rc" = 3 ] && grep -q '已更新到 beef002' "$WORK/err" && grep -q NEW "$ROOT/bin/fleet" && [ -L "$ROOT" ] \
   && [ "$(cd "$ROOT" && pwd -P)" = "$(cd "$V/v2" && pwd -P)" ] && grep -q OLD "$V/v1/bin/fleet" && [ "$(cat "$V/.prev")" = v1 ] && [ ! -e "$V/.next" ]; then
  ok "C next start: switched (exit 3, 已更新到 beef002): <home> → versions/v2, the old home adopted as versions/v1 (.prev)"
else bad "C switch: rc=$rc err=$(cat "$WORK/err") root=$(cat "$ROOT/bin/fleet") link=$(readlink "$ROOT") vers=$(ls -a "$V")"; fi
grep -q '已更新到 beef002' "$STATE/note" 2>/dev/null && ok "C the note is written" || bad "C note: $(cat "$STATE/note" 2>&1)"

# --- D. below the min: update before opening --------------------------------
install_client v1 1; hub v3 3 2 beef003
start; rc=$?
if [ "$rc" = 3 ] && grep -q '已更新到 beef003' "$WORK/err" && grep -q NEW "$ROOT/bin/fleet"; then
  ok "D compat 1 < min 2: updated before opening (exit 3, 已更新到 beef003)"
else bad "D below min: rc=$rc err=$(cat "$WORK/err")"; fi

# --- E. below the min, the installer fails: open as is ----------------------
install_client v1 1; hub v3 3 2; : > "$HUBD/fail"
start; rc=$?
if [ "$rc" = 0 ] && grep -q '更新失败' "$WORK/err" && grep -q OLD "$ROOT/bin/fleet" && [ ! -e "$ROOT.next" ]; then
  ok "E the update fails: exit 0, one 更新失败 line, the home untouched"
else bad "E fail: rc=$rc err=$(cat "$WORK/err")"; fi
rm -f "$HUBD/fail"

# --- F. the hub out of reach; the throttle ----------------------------------
install_client v1; hub v3 3 2
printf 'FLEET_HUB_URL=file://%s/nowhere\n' "$WORK" > "$CONF/fleet.conf"
start; rc=$?
[ "$rc" = 0 ] && grep -q OLD "$ROOT/bin/fleet" && [ ! -e "$ROOT.next" ] \
  && ok "F hub out of reach: exit 0, nothing changed" || bad "F unreachable: rc=$rc err=$(cat "$WORK/err")"
printf 'FLEET_HUB_URL=%s\n' "$HUB" > "$CONF/fleet.conf"
start; rc=$?
[ "$rc" = 0 ] && grep -q OLD "$ROOT/bin/fleet" && ok "F inside the hour: asked nothing (min 2 not seen yet)" \
  || bad "F throttle: rc=$rc err=$(cat "$WORK/err")"
FLEET_CLIENT_CHECK_SECS=0 start; rc=$?
[ "$rc" = 3 ] && ok "F FLEET_CLIENT_CHECK_SECS=0: asks again and updates" || bad "F check-secs: rc=$rc"

# --- G. auto-update off -----------------------------------------------------
install_client v1; hub v3 3 2; rm -f "$CONF/hub-defaults.conf"
FLEET_CLIENT_AUTO_UPDATE=0 start; rc=$?
[ "$rc" = 0 ] && grep -q OLD "$ROOT/bin/fleet" && [ ! -e "$ROOT.next" ] && [ -f "$CONF/hub-defaults.conf" ] \
  && ok "G FLEET_CLIENT_AUTO_UPDATE=0: no update, the defaults still land" || bad "G off: rc=$rc err=$(cat "$WORK/err")"

# --- H. doctor --------------------------------------------------------------
install_client v1; hub v1 1 1
row=$(bash "$ROOT/bin/fleet-client-update.sh" doctor)
case "$row" in
  PASS*|WARN*|INFO*) case "$row" in *版本\ v1*入口*同版*证书*) ok "H doctor row: ${row#*	}" ;; *) bad "H doctor fields: $row" ;; esac ;;
  *) bad "H doctor level: $row" ;; esac
hub v2 1 1
row=$(bash "$ROOT/bin/fleet-client-update.sh" doctor)
case "$row" in *有新版\ v2*) ok "H doctor: a newer client on the hub is said" ;; *) bad "H doctor behind: $row" ;; esac
row=$(bash "$ROOT/bin/fleet-client-update.sh" doctor --root "$WORK/none")
case "$row" in INFO*没有*) ok "H doctor: no installed client → INFO" ;; *) bad "H doctor none: $row" ;; esac
cp "$BIN/fleet" "$ROOT/bin/fleet"
cp "$BIN/fleet-conf.sh" "$BIN/fleet-lib.sh" "$BIN/fleet-client-core.sh" "$ROOT/bin/"   # the 能力 row's reader (#1806)
out=$(sh "$ROOT/bin/fleet" doctor 2>&1)
case "$out" in *fleet*版本*) ok "H \`fleet doctor\` on a client-only home: the fleet row" ;; *) bad "H fleet doctor: $out" ;; esac
case "$out" in *能力*基础*) ok "H …and the 能力 row (#1806)" ;; *) bad "H no 能力 row: $out" ;; esac

# --- I. bin/fleet switches and runs the new client ---------------------------
install_client v1; cp "$BIN/fleet" "$ROOT/bin/fleet"; hub v2 1 1
mkdir -p "$ROOT.next/bin"; cp "$HUBD/new/"* "$ROOT.next/bin/"; chmod +x "$ROOT.next/bin/"*
printf 'version=v2\ncompat=1\ncommit=beef002\n' > "$ROOT.next/.client-version"; : > "$ROOT.next/.staged"
out=$(sh "$ROOT/bin/fleet" mac-a 2>&1)
case "$out" in *已更新到\ beef002*"NEW --thin --home mac-a"*) ok "I \`fleet mac-a\`: switched, then the NEW fleet opened the same client" ;;
  *) bad "I bin/fleet: $out" ;; esac

# --- J. a switch carries the person's files; tidy (issue #4827) --------------
install_client v1; hub v2 1 1
printf '#!/bin/sh\n# fleet-old.sh\n' > "$ROOT/bin/fleet-old.sh"
printf '#!/bin/sh\n# fleet-edited.sh\n' > "$ROOT/bin/fleet-edited.sh"
( . "$BIN/fleet-versions-lib.sh"; fleet_installed_write "$ROOT" bin/fleet bin/fleet-old.sh bin/fleet-edited.sh )
printf '#!/bin/sh\necho mine\n' > "$ROOT/bin/mine.sh"; echo '# by hand' >> "$ROOT/bin/fleet-edited.sh"
mkdir -p "$ROOT.next/bin"; cp "$HUBD/new/"* "$ROOT.next/bin/"; chmod +x "$ROOT.next/bin/"*
printf 'version=v2\ncompat=1\ncommit=beef002\n' > "$ROOT.next/.client-version"; : > "$ROOT.next/.staged"
start; rc=$?
if [ "$rc" = 3 ] && [ -L "$ROOT" ] && grep -q NEW "$ROOT/bin/fleet" && [ -f "$ROOT/bin/mine.sh" ] \
   && grep -q 'by hand' "$ROOT/bin/fleet-edited.sh" && [ ! -e "$ROOT/bin/fleet-old.sh" ]; then
  ok "J switch: the person's file and edit carried, the fleet's unchanged one left behind"
else
  bad "J carry: rc=$rc mine=$([ -f "$ROOT/bin/mine.sh" ] && echo y) old=$([ -e "$ROOT/bin/fleet-old.sh" ] && echo y) err=$(cat "$WORK/err")"
fi
mkdir -p "$ROOT.versions/stale/bin" "$ROOT.versions/.staging-install.99/bin"
touch -t 202001010000 "$ROOT.versions/.staging-install.99"
stamp_old; start
if [ ! -e "$ROOT.versions/stale" ] && [ ! -e "$ROOT.versions/.staging-install.99" ] && [ -e "$ROOT/bin/fleet" ]; then
  ok "J tidy: a version past the current + .prev and a crashed staging dir gone"
else
  bad "J tidy: $(ls -a "$ROOT.versions" | tr '\n' ' ')"
fi

# --- K. poll: the connected 看台's ask (issue #4916) --------------------------
poll() { bash "$ROOT/bin/fleet-client-update.sh" poll 2>"$WORK/err"; }
rm -f "$HUBD/fail"
install_client v1; hub v1 1 1
mkdir -p "$STATE"; date +%s > "$STATE/checked"   # inside the hourly window: poll asks anyway
poll; rc=$?
[ "$rc" = 0 ] && [ ! -e "$ROOT.versions/.next" ] && ok "K poll, same version: 0, nothing staged" \
  || bad "K poll same: rc=$rc next=$(cat "$ROOT.versions/.next" 2>&1)"
hub v2 1 1 beef002
poll; rc=$?
if [ "$rc" = 10 ] && [ "$(cat "$ROOT.versions/.next" 2>/dev/null)" = v2 ] && [ -f "$ROOT.versions/v2/.staged" ] && grep -q OLD "$ROOT/bin/fleet"; then
  ok "K poll, behind (hourly stamp fresh): staged v2 in the foreground, exit 10, still the old client"
else bad "K poll behind: rc=$rc next=$(cat "$ROOT.versions/.next" 2>&1) err=$(cat "$WORK/err")"; fi
start; rc=$?
[ "$rc" = 3 ] && grep -q NEW "$ROOT/bin/fleet" && ok "K the start after it switches (exit 3)" || bad "K start after poll: rc=$rc err=$(cat "$WORK/err")"
install_client v1; hub v2 1 1 beef002
FLEET_CLIENT_AUTO_UPDATE=0 poll; rc=$?
[ "$rc" = 0 ] && [ ! -e "$ROOT.versions/.next" ] && ok "K poll, auto update off: 0, nothing staged" \
  || bad "K poll off: rc=$rc next=$(cat "$ROOT.versions/.next" 2>&1)"

if [ "$fail" = 0 ]; then echo "PASS fleet-client-update-selftest"; else echo "FAIL fleet-client-update-selftest"; fi
exit "$fail"
