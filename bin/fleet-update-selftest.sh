#!/bin/bash
# fleet-update-selftest.sh — ONE update path: every computer follows stable
# (issue #1805, EPIC #1813 C3). Drives the real bin/fleet-install.sh,
# bin/fleet-client-update.sh, bin/fleet-update.sh and bin/fleet-install-sync.sh
# against a fake GitHub reached over file:// — FLEET_STABLE_API is a file holding
# the commit stable names, FLEET_STABLE_RAW a tree of <sha>/<repo path> — and a
# fake hub that is NEVER redeployed: its /install (the installer its image was
# built with) stays the same bytes for the whole test; only its /version moves,
# the way the hub's stable lookup moves it. The installer takes only an http(s)
# hub address, so the hub is a static file server on 127.0.0.1 (an ephemeral
# port, a kernel alarm(2) deadline, killed by the trap). HOME is a sandbox. The
# 承载 half moves a local bare repo's refs/tags/stable.
#
# Legs:
#   A. 不接 install  the installer asks GitHub which commit stable is and
#                    installs the files AT it; .client-version records it with
#                    no hub; `fleet update` says 基础 · 跟 stable 同版
#   B. 不接 follows  stable moves → the next start stages it in the background
#                    from GitHub (stable's own installer), the start after
#                    switches (exit 3): the version and the files are the new
#                    stable's; GitHub out of reach → open as is, nothing changes
#   C. 接, hub not redeployed   installed through the hub (client_url); stable
#                    moves, the hub's /install is byte for byte what it was, and
#                    the client still lands on the new stable; the version string
#                    is the same one a 不接 computer on that stable has
#   D. proxy down    the hub's client_url fails → each file from GitHub's raw
#                    host at the same commit; the install is that version
#   E. 承载 follows  a checkout + `fleet update tick --root`: stable moved → the
#                    next tick moves it (install-sync's `updated`); an EPIC
#                    heartbeat → `deferred`, HEAD untouched; `fleet update` on
#                    each layer names the same short commit (the doctor's
#                    first-row word)
#   F. degenerate    a home with no .client-version → start / tick touch nothing
#                    and ask nothing; FLEET_INSTALL_SRC pinned → no .client-version
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$BIN/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-update-selftest.XXXXXX") || exit 2
WORK=$(cd "$WORK" && pwd -P)
SRV_PID=''
trap '[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "${WORK:?}"' EXIT INT TERM HUP
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

SYSPATH=/usr/bin:/bin:/usr/sbin:/sbin
command -v git >/dev/null 2>&1 || { echo 'fleet-update-selftest SKIP (no git)'; exit 0; }
GH="$WORK/gh"; mkdir -p "$GH/raw"
M=tokenledger/internal/api/fleetclient/manifest
S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222
S3=3333333333333333333333333333333333333333
S4=4444444444444444444444444444444444444444

# publish <sha> — the repo's client files as GitHub would serve them at <sha>,
# each release marked in bin/fleet-update.sh so the files say which they are
publish() {
  local d="$GH/raw/$1" f
  mkdir -p "$d/$(dirname "$M")"; cp "$REPO/$M" "$d/$M"
  awk '!/^[[:space:]]*#/ && NF {print $1}' "$REPO/$M" | while IFS= read -r f; do
    mkdir -p "$d/$(dirname "$f")"; cp "$REPO/$f" "$d/$f"
  done
  printf '# release %s\n' "$1" >> "$d/bin/fleet-update.sh"
}
stable() { printf '%s\n' "$1" > "$GH/api"; }
release_of() { tail -n 1 "$1/bin/fleet-update.sh" 2>/dev/null | sed -n 's/^# release //p'; }
publish "$S1"; publish "$S2"; publish "$S3"; publish "$S4"
stable "$S1"

