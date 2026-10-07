#!/bin/bash
# fleet-hub-url-selftest.sh — bin/fleet-hub-url.sh, the one hub-address reader
# (issue #2024): every place a node or a client-only computer keeps the address,
# in order, on a sandbox HOME. The case that made it: a MacBook whose fleet.conf
# names the hub only inside the guarded [client] section, where
# `fleet drill invite`'s column-0 sed said "no hub".
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
SH="$BIN/fleet-hub-url.sh"
FAILS=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
T=$(mktemp -d "${TMPDIR:-/tmp}/hub-url.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT

# want <rc> <url|-> <label> [env…] — run the reader on a fresh sandbox HOME ($H)
want() {
  local rc=$1 url=$2 label=$3 out got; shift 3
  out=$(env -i PATH="$PATH" HOME="$H" ${1+"$@"} bash "$SH" 2>&1); got=$?
  [ "$url" = - ] && url=''
  if [ "$got" = "$rc" ] && [ "$out" = "$url" ]; then ok "$label"
  else bad "$label: exit $got (want $rc), printed '$out' (want '$url')"; fi
}
fresh() { H="$T/h$1"; C="$H/.config/claude-fleet"; mkdir -p "$C"; }

fresh 0
want 1 - 'nothing anywhere = exit 1, nothing printed'
want 0 https://e.example 'FLEET_HUB_URL in the env (trailing / dropped)' FLEET_HUB_URL=https://e.example/
want 0 https://c.example 'CCQUOTA_HUB_URL in the env' CCQUOTA_HUB_URL=https://c.example
want 1 - 'a value that is not http(s) does not count' FLEET_HUB_URL=hub.example

fresh 1
printf '# ---- [common] ----\nFLEET_HOST=0\nexport FLEET_HUB_URL="https://common.example"\n' > "$C/fleet.conf"
want 0 https://common.example "fleet.conf's [common]"
want 0 https://e.example 'the env wins over fleet.conf' FLEET_HUB_URL=https://e.example

fresh 2
cat > "$C/fleet.conf" <<'EOF'
# ---- [common] ----
FLEET_HOST=0
_fcs="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/secrets.env"; [ -f "$_fcs" ] && . "$_fcs"; unset _fcs

# ---- [client] — only the shell (FLEET_SHELL=1) reads this section ----
if [ "${FLEET_SHELL:-0}" = 1 ]; then
  CCQUOTA_HUB_URL="https://client.example"
  FLEET_UI_LANG=zh
fi

# ---- [node] — the shell (FLEET_SHELL=1) does not read this section ----
if [ "${FLEET_SHELL:-0}" != 1 ]; then
:
fi
EOF
want 0 https://client.example "a client's guarded [client] section (the MacBook, #2024)"
want 0 https://client.example 'FLEET_CONF_DIR names the dir' FLEET_CONF_DIR="$C"

fresh 3
printf 'if [ "${FLEET_SHELL:-0}" != 1 ]; then\n  export FLEET_HUB_URL=https://node.example\nfi\n' > "$C/fleet.conf"
want 0 https://node.example "a node's guarded [node] section"

fresh 4
printf 'CCQUOTA_HUB_URL=https://shell.example\n' > "$C/shell.conf"
want 0 https://shell.example 'the old shell.conf'

fresh 5
printf 'CCQUOTA_NODE_TOKEN=ntok-secret\nexport CCQUOTA_HUB_URL="https://nodeenv.example"\n' > "$C/node.env"
want 0 https://nodeenv.example "node.env's CCQUOTA_HUB_URL (grepped)"
printf 'touch "%s/sourced"\n' "$T" >> "$C/node.env"
want 0 https://nodeenv.example 'node.env is never sourced'
[ -e "$T/sourced" ] && bad 'node.env was sourced' || ok 'node.env ran nothing'

fresh 6
printf '{"url": "https://json.example/", "token": "x"}\n' > "$C/hub.json"
want 0 https://json.example "hub.json's old url"
mkdir -p "$T/xdg/claude-fleet"; mv "$C/hub.json" "$T/xdg/claude-fleet/hub.json"
want 0 https://json.example 'XDG_CONFIG_HOME is honoured' XDG_CONFIG_HOME="$T/xdg"

fresh 7
printf 'export FLEET_HUB_URL="https://common.example"\n' > "$C/fleet.conf"
printf '{"url": "https://json.example"}\n' > "$C/hub.json"
want 0 https://common.example 'fleet.conf wins over hub.json'

fresh 8
printf 'echo noise; echo noise >&2\nexport FLEET_HUB_URL=https://quiet.example\n' > "$C/fleet.conf"
want 0 https://quiet.example "a conf's own output never reaches stdout"

# the --lib form: sourced, defines fleet_hub_url and prints nothing on its own
fresh 9
out=$(env -i PATH="$PATH" HOME="$H" FLEET_HUB_URL=https://lib.example bash -c '. "$1" --lib; echo "[loaded]"; fleet_hub_url' _ "$SH")
[ "$out" = "[loaded]
https://lib.example" ] && ok '. fleet-hub-url.sh --lib defines fleet_hub_url' || bad "--lib: $out"

[ "$FAILS" = 0 ] && { echo 'fleet-hub-url-selftest: PASS'; exit 0; }
echo "fleet-hub-url-selftest: FAIL ($FAILS)"; exit 1
