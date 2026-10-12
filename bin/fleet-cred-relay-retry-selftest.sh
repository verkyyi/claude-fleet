#!/bin/bash
# fleet-cred-relay-retry-selftest.sh — a login opened while its account is still
# `creating` gets its relay pass with no hand step (issue #3423).
#
# The real launcher (`bin/fleet-cred-proxy.sh run`, separated) in a Linux
# tenant's exact shape: its fleet.conf says only FLEET_CRED_PROXY=1 /
# FLEET_CRED_SEPARATE=1 (the relay URL is root's <LIB>/<login>.conf, which only
# the proxy reads), node.env is the store's unreadable link and the hub switch
# CCQUOTA_FLEET=1 is in node.pub.env alone. A fake shared proxy answers the
# control socket (status · node-token · relay); a fake curl is the hub, which
# refuses POST /v1/node/relay-credential with 403 until the account is active.
#
# What it pins:
#   A. boot      the proxy is not up yet → no hub call, asked again on the short
#                clock (not the 30-minute one)
#   B. creating  403 → asked again on the short clock, nothing kept, no re-probe
#   C. active    the next ask ISSUES: the pass kept 0600, handed to the proxy,
#                and the probe re-run at once (FLEET_CRED_REPROBE_CMD)
#   D. held      a held pass is not asked for again on the short clock
#   E. no relay  a proxy with no relay road → the hub is never asked
#   F. relay-tick  a login on the SHARED proxy has no resident launcher (issue
#                #3524): the node daemon's one-minute `relay-tick` is one pass of
#                the same keeping — boot, 403, issue, held — its clocks kept in
#                cred-proxy/relay-keep between passes
# No network, no tmux; everything is a file or a unix socket under one tmp dir.
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKS=0
fail() { printf 'fleet-cred-relay-retry selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

# Short: ctl.sock lives under it (104 bytes on macOS).
TMPB=${TMPDIR:-/tmp}; [ "${#TMPB}" -le 40 ] || TMPB=/tmp
W="$(mktemp -d "${TMPB%/}/frr.XXXXXX")" || exit 2
PIDS=''
cleanup() {
  local p
  exec 2>/dev/null
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  rm -rf "$W"
}
trap cleanup EXIT
unset CCQUOTA_FLEET CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_URL FLEET_CRED_RELAY_URL FLEET_CRED_RELAY_TOKEN

# ---- the fakes --------------------------------------------------------------
cat > "$W/ctl.py" <<'PY'
import json, os, signal, socket, sys
signal.alarm(120)   # never outlive the test
run, log = sys.argv[1], sys.argv[2]
relay_on = sys.argv[3] == "1"
held = {"pass": ""}
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
p = os.path.join(run, "ctl.sock")
s.bind(p); s.listen(8)
while True:
    c, _ = s.accept()
    buf = b""
    while b"\n" not in buf:
        d = c.recv(65536)
        if not d: break
        buf += d
    req = json.loads(buf or b"{}")
    op = req.get("op")
    with open(log, "a") as f: f.write(op + "\n")
    if op == "status":
        res = {"ok": True, "pid": 1, "port": 1, "trust": "trusted", "trust_why": "test",
               "relay": relay_on, "relay_pass": bool(held["pass"])}
    elif op == "node-token":
        res = {"ok": True, "url": "http://127.0.0.1:9/broker", "token": "fcpn1.test"}
    elif op == "relay":
        held["pass"] = (req.get("data") or "").strip()
        with open(os.path.join(run, "relay.got"), "w") as f: f.write(held["pass"])
        res = {"ok": True}
    else:
        res = {"ok": False, "err": "no op " + str(op)}
    c.sendall((json.dumps(res) + "\n").encode()); c.close()
PY
# the hub, as curl: the request's last argument is the URL; stdin carries the
# bearer and is read away
cat > "$W/curl" <<EOF
#!/bin/bash
cat >/dev/null
for u; do :; done
case "\$u" in
  */v1/node/relay-credential)
    echo x >> "$W/calls"
    if [ -f "$W/active" ]; then printf '{"token":"frl1.abc","machine":"lnx0","login":"tenant"}\n200'
    else printf '{"error":"account is creating"}\n403'; fi ;;
  */v1/relay/check) printf '{}\n200' ;;
  *) printf '{}\n404' ;;
esac
EOF
chmod +x "$W/curl"

# the tenant: home, conf dir, its node files
tenant() { # tenant <dir> — a Linux tenant's conf dir, as fleet-node-linux.py writes it
  local c=$1
  mkdir -p "$c" "$c.run"
  printf '# ---- [common] ----\nFLEET_CRED_PROXY=1\nFLEET_CRED_SEPARATE=1\n' > "$c/fleet.conf"
  printf '{"separated": true, "run": "%s"}\n' "$c.run" > "$c/credsep.json"
  ln -s "$W/store-not-yours/node.env" "$c/node.env"
  printf 'CCQUOTA_HUB_URL=http://127.0.0.1:9\nCCQUOTA_FLEET=1\nCCQUOTA_FLEET_COMPUTE=1\n' > "$c/node.pub.env"
}
launch() { # launch <conf dir> — the real launcher, on short clocks
  HOME="$W/home" FLEET_CONF_DIR="$1" FLEET_SKIP_GLOBAL_CONF=1 FLEET_HUB_CURL="$W/curl" \
    FLEET_CRED_PROXY_IDLE_SECS=1 FLEET_CRED_RELAY_RETRY_SECS=1 FLEET_CRED_RELAY_RETRY_MAX_SECS=2 \
    FLEET_CRED_REPROBE_CMD="echo probed >> '$1/reprobed'" \
    bash "$BIN/fleet-cred-proxy.sh" run </dev/null >"$1.out" 2>&1 &
  PIDS="$PIDS $!"
}
calls() { [ -f "$W/calls" ] && wc -l < "$W/calls" | tr -d ' ' || echo 0; }
calls_ge() { [ "$(calls)" -ge "$1" ]; }
until_() { # until_ <secs> <cmd…> — poll every 0.2 s
  local n=$(($1 * 5)); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.2; n=$((n - 1)); done
  return 1
}
mkdir -p "$W/home"

