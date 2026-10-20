#!/bin/bash
# fleet-dev-mode-selftest.sh — `fleet host dev on|off|status` (issue #2779,
# EPIC #2770 R3): bin/fleet-dev-mode.sh through bin/fleet-host.sh, against a
# sandbox install bin/fleet-install-sync.sh ticks on.
#
#   A  dev on: a plain-directory install is adopted, ~/.claude/fleet → the
#      checkout, global/dist-mode records it; status says 已开
#   B  stable moves: the tick answers `off · dev <checkout>` and switches nothing
#   C  the readers: fleet-dist-source.sh `INFO dev <checkout>` (even with a hub),
#      fleet-install-follow.sh OFF / dev, fleet-installs.sh 来源 dev
#   D  dev off: the link goes back to the version before, the record goes, and
#      the next tick is `switched` to the new stable
#   E  off when not on: says so, exit 0; on with no checkout / not a fleet dir: refused
#   F  managed login: refused without root's consent (link untouched), allowed with it
#   G  off with the old version gone: back to the version holding the repository
# check() evals its single-quoted test, so the variables it names look unused:
# shellcheck disable=SC2016,SC2034
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/devmode.XXXXXX")
trap 'rm -rf "$T"' EXIT
FAILS=0
bad() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then st_ok "$1"; else bad "$1"; fi; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset FLEET_HUB_URL CCQUOTA_HUB_URL FLEET_DIST_SOURCE FLEET_INSTALL_SYNC

