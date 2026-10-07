#!/bin/bash
# fleet-peer-cert.sh — ask the hub for a five-minute certificate to reach ONE
# other machine, and print the ssh options that use it (issue #1626, EPIC #1615 C9).
#
#   fleet-peer-cert.sh <machine> <view|upgrade|move>
#
# Machine-to-machine ssh (fleet-remote-view.sh, fleet-node-upgrade.sh --host,
# fleet-move.sh) no longer rides a key the target keeps in authorized_keys
# forever. Each connection asks the hub first, with THIS login's node token
# (node.env, read inside the one subshell that calls the hub — never exported,
# issue #1491): the hub checks the target is the same owner's, signs this
# login's peer key for the owner's login there — valid five minutes, its key id
# naming source, target and purpose — and records the issuance. The target's
# sshd admits it through the CA it already trusts (TrustedUserCAKeys); the
# connection outlives the certificate. No hub nod, no way in.
#
# The key is ~/.ssh/fleet-peer (made once, ed25519, never in anyone's
# authorized_keys); the certificate goes to $FLEET_CONF_DIR/peer/<machine>.<purpose>-cert.pub.
# It is REUSED (issue #1631) until 30 s before it expires: one ask per (source,
# target, purpose) per five minutes, however often the caller reconnects.
#
# stdout on success (exit 0): the ssh options, ONE PER LINE, for the caller to
# read into an array (bash 3.2: `while IFS= read -r o; do a+=("$o"); done`):
#   -i  <key>  -o  CertificateFile=<cert>  -o  IdentitiesOnly=yes  -l  <login>
#
# Exit status (issue #683's convention):
#   0   certificate issued — options on stdout
#   1   PAUSED: the hub was asked and could not be reached, or refused (not the
#       owner's machine, unknown machine) — stderr says which. The caller stops
#       and says so; it never falls back to a standing key (EPIC #1615 decision 14).
#   2   usage
#   3   not applicable — plain ssh as before: this login is not a hub node
#       (no node.env token), the hub predates #1626 or has no CA (404), or
#       FLEET_PEER_CERT=0. Nothing printed on stdout.
#
# A hub that is DOWN is answered within a second (issue #1630): the connect is
# bounded by FLEET_PEER_CERT_CONNECT_SECS (default 0.8) — no 10-second wait, no
# retry — and the refusal names the way round, `fleet <machine>` straight in on
# the operator's own client certificate. The whole request stays bounded by
# FLEET_HUB_TIMEOUT (10) for a hub that answers slowly.
#
# Seams: FLEET_HUB_CURL (default `curl`) is the transport; FLEET_PEER_KEY the
# key path; FLEET_PEER_CERT_SECS the life asked for (default 300 — the hub caps
# it at 300 whatever is asked); FLEET_PEER_CERT_MARGIN how many seconds before
# expiry a cached certificate stops being reused (default 30).
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"
# shellcheck source=fleet-ui-lang.sh
. "$BIN/fleet-ui-lang.sh"

die() { printf 'fleet-peer-cert: %s\n' "$2" >&2; exit "$1"; }

[ $# -eq 2 ] || die 2 'usage: fleet-peer-cert.sh <machine> <view|upgrade|move>'
MACHINE=$1 PURPOSE=$2
SHOWN=${MACHINE##*@}; SHOWN=${SHOWN%%.*}   # the name the operator typed, for the way round
case "$PURPOSE" in view|upgrade|move) ;; *) die 2 "purpose must be view, upgrade or move, not '$PURPOSE'" ;; esac
# An ssh destination is fine: drop a user@, keep the host's first label unless
# it is an address, and turn a local label back into the hub's name
# (FLEET_NODE_ALIASES `macmini=m5`: m5 → macmini).
MACHINE=${MACHINE##*@}
case "$MACHINE" in
  *[!0-9.]*) MACHINE=${MACHINE%%.*} ;;
