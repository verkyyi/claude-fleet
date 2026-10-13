#!/bin/bash
# fleet-move-to-pod.sh — move one person's login off a shared Linux node into a
# pod of their own, their home, number and sessions as they were, in one stop
# (issue #3554, EPIC #3500 C10).
#
#   fleet-move-to-pod.sh <phase> <login> --principal <id> [options] [-- <render.py args>]
#
# Phases, in order (`all` = check … verify; each one may be run again):
#   check    the source declares <login> and nothing else of the move is half-done;
#            prints its UID, home size, sessions and whether anyone is attached
#   prepare  the pod's disk, Service and machine join Secret, and a seeder pod on the
#            disk — the person's pod is not started yet (nothing they use changes)
#   stop     ── the one interruption starts ── refused while a client is attached;
#            `fleet-node-linux.py login stop <login>` on the source: sessions
#            pinned, the daemon lets go, its processes stop; home kept
#   copy     the home, tar pod to pod inside the cluster (the seeder pulls from
#            the source with a one-time token; numeric owners, the UID kept),
#            then the shared-node-only files cleared (node.env · node.pub.env ·
#            credsep.json); file counts compared
#   start    the seeder goes, the person's pod is applied and waited for
#   open     the hub opens <login> on the pod (`fleet hub accounts assign --own-name`,
#            pod_login_open: its token, `credsep: central`) — after the source
#            machine's credential allow-list is copied to the pod and read back
#   home     the person's home (the door's table, their name) moves to the pod
#            ── the interruption ends ──
#   verify   every pinned session of the source is a window on the pod
#   retire   (after acceptance, never in `all`) the hub closes the source login
#            (`accounts remove --delete`: its home archived in the source's attic)
#
# Options:
#   --principal <id>   the hub's person (gh:<n>) — required
#   --pod u-<nonce>    the pod's name; default: the one `prepare` picked
#   --source <pod>     the shared node's pod it leaves — required
#   --source-machine <name>  the hub's name for it (default: --source)
#   --ns <namespace>   default fleet-workers
#   --allow-list-none  move a login whose source machine has no subscription
#                      allow-list (default: refuse — the pod would be open)
#   --limits <text>    the pod's ceiling (render.py --limits; default the template's)
#   --hub <url>        default $FLEET_HUB_URL
#   -- <args>          handed to extras/managed-node/render.py (--image, --hub,
#                      --storage-class, --cred-central, --egress-proxy, …); the script
#                      adds --user-pod, --login, --uid, --limits
#
# Who runs it: someone holding the cluster (KUBECONFIG, admin) and the hub's
# operator token (CCQUOTA_VIEWER_TOKEN, read at start, never written down). Each
# phase appends `<UTC> <phase> <word>` to the timeline in the state dir
# ($FLEET_MOVE_STATE, default ~/.local/state/fleet-move-to-pod/<login>/), which
# also keeps the pod name and the rendered manifest (no secret: the join code
# goes straight into its Secret on kubectl's stdin).
#
# Back out before `home`: `kubectl exec <source> -c fleet -- env
# FLEET_LOGIN_OP_ID=<op> python3 …/fleet-node-linux.py login open <login>` (the
# line `stop` printed) brings the login back on the source; delete the u-<nonce>
# objects. Nothing of the source's home is changed before `retire`.
#
# Exit: 0 done · 1 a step failed (stderr says which; run the phase again) ·
# 2 usage · 3 refused (someone attached, a phase out of order, a name taken)
#
# Seams: FLEET_MOVE_KUBECTL (default kubectl), FLEET_MOVE_HUB_ADMIN (default
# python3 fleet-hub-admin.py), FLEET_MOVE_CRED_POLICY (default
# fleet-cred-policy.sh), FLEET_HUB_CURL (default curl), FLEET_MOVE_WAIT
# (seconds a wait lasts, default 600).
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"

die() { printf 'fleet-move-to-pod: %s\n' "$2" >&2; exit "$1"; }
usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; }
say() { printf '%s\n' "$*"; }

