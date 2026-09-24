#!/bin/bash
# doc-preview-share-selftest.sh — skills/doc-preview/share.sh's serving half
# (issue #1093), hermetic: a fake `tailscale` (and a blind `lsof`) on PATH, a
# scratch HOME, real server.py processes on loopback.
#
#   • HTTP-DIRECT  `tailscale serve` refused with the not-operator stderr
#                  (`--operator` / `sudo`) → server.py binds the tailscale IPv4
#                  and READY is `http://<magicdns>:<port>/d/<id>/`, the line says
#                  it is plain http inside the tailnet, $ROOT/mode = http-direct,
#                  and --list / a second share keep that URL. Never the cert hint.
#   • CERT         any OTHER serve failure → the HTTPS-cert hint, exit 1, and the
#                  entries it rendered are rolled back (--list: nothing shared).
#   • HTTPS        serve succeeds → https URL, mode = https (unchanged behaviour).
#   • PORT PROBE   the start port is held by a socket `lsof` cannot see (another
#                  login's server, faked by an lsof that always says "free") →
#                  a real bind() probe skips it; no EADDRINUSE death.
#   • NO HALF-STATE the server cannot start at all → exit 1 with no server.pid /
#                  server.port / mode left behind and no new entries.
#   • DOCTOR       fleet-doctor's `docprev` row: operator = this login → PASS;
#                  another login → INFO naming the http-direct fallback and the
#                  one-time `sudo tailscale serve` command; unreadable → no row.
#
# NEVER calls `share.sh --stop`: its pkill would hit the operator's LIVE
# doc-preview server. Servers started here are killed by pid.
# node or python3 absent → SKIP cleanly (exit 0), per the run-selftests convention.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SH="$BIN/../skills/doc-preview/share.sh"
[ -f "$SH" ] || { printf 'selftest: %s not found\n' "$SH" >&2; exit 2; }
for t in node python3; do
  command -v "$t" >/dev/null 2>&1 || { printf 'doc-preview-share-selftest: %s not installed — SKIP\n' "$t"; exit 0; }
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/docprev-share.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
ROOT="$WORK/home/.cache/claude-doc-preview"
PIDS=()
cleanup() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done
  [ -f "$ROOT/server.pid" ] && kill "$(cat "$ROOT/server.pid")" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
mkdir -p "$WORK/home" "$WORK/fake"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }
has()  { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) ;; *) fail "$3" "$2";; esac; }
lacks(){ CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) fail "$3" "$2";; esac; }
ok()   { CHECKS=$((CHECKS + 1)); "$@" || fail "check failed: $*"; }
nofile(){ CHECKS=$((CHECKS + 1)); [ ! -e "$1" ] || fail "$2 ($1 exists: $(cat "$1" 2>/dev/null))"; }

# fake tailscale: the tailnet "IPv4" is loopback (the only address a test can bind);
# `serve --bg` behaves per $WORK/serve.mode: operator | cert | ok.
cat > "$WORK/fake/tailscale" <<SH
#!/bin/sh
case "\$1 \${2:-}" in
  "status --json") echo '{"Self":{"DNSName":"box.tailnet.ts.net."}}' ;;
  "status "*)      exit 0 ;;
  "ip -4")         cat "$WORK/ts.ip" ;;
  "serve status")  exit 0 ;;
  "serve --bg")
    printf '%s\n' "\$*" >> "$WORK/serve.argv"
    case "\$(cat "$WORK/serve.mode")" in
      operator) printf "Use 'sudo tailscale %s'.\nTo not require root, use 'sudo tailscale set --operator=\\\$USER' once.\n" "\$*" >&2; exit 1 ;;
      cert)     echo 'error: certificates are not enabled for this tailnet' >&2; exit 1 ;;
      *)        exit 0 ;;
    esac ;;
  "serve reset"|"funnel status") exit 0 ;;
  "debug prefs")   cat "$WORK/prefs.json" ;;
  *) exit 0 ;;
