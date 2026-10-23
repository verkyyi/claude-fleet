#!/bin/bash
# Retired progress pulls are inert. Historical files remain readable and unchanged.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hub-progress.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
mkdir -p "$FLEET_CONF_DIR/hub-progress" "$FLEET_CONF_DIR/fleets/history/children"
printf '42\n' > "$FLEET_CONF_DIR/hub-progress/seq"
printf '%s\n' '{"events":[{"rid":"old","state":"MERGED"}],"seq":42}' > "$FLEET_CONF_DIR/hub-progress/last.json"
printf '%s\n' '{"child":"issue-7","state":"MERGED","pr":"8"}' > "$FLEET_CONF_DIR/fleets/history/children/issue-1.ndjson"
cp -R "$FLEET_CONF_DIR" "$WORK/before"
cat > "$WORK/curl" <<'CURL'
#!/bin/bash
printf 'unexpected network\n' >> "$FLEET_CONF_DIR/network"
exit 1
CURL
chmod +x "$WORK/curl"
export FLEET_HUB_CURL="$WORK/curl"
st_tally
for enabled in 0 1; do
  for age in 0 60; do
    CCQUOTA_FLEET=$enabled CCQUOTA_TOKEN=fixture CCQUOTA_HUB_URL=http://hub.invalid \
      bash "$BIN/fleet-hub-node.sh" progress --max-age "$age" > "$WORK/out" 2> "$WORK/err"
    rc=$?
    st_count; [ "$rc" = 0 ] && [ ! -s "$WORK/out" ] && [ ! -s "$WORK/err" ] || st_miss 'old progress caller returns inert success' "rc=$rc"
    st_count; diff -r "$WORK/before" "$FLEET_CONF_DIR" > "$WORK/diff" || st_miss 'no network, cursor, ledger, or history mutation' "$(cat "$WORK/diff")"
  done
done
st_count; python3 - "$FLEET_CONF_DIR" <<'PYHISTORY' || st_miss 'historical data remains readable'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
assert json.loads((root/'hub-progress/last.json').read_text())['seq']==42
assert json.loads((root/'fleets/history/children/issue-1.ndjson').read_text())['pr']=='8'
PYHISTORY
st_done