PHASE='' LOGIN='' PRINCIPAL='' POD='' SOURCE='' SRC_MACHINE='' ALLOW_NONE=0 NS=fleet-workers LIMITS=''
HUB=${FLEET_HUB_URL:-}
RENDER=()
while [ $# -gt 0 ]; do
  case "$1" in
    --principal) PRINCIPAL=${2:-}; shift 2 ;;
    --pod) POD=${2:-}; shift 2 ;;
    --source) SOURCE=${2:-}; shift 2 ;;
    --source-machine) SRC_MACHINE=${2:-}; shift 2 ;;
    --ns) NS=${2:-}; shift 2 ;;
    --limits) LIMITS=${2:-}; shift 2 ;;
    --allow-list-none) ALLOW_NONE=1; shift ;;
    --hub) HUB=${2:-}; shift 2 ;;
    --) shift; RENDER=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die 2 "unknown option '$1'" ;;
    *) if [ -z "$PHASE" ]; then PHASE=$1; elif [ -z "$LOGIN" ]; then LOGIN=$1; else die 2 "one login only"; fi; shift ;;
  esac
done
case "$PHASE" in
  check|prepare|stop|copy|start|open|home|verify|retire|all) ;;
  *) usage >&2; die 2 'say a phase: check prepare stop copy start open home verify retire all' ;;
esac
[[ "$LOGIN" =~ ^[a-z0-9]{2,16}$ ]] || die 2 "a login of 2-16 a-z0-9 (got '$LOGIN')"
[ -n "$PRINCIPAL" ] || die 2 '--principal <id> (the hub person, gh:<n>)'
[[ "$SOURCE" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || die 2 '--source <pod> (the shared node it leaves)'
[ -z "$POD" ] || [[ "$POD" =~ ^u-[a-z0-9]{4,20}$ ]] || die 2 "--pod is u-<4-20 of a-z0-9> (got '$POD')"
SRC_MACHINE=${SRC_MACHINE:-$SOURCE}

STATE=${FLEET_MOVE_STATE:-$HOME/.local/state/fleet-move-to-pod}/$LOGIN
mkdir -p "$STATE" && chmod 700 "$STATE" || die 1 "cannot write $STATE"
TIMELINE=$STATE/timeline
WAIT=${FLEET_MOVE_WAIT:-600}
read -r -a KC <<< "${FLEET_MOVE_KUBECTL:-kubectl}"
read -r -a HUBADM <<< "${FLEET_MOVE_HUB_ADMIN:-python3 $BIN/fleet-hub-admin.py}"
read -r -a CREDPOL <<< "${FLEET_MOVE_CRED_POLICY:-$BIN/fleet-cred-policy.sh}"
CURL=${FLEET_HUB_CURL:-curl}

mark() { printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$TIMELINE"; say "== $1: $2"; }
kc() { ${KC[@]+"${KC[@]}"} -n "$NS" "$@"; }
hubadm() { ${HUBADM[@]+"${HUBADM[@]}"} ${HUB:+--hub "$HUB"} "$@"; }
credpol() { env ${HUB:+CCQUOTA_HUB_URL="$HUB"} ${CREDPOL[@]+"${CREDPOL[@]}"} "$@"; }
# node_allow <machine>: its subscription allow-list as cred-policy's own verb —
# `all`, `deny`, `set <id>…` — or nothing when it has none; rc 1 unreadable
node_allow() {
  credpol show --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for s in d.get("nodes") or []:
    if s.get("id") != sys.argv[1]:
        continue
    if s.get("error"):
        sys.exit(1)
    a = s.get("allow")
    print("all" if s.get("all") else "deny" if a == [] else "set " + " ".join(a) if a else "")
' "$1"
}
src() { kc exec "$SOURCE" -c fleet -- "$@"; }

[ -n "$POD" ] || POD=$(cat "$STATE/pod" 2>/dev/null || true)
need_pod() { [ -n "$POD" ] || die 3 "no pod yet: run prepare (or name it with --pod)"; }
SEEDER() { printf '%s-seed' "$POD"; }

# the login's declaration on the source: uid and op (json on one line)
decl() {
  src cat "/var/db/fleet-node/linux-tenants/$LOGIN.json" 2>/dev/null
}
decl_field() {
  printf '%s' "$1" | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1], ""); print(v)' "$2"
}

# attached: tmux clients on any of the login's servers on the source
attached() {
  local uid=$1
  src sh -c 'n=0; for s in /tmp/tmux-'"$uid"'/*; do [ -S "$s" ] || continue
      c=$(su -s /bin/sh "$1" -c "tmux -S \"$s\" list-clients 2>/dev/null" | wc -l); n=$((n+c)); done; echo $n' _ "$LOGIN"
}

# the pinned sessions of the source snapshot: "<fleet_id> <key>" per line
pinned() {
  src sh -c 'f=/home/$1/.config/claude-fleet/global/sessions.snapshot
    [ -f "$f" ] && awk -F"\t" '\''!/^#/ && NF>=6 {print $6" "$2}'\'' "$f"' _ "$LOGIN"
}

hub_req() {   # hub_req <method> <path> [json] → the body on stdout; rc 1 on non-2xx
  local out code
  [ -n "${CCQUOTA_VIEWER_TOKEN:-}" ] || die 1 'CCQUOTA_VIEWER_TOKEN (the operator token) is not in the environment'
  [ -n "$HUB" ] || die 1 'no hub: --hub or FLEET_HUB_URL'
  out=$(mktemp) || return 1
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$CCQUOTA_VIEWER_TOKEN" |
    "$CURL" -sS --max-time 30 -K - -X "$1" -H 'Content-Type: application/json' \
      -o "$out" -w '%{http_code}' ${3:+--data "$3"} "$HUB$2") || code=000
  cat "$out"; rm -f "$out"
  case "$code" in 2??) return 0 ;; *) printf 'fleet-move-to-pod: hub %s %s → HTTP %s\n' "$1" "$2" "$code" >&2; return 1 ;; esac
}

