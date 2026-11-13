#!/bin/bash
# fleet-client-update-selftest.sh — the client keeps up with its hub by itself
# (issue #1722): bin/fleet-client-update.sh (start / stage / doctor) and the
# pieces that read what it writes (bin/fleet, fleet-lib.sh's hub-defaults.conf),
# against a fake hub reached over
# file:// — /version, /v1/fleet/client-settings and /install are files — so no
# port is bound, but in leg L (a signing hub on 127.0.0.1,
# bin/fleet-release-hub-fixture.py, an alarm(2) deadline, killed by the trap).
# HOME is a sandbox; tmux only on this run's own -L socket.
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
#   L. signed      with a pinned release key the new version is the hub's signed
#                  release, checked by the client's own fleet-release-fetch.py,
#                  installed by the installer inside that verified tree — the
#                  hub's /install is never fetched (a hostile one there runs
#                  nothing): valid → staged, .client-version names the release
#                  and the hub; a file or the installer altered inside the
#                  tree, a release signed
#                  by another key, a hub that stops serving releases → refused:
#                  nothing staged, the home untouched, one line saying why, the
#                  next start says it again (not 「后台取」), update.state failed
#   M. served      (fc_served, fleet-client-lib.sh) against the same signing hub
#                  and a fake curl: the staged version keeps its verified tree
#                  (.release-tree: the manifest + the bin/ files it does not
#                  install) and a served file comes from it, no download and no
#                  hub; pinned, no kept tree: a download matching the hub's
#                  signed manifest → in place (installed.list), other bytes (a
#                  matching header or not), a path the manifest lacks, a
#                  release signed by another key, a hub with no releases →
#                  refused, nothing left; no key: the header matching → in
#                  place, a missing or other header → refused
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-client-update-selftest.XXXXXX") || exit 2
RELHUB_PID=''
trap 'tmux -L "fcu$$" kill-server 2>/dev/null; [ -n "$RELHUB_PID" ] && kill "$RELHUB_PID" 2>/dev/null; rm -rf "${WORK:?}"' EXIT INT TERM HUP
FAIL=0

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
  st_ok_all "A no .client-version: exit 0, asked nothing, wrote nothing"
else st_miss "A degenerate: rc=$rc state=$(ls "$STATE" 2>&1) err=$(cat "$WORK/err")"; fi

# --- B. same version + the team's defaults ---------------------------------
install_client v1; hub v1 1 1
start; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$ROOT.next" ]; then st_ok_all "B same version: exit 0, nothing staged"
else st_miss "B same: rc=$rc next=$(ls "$ROOT.next" 2>&1)"; fi
hd="$CONF/hub-defaults.conf"
if [ -f "$hd" ] && grep -q "FLEET_UI_LANG='en'" "$hd" && grep -q "FLEET_SHELL_PREFIX='C-a'" "$hd" \
   && ! grep -q 'FLEET_HUB_URL\|FLEET_NODE_ALIASES\|FLEET_SHELL_WARM\|evil\|ghp_' "$hd"; then
  st_ok_all "B hub-defaults.conf: whitelisted keys written, address / unquotable / secret-shaped dropped"
else st_miss "B hub-defaults.conf: $(cat "$hd" 2>&1)"; fi
grep -q '不合规' "$WORK/err" && st_ok_all "B a dropped key is named on stderr" || st_miss "B no note for the dropped keys: $(cat "$WORK/err")"
# the readers' order: hub-defaults first, fleet.conf after → this computer wins
printf 'FLEET_SHELL_PREFIX=C-x\n' >> "$CONF/fleet.conf"
got=$( . "$hd"; . "$CONF/fleet.conf"; printf '%s|%s|%s' "$FLEET_UI_LANG" "$FLEET_SHELL_PREFIX" "$FLEET_SHELL_WIDTH" )
[ "$got" = "en|C-x|40" ] && st_ok_all "B a key fleet.conf sets wins over the hub's (C-x, not C-a); a gap is filled (en, 40)" \
  || st_miss "B precedence: $got"
got=$( FLEET_UI_LANG=zh; . "$hd"; printf '%s' "$FLEET_UI_LANG" )
[ "$got" = zh ] && st_ok_all "B an exported value wins over the hub's" || st_miss "B env precedence: $got"
# fleet-lib.sh reads it first too (a node's readers), and never as a fleet
got=$( FLEET_CONF_DIR="$CONF"; export FLEET_CONF_DIR; unset _FLEET_GLOBAL_CONF_SOURCED FLEET_SKIP_GLOBAL_CONF
       . "$BIN/fleet-lib.sh" >/dev/null 2>&1; printf '%s|%s|' "${FLEET_UI_LANG:-}" "${FLEET_SHELL_PREFIX:-}"; fleet_each_conf | cut -f1 | tr '\n' ' ' )
