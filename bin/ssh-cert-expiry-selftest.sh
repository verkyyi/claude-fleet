#!/bin/bash
# ssh-cert-expiry-selftest.sh — a fleet SSH certificate is checked when you log
# in, never during the session (task KEA0): a session opened on a certificate
# that then expires keeps running, and only a NEW login on it is refused. Every
# hop that presents a certificate to an sshd — `fleet shell` / the 看台 on the
# 12-hour user certificate, the door's two-minute door-session certificate into a
# home's entry port — rests on this, so a short certificate never cuts a person
# off mid-work. (The door itself, tokenledger/agent/door, takes no certificate
# at all and clears its deadlines after the handshake.)
#
# A sandbox sshd on 127.0.0.1 trusting a throwaway CA; a certificate valid for a
# few seconds; a session that outlives it by twice that. No sshd here ⇒ SKIP.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need ssh ssh-keygen python3
SSHD="${FLEET_ENTRY_SSHD:-/usr/sbin/sshd}"
[ -x "$SSHD" ] || { printf 'selftest: %s absent — SKIP\n' "$SSHD" >&2; exit 0; }
st_sandbox "${TMPDIR:-/tmp}/sshcertexp.XXXXXX" physical
d="$WORK"
LIFE=6   # the certificate's seconds left when the session opens
me=$(id -un)

for k in ca u hk; do
  ssh-keygen -q -t ed25519 -N '' -C "$k" -f "$d/$k" || st_fail setup "ssh-keygen could not make the test key $k"
done
# valid from a minute ago until LIFE seconds from now (absolute, UTC: ssh-keygen's
# relative form has no seconds)
until_ts=$(python3 -c 'import sys,time; print(time.strftime("%Y%m%d%H%M%S", time.gmtime(time.time()+int(sys.argv[1]))))' "$LIFE")
from_ts=$(python3 -c 'import time; print(time.strftime("%Y%m%d%H%M%S", time.gmtime(time.time()-60)))')
ssh-keygen -q -s "$d/ca" -I "person:gh:7" -n "$me" -V "${from_ts}Z:${until_ts}Z" "$d/u.pub" 2>/dev/null \
  || ssh-keygen -q -s "$d/ca" -I "person:gh:7" -n "$me" -V "${from_ts}:${until_ts}" "$d/u.pub" \
  || st_fail setup "ssh-keygen could not sign the short certificate"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
cat > "$d/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $d/hk
PidFile $d/sshd.pid
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AuthorizedKeysFile none
TrustedUserCAKeys $d/ca.pub
AllowUsers $me
ClientAliveInterval 0
LogLevel VERBOSE
EOF
"$SSHD" -D -e -f "$d/sshd_config" 2>>"$d/sshd.log" &
spid=$!
trap 'kill "$spid" 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 50); do
  python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1",int(sys.argv[1])),0.2)' "$port" 2>/dev/null && break
  sleep 0.1
done
sshin() {
  ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR -i "$d/u" \
    -o CertificateFile="$d/u-cert.pub" -p "$port" "$me@127.0.0.1" "$@" </dev/null 2>>"$d/ssh.err"
}
if ! out=$(sshin echo in); then
  grep -qiE 'not permitted|privilege|cannot|fatal' "$d/sshd.log" && ! grep -q 'Accepted' "$d/sshd.log" \
    && { printf 'selftest: the sandbox sshd will not run here (%s) — SKIP\n' "$(tail -1 "$d/sshd.log")" >&2; exit 0; }
  st_fail "live-cert" "a valid certificate did not get in: $(tail -2 "$d/sshd.log" | tr '\n' ' ') $(tail -1 "$d/ssh.err")"
fi
st_eq "live-cert" "in" "$out"
st_ok "a certificate with ${LIFE}s left logs in"

# the session outlives the certificate by 2×LIFE, printing as it goes
hold=$((LIFE * 3))
out=$(sshin "for i in \$(seq $hold); do sleep 1; done; echo still-here")
st_eq "session-outlives-cert" "still-here" "$out" "a session cut when its certificate expired"
st_ok "the session opened on it ran ${hold}s — $((hold - LIFE))s past the certificate's end — and was not cut"

# a NEW login on the expired certificate is refused
if sshin true; then st_fail "expired-cert" "a new login on an expired certificate got in"; fi
grep -qiE 'expired|not yet valid|certificate invalid' "$d/sshd.log" \
  || st_fail "expired-cert" "sshd did not say why it refused: $(tail -2 "$d/sshd.log" | tr '\n' ' ')"
st_ok "a new login on the expired certificate is refused (sshd: expired)"
printf 'PASS %s\n' "${0##*/}"
