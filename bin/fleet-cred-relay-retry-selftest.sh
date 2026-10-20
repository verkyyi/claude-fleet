#!/bin/bash
# fleet-cred-relay-retry-selftest.sh — a login opened while its account is still
# `creating` gets its relay pass with no hand step (issue #3423).
#
# The real `bin/fleet-cred-proxy.sh relay-tick` — the one road left (issue #4674
# deleted the per-login launcher `run`): the node daemon runs it as the login
# when the machine's shared proxy asks — in a Linux tenant's exact shape: its fleet.conf says only FLEET_CRED_PROXY=1 /
# FLEET_CRED_SEPARATE=1 (the relay URL is root's <LIB>/<login>.conf, which only
# the proxy reads), node.env is the store's unreadable link and the hub switch
# CCQUOTA_FLEET=1 is in node.pub.env alone. A fake shared proxy answers the
# control socket (status · node-token · relay); a fake curl is the hub, which
# refuses POST /v1/node/relay-credential with 403 until the account is active.
#
# The pass is renewed on REQUEST, never on a clock (issue #3561, EPIC #3500
# C19): the proxy writes relay-want.<login> in its run dir (missing · used ·
# 80% · refused) and relay-tick answers each request once. Here the test writes
# those requests, as the proxy would.
#
# What it pins:
#   A. boot      the proxy is not up yet → no hub call, whatever is asked
#   B. creating  a `missing` request → 403 → nothing kept, no re-probe, and no
#                second ask until the proxy asks again (its clock, not ours)
#   C. active    the next request ISSUES: the pass kept 0600, handed to the
#                proxy, and the probe re-run at once (FLEET_CRED_REPROBE_CMD)
#   D. held      no request → the hub is never asked, however many passes;
#                an `80%` / `used` request mints a new pass (--force), not a check;
#                the last answered request is kept in cred-proxy/relay-keep
#   E. no relay  a proxy with no relay road → the hub is never asked
#   F. run       the per-login launcher's old entry starts nothing (#4674)
# No network, no tmux; everything is a file or a unix socket under one tmp dir.
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN/selftest-lib.sh"
CHECKS=0

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
  printf '{"separated": true, "shared": true, "run": "%s"}\n' "$c.run" > "$c/credsep.json"
  ln -s "$W/store-not-yours/node.env" "$c/node.env"
  printf 'CCQUOTA_HUB_URL=http://127.0.0.1:9\nCCQUOTA_FLEET=1\nCCQUOTA_FLEET_COMPUTE=1\n' > "$c/node.pub.env"
}
tick() { # tick <conf dir> — one relay-tick pass, as the node daemon runs it
  HOME="$W/home" FLEET_CONF_DIR="$1" FLEET_SKIP_GLOBAL_CONF=1 FLEET_HUB_CURL="$W/curl" \
    FLEET_CRED_REPROBE_CMD="echo probed >> '$1/reprobed'" \
    bash "$BIN/fleet-cred-proxy.sh" relay-tick </dev/null >>"$1.out" 2>&1
}
WANT_T=$(( $(date +%s) - 1000 ))
want() { # want <file> <reason> — the proxy's request, each one a newer mtime
  WANT_T=$((WANT_T + 10))
  printf '%s %s -\n' "$2" "$WANT_T" > "$1.tmp"
  python3 -c 'import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1.tmp" "$WANT_T"
  mv -f "$1.tmp" "$1"   # one rename, as the proxy writes it
}
calls() { [ -f "$W/calls" ] && wc -l < "$W/calls" | tr -d ' ' || echo 0; }
calls_ge() { [ "$(calls)" -ge "$1" ]; }
until_() { # until_ <secs> <cmd…> — poll every 0.2 s
  local n=$(($1 * 5)); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.2; n=$((n - 1)); done
  return 1
}
mkdir -p "$W/home"

ME=$(id -un)
# ---- A. boot: the proxy is not up yet ----------------------------------------
C="$W/t1"; tenant "$C"; WF="$C.run/relay-want.$ME"
tick "$C" || st_fail "A: relay-tick exit $?"; st_count
want "$WF" missing; tick "$C"
[ "$(calls)" = 0 ] || st_fail "A: the hub was asked with no proxy to say it has a relay ($(calls) calls)"; st_count
python3 -I "$W/ctl.py" "$C.run" "$W/ctl1.log" 1 & PIDS="$PIDS $!"
until_ 10 test -S "$C.run/ctl.sock" || st_fail "A: the fake proxy did not start"