esac
hub_name=$(printf '%s\n' ${FLEET_NODE_ALIASES:-} | awk -F= -v n="$MACHINE" '$2 == n { print $1; exit }')
MACHINE=${hub_name:-$MACHINE}
# Then the hub's own list (issue #1719): peer/machines, `<hostname> <alias>` per
# line, written by `fleet login` from the hub's answer. The alias, the hostname,
# a route of either (`m4-lan`, the operator's <name>-lan/-ts/-pub) and the
# generated `fleet-<alias>…` names all become the hostname — so `m4`, `m4-lan`
# and `mini2` share ONE certificate file, and the hub is asked by the name it
# knows. The ONE place a typed name becomes a machine: fleet-node-upgrade.sh
# --host, fleet-remote-view.sh and the generated ssh Match blocks all pass
# their name through here.
if [ -r "$FLEET_CONF_DIR/peer/machines" ]; then
  hub_name=$(awk -v n="$MACHINE" '
    NF >= 2 { h = tolower($1); a = tolower($2); m = tolower(n)
      if (m == h || m == a || m == "fleet-" a) { exact = $1; exit }
      if (pre == "" && (index(m, a "-") == 1 || index(m, h "-") == 1 || index(m, "fleet-" a "-") == 1)) pre = $1 }
    END { if (exact != "") print exact; else if (pre != "") print pre }' "$FLEET_CONF_DIR/peer/machines")
  MACHINE=${hub_name:-$MACHINE}
fi
case "$MACHINE" in
  ''|-*|*[!A-Za-z0-9._-]*) die 2 "not a machine name: '$1'" ;;
esac

[ "${FLEET_PEER_CERT:-1}" != 0 ] || exit 3
# Not a hub node: nothing to ask, plain ssh exactly as before.
_fleet_hub_creds_missing >/dev/null && exit 3

KEY=${FLEET_PEER_KEY:-$HOME/.ssh/fleet-peer}
if [ ! -s "$KEY" ] || [ ! -s "$KEY.pub" ]; then
  mkdir -p "$(dirname "$KEY")" && chmod 700 "$(dirname "$KEY")" 2>/dev/null
  rm -f "$KEY" "$KEY.pub"
  ssh-keygen -q -t ed25519 -N '' -C "fleet-peer $(id -un)@$(hostname -s 2>/dev/null)" -f "$KEY" </dev/null >/dev/null 2>&1 \
    || die 1 "cannot make the peer key $KEY (ssh-keygen failed)"
fi
DIR="$FLEET_CONF_DIR/peer"
mkdir -p "$DIR" && chmod 700 "$DIR" 2>/dev/null
CERT="$DIR/$MACHINE.$PURPOSE-cert.pub"

# The cache (issue #1631): one certificate per (source, target, purpose) — this
# login's peer key, $MACHINE, $PURPOSE — reused until FLEET_PEER_CERT_MARGIN (30)
# seconds before it expires, so a reconnect loop or a move's several ssh steps
# ask the hub once per five minutes, not once per connection. <cert>.meta holds
# `<valid-before epoch> <login> <key's public half, as one word>`: a regenerated
# key, a cert written by an older script (no .meta) or one past the margin is a
# miss, asked afresh.
keypub=$(awk '{ print $2; exit }' "$KEY.pub" 2>/dev/null)
if [ -s "$CERT" ] && [ -n "$keypub" ] && read -r m_until m_login m_key 2>/dev/null < "$CERT.meta"; then
  case "$m_until" in ''|*[!0-9]*) m_until=0 ;; esac
  if [ "$m_key" = "$keypub" ] && [ -n "$m_login" ] \
     && [ "$(date +%s)" -lt $(( m_until - ${FLEET_PEER_CERT_MARGIN:-30} )) ]; then
    printf '%s\n' -i "$KEY" -o "CertificateFile=$CERT" -o IdentitiesOnly=yes -l "$m_login"
    exit 0
  fi
