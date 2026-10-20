#!/bin/bash
# Shared upload helpers after #3008: local recv and inbox cleanup. Drag/drop,
# clipboard input ordering and remote transactions live in fleet-thin-upload-selftest.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"; UP="$BIN/fleet-client-upload.py"
. "$BIN/selftest-lib.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
st_tally
FID=11111111-2222-3333-4444-555555555555
mkdir -p "$W/home"
# The legacy recv remains for callers from the previous release.
p=$(printf abc | HOME="$W/home" FLEET_PASTE_LOG="$W/paste.log" python3 "$UP" recv - "$(id -un)" "x/$FID" --name n.txt)
[ -f "$p" ] && [ "$(cat "$p")" = abc ] && st_ok_all 'recv writes stdin to the session inbox' || st_miss "recv: $p"
p2=$(printf abc | HOME="$W/home" FLEET_PASTE_LOG="$W/paste.log" python3 "$UP" recv - "$(id -un)" "x/$FID" --name n.txt)
[ "$p2" = "$p" ] && st_ok_all 'same content reuses its path' || st_miss 'recv duplicated the content'

# ---------------------------------------------------------------- D sweep
G=99999999-2222-3333-4444-555555555555
mkdir -p "$W/home/.cache/claude-fleet/inbox/$G" "$W/home/.cache/claude-fleet/inbox/$FID" \
         "$W/home/.cache/claude-fleet/inbox/issue-7" "$W/home/.cache/claude-fleet/inbox/machine"
I2="$W/home/.cache/claude-fleet/inbox"
for d in "$G" "$FID" issue-7 machine; do printf x > "$I2/$d/f"; done
printf x > "$I2/$FID/old"; touch -t 202001010000 "$I2/$FID/old"
printf '#!/bin/sh\necho %s\necho other\n' "$FID" > "$W/live"; chmod +x "$W/live"
HOME="$W/home" FLEET_INBOX_LIVE_CMD="$W/live" python3 "$UP" sweep --dry > "$W/dry.out"
[ -d "$I2/$G" ] && grep -q "$G" "$W/dry.out" && st_ok_all "D --dry names, removes nothing" || st_miss "D --dry: $(cat "$W/dry.out")"
HOME="$W/home" FLEET_INBOX_LIVE_CMD="$W/live" python3 "$UP" sweep >/dev/null
[ ! -e "$I2/$G" ] && st_ok_all "D a gone session's inbox goes" || st_miss "D the gone session's inbox stayed"
[ -f "$I2/$FID/f" ] && [ ! -e "$I2/$FID/old" ] && st_ok_all "D a live one stays; a file past 7 days goes" || st_miss "D live: $(ls "$I2/$FID")"
[ -f "$I2/issue-7/f" ] && [ -f "$I2/machine/f" ] && st_ok_all "D key-named and machine wait out the days" || st_miss "D a key-named dir went"
printf '#!/bin/sh\nexit 1\n' > "$W/live"
HOME="$W/home" FLEET_INBOX_LIVE_CMD="$W/live" python3 "$UP" sweep >/dev/null
[ -f "$I2/$FID/f" ] && st_ok_all "D no read of the live windows removes no session's inbox" || st_miss "D an unknown read removed a live inbox"

st_done
