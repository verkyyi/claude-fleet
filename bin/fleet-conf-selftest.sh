#!/bin/bash
# fleet-conf-selftest.sh — a machine's ONE config file (issue #1623, EPIC #1615 C8):
# bin/fleet-conf.sh migrate / host / set-hub, the readers that now take
# $FLEET_CONF_DIR/fleet.conf (fleet-lib.sh, fleet-shell.sh's FLEET_SHELL guard,
# fleet_config_write.py, fleet-connect.py / fleet-login.py's hub address), and
# fleet-doctor.sh's `能力` row (the `role` row before issue #1806) — on three
# kinds of computer in a sandbox install. The one capability key is FLEET_HOST
# (issue #1806): `node` in the old FLEET_ROLE list ⇒ 1, unless the node only
# coordinates (node.env COMPUTE=0 and no fleet here).
#
#   A. degenerate   — a login that is neither client nor node: migrate writes
#                     nothing, host says 0, the doctor's 能力 row is 基础 · 承载 未开;
#                     $FLEET_CONF_DIR/fleet.conf is never listed as a fleet
#   B. node (m4)    — install fleet.conf (hub URL, a viewer TOKEN, CCQUOTA_FLEET,
#                     aliases) + fleets/fleet/conf + node.env: every key resolves
#                     byte for byte as before; the token moved to secrets.env
#                     (0600) and is in no config; each old file kept as .bak; the
#                     fleet conf trimmed to its identity; FLEET_HOST=1; doctor
#                     能力 PASS; a second migrate changes nothing
#   C. client (MacBook) — hub.json {url, token} + shell.conf: FLEET_HOST=0,
#                     FLEET_HUB_URL in [common], hub.json keeps ONLY its token;
#                     fleet-connect.py / fleet-login.py read the address there
#   D. client,node (m5) — all of the above at once: the shell (FLEET_SHELL=1)
#                     reads [common]+[client] and none of [node]; a node reader
#                     sees everything as before
#   E. writes       — the config modal's writer puts a new key INSIDE [node];
#                     set-hub on a fresh login makes a FLEET_HOST=0 file; the old
#                     add-role node / set-hub --role node turn hosting on
#   F. doctor before— an unmigrated node: 能力 INFO, inferred, names the command
#   G. the old key  — a file that still says FLEET_ROLE (m5 client,node · a laptop
#                     node that only coordinates · a client) is rewritten in place
#                     by migrate: FLEET_HOST 1 · 0 · 0, every other line kept, and
#                     until then host / the doctor read the old key (one version);
#                     `role` still answers from FLEET_HOST
#   H. keys kept    — (issue #1887) a migration rewrite leaves fleet.conf.bak-<time>;
#                     a migrated FLEET_HOST=1 on a machine that hosts nothing (a
#                     leftover fleet conf, no node.env, no fleet running) goes to 0
#                     ONCE — --dry-run only says so, a later set-host 1 is not
#                     undone; _carry moves every key a file that appeared mid-
#                     rewrite set into the same section of the new one
#   I. repos/       — (issue #1937) migrate moves an old-layout fleet conf's repo
#                     into repos/<slug>.conf (ahead of the overlay it had, which
#                     still wins; first in repos/.order): fleet_repos, every
#                     repo's view, a no-window caller's FLEET_REPO and fleet_uuid
#                     are unchanged, both files kept as .bak, --dry-run moves
#                     nothing, a second run changes nothing; the original first
#                     repo then removes like any (no promotion)
#   J. hub fill     — (issue #2116) node.env has CCQUOTA_FLEET=1 + a hub URL, an
#                     already-migrated fleet.conf has neither: migrate adds both
#                     to [common] (no token), the node's view reads them, the
#                     doctor's hub row goes WARN → PASS, a second run changes
#                     nothing; an explicit CCQUOTA_FLEET=0 is never overwritten;
#                     a client with no node.env stays byte for byte
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
cap_line() { run bash "$INS/bin/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+能力([[:space:]]|$)'; }
# the doctor's rows that describe what this computer is — ONE (issue #1806)
what_rows() { run bash "$INS/bin/fleet-doctor.sh" 2>/dev/null | grep -cE '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+(client|role|node|能力)([[:space:]]|$)'; }

# ---------------------------------------------------------------------------- A
mkbox a
out=$(run bash "$INS/bin/fleet-conf.sh" migrate 2>&1); rc=$?
is "A: migrate on an empty login exits 0" "$rc" 0
[ -e "$CD/fleet.conf" ] && bad "A: no file may be written for a login that is neither" || ok
is "A: role none" "$(run bash "$INS/bin/fleet-conf.sh" role)" none
is "A: host 0" "$(run bash "$INS/bin/fleet-conf.sh" host)" 0
is "A: doctor 能力: the base only" "$(cap_line | sed -E 's/^[[:space:]]+//')" "PASS  能力     基础 · 承载 未开（fleet host on）"
is "A: one row says what this computer is" "$(what_rows)" 1
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
has "B: says one file" "$out" "one file — $CD/fleet.conf (FLEET_HOST=1)"
after=$(view)
is "B: every key resolves as before" "$after" "$before"
mc=$(cat "$CD/fleet.conf")
has "B: FLEET_HOST=1" "$mc" 'FLEET_HOST=1'
hasnt "B: no FLEET_ROLE" "$mc" 'FLEET_ROLE'
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
# …and its repo moved into repos/ like every repo (issue #1937; leg I pins it)
hasnt "B: the fleet conf names no repo" "$fc" 'FLEET_REPO='
ov=$(cat "$CD/fleets/fleet/repos/acme-app.conf" 2>/dev/null)
has "B: the repo's overlay holds its identity" "$ov" 'FLEET_REPO="acme/app"'
has "B: …and FLEET_SEED" "$ov" 'FLEET_SEED="1"'
is "B: node.env untouched" "$(cat "$CD/node.env")" "$(printf 'CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_TOKEN=node-tok')"
sh -n "$CD/fleet.conf" && ok || bad "B: the file parses under sh"
snap=$(cat "$CD/fleet.conf")
out=$(run bash "$INS/bin/fleet-conf.sh" migrate 2>&1)
has "B: a second migrate is a no-op" "$out" "already one file"
is "B: …and changes nothing" "$(cat "$CD/fleet.conf")" "$snap"
is "B: host" "$(run bash "$INS/bin/fleet-conf.sh" host --why)" "$(printf '1\tFLEET_HOST')"
is "B: the old word still answers (one version)" "$(run bash "$INS/bin/fleet-conf.sh" role)" client,node
l=$(cap_line)
has "B: doctor 能力 PASS" "$l" "PASS  能力     基础 · 承载 — FLEET_HOST"
has "B: …and the one file" "$l" "配置只有一份"
is "B: one row says what this computer is" "$(what_rows)" 1

# ---------------------------------------------------------------------------- C
client_fixture() {
  printf '{"url": "https://hub.example", "token": "wc-tok"}\n' > "$CD/hub.json"; chmod 600 "$CD/hub.json"
  printf 'FLEET_SHELL_WIDTH=34\nFLEET_UI_LANG=zh\n' > "$CD/shell.conf"
}
mkbox c; rm -rf "$INS/conf"; client_fixture
out=$(run bash "$INS/bin/fleet-conf.sh" migrate 2>&1); rc=$?
is "C: migrate exits 0" "$rc" 0
mc=$(cat "$CD/fleet.conf")
has "C: FLEET_HOST=0" "$mc" 'FLEET_HOST=0'
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
is "C: host" "$(run bash "$INS/bin/fleet-conf.sh" host)" 0
has "C: doctor 能力: 承载 未开" "$(cap_line)" "基础 · 承载 未开（fleet host on）"

# ---------------------------------------------------------------------------- D
mkbox d; node_fixture; client_fixture
printf 'FLEET_INSTALL_SYNC=0\n' > "$CD/fleet.settings"
before=$(view)
out=$(run bash "$INS/bin/fleet-conf.sh" migrate 2>&1); rc=$?
is "D: migrate exits 0" "$rc" 0
has "D: FLEET_HOST=1" "$(cat "$CD/fleet.conf")" 'FLEET_HOST=1'
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
is "D: doctor 能力" "$(cap_line | sed -E 's/^[[:space:]]+//; s/ — .*//')" "PASS  能力     基础 · 承载"
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
has "E: …makes a FLEET_HOST=0 file" "$mc" 'FLEET_HOST=0'
has "E: …with the address" "$mc" 'export FLEET_HUB_URL="https://hub.example"'
run bash "$INS/bin/fleet-conf.sh" add-role node
has "E: add-role node (the old word) → FLEET_HOST=1" "$(cat "$CD/fleet.conf")" 'FLEET_HOST=1'
is "E: one FLEET_HOST line" "$(grep -c '^FLEET_HOST=' "$CD/fleet.conf")" 1
run bash "$INS/bin/fleet-conf.sh" set-hub https://hub.example
is "E: set-hub never turns hosting off" "$(run bash "$INS/bin/fleet-conf.sh" host)" 1
run bash "$INS/bin/fleet-conf.sh" set-host 0
is "E: set-host 0" "$(grep '^FLEET_HOST=' "$CD/fleet.conf")" 'FLEET_HOST=0'
sh -n "$CD/fleet.conf" && ok || bad "E: still parses after set-host"

# ---------------------------------------------------------------------------- F
mkbox f; node_fixture
l=$(cap_line)
has "F: unmigrated → INFO" "$l" "INFO  能力"
has "F: inferred" "$l" "基础 · 承载 — inferred — a fleet conf"
has "F: names the command" "$l" "fleet-conf.sh migrate"
hasnt "F: no credential printed" "$l" "vt-secret"

# ---------------------------------------------------------------------------- G
oldkey() {   # $1 FLEET_ROLE value — a file one version old, in the [common] it had
  printf '# claude-fleet — one file\n\n# ---- [common] ----\nFLEET_ROLE="%s"\nexport FLEET_HUB_URL="https://hub.example"\nFLEET_UI_LANG=zh\n' "$1" > "$CD/fleet.conf"
}
# m5: client,node with a fleet here
mkbox g1; node_fixture; rm -f "$INS/fleet.conf"; oldkey client,node
is "G m5: before migrate, host reads the old key" "$(run bash "$INS/bin/fleet-conf.sh" host --why)" "$(printf '1\tFLEET_ROLE=client,node（旧键）')"
l=$(cap_line)
has "G m5: doctor says the old key and the command" "$l" "FLEET_ROLE=client,node（旧键） — 同步时自动改写成 FLEET_HOST"
has "G m5: …as INFO" "$l" "INFO  能力"
want=$(sed 's/^FLEET_ROLE="client,node"$/FLEET_HOST=1/' "$CD/fleet.conf")
out=$(run bash "$INS/bin/fleet-conf.sh" migrate --quiet 2>&1)
has "G m5: migrate says what it rewrote" "$out" 'FLEET_ROLE="client,node" → FLEET_HOST=1'
is "G m5: rewritten in place, every other line kept" "$(cat "$CD/fleet.conf")" "$want"
is "G m5: host 1" "$(run bash "$INS/bin/fleet-conf.sh" host --why)" "$(printf '1\tFLEET_HOST')"
out=$(run bash "$INS/bin/fleet-conf.sh" migrate 2>&1)
has "G m5: a second migrate is a no-op" "$out" "already one file"
# a laptop joined only to coordinate: node.env COMPUTE=0, no fleet here
mkbox g2; oldkey client,node
printf 'CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_TOKEN=t\nCCQUOTA_FLEET_COMPUTE=0\n' > "$CD/node.env"; chmod 600 "$CD/node.env"
run bash "$INS/bin/fleet-conf.sh" migrate --quiet >/dev/null 2>&1
has "G laptop: a coordinate-only node is not 承载" "$(cat "$CD/fleet.conf")" "FLEET_HOST=0"
hasnt "G laptop: no FLEET_ROLE left" "$(cat "$CD/fleet.conf")" "FLEET_ROLE"
has "G laptop: doctor 能力 未开" "$(cap_line)" "基础 · 承载 未开（fleet host on）"
is "G laptop: one row says what this computer is" "$(what_rows)" 1
# a client
mkbox g3; oldkey client
run bash "$INS/bin/fleet-conf.sh" migrate --quiet >/dev/null 2>&1
has "G client: FLEET_HOST=0" "$(cat "$CD/fleet.conf")" "FLEET_HOST=0"
is "G client: role still answers (one version)" "$(run bash "$INS/bin/fleet-conf.sh" role)" client
sh -n "$CD/fleet.conf" && ok || bad "G: the rewritten file parses"

# ---- H. keys kept, FLEET_HOST corrected once (issue #1887) ------------------------
hrun() { run TMUX_TMPDIR="$WORK/htt" FLEET_LAUNCHD_AGENTS_DIR="$H/LA" FLEET_INSTALL_DAEMON_DIR="$H/LD" "$@"; }
mkbox h1; mkdir -p "$CD/fleets/fleet" "$WORK/htt"
printf 'FLEET_REPO="o/r"\nFLEET_MAIN="/nowhere"\nFLEET_BASE_BRANCH="master"\n' > "$CD/fleets/fleet/conf"
cat > "$CD/fleet.conf" <<'EOF'
# Migrated by fleet-conf.sh 2026-10-06 12:05:03 from: hub.json(url)

# ---- [common] ----
FLEET_HOST=1
export FLEET_HUB_URL="https://hub.example"

# ---- [client] — only the shell (FLEET_SHELL=1) reads this section ----
if [ "${FLEET_SHELL:-0}" = 1 ]; then
:
export FLEET_UI_LANG=zh
fi  # ---- [client] end ----
EOF
before=$(cat "$CD/fleet.conf")
is "H: before, host reads the file's 1" "$(hrun bash "$INS/bin/fleet-conf.sh" host)" 1
out=$(hrun bash "$INS/bin/fleet-conf.sh" migrate --dry-run 2>&1)
has "H: --dry-run says it would correct" "$out" "would correct FLEET_HOST 1 → 0"
is "H: --dry-run changes nothing" "$(cat "$CD/fleet.conf")" "$before"
out=$(hrun bash "$INS/bin/fleet-conf.sh" migrate --quiet 2>&1)
has "H: migrate corrects and says so" "$out" "FLEET_HOST 1 → 0"
has "H: FLEET_HOST=0" "$(cat "$CD/fleet.conf")" "$(printf 'FLEET_HOST=0\n# FLEET_HOST checked')"
has "H: the [client] key stays" "$(cat "$CD/fleet.conf")" "export FLEET_UI_LANG=zh"
is "H: the old file kept as .bak-<time>" "$(cat "$CD"/fleet.conf.bak-*)" "$before"
out=$(hrun bash "$INS/bin/fleet-conf.sh" migrate 2>&1)
has "H: once — a second migrate is a no-op" "$out" "already one file"
hrun bash "$INS/bin/fleet-conf.sh" set-host 1 >/dev/null 2>&1
hrun bash "$INS/bin/fleet-conf.sh" migrate --quiet >/dev/null 2>&1
is "H: a person's set-host 1 is never corrected" "$(hrun bash "$INS/bin/fleet-conf.sh" host)" 1
is "H: …one mark line, not two" "$(grep -c '^# FLEET_HOST checked' "$CD/fleet.conf")" 1
# the old key: FLEET_ROLE → FLEET_HOST in place leaves a backup too
mkbox h2; oldkey client
run bash "$INS/bin/fleet-conf.sh" migrate --quiet >/dev/null 2>&1
has "H role: the in-place rewrite left a .bak-<time>" "$(cat "$CD"/fleet.conf.bak-* 2>/dev/null)" 'FLEET_ROLE="client"'
# _carry: the same section, a key the new file already sets wins
cat > "$WORK/c.old" <<'EOF'
# ---- [common] ----
FLEET_HOST=1
export FLEET_MINE=7

# ---- [client] — x ----
if [ "${FLEET_SHELL:-0}" = 1 ]; then
export FLEET_UI_LANG=zh
fi  # ---- [client] end ----

# ---- [node] — y ----
if [ "${FLEET_SHELL:-0}" != 1 ]; then
FLEET_MAX_SESSIONS=9
FLEET_X=1
fi  # ---- [node] end ----
EOF
cat > "$WORK/c.new" <<'EOF'
# ---- [common] ----
FLEET_HOST=0

# ---- [client] — x ----
if [ "${FLEET_SHELL:-0}" = 1 ]; then
:
fi  # ---- [client] end ----

# ---- [node] — y ----
if [ "${FLEET_SHELL:-0}" != 1 ]; then
FLEET_MAX_SESSIONS=3
fi  # ---- [node] end ----
EOF
cat > "$WORK/carry.sh" <<'EOF'
eval "$(sed -n '/^NODE_OPEN=/,/^CLIENT_CLOSE=/p' "$1")"
eval "$(sed -n '/^_carry() {/,/^}/p' "$1")"
_carry "$2" "$3"
EOF
bash "$WORK/carry.sh" "$BIN/fleet-conf.sh" "$WORK/c.old" "$WORK/c.new" || bad "H carry: _carry failed"
is "H carry: each section gains only what it lacked" "$(cat "$WORK/c.new")" "$(cat <<'EOF'
# ---- [common] ----
FLEET_HOST=0
export FLEET_MINE=7

# ---- [client] — x ----
if [ "${FLEET_SHELL:-0}" = 1 ]; then
:
export FLEET_UI_LANG=zh
fi  # ---- [client] end ----

# ---- [node] — y ----
if [ "${FLEET_SHELL:-0}" != 1 ]; then
FLEET_MAX_SESSIONS=3
FLEET_X=1
fi  # ---- [node] end ----
EOF
)"