case "$got" in "en|C-x|"*hub-defaults*) st_miss "B fleet-lib lists hub-defaults.conf as a fleet: $got" ;;
  "en|C-x|"*) st_ok_all "B fleet-lib.sh: hub-defaults read first (en), fleet.conf wins (C-x), not a fleet" ;;
  *) st_miss "B fleet-lib.sh: $got" ;; esac
# the hub changes a default this computer set: still ours
sed -i.bak 's/"C-a"/"C-q"/' "$HUBD/v1/fleet/client-settings"; rm -f "$HUBD/v1/fleet/client-settings.bak"
stamp_old; start
got=$( . "$hd"; . "$CONF/fleet.conf"; printf '%s' "$FLEET_SHELL_PREFIX" )
grep -q "C-q" "$hd" && [ "$got" = C-x ] && st_ok_all "B the hub's default moves (C-q): this computer's C-x still reads C-x" \
  || st_miss "B hub default moved: file=$(grep PREFIX "$hd") got=$got"
sed -i.bak '/FLEET_SHELL_PREFIX=C-x/d' "$CONF/fleet.conf"; rm -f "$CONF/fleet.conf.bak"

# --- C. behind, compatible: background stage, switch on the next start -----
install_client v1; hub v2 1 1 beef002
start; rc=$?
if [ "$rc" = 0 ] && grep -q '后台取' "$WORK/err"; then st_ok_all "C behind: exit 0 at once, 「后台取，下次启动生效」"
else st_miss "C behind: rc=$rc err=$(cat "$WORK/err")"; fi
V="$ROOT.versions"
for _ in $(seq 1 50); do [ -f "$V/v2/.staged" ] && break; sleep 0.2; done
[ -f "$V/v2/.staged" ] && [ "$(cat "$V/.next" 2>/dev/null)" = v2 ] \
  && st_ok_all "C the background stage landed in <home>.versions/v2 (.next)" || st_miss "C no stage: $(cat "$STATE/stage.log" 2>&1) $(ls -a "$V" 2>&1)"
grep -q OLD "$ROOT/bin/fleet" && st_ok_all "C this start still runs the old client" || st_miss "C switched too early"
# nothing running: the plain-dir home is adopted at once (issue #1829), not on its first switch
[ -L "$ROOT" ] && [ "$(cd "$ROOT" && pwd -P)" = "$(cd "$V/v1" && pwd -P)" ] \
  && st_ok_all "C the plain-dir home adopted as <home>.versions/v1 + the link" || st_miss "C not adopted: $(ls -la "$XDG_DATA_HOME") $(ls -a "$V")"
start; rc=$?
if [ "$rc" = 3 ] && grep -q '已更新到 beef002' "$WORK/err" && grep -q NEW "$ROOT/bin/fleet" && [ -L "$ROOT" ] \
   && [ "$(cd "$ROOT" && pwd -P)" = "$(cd "$V/v2" && pwd -P)" ] && grep -q OLD "$V/v1/bin/fleet" && [ "$(cat "$V/.prev")" = v1 ] && [ ! -e "$V/.next" ]; then
  st_ok_all "C next start: switched (exit 3, 已更新到 beef002): <home> → versions/v2, the old home adopted as versions/v1 (.prev)"
else st_miss "C switch: rc=$rc err=$(cat "$WORK/err") root=$(cat "$ROOT/bin/fleet") link=$(readlink "$ROOT") vers=$(ls -a "$V")"; fi
grep -q '已更新到 beef002' "$STATE/note" 2>/dev/null && st_ok_all "C the note is written" || st_miss "C note: $(cat "$STATE/note" 2>&1)"

# --- D. below the min: update before opening --------------------------------
install_client v1 1; hub v3 3 2 beef003
start; rc=$?
if [ "$rc" = 3 ] && grep -q '已更新到 beef003' "$WORK/err" && grep -q NEW "$ROOT/bin/fleet"; then
  st_ok_all "D compat 1 < min 2: updated before opening (exit 3, 已更新到 beef003)"
