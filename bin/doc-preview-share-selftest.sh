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
#   • TUNNEL       (issue #1151) --tunnel → a fake `cloudflared` quick tunnel fronts
#                  the loopback server: READY is the trycloudflare URL + the PUBLIC
#                  note, mode = tunnel (sticky), the server is in `public` mode
#                  (doc header + index source paths stripped, /_ctl 404), a second
#                  share reuses the one tunnel, --unpublish refuses; a live tailnet
#                  share is never turned public; a tunnel that never reports a URL
#                  → exit 1 with nothing left behind; tailscale down → the error
#                  names --tunnel.
#   • LOCAL        (issue #1379) --local with tailscale DOWN → READY is
#                  http://127.0.0.1:<port>/d/<id>/, server on loopback, mode = local,
#                  tailscale never asked; a later plain share upgrades it to https on
#                  the SAME server; --local beside https keeps https and prints the
#                  loopback URL; beside http-direct refuses; --local --tunnel refuses;
#                  --open hands the doc URL to fleet-open (FLEET_OPEN_BIN stub) and
#                  prints OPEN <its result>. Sections 1-7 run with no --local and are
#                  the "behaviour unchanged" half.
#   • NO-DNS       (issue #1500) server.py comes up and serves with EVERY reverse
#                  lookup raising: http.server's server_bind() reverse-resolves the
#                  bind address between bind() and listen(), and on a GitHub
#                  macos-latest runner that blocked 30s+ — the port sat bound but
#                  never accepting, share.sh gave up on five ports (~170s), and this
#                  test was red on every macOS run from the day it landed.
#   • CODES        (issue #1153) every link carries a 128-bit random code: `/`, `/d/`,
#                  no / a wrong / an EXPIRED code → 404, the right one → 200; the index
#                  is /i/<its own code>/; another login (a second HOME) holding its own
#                  codes gets 404 here; --refresh keeps the link; --ttl / 0 = never; a
#                  pre-#1153 id lives 7 days from its timestamp; a server.py from an older
#                  version is restarted on the SAME port — by a share, or by --upgrade
#                  with no share (issue #2415), which also ends an untracked server.py;
#                  --health's server_stale and the doctor's docprev WARN report one.
#   • SERVE LEAK   a restarted server re-points this login's one tailnet route instead of
#                  opening another; routes stacked on our backend or left on a dead port
#                  we once served are dropped, another login's routes are not.
#   • PUBLIC       --publish mounts /p/<its own code>/ (never the doc's), with an expiry;
#                  an expired public link 404s and is taken down; --unpublish exits 1 and
#                  never prints OFF when tailscale fails, lies, or cannot be asked; with no
#                  CLI on PATH the App's own binary is called directly (never a symlink).
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
  [ -f "$ROOT/tunnel.pid" ] && kill "$(cat "$ROOT/tunnel.pid")" 2>/dev/null
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
# `serve --bg` behaves per $WORK/serve.mode: operator | cert | ok, and keeps the routes it
# set in $WORK/ts.json (`serve status --json` reads them back, `serve --https=N off` drops
# one). `funnel` keeps its /p/ mounts there too: $WORK/funnel.mode fail → --bg refused;
# $WORK/off.mode fail (exit 1, mount stays) | lie (exit 0, mount stays); $WORK/fstat.fail
# → `funnel status` errors. Invoked through a symlink while $WORK/app.only exists → the
# App binary's bundleIdentifier crash (issue #1153).
cat > "$WORK/fake/tailscale" <<PYF
#!/usr/bin/env python3
import json, os, sys
W = "$WORK"
def rd(n, d=""):
    try: return open(os.path.join(W, n)).read().strip()
    except OSError: return d
if os.path.exists(os.path.join(W, "app.only")) and os.path.islink(sys.argv[0]):
    sys.stderr.write("Tailscale: bundleIdentifier is nil — crash\n"); sys.exit(134)
st = json.loads(rd("ts.json", "{}") or "{}"); st.setdefault("web", {}); st.setdefault("mounts", {})
def save(): open(os.path.join(W, "ts.json"), "w").write(json.dumps(st))
a = sys.argv[1:]
opt = {x.split("=", 1)[0]: (x.split("=", 1)[1] if "=" in x else "") for x in a if x.startswith("--")}
pos = [x for x in a if not x.startswith("--")]
cmd = " ".join(pos[:2])
if cmd == "status" and "--json" in opt: print(json.dumps({"Self": {"DNSName": "box.tailnet.ts.net."}}))
elif pos[:1] == ["status"]: sys.exit(1 if os.path.exists(os.path.join(W, "ts.down")) else 0)
elif pos[:1] == ["ip"]: print(rd("ts.ip"))
elif cmd == "serve status":
    if "--json" in opt:
        print(json.dumps({"TCP": {p: {"HTTPS": True} for p in st["web"]},
                          "Web": {"box.tailnet.ts.net:" + p: {"Handlers": {"/": {"Proxy": u}}} for p, u in st["web"].items()}}))