# sandbox <dir> — origin.git + install (a clone at commit one) + stable=one
sandbox() {
  local d="$1"
  mkdir -p "$d/conf" "$d/home" "$d/node"
  (
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/install" 2>/dev/null
    mkdir -p "$d/install/bin"
    printf 'echo "apply: ok"\n' > "$d/install/bin/fleet-install-apply.sh"
    printf 'exit 0\n' > "$d/install/bin/fleet-doctor.sh"
    printf 'exit 0\n' > "$d/install/bin/fleet-diskguard.sh"; chmod +x "$d"/install/bin/*
    printf 'logs/\n' > "$d/install/.gitignore"
    git -C "$d/install" add -A && git -C "$d/install" commit -qm one && git -C "$d/install" push -q origin master
    git --git-dir="$d/origin.git" update-ref refs/tags/stable master
    # the developer's checkout: a fleet code dir of its own
    mkdir -p "$d/checkout/bin"
    : > "$d/checkout/bin/fleet-install-sync.sh"; : > "$d/checkout/bin/fleet-lib.sh"
  ) >/dev/null 2>&1
}
# stable moves one commit past what the install is at
move_stable() {
  local d="$1" w; w="$1/work"
  rm -rf "$w"; git clone -q "$d/origin.git" "$w" 2>/dev/null
  echo "$2" > "$w/f"; git -C "$w" add -A; git -C "$w" commit -qm "$2"
  git -C "$w" push -q origin master 2>/dev/null
  git --git-dir="$d/origin.git" update-ref refs/tags/stable master
}
# sandbox_env <dir> — the sandbox login, in the calling subshell
sandbox_env() { export HOME="$1/home" FLEET_CONF_DIR="$1/conf" FLEET_LIVE_DIR="$1/install" FLEET_NODE_STATE="$1/node" \
  FLEET_NODE_ROOT="$1/noderoot" FLEET_SKIP_GLOBAL_CONF=1; }
dev() { ( sandbox_env "$1"; shift; bash "$BIN/fleet-host.sh" dev "$@" ); }
tick() { ( sandbox_env "$1"; bash "$BIN/fleet-install-sync.sh" --root "$1/install" 2>"$1/tick.err" ); }
res() { sed -n 's/^result: //p' "$1/conf/global/install-sync.state"; }
reason() { sed -n 's/^reason: //p' "$1/conf/global/install-sync.state"; }
real() { (cd "$1" 2>/dev/null && pwd -P); }

D="$T/a"; sandbox "$D"
[ -d "$D/install/.git" ] || { echo "FAIL sandbox did not build"; exit 1; }
ONE=$(git -C "$D/install" rev-parse HEAD)
CO=$(real "$D/checkout")

# --- A ------------------------------------------------------------------------
out=$(dev "$D" on "$D/checkout" 2>&1); rc=$?
check "A on exits 0" '[ "$rc" = 0 ]'
check "A the install is now a link to the checkout" '[ -L "$D/install" ] && [ "$(real "$D/install")" = "$CO" ]'
check "A the old install was adopted into fleet.versions/<sha>" '[ -d "$D/install.versions/$ONE/.git" ]'
check "A dist-mode records mode · checkout · prev" \
  'grep -qx "mode: dev" "$D/conf/global/dist-mode" && grep -qx "checkout: $CO" "$D/conf/global/dist-mode" && grep -q "^prev: .*install.versions/$ONE" "$D/conf/global/dist-mode"'
st=$(dev "$D" status 2>&1)
check "A status says 已开 · dev <checkout>" 'printf "%s" "$st" | grep -q "开发模式 已开 · dev $CO"'
out=$(dev "$D" on "$D/checkout" 2>&1)
check "A on again: nothing to do" 'printf "%s" "$out" | grep -q "已经指向"'

# --- B ------------------------------------------------------------------------
move_stable "$D" two
TWO=$(git --git-dir="$D/origin.git" rev-parse stable)
tick "$D"
check "B the tick answers off · dev" '[ "$(res "$D")" = off ] && reason "$D" | grep -q "^dev · $CO"'
check "B the link still names the checkout" '[ "$(real "$D/install")" = "$CO" ]'
check "B no version of the new stable was checked out" '[ ! -d "$D/install.versions/$TWO" ]'

# --- C ------------------------------------------------------------------------
ds=$(HOME="$D/home" FLEET_CONF_DIR="$D/conf" FLEET_LIVE_DIR="$D/install" FLEET_HUB_URL=https://hub.example sh "$BIN/fleet-dist-source.sh")
check "C dist row: INFO dev <checkout>, with a hub too" 'printf "%s" "$ds" | grep -q "^INFO	dev ${CO}（开发中"'
fl=$(sh "$BIN/fleet-install-follow.sh" --self --dir "$D/install" --conf-dir "$D/conf" 2>/dev/null)
check "C install-follow: OFF · dev" 'printf "%s\n" "$fl" | grep -q "^verdict: *OFF" && printf "%s\n" "$fl" | grep -q "^result: *dev"'
mkdir -p "$T/homes/dana/.claude" "$T/homes/dana/.config/claude-fleet/global"
ln -s "$CO" "$T/homes/dana/.claude/fleet"
cp "$D/conf/global/dist-mode" "$T/homes/dana/.config/claude-fleet/global/dist-mode"
inst=$(FLEET_INSTALLS_HOMES="$T/homes" FLEET_INSTALLS_SUDO='' FLEET_INSTALLS_STABLE="$TWO" FLEET_NODE_ROOT="$T/none" \
  FLEET_NODE_STATE="$T/none" FLEET_INSTALLS_HUB='' FLEET_INSTALLS_LOGIN=dana bash "$BIN/fleet-installs.sh" --json 2>/dev/null)
check "C installs: 来源 dev" 'printf "%s" "$inst" | grep -q "\"source\": *\"dev\""'

# --- D ------------------------------------------------------------------------
out=$(dev "$D" off 2>&1); rc=$?
check "D off exits 0" '[ "$rc" = 0 ]'
check "D the link is back on the version before" '[ "$(real "$D/install")" = "$(real "$D/install.versions/$ONE")" ]'
check "D the record is gone" '[ ! -e "$D/conf/global/dist-mode" ]'
tick "$D"
check "D the next tick is switched to the new stable" \
  '[ "$(res "$D")" = switched ] && [ "$(git -C "$D/install" rev-parse HEAD)" = "$TWO" ]'
check "D the checkout is untouched" '[ -f "$CO/bin/fleet-lib.sh" ]'

# --- E ------------------------------------------------------------------------
out=$(dev "$D" off 2>&1); rc=$?
check "E off when not on: 本来就没开, exit 0" '[ "$rc" = 0 ] && printf "%s" "$out" | grep -q "本来就没开"'
dev "$D" on >/dev/null 2>&1; rc=$?
check "E on with no checkout: usage (2)" '[ "$rc" = 2 ]'
mkdir -p "$T/notfleet"
dev "$D" on "$T/notfleet" >/dev/null 2>&1; rc=$?
check "E on a dir that is not fleet code: refused (1)" '[ "$rc" = 1 ] && [ ! -e "$D/conf/global/dist-mode" ]'
dev "$D" on "$D/install.versions/$TWO" >/dev/null 2>&1; rc=$?
check "E on a release version dir: refused (1)" '[ "$rc" = 1 ]'

# --- F ------------------------------------------------------------------------
me=$(id -un)
printf '{"%s": {"managed": true, "since": 1}}\n' "$me" > "$D/node/accounts.json"
was=$(readlink "$D/install")
out=$(dev "$D" on "$D/checkout" 2>&1); rc=$?
check "F managed, no consent: refused, naming account dev" \
  '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "account dev $me on" && [ "$(readlink "$D/install")" = "$was" ] && [ ! -e "$D/conf/global/dist-mode" ]'
printf '{"%s": {"managed": true, "since": 1, "dev": 5}}\n' "$me" > "$D/node/accounts.json"
dev "$D" on "$D/checkout" >/dev/null 2>&1; rc=$?
check "F managed, consented: on" '[ "$rc" = 0 ] && [ "$(real "$D/install")" = "$CO" ]'
out=$(dev "$D" off 2>&1)
check "F off on a managed login names taking the consent back" 'printf "%s" "$out" | grep -q "account dev $me off"'
rm -f "$D/node/accounts.json"

# --- G ------------------------------------------------------------------------
dev "$D" on "$D/checkout" >/dev/null 2>&1
prev=$(sed -n 's/^prev: //p' "$D/conf/global/dist-mode")
mv "$prev" "$prev.gone"
out=$(dev "$D" off 2>&1); rc=$?
check "G old version gone: back to the version holding the repository" \
  '[ "$rc" = 0 ] && [ "$(real "$D/install")" = "$(real "$D/install.versions/$ONE")" ]'

[ "$FAILS" = 0 ] && { echo "fleet-dev-mode-selftest: all passed"; exit 0; }
echo "fleet-dev-mode-selftest: $FAILS failed"; exit 1