account_state() {   # the principal's account state on host, or ""
  hubadm accounts list --json 2>/dev/null | python3 -c '
import json, sys
p, h = sys.argv[1], sys.argv[2]
for a in (json.load(sys.stdin).get("accounts") or []):
    if a.get("principal_id") == p and a.get("hostname", "").split(".")[0] == h:
        print(a.get("state", "")); break' "$PRINCIPAL" "$1"
}

wait_for() {   # wait_for <what> <cmd…>: until cmd succeeds, at most $WAIT seconds
  local what=$1 end=$((SECONDS + WAIT)); shift
  until "$@"; do
    [ "$SECONDS" -lt "$end" ] || { printf 'fleet-move-to-pod: %s: not within %ss\n' "$what" "$WAIT" >&2; return 1; }
    sleep 5
  done
}

phase_check() {
  local d uid n
  d=$(decl) || die 1 "$SOURCE declares no login $LOGIN (or the source is unreachable)"
  uid=$(decl_field "$d" uid); [[ "$uid" =~ ^[0-9]+$ ]] || die 1 "no uid in $LOGIN's declaration"
  printf '%s\n' "$uid" > "$STATE/uid"
  decl_field "$d" op > "$STATE/op"
  say "login $LOGIN · UID $uid · on $SOURCE ($SRC_MACHINE)"
  src du -sh "/home/$LOGIN" | sed 's/^/home: /'
  local other; other=$(src find "/home/$LOGIN" -xdev ! -uid "$uid" | head -5)
  [ -z "$other" ] || say "WARN files not $LOGIN's (they move with root's owner): $other"
  n=$(pinned | wc -l | tr -d ' '); say "pinned sessions: $n"; pinned | sed 's/^/  /'
  say "attached clients: $(attached "$uid")"
  if [ -n "$POD" ] && kc get deploy "$POD" >/dev/null 2>&1; then say "pod $POD: Deployment exists"; fi
  mark check "uid=$uid sessions=$n"
}