# ---- B. creating: a `missing` request, 403 -----------------------------------
want "$WF" missing; tick "$C"
[ "$(calls)" = 1 ] || st_fail "B: the request was not answered ($(calls) calls; $(cat "$C.out"))"; st_count
grep -qx status "$W/ctl1.log" || st_fail "B: relay-tick never asked its proxy whether a relay is configured"; st_count
[ ! -e "$C/cred-proxy/relay.token" ] || st_fail "B: a pass kept while the hub refused"; st_count
[ ! -e "$C/reprobed" ] || st_fail "B: re-probed with no pass"; st_count
tick "$C"; tick "$C"
[ "$(calls)" = 1 ] || st_fail "B: asked again with no new request ($(calls) calls) — a clock of its own?"; st_count

# ---- C. active: the next request issues, the proxy gets it, the probe re-runs --
: > "$W/active"
want "$WF" missing; tick "$C"
[ "$(cat "$C.run/relay.got" 2>/dev/null)" = frl1.abc ] || st_fail "C: no pass reached the proxy ($(calls) calls; $(cat "$C.out"))"; st_count
[ "$(cat "$C/cred-proxy/relay.token" 2>/dev/null)" = frl1.abc ] || st_fail "C: the login does not keep the pass"; st_count
case "$(ls -l "$C/cred-proxy/relay.token" | cut -c1-10)" in -rw-------) st_count ;; *) st_fail "C: the pass is not 0600" ;; esac
until_ 10 test -s "$C/reprobed" || st_fail "C: no re-probe after the pass landed"; st_count
grep -q 'relay (missing): relay: ISSUED' "$C.out" || st_fail "C: relay-tick's log does not say why it renewed ($(cat "$C.out"))"; st_count
[ -s "$C/cred-proxy/relay-keep" ] || st_fail "C: the answered request is not kept between passes"; st_count

# ---- D. held: no request, no ask; an 80% / used request mints anew -------------
n=$(calls); tick "$C"; tick "$C"
[ "$(calls)" = "$n" ] || st_fail "D: a held pass was asked for with no request ($n → $(calls))"; st_count
[ "$(wc -l < "$C/reprobed" | tr -d ' ')" = 1 ] || st_fail "D: re-probed more than once"; st_count
want "$WF" 80%; tick "$C"
[ "$(calls)" = $((n + 1)) ] || st_fail "D: an 80% request did not mint a new pass ($(calls) calls; $(cat "$C.out"))"; st_count
grep -q 'relay (80%): relay: ISSUED' "$C.out" || st_fail "D: the 80% renewal is not in the log"; st_count
want "$WF" used; tick "$C"
[ "$(calls)" = $((n + 2)) ] || st_fail "D: a 'used' request did not mint a new pass ($(calls) calls)"; st_count

# ---- E. no relay road: the hub is never asked ---------------------------------
rm -f "$W/calls"
C="$W/t2"; tenant "$C"; WF="$C.run/relay-want.$ME"
python3 -I "$W/ctl.py" "$C.run" "$W/ctl2.log" 0 & PIDS="$PIDS $!"
until_ 10 test -S "$C.run/ctl.sock" || st_fail "E: the fake proxy did not start"
want "$WF" missing; tick "$C"
grep -sqx status "$W/ctl2.log" || st_fail "E: relay-tick never asked its proxy"; st_count
[ "$(calls)" = 0 ] || st_fail "E: the hub was asked with no relay road ($(calls) calls)"; st_count

# ---- F. the per-login launcher is gone (#4674) --------------------------------
out=$(HOME="$W/home" FLEET_CONF_DIR="$C" FLEET_SKIP_GLOBAL_CONF=1 bash "$BIN/fleet-cred-proxy.sh" run 2>&1); rc=$?
[ "$rc" = 2 ] || st_fail "F: run is not an unknown command (rc $rc): $out"; st_count
pgrep -f "fleet-cred-proxy.sh relay-tick" >/dev/null && st_fail "F: a relay-tick outlived its pass"; st_count

printf 'fleet-cred-relay-retry selftest: PASS (%d checks)\n' "$CHECKS"