# sandbox <name> — a fresh HOME; exports what every command below reads
sandbox() {
  H="$WORK/$1"; rm -rf "$H"; mkdir -p "$H"
  ROOT="$H/.claude/fleet"; STATE="$H/.cache/claude-fleet/client"
}
envrun() {
  env -i HOME="$H" PATH="$SYSPATH" TMPDIR="$WORK" SHELL=/bin/sh \
    XDG_CONFIG_HOME="$H/.config" XDG_CACHE_HOME="$H/.cache" XDG_DATA_HOME="$H/.local/share" \
    FLEET_STABLE_API="file://$GH/api" FLEET_STABLE_RAW="file://$GH/raw" \
    FLEET_SHELL_SESSION="fus$$" FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1 FLEET_INSTALL_ASK=0 \
    FLEET_INSTALL_NO_NODE=1 FLEET_INSTALL_NO_AGENTS=1 FLEET_INSTALL_RC=/dev/null "$@"
}
cv() { sed -n "s/^$1=//p" "$ROOT/.client-version" 2>/dev/null; }
start() { mkdir -p "$STATE"; echo 0 > "$STATE/checked"; OUT=$(envrun bash "$ROOT/bin/fleet-client-update.sh" start 2>&1); RC=$?; }
wait_staged() { local _; for _ in $(seq 1 100); do [ -f "$ROOT.versions/$1/.staged" ] && return 0; sleep 0.1; done; return 1; }

# --- A. 不接 install ------------------------------------------------------------
sandbox a
out=$(envrun sh "$BIN/fleet-install.sh" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(cv version)" = "$S1" ] && [ "$(cv commit)" = "${S1:0:7}" ] && [ -z "$(cv hub)" ] \
   && [ "$(release_of "$ROOT")" = "$S1" ]; then
  ok "A 不接: installed stable's files at $S1 (asked GitHub), .client-version names it, no hub"
else bad "A 不接 install: rc=$rc cv=$(cat "$ROOT/.client-version" 2>&1) rel=$(release_of "$ROOT") out=$(printf '%s' "$out" | tail -3)"; fi
s=$(envrun bash "$ROOT/bin/fleet-update.sh" 2>&1)
case "$s" in "基础 · 版本 ${S1:0:7} · 跟 stable 同版 · 从 GitHub 取"*) ok "A fleet update: $s" ;; *) bad "A fleet update: $s" ;; esac

# --- B. 不接 follows stable ------------------------------------------------------
stable "$S2"
start
if [ "$RC" = 0 ] && wait_staged "$S2" && [ "$(release_of "$ROOT.versions/$S2")" = "$S2" ]; then
  ok "B stable moved: start exits 0 and stages $S2 from GitHub in the background"
else bad "B stage: rc=$RC out=$OUT log=$(cat "$STATE/stage.log" 2>&1) vers=$(ls "$ROOT.versions" 2>&1)"; fi
start
if [ "$RC" = 3 ] && [ "$(cv version)" = "$S2" ] && [ "$(release_of "$ROOT")" = "$S2" ] && [ -L "$ROOT" ]; then
  ok "B the next start switches (exit 3): version and files are stable's $S2"
else bad "B switch: rc=$RC out=$OUT cv=$(cv version) rel=$(release_of "$ROOT")"; fi
mv "$GH/api" "$GH/api.off"
start
if [ "$RC" = 0 ] && [ "$(cv version)" = "$S2" ] && [ ! -e "$ROOT.versions/.next" ]; then
  ok "B GitHub out of reach: open as is, nothing staged"
else bad "B unreachable: rc=$RC out=$OUT"; fi
mv "$GH/api.off" "$GH/api"

# --- C. 接 a hub that is never redeployed ---------------------------------------
HUBD="$WORK/hub"; mkdir -p "$HUBD/proxy"
ln -s "$GH/raw/$S2" "$HUBD/proxy/$S2"; ln -s "$GH/raw/$S3" "$HUBD/proxy/$S3"   # /install/stable/<sha> stand-in
python3 - "$HUBD" "$WORK/port" <<'PY' >"$WORK/srv.log" 2>&1 &
import functools, http.server, os, signal, sys
signal.alarm(600)   # never outlives the test
h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
h.func.log_message = lambda *a: None
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), h)
with open(sys.argv[2] + ".tmp", "w") as f:
    f.write(str(srv.server_address[1]))