# ---- I. every repo in repos/ (issue #1937) ----------------------------------------
# An old-layout fleet: the conf names acme/app (+ a deploy key and a fleet-wide
# key), repos/ holds aaa/first (sorts BEFORE it) and zzz/last, and acme/app has an
# overlay of its own carrying an override. The fleet's UUID is NOT frozen yet.
mkbox i
# One file already (leg B covers the fold): only the repo move runs here.
printf '# one file\nFLEET_HOST=1\n' > "$CD/fleet.conf"
mkdir -p "$CD/fleets/fleet/repos" "$CD/control" "$H/p/app" "$H/p/app2" "$H/p/first" "$H/p/last"
cat > "$CD/fleets/fleet/conf" <<EOF
# claude-fleet: fleet 'fleet' — written by fleet-up.sh 2026-10-04 07:23:29
FLEET_REPO="acme/app"
FLEET_MAIN="$H/p/app"
FLEET_BASE_BRANCH="main"
FLEET_DEPLOY_REF="origin/prod"
FLEET_CTX_WINDOW="7"
EOF
printf 'FLEET_REPO="acme/app"\nFLEET_MODEL="sonnet"\n' > "$CD/fleets/fleet/repos/acme-app.conf"
printf 'FLEET_REPO="aaa/first"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\n' "$H/p/first" > "$CD/fleets/fleet/repos/aaa-first.conf"
printf 'FLEET_REPO="zzz/last"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="dev"\n' "$H/p/last" > "$CD/fleets/fleet/repos/zzz-last.conf"
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT)"); c.execute("INSERT INTO metadata VALUES(?,?)", ("machine_id","5b1c0a52-6a1e-4c55-9d27-0f3a4c2d9e10")); c.commit()' "$CD/control/state.sqlite3"
lib_i() { run bash -c ". '$INS/bin/fleet-lib.sh'; $1"; }
# what each repo resolves to, and what a caller with no window (a daemon) reads
rview() { lib_i 'for r in $(fleet_repos fleet); do ( fleet_load_repo_conf fleet "$r" >/dev/null 2>&1
  printf "%s main=%s base=%s deploy=%s model=%s ctx=%s\n" "$r" "$FLEET_MAIN" "$FLEET_BASE_BRANCH" "${FLEET_DEPLOY_REF:-}" "${FLEET_MODEL:-}" "${FLEET_CTX_WINDOW:-}" ); done
  fleet_load_conf fleet; printf "nowindow=%s %s %s\n" "$FLEET_REPO" "$FLEET_MAIN" "$FLEET_BASE_BRANCH"'; }
