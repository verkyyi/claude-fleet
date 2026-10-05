#!/bin/bash
# fleet-conf-selftest.sh — a machine's ONE config file (issue #1623, EPIC #1615 C8):
# bin/fleet-conf.sh migrate / role / set-hub, the readers that now take
# $FLEET_CONF_DIR/fleet.conf (fleet-lib.sh, fleet-shell.sh's FLEET_SHELL guard,
# fleet_config_write.py, fleet-connect.py / fleet-login.py's hub address), and
# fleet-doctor.sh's `role` row — on three role fixtures in a sandbox install.
#
#   A. degenerate   — a login that is neither client nor node: migrate writes
#                     nothing, role says none, the doctor prints no role row;
#                     $FLEET_CONF_DIR/fleet.conf is never listed as a fleet
#   B. node (m4)    — install fleet.conf (hub URL, a viewer TOKEN, CCQUOTA_FLEET,
#                     aliases) + fleets/fleet/conf + node.env: every key resolves
#                     byte for byte as before; the token moved to secrets.env
#                     (0600) and is in no config; each old file kept as .bak; the
#                     fleet conf trimmed to its identity; doctor role PASS; a
#                     second migrate changes nothing
#   C. client (MacBook) — hub.json {url, token} + shell.conf: role client,
#                     FLEET_HUB_URL in [common], hub.json keeps ONLY its token;
#                     fleet-connect.py / fleet-login.py read the address there
#   D. client,node (m5) — all of the above at once: the shell (FLEET_SHELL=1)
#                     reads [common]+[client] and none of [node]; a node reader
#                     sees everything as before
#   E. writes       — the config modal's writer puts a new key INSIDE [node];
#                     set-hub on a fresh login makes a client file
#   F. doctor before— an unmigrated node: role INFO, inferred, names the command
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-conf.sh fleet-lib.sh fleet-doctor.sh fleet_config_write.py fleet-connect.py fleet-login.py; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-conf-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

CHECKS=0 FAILS=0
ok()  { CHECKS=$((CHECKS + 1)); }
bad() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    | /' >&2; }
is()  { if [ "$2" = "$3" ]; then ok; else bad "$1 — want [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1 — lacks [$3]" "$2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1 — carries [$3]" "$2" ;; *) ok ;; esac; }