esac
SH
# blind lsof: sees no listener at all — what a port held by ANOTHER login looks like.
printf '#!/bin/sh\nexit 1\n' > "$WORK/fake/lsof"
chmod +x "$WORK/fake/tailscale" "$WORK/fake/lsof"
echo 127.0.0.1 > "$WORK/ts.ip"

# a free start port for this run (bind-probed), so a live doc-preview can't collide
BASEPORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
share() { HOME="$WORK/home" PATH="$WORK/fake:$PATH" DOC_PREVIEW_PORT="$BASEPORT" DOC_PREVIEW_SESSION=t "$SH" "$@" 2>&1; }
reset_state() {
  [ -f "$ROOT/server.pid" ] && kill "$(cat "$ROOT/server.pid")" 2>/dev/null
  rm -rf "$ROOT"; : > "$WORK/serve.argv"
}
entries() { ls "$ROOT/entries" 2>/dev/null | wc -l | tr -d ' '; }
printf '# Doc one\n\nhi\n' > "$WORK/a.md"
printf '# Doc two\n\nhi\n' > "$WORK/b.md"

# --- 1. not the operator → http-direct -------------------------------------
reset_state; echo operator > "$WORK/serve.mode"
out="$(share "$WORK/a.md")"; rc=$?
[ "$rc" = 0 ] || fail "1: a refused serve must fall back, not fail (rc=$rc)" "$out"
PORT="$(cat "$ROOT/server.port" 2>/dev/null)"
has "READY http://box.tailnet.ts.net:$PORT/d/" "$out" "1: READY must be the http-direct URL on the server port"
has "plain http inside the tailnet" "$out" "1: the READY line must say it is plain http inside the tailnet"
lacks "HTTPS Certificates" "$out" "1: a not-operator refusal must NOT print the cert hint"
ok [ "$(cat "$ROOT/mode")" = http-direct ]
nofile "$ROOT/https.port" "1: http-direct must not leave an https.port"
url="$(printf '%s\n' "$out" | sed -n 's/^READY \(http:[^ ]*\).*/\1/p')"
path="/${url#http://*/}"
code="$(python3 -c 'import sys,urllib.request;print(urllib.request.urlopen("http://127.0.0.1:"+sys.argv[1]+sys.argv[2]).status)' "$PORT" "$path" 2>&1)"
has 200 "$code" "1: the http-direct server must serve the doc on the tailnet address"
out="$(share --list)"
has "Shared docs at: http://box.tailnet.ts.net:$PORT/" "$out" "1: --list must report the http-direct URL"
# a second share reuses the server + mode and never re-asks tailscale serve
: > "$WORK/serve.argv"
out="$(share "$WORK/b.md")"
has "READY http://box.tailnet.ts.net:$PORT/d/" "$out" "1b: a second share must keep the same http-direct URL"
ok [ ! -s "$WORK/serve.argv" ]
out="$(share --publish "$(ls "$ROOT/entries" | head -1 | sed "s/\.json$//")")"
has "not tailscale's operator" "$out" "1c: --publish in http-direct must say why public links are unavailable"

# --- 2. any other serve failure → cert hint + rollback ---------------------
reset_state; echo cert > "$WORK/serve.mode"
out="$(share "$WORK/a.md")"; rc=$?
[ "$rc" = 1 ] || fail "2: a cert failure must exit 1 (rc=$rc)" "$out"
has "HTTPS Certificates" "$out" "2: a non-operator failure must keep the cert hint"
has "certificates are not enabled" "$out" "2: the hint must quote what tailscale said"
ok [ "$(entries)" = 0 ]
has "nothing is being shared" "$(share --list)" "2: a failed share must leave --list empty"

