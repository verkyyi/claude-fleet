#!/bin/bash
# fleet-hub-move-selftest.sh — bin/fleet-hub-move.py, the ONE writer of a
# machine's hub address (task PNWW, docs/dev/MANAGED-NODE.md «Moving the hub»).
#
#   A  rewrite --scope login: fleet.conf / node.env / node.pub.env / hub.json /
#      node.key.ok name the new address; another hub's line, the token lines,
#      modes and a `CCQUOTA_HUB_URL="$FLEET_HUB_URL"` line stay byte for byte;
#      the old bytes are kept as .hub-prev; a separated node.env (a link into the
#      store) is never written through and is reported LEFT (exit 1)
#   B  rewrite --scope machine: machine.env, logins/*.env, *.key.ok, hub-url,
#      admin/admin.conf, admin-agent/ and the credential stores' node.env
#   C  verify: the new address must take the node's own credential for the SAME
#      endpoint — a 401, another endpoint_id, a redirect, plain http or the
#      address dialed are refused (exit 3) and `follow` then writes nothing
#   D  follow, verified: verify + rewrite in one call
#   E  nothing names the old address: exit 0, nothing written
#   F  a credential store rewritten on a machine running the shared credential
#      proxy (<cred-base>/.shared.json) asks for its reload — `fleet-credsep.py
#      machine reload`, which (the machine daemon running it) stamps
#      <LIB>/.restart, the `reload` the daemon watches; nothing rewritten ⇒ no
#      stamp; no shared proxy (leg B) ⇒ no reload asked
#
# Fake hubs are python on 127.0.0.1 (FLEET_HUB_MOVE_TEST_HTTP=1, the seam that
# lets an http://127.0.0.1 address stand in for https), killed at the end.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
MOVE="$BIN/fleet-hub-move.py"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hub-move-st.XXXXXX")
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT
FAILS=0
ok()   { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
mode_of() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }

OLD=https://claudefleet.example.com
NEW=https://core.example.io

# ── A: login scope ──────────────────────────────────────────────────────────
C="$WORK/conf"; mkdir -p "$C"
cat > "$C/fleet.conf" <<EOF
# [common]
export FLEET_HOST=1
export FLEET_HUB_URL="$OLD/"
export CCQUOTA_HUB_URL="\$FLEET_HUB_URL"
# export FLEET_HUB_URL="https://other.example"
if [ "\${FLEET_SHELL:-0}" = 1 ]; then
  CCQUOTA_HUB_URL=https://other.example
fi
EOF
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=ccq_secret_token_value_1234567890\nCCQUOTA_FLEET=1\n' "$OLD" > "$C/node.env"
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_FLEET=1\n' "$OLD" > "$C/node.pub.env"
printf '{\n  "url": "%s",\n  "token": "fleet_hubjson_tok"\n}\n' "$OLD" > "$C/hub.json"
printf 'kid123 %s\n' "$OLD" > "$C/node.key.ok"
chmod 600 "$C/node.env" "$C/hub.json" "$C/node.key.ok"
cp "$C/fleet.conf" "$WORK/fleet.conf.orig"
out=$(python3 -I "$MOVE" rewrite --scope login --from "$OLD" --to "$NEW" --conf-dir "$C" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "A rewrite login exit 0" || fail "A rewrite login exit $rc: $out"
grep -qx "export FLEET_HUB_URL=\"$NEW\"" "$C/fleet.conf" && ok "A fleet.conf FLEET_HUB_URL" || fail "A fleet.conf: $(cat "$C/fleet.conf")"
grep -qx 'export CCQUOTA_HUB_URL="$FLEET_HUB_URL"' "$C/fleet.conf" \
  && grep -qx '# export FLEET_HUB_URL="https://other.example"' "$C/fleet.conf" \
  && grep -qx '  CCQUOTA_HUB_URL=https://other.example' "$C/fleet.conf" \
  && ok "A another hub's lines and the derived line untouched" || fail "A touched a line it should not: $(cat "$C/fleet.conf")"
cmp -s "$C/fleet.conf.hub-prev" "$WORK/fleet.conf.orig" && ok "A old bytes kept as .hub-prev" || fail "A no .hub-prev"
grep -qx "CCQUOTA_HUB_URL=$NEW" "$C/node.env" && grep -qx 'CCQUOTA_TOKEN=ccq_secret_token_value_1234567890' "$C/node.env" \
  && [ "$(mode_of "$C/node.env")" = 0o600 ] && [ "$(mode_of "$C/node.env.hub-prev")" = 0o600 ] \
  && ok "A node.env: address moved, token line and 0600 kept" || fail "A node.env: $(cat "$C/node.env") $(mode_of "$C/node.env")"
grep -qx "CCQUOTA_HUB_URL=$NEW" "$C/node.pub.env" && ok "A node.pub.env" || fail "A node.pub.env"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d=={"url":sys.argv[2],"token":"fleet_hubjson_tok"} else 1)' "$C/hub.json" "$NEW" \
  && ok "A hub.json url (token kept)" || fail "A hub.json: $(cat "$C/hub.json")"