fi

body=$(python3 -c 'import json,sys; print(json.dumps({"target":sys.argv[1],"purpose":sys.argv[2],"public_key":open(sys.argv[3]).read().strip(),"ttl_sec":int(sys.argv[4])}))' \
  "$MACHINE" "$PURPOSE" "$KEY.pub" "${FLEET_PEER_CERT_SECS:-300}" 2>/dev/null) \
  || die 2 "FLEET_PEER_CERT_SECS must be a number of seconds"
CURL=${FLEET_HUB_CURL:-curl}
resp=$(_fleet_hub_env
  "$CURL" -sS --connect-timeout "${FLEET_PEER_CERT_CONNECT_SECS:-0.8}" --max-time "${FLEET_HUB_TIMEOUT:-10}" -o - -w '\n%{http_code}' \
    -H "Authorization: Bearer $CCQUOTA_TOKEN" -H 'Content-Type: application/json' \
    -X POST --data-binary "$body" "${CCQUOTA_HUB_URL%/}/v1/node/peer-cert" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -n "$resp" ] || die 1 "$(fleet_ui_t peer_hub_lost_fmt "$SHOWN")（curl exit ${rc}；不退回长期互信）"
code=$(printf '%s\n' "$resp" | tail -n 1)
json=$(printf '%s\n' "$resp" | sed '$d')
case "$code" in
  200) ;;
  404|405) printf 'fleet-peer-cert: the hub issues no machine-to-machine certificate (it predates #1626, or has no CA) — plain ssh\n' >&2; exit 3 ;;
  401) case "$json" in
         *'viewer token'*) printf 'fleet-peer-cert: the hub has no /v1/node/peer-cert (it predates #1626) — plain ssh\n' >&2; exit 3 ;;
       esac
       die 1 "入口不认这台机器的节点令牌（401）：re-join with fleet-node-join.sh, or fleet-hub-node.sh env --write" ;;
  *) die 1 "入口拒绝了到 $MACHINE 的访问（HTTP ${code}）：$(printf '%s' "$json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("error",""))
except Exception: print("")' 2>/dev/null | head -c 300)" ;;
esac

login=$(printf '%s' "$json" | FLEET_ISO_BIN="$BIN" python3 -c '
import json, os, re, sys, time
d = json.load(sys.stdin)
cert, login = d.get("certificate", ""), d.get("login", "")
if not cert.startswith("ssh-") or not login or any(c in login for c in " \t\n/"):
    sys.exit(1)
tmp = sys.argv[1] + ".tmp.%d" % os.getpid()
with open(tmp, "w") as f:
    f.write(cert)
os.chmod(tmp, 0o600)
os.rename(tmp, sys.argv[1])
# when it stops working: valid_before, else now + ttl_sec, else now + what was asked
until = 0
try:
    vb = str(d.get("valid_before") or "")
    if vb:
        sys.path.insert(0, os.environ.get("FLEET_ISO_BIN") or ".")
        import fleet_iso  # the one ISO reader (issue #2024)
        until = int(fleet_iso.parse(vb).timestamp())
except Exception:
    until = 0
if until <= 0:
    try:
        until = int(time.time()) + int(d.get("ttl_sec") or sys.argv[3])
    except (TypeError, ValueError):
        until = 0
meta = sys.argv[1] + ".meta"
if until > 0 and sys.argv[2]:
    with open(meta + ".tmp", "w") as f:
        f.write("%d %s %s\n" % (until, login, sys.argv[2]))
    os.rename(meta + ".tmp", meta)
else:
    try:
        os.unlink(meta)
    except OSError:
        pass
print(login)
' "$CERT" "$keypub" "${FLEET_PEER_CERT_SECS:-300}") || die 1 "the hub's answer carries no certificate"

printf '%s\n' -i "$KEY" -o "CertificateFile=$CERT" -o IdentitiesOnly=yes -l "$login"