# A sandbox install: bin/ as a dir of symlinks (so $BIN/../fleet.conf is the
# sandbox's), HOME and FLEET_CONF_DIR of its own.
mkbox() {   # $1 name → sets INS, H, CD
  INS="$WORK/$1/inst"; H="$WORK/$1/home"; CD="$H/.config/claude-fleet"
  mkdir -p "$INS/bin" "$CD"
  for f in "$BIN"/*; do [ -f "$f" ] && ln -s "$f" "$INS/bin/${f##*/}"; done
  [ -d "$BIN/../conf" ] && ln -s "$BIN/../conf" "$INS/conf"
}
# run <cmd…> in the box's environment, the operator's settings out of reach
run() {
  env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$CD" TMPDIR="$WORK" LANG=C "$@"
}
KEYS='CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN CCQUOTA_FLEET FLEET_NODE_ALIASES FLEET_AUTOFILL_NODE FLEET_COMPACT_PREP_PCT FLEET_REPO FLEET_MAIN FLEET_BASE_BRANCH FLEET_AUTOFILL FLEET_SIDEBAR_SOURCE FLEET_SHELL_WIDTH FLEET_UI_LANG'
# view [shell] → KEY=value for every key a node script (or, with `shell`, the
# shell) would resolve: fleet-lib's load + the fleet's conf.
view() {
  local sh=0; [ "${1:-}" = shell ] && sh=1
  run FLEET_SHELL="$([ $sh = 1 ] && echo 1)" KEYS="$KEYS" bash -c '
    . "$0/fleet-lib.sh"
    [ "${FLEET_SHELL:-}" = 1 ] || fleet_load_conf fleet
    for k in $KEYS; do eval "printf \"%s=%s\\n\" $k \"\${$k-<unset>}\""; done' "$INS/bin"
}
role_line() { run bash "$INS/bin/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+role([[:space:]]|$)'; }

# ---------------------------------------------------------------------------- A
mkbox a
out=$(run bash "$INS/bin/fleet-conf.sh" migrate 2>&1); rc=$?
is "A: migrate on an empty login exits 0" "$rc" 0
[ -e "$CD/fleet.conf" ] && bad "A: no file may be written for a login that is neither" || ok
is "A: role none" "$(run bash "$INS/bin/fleet-conf.sh" role)" none
is "A: no doctor role row" "$(role_line)" ""
# the machine conf is never a legacy flat fleet named `fleet`
printf 'FLEET_ROLE="node"\n' > "$CD/fleet.conf"
lst=$(run bash -c '. "$0/fleet-lib.sh"; fleet_each_conf; printf "conf=%s\n" "$(fleet_conf_file fleet)"' "$INS/bin")
hasnt "A: fleet_each_conf skips \$FLEET_CONF_DIR/fleet.conf" "$lst" "$CD/fleet.conf	"
hasnt "A: fleet_conf_file fleet never answers the machine conf" "$lst" "conf=$CD/fleet.conf"
rm -f "$CD/fleet.conf"

# ---------------------------------------------------------------------------- B
node_fixture() {
  cat > "$INS/fleet.conf" <<'EOF'
# ~/.claude/fleet/fleet.conf on m4
export CCQUOTA_HUB_URL=https://hub.example
export CCQUOTA_VIEWER_TOKEN=vt-secret-123
export CCQUOTA_FLEET=1
FLEET_NODE_ALIASES="macmini=m5 mini2=m4"
FLEET_AUTOFILL_NODE=local
FLEET_SIDEBAR_SOURCE=local

# --- 上下文梯子 ---
FLEET_COMPACT_PREP_PCT=55
EOF
  mkdir -p "$CD/fleets/fleet"
  cat > "$CD/fleets/fleet/conf" <<EOF
# claude-fleet: fleet 'fleet' — written by fleet-up.sh 2026-10-04 07:23:29
# Overlays the global fleet.conf for this fleet's tmux session. Add any other
# FLEET_* keys (see fleet.conf.example) — e.g. FLEET_CTX_WINDOW, FLEET_PROTECTED_RE.
FLEET_REPO="acme/app"
FLEET_MAIN="$H/projects/app"
FLEET_BASE_BRANCH="main"
FLEET_SEED="1"
FLEET_AUTOFILL="0"
EOF
  printf 'CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_TOKEN=node-tok\n' > "$CD/node.env"; chmod 600 "$CD/node.env"
}
mkbox b; node_fixture
before=$(view)
out=$(run bash "$INS/bin/fleet-conf.sh" migrate 2>&1); rc=$?
is "B: migrate exits 0" "$rc" 0
has "B: says one file" "$out" "one file — $CD/fleet.conf (role node)"
after=$(view)
is "B: every key resolves as before" "$after" "$before"
mc=$(cat "$CD/fleet.conf")
has "B: FLEET_ROLE node" "$mc" 'FLEET_ROLE="node"'
has "B: the hub address, once" "$mc" 'export FLEET_HUB_URL="https://hub.example"'
is "B: the URL is spelled once in the file" "$(grep -c 'hub.example' "$CD/fleet.conf")" 1
hasnt "B: no credential in the config" "$mc" "vt-secret-123"
is "B: secrets.env holds the token" "$(grep -c 'vt-secret-123' "$CD/secrets.env")" 1
is "B: secrets.env is 0600" "$(stat -c '%a' "$CD/secrets.env" 2>/dev/null || stat -f '%Lp' "$CD/secrets.env")" 600
is "B: fleet.conf is 0600" "$(stat -c '%a' "$CD/fleet.conf" 2>/dev/null || stat -f '%Lp' "$CD/fleet.conf")" 600
[ -f "$INS/fleet.conf.bak" ] && [ ! -e "$INS/fleet.conf" ] && ok || bad "B: install fleet.conf kept as .bak, gone from its path"
[ -f "$CD/fleets/fleet/conf.bak" ] && ok || bad "B: fleet conf kept as .bak"
fc=$(grep -v '^#' "$CD/fleets/fleet/conf")
hasnt "B: fleet conf trimmed (FLEET_AUTOFILL moved)" "$fc" FLEET_AUTOFILL
has "B: fleet conf keeps its identity" "$fc" 'FLEET_REPO="acme/app"'
has "B: …and FLEET_SEED" "$fc" 'FLEET_SEED="1"'
is "B: node.env untouched" "$(cat "$CD/node.env")" "$(printf 'CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_TOKEN=node-tok')"
sh -n "$CD/fleet.conf" && ok || bad "B: the file parses under sh"
snap=$(cat "$CD/fleet.conf")
out=$(run bash "$INS/bin/fleet-conf.sh" migrate 2>&1)
has "B: a second migrate is a no-op" "$out" "already one file"
is "B: …and changes nothing" "$(cat "$CD/fleet.conf")" "$snap"
is "B: role" "$(run bash "$INS/bin/fleet-conf.sh" role --why)" "$(printf 'node\tFLEET_ROLE')"
l=$(role_line)
has "B: doctor role PASS" "$l" "PASS  role"
has "B: doctor names the role and the one file" "$l" "node (FLEET_ROLE) — 配置只有一份"

# ---------------------------------------------------------------------------- C
client_fixture() {
  printf '{"url": "https://hub.example", "token": "wc-tok"}\n' > "$CD/hub.json"; chmod 600 "$CD/hub.json"
  printf 'FLEET_SHELL_WIDTH=34\nFLEET_UI_LANG=zh\n' > "$CD/shell.conf"
}
mkbox c; rm -rf "$INS/conf"; client_fixture
out=$(run bash "$INS/bin/fleet-conf.sh" migrate 2>&1); rc=$?
is "C: migrate exits 0" "$rc" 0
mc=$(cat "$CD/fleet.conf")
has "C: FLEET_ROLE client" "$mc" 'FLEET_ROLE="client"'
has "C: the address from hub.json" "$mc" 'export FLEET_HUB_URL="https://hub.example"'
has "C: shell.conf's keys in [client]" "$(sed -n '/^# ---- \[client\]/,$p' "$CD/fleet.conf")" "FLEET_SHELL_WIDTH=34"
hasnt "C: a client file has no [node] section" "$mc" 'FLEET_SHELL:-0}" != 1'
hj=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(sorted(d.items()))' "$CD/hub.json")
is "C: hub.json keeps only its token" "$hj" "[('token', 'wc-tok')]"
[ -f "$CD/hub.json.bak" ] && [ -f "$CD/shell.conf.bak" ] && [ ! -e "$CD/shell.conf" ] && ok || bad "C: hub.json / shell.conf kept as .bak"
got=$(run python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("fc", sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.machine_conf_hub())' "$INS/bin/fleet-connect.py")
is "C: fleet-connect.py reads the address from fleet.conf" "$got" "https://hub.example"
got=$(run python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("fl", sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.hub_url(None))' "$INS/bin/fleet-login.py")
is "C: fleet-login.py reads the address from fleet.conf" "$got" "https://hub.example"
sv=$(view shell)
has "C: the shell sees the hub address" "$(run FLEET_SHELL=1 bash -c '. "$0/fleet-lib.sh"; printf "%s" "$FLEET_HUB_URL"' "$INS/bin")" "https://hub.example"
has "C: the shell sees [client]" "$sv" "FLEET_SHELL_WIDTH=34"
is "C: role" "$(run bash "$INS/bin/fleet-conf.sh" role)" client

# ---------------------------------------------------------------------------- D
mkbox d; node_fixture; client_fixture
printf 'FLEET_INSTALL_SYNC=0\n' > "$CD/fleet.settings"
before=$(view)
out=$(run bash "$INS/bin/fleet-conf.sh" migrate 2>&1); rc=$?
is "D: migrate exits 0" "$rc" 0
has "D: role client,node" "$(cat "$CD/fleet.conf")" 'FLEET_ROLE="client,node"'
after=$(view)
is "D: a node reader resolves every key as before" "$after" "$before"
has "D: fleet.settings folded" "$(cat "$CD/fleet.conf")" "FLEET_INSTALL_SYNC=0"
[ -f "$CD/fleet.settings.bak" ] && [ ! -e "$CD/fleet.settings" ] && ok || bad "D: fleet.settings kept as .bak"
sv=$(view shell)
has "D: the shell reads [client]" "$sv" "FLEET_SHELL_WIDTH=34"
has "D: the shell reads [common]" "$sv" "FLEET_NODE_ALIASES=macmini=m5 mini2=m4"
has "D: the shell gets the hub URL" "$sv" "CCQUOTA_HUB_URL=https://hub.example"
has "D: the shell does NOT read the node's FLEET_SIDEBAR_SOURCE" "$sv" "FLEET_SIDEBAR_SOURCE=<unset>"
has "D: …nor its CCQUOTA_FLEET" "$sv" "CCQUOTA_FLEET=<unset>"
is "D: doctor role" "$(role_line | sed -E 's/^[[:space:]]+//; s/ — .*//')" "PASS  role     client,node (FLEET_ROLE)"
is "D: fleet_settings_file is the one file" "$(run bash -c '. "$0/fleet-lib.sh"; fleet_settings_file' "$INS/bin")" "$CD/fleet.conf"

# ---------------------------------------------------------------------------- E
run python3 "$INS/bin/fleet_config_write.py" "$CD/fleet.conf" FLEET_NEW_KNOB 7 num >/dev/null 2>&1 \
  || run python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("w", sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.write(sys.argv[2], "FLEET_NEW_KNOB", "7", "num")' "$INS/bin/fleet_config_write.py" "$CD/fleet.conf"
is "E: the writer puts a new key inside [node]" "$(grep -A1 'FLEET_NEW_KNOB' "$CD/fleet.conf" | tail -n1)" 'fi  # ---- [node] end ----'
sh -n "$CD/fleet.conf" && ok || bad "E: still parses"
is "E: the shell does not see a node write" "$(view shell | grep -c FLEET_NEW_KNOB)" 0
mkbox e
run bash "$INS/bin/fleet-conf.sh" set-hub https://hub.example --role client; rc=$?
is "E: set-hub on a fresh login exits 0" "$rc" 0
mc=$(cat "$CD/fleet.conf" 2>/dev/null)
has "E: …makes a client file" "$mc" 'FLEET_ROLE="client"'
has "E: …with the address" "$mc" 'export FLEET_HUB_URL="https://hub.example"'
run bash "$INS/bin/fleet-conf.sh" add-role node
has "E: add-role node → client,node" "$(cat "$CD/fleet.conf")" 'FLEET_ROLE="client,node"'
is "E: one FLEET_ROLE line" "$(grep -c '^FLEET_ROLE=' "$CD/fleet.conf")" 1

# ---------------------------------------------------------------------------- F
mkbox f; node_fixture
l=$(role_line)
has "F: unmigrated → INFO" "$l" "INFO  role"
has "F: inferred" "$l" "node (inferred — node: a fleet conf)"
has "F: names the command" "$l" "fleet-conf.sh migrate"
hasnt "F: no credential printed" "$l" "vt-secret"

printf 'fleet-conf-selftest: %d checks, %d failed\n' "$CHECKS" "$FAILS"
[ "$FAILS" = 0 ]
