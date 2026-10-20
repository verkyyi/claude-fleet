#!/bin/bash
# fleet-peer-cert-selftest.sh — machine-to-machine access through the hub
# (issue #1626, EPIC #1615 C9): bin/fleet-peer-cert.sh asks the hub for a
# five-minute certificate per connection, and fleet-move.sh /
# fleet-node-upgrade.sh ride it and never fall back to a standing key (the
# 看台's peer link, fleet-peerlink.py, is fleet-peerlink-selftest's). The hub is
# stubbed through FLEET_HUB_CURL, ssh through PATH — no hub, no network, no tmux.
# (The hub half — owner-only, five minutes, audited, a real sshd refusing an
# expired one — is the Go gate's: TestPeerCertOwnerOnlyShortAndAudited,
# TestRealSshdTrustsTheCA.)
#
# What it pins:
#   A. not a node   no node.env: exit 3, curl NEVER called, nothing on stdout —
#                   plain ssh, byte for byte as before (the degenerate case);
#                   FLEET_PEER_CERT=0 the same
#   B. granted      POST /v1/node/peer-cert {target, purpose, public_key,
#                   ttl_sec} with the bearer token FROM node.env (never left in
#                   the caller's env); a peer key made once at ~/.ssh/fleet-peer;
#                   the certificate written 0600; stdout = the ssh options one
#                   per line (-i key, CertificateFile, IdentitiesOnly, -l login)
#   C. names        `erin@mac-b.example.ts.net` → mac-b → its hub name through
#                   FLEET_NODE_ALIASES (`mac-c=mac-b` → mac-c)
#   C2. hub list    (issue #1719) peer/machines `mac-d mac-a`: mac-a, mac-a-lan,
#                   user@mac-d and fleet-mac-a-public all ask for mac-d — once,
#                   one certificate file; an unknown name passes through
#   D. refused      403 → exit 1 naming the hub's reason; curl failing → exit 1
#                   「入口失联，机器间访问暂停；你可直接 `fleet <机器>` 进去」 —
#                   paused, never a fallback; nothing on stdout. A down hub is
#                   refused inside 1 s: connect bounded to 0.8 s, one try (#1630)
#   E. old hub      404 / a 401 from the viewer gate → exit 3 (plain ssh) with a note
#   F. usage        bad purpose / bad name: exit 2, curl never called
#   H. move         fleet-move.sh's move_ssh puts the certificate's options on
#                   the ssh it runs; a refusal runs NO ssh (exit 255)
#   J. cache        (issue #1631) one certificate per (source, target,
#                   purpose) reused until 30 s before it expires: a second call
#                   prints the same options and does NOT reach the hub (a
#                   counting fake hub); another purpose / target asks; the
#                   hub's valid_before is honoured; inside the margin, a
#                   regenerated peer key, or no .meta (an older script's cert)
#                   asks afresh; a refusal is not cached
#   K. host keys    (issue #3050) the hub's host_keys + alias for the target go
#                   into peer/known_hosts under fleet-<alias> (bad lines dropped,
#                   that alias's old lines replaced, other machines' kept) and the
#                   options gain HostKeyAlias=fleet-<alias> + UserKnownHostsFile=
#                   that file, before -l; the cache keeps them; an older .meta
#                   (no alias field) or an alias whose lines are gone is a miss;
#                   no keys / a bad alias → no such option, as before
#   I. lint         every ssh fleet-move.sh / fleet-node-upgrade.sh opens to
#                   another machine carries the peer options
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$BIN/fleet-peer-cert.sh"
CHECKS=0
fail() { printf 'fleet-peer-cert selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-peer-cert-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
mkdir -p "$HOME" "$FLEET_CONF_DIR" "$TMPDIR"
unset CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_CURL FLEET_HUB_TIMEOUT FLEET_NODE_ALIASES FLEET_REMOTE_SSH FLEET_PEER_CERT_CONNECT_SECS \
      FLEET_PEER_CERT FLEET_PEER_KEY FLEET_PEER_CERT_SECS

STUB="$WORK/curl"
cat > "$STUB" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$STUB_LOG"
[ -n "${STUB_COUNT:-}" ] && printf 'x\n' >> "$STUB_COUNT"
body=''
while [ $# -gt 0 ]; do case "$1" in --data-binary) body="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s' "$body" > "$STUB_BODY"
[ "${FAKE_RC:-0}" -eq 0 ] || exit "$FAKE_RC"
printf '%s\n%s' "${FAKE_BODY:-{\}}" "${FAKE_CODE:-200}"
EOF
chmod +x "$STUB"
export STUB_LOG="$WORK/curl.log" STUB_BODY="$WORK/curl.body" FLEET_HUB_CURL="$STUB"
reset() { rm -f "$STUB_LOG" "$STUB_BODY"; unset FAKE_RC FAKE_CODE FAKE_BODY; }
GRANT='{"certificate":"ssh-ed25519-cert-v01@openssh.com AAAAfake peer:carol@mac-b>carol@mac-a:view\n","serial":"7","key_id":"peer:carol@mac-b>carol@mac-a:view","login":"carol","target":"mac-d","ttl_sec":300}'

# A. not a node
reset
out=$("$SUT" mac-a view 2>"$WORK/err"); rc=$?
[ "$rc" -eq 3 ] || fail "A: exit $rc, want 3 without node.env"
[ -z "$out" ] || fail "A: stdout should be empty, got: $out"
[ ! -e "$STUB_LOG" ] || fail "A: curl called without a node token"
[ ! -e "$HOME/.ssh/fleet-peer" ] || fail "A: a peer key was made on a login that is no node"
ok

printf 'CCQUOTA_TOKEN=node-secret\nCCQUOTA_HUB_URL=https://hub.example\n' > "$FLEET_CONF_DIR/node.env"
chmod 600 "$FLEET_CONF_DIR/node.env"

reset
out=$(FLEET_PEER_CERT=0 "$SUT" mac-a view 2>/dev/null); rc=$?
{ [ "$rc" -eq 3 ] && [ -z "$out" ] && [ ! -e "$STUB_LOG" ]; } || fail "A: FLEET_PEER_CERT=0 → exit $rc, out '$out'"
ok

# B. granted
reset
export FAKE_BODY="$GRANT"
out=$("$SUT" mac-a view 2>"$WORK/err"); rc=$?
[ "$rc" -eq 0 ] || fail "B: exit $rc: $(cat "$WORK/err")"
grep -q -- '-H Authorization: Bearer node-secret' "$STUB_LOG" || fail "B: no bearer from node.env: $(cat "$STUB_LOG")"
grep -q 'https://hub.example/v1/node/peer-cert' "$STUB_LOG" || fail "B: wrong url: $(cat "$STUB_LOG")"
[ -z "${CCQUOTA_TOKEN:-}" ] || fail "B: the token leaked into the caller"
python3 - "$STUB_BODY" "$HOME/.ssh/fleet-peer.pub" <<'PY' || fail "B: body: $(cat "$STUB_BODY")"
import json, sys
b = json.load(open(sys.argv[1]))
assert b["target"] == "mac-a" and b["purpose"] == "view" and b["ttl_sec"] == 300, b
assert b["public_key"] == open(sys.argv[2]).read().strip(), b
PY
[ -s "$HOME/.ssh/fleet-peer" ] || fail "B: no peer key made"
cert="$FLEET_CONF_DIR/peer/mac-a.view-cert.pub"
grep -q '^ssh-ed25519-cert-v01@openssh.com ' "$cert" || fail "B: certificate not written: $(cat "$cert" 2>&1)"
[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$cert")" = 0o600 ] || fail "B: certificate not 0600"
want=$(printf '%s\n' -i "$HOME/.ssh/fleet-peer" -o "CertificateFile=$cert" -o IdentitiesOnly=yes -l carol)
[ "$out" = "$want" ] || fail "B: options:
$out
want:
$want"
k1=$(cat "$HOME/.ssh/fleet-peer.pub")
"$SUT" mac-a view >/dev/null 2>&1
[ "$(cat "$HOME/.ssh/fleet-peer.pub")" = "$k1" ] || fail "B: the peer key changed on the second call"
ok

# C. names
reset
export FAKE_BODY="$GRANT"
FLEET_NODE_ALIASES='mac-c=mac-b mac-d=mac-a' "$SUT" erin@mac-b.example.ts.net upgrade >/dev/null 2>&1 || fail "C: exit $?"
python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); assert b["target"]=="mac-c" and b["purpose"]=="upgrade", b' "$STUB_BODY" \
  || fail "C: body: $(cat "$STUB_BODY")"
ok
# C2 (issue #1719): the hub's own list, peer/machines (`fleet login` writes it):
# mac-a, mac-a-lan, mac-d and fleet-mac-a-public are ONE machine — the hub is asked for
# mac-d once, and every name gets the same certificate file.
reset
export FAKE_BODY="$GRANT" STUB_COUNT="$WORK/c2.count"
rm -f "$STUB_COUNT" "$FLEET_CONF_DIR"/peer/*-cert.pub*
mkdir -p "$FLEET_CONF_DIR/peer"
printf 'mac-c mac-b\nmac-d mac-a\n' > "$FLEET_CONF_DIR/peer/machines"
for n in mac-a mac-a-lan erin@mac-d fleet-mac-a-public; do
  o=$("$SUT" "$n" view 2>"$WORK/err") || fail "C2: $n exit $?: $(cat "$WORK/err")"
  case "$o" in *"CertificateFile=$FLEET_CONF_DIR/peer/mac-d.view-cert.pub"*) ;; *) fail "C2: $n → $o" ;; esac
done
python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); assert b["target"]=="mac-d", b' "$STUB_BODY" \
  || fail "C2: body: $(cat "$STUB_BODY")"
[ "$(wc -l < "$STUB_COUNT" | tr -d ' ')" = 1 ] || fail "C2: the hub was asked $(wc -l < "$STUB_COUNT") times, want once"
# a name the list does not know is passed through as before
reset
"$SUT" m9 view >/dev/null 2>&1
python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); assert b["target"]=="m9", b' "$STUB_BODY" || fail "C2: m9 body: $(cat "$STUB_BODY")"
unset STUB_COUNT
rm -f "$FLEET_CONF_DIR/peer/machines" "$FLEET_CONF_DIR"/peer/*-cert.pub*
ok

# D. refused / down
reset
export FAKE_CODE=403 FAKE_BODY='{"error":"bob@mac-a has no login of its owner on mac-b"}'
out=$("$SUT" mac-b view 2>"$WORK/err"); rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$out" ]; } || fail "D: 403 → exit $rc, out '$out'"
grep -q 'has no login of its owner' "$WORK/err" || fail "D: reason not relayed: $(cat "$WORK/err")"
reset
export FAKE_RC=7
out=$(FLEET_UI_LANG=zh "$SUT" mac-b view 2>"$WORK/err"); rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$out" ]; } || fail "D: down → exit $rc, out '$out'"
grep -q '入口失联，机器间访问暂停；你可直接 `fleet mac-b` 进去' "$WORK/err" || fail "D: stderr: $(cat "$WORK/err")"
# #1630: a down hub is refused within a second — the connect is bounded to 1 s
# (0.8 s, not the 10 s request bound) and there is exactly one try.
grep -q -- '--connect-timeout 0.8 ' "$STUB_LOG" || fail "D: connect not bounded to 0.8 s: $(cat "$STUB_LOG")"
reset
export FAKE_RC=28 FLEET_UI_LANG=en
out=$("$SUT" erin@mac-b.example.ts.net view 2>"$WORK/err"); rc=$?
unset FLEET_UI_LANG
{ [ "$rc" -eq 1 ] && [ -z "$out" ]; } || fail "D: connect timeout → exit $rc, out '$out'"
grep -q 'hub lost — machine-to-machine access paused; you can still go in directly with `fleet mac-b`' "$WORK/err" \
  || fail "D: en stderr: $(cat "$WORK/err")"
# And for real: a hub port nobody listens on is refused well inside a second.
if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  t0=$(python3 -c 'import time; print(time.time())')
  out=$(FLEET_HUB_CURL=curl CCQUOTA_HUB_URL="http://127.0.0.1:$port" "$SUT" mac-b view 2>"$WORK/err"); rc=$?
  dt=$(python3 -c "import time; print(int((time.time()-$t0)*1000))")
  { [ "$rc" -eq 1 ] && [ -z "$out" ]; } || fail "D: closed port → exit $rc, out '$out', err $(cat "$WORK/err")"
  [ "$dt" -lt 1000 ] || fail "D: a down hub took ${dt} ms to refuse; want < 1000"
fi
ok

# E. old hub
for case_ in '404|404 page not found' '401|{"error":"missing viewer token"}'; do
  reset
  export FAKE_CODE="${case_%%|*}" FAKE_BODY="${case_#*|}"
  out=$("$SUT" mac-a move 2>"$WORK/err"); rc=$?
  { [ "$rc" -eq 3 ] && [ -z "$out" ]; } || fail "E: HTTP $FAKE_CODE → exit $rc, out '$out'"
  grep -q 'plain ssh' "$WORK/err" || fail "E: no note: $(cat "$WORK/err")"
done
ok

# F. usage
for args in 'mac-a shell' '-x view' 'mac-a/../x view'; do
  reset
  # shellcheck disable=SC2086
  "$SUT" $args >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "F: '$args' → exit $rc, want 2"
  [ ! -e "$STUB_LOG" ] || fail "F: '$args' called curl"
done
ok

# H. move: the certificate rides the ssh; a refusal runs none
mkdir -p "$WORK/shim"
cat > "$WORK/shim/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$SSH_LOG"
EOF
chmod +x "$WORK/shim/ssh"
export SSH_LOG="$WORK/ssh.log"
reset; rm -f "$SSH_LOG"
export FAKE_BODY="$GRANT"
( PATH="$WORK/shim:$PATH"; . "$BIN/fleet-move.sh"; TO='mac-a'; move_ssh "$TO" true ) || fail "H: move_ssh failed"
want=$(printf '%s\n' -o BatchMode=yes -i "$HOME/.ssh/fleet-peer" -o "CertificateFile=$FLEET_CONF_DIR/peer/mac-a.move-cert.pub" -o IdentitiesOnly=yes -l carol mac-a true)
[ "$(cat "$SSH_LOG")" = "$want" ] || fail "H: ssh argv:
$(cat "$SSH_LOG")
want:
$want"
reset; rm -f "$SSH_LOG" "$FLEET_CONF_DIR"/peer/*.meta   # the grant above is cached (#1631): forget it
export FAKE_CODE=403 FAKE_BODY='{"error":"no"}'
( PATH="$WORK/shim:$PATH"; . "$BIN/fleet-move.sh"; TO='mac-a'; move_ssh "$TO" true ) 2>/dev/null; rc=$?
[ "$rc" -eq 255 ] || fail "H: refused → exit $rc, want 255"
[ ! -e "$SSH_LOG" ] || fail "H: ssh ran after the hub refused: $(cat "$SSH_LOG")"
reset; rm -f "$SSH_LOG"; mv "$FLEET_CONF_DIR/node.env" "$WORK/node.env.off"
( PATH="$WORK/shim:$PATH"; . "$BIN/fleet-move.sh"; TO='mac-a'; move_ssh "$TO" true ) || fail "H: plain move_ssh failed"
[ "$(cat "$SSH_LOG")" = "$(printf '%s\n' -o BatchMode=yes mac-a true)" ] || fail "H: not a node, yet ssh got: $(cat "$SSH_LOG")"
mv "$WORK/node.env.off" "$FLEET_CONF_DIR/node.env"
ok

# I. lint: no cross-machine ssh without the peer options
bad=$(grep -n 'ssh -o BatchMode=yes' "$BIN/fleet-move.sh" "$BIN/fleet-node-upgrade.sh" | grep -v 'PEER\[@\]')
[ -z "$bad" ] || fail "I: an ssh without the peer certificate:
$bad"
ok

# J. cache (issue #1631)
cnt() { [ -f "$STUB_COUNT" ] && grep -c x "$STUB_COUNT" || printf 0; }
export STUB_COUNT="$WORK/curl.count"
rm -rf "$FLEET_CONF_DIR/peer"; rm -f "$STUB_COUNT"; reset
export FAKE_BODY="$GRANT"
o1=$("$SUT" mac-a view 2>/dev/null) || fail "J: first call"
o2=$("$SUT" mac-a view 2>/dev/null) || fail "J: second call"
[ "$o1" = "$o2" ] || fail "J: cached options differ:
$o2
want:
$o1"
[ "$(cnt)" = 1 ] || fail "J: the hub was asked $(cnt) times for one (mac-a, view), want 1"
"$SUT" mac-a upgrade >/dev/null 2>&1; "$SUT" mac-b view >/dev/null 2>&1
[ "$(cnt)" = 3 ] || fail "J: another purpose / target must ask (count $(cnt), want 3)"
# the hub's valid_before: 20 s left is inside the 30 s margin → asks every time
vb=$(python3 -c 'import datetime,time; print(datetime.datetime.utcfromtimestamp(time.time()+20).strftime("%Y-%m-%dT%H:%M:%S.123456789Z"))')
rm -f "$STUB_COUNT"
export FAKE_BODY="${GRANT%\}},\"valid_before\":\"$vb\"}"
"$SUT" mac-a move >/dev/null 2>&1; "$SUT" mac-a move >/dev/null 2>&1
[ "$(cnt)" = 2 ] || fail "J: a certificate inside the margin was reused (count $(cnt), want 2)"
read -r u _ < "$FLEET_CONF_DIR/peer/mac-a.move-cert.pub.meta"
[ $(( u - $(date +%s) )) -le 21 ] || fail "J: valid_before not honoured: until $u"
# FLEET_PEER_CERT_MARGIN=5: 20 s left is reusable
FLEET_PEER_CERT_MARGIN=5 "$SUT" mac-a move >/dev/null 2>&1
[ "$(cnt)" = 2 ] || fail "J: FLEET_PEER_CERT_MARGIN=5 still asked (count $(cnt))"
# a regenerated key / no .meta → a miss
export FAKE_BODY="$GRANT"; rm -f "$STUB_COUNT"
rm -f "$HOME/.ssh/fleet-peer" "$HOME/.ssh/fleet-peer.pub"
"$SUT" mac-a view >/dev/null 2>&1
[ "$(cnt)" = 1 ] || fail "J: a new peer key reused the old certificate"
rm -f "$FLEET_CONF_DIR/peer/mac-a.view-cert.pub.meta"
"$SUT" mac-a view >/dev/null 2>&1
[ "$(cnt)" = 2 ] || fail "J: a certificate with no .meta was reused"
# a refusal is not cached
rm -f "$STUB_COUNT"; export FAKE_CODE=403 FAKE_BODY='{"error":"no"}'
"$SUT" m9 view >/dev/null 2>&1; "$SUT" m9 view >/dev/null 2>&1
[ "$(cnt)" = 2 ] || fail "J: a refusal was cached (count $(cnt))"
unset STUB_COUNT; reset
ok

# K. host keys (issue #3050)
cnt() { [ -f "$STUB_COUNT" ] && wc -l < "$STUB_COUNT" | tr -d ' ' || echo 0; }
export STUB_COUNT="$WORK/count"; rm -f "$STUB_COUNT" "$FLEET_CONF_DIR"/peer/*.meta
KH="$FLEET_CONF_DIR/peer/known_hosts"
HK1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne'; HK2='ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY='
printf 'fleet-m9 ssh-ed25519 AAAAkeep\nfleet-mac-a ssh-ed25519 AAAAstale\n' > "$KH"
export FAKE_BODY='{"certificate":"ssh-ed25519-cert-v01@openssh.com AAAAfake\n","login":"carol","target":"mac-d","ttl_sec":300,"alias":"mac-a","host_keys":["'"$HK1"' root@mac-a","garbage","'"$HK2"'","ssh-ed25519 AAAA\nfleet-m9 ssh-ed25519 AAAAevil"]}'
out=$("$SUT" mac-a view 2>"$WORK/err") || fail "K: exit $?: $(cat "$WORK/err")"
cert="$FLEET_CONF_DIR/peer/mac-a.view-cert.pub"
want=$(printf '%s\n' -i "$HOME/.ssh/fleet-peer" -o "CertificateFile=$cert" -o IdentitiesOnly=yes \
  -o HostKeyAlias=fleet-mac-a -o "UserKnownHostsFile=$KH" -l carol)
[ "$out" = "$want" ] || fail "K: options:
$out
want:
$want"
want=$(printf 'fleet-m9 ssh-ed25519 AAAAkeep\nfleet-mac-a %s\nfleet-mac-a %s' "$HK1" "$HK2")
[ "$(cat "$KH")" = "$want" ] || fail "K: known_hosts:
$(cat "$KH")
want:
$want"
# the cache keeps the options, without asking
[ "$("$SUT" mac-a view 2>/dev/null)" = "$out" ] && [ "$(cnt)" = 1 ] || fail "K: the cached certificate lost its host-key options (asked $(cnt))"
# mac-a's lines gone (the file cleaned by hand) → asked afresh
sed -i.bak '/^fleet-mac-a /d' "$KH"; rm -f "$KH.bak"
"$SUT" mac-a view >/dev/null 2>&1; [ "$(cnt)" = 2 ] || fail "K: a cache whose host keys are gone was reused"
grep -q "^fleet-mac-a $HK1\$" "$KH" || fail "K: the re-ask did not write mac-a's key back"
# an older script's .meta (three fields, before #3050) → asked afresh
read -r a b c _ < "$cert.meta"; printf '%s %s %s\n' "$a" "$b" "$c" > "$cert.meta"
"$SUT" mac-a view >/dev/null 2>&1; [ "$(cnt)" = 3 ] || fail "K: a .meta with no host alias was reused"
# no keys / a bad alias → no host-key option; the cache remembers «none» (-)
rm -f "$FLEET_CONF_DIR"/peer/*.meta
export FAKE_BODY='{"certificate":"ssh-ed25519-cert-v01@openssh.com AAAAfake\n","login":"carol","target":"mac-d","ttl_sec":300,"alias":"../mac-a","host_keys":["'"$HK1"'"]}'
out=$("$SUT" mac-a view 2>/dev/null) || fail "K: bad alias: exit $?"
case "$out" in *HostKey*|*KnownHosts*) fail "K: a bad alias put host-key options on: $out" ;; esac
grep -q '^fleet-\.\./' "$KH" && fail "K: a bad alias reached known_hosts"
[ "$("$SUT" mac-a view 2>/dev/null)" = "$out" ] && [ "$(cnt)" = 4 ] || fail "K: a «no keys» certificate was not cached (asked $(cnt))"
unset STUB_COUNT; reset
ok

printf 'fleet-peer-cert selftest: OK (%d checks)\n' "$CHECKS"
