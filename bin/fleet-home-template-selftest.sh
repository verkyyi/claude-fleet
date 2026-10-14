#!/bin/bash
# fleet-home-template-selftest.sh — bin/fleet-home-template.py in a sandbox
# (issue #4194; BREAK-IT `home-template-leak`).
#
#   A  build: the version's home made by the build command into a staging home,
#      then scrubbed (no fleet.conf, no ~/.ssh, no Claude session state, no
#      per-install ids in .claude.json, no bootstrapped mark), every file / link
#      naming the staging home recorded, the base 0711 and the template 0700
#   B  a credential-shaped file or content outside the version's code ⇒ refused,
#      nothing kept; the same in the starter checkout (the runtime's bytes) passes
#   C  a binary file naming the staging home ⇒ refused
#   D  clone: the home is the template's copy, every recorded file and link
#      names the new home, marked, 0700, newer than the wash (ctime), and a
#      change to the clone never reaches the template
#   E  no template for the runtime's version ⇒ exit 3, nothing made; a home that
#      exists ⇒ exit 1, untouched; not root ⇒ exit 2
#   F  a second version's build keeps the newest previous one, drops older ones
# The build runs as this process (FLEET_HOME_TEMPLATE_RUNAS=-) with a stub
# build command; clone hands the home to THIS login (the only uid a test owns).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d "${TMPDIR:-/tmp}/home-template-selftest.XXXXXX") || exit 2
W=$(cd "$W" && pwd -P)
trap 'rm -rf "${W:?}"' EXIT INT TERM HUP
FAILS=0
fail() { FAILS=$((FAILS + 1)); printf 'selftest FAIL %s\n' "$1"; }
ok() { printf 'ok   %s\n' "$1"; }
T="$BIN/fleet-home-template.py"
ME=$(id -un)
export FLEET_HOME_TEMPLATE_DIR="$W/tpl" FLEET_NODE_ROOT="$W/rt" FLEET_HOME_TEMPLATE_RUNAS=- FLEET_HOME_TEMPLATE_TEST_EUID=0
S1=1111111111111111111111111111111111111111 S2=2222222222222222222222222222222222222222 S3=3333333333333333333333333333333333333333
runtime() { mkdir -p "$W/rt/$1/bin"; rm -f "$W/rt/current"; ln -s "$W/rt/$1" "$W/rt/current"; }
# the stub of a login's first minute: what install + bootstrap leave in $HOME
# shellcheck disable=SC2016 # expanded by the build's bash
GOOD='mkdir -p "$HOME/.claude/fleet.versions/v/bin" "$HOME/.config/claude-fleet/global" "$HOME/.ssh" "$HOME/.claude/projects/x" "$HOME/projects/claude-fleet"
ln -s "$HOME/.claude/fleet.versions/v" "$HOME/.claude/fleet"
printf "source %s/.claude/fleet/conf/tmux.conf\n" "$HOME" > "$HOME/.tmux.conf"
printf "{\"userID\": \"abc\", \"numStartups\": 3, \"theme\": \"dark\", \"projects\": {\"%s/projects/claude-fleet\": {}}}\n" "$HOME" > "$HOME/.claude.json"
printf "x\n" > "$HOME/.config/claude-fleet/fleet.conf"
printf "%s\n" "$FLEET_NODE_ROOT" > "$HOME/.config/claude-fleet/global/bootstrap.applied"
: > "$HOME/.config/claude-fleet/global/bootstrapped"
: > "$HOME/.ssh/known_hosts"; : > "$HOME/.claude/projects/x/s.jsonl"
printf "fake = \"sk-ant-api03-FIXTUREFIXTURE\"\n" > "$HOME/projects/claude-fleet/fixture.py"
printf "plain\n" > "$HOME/.zshrc"'

# ---- A: build ----
runtime "$S1"
FLEET_HOME_TEMPLATE_BUILD_CMD="$GOOD" python3 "$T" build > "$W/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q "^built ${S1:0:12}" "$W/out" && ok 'A built' || { cat "$W/out"; fail "A build: $rc"; }
H="$W/tpl/$S1/home"
for g in .config/claude-fleet/fleet.conf .config/claude-fleet/global/bootstrapped .ssh .claude/projects; do
  [ ! -e "$H/$g" ] && ok "A scrubbed: $g" || fail "A not scrubbed: $g"
done
[ -f "$H/.config/claude-fleet/global/bootstrap.applied" ] && ok 'A the apply mark stays (the clone skips the full apply)' || fail 'A the apply mark is gone'
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if "userID" not in d and "numStartups" not in d and d.get("theme")=="dark" else 1)' "$H/.claude.json" \
  && ok 'A .claude.json: per-install ids dropped, the rest kept' || fail 'A .claude.json not scrubbed'
python3 - "$W/tpl/$S1/meta.json" <<'PY' && ok 'A meta records the files and the link naming the staging home' || fail 'A meta wrong'
import json, sys
m = json.load(open(sys.argv[1]))
assert sorted(m["rewrite"]) == [".claude.json", ".tmux.conf"], m["rewrite"]
assert m["relink"] == [".claude/fleet"], m["relink"]
PY
[ "$(stat -f %Lp "$W/tpl" 2>/dev/null || stat -c %a "$W/tpl")" = 711 ] && [ "$(stat -f %Lp "$W/tpl/$S1" 2>/dev/null || stat -c %a "$W/tpl/$S1")" = 700 ] \
  && ok 'A base 0711, template 0700' || fail 'A modes'