# --- 3. serve works → https (unchanged) ------------------------------------
reset_state; echo ok > "$WORK/serve.mode"
out="$(share "$WORK/a.md")"
has "READY https://box.tailnet.ts.net" "$out" "3: a working serve must give the https URL"
lacks "http-direct" "$out" "3: https mode must not carry the http-direct note"
ok [ "$(cat "$ROOT/mode")" = https ]
has "http://127.0.0.1:$(cat "$ROOT/server.port")" "$(cat "$WORK/serve.argv")" "3: serve must front the loopback server"

# --- 4. start port held by a socket lsof cannot see → next port ------------
reset_state; echo operator > "$WORK/serve.mode"
python3 -c 'import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(1); time.sleep(120)' "$BASEPORT" &
PIDS+=($!)
for _ in $(seq 1 50); do python3 -c 'import socket,sys;s=socket.socket();sys.exit(s.connect_ex(("127.0.0.1",int(sys.argv[1]))))' "$BASEPORT" && break; sleep 0.1; done
out="$(share "$WORK/a.md")"; rc=$?
[ "$rc" = 0 ] || fail "4: a held start port must be skipped, not fatal (rc=$rc)" "$out"
PORT="$(cat "$ROOT/server.port" 2>/dev/null)"
ok [ "$PORT" != "$BASEPORT" ]
has "READY http://box.tailnet.ts.net:$PORT/d/" "$out" "4: READY must name the port actually bound"
ok kill -0 "$(cat "$ROOT/server.pid")"
lacks "Address already in use" "$(cat "$ROOT/server.log" 2>/dev/null)" "4: the server must never have died on EADDRINUSE"

# --- 5. the server cannot start at all → no half-written state ------------
reset_state; echo operator > "$WORK/serve.mode"
echo 192.0.2.1 > "$WORK/ts.ip"   # TEST-NET-1: not a local address, bind always refused
out="$(share "$WORK/a.md")"; rc=$?
[ "$rc" = 1 ] || fail "5: an unstartable server must exit 1 (rc=$rc)" "$out"
has "could not start server.py" "$out" "5: the failure must say the server could not start"
nofile "$ROOT/server.pid" "5: no server.pid may be left behind"
nofile "$ROOT/server.port" "5: no server.port may be left behind"
nofile "$ROOT/mode" "5: no mode may be recorded"
ok [ "$(entries)" = 0 ]
has "nothing is being shared" "$(share --list)" "5: --list must say nothing is shared"
echo 127.0.0.1 > "$WORK/ts.ip"

# --- 6. fleet-doctor's docprev row ------------------------------------------
mkdir -p "$WORK/skills/doc-preview" "$WORK/conf"; : > "$WORK/skills/doc-preview/SKILL.md"
doctor_row() {
  HOME="$WORK/home" PATH="$WORK/fake:$PATH" CLAUDE_SKILLS_DIR="$WORK/skills" FLEET_SKIP_GLOBAL_CONF=1 \
    FLEET_CONF_DIR="$WORK/conf" DOC_PREVIEW_PORT="$BASEPORT" sh "$BIN/fleet-doctor.sh" 2>/dev/null \
    | grep -aE '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+docprev' | head -1
}
me="$(id -un)"
printf '{"OperatorUser": "someone-else-%s"}' "$me" > "$WORK/prefs.json"
l="$(doctor_row)"
has "INFO" "$l" "6: a non-operator login must be INFO (a supported mode, not a fault)"
has "http-direct" "$l" "6: the INFO must name the fallback"
has "sudo tailscale serve --bg --https=" "$l" "6: the INFO must offer the one-time root command"
has "http://127.0.0.1:" "$l" "6: the command must front a loopback port"
printf '{"OperatorUser": "%s"}' "$me" > "$WORK/prefs.json"
has "PASS" "$(doctor_row)" "6b: the operator login must PASS"
if [ "$(id -u)" != 0 ]; then
  printf '{}' > "$WORK/prefs.json"
  CHECKS=$((CHECKS + 1)); [ -z "$(doctor_row)" ] || fail "6c: an unset operator must print no row" "$(doctor_row)"
fi

printf 'doc-preview-share-selftest OK (%d checks)\n' "$CHECKS"