render_pod() {
  local uid; uid=$(cat "$STATE/uid")
  python3 "$ROOT/extras/managed-node/render.py" ${RENDER[@]+"${RENDER[@]}"} --namespace "$NS" \
    --user-pod "$POD" --login "$LOGIN" --uid "$uid" ${LIMITS:+--limits "$LIMITS"} > "$STATE/render.json.tmp" &&
    mv "$STATE/render.json.tmp" "$STATE/render.json"
}
# render_kind <Kind…>: the rendered List with only those kinds
render_kind() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["items"]=[i for i in d["items"] if i["kind"] in sys.argv[2:]]; print(json.dumps(d))' \
    "$STATE/render.json" "$@"
}

phase_prepare() {
  [ -s "$STATE/uid" ] || phase_check
  if [ -z "$POD" ]; then
    POD="u-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 10)"
  fi
  printf '%s\n' "$POD" > "$STATE/pod"
  render_pod || die 1 "render.py refused (its line above)"
  local uid image; uid=$(cat "$STATE/uid")
  image=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
print([i for i in d["items"] if i["kind"]=="Deployment"][0]["spec"]["template"]["spec"]["containers"][0]["image"])' "$STATE/render.json")
  render_kind PersistentVolumeClaim Service | kc apply -f - || die 1 "applying $POD's disk and Service failed"
  if ! kc get secret "$POD-join" >/dev/null 2>&1; then
    local code
    code=$(hub_req POST /v1/fleet/nodes/join-codes "{\"label\":\"pod-$POD\"}" |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["code"])') || die 1 'the hub minted no machine join code'
    printf '%s' "$code" | kc create secret generic "$POD-join" --from-file=machine=/dev/stdin >/dev/null ||
      die 1 "the join Secret $POD-join was not written"
    unset code
  fi
  # the seeder: the disk alone, as the login, nothing else (no token, no caps)
  python3 - "$(SEEDER)" "$POD" "$uid" "$image" "$STATE/render.json" <<'PY' | kc apply -f - || die 1 'the seeder pod was not applied'
import json, sys
name, pod, uid, image, render = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
dep = [i for i in json.load(open(render))['items'] if i['kind'] == 'Deployment'][0]['spec']['template']['spec']
print(json.dumps({'apiVersion': 'v1', 'kind': 'Pod',
  'metadata': {'name': name, 'labels': {'fleet/role': 'move', 'fleet/move-to': pod}},
  'spec': {'restartPolicy': 'Never', 'automountServiceAccountToken': False,
           'serviceAccountName': dep.get('serviceAccountName', 'default'),
           'imagePullSecrets': dep.get('imagePullSecrets', []),
           'securityContext': {'runAsUser': uid, 'runAsGroup': uid, 'fsGroup': uid, 'runAsNonRoot': True,
                               'seccompProfile': {'type': 'RuntimeDefault'}},
           'containers': [{'name': 'seed', 'image': image, 'command': ['sleep', '86400'],
                           'securityContext': {'allowPrivilegeEscalation': False,
                                               'capabilities': {'drop': ['ALL']}},
                           'resources': {'requests': {'cpu': '50m', 'memory': '64Mi'},
                                         'limits': {'cpu': '1', 'memory': '512Mi'}},
                           'volumeMounts': [{'name': 'data', 'mountPath': '/data'}]}],
           'volumes': [{'name': 'data', 'persistentVolumeClaim': {'claimName': pod}}]}}))
PY
  kc wait --for=condition=Ready "pod/$(SEEDER)" --timeout="${WAIT}s" >/dev/null || die 1 "seeder $(SEEDER) not Ready"
  mark prepare "pod=$POD"
}