# ---- A. boot: the proxy is not up yet ----------------------------------------
C="$W/t1"; tenant "$C"
launch "$C"
sleep 2
[ "$(calls)" = 0 ] || fail "A: the hub was asked with no proxy to say it has a relay ($(calls) calls)"; ok
python3 -I "$W/ctl.py" "$C.run" "$W/ctl1.log" 1 & PIDS="$PIDS $!"

# ---- B. creating: 403, asked again on the short clock ------------------------
until_ 15 calls_ge 2 || fail "B: not asked again after the 403 within 15 s ($(calls) calls) — the 30-minute clock?"; ok
grep -qx status "$W/ctl1.log" || fail "B: the launcher never asked its proxy whether a relay is configured"; ok
[ ! -e "$C/cred-proxy/relay.token" ] || fail "B: a pass kept while the hub refused"; ok
[ ! -e "$C/reprobed" ] || fail "B: re-probed with no pass"; ok

# ---- C. active: the next ask issues, the proxy gets it, the probe re-runs -----
: > "$W/active"
until_ 15 test -s "$C.run/relay.got" || fail "C: no pass reached the proxy within 15 s of the account turning active ($(calls) calls; $(cat "$C.out"))"; ok
[ "$(cat "$C.run/relay.got")" = frl1.abc ] || fail "C: the proxy got '$(cat "$C.run/relay.got")'"; ok
[ "$(cat "$C/cred-proxy/relay.token" 2>/dev/null)" = frl1.abc ] || fail "C: the login does not keep the pass"; ok
case "$(ls -l "$C/cred-proxy/relay.token" | cut -c1-10)" in -rw-------) ok ;; *) fail "C: the pass is not 0600" ;; esac
until_ 10 test -s "$C/reprobed" || fail "C: no re-probe after the pass landed"; ok

# ---- D. held: no more asks on the short clock ---------------------------------
n=$(calls); sleep 4
[ "$(calls)" = "$n" ] || fail "D: a held pass was asked for again ($n → $(calls))"; ok
[ "$(wc -l < "$C/reprobed" | tr -d ' ')" = 1 ] || fail "D: re-probed more than once"; ok

# ---- E. no relay road: the hub is never asked ---------------------------------
rm -f "$W/calls"
C="$W/t2"; tenant "$C"
python3 -I "$W/ctl.py" "$C.run" "$W/ctl2.log" 0 & PIDS="$PIDS $!"
until_ 10 test -S "$C.run/ctl.sock" || fail "E: the fake proxy did not start"
launch "$C"
until_ 10 grep -sqx status "$W/ctl2.log" || fail "E: the launcher never asked its proxy"; ok
sleep 3
[ "$(calls)" = 0 ] || fail "E: the hub was asked with no relay road ($(calls) calls)"; ok

# ---- F. relay-tick: one pass at a time, the clocks kept between passes ---------
rm -f "$W/calls" "$W/active"
C="$W/t3"; tenant "$C"
printf '{"separated": true, "shared": true, "run": "%s"}\n' "$C.run" > "$C/credsep.json"
tick() {
  HOME="$W/home" FLEET_CONF_DIR="$C" FLEET_SKIP_GLOBAL_CONF=1 FLEET_HUB_CURL="$W/curl" \
    FLEET_CRED_RELAY_RETRY_SECS=1 FLEET_CRED_RELAY_RETRY_MAX_SECS=2 \
    FLEET_CRED_REPROBE_CMD="echo probed >> '$C/reprobed'" \
    bash "$BIN/fleet-cred-proxy.sh" relay-tick </dev/null >>"$C.out" 2>&1
}
tick; rc=$?
[ "$rc" = 0 ] || fail "F: relay-tick exit $rc"; ok
[ "$(calls)" = 0 ] || fail "F: asked the hub with no proxy up"; ok
[ -s "$C/cred-proxy/relay-keep" ] || fail "F: no clocks kept between passes"; ok
python3 -I "$W/ctl.py" "$C.run" "$W/ctl3.log" 1 & PIDS="$PIDS $!"
until_ 10 test -S "$C.run/ctl.sock" || fail "F: the fake proxy did not start"
sleep 1.2; tick
[ "$(calls)" = 1 ] || fail "F: the second pass did not ask the hub ($(calls) calls)"; ok
tick
[ "$(calls)" = 1 ] || fail "F: asked again before its short clock ($(calls) calls)"; ok
: > "$W/active"; sleep 2.2; tick
[ "$(cat "$C.run/relay.got" 2>/dev/null)" = frl1.abc ] || fail "F: no pass reached the shared proxy ($(calls) calls; $(cat "$C.out"))"; ok
n=$(calls); sleep 2.2; tick
[ "$(calls)" = "$n" ] || fail "F: a held pass was asked for again ($n → $(calls))"; ok
# no resident launcher is left behind by a pass
pgrep -f "fleet-cred-proxy.sh relay-tick" >/dev/null && fail "F: a relay-tick outlived its pass"; ok

printf 'fleet-cred-relay-retry selftest: PASS (%d checks)\n' "$CHECKS"