repos0=$(lib_i 'fleet_repos fleet')
is "I: old layout lists the conf's repo first" "$(printf '%s\n' "$repos0" | tr '\n' ' ')" "acme/app aaa/first zzz/last "
uuid0=$(lib_i 'fleet_uuid fleet'); rm -f "$CD/fleets/fleet/identity"   # computed, then un-frozen again
case "$uuid0" in ????????-????-????-????-????????????) ok ;; *) bad "I: no UUID computed before ($uuid0)" ;; esac
rv0=$(rview)
list0=$(run bash "$INS/bin/fleet-repo.sh" list --session fleet 2>&1)
out=$(run bash "$INS/bin/fleet-conf.sh" migrate --dry-run 2>&1)
has "I: --dry-run says it would move" "$out" "would move fleet fleet's repo acme/app"
has "I: --dry-run moves nothing" "$(cat "$CD/fleets/fleet/conf")" 'FLEET_REPO="acme/app"'
out=$(run bash "$INS/bin/fleet-conf.sh" migrate 2>&1); rc=$?
is "I: migrate exits 0" "$rc" 0
has "I: says it moved" "$out" "every repo in repos/ — fleet:acme/app"
is "I: fleet_repos unchanged, order too" "$(lib_i 'fleet_repos fleet')" "$repos0"
is "I: fleet_uuid unchanged" "$(lib_i 'fleet_uuid fleet')" "$uuid0"
[ -f "$CD/fleets/fleet/identity" ] && ok || bad "I: the identity was not frozen by the move"
is "I: every repo resolves as before (and a caller with no window reads the first)" "$(rview)" "$rv0"
fc=$(grep -v '^#' "$CD/fleets/fleet/conf")
is "I: the fleet conf keeps only the fleet's setting" "$fc" 'FLEET_CTX_WINDOW="7"'
ov=$(grep -v '^#' "$CD/fleets/fleet/repos/acme-app.conf")
has "I: the overlay took the identity" "$ov" "FLEET_MAIN=\"$H/p/app\""
has "I: …and the repo-scoped deploy key" "$ov" 'FLEET_DEPLOY_REF="origin/prod"'
has "I: …and kept its own override" "$ov" 'FLEET_MODEL="sonnet"'
is "I: repos/.order puts it first, the rest as they were" "$(cat "$CD/fleets/fleet/repos/.order" | tr '\n' ' ')" "acme-app aaa-first zzz-last "
[ -f "$CD/fleets/fleet/conf.bak" ] && [ -f "$CD/fleets/fleet/repos/acme-app.conf.bak" ] && ok \
  || bad "I: the conf and the old overlay are kept as .bak"