phase_stop() {
  need_pod
  local uid n; uid=$(cat "$STATE/uid" 2>/dev/null) || die 3 'run check first'
  n=$(attached "$uid")
  [ "$n" = 0 ] || die 3 "$LOGIN has $n client(s) attached on $SOURCE — wait until nobody is, then run stop again"
  kc get "pod/$(SEEDER)" >/dev/null 2>&1 || die 3 "no seeder: run prepare first"
  mark stop begin
  src python3 -I /var/db/fleet-node/runtime/current/bin/fleet-node-linux.py login stop "$LOGIN" 2>&1 |
    tee "$STATE/stop.out"
  [ "${PIPESTATUS[0]}" = 0 ] || die 1 "login stop on $SOURCE failed (above); nothing copied"
  # read AFTER the stop: its snapshot save is what pins the sessions (check's
  # count predates it — a login that never saved one reads 0 there)
  pinned > "$STATE/pinned"
  mark stop "sessions=$(wc -l < "$STATE/pinned" | tr -d ' ')"
}

# the excluded paths: throwaway trees whose links point into the source's runtime
EXCL=(--exclude="$LOGIN/.codex/tmp" --exclude="$LOGIN/.config/claude-fleet/cred-proxy/codex-homes")

# The copy never leaves the cluster (issue #3554: 387 MB of a drill's home
# through the API server from the operator's machine broke 4 times out of 4;
# a real home is 3.8 GB). The source's egress guard rejects pod addresses, so the
# SEEDER pulls: the source listens once on its pod IP for one connection that
# first sends a one-time token (written into the script on kubectl's stdin, never
# an argv), and streams the tar into it; both halves run detached and each
# leaves its exit code in a file the phase polls. No byte of the home passes
# through this machine; a failed run starts over from an empty directory.
SEND_PY='
import hmac, os, socket, subprocess, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((IP, PORT)); s.listen(1); s.settimeout(WAIT)
try:
    os.unlink(RC)
except OSError:
    pass
if os.fork():
    print("listening %s:%d" % (IP, PORT)); sys.exit(0)
os.setsid()
fd = os.open(os.devnull, os.O_RDWR)
for n in (0, 1, 2):
    os.dup2(fd, n)
rc = "timeout"
try:
    c, _ = s.accept(); s.close()
    c.settimeout(30); got = b""
    while len(got) < len(TOKEN):
        b = c.recv(len(TOKEN) - len(got))
        if not b:
            break
        got += b
    if not hmac.compare_digest(got, TOKEN):
        rc = "badtoken"
    else:
        c.settimeout(None)
        rc = str(subprocess.call(["tar", "-C", "/home", "--numeric-owner"] + EXCL + ["-cpf", "-", LOGIN], stdout=c.fileno()))
    c.shutdown(socket.SHUT_WR); c.close()
except Exception as e:
    rc = "error: %s" % e
open(RC + ".tmp", "w").write(rc + "\n"); os.rename(RC + ".tmp", RC)
'
RECV_PY='
import os, socket, subprocess, sys
try:
    os.unlink(RC)
except OSError:
    pass
if os.fork():
    sys.exit(0)
os.setsid()
fd = os.open(os.devnull, os.O_RDWR)
for n in (0, 1, 2):
    os.dup2(fd, n)
try:
    c = socket.create_connection((IP, PORT), 30); c.sendall(TOKEN); c.settimeout(None)
    rc = str(subprocess.call(["tar", "-C", "/data/homes", "--numeric-owner", "-xpf", "-"], stdin=c.fileno()))
    c.close()
except Exception as e:
    rc = "error: %s" % e
open(RC + ".tmp", "w").write(rc + "\n"); os.rename(RC + ".tmp", RC)
'
SEND_RC=/tmp/.fleet-move-send.rc RECV_RC=/data/.fleet-move-recv.rc

# rc_of <pod> [-c <container>] <file>: the half's exit code once it wrote one, else ""
rc_of() { local f=${*: -1}; kc exec "${@:1:$#-1}" -- cat "$f" 2>/dev/null | head -n 1; }