else st_miss "D below min: rc=$rc err=$(cat "$WORK/err")"; fi

# --- E. below the min, the installer fails: open as is ----------------------
install_client v1 1; hub v3 3 2; : > "$HUBD/fail"
start; rc=$?
if [ "$rc" = 0 ] && grep -q '更新失败' "$WORK/err" && grep -q OLD "$ROOT/bin/fleet" && [ ! -e "$ROOT.next" ]; then
  st_ok_all "E the update fails: exit 0, one 更新失败 line, the home untouched"
else st_miss "E fail: rc=$rc err=$(cat "$WORK/err")"; fi
rm -f "$HUBD/fail"

# --- F. the hub out of reach; the throttle ----------------------------------
install_client v1; hub v3 3 2
printf 'FLEET_HUB_URL=file://%s/nowhere\n' "$WORK" > "$CONF/fleet.conf"
start; rc=$?
[ "$rc" = 0 ] && grep -q OLD "$ROOT/bin/fleet" && [ ! -e "$ROOT.next" ] \
  && st_ok_all "F hub out of reach: exit 0, nothing changed" || st_miss "F unreachable: rc=$rc err=$(cat "$WORK/err")"
printf 'FLEET_HUB_URL=%s\n' "$HUB" > "$CONF/fleet.conf"
start; rc=$?
[ "$rc" = 0 ] && grep -q OLD "$ROOT/bin/fleet" && st_ok_all "F inside the hour: asked nothing (min 2 not seen yet)" \
  || st_miss "F throttle: rc=$rc err=$(cat "$WORK/err")"
FLEET_CLIENT_CHECK_SECS=0 start; rc=$?
[ "$rc" = 3 ] && st_ok_all "F FLEET_CLIENT_CHECK_SECS=0: asks again and updates" || st_miss "F check-secs: rc=$rc"

# --- G. auto-update off -----------------------------------------------------
install_client v1; hub v3 3 2; rm -f "$CONF/hub-defaults.conf"
FLEET_CLIENT_AUTO_UPDATE=0 start; rc=$?
[ "$rc" = 0 ] && grep -q OLD "$ROOT/bin/fleet" && [ ! -e "$ROOT.next" ] && [ -f "$CONF/hub-defaults.conf" ] \
  && st_ok_all "G FLEET_CLIENT_AUTO_UPDATE=0: no update, the defaults still land" || st_miss "G off: rc=$rc err=$(cat "$WORK/err")"

# --- H. doctor --------------------------------------------------------------
install_client v1; hub v1 1 1
row=$(bash "$ROOT/bin/fleet-client-update.sh" doctor)
case "$row" in
  PASS*|WARN*|INFO*) case "$row" in *版本\ v1*入口*同版*证书*) st_ok_all "H doctor row: ${row#*	}" ;; *) st_miss "H doctor fields: $row" ;; esac ;;
  *) st_miss "H doctor level: $row" ;; esac
hub v2 1 1
row=$(bash "$ROOT/bin/fleet-client-update.sh" doctor)
case "$row" in *有新版\ v2*) st_ok_all "H doctor: a newer client on the hub is said" ;; *) st_miss "H doctor behind: $row" ;; esac
row=$(bash "$ROOT/bin/fleet-client-update.sh" doctor --root "$WORK/none")
case "$row" in INFO*没有*) st_ok_all "H doctor: no installed client → INFO" ;; *) st_miss "H doctor none: $row" ;; esac
cp "$BIN/fleet" "$ROOT/bin/fleet"
cp "$BIN/fleet-conf.sh" "$BIN/fleet-lib.sh" "$BIN/fleet-client-core.sh" "$ROOT/bin/"   # the 能力 row's reader (#1806)
out=$(sh "$ROOT/bin/fleet" doctor 2>&1)
case "$out" in *fleet*版本*) st_ok_all "H \`fleet doctor\` on a client-only home: the fleet row" ;; *) st_miss "H fleet doctor: $out" ;; esac
case "$out" in *能力*基础*) st_ok_all "H …and the 能力 row (#1806)" ;; *) st_miss "H no 能力 row: $out" ;; esac