list1=$(run bash "$INS/bin/fleet-repo.sh" list --session fleet 2>&1)
is "I: fleet-repo.sh list names the same repos" "$(printf '%s\n' "$list1" | awk 'NR>1{print $1}')" "$(printf '%s\n' "$list0" | awk 'NR>1{print $1}')"
has "I: …each from repos/" "$list1" "[repos/acme-app.conf]"
snap=$(cat "$CD/fleets/fleet/conf" "$CD/fleets/fleet/repos/acme-app.conf" "$CD/fleets/fleet/repos/.order")
out=$(run bash "$INS/bin/fleet-conf.sh" migrate 2>&1)
hasnt "I: a second migrate moves nothing" "$out" "every repo in repos/"
is "I: …and changes nothing" "$(cat "$CD/fleets/fleet/conf" "$CD/fleets/fleet/repos/acme-app.conf" "$CD/fleets/fleet/repos/.order")" "$snap"
# the original first repo is removed like any other — no promotion, nothing else moves
out=$(run bash "$INS/bin/fleet-repo.sh" remove --session fleet acme/app 2>&1); rc=$?
is "I: removing the original first repo exits 0" "$rc" 0
hasnt "I: …with no promotion" "$out" "promot"
is "I: …the others stay, in order" "$(lib_i 'fleet_repos fleet' | tr '\n' ' ')" "aaa/first zzz/last "
is "I: …the fleet conf untouched" "$(grep -v '^#' "$CD/fleets/fleet/conf")" 'FLEET_CTX_WINDOW="7"'
is "I: …fleet_uuid still unchanged" "$(lib_i 'fleet_uuid fleet')" "$uuid0"
is "I: …a caller with no window reads the new first" "$(lib_i 'fleet_load_conf fleet; printf %s "$FLEET_REPO|$FLEET_BASE_BRANCH|${FLEET_DEPLOY_REF:-}"')" "aaa/first|master|"
# a new repo lists last
printf 'FLEET_REPO="bbb/new"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="main"\n' "$H/p/app2" > "$CD/fleets/fleet/repos/bbb-new.conf"
lib_i 'fleet_repo_order_put fleet bbb/new'
is "I: a repo recorded later lists after the others" "$(lib_i 'fleet_repos fleet' | tr '\n' ' ')" "aaa/first zzz/last bbb/new "

