#!/usr/bin/env bash
# fleet-debug-selftest.sh — bin/fleet-debug (issue #2892, EPIC #2889 C3): the
# sender that needs none of fleet.
#
#   A  no Python CA: PATH whose only python3 dies on `import ssl` → report still
#      uploads through curl to a fake hub (the ticket, the fingerprint, the bundle
#      and the note arrive) and prints 已上传 + the short link; exit 0
#   B  no fleet-doctor.sh / bin/fleet beside it → the minimal collection (C1's
#      bundle, the doctor replaced by one line saying why)
#   C  the copy GET /debug serves (the kit spliced in as fleet_debug_script.go
#      does), run from stdin (`curl … | sh -s report`) with nothing installed
#   D  every exit code: 2 usage · 3 the ticket left in a log / the hub finds a
#      shape · 4 no ticket / 401 · 5 429 · 6 the hub down (package kept, path
#      printed) — and --again sends the kept package
#   E  --dry-run packs, lists, uploads nothing; ticket <code> keeps a ticket 0600
#      and refuses garbage; version
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/fdebug.XXXXXX")" || exit 2
T="$(cd "$T" && pwd -P)"
HUBPID=''
trap '[ -n "$HUBPID" ] && { kill "$HUBPID"; wait "$HUBPID"; } 2>/dev/null; rm -rf "$T"' EXIT
fails=0
ok()  { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
PY=$(command -v python3) || { echo "fleet-debug-selftest: the fake hub needs a python3"; exit 2; }
TICKET='fdt1.eyJpZCI6InQxIn0.c2lnbmF0dXJl'
HWID='HWID-SELFTEST-2892'

# --- a PATH with every tool but python, and one python3 that cannot verify TLS
mkdir -p "$T/nopy"
for d in /bin /usr/bin /usr/sbin /sbin; do
  for f in "$d"/*; do
    n=${f##*/}
    case $n in python*|pydoc*) continue ;; esac
    [ -e "$T/nopy/$n" ] || ln -s "$f" "$T/nopy/$n" 2>/dev/null
  done
done
cat > "$T/nopy/python3" <<'EOF'
#!/bin/sh
echo "ModuleNotFoundError: No module named '_ssl' (fake python3: import ssl fails)" >&2
exit 1
EOF
chmod +x "$T/nopy/python3"
NOPY="$T/nopy"

# --- the fake hub: answers by $T/hub.mode, keeps each request
cat > "$T/hub.py" <<'EOF'
import http.server, json, os, sys
T = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        with open(os.path.join(T, "req.hdr"), "w") as f:
            f.write("".join("%s: %s\n" % kv for kv in self.headers.items()))
        with open(os.path.join(T, "req.body"), "wb") as f:
            f.write(body)
        mode = open(os.path.join(T, "hub.mode")).read().strip()
        code, out, ct = {
            "ok": (200, json.dumps({"id": "abcd2345", "url": "http://hub.test/s/abcd2345",
                                    "open_url": "http://hub.test/s/abcd2345?k=x", "state": "uploaded", "again": False}), "application/json"),
            "again": (200, json.dumps({"id": "abcd2345", "url": "http://hub.test/s/abcd2345", "again": True}), "application/json"),
            "401": (401, "调试票已过期（2026-10-09 00:00 UTC 到期）。\n", "text/plain"),
            "429": (429, "这张调试票今天的上传次数用完了（每天 5 次）\n", "text/plain"),
            "400shape": (400, "logs/connect.log 里还有 github\n", "text/plain"),
            "500": (500, "boom\n", "text/plain"),
        }[mode]
        b = out.encode()
        self.send_response(code)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(T, "hub.port.tmp"), "w").write(str(s.server_address[1]))