phase_copy() {
  need_pod
  [ -s "$STATE/stop.out" ] || die 3 'stop has not run: the home would be copied while it changes'
  mark copy begin
  kc exec "$(SEEDER)" -- mkdir -p /data/homes || die 1 'no /data/homes on the seeder'
  # a second run starts clean: whatever an interrupted one left goes first
  kc exec "$(SEEDER)" -- rm -rf "/data/homes/$LOGIN" || die 1 'cannot clear an earlier partial copy'
  local ip port tok excl a b src_rc dst_rc end
  ip=$(kc get pod "$SOURCE" -o jsonpath='{.status.podIP}') && [ -n "$ip" ] || die 1 "no pod IP for $SOURCE"
  port=$((20000 + RANDOM % 20000))
  tok=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 32)
  excl=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' ${EXCL[@]+"${EXCL[@]}"})
  { printf 'IP="%s"\nPORT=%d\nTOKEN=b"%s"\nLOGIN="%s"\nEXCL=%s\nRC="%s"\nWAIT=%d\n' \
      "$ip" "$port" "$tok" "$LOGIN" "$excl" "$SEND_RC" "$WAIT"; printf '%s' "$SEND_PY"; } |
    kc exec -i "$SOURCE" -c fleet -- python3 - || die 1 "the source would not listen on $ip:$port"
  { printf 'IP="%s"\nPORT=%d\nTOKEN=b"%s"\nRC="%s"\n' "$ip" "$port" "$tok" "$RECV_RC"; printf '%s' "$RECV_PY"; } |
    kc exec -i "$(SEEDER)" -- python3 - || die 1 'the seeder would not start its half'
  unset tok
  end=$((SECONDS + WAIT))
  until src_rc=$(rc_of "$SOURCE" -c fleet "$SEND_RC") && dst_rc=$(rc_of "$(SEEDER)" "$RECV_RC") &&
        [ -n "$src_rc" ] && [ -n "$dst_rc" ]; do
    [ "$SECONDS" -lt "$end" ] || die 1 "copy not done within ${WAIT}s (source: ${src_rc:-running}, pod: ${dst_rc:-running}); run copy again"
    sleep 5
  done
  [ "$src_rc" = 0 ] && [ "$dst_rc" = 0 ] || die 1 "copy failed (source tar: $src_rc · pod tar: $dst_rc); run copy again"
  # what only a shared node has: its credential store link and record
  kc exec "$(SEEDER)" -- rm -f "/data/homes/$LOGIN/.config/claude-fleet/node.env" \
    "/data/homes/$LOGIN/.config/claude-fleet/node.pub.env" "/data/homes/$LOGIN/.config/claude-fleet/credsep.json" \
    "$RECV_RC" || die 1 'clearing the shared-node files failed'
  a=$(src sh -c 'cd /home && find "$1" -xdev ! -path "$1/.codex/tmp*" ! -path "$1/.config/claude-fleet/cred-proxy/codex-homes*" | wc -l' _ "$LOGIN")
  b=$(kc exec "$(SEEDER)" -- sh -c 'cd /data/homes && find "$1" | wc -l' _ "$LOGIN")
  # the three cleared files are the only difference allowed
  [ $((a - b)) -ge 0 ] && [ $((a - b)) -le 3 ] || die 1 "file counts differ: $SOURCE $a, pod disk $b"
  mark copy "files=$b"
}

