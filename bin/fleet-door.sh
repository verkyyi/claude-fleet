#!/bin/bash
# fleet-door.sh — the cluster's one door's ForceCommand (issue #3549, EPIC #3500
# C4). sshd ran it as the door account it let in — so with one of THAT person's
# own keys (the hub's list, fleet-node-supervisor.py's door mode). It reads the
# login's ONE pod from the door's book (root's 0644 state.json, written from
# GET /v1/node/entry-routes: login → u-<nonce>) and hands the connection to it,
# with the door's own key — the only key a user pod's sshd takes:
#
#   ssh <login>@u-<nonce>.<namespace>.svc.cluster.local   (port 22)
#
# Nothing the person sends picks the pod: the login sshd authenticated does, and
# a login the book does not route (none, or one two pods claim — the hub routes
# neither) goes nowhere. What they asked for goes on as it came: a command
# (SSH_ORIGINAL_COMMAND — sftp too) as the pod's own command, a terminal as a
# terminal; on the pod, bin/fleet-entry.sh dispatches it as a home's entry port
# does (no command on a terminal is the 看台). The person's key fingerprint, its
# label and their address ride along as FLEET_DOOR_* (the pod's sshd accepts them
# from the door's key alone), the client's LANG / LC_* as they arrived.
#
# Each arrival is the door sshd's own log line (accepted, with the key's
# fingerprint and the source) — the supervisor's entry audit sends it to the hub;
# nothing here writes a log a door account could reach.
set -u
LOGIN="$(id -un 2>/dev/null)"
BOOK="${FLEET_ENTRY_BOOK:-}"
KEY="${FLEET_DOOR_KEY:-}"
NS="${FLEET_DOOR_NAMESPACE:-fleet-workers}"
CMD="${SSH_ORIGINAL_COMMAND-}"
SRC="${SSH_CONNECTION%% *}"

say() { printf 'fleet-door: %s\n' "$*" >&2; }

# the key this connection logged in with (ExposeAuthInfo): `publickey <type> <b64>`
FP=""
if [ -n "${SSH_USER_AUTH:-}" ] && [ -r "$SSH_USER_AUTH" ]; then
  FP=$(awk '$1 == "publickey" { print $2 " " $3; exit }' "$SSH_USER_AUTH" 2>/dev/null \
    | ssh-keygen -l -f /dev/stdin 2>/dev/null | awk '{ print $2; exit }')
fi

# the login's pod and the key's label, from the book alone
DOOR_PY='
import base64, json, re, sys
book, login, fp = sys.argv[1:4]
try:
    ent = (json.load(open(book)).get("logins") or {}).get(login) or {}
except Exception:
    ent = {}
svc = str(ent.get("service") or "")
if not re.match(r"^u-[a-z0-9]{4,20}$", svc):
    sys.exit(1)
name = str((ent.get("names") or {}).get(fp) or "")
print(svc, base64.b64encode(name.encode("utf-8")).decode() or "-")
'
OUT=$(python3 -I -c "$DOOR_PY" "$BOOK" "$LOGIN" "$FP" 2>/dev/null) || OUT=""
SVC=${OUT%% *}
NAME=${OUT#* }
[ "$NAME" = "-" ] && NAME=""
case "$SVC" in
  u-[a-z0-9][a-z0-9][a-z0-9][a-z0-9]*) ;;
  *) say "${LOGIN} 在这扇门后没有自己的 pod（入口的表里没有它）"; exit 1 ;;
esac
case "$SVC$NAME$FP$SRC" in *[!A-Za-z0-9+/=:.-]*) say "refused: a malformed route"; exit 1 ;; esac
[ -n "$KEY" ] && [ -r "$KEY" ] || { say "门的钥匙不在（${KEY:-unset}）"; exit 1; }

HOST="$SVC.$NS.svc.cluster.local"
PORT=22
# the drill's seam (FLEET_NODE_TEST only): the "pod" is a local sshd
# (FLEET_DOOR_TEST_TARGETS: u-<nonce>=127.0.0.1:<port>,…), the route still the book's
if [ "${FLEET_NODE_TEST:-}" = 1 ] && [ -n "${FLEET_DOOR_TEST_TARGETS:-}" ]; then
  T=$(printf '%s\n' "$FLEET_DOOR_TEST_TARGETS" | tr ',' '\n' | awk -F= -v s="$SVC" '$1 == s { print $2; exit }')
  [ -n "$T" ] || { say "drill: no stand-in for ${SVC}"; exit 1; }
  HOST="${T%:*}"
  PORT="${T##*:}"
fi

TTY=-T
[ -n "${SSH_TTY:-}" ] && TTY=-tt
set -- -F /dev/null -i "$KEY" -p "$PORT" -l "$LOGIN" "$TTY" \
  -o IdentityAgent=none -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -o ClearAllForwardings=yes -o ForwardAgent=no -o ForwardX11=no \
  -o 'SendEnv=LANG LC_*' \
  -o "SetEnv=FLEET_DOOR_FP=${FP} FLEET_DOOR_SRC=${SRC} FLEET_DOOR_NAME=${NAME}" \
  "$HOST"
if [ -n "$CMD" ]; then
  exec ssh "$@" -- "$CMD"
fi
exec ssh "$@"
