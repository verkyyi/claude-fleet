#!/bin/bash
# fleet-shell-list-selftest.sh — bin/fleet-shell.py's machine list (task KEA0):
# `--list` prints the person's machines off fleet-connect.py --pick (number ·
# machine · login · status · last heard · ← 家), and a bare number picks that row
# (a machine named like a number wins; a number past the list is refused).
# Both seams are stand-ins: FLEET_SHELL_PICK_CMD (the pick's JSON line) and
# FLEET_SHELL_ARGV_CMD (records the machine it was asked for). Nothing is reached.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
st_sandbox "${TMPDIR:-/tmp}/shelllist.XXXXXX"
st_tally
SHELLPY="$BIN/fleet-shell.py"
now=$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))')
ago3h=$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-3*3600-60)))')
cat > "$WORK/pick.json" <<EOF
{"machine":"ma","hostname":"mac-home","reason":"","login":"zoe","machines":[
 {"alias":"ma","hostname":"mac-home","login":"zoe","status":"online","seen_at":"$now"},
 {"alias":"mb","hostname":"mac-two","login":"zoe","status":"online","seen_at":"$ago3h"},
 {"alias":"laptop-x","hostname":"laptop-x","login":"zc","status":"lost","seen_at":""},
 {"alias":"7","hostname":"seven","login":"zoe","status":"","seen_at":""}]}
EOF
cat > "$WORK/argv.sh" <<'SH'
#!/bin/bash
for a in "$@"; do case "$a" in --argv|--offline) ;; *) echo "$a" >> "$SL_T/asked" ;; esac; done
printf '{"machine":"%s","argv":["ssh","-p","22022","zoe@h"],"host":3,"route":{"name":"entry","kind":"direct"}}\n' "${!#}"
SH
tr -d '\n' < "$WORK/pick.json" > "$WORK/pick.1" && printf '\n' >> "$WORK/pick.1" && mv "$WORK/pick.1" "$WORK/pick.json"   # one line, as --pick prints
chmod +x "$WORK/argv.sh"
run() { env SL_T="$WORK" FLEET_SHELL_PICK_CMD="cat $WORK/pick.json" FLEET_SHELL_ARGV_CMD="$WORK/argv.sh" \
          python3 "$SHELLPY" "$@" 2>"$WORK/err"; }

out=$(run --list); rc=$?
st_eq list-rc 0 "$rc"
st_has list-head "$out" "#  机器"
st_has list-home "$out" "ma (mac-home)"
st_has list-home-mark "$(printf '%s\n' "$out" | grep 'ma (mac-home)')" "← 家"
st_has list-online-now "$(printf '%s\n' "$out" | grep 'ma (mac-home)')" "在线"
st_has list-just-now "$(printf '%s\n' "$out" | grep 'ma (mac-home)')" "刚刚"
st_has list-hours "$(printf '%s\n' "$out" | grep 'mb (mac-two)')" "3 小时前"
st_has list-lost "$(printf '%s\n' "$out" | grep laptop-x)" "离线"
st_hasnt list-not-home "$(printf '%s\n' "$out" | grep 'mb (mac-two)')" "← 家"
st_has list-hint "$out" "fleet shell 2"

: > "$WORK/asked"; run 2 --print >/dev/null
st_eq number-picks-row "mb" "$(tail -n 1 "$WORK/asked")"
: > "$WORK/asked"; run 7 --print >/dev/null
st_eq name-wins-over-number "7" "$(tail -n 1 "$WORK/asked")"
: > "$WORK/asked"; run 9 --print >/dev/null; rc=$?
st_eq past-the-list-rc 2 "$rc"
st_has past-the-list-said "$(cat "$WORK/err")" "没有第 9 台"
st_eq past-the-list-not-asked "" "$(cat "$WORK/asked")"
: > "$WORK/asked"; run mac-two --print >/dev/null
st_eq name-as-is "mac-two" "$(tail -n 1 "$WORK/asked")"

out=$(env FLEET_SHELL_PICK_CMD=false python3 "$SHELLPY" --list 2>&1); rc=$?
st_eq no-pick-rc 1 "$rc"
st_has no-pick-said "$out" "没拿到你的机器列表"
st_done