elif cmd == "serve reset": st["web"] = {}; save()
elif pos[:1] == ["serve"] and pos[-1:] == ["off"]: st["web"].pop(opt.get("--https", ""), None); save()
elif pos[:1] == ["serve"] and "--bg" in opt:
    open(os.path.join(W, "serve.argv"), "a").write(" ".join(a) + "\n")
    m = rd("serve.mode")
    if m == "operator":
        sys.stderr.write("Use 'sudo tailscale %s'.\nTo not require root, use 'sudo tailscale set --operator=\$USER' once.\n" % " ".join(a)); sys.exit(1)
    if m == "cert": sys.stderr.write("error: certificates are not enabled for this tailnet\n"); sys.exit(1)
    st["web"][opt["--https"]] = pos[-1]; save()
elif cmd == "funnel status":
    if os.path.exists(os.path.join(W, "fstat.fail")): sys.stderr.write("funnel status: daemon gone\n"); sys.exit(1)
    for path, u in sorted(st["mounts"].items()): print("|-- %s proxy %s" % (path, u))
elif pos[:1] == ["funnel"] and pos[-1:] == ["off"]:
    m = rd("off.mode")
    if m == "fail": sys.exit(1)
    if m != "lie": st["mounts"].pop(opt.get("--set-path", ""), None); save()
elif pos[:1] == ["funnel"] and "--bg" in opt:
    if rd("funnel.mode") == "fail": sys.exit(1)
    st["mounts"][opt["--set-path"]] = pos[-1]; save()
elif cmd == "debug prefs": print(rd("prefs.json"))
PYF
# blind lsof: sees no listener at all — what a port held by ANOTHER login looks like.
printf '#!/bin/sh\nexit 1\n' > "$WORK/fake/lsof"
# fake cloudflared: logs the quick-tunnel banner (mode ok) or nothing (mode never), then idles.
cat > "$WORK/fake/cloudflared" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/cf.argv"
if [ "\$(cat "$WORK/cf.mode")" = ok ]; then
  echo 'INF |  Your quick Tunnel has been created! Visit it at:' >&2
  echo 'INF |  https://brave-fox-tunnel.trycloudflare.com  |' >&2
fi
exec sleep 120
SH
chmod +x "$WORK/fake/tailscale" "$WORK/fake/lsof" "$WORK/fake/cloudflared"
echo 127.0.0.1 > "$WORK/ts.ip"