os.replace(sys.argv[2] + ".tmp", sys.argv[2])
srv.serve_forever()
PY
SRV_PID=$!
for _ in $(seq 1 300); do [ -s "$WORK/port" ] && break; sleep 0.1; done   # a cold CI runner is slow
[ -s "$WORK/port" ] || { echo "FAIL C/D: the loopback hub never started: $(cat "$WORK/srv.log" 2>&1)"; exit 1; }
HUB="http://127.0.0.1:$(cat "$WORK/port")"
# hub_version <sha> [<client_url>] — what the hub's stable lookup reports
hub_version() {
  printf '{"version":"prod-abc1234","commit":"abc1234","client_version":"%s","stable":"%s","client_url":"%s","client_compat":1,"min_client_compat":0}\n' \
    "$1" "$1" "${2:-$HUB/proxy/$1}" > "$HUBD/version"
}
# the image's installer — the one this hub was built with; never changes below
sed "s#__FLEET_HUB_URL__#$HUB#" "$BIN/fleet-install.sh" > "$HUBD/install"
img=$(cksum < "$HUBD/install")
stable "$S2"; hub_version "$S2"
sandbox c
out=$(envrun FLEET_INSTALL_HUB=1 sh "$HUBD/install" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(cv version)" = "$S2" ] && [ "$(cv hub)" = "$HUB" ] && [ "$(release_of "$ROOT")" = "$S2" ]; then
  ok "C 接: installed through the hub's client_url at $S2; .client-version names the hub"
else bad "C 接 install: rc=$rc cv=$(cat "$ROOT/.client-version" 2>&1) out=$(printf '%s' "$out" | tail -3)"; fi
stable "$S3"; hub_version "$S3"        # stable moved — the hub is NOT redeployed
start
wait_staged "$S3"
start
if [ "$RC" = 3 ] && [ "$(cv version)" = "$S3" ] && [ "$(release_of "$ROOT")" = "$S3" ] && [ "$(cksum < "$HUBD/install")" = "$img" ]; then
  ok "C stable moved, the hub's /install unchanged: the client is on $S3 anyway"
else bad "C follow: rc=$RC out=$OUT cv=$(cv version) rel=$(release_of "$ROOT") log=$(cat "$STATE/stage.log" 2>&1)"; fi
C_VER=$(cv version)
s=$(envrun FLEET_HUB_URL="$HUB" bash "$ROOT/bin/fleet-update.sh" 2>&1)
case "$s" in "基础 · 版本 ${S3:0:7} · 跟 stable 同版 · 经入口取"*) ok "C fleet update: $s" ;; *) bad "C fleet update: $s" ;; esac