pod_ready() { [ "$(kc get deploy "$POD" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ]; }

phase_start() {
  need_pod
  grep -q ' copy files=' "$TIMELINE" 2>/dev/null || die 3 'copy has not finished: the pod would start on an empty home'
  [ -f "$STATE/render.json" ] || render_pod || die 1 'render.py refused'
  kc delete pod "$(SEEDER)" --wait=true --ignore-not-found >/dev/null || die 1 "the seeder did not let go of the disk"
  render_kind Deployment | kc apply -f - || die 1 "applying $POD's Deployment failed"
  mark start applied
  wait_for "$POD Ready" pod_ready || die 1 "$POD is not Ready (kubectl -n $NS logs deploy/$POD -c fleet)"
  mark start ready
}

acct_active() { [ "$(account_state "$POD")" = active ]; }

phase_open() {
  need_pod
  pod_ready || die 3 "$POD is not Ready: run start"
  # the machine's subscription allow-list (the hub's cred-policy, scope node)
  # is the source's, set BEFORE the login exists there: a machine with no list
  # is an open one, and the restored sessions ask for credentials at once
  local allow got ids
  allow=$(node_allow "$SRC_MACHINE") || die 1 "could not read $SRC_MACHINE's allow-list (fleet-cred-policy.sh show)"
  if [ -z "$allow" ]; then
    [ "$ALLOW_NONE" = 1 ] || die 3 "$SRC_MACHINE has no subscription allow-list: the pod would be open to every subscription (--allow-list-none to move anyway)"
  else
    # --force: the pod has no list yet, so the hub reads a narrowing as taking
    # a provider away — the source's own list is exactly what is meant
    case "$allow" in
      set\ *) read -r -a ids <<< "${allow#set }"; credpol set --force node "$POD" ${ids[@]+"${ids[@]}"} >/dev/null ;;
      *) credpol "$allow" node "$POD" >/dev/null ;;
    esac || die 1 "could not copy the credential allow-list ($allow) to $POD"
    got=$(node_allow "$POD") || got='(unreadable)'
    [ "$got" = "$allow" ] || die 1 "the allow-list on $POD reads '$got', not the source's '$allow'"
  fi
  if ! acct_active; then
    hubadm accounts assign "$PRINCIPAL" --host "$POD" --login "$LOGIN" --own-name ||
      die 1 "the hub would not open $LOGIN on $POD"
    wait_for "$LOGIN active on $POD" acct_active || die 1 "$LOGIN is not active on $POD (fleet hub accounts)"
  fi
  mark open "active allow=${allow:-none}"
}

phase_home() {
  need_pod
  acct_active || die 3 "$LOGIN is not active on $POD: run open"
  hub_req PUT "/v1/fleet/entry/home?principal=$PRINCIPAL" "{\"machine\":\"$POD\",\"login\":\"$LOGIN\"}" >/dev/null ||
    die 1 "the hub would not move $PRINCIPAL's home to $POD"
  mark home "$POD"
}

phase_verify() {
  need_pod
  local missing=0 fid key want
  [ -s "$STATE/pinned" ] || pinned > "$STATE/pinned" 2>/dev/null || true
  want=$(wc -l < "$STATE/pinned" | tr -d ' ')
  local have
  have=$(kc exec "deploy/$POD" -c fleet -- sh -c 'for s in /tmp/tmux-$(id -u)/*; do [ -S "$s" ] &&
      tmux -S "$s" list-windows -a -F "#{@fleet_id} #{window_name} #{@pin}" 2>/dev/null; done' | sort -u)  # view-ok: runs in the pod (no fleet-lib there); sort -u drops a view session's duplicate rows
  while read -r fid key; do
    [ -n "$fid" ] || continue
    if printf '%s\n' "$have" | awk -v f="$fid" '$1 == f {ok=1} END {exit !ok}'; then
      say "  back: $key"
    elif [ "$key" = guide ] && printf '%s\n' "$have" | awk '$2 == "guide" && $3 == 1 {ok=1} END {exit !ok}'; then
      # the onboarding guide of a login that never finished it is reopened by the
      # fleet itself (fleet_guide_open) as a NEW pinned window — same guide, new id
      say "  back: guide (reopened by onboarding)"
    else
      say "  MISSING: $key ($fid)"; missing=$((missing + 1))
    fi
  done < "$STATE/pinned"
  mark verify "sessions=$((want - missing))/$want"
  [ "$missing" = 0 ] || die 1 "$missing pinned session(s) did not come back on $POD"
}

phase_retire() {
  need_pod
  grep -q ' verify sessions=' "$TIMELINE" 2>/dev/null || die 3 'verify has not run: retire only after the move is accepted'
  hubadm accounts remove "$PRINCIPAL" --host "$SRC_MACHINE" --delete ||
    die 1 "the hub would not close $LOGIN on $SRC_MACHINE"
  mark retire "$SRC_MACHINE"
}

case "$PHASE" in
  all) for p in check prepare stop copy start open home verify; do "phase_$p"; done ;;
  *) "phase_$PHASE" ;;
esac
say "timeline: $TIMELINE"