# ---------------------------------------------------------------------------- J
hub_row() { run bash "$INS/bin/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+hub([[:space:]]|$)'; }
j_conf() {
  printf '# claude-fleet — one file\n\n# ---- [common] ----\nFLEET_HOST=1\n%s\n# ---- [node] ----\nif [ "${FLEET_SHELL:-0}" != 1 ]; then\n:\nFLEET_AUTOFILL_NODE=local\nfi  # ---- [node] end ----\n' "${1:-}" > "$CD/fleet.conf"
}
mkbox j
j_conf
printf 'CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_TOKEN=node-tok\nCCQUOTA_FLEET=1\n' > "$CD/node.env"; chmod 600 "$CD/node.env"
has "J: doctor WARNs while fleet.conf says off" "$(hub_row)" "WARN  hub"
has "J: …naming both keys" "$(hub_row)" "CCQUOTA_FLEET=1、FLEET_HUB_URL"
out=$(run bash "$INS/bin/fleet-conf.sh" migrate --dry-run 2>&1)
has "J: --dry-run says what it would add" "$out" "would add to $CD/fleet.conf [common] from node.env: CCQUOTA_FLEET=1 FLEET_HUB_URL"
hasnt "J: --dry-run writes nothing" "$(cat "$CD/fleet.conf")" "CCQUOTA_FLEET"
out=$(run bash "$INS/bin/fleet-conf.sh" migrate --quiet 2>&1); rc=$?
is "J: migrate exits 0" "$rc" 0
has "J: says what it added" "$out" "from node.env: CCQUOTA_FLEET=1 FLEET_HUB_URL"
mc=$(cat "$CD/fleet.conf")
has "J: CCQUOTA_FLEET in the file" "$mc" "export CCQUOTA_FLEET=1"
has "J: FLEET_HUB_URL in the file" "$mc" 'export FLEET_HUB_URL="https://hub.example"'
hasnt "J: no token entered it" "$mc" "node-tok"
is "J: both sit in [common]" "$(awk '/^# ---- \[common\]/{c=1;next} /^# ---- \[/{c=0} c' "$CD/fleet.conf" | grep -cE '^export (CCQUOTA_FLEET|FLEET_HUB_URL)=')" 2
sh -n "$CD/fleet.conf" && ok || bad "J: the file still parses"
vv=$(view)
has "J: a node script reads the hub as on" "$vv" "CCQUOTA_FLEET=1"
has "J: the shell reads it too" "$(run FLEET_SHELL=1 bash -c '. "$0/fleet-lib.sh"; printf "%s" "$FLEET_HUB_URL"' "$INS/bin")" "https://hub.example"
has "J: doctor hub PASS after" "$(hub_row)" "PASS  hub"
snap=$(cat "$CD/fleet.conf")
out=$(run bash "$INS/bin/fleet-conf.sh" migrate --quiet 2>&1)
hasnt "J: a second migrate adds nothing" "$out" "from node.env"
is "J: …and changes nothing" "$(cat "$CD/fleet.conf")" "$snap"
# the operator's explicit off is theirs: never overwritten, the doctor says it
j_conf 'CCQUOTA_FLEET=0'
run bash "$INS/bin/fleet-conf.sh" migrate --quiet >/dev/null 2>&1
has "J: an explicit CCQUOTA_FLEET=0 stays" "$(cat "$CD/fleet.conf")" "CCQUOTA_FLEET=0"
hasnt "J: …and no =1 is added beside it" "$(cat "$CD/fleet.conf")" "CCQUOTA_FLEET=1"
has "J: doctor names the explicit off" "$(hub_row)" "写着 CCQUOTA_FLEET=0"
# a URL carrying credentials is never written
j_conf
printf 'CCQUOTA_HUB_URL=https://u:pw@hub.example\nCCQUOTA_FLEET=1\n' > "$CD/node.env"
out=$(run bash "$INS/bin/fleet-conf.sh" migrate --quiet 2>&1)
hasnt "J: a credentialed URL is not written" "$(cat "$CD/fleet.conf")" "pw@"
has "J: …and says so" "$out" "carries credentials"
# a client (no node.env): byte for byte, and no hub row
mkbox j2
printf '# claude-fleet — one file\n\n# ---- [common] ----\nFLEET_HOST=0\n' > "$CD/fleet.conf"
snap=$(cat "$CD/fleet.conf")
out=$(run bash "$INS/bin/fleet-conf.sh" migrate --quiet 2>&1)
is "J: a client without node.env is byte for byte" "$(cat "$CD/fleet.conf")" "$snap"
is "J: …migrate says nothing" "$out" ""
is "J: …and the doctor has no hub row" "$(hub_row)" ""

printf 'fleet-conf-selftest: %d checks, %d failed\n' "$CHECKS" "$FAILS"
[ "$FAILS" = 0 ]