# --- D. the hub's proxy down: GitHub's raw host at the same commit ----------------
stable "$S4"; hub_version "$S4" "$HUB/no-such-proxy/$S4"
sandbox d
out=$(envrun FLEET_INSTALL_HUB=1 sh "$HUBD/install" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(cv version)" = "$S4" ] && [ "$(release_of "$ROOT")" = "$S4" ]; then
  ok "D client_url down: every file from GitHub at $S4"
else bad "D fallback: rc=$rc out=$(printf '%s' "$out" | tail -3)"; fi

# --- E. 承载: the checkout follows the same stable -------------------------------
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: > "$WORK/gitconfig"
BARE="$WORK/origin.git" SEED="$WORK/seed" CO="$WORK/host/.claude/fleet" LOG="$WORK/calls.log"
HCONF="$WORK/host/.config/claude-fleet"
mkdir -p "$WORK/host" "$HCONF" "$WORK/shim"; : > "$LOG"
printf '#!/bin/sh\nexit 1\n' > "$WORK/shim/tmux"; chmod +x "$WORK/shim/tmux"   # no live fleet: nothing busy
git init -q --bare -b master "$BARE"
git clone -q "$BARE" "$SEED" 2>/dev/null
mkdir -p "$SEED/bin" "$SEED/logs"
printf '#!/bin/bash\necho "apply $*" >> %s\necho "apply: ok — stub"\n' "$LOG" > "$SEED/bin/fleet-install-apply.sh"
printf '#!/bin/sh\necho "  PASS  gh       ok"\n' > "$SEED/bin/fleet-doctor.sh"
printf '#!/bin/sh\nexit 0\n' > "$SEED/bin/fleet-diskguard.sh"
: > "$SEED/bin/fleet-up.sh"
chmod +x "$SEED"/bin/*
hcommit() { echo "$1" >> "$SEED/f"; git -C "$SEED" add -A; git -C "$SEED" commit -qm "$1"; git -C "$SEED" rev-parse HEAD; }
H1=$(hcommit one); H2=$(hcommit two); H3=$(hcommit three)
git -C "$SEED" push -q origin master
git --git-dir="$BARE" update-ref refs/tags/stable "$H1"
git clone -q "$BARE" "$CO" 2>/dev/null; git -C "$CO" reset -q --hard "$H1"
htick() { OUT=$(env HOME="$WORK/host" FLEET_CONF_DIR="$HCONF" FLEET_SKIP_GLOBAL_CONF=1 PATH="$WORK/shim:$PATH" TMPDIR="$WORK" \
  bash "$BIN/fleet-update.sh" tick --root "$CO" 2>&1); RC=$?; }
hst() { sed -n "s/^$1: //p" "$HCONF/global/install-sync.state" | head -n 1; }
git --git-dir="$BARE" update-ref refs/tags/stable "$H2"
htick
if [ "$(hst result)" = updated ] && [ "$(git -C "$CO" rev-parse HEAD)" = "$H2" ] && grep -q "^apply --from $H1 --to $H2" "$LOG"; then
  ok "E stable moved: the next tick moves the checkout to it (install-sync updated)"
else bad "E follow: rc=$RC result=$(hst result) reason=$(hst reason) head=$(git -C "$CO" rev-parse HEAD) out=$OUT"; fi
env FLEET_CONF_DIR="$HCONF" bash "$BIN/fleet-epic-heartbeat.sh" 1813 --tick 1 --repo o/r --session f1 >/dev/null 2>&1
git --git-dir="$BARE" update-ref refs/tags/stable "$H3"
htick
if [ "$(hst result)" = deferred ] && [ "$(git -C "$CO" rev-parse HEAD)" = "$H2" ] && case "$(hst reason)" in *EPIC*) true ;; *) false ;; esac; then
  ok "E an EPIC heartbeat: deferred, HEAD untouched ($(hst reason | cut -c1-40)…)"
else bad "E epic: result=$(hst result) reason=$(hst reason) head=$(git -C "$CO" rev-parse HEAD)"; fi
env FLEET_CONF_DIR="$HCONF" bash "$BIN/fleet-epic-heartbeat.sh" --clear >/dev/null 2>&1
htick
[ "$(git -C "$CO" rev-parse HEAD)" = "$H3" ] && ok "E heartbeat gone: the next tick takes $H3" || bad "E after epic: $(hst result) $(hst reason)"
s=$(env HOME="$WORK/host" FLEET_CONF_DIR="$HCONF" FLEET_UPDATE_ROOT="$CO" FLEET_STABLE_API="file://$WORK/nothing" bash "$BIN/fleet-update.sh" 2>&1)
case "$s" in "承载 · 版本 ${H3:0:7} · 跟 stable 同版"*) ok "E fleet update: $s" ;; *) bad "E fleet update: $s" ;; esac
# one stable, one word: a client and a checkout on the same commit say the same 版本
sandbox e; envrun sh "$BIN/fleet-install.sh" >/dev/null 2>&1   # stable is $S4 on GitHub
c=$(envrun bash "$ROOT/bin/fleet-update.sh" 2>&1)
[ "$(cv version)" = "$S4" ] && case "$c" in "基础 · 版本 ${S4:0:7} "*) true ;; *) false ;; esac \
  && ok "E both layers lead with 版本 <stable's 7 hex> (C was on ${C_VER:0:7})" || bad "E version word: $c"

# --- F. degenerate --------------------------------------------------------------
sandbox f; mkdir -p "$ROOT/bin"; cp "$BIN/fleet-client-update.sh" "$BIN/fleet-update.sh" "$ROOT/bin/"
stable "$S1"
out=$(envrun bash "$ROOT/bin/fleet-client-update.sh" start 2>&1); rc=$?
out2=$(envrun bash "$ROOT/bin/fleet-update.sh" tick 2>&1); rc2=$?
if [ "$rc" = 0 ] && [ "$rc2" = 0 ] && [ -z "$out$out2" ] && [ ! -e "$STATE" ] && [ ! -e "$ROOT.versions" ]; then
  ok "F no .client-version: start and tick ask nothing, write nothing"
else bad "F degenerate: rc=$rc/$rc2 out=$out$out2 state=$(ls "$STATE" 2>&1)"; fi
sandbox f2
envrun FLEET_INSTALL_SRC="file://$GH/raw/$S1" sh "$BIN/fleet-install.sh" >/dev/null 2>&1
[ -f "$ROOT/bin/fleet" ] && [ ! -e "$ROOT/.client-version" ] \
  && ok "F FLEET_INSTALL_SRC pinned: installed, no .client-version (as before)" || bad "F pinned: $(ls -a "$ROOT" 2>&1)"

[ "$fail" = 0 ] && echo "fleet-update-selftest: PASS" || echo "fleet-update-selftest: FAIL"
exit "$fail"