os.rename(os.path.join(T, "hub.port.tmp"), os.path.join(T, "hub.port"))
s.serve_forever()
EOF
echo ok > "$T/hub.mode"
"$PY" "$T/hub.py" "$T" & HUBPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$T/hub.port" ] && break; sleep 0.2; done
[ -s "$T/hub.port" ] || { echo "fleet-debug-selftest: the fake hub did not start"; exit 2; }
HUB="http://127.0.0.1:$(cat "$T/hub.port")"
# a port nothing listens on: bind one, close it
DEAD=$("$PY" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

# a sandbox home: HOME, the conf dir with the ticket, the client's log cache
home() {  # home <name> [ticket]
  local h="$T/$1"
  mkdir -p "$h/conf" "$h/cache/logs" "$h/pkgs"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$h/conf/debug-ticket"
  printf '2026-10-10T00:00:00Z\trelay-end\tm5\trelay\t1000\tclosed\tby hub\n' > "$h/cache/logs/connect.log"
  printf '%s\n' "$h"
}
# fd <home> <script> args… — the sender, as the person's shell would run it, no python
fd() {
  local h=$1 s=$2; shift 2
  env -i HOME="$h" PATH="$NOPY" TMPDIR="$T" LANG=C.UTF-8 FLEET_CONF_DIR="$h/conf" \
    FLEET_SHELL_CACHE="$h/cache" FLEET_DEBUG_CACHE="$h/pkgs" FLEET_DEBUG_HWID="$HWID" \
    FLEET_HUB_URL="${FHUB-$HUB}" FLEET_BUNDLE_NET=0 FLEET_BUNDLE_DOCTOR_CMD="${FDOC-echo doctor-ran}" \
    sh "$s" "$@"
}
fp_expect=$(printf '%s|%s|%s' "$HWID" "$(id -un)" "$T/a/.claude/fleet" | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{ print $1 }')

# ---- A: no Python CA → curl uploads ----------------------------------------------
h=$(home a "$TICKET")
s0=$(date +%s)
out=$(fd "$h" "$BIN/fleet-debug" report --note '演练 一句话' 2>&1); rc=$?
dur=$(( $(date +%s) - s0 ))
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '已上传' && printf '%s\n' "$out" | grep -q 'http://hub.test/s/abcd2345'; then
  ok "A no python CA: uploaded, short link printed (${dur}s)"
else bad "A no python CA: rc=$rc"; printf '%s\n' "$out" | sed 's/^/      /'; fi
grep -q "^Authorization: FleetDebug $TICKET$" "$T/req.hdr" && ok "A the ticket rides Authorization: FleetDebug" || bad "A no ticket header: $(cat "$T/req.hdr")"
grep -q "^X-Fleet-FP: $fp_expect$" "$T/req.hdr" && ok "A the fingerprint is fleet-install.sh's" || bad "A fingerprint: $(grep -i fleet-fp "$T/req.hdr")"
# LC_ALL=C: the body is mostly gzip bytes, which a UTF-8 grep calls invalid
if LC_ALL=C grep -aq 'name="bundle"; filename=' "$T/req.body" && LC_ALL=C grep -aq 'name="note"' "$T/req.body" \
   && LC_ALL=C grep -aq '演练 一句话' "$T/req.body"; then
  ok "A multipart: bundle + note"
else bad "A multipart body lacks bundle/note"; fi
[ -z "$(ls "$h/pkgs" 2>/dev/null)" ] && ok "A a sent package is not kept" || bad "A kept after success: $(ls "$h/pkgs")"
[ "$dur" -le 60 ] && ok "A ≤ 60 s" || bad "A took ${dur}s"

# ---- B: no doctor beside it → minimal collection ---------------------------------
mkdir -p "$T/lone/bin" "$T/lone/conf"
cp "$BIN/fleet-debug" "$BIN/fleet-doctor-bundle.sh" "$BIN/fleet-redact.awk" "$T/lone/bin/"
cp "$ROOT/conf/secret-shapes.list" "$ROOT/conf/debug-collect.list" "$T/lone/conf/"
h=$(home b "$TICKET")
out=$(FDOC='' fd "$h" "$T/lone/bin/fleet-debug" report --dry-run 2>&1); rc=$?
pkg=$(ls "$h/pkgs"/*.tar.gz 2>/dev/null | head -n 1)
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '最小采集' && [ -n "$pkg" ] \
   && tar xzf "$pkg" -O bundle/doctor.txt 2>/dev/null | grep -q '体检没跑' \
   && tar tzf "$pkg" | grep -q 'bundle/logs/connect.log'; then
  ok "B no doctor: the minimal collection, the client's logs in it"
else bad "B minimal: rc=$rc"; printf '%s\n' "$out" | sed 's/^/      /'; fi

# ---- C: the spliced copy, from stdin, nothing installed -----------------------------
# the splice fleet_debug_script.go does (TestDebugScriptSplicesTheKit pins the Go side)
awk -v root="$ROOT" -v hub="$HUB" '
  index($0, "__FLEET_DEBUG_EMB__ ") == 1 { f = root "/" substr($0, 21); while ((getline l < f) > 0) print l; close(f); next }
  { gsub(/__FLEET_HUB_URL__/, hub); gsub(/__FLEET_DEBUG_VERSION__/, "selftest"); print }' "$BIN/fleet-debug" > "$T/served.sh"
h=$(home c "$TICKET")
echo ok > "$T/hub.mode"
out=$(env -i HOME="$h" PATH="$NOPY" TMPDIR="$T" LANG=C.UTF-8 FLEET_CONF_DIR="$h/conf" FLEET_SHELL_CACHE="$h/cache" \
        FLEET_DEBUG_CACHE="$h/pkgs" FLEET_DEBUG_HWID="$HWID" FLEET_BUNDLE_NET=0 sh -s report < "$T/served.sh" 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q 'http://hub.test/s/abcd2345' && printf '%s\n' "$out" | grep -q '最小采集'; then
  ok "C curl … | sh -s report: the spliced kit, the baked hub"
else bad "C spliced: rc=$rc"; printf '%s\n' "$out" | sed 's/^/      /'; fi
v=$(sh "$T/served.sh" version)
[ "$v" = 'fleet-debug selftest' ] && ok "C version stamped" || bad "C version: $v"
out=$(env -i HOME="$T/c-none" PATH="$NOPY" TMPDIR="$T" sh -s report < "$BIN/fleet-debug" 2>&1); rc=$?
[ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q '/debug | sh -s report' \
  && ok "C an unspliced copy alone refuses (exit 2) and says where the right one is" || bad "C unspliced: rc=$rc $out"

# ---- D: the exit codes ---------------------------------------------------------------
h=$(home d "$TICKET")
fd "$h" "$BIN/fleet-debug" report --bogus >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "D 2 usage" || bad "D usage rc=$rc"
# 3: the ticket itself in a log (no shape catches a bare fdt1.)
h=$(home d3 "$TICKET")
printf 'pasted %s by mistake\n' "$TICKET" >> "$h/cache/logs/connect.log"
out=$(fd "$h" "$BIN/fleet-debug" report 2>&1); rc=$?
[ "$rc" = 3 ] && printf '%s\n' "$out" | grep -q '脱敏后仍有命中' && [ -z "$(ls "$h/pkgs")" ] \
  && ok "D 3 the ticket in a log: nothing packed" || bad "D 3 ticket: rc=$rc $out"
h=$(home d3h "$TICKET"); echo 400shape > "$T/hub.mode"
out=$(fd "$h" "$BIN/fleet-debug" report 2>&1); rc=$?
[ "$rc" = 3 ] && printf '%s\n' "$out" | grep -q '脱敏后仍有命中' && ok "D 3 the hub finds a shape" || bad "D 3 hub: rc=$rc $out"
h=$(home d4); echo ok > "$T/hub.mode"
out=$(fd "$h" "$BIN/fleet-debug" report 2>&1); rc=$?
[ "$rc" = 4 ] && printf '%s\n' "$out" | grep -q '票无效' && printf '%s\n' "$out" | grep -q '包留在本机' \
  && ok "D 4 no ticket: kept, says how to get one" || bad "D 4 none: rc=$rc $out"
h=$(home d4x "$TICKET"); echo 401 > "$T/hub.mode"
out=$(fd "$h" "$BIN/fleet-debug" report 2>&1); rc=$?
[ "$rc" = 4 ] && printf '%s\n' "$out" | grep -q '票过期' && printf '%s\n' "$out" | grep -q 'fleet hub debug-ticket' \
  && ok "D 4 401: 票过期 + the re-issue command" || bad "D 4 401: rc=$rc $out"
h=$(home d5 "$TICKET"); echo 429 > "$T/hub.mode"
out=$(fd "$h" "$BIN/fleet-debug" report 2>&1); rc=$?
[ "$rc" = 5 ] && printf '%s\n' "$out" | grep -q '今天次数用完' && ok "D 5 429" || bad "D 5: rc=$rc $out"
h=$(home d6 "$TICKET")
out=$(FHUB="http://127.0.0.1:$DEAD" fd "$h" "$BIN/fleet-debug" report 2>&1); rc=$?
kept=$(ls "$h/pkgs"/*.tar.gz 2>/dev/null | head -n 1)
if [ "$rc" = 6 ] && printf '%s\n' "$out" | grep -q '入口连不上' && [ -n "$kept" ] \
   && printf '%s\n' "$out" | grep -qF "$kept" && printf '%s\n' "$out" | grep -q '发群里'; then
  ok "D 6 the hub down: the package kept, its path printed"
else bad "D 6: rc=$rc $out"; fi
[ -n "$kept" ] && [ "$(ls -l "$kept" | cut -c1-10)" = '-rw-------' ] && ok "D 6 the kept package is 0600" || bad "D 6 mode: $(ls -l "$kept" 2>&1)"
echo again > "$T/hub.mode"
out=$(FDOC='echo must-not-collect' fd "$h" "$BIN/fleet-debug" report --again 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '再送一次' && printf '%s\n' "$out" | grep -q '已上传' && [ -z "$(ls "$h/pkgs")" ] \
  && ok "D --again sends the kept package" || bad "D again: rc=$rc $out"
h=$(home d6b "$TICKET"); echo 500 > "$T/hub.mode"
fd "$h" "$BIN/fleet-debug" report >/dev/null 2>&1; rc=$?
[ "$rc" = 6 ] && [ -n "$(ls "$h/pkgs")" ] && ok "D 6 a hub that answers 500: kept" || bad "D 6 500: rc=$rc"

# ---- E: dry-run, ticket, version -----------------------------------------------------
h=$(home e "$TICKET"); rm -f "$T/req.hdr"
out=$(fd "$h" "$BIN/fleet-debug" report --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -f "$T/req.hdr" ] && printf '%s\n' "$out" | grep -q 'bundle/manifest.json' \
  && printf '%s\n' "$out" | grep -q '去掉了 [0-9]* 处' && ok "E --dry-run: listed + counted, nothing sent" || bad "E dry-run: rc=$rc $out"
h=$(home e2)
fd "$h" "$BIN/fleet-debug" ticket "fleet-debug ticket $TICKET" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$h/conf/debug-ticket")" = "$TICKET" ] && [ "$(ls -l "$h/conf/debug-ticket" | cut -c1-10)" = '-rw-------' ] \
  && ok "E ticket: the admin's line pasted whole, kept 0600" || bad "E ticket rc=$rc"
fd "$h" "$BIN/fleet-debug" ticket 'not-a-ticket' >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ "$(cat "$h/conf/debug-ticket")" = "$TICKET" ] && ok "E ticket garbage: 2, the old one kept" || bad "E garbage rc=$rc"
fd "$h" "$BIN/fleet-debug" version | grep -q '^fleet-debug ' && ok "E version" || bad "E version"

[ "$fails" = 0 ] && { echo "fleet-debug-selftest: PASS"; exit 0; }
echo "fleet-debug-selftest: $fails FAIL"; exit 1