grep -qx "kid123 $NEW" "$C/node.key.ok" && ok "A node.key.ok stays confirmed at the new address" || fail "A key.ok: $(cat "$C/node.key.ok")"
# a separated login: node.env is a link into root's store — never written through
S="$WORK/conf-sep"; mkdir -p "$S" "$WORK/store"
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=x\n' "$OLD" > "$WORK/store/node.env"
ln -s "$WORK/store/node.env" "$S/node.env"
out=$(python3 -I "$MOVE" rewrite --scope login --from "$OLD" --to "$NEW" --conf-dir "$S" 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "LEFT $S/node.env" && [ -L "$S/node.env" ] \
  && grep -qx "CCQUOTA_HUB_URL=$OLD" "$WORK/store/node.env" \
  && ok "A a store link is not written through, and is reported LEFT" || fail "A store link: rc $rc: $out"

# ── B: machine scope ────────────────────────────────────────────────────────
M="$WORK/state"; B="$WORK/fleet-cred"; mkdir -p "$M/logins" "$M/admin" "$M/admin-agent/conf" "$B/alice"
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=ccq_machine_tok\n' "$OLD" > "$M/machine.env"
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=ccq_login_tok\n' "$OLD" > "$M/logins/alice.env"
printf 'kidA %s\n' "$OLD" > "$M/logins/alice.key.ok"
printf 'kidM %s\n' "$OLD" > "$M/machine.key.ok"
printf '%s\n' "$OLD" > "$M/hub-url"
printf 'bin=/x/current/bin\nhub=%s\n' "$OLD" > "$M/admin/admin.conf"
printf 'kidS %s\n' "$OLD" > "$M/admin-agent/node.key.ok"
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=ccq_store_tok\n' "$OLD" > "$B/alice/node.env"
chmod 600 "$M/machine.env" "$M/logins/alice.env" "$B/alice/node.env"
out=$(FLEET_ADMIN_UNIT_DIR="$WORK/no-units" python3 -I "$MOVE" rewrite --scope machine --from "$OLD" --to "$NEW" \
  --state "$M" --cred-base "$B" 2>&1); rc=$?
out_b=$out
[ "$rc" = 0 ] && ok "B rewrite machine exit 0" || fail "B rewrite machine exit $rc: $out"
for f in machine.env logins/alice.env; do
  grep -qx "CCQUOTA_HUB_URL=$NEW" "$M/$f" && [ "$(mode_of "$M/$f")" = 0o600 ] && ok "B $f" || fail "B $f: $(cat "$M/$f")"
done
grep -qx "kidA $NEW" "$M/logins/alice.key.ok" && grep -qx "kidM $NEW" "$M/machine.key.ok" \
  && grep -qx "kidS $NEW" "$M/admin-agent/node.key.ok" && ok "B every key.ok" || fail "B key.ok"
grep -qx "$NEW" "$M/hub-url" && ok "B hub-url" || fail "B hub-url: $(cat "$M/hub-url")"
grep -qx "hub=$NEW" "$M/admin/admin.conf" && grep -qx 'bin=/x/current/bin' "$M/admin/admin.conf" \
  && ok "B admin.conf hub=" || fail "B admin.conf: $(cat "$M/admin/admin.conf")"
grep -qx "CCQUOTA_HUB_URL=$NEW" "$B/alice/node.env" && grep -qx 'CCQUOTA_TOKEN=ccq_store_tok' "$B/alice/node.env" \
  && ok "B the credential store's node.env" || fail "B store: $(cat "$B/alice/node.env")"
# machine.env is the last file written: its change restarts the node program
last=$(printf '%s\n' "$out" | grep '^rewrote ' | tail -n 1)
case "$last" in "rewrote $M/machine.env "*) ok "B machine.env last" ;; *) fail "B the last write was: $last" ;; esac