# --- I. bin/fleet switches and runs the new client ---------------------------
install_client v1; cp "$BIN/fleet" "$ROOT/bin/fleet"; hub v2 1 1
mkdir -p "$ROOT.next/bin"; cp "$HUBD/new/"* "$ROOT.next/bin/"; chmod +x "$ROOT.next/bin/"*
printf 'version=v2\ncompat=1\ncommit=beef002\n' > "$ROOT.next/.client-version"; : > "$ROOT.next/.staged"
out=$(sh "$ROOT/bin/fleet" mac-a 2>&1)
case "$out" in *已更新到\ beef002*"NEW --thin --home mac-a"*) st_ok_all "I \`fleet mac-a\`: switched, then the NEW fleet opened the same client" ;;
  *) st_miss "I bin/fleet: $out" ;; esac

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
  st_ok_all "J switch: the person's file and edit carried, the fleet's unchanged one left behind"
else
  st_miss "J carry: rc=$rc mine=$([ -f "$ROOT/bin/mine.sh" ] && echo y) old=$([ -e "$ROOT/bin/fleet-old.sh" ] && echo y) err=$(cat "$WORK/err")"
fi
mkdir -p "$ROOT.versions/stale/bin" "$ROOT.versions/.staging-install.99/bin"
touch -t 202001010000 "$ROOT.versions/.staging-install.99"
stamp_old; start
if [ ! -e "$ROOT.versions/stale" ] && [ ! -e "$ROOT.versions/.staging-install.99" ] && [ -e "$ROOT/bin/fleet" ]; then
  st_ok_all "J tidy: a version past the current + .prev and a crashed staging dir gone"
else
  st_miss "J tidy: $(ls -a "$ROOT.versions" | tr '\n' ' ')"
fi

# --- K. poll: the connected 看台's ask (issue #4916) --------------------------
poll() { bash "$ROOT/bin/fleet-client-update.sh" poll 2>"$WORK/err"; }
rm -f "$HUBD/fail"
install_client v1; hub v1 1 1
mkdir -p "$STATE"; date +%s > "$STATE/checked"   # inside the hourly window: poll asks anyway
poll; rc=$?
[ "$rc" = 0 ] && [ ! -e "$ROOT.versions/.next" ] && st_ok_all "K poll, same version: 0, nothing staged" \
  || st_miss "K poll same: rc=$rc next=$(cat "$ROOT.versions/.next" 2>&1)"
hub v2 1 1 beef002
poll; rc=$?
if [ "$rc" = 10 ] && [ "$(cat "$ROOT.versions/.next" 2>/dev/null)" = v2 ] && [ -f "$ROOT.versions/v2/.staged" ] && grep -q OLD "$ROOT/bin/fleet"; then
  st_ok_all "K poll, behind (hourly stamp fresh): staged v2 in the foreground, exit 10, still the old client"
else st_miss "K poll behind: rc=$rc next=$(cat "$ROOT.versions/.next" 2>&1) err=$(cat "$WORK/err")"; fi
start; rc=$?
[ "$rc" = 3 ] && grep -q NEW "$ROOT/bin/fleet" && st_ok_all "K the start after it switches (exit 3)" || st_miss "K start after poll: rc=$rc err=$(cat "$WORK/err")"
install_client v1; hub v2 1 1 beef002
FLEET_CLIENT_AUTO_UPDATE=0 poll; rc=$?
[ "$rc" = 0 ] && [ ! -e "$ROOT.versions/.next" ] && st_ok_all "K poll, auto update off: 0, nothing staged" \
  || st_miss "K poll off: rc=$rc next=$(cat "$ROOT.versions/.next" 2>&1)"

# --- L. signed: the pinned key decides what is installed ----------------------
if ! command -v ssh-keygen >/dev/null 2>&1; then
  st_ok_all "L SKIP: no ssh-keygen (the signing hub signs with it)"