# a free start port for this run (bind-probed), so a live doc-preview can't collide
BASEPORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
share() { HOME="$WORK/home" PATH="$WORK/fake:$PATH" DOC_PREVIEW_PORT="$BASEPORT" DOC_PREVIEW_SESSION=t "$SH" "$@" 2>&1; }
reset_state() {
  [ -f "$ROOT/server.pid" ] && kill "$(cat "$ROOT/server.pid")" 2>/dev/null
  [ -f "$ROOT/tunnel.pid" ] && kill "$(cat "$ROOT/tunnel.pid")" 2>/dev/null
  rm -rf "$ROOT"; : > "$WORK/serve.argv"; : > "$WORK/cf.argv"; rm -f "$WORK/ts.json"
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

# --- 7. --tunnel → public cloudflared quick tunnel (issue #1151) ------------
get() { python3 -c 'import sys,urllib.request,urllib.error
try:
  r=urllib.request.urlopen("http://127.0.0.1:"+sys.argv[1]+sys.argv[2]); print(r.status); print(r.read().decode())
except urllib.error.HTTPError as e: print(e.code)' "$1" "$2" 2>&1; }
reset_state; echo ok > "$WORK/cf.mode"; touch "$WORK/ts.down"
out="$(share "$WORK/a.md")"; rc=$?
[ "$rc" = 1 ] || fail "7: tailscale down without --tunnel must still fail (rc=$rc)" "$out"
has "share.sh --tunnel" "$out" "7: tailscale down must point at --tunnel"
out="$(share --tunnel "$WORK/a.md")"; rc=$?
[ "$rc" = 0 ] || fail "7: --tunnel must share without a tailnet (rc=$rc)" "$out"
PORT="$(cat "$ROOT/server.port" 2>/dev/null)"
has "READY https://brave-fox-tunnel.trycloudflare.com/d/" "$out" "7: READY must be the trycloudflare URL"
has "PUBLIC" "$out" "7: the READY line must say the tunnel is public"
ok [ "$(cat "$ROOT/mode")" = tunnel ]
has "--url http://127.0.0.1:$PORT" "$(cat "$WORK/cf.argv")" "7: cloudflared must front the loopback server"
path="/${out#*trycloudflare.com/}"; path="${path%% *}"; path="${path%%$'\n'*}"
page="$(get "$PORT" "$path")"
has 200 "$page" "7: the tunnel server must serve the doc"
lacks 'class="hdr"' "$page" "7: a public doc page must have its header stripped"
lacks "$WORK" "$page" "7: a public doc page must not carry the source path"
has 404 "$(get "$PORT" /)" "7: the public root is 404 — the index needs its code (issue #1153)"
idx="$(get "$PORT" "/i/$(cat "$ROOT/index.token")/")"
has "Doc one" "$idx" "7: the public index still lists the doc"
lacks 'class="src"' "$idx" "7: the public index must drop source paths"
has 404 "$(get "$PORT" "/_ctl/status?id=${path#/d/}")" "7: /_ctl must be 404 on a public server"
rm -f "$WORK/ts.down"
: > "$WORK/cf.argv"
out="$(share "$WORK/b.md")"
has "READY https://brave-fox-tunnel.trycloudflare.com/d/" "$out" "7b: tunnel mode is sticky and reuses the URL"
ok [ ! -s "$WORK/cf.argv" ]
ok [ ! -s "$WORK/serve.argv" ]
id1="$(ls "$ROOT/entries" | head -1 | sed "s/\.json$//")"
has '"public":true' "$(share --pubstatus "$id1" --json)" "7c: every tunnel doc reports public"
has "--remove it instead" "$(share --unpublish "$id1")" "7c: --unpublish must refuse in tunnel mode"
has "Shared docs at: https://brave-fox-tunnel.trycloudflare.com/" "$(share --list)" "7c: --list reports the tunnel URL"
# a live tailnet share is never silently made public
reset_state; echo ok > "$WORK/serve.mode"
share "$WORK/a.md" >/dev/null
out="$(share --tunnel "$WORK/b.md")"; rc=$?
[ "$rc" = 1 ] || fail "7d: --tunnel over a live tailnet share must refuse (rc=$rc)" "$out"
has "--stop first" "$out" "7d: the refusal must say how to switch"
ok [ "$(cat "$ROOT/mode")" = https ]
ok [ ! -s "$WORK/cf.argv" ]
# the tunnel never reports a URL → nothing left behind
reset_state; echo never > "$WORK/cf.mode"
out="$(DOC_PREVIEW_TUNNEL_WAIT=1 share --tunnel "$WORK/a.md")"; rc=$?
[ "$rc" = 1 ] || fail "7e: a tunnel with no URL must exit 1 (rc=$rc)" "$out"
has "did not come up" "$out" "7e: the failure must say the tunnel did not come up"
nofile "$ROOT/tunnel.pid" "7e: no tunnel.pid may be left behind"
nofile "$ROOT/server.pid" "7e: no server.pid may be left behind"
nofile "$ROOT/mode" "7e: no mode may be recorded"
ok [ "$(entries)" = 0 ]

# --- 8. --local: loopback only, no tailscale (issue #1379) -------------------
reset_state; echo ok > "$WORK/serve.mode"; touch "$WORK/ts.down"
out="$(share --local "$WORK/a.md")"; rc=$?
[ "$rc" = 0 ] || fail "8: --local must share with tailscale down (rc=$rc)" "$out"
PORT="$(cat "$ROOT/server.port" 2>/dev/null)"
has "READY http://127.0.0.1:$PORT/d/" "$out" "8: READY must be the loopback URL"
has "fleet-open" "$out" "8: the READY note must point at fleet-open"
ok [ "$(cat "$ROOT/mode")" = local ]
ok [ ! -s "$WORK/serve.argv" ]
path="/${out#*127.0.0.1:$PORT/}"; path="${path%% *}"; path="${path%%$'\n'*}"
has 200 "$(get "$PORT" "$path")" "8: the loopback server must serve the doc"
has "Shared docs at: http://127.0.0.1:$PORT/" "$(share --list)" "8: --list reports the loopback URL"
out="$(share --local --tunnel "$WORK/b.md")"; rc=$?
[ "$rc" = 1 ] || fail "8a: --local --tunnel must refuse (rc=$rc)" "$out"
# a later plain share → https on the same loopback server
rm -f "$WORK/ts.down"
out="$(share "$WORK/b.md")"
has "READY https://box.tailnet.ts.net" "$out" "8b: a plain share after --local must give https"
ok [ "$(cat "$ROOT/mode")" = https ]
ok [ "$(cat "$ROOT/server.port")" = "$PORT" ]
has "http://127.0.0.1:$PORT" "$(cat "$WORK/serve.argv")" "8b: serve must front the same loopback server"
# --local beside https: mode stays https, the line is the loopback URL, serve untouched
: > "$WORK/serve.argv"
out="$(share --local "$WORK/a.md")"
has "READY http://127.0.0.1:$PORT/d/" "$out" "8c: --local beside https must print the loopback URL"
ok [ "$(cat "$ROOT/mode")" = https ]
ok [ ! -s "$WORK/serve.argv" ]
# --open → fleet-open gets the doc URL; its last line comes back as OPEN …
printf '#!/bin/sh\nprintf "%%s\\n" "$1" > "%s/fo.argv"\necho "fleet-open: chatter"\necho sent:iterm2\n' "$WORK" > "$WORK/fake/fleet-open"
chmod +x "$WORK/fake/fleet-open"
out="$(FLEET_OPEN_BIN="$WORK/fake/fleet-open" share --open --local "$WORK/a.md")"
has "OPEN sent:iterm2" "$out" "8d: --open must print fleet-open's result"
has "http://127.0.0.1:$PORT/d/" "$(cat "$WORK/fo.argv")" "8d: --open must hand fleet-open the doc URL"
# beside http-direct: no loopback server to point at → refuse
reset_state; echo operator > "$WORK/serve.mode"
share "$WORK/a.md" >/dev/null
out="$(share --local "$WORK/b.md")"; rc=$?
[ "$rc" = 1 ] || fail "8e: --local beside http-direct must refuse (rc=$rc)" "$out"
has "http-direct" "$out" "8e: the refusal must say why"

# --- 9. server.py must come up with reverse DNS unavailable (issue #1500) -----
# Run server.py itself with socket.getfqdn / gethostbyaddr / getnameinfo raising: a
# server that reverse-resolves its bind address at startup dies here with the
# traceback in its log, instead of silently sitting bound-but-not-listening on a
# runner whose resolver is slow.
P9="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
mkdir -p "$WORK/serve9"; echo '<p>no-dns ok</p>' > "$WORK/serve9/index.html"; echo 0123456789abcdef0123456789abcdef > "$WORK/index.token"
python3 - "$BIN/../skills/doc-preview/server.py" "$P9" "$WORK/serve9" "$BIN/../skills/doc-preview" > "$WORK/srv9.log" 2>&1 <<'PY' &
import runpy, socket, sys
def boom(*a, **k): raise RuntimeError("reverse DNS lookup at startup: %r" % (a,))
socket.getfqdn = socket.gethostbyaddr = socket.getnameinfo = boom
sys.argv = sys.argv[1:]            # python3 - <server.py> <args…> → argv[0] = server.py
runpy.run_path(sys.argv[0], run_name="__main__")
PY
pid9=$!; PIDS+=("$pid9"); up9=0
for _ in $(seq 1 100); do
  kill -0 "$pid9" 2>/dev/null || break
  python3 -c 'import socket,sys;s=socket.socket();s.settimeout(0.5);sys.exit(s.connect_ex(("127.0.0.1",int(sys.argv[1]))))' "$P9" 2>/dev/null && { up9=1; break; }
  sleep 0.1
done
CHECKS=$((CHECKS + 1)); [ "$up9" = 1 ] || fail "9: server.py must come up with reverse DNS unavailable (it reverse-resolves at startup, or never reached listen())" "$(cat "$WORK/srv9.log" 2>/dev/null)"
has 200 "$(get "$P9" /i/0123456789abcdef0123456789abcdef/)" "9: the no-DNS server must serve"
has "listening on http://127.0.0.1:$P9/" "$(cat "$WORK/srv9.log")" "9: server.py must log the address it is accepting on"
lacks "reverse DNS lookup" "$(cat "$WORK/srv9.log")" "9: server.py must never have called a reverse lookup"
kill "$pid9" 2>/dev/null

# --- 10. codes, expiry, isolation, serve leak, honest unpublish (issue #1153) ----
code() { python3 -c 'import sys,urllib.request,urllib.error
class N(urllib.request.HTTPRedirectHandler):
  def redirect_request(self,*a): return None
o=urllib.request.build_opener(N)
try: print(o.open("http://127.0.0.1:"+sys.argv[1]+sys.argv[2]).status)
except urllib.error.HTTPError as e: print(e.code)
except Exception as e: print("ERR",e)' "$1" "$2" 2>&1; }
tset() { python3 "$BIN/../skills/doc-preview/server.py" --tool set "$ROOT" "$@"; }
reset_state; echo ok > "$WORK/serve.mode"; : > "$WORK/funnel.mode"; : > "$WORK/off.mode"; rm -f "$WORK/fstat.fail"
out="$(share "$WORK/a.md")"; rc=$?
[ "$rc" = 0 ] || fail "10: an https share must work (rc=$rc)" "$out"
PORT="$(cat "$ROOT/server.port")"
doc="$(printf '%s\n' "$out" | sed -n 's#^READY https://[^/]*\(/d/[^ ]*\).*#\1#p')"
id="${doc#/d/}"; id="${id%/}"
CHECKS=$((CHECKS + 1)); printf '%s\n' "$id" | grep -Eqx '[0-9a-f]{32}' || fail "10a: a doc link must carry a 128-bit random code, got '$doc'" "$out"
IDX="$(cat "$ROOT/index.token")"
CHECKS=$((CHECKS + 1)); printf '%s\n' "$IDX" | grep -Eqx '[0-9a-f]{32}' || fail "10a: the index code must be 128 random bits"
has "INDEX https://box.tailnet.ts.net/i/$IDX/" "$out" "10a: INDEX must be the coded index URL"
has "TTL expires in 7d" "$out" "10a: the default TTL is 7 days and the share says so"
has 200 "$(code "$PORT" "$doc")" "10a: the right code → 200"
has 404 "$(code "$PORT" /)" "10a: the root → 404 (no code, no listing)"
has 404 "$(code "$PORT" /d/)" "10a: /d/ → 404 (never a directory listing of codes)"
has 404 "$(code "$PORT" /d/0123456789abcdef0123456789abcdef/)" "10a: a wrong code → 404"
has 404 "$(code "$PORT" /index.html)" "10a: the index file by name → 404"
has 404 "$(code "$PORT" /i/0123456789abcdef0123456789abcdef/)" "10a: a wrong index code → 404"
has 200 "$(code "$PORT" "/i/$IDX/")" "10a: the right index code → 200"
has "/i/$IDX/" "$(get "$PORT" "$doc")" "10a: the doc's 全部文档 link carries the index code"
has 404 "$(code "$PORT" /entries/)" "10a: the state dir is never served"
exp="$(python3 "$BIN/../skills/doc-preview/server.py" --tool get "$ROOT" "$id" expires)"
now="$(date +%s)"
CHECKS=$((CHECKS + 1)); [ "$exp" -gt $((now + 604000)) ] && [ "$exp" -le $((now + 604800)) ] || fail "10b: the entry must expire 7d out (expires=$exp now=$now)"
# expired → 404 at once, and pruned by the next run
tset "$id" "expires=$((now - 1))"
has 404 "$(code "$PORT" "$doc")" "10b: an expired code → 404 (server-side, before any prune)"
lst="$(share --list)"
lacks "$id" "$lst" "10b: --list prunes an expired doc"
nofile "$ROOT/entries/$id.json" "10b: the expired entry must be gone"
# --ttl 0 = never, --ttl 2h
out="$(share --ttl 0 "$WORK/a.md")"; id0="$(printf '%s\n' "$out" | sed -n 's#^READY [^ ]*/d/\([0-9a-f]*\)/.*#\1#p')"
has "never expires" "$out" "10c: --ttl 0 must say the link never expires"
has "永久" "$(share --list)" "10c: --list shows a never-expiring doc as 永久"
out="$(share --ttl 2h "$WORK/b.md")"; id2="$(printf '%s\n' "$out" | sed -n 's#^READY [^ ]*/d/\([0-9a-f]*\)/.*#\1#p')"
e2="$(python3 "$BIN/../skills/doc-preview/server.py" --tool get "$ROOT" "$id2" expires)"
CHECKS=$((CHECKS + 1)); [ "$e2" -gt $((now + 7000)) ] && [ "$e2" -le $(( $(date +%s) + 7200 )) ] || fail "10c: --ttl 2h → expires 2h out (got $e2)"
has "· 剩 " "$(share --list)" "10c: --list shows the time left"
out="$(share --ttl soon "$WORK/a.md")"; rc=$?
[ "$rc" = 1 ] || fail "10c: a bad --ttl must refuse (rc=$rc)" "$out"
# --refresh keeps every link
share --refresh >/dev/null
has 200 "$(code "$PORT" "/d/$id0/")" "10d: --refresh keeps the link working"
has 200 "$(code "$PORT" "/d/$id2/")" "10d: --refresh keeps every link"
# another login: its own HOME, its own codes — none of them opens anything here
HOME2="$WORK/home2"; mkdir -p "$HOME2"
out2="$(HOME="$HOME2" PATH="$WORK/fake:$PATH" DOC_PREVIEW_PORT="$((PORT + 1))" DOC_PREVIEW_SESSION=u "$SH" --local "$WORK/a.md" 2>&1)"
doc2="$(printf '%s\n' "$out2" | sed -n 's#^READY http://127.0.0.1:[0-9]*\(/d/[^ ]*\).*#\1#p')"
IDX2="$(cat "$HOME2/.cache/claude-doc-preview/index.token")"
has 404 "$(code "$PORT" "$doc2")" "10e: another login's doc code → 404 on this login's port"
has 404 "$(code "$PORT" "/i/$IDX2/")" "10e: another login's index code → 404 on this login's port"
has 404 "$(code "$PORT" /)" "10e: another login with no code → 404"
CHECKS=$((CHECKS + 1)); [ "$(ls -ld "$ROOT" | cut -c1-10)" = drwx------ ] || fail "10e: the state dir must be 0700 ($(ls -ld "$ROOT"))"
CHECKS=$((CHECKS + 1)); [ "$(ls -l "$ROOT/index.token" | cut -c1-10)" = -rw------- ] || fail "10e: index.token must be 0600"
kill "$(cat "$HOME2/.cache/claude-doc-preview/server.pid")" 2>/dev/null
# a pre-#1153 doc: its old link lives 7 days from its timestamp, then 404s
for L in "$(date +%Y%m%d-%H%M%S)-11" "20200101-120000-22"; do
  mkdir -p "$ROOT/serve/d/$L"; echo '<p>old</p>' > "$ROOT/serve/d/$L/index.html"
  printf '{"id":"%s","title":"old","href":"/d/%s/","src":"x","added":"then"}' "$L" "$L" > "$ROOT/entries/$L.json"
done
L1=""; for j in "$ROOT"/entries/*-11.json; do L1="$(basename "$j" .json)"; done
has 200 "$(code "$PORT" "/d/$L1/")" "10f: a fresh pre-#1153 link keeps working"
has 404 "$(code "$PORT" /d/20200101-120000-22/)" "10f: a pre-#1153 link older than 7 days → 404"
share --list >/dev/null
nofile "$ROOT/entries/20200101-120000-22.json" "10f: a stale pre-#1153 doc is pruned"
# a server.py from an older version is replaced on the SAME port
pid0="$(cat "$ROOT/server.pid")"; echo stale > "$ROOT/server.ver"
share "$WORK/b.md" >/dev/null
CHECKS=$((CHECKS + 1)); [ "$(cat "$ROOT/server.pid")" != "$pid0" ] || fail "10g: an old-version server must be restarted"
ok [ "$(cat "$ROOT/server.port")" = "$PORT" ]
CHECKS=$((CHECKS + 1)); ! kill -0 "$pid0" 2>/dev/null || fail "10g: the old server must be gone"
# --upgrade (issue #2415): the same restart WITHOUT a share — install-apply runs it, so a
# server from before an install never outlives it; an untracked copy is ended too.
CHECKS=$((CHECKS + 1)); [ "$(ps -o pgid= -p "$(cat "$ROOT/server.pid")" | tr -d ' ')" = "$(cat "$ROOT/server.pid")" ] \
  || fail "10g2: server.py runs in its own session (setsid), so a launchd job's exit cannot take it"
has "server_stale=0" "$(share --health)" "10g2: a current server is not stale"
out="$(share --upgrade --check)"; rc=$?
[ "$rc" = 0 ] || fail "10g2: --upgrade --check on a current server → 0 (rc=$rc)" "$out"
pid1="$(cat "$ROOT/server.pid")"; echo stale > "$ROOT/server.ver"
has "server_stale=1" "$(share --health)" "10g2: --health counts an old-version server"
out="$(share --upgrade --check)"; rc=$?
[ "$rc" = 1 ] || fail "10g2: --upgrade --check on an old server → 1 (rc=$rc)" "$out"
has "older copy" "$out" "10g2: --check names it"
ok [ "$(cat "$ROOT/server.pid")" = "$pid1" ]
mkdir -p "$WORK/skills10g" "$WORK/conf"; ln -s "$(dirname "$SH")" "$WORK/skills10g/doc-preview"
l="$(HOME="$WORK/home" PATH="$WORK/fake:$PATH" CLAUDE_SKILLS_DIR="$WORK/skills10g" FLEET_SKIP_GLOBAL_CONF=1 \
    FLEET_CONF_DIR="$WORK/conf" sh "$BIN/fleet-doctor.sh" 2>/dev/null | grep -a 'docprev' | grep -a 'older than the installed')"
has "WARN" "$l" "10g2: doctor WARNs on a server older than the installed copy"
has "share.sh --upgrade" "$l" "10g2: and names the fix"
out="$(share --upgrade)"; rc=$?
[ "$rc" = 0 ] || fail "10g2: --upgrade must restart an old server (rc=$rc)" "$out"
has "restarted server.py on :$PORT" "$out" "10g2: on the SAME port"
CHECKS=$((CHECKS + 1)); ! kill -0 "$pid1" 2>/dev/null || fail "10g2: the old server must be gone"
ok [ "$(cat "$ROOT/server.port")" = "$PORT" ]
has 200 "$(code "$PORT" "/d/$id0/")" "10g2: links keep working after --upgrade"
has 404 "$(code "$PORT" /)" "10g2: and / is still 404"
has "current" "$(share --upgrade)" "10g2: a second --upgrade changes nothing"
# an untracked server.py of this install + this login (a lost pid file) is ended
SP="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
SKD="$(cd "$(dirname "$SH")" && pwd)"   # the path share.sh names its own server.py by
python3 "$SKD/server.py" "$SP" "$ROOT/serve" "$SKD" 127.0.0.1 >/dev/null 2>&1 &
spid=$!; PIDS+=("$spid")
for _ in $(seq 1 50); do code "$SP" / | grep -q 404 && break; sleep 0.1; done
has "server_stale=1" "$(share --health)" "10g2: --health counts an untracked server"
out="$(share --upgrade)"
has "untracked server.py pid $spid" "$out" "10g2: --upgrade ends the untracked one"
for _ in $(seq 1 30); do kill -0 "$spid" 2>/dev/null || break; sleep 0.1; done
CHECKS=$((CHECKS + 1)); ! kill -0 "$spid" 2>/dev/null || fail "10g2: the untracked server must be gone"
CHECKS=$((CHECKS + 1)); kill -0 "$(cat "$ROOT/server.pid")" 2>/dev/null || fail "10g2: and ours must still run"

# serve leak: the restart above re-used its route; now a restart on ANOTHER port
routes() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(" ".join(p+">"+u.rsplit(":",1)[1] for p,u in sorted(d["web"].items())))' "$WORK/ts.json"; }
HP="$(cat "$ROOT/https.port")"
ok [ "$(routes)" = "$HP>$PORT" ]
spid="$(cat "$ROOT/server.pid")"; kill "$spid"
for _ in $(seq 1 50); do kill -0 "$spid" 2>/dev/null || break; sleep 0.1; done
# the restarted server lands on ANOTHER loopback port (its first free one from here)
NEWBASE="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
out="$(HOME="$WORK/home" PATH="$WORK/fake:$PATH" DOC_PREVIEW_PORT="$NEWBASE" DOC_PREVIEW_SESSION=t "$SH" "$WORK/a.md" 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "10h: a share after a restart must work (rc=$rc)" "$out"
NP="$(cat "$ROOT/server.port")"
ok [ "$NP" != "$PORT" ]
ok [ "$(cat "$ROOT/https.port")" = "$HP" ]
has "READY https://box.tailnet.ts.net/d/" "$out" "10h: the URL keeps its tailnet port"
CHECKS=$((CHECKS + 1)); [ "$(routes)" = "$HP>$NP" ] || fail "10h: a restarted server re-points this login's route, never opens another" "$(routes)"
PORT="$NP"
# stacked + dead routes: two more onto our server, one on a dead port we once served,
# one on a dead port that was never ours (another login's) — only ours may go
DEADP="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
OTHERP="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
echo "$DEADP" >> "$ROOT/served.ports"
python3 - "$WORK/ts.json" "$PORT" "$DEADP" "$OTHERP" <<'PY2'
import json, sys
f, p, dead, other = sys.argv[1:]
d = json.load(open(f))
d["web"].update({"8444": "http://127.0.0.1:" + p, "8445": "http://127.0.0.1:" + p,
                 "8446": "http://127.0.0.1:" + dead, "8447": "http://127.0.0.1:" + other})
json.dump(d, open(f, "w"))
PY2
has "serve_dup=2 serve_dead=2" "$(share --health)" "10h: --health counts stacked and dead routes"
out="$(share "$WORK/b.md")"
CHECKS=$((CHECKS + 1)); [ "$(routes)" = "$HP>$PORT 8447>$OTHERP" ] || fail "10h: stacked/dead routes of this login dropped, another login's kept, no new port" "$(routes)"

# public: its own code, an expiry, honest down
id=""; for j in "$ROOT"/entries/*.json; do j="$(basename "$j" .json)"; case "$j" in *-*) ;; *) id="$j"; break ;; esac; done
out="$(share --publish "$id")"; rc=$?
[ "$rc" = 0 ] || fail "10i: --publish must work (rc=$rc)" "$out"
pc="$(printf '%s\n' "$out" | sed -n 's#^public ON: *https://[^/]*/p/\([0-9a-f]*\)/$#\1#p')"
CHECKS=$((CHECKS + 1)); printf '%s\n' "$pc" | grep -Eqx '[0-9a-f]{32}' || fail "10i: a public link must be /p/<128-bit code>/" "$out"
CHECKS=$((CHECKS + 1)); [ "$pc" != "$id" ] || fail "10i: the public code must not be the doc's code"
has "\"/p/$pc\": \"http://127.0.0.1:$PORT/_pub/$pc/\"" "$(cat "$WORK/ts.json")" "10i: funnel mounts /p/<code> onto /_pub/<code>/"
pg="$(get "$PORT" "/_pub/$pc/")"
has 200 "$pg" "10i: the public view serves"
lacks 'class="hdr"' "$pg" "10i: the public view strips the header"
has 404 "$(code "$PORT" "/_pub/$id/")" "10i: the doc's own code is not a public code"
pe="$(python3 "$BIN/../skills/doc-preview/server.py" --tool get "$ROOT" "$id" pub_expires)"
CHECKS=$((CHECKS + 1)); [ "$pe" -gt $(( $(date +%s) + 604000 )) ] || fail "10i: a public link expires 7d out by default (pub_expires=$pe)"
has "public=1 " "$(share --health)" "10i: --health counts the public link"
# expired public link → 404, and the next run takes the mount down
tset "$id" "pub_expires=$(( $(date +%s) - 1 ))"
has 404 "$(code "$PORT" "/_pub/$pc/")" "10j: an expired public link → 404"
share --list >/dev/null
lacks "/p/$pc" "$(cat "$WORK/ts.json")" "10j: an expired public link is unmounted by the next run"
has 200 "$(code "$PORT" "/d/$id/")" "10j: the doc itself stays"
# --unpublish when tailscale fails / lies / cannot be asked → exit 1, never OFF
for m in fail lie; do
  share --publish --ttl 1h "$id" >/dev/null
  echo "$m" > "$WORK/off.mode"
  out="$(share --unpublish "$id")"; rc=$?
  [ "$rc" = 1 ] || fail "10k: --unpublish with tailscale '$m' must exit 1 (rc=$rc)" "$out"
  lacks "public OFF" "$out" "10k: --unpublish with tailscale '$m' must never print OFF"
  has "STILL public" "$out" "10k: it must say the link is still public ($m)"
  : > "$WORK/off.mode"
  has "public OFF" "$(share --unpublish "$id")" "10k: a working off prints OFF"
done
share --publish "$id" >/dev/null; touch "$WORK/fstat.fail"
out="$(share --unpublish "$id")"; rc=$?
[ "$rc" = 1 ] || fail "10k: --unpublish with funnel status failing must exit 1 (rc=$rc)" "$out"
lacks "public OFF" "$out" "10k: an unverifiable off must not print OFF"
rm -f "$WORK/fstat.fail"
# no CLI on PATH: the App's binary, called directly (a symlink to it crashes)
mkdir -p "$WORK/app/Tailscale.app/Contents/MacOS" "$WORK/nots"
cp "$WORK/fake/tailscale" "$WORK/app/Tailscale.app/Contents/MacOS/Tailscale"
for t in python3 node git cksum awk sed grep date cat; do p="$(command -v "$t")" && ln -sf "$p" "$WORK/nots/$t"; done
ln -sf "$WORK/app/Tailscale.app/Contents/MacOS/Tailscale" "$WORK/nots/tailscale"; touch "$WORK/app.only"
appsh() { HOME="$WORK/home" PATH="$WORK/nots:/usr/bin:/bin" DOC_PREVIEW_TAILSCALE_APP="$WORK/app/Tailscale.app/Contents/MacOS/Tailscale" DOC_PREVIEW_PORT="$BASEPORT" "$SH" "$@" 2>&1; }
out="$(appsh --unpublish "$id")"; rc=$?
[ "$rc" = 0 ] || fail "10l: a symlinked CLI must be bypassed for the App binary (rc=$rc)" "$out"
has "public OFF" "$out" "10l: unpublish through the App binary works"
lacks "/p/" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["mounts"])' "$WORK/ts.json")" "10l: and the mount is really gone"
rm -f "$WORK/nots/tailscale"
out="$(HOME="$WORK/home" PATH="$WORK/nots:/usr/bin:/bin" DOC_PREVIEW_TAILSCALE_APP="$WORK/none" "$SH" --unpublish "$id" 2>&1)"; rc=$?
[ "$rc" = 1 ] || fail "10l: no tailscale CLI at all → exit 1 (rc=$rc)" "$out"
lacks "public OFF" "$out" "10l: no CLI must never print OFF"
has "not found" "$out" "10l: and say the CLI was not found"
rm -f "$WORK/app.only"
# --health + the doctor row: a public link that never expires is a WARN
share --publish --ttl 0 "$id" >/dev/null
has "unexpiring_public=1" "$(share --health)" "10m: --health counts a never-expiring public link"
mkdir -p "$WORK/skills10" "$WORK/conf"; ln -s "$(dirname "$SH")" "$WORK/skills10/doc-preview"
l="$(HOME="$WORK/home" PATH="$WORK/fake:$PATH" CLAUDE_SKILLS_DIR="$WORK/skills10" FLEET_SKIP_GLOBAL_CONF=1 \
    FLEET_CONF_DIR="$WORK/conf" sh "$BIN/fleet-doctor.sh" 2>/dev/null | grep -a 'docprev' | grep -a 'public links')"
has "WARN" "$l" "10m: doctor WARNs on a public link that never expires"
has "never-expiring 1" "$l" "10m: the row names it"
share --unpublish "$id" >/dev/null
share --remove Doc >/dev/null

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