# ── C/D: verify / follow against fake hubs ──────────────────────────────────
cat > "$WORK/fakehub.py" <<'PY'
import http.server, json, sys
port_file, eid, mode = sys.argv[1], sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if mode == "redirect":
            self.send_response(302); self.send_header("Location", "https://elsewhere.example/v1/node/self"); self.end_headers(); return
        if self.path != "/v1/node/self" or self.headers.get("Authorization") != "Bearer good":
            self.send_response(401); self.end_headers(); return
        b = json.dumps({"endpoint_id": eid}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.serve_forever()
PY
hub() { # <name> <endpoint id> <mode>: a fake hub, its port in $WORK/<name>.port
  python3 -I "$WORK/fakehub.py" "$WORK/$1.port" "$2" "$3" & PIDS="$PIDS $!"; disown "$!" 2>/dev/null
  for _ in $(seq 1 50); do [ -s "$WORK/$1.port" ] && break; sleep 0.1; done
}
url() { printf 'http://127.0.0.1:%s' "$(cat "$WORK/$1.port")"; }
hub old e1 ok; hub same e1 ok; hub other e2 ok; hub redir e1 redirect
URL_old=$(url old) URL_same=$(url same) URL_other=$(url other) URL_redir=$(url redir)
export FLEET_HUB_MOVE_TEST_HTTP=1
v() { printf 'Bearer good\n%s\n' "${3:-Bearer good}" | python3 -I "$MOVE" verify --from "$1" --to "$2" >/dev/null 2>&1; echo $?; }
[ "$(v "$URL_old" "$URL_same")" = 0 ] && ok "C verify: the same endpoint at the new address" || fail "C verify same"
[ "$(v "$URL_old" "$URL_same" 'Bearer bad')" = 3 ] && ok "C verify: a new address that refuses the token" || fail "C verify 401"
[ "$(v "$URL_old" "$URL_other")" = 3 ] && ok "C verify: another endpoint (another hub)" || fail "C verify other endpoint"
[ "$(v "$URL_old" "$URL_redir")" = 3 ] && ok "C verify: a redirect is no answer" || fail "C verify redirect"
[ "$(v "$URL_old" "$URL_old")" = 3 ] && ok "C verify: the address dialed" || fail "C verify same address"
[ "$(FLEET_HUB_MOVE_TEST_HTTP=0 v "$URL_old" "$URL_same")" = 3 ] && ok "C verify: plain http without the seam" || fail "C verify http"
[ "$(v "$URL_old" "http://hub.example.com")" = 3 ] && ok "C verify: plain http to a real name" || fail "C verify http name"
F="$WORK/conf-f"; mkdir -p "$F"; printf 'export FLEET_HUB_URL="%s"\n' "$URL_old" > "$F/fleet.conf"; cp "$F/fleet.conf" "$WORK/f.orig"
printf 'Bearer good\nBearer bad\n' | python3 -I "$MOVE" follow --scope login --from "$URL_old" --to "$URL_same" --conf-dir "$F" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && cmp -s "$F/fleet.conf" "$WORK/f.orig" && [ ! -e "$F/fleet.conf.hub-prev" ] \
  && ok "C follow: unverified ⇒ nothing written" || fail "C follow unverified rc $rc"
printf 'Bearer good\nBearer good\n' | python3 -I "$MOVE" follow --scope login --from "$URL_old" --to "$URL_same" --conf-dir "$F" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qx "export FLEET_HUB_URL=\"$URL_same\"" "$F/fleet.conf" \
  && ok "D follow: verified ⇒ rewritten" || fail "D follow verified rc $rc: $(cat "$F/fleet.conf")"

# ── E: nothing to do ────────────────────────────────────────────────────────
N="$WORK/conf-n"; mkdir -p "$N"; printf 'export FLEET_HUB_URL="https://other.example"\n' > "$N/fleet.conf"
python3 -I "$MOVE" rewrite --scope login --from "$OLD" --to "$NEW" --conf-dir "$N" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$N/fleet.conf.hub-prev" ] && ok "E nothing names the old address: exit 0, nothing written" || fail "E rc $rc"
python3 -I "$MOVE" rewrite --scope login --from "$OLD" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "E usage" || fail "E usage rc $rc"

# ── F: the shared credential proxy is reloaded after its store moved ───────
grep -q '^credential proxy reload' <<<"$out_b" && fail "F leg B (no shared proxy) asked for a reload" \
  || ok "F no shared proxy on the machine: no reload asked"
FB="$WORK/f-cred"; FL="$WORK/f-lib"; FN="$WORK/f-node"; mkdir -p "$FB/alice" "$FL" "$FN" "$WORK/f-daemons" "$WORK/f-run"
printf '{"user": "%s", "port": 1, "logins": ["alice"]}\n' "$(id -un)" > "$FB/.shared.json"
printf '{"children": {"cred-proxy-shared": {"pid": 0}}}\n' > "$FN/state.json"   # the machine daemon runs it
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=ccq_store_tok\n' "$OLD" > "$FB/alice/node.env"; chmod 600 "$FB/alice/node.env"
fmove() {
  FLEET_CREDSEP_LIB="$FL" FLEET_NODE_STATE="$FN" FLEET_CREDSEP_DAEMON_DIR="$WORK/f-daemons" FLEET_CREDSEP_RUN_BASE="$WORK/f-run" \
    FLEET_CREDSEP_ROLE="$(id -un)" FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_SVC=0 FLEET_ADMIN_UNIT_DIR="$WORK/no-units" \
    python3 -I "$MOVE" rewrite --scope machine --from "$OLD" --to "$NEW" --state "$WORK/f-state" --cred-base "$FB" 2>&1
}
out=$(fmove); rc=$?
[ "$rc" = 0 ] && grep -qx "CCQUOTA_HUB_URL=$NEW" "$FB/alice/node.env" && [ -s "$FL/.restart" ] \
  && printf '%s\n' "$out" | grep -q '^credential proxy reload: rc 0' \
  && ok "F the store moved ⇒ the shared proxy's reload stamp (<LIB>/.restart) bumped" \
  || fail "F rc $rc, stamp $(cat "$FL/.restart" 2>&1): $out"
stamp=$(cat "$FL/.restart" 2>/dev/null)
out=$(fmove); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$FL/.restart" 2>/dev/null)" = "$stamp" ] && ! printf '%s\n' "$out" | grep -q '^credential proxy reload' \
  && ok "F nothing rewritten ⇒ no reload" || fail "F a second, empty move: rc $rc: $out"

if [ "$FAILS" -gt 0 ]; then
  printf 'fleet-hub-move selftest: %d FAILED\n' "$FAILS" >&2
  exit 1
fi
printf 'fleet-hub-move selftest: OK\n'