else
  RH="$WORK/relhub"; S1=5151515151515151515151515151515151515151
  mkdir -p "$RH/rel/$S1/bin" "$RH/rel/$S1/tokenledger/hub/api/fleetclient"
  # the release: a real client package in miniature — the real installer and
  # updater, a stand-in fleet, the manifest the installer walks
  cp "$BIN/fleet-install.sh" "$BIN/fleet-client-update.sh" "$BIN/fleet-versions-lib.sh" \
     "$BIN/fleet-release-fetch.py" "$BIN/fleet-release-verify.py" "$BIN/fleet-ui-lang.sh" "$RH/rel/$S1/bin/"
  printf '#!/bin/sh\necho SIGNED "$@"\n' > "$RH/rel/$S1/bin/fleet"
  chmod +x "$RH/rel/$S1/bin/"*
  printf 'bin/fleet-install.sh  installer\nbin/fleet\nbin/fleet-client-update.sh\nbin/fleet-versions-lib.sh\nbin/fleet-release-fetch.py\nbin/fleet-release-verify.py\nbin/fleet-ui-lang.sh\n' \
    > "$RH/rel/$S1/tokenledger/hub/api/fleetclient/manifest"
  mkdir -p "$RH/rel/$S1/.release"
  printf '{"schema": 1, "sha": "%s", "prev": "", "seq": 7, "artifacts": []}\n' "$S1" > "$RH/rel/$S1/.release/manifest.json"
  # served only (fc_served, leg M): in the release, never installed
  printf '#!/bin/sh\necho SERVED-A\n' > "$RH/rel/$S1/bin/fleet-served-a.sh"
  chmod +x "$RH/rel/$S1/bin/fleet-served-a.sh"
  printf '%s\n' "$S1" > "$RH/rel/stable"
  # a hostile /install: anything that runs it leaves a mark
  printf '#!/bin/sh\ntouch "%s/hostile-ran"\nexit 1\n' "$WORK" > "$RH/install"
  python3 "$BIN/fleet-release-hub-fixture.py" "$RH" 2>"$WORK/relhub.err" &
  RELHUB_PID=$!
  for _ in $(seq 1 300); do [ -s "$RH/port" ] && break; sleep 0.1; done
  if [ ! -s "$RH/port" ]; then
    st_miss "L the signing hub never started: $(tail -2 "$WORK/relhub.err")"
  else
    RHUB="http://127.0.0.1:$(cat "$RH/port")"
    printf '{"commit":"img","client_version":"%s","stable":"%s","client_compat":1,"min_client_compat":0}\n' "$S1" "$S1" > "$RH/version"
    printf 'FLEET_HUB_URL=%s\n' "$RHUB" > "$CONF/fleet.conf"
    rm -f "$CONF/release.pub" "$CONF/release.pub.revoked" "$CONF/hub-defaults.conf"
    sstage() { FLEET_UI_LANG=${LANG_T:-zh} bash "$ROOT/bin/fleet-client-update.sh" stage "$S1" 2>"$WORK/err"; }
    linstall() {   # a client at v1 that carries the checker, beside its updater
      install_client v1; cp "$BIN/fleet-release-fetch.py" "$BIN/fleet-release-verify.py" "$BIN/fleet-ui-lang.sh" "$ROOT/bin/"
      sed -i.bak "s#^hub=.*#hub=$RHUB#" "$ROOT/.client-version"; rm -f "$ROOT/.client-version.bak"
    }
    untouched() { grep -q OLD "$ROOT/bin/fleet" && [ ! -e "$ROOT.versions/.next" ] && [ ! -e "$ROOT.versions/$S1" ]; }
    # a file altered inside tree.tar.gz (its `tree` digest still matches): refused
    linstall; cp "$RH/key" "$CONF/release.pub"; : > "$RH/tamper"; : > "$RH/hub.log"
    LANG_T=en sstage; rc=$?
    if [ "$rc" != 0 ] && untouched && grep -q 'failed the release signature check' "$WORK/err" \
       && [ "$(grep -c . "$WORK/err")" = 1 ] && grep -q 'digest does not match' "$WORK/err"; then
      st_ok_all "L a file altered inside the signed tree: refused, nothing staged, one line: $(cat "$WORK/err")"
    else st_miss "L tampered file: rc=$rc err=$(cat "$WORK/err") vers=$(ls -a "$ROOT.versions" 2>&1)"; fi
    st=$(cat "$XDG_CACHE_HOME/claude-fleet/shell/update.state" 2>/dev/null)
    case "$st" in *'"phase": "failed"'*"$S1"*) st_ok_all "L update.state: failed, naming $(printf '%.7s' "$S1")" ;; *) st_miss "L update.state: $st" ;; esac
    # the next start says why again, not 「后台取」 — and tries again in the
    # background (refused again: the tree is still altered)
    rm -f "$STATE/stage.log"; stamp_old; FLEET_UI_LANG=zh start; rc=$?
    if [ "$rc" = 0 ] && grep -q '没通过发布签名校验' "$WORK/err" && ! grep -q '后台取' "$WORK/err"; then
      st_ok_all "L the next start: the refusal again, not 「后台取」: $(head -1 "$WORK/err")"
    else st_miss "L start after refusal: rc=$rc err=$(cat "$WORK/err")"; fi
    for _ in $(seq 1 100); do grep -q . "$STATE/stage.log" 2>/dev/null && [ ! -d "$ROOT.versions/.lock" ] && break; sleep 0.2; done
    untouched && st_ok_all "L the background retry refused too, nothing staged" || st_miss "L bg retry: $(cat "$STATE/stage.log" 2>&1)"
    rm -f "$RH/tamper"
    # the installer altered inside the signed tree: refused before it runs
    linstall; cp "$RH/key" "$CONF/release.pub"; printf 'bin/fleet-install.sh\n' > "$RH/tamper"
    sstage; rc=$?; rm -f "$RH/tamper"
    [ "$rc" != 0 ] && untouched && grep -q 'bin/fleet-install.sh: digest does not match' "$WORK/err" \
      && st_ok_all "L the installer altered inside the signed tree: refused, nothing run or staged" \
      || st_miss "L tampered installer: rc=$rc err=$(cat "$WORK/err")"
    # a release signed by a key the pinned one does not vouch for (the whole
    # tree, installer included, replaced): refused
    linstall; cp "$RH/key" "$CONF/release.pub"; : > "$RH/badsig"
    sstage; rc=$?; rm -f "$RH/badsig"
    [ "$rc" != 0 ] && untouched && grep -q '没通过发布签名校验' "$WORK/err" \
      && st_ok_all "L a release signed by another key: refused, nothing staged" \
      || st_miss "L badsig: rc=$rc err=$(cat "$WORK/err")"
    # pinned, and the hub stops serving releases: refused — never its /install
    linstall; cp "$RH/key" "$CONF/release.pub"; : > "$RH/nostore"
    sstage; rc=$?; rm -f "$RH/nostore"
    [ "$rc" != 0 ] && untouched && grep -q '取不到新版' "$WORK/err" && [ ! -e "$WORK/hostile-ran" ] \
      && st_ok_all "L pinned key, hub with no releases: refused, the hub's /install not run" \
      || st_miss "L nostore: rc=$rc err=$(cat "$WORK/err") hostile=$([ -e "$WORK/hostile-ran" ] && echo ran)"
    # valid: staged from the verified tree; the hostile /install never fetched
    linstall; cp "$RH/key" "$CONF/release.pub"; : > "$RH/hub.log"
    sstage; rc=$?
    cv="$ROOT.versions/$S1/.client-version"
    if [ "$rc" = 0 ] && [ "$(cat "$ROOT.versions/.next" 2>/dev/null)" = "$S1" ] && grep -q SIGNED "$ROOT.versions/$S1/bin/fleet" \
       && grep -qx "version=$S1" "$cv" && grep -qx "hub=$RHUB" "$cv" && grep -qx 'compat=1' "$cv" && grep -q OLD "$ROOT/bin/fleet"; then
      st_ok_all "L a valid signed release: staged at versions/$(printf '%.7s' "$S1") (.client-version: the release, compat 1, the hub)"
    else st_miss "L valid: rc=$rc err=$(cat "$WORK/err") cv=$(cat "$cv" 2>&1) log=$(tail -3 "$STATE/update.log" 2>&1)"; fi
    ! grep -qx /install "$RH/hub.log" && [ ! -e "$WORK/hostile-ran" ] && grep -q "^/v1/fleet/release/$S1/tree.tar.gz" "$RH/hub.log" \
      && st_ok_all "L the hub's /install never fetched; the signed tree was" || st_miss "L hub asked: $(tr '\n' ' ' < "$RH/hub.log")"
    start; rc=$?
    [ "$rc" = 3 ] && grep -q SIGNED "$ROOT/bin/fleet" && st_ok_all "L the next start switches to it (exit 3)" \
      || st_miss "L switch: rc=$rc err=$(cat "$WORK/err")"
    # no key yet, the hub keeps releases: pinned once (as a login install does), then checked
    linstall; rm -f "$CONF/release.pub"
    sstage; rc=$?
    [ "$rc" = 0 ] && cmp -s "$RH/key" "$CONF/release.pub" && grep -q SIGNED "$ROOT.versions/$S1/bin/fleet" \
      && st_ok_all "L no key yet: the hub's taken once, the release checked against it" \
      || st_miss "L first pin: rc=$rc err=$(cat "$WORK/err") pub=$(cat "$CONF/release.pub" 2>&1)"

    # --- M. served: the kept verified tree, else the signed manifest ----------
    FCSRV="$WORK/fcsrv"; FCB="$WORK/fcbin"; mkdir -p "$FCSRV" "$FCB"
    cat > "$FCB/curl" <<'SH'