[ ! -e "$W/tpl/build" ] && [ ! -e "$W/tpl/build.lock" ] && ok 'A no staging left' || fail 'A staging left'
python3 "$T" status | grep -q "^ready ${S1:0:12}" && ok 'A status: ready' || fail 'A status'
FLEET_HOME_TEMPLATE_BUILD_CMD='exit 9' python3 "$T" build | grep -q 'there already' && ok 'A built once per version' || fail 'A rebuilt'

# ---- B: credentials refused ----
runtime "$S2"
FLEET_HOME_TEMPLATE_BUILD_CMD="$GOOD"'
mkdir -p "$HOME/.config/claude-fleet"; printf "CCQUOTA_TOKEN=x\n" > "$HOME/.config/claude-fleet/node.env"' python3 "$T" build > "$W/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'credential-shaped file .config/claude-fleet/node.env' "$W/out" && [ ! -e "$W/tpl/$S2" ] \
  && ok 'B a node.env ⇒ refused, nothing kept' || { cat "$W/out"; fail "B node.env: $rc"; }
FLEET_HOME_TEMPLATE_BUILD_CMD="$GOOD"'
printf "export K=sk-ant-oat01-LEAKEDLEAKED\n" >> "$HOME/.zshrc"' python3 "$T" build > "$W/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'credential-shaped content in .zshrc' "$W/out" && [ ! -e "$W/tpl/$S2" ] \
  && ok 'B a token in .zshrc ⇒ refused' || { cat "$W/out"; fail "B content: $rc"; }

# ---- C: a binary naming the staging home ----
FLEET_HOME_TEMPLATE_BUILD_CMD="$GOOD"'
printf "\0\0bin %s\0" "$HOME" > "$HOME/.claude/blob.bin"' python3 "$T" build > "$W/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'binary file naming the staging home' "$W/out" && ok 'C a binary naming the staging home ⇒ refused' || { cat "$W/out"; fail "C: $rc"; }

# ---- D: clone ----
runtime "$S1"
D="$W/homes/$ME"; mkdir -p "$W/homes"
sleep 1; since=$(date +%s)
python3 "$T" clone "$ME" --home "$D" > "$W/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q "^cloned ${S1:0:12} → $D" "$W/out" && ok "D cloned ($(sed 's/.*(//; s/)//' "$W/out"))" || { cat "$W/out"; fail "D clone: $rc"; }
grep -q "source $D/.claude/fleet/conf" "$D/.tmux.conf" && ! grep -q "$W/tpl" "$D/.tmux.conf" "$D/.claude.json" \
  && ok 'D files name the new home' || fail 'D a file still names the staging home'
[ "$(readlink "$D/.claude/fleet")" = "$D/.claude/fleet.versions/v" ] && ok 'D the link names the new home' || fail "D link: $(readlink "$D/.claude/fleet")"
grep -q "^$S1 " "$D/.config/claude-fleet/global/home-template" && ok 'D marked home-template' || fail 'D no mark'
[ "$(stat -f %Lp "$D" 2>/dev/null || stat -c %a "$D")" = 700 ] && ok 'D 0700' || fail 'D mode'
python3 - "$D" "$since" <<'PY' && ok 'D every entry is newer than the wash (the check never reads it as the last person'"'"'s)' || fail 'D an entry predates the wash'
import os, sys
top, since = sys.argv[1], float(sys.argv[2])
for d, ds, fs in os.walk(top):
    for n in ds + fs:
        assert os.lstat(os.path.join(d, n)).st_ctime >= since, n
PY
echo mine >> "$D/.zshrc"
grep -q mine "$W/tpl/$S1/home/.zshrc" && fail 'D a change to the clone reached the template' || ok 'D the template is untouched by the clone'

# ---- E: refusals ----
python3 "$T" clone "$ME" --home "$D" > "$W/out" 2>&1; [ "$?" = 1 ] && grep -q mine "$D/.zshrc" && ok 'E a home that exists: 1, untouched' || fail 'E existing home'
runtime "$S3"
python3 "$T" clone "$ME" --home "$W/homes/x" > "$W/out" 2>&1; rc=$?
[ "$rc" = 3 ] && [ ! -e "$W/homes/x" ] && grep -q '^none ' "$W/out" && ok 'E no template for this version: 3, nothing made' || fail "E none: $rc"
FLEET_HOME_TEMPLATE_TEST_EUID=501 python3 "$T" clone "$ME" --home "$W/homes/y" > /dev/null 2>&1; [ "$?" = 2 ] && ok 'E not root: 2' || fail 'E not root'
FLEET_HOME_TEMPLATE_TEST_EUID=501 python3 "$T" build > /dev/null 2>&1; [ "$?" = 2 ] && ok 'E build not root: 2' || fail 'E build not root'

# ---- F: versions kept ----
runtime "$S2"; FLEET_HOME_TEMPLATE_BUILD_CMD="$GOOD" python3 "$T" build >/dev/null 2>&1
touch "$W/tpl/$S2"; sleep 1
runtime "$S3"; FLEET_HOME_TEMPLATE_BUILD_CMD="$GOOD" python3 "$T" build >/dev/null 2>&1
[ -d "$W/tpl/$S3" ] && [ -d "$W/tpl/$S2" ] && [ ! -e "$W/tpl/$S1" ] && ok 'F the current and the newest previous kept, older gone' \
  || fail "F kept: $(ls "$W/tpl" | tr '\n' ' ')"

[ "$FAILS" = 0 ] && { echo 'fleet-home-template-selftest: PASS'; exit 0; }
echo "fleet-home-template-selftest: $FAILS FAIL"; exit 1