#!/bin/sh
# a fake curl: <url>'s path under $FCSRV, the header as a hub sends it
hdr='' out='' url=''
while [ $# -gt 0 ]; do
  case $1 in -D) hdr=$2; shift 2 ;; -o) out=$2; shift 2 ;; --connect-timeout|--max-time) shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac
done
printf '%s\n' "$url" >> "$FCSRV.log"
p=${url#*://}; f="$FCSRV/${p#*/}"
[ -f "$f" ] || exit 22
cp "$f" "$out"
s=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$f")
[ -e "$FCSRV/.badhdr" ] && s=0000000000000000000000000000000000000000000000000000000000000000
if [ -e "$FCSRV/.nohdr" ]; then printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
else printf 'HTTP/1.1 200 OK\r\nX-Ccquota-Sha256: %s\r\n\r\n' "$s" > "$hdr"; fi
SH
    chmod +x "$FCB/curl"
    fcs() {   # <root> <path> — fc_served through the fake curl; "rc=<n> <FC_WHY>"
      : > "$FCSRV.log"; : > "$RH/hub.log"
      PATH="$FCB:$PATH" FCSRV="$FCSRV" sh -c '. "$1/fleet-client-lib.sh"; fc_served "$2" "$3"; echo "rc=$? $FC_WHY"' _ "$BIN" "$1" "$2" 2>&1
    }
    SA="$RH/rel/$S1/bin/fleet-served-a.sh"
    # the staged version kept its verified tree: taken from it, no download, no hub
    KV="$ROOT.versions/$S1"
    if [ -f "$KV/.release-tree/.release/manifest.json" ] && cmp -s "$KV/.release-tree/bin/fleet-served-a.sh" "$SA" \
       && [ ! -e "$KV/.release-tree/bin/fleet" ] && [ ! -e "$KV/.release-tree/tokenledger" ] && [ ! -e "$KV/bin/fleet-served-a.sh" ]; then
      st_ok_all "M the staged version keeps the verified tree's manifest + the bin/ files it does not install"
    else st_miss "M kept tree: $(cd "$KV" 2>/dev/null && find .release-tree -maxdepth 2 2>&1 | tr '\n' ' ')"; fi
    : > "$KV/installed.list"
    out=$(fcs "$KV" bin/fleet-served-a.sh)
    if [ "$out" = "rc=0 " ] && cmp -s "$KV/bin/fleet-served-a.sh" "$SA" && [ -x "$KV/bin/fleet-served-a.sh" ] \
       && [ ! -s "$FCSRV.log" ] && [ ! -s "$RH/hub.log" ] && grep -q '^bin/fleet-served-a.sh	' "$KV/installed.list"; then
      st_ok_all "M kept tree: the served file taken from it — no download, nothing asked of the hub, on installed.list"
    else st_miss "M kept tree: $out curl=$(tr '\n' ' ' < "$FCSRV.log") hub=$(tr '\n' ' ' < "$RH/hub.log")"; fi
    # no kept tree: a client the install line put in (version + hub, the checker)
    FR="$WORK/fcroot"
    fcroot() {
      rm -rf "$FR"; mkdir -p "$FR/bin"; cp "$BIN/fleet-release-fetch.py" "$BIN/fleet-release-verify.py" "$FR/bin/"
      printf 'version=%s\ncompat=1\ncommit=%.7s\nhub=%s\n' "$S1" "$S1" "$RHUB" > "$FR/.client-version"; : > "$FR/installed.list"
      rm -rf "${FCSRV:?}"/* "$FCSRV"/.nohdr "$FCSRV"/.badhdr; mkdir -p "$FCSRV/install/stable/$S1/bin"
    }
    nothing_left() { [ ! -e "$FR/bin/$1" ] && [ -z "$(find "$FR/bin" -name '*.fetch.*')" ]; }
    cp "$RH/key" "$CONF/release.pub"
    fcroot; cp "$SA" "$FCSRV/install/stable/$S1/bin/"
    out=$(fcs "$FR" bin/fleet-served-a.sh)
    if [ "$out" = "rc=0 " ] && cmp -s "$FR/bin/fleet-served-a.sh" "$SA" && grep -q "^/v1/fleet/release/$S1" "$RH/hub.log" \
       && grep -q '^bin/fleet-served-a.sh	' "$FR/installed.list"; then
      st_ok_all "M pinned: a download matching the hub's signed manifest → in place, on installed.list"
    else st_miss "M pinned ok: $out hub=$(tr '\n' ' ' < "$RH/hub.log")"; fi
    fcroot; printf '#!/bin/sh\necho OTHER\n' > "$FCSRV/install/stable/$S1/bin/fleet-served-a.sh"
    out=$(fcs "$FR" bin/fleet-served-a.sh)
    case $out in "rc=1 取不到 bin/fleet-served-a.sh"*"已签名发布清单"*) nothing_left fleet-served-a.sh \
      && st_ok_all "M pinned: other bytes (their own header matching) → refused, nothing left: ${out#rc=1 }" || st_miss "M pinned mismatch left files" ;;
      *) st_miss "M pinned mismatch: $out" ;; esac
    fcroot; printf '#!/bin/sh\necho NEW\n' > "$FCSRV/install/stable/$S1/bin/fleet-unreleased.sh"
    out=$(fcs "$FR" bin/fleet-unreleased.sh)
    case $out in "rc=1 已签名的发布"*"里没有 bin/fleet-unreleased.sh"*) nothing_left fleet-unreleased.sh && [ ! -s "$FCSRV.log" ] \
      && st_ok_all "M pinned: a path the signed manifest lacks → refused before any download" || st_miss "M not in manifest: downloaded or left files" ;;
      *) st_miss "M not in manifest: $out" ;; esac
    fcroot; cp "$SA" "$FCSRV/install/stable/$S1/bin/"; : > "$RH/badsig"
    out=$(fcs "$FR" bin/fleet-served-a.sh); rm -f "$RH/badsig"
    case $out in "rc=1 核对不了 bin/fleet-served-a.sh"*) nothing_left fleet-served-a.sh && [ ! -s "$FCSRV.log" ] \
      && st_ok_all "M pinned: a manifest signed by another key → refused, nothing downloaded" || st_miss "M badsig: downloaded or left files" ;;
      *) st_miss "M badsig: $out" ;; esac
    fcroot; cp "$SA" "$FCSRV/install/stable/$S1/bin/"; : > "$RH/nostore"
    out=$(fcs "$FR" bin/fleet-served-a.sh); rm -f "$RH/nostore"
    case $out in "rc=1 核对不了 bin/fleet-served-a.sh"*) nothing_left fleet-served-a.sh \
      && st_ok_all "M pinned: no signed manifest to be had → refused: ${out#rc=1 }" || st_miss "M nostore left files" ;;
      *) st_miss "M nostore: $out" ;; esac
    # no key pinned: the hub's header, required
    rm -f "$CONF/release.pub"
    fcroot; cp "$SA" "$FCSRV/install/stable/$S1/bin/"
    out=$(fcs "$FR" bin/fleet-served-a.sh)
    [ "$out" = "rc=0 " ] && cmp -s "$FR/bin/fleet-served-a.sh" "$SA" && [ ! -s "$RH/hub.log" ] \
      && st_ok_all "M no key: the header matching → in place (no release asked for)" || st_miss "M unpinned ok: $out"
    fcroot; cp "$SA" "$FCSRV/install/stable/$S1/bin/"; : > "$FCSRV/.nohdr"
    out=$(fcs "$FR" bin/fleet-served-a.sh)
    case $out in "rc=1 取不到 bin/fleet-served-a.sh"*"X-Ccquota-Sha256"*) nothing_left fleet-served-a.sh \
      && st_ok_all "M no key: no X-Ccquota-Sha256 → refused, nothing left" || st_miss "M nohdr left files" ;;
      *) st_miss "M nohdr: $out" ;; esac
    fcroot; cp "$SA" "$FCSRV/install/stable/$S1/bin/"; : > "$FCSRV/.badhdr"
    out=$(fcs "$FR" bin/fleet-served-a.sh)
    case $out in "rc=1 取不到 bin/fleet-served-a.sh"*"对不上"*) nothing_left fleet-served-a.sh \
      && st_ok_all "M no key: a header naming other bytes → refused, nothing left" || st_miss "M badhdr left files" ;;
      *) st_miss "M badhdr: $out" ;; esac
  fi
  kill "$RELHUB_PID" 2>/dev/null; RELHUB_PID=''
fi

if [ "$FAIL" = 0 ]; then echo "PASS fleet-client-update-selftest"; else echo "FAIL fleet-client-update-selftest"; fi
st_done
