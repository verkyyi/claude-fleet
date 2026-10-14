#!/bin/bash
# fleet-cn-probe-env.sh ensure|status [--repo owner/name] [--stable <sha>] [--dry-run]
#   — keep the China probe's test road standing by itself (issue #4180): the test
#     login on the China client, its drill person on the hub, and the test pod.
#
# bin/fleet-cn-probe.sh walks a real person's road; this keeps that person there
# without anyone remaking it by hand. Same knobs as the probe (FLEET_CN_PROBE_CLIENT
# · _KEY · _KNOWN_HOSTS · _LOGIN · _MACHINE · _KUBECTL · _DOOR_NS), plus:
#
#   client    the login exists on the client box and has `fleet` — else
#             `useradd -m` (root on the client) and the hub's own install line
#             (`curl -fsSL <hub>/install | sh`, as the login), the way a person does
#   identity  `fleet connect --cert-check` passes and the hub lists the machine for
#             the login — else the drill person is made again: `fleet drill invite
#             --login <login> --home <machine> --ttl 24h` (this computer's admin
#             certificate signs it — the hub's cap on a drill person is 24 h, so it
#             IS re-made about once a day: the expiry deletes the person and the
#             login the hub opened on the pod, the invite opens it again), then
#             `fleet login` on the client, confirmed by the invite's one-time
#             approve code (`fleet drill approve`, the code in the environment, never
#             printed), then waits ≤ FLEET_CN_PROBE_ENSURE_WAIT s (300) for the hub to
#             list the pod again
#   pod       the test pod's Deployment runs stable's node image: the `node image`
#             commit status the release train's node-image job leaves on the commit
#             it built (its description `<repo>@sha256:…`) — different ⇒ `kubectl set
#             image` on every container of the test pod alone (it was made by hand,
#             outside the provisioner, so nobody else rolls it), then its rollout.
#             No Deployment ⇒ FLEET_CN_PROBE_POD_MANIFEST (the render.py manifest it
#             was made from — `render.py --user-pod`, kept on this computer, never in
#             the repo) is applied with that image; no manifest ⇒ said, not made.
#             No status on stable (a train before #4180) ⇒ the pod is left as it is.
#
# Prints one `ENSURE <part> ok|made|rolled|fail|skip <detail>` line per part.
# status: only reads — what ensure would do. --dry-run: the same.
# Exit 0 every part ok / repaired · 1 a part failed · 2 usage.
# Nothing is ever printed of a credential: the approve code stays in a variable,
# the install line carries no token.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

CLIENT=${FLEET_CN_PROBE_CLIENT:-root@47.119.157.4}
KEY=${FLEET_CN_PROBE_KEY:-$HOME/fleet-secrets/oss-drill/id_oss_drill}
KH=${FLEET_CN_PROBE_KNOWN_HOSTS:-$HOME/fleet-secrets/oss-drill/known_hosts}
AS=${FLEET_CN_PROBE_LOGIN:-drillcn}
MACHINE=${FLEET_CN_PROBE_MACHINE:-u-drillcn4150}
KUBECTL=${FLEET_CN_PROBE_KUBECTL:-kubectl}
NS=${FLEET_CN_PROBE_POD_NS:-fleet-workers}
MANIFEST=${FLEET_CN_PROBE_POD_MANIFEST:-}
WAIT=${FLEET_CN_PROBE_ENSURE_WAIT:-300}
GH=${FLEET_CN_PROBE_GH:-gh}
DRILL=${FLEET_CN_PROBE_DRILL_CMD:-bash $BIN/fleet-drill.sh}

sub=${1:-}; shift 2>/dev/null
case "$sub" in ensure|status) ;; -h|--help|'') sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
  *) echo "fleet-cn-probe-env: ensure|status" >&2; exit 2 ;; esac
repo='' stable='' dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --stable) stable=${2:-}; shift 2 ;;
    --dry-run|-n) dry=1; shift ;;
    *) echo "fleet-cn-probe-env: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ "$sub" = status ] && dry=1
case "$AS" in ''|*[!a-z0-9_.-]*) echo "fleet-cn-probe-env: the login is a login name" >&2; exit 2 ;; esac
case "$MACHINE" in ''|*[!A-Za-z0-9_.-]*) echo "fleet-cn-probe-env: the machine is a machine name" >&2; exit 2 ;; esac
case "$WAIT" in ''|*[!0-9]*) WAIT=300 ;; esac

RC=0
say() { printf 'ENSURE %s\n' "$*"; }
bad() { say "$*"; RC=1; }

SSHO=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10)
[ -n "$KEY" ] && SSHO+=(-i "$KEY")
[ -n "$KH" ] && SSHO+=(-o "UserKnownHostsFile=$KH")
as_root() { ssh "${SSHO[@]}" "$CLIENT" 'bash -s' 2>&1; }
as_login() { ssh "${SSHO[@]}" "$CLIENT" "su - $AS -s /bin/bash" 2>&1; }

# ---- client: the login and its fleet ----------------------------------------
client_part() {
  local out hub
  out=$(printf 'id -u %s >/dev/null 2>&1 && echo USER || echo NOUSER\nsu - %s -s /bin/bash -c "command -v fleet" 2>/dev/null\n' "$AS" "$AS" | as_root)
  case "$out" in
    *NOUSER*)
      [ "$dry" = 0 ] || { say "client fail $AS is not a login on $CLIENT (ensure would useradd it)"; RC=1; return; }
      printf 'useradd -m -s /bin/bash %s\n' "$AS" | as_root >/dev/null || { bad "client fail useradd $AS on $CLIENT"; return; } ;;
    *USER*/fleet*) say "client ok $AS has $(printf '%s\n' "$out" | grep /fleet | head -n 1)"; return ;;
    *USER*) ;;
    *) bad "client fail ssh $CLIENT: $(printf '%s' "$out" | tail -n 1)"; return ;;
  esac
  hub=$(bash "$BIN/fleet-hub-url.sh" 2>/dev/null)
  [ -n "$hub" ] || { bad "client fail no hub address here to install from"; return; }
  [ "$dry" = 0 ] || { say "client fail $AS has no fleet (ensure would run $hub/install)"; RC=1; return; }
  out=$(printf 'curl -fsSL %s/install | sh >/tmp/cnprobe-install.$$ 2>&1; rc=$?; tail -n 2 /tmp/cnprobe-install.$$; rm -f /tmp/cnprobe-install.$$; echo rc=$rc\n' "$hub" | as_login)
  case "$out" in *rc=0*) say "client made $AS on $CLIENT: fleet installed from $hub" ;;
    *) bad "client fail the install line: $(printf '%s\n' "$out" | tail -n 2 | tr '\n' ' ')" ;; esac
}

# ---- identity: a certificate the hub accepts, the pod listed ----------------
listed() {   # → 0 when the hub lists the machine for the login
  local out
  out=$(printf 'timeout 60 fleet connect --cert-check; timeout 60 fleet connect --pick %s\n' "$MACHINE" | as_login)
  case "$out" in PASS*"\"machine\": \"$MACHINE\""*|PASS*"\"hostname\": \"$MACHINE\""*) return 0 ;; esac
  LISTED_WHY=$(printf '%s\n' "$out" | grep -v '^Could not chdir' | tail -n 2 | tr '\t\n' '  ')
  return 1
}
identity_part() {
  local inv code ucode out i
  LISTED_WHY=''
  if listed; then say "identity ok $AS has a live certificate and the hub lists $MACHINE"; return; fi
  [ "$dry" = 0 ] || { say "identity fail $LISTED_WHY (ensure would re-make the drill person)"; RC=1; return; }
  inv=$($DRILL invite --login "$AS" --home "$MACHINE" --ttl 24h --json 2>&1) \
    || { bad "identity fail fleet drill invite: $(printf '%s' "$inv" | tail -n 1)"; return; }
  code=$(printf '%s' "$inv" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("approve_code",""))
except Exception: pass' 2>/dev/null)
  case "$code" in fd_*) ;; *) bad "identity fail the invite answered no approve code"; return ;; esac
  # `fleet login` on the client, in the background there; its 验证码 read back,
  # confirmed here as the drill person, then the login is waited for
  out=$(printf '%s\n' 'rm -f /tmp/cnprobe-login.out; (setsid fleet login </dev/null >/tmp/cnprobe-login.out 2>&1 &); for i in $(seq 1 40); do c=$(grep -Eo "[A-Z]{4}-[A-Z]{4}" /tmp/cnprobe-login.out | head -n 1); [ -n "$c" ] && { echo "CODE $c"; break; }; sleep 0.5; done' | as_login)
  ucode=$(printf '%s\n' "$out" | sed -n 's/^CODE //p' | head -n 1)
  [ -n "$ucode" ] || { bad "identity fail fleet login on the client printed no 验证码"; return; }
  FLEET_DRILL_INVITE=$code $DRILL approve "$ucode" >/dev/null 2>&1 \
    || { bad "identity fail fleet drill approve $ucode"; return; }
  code=''
  out=$(printf '%s\n' 'for i in $(seq 1 60); do pgrep -u "$(id -u)" -f "fleet-login" >/dev/null || break; sleep 1; done; tail -n 2 /tmp/cnprobe-login.out' | as_login)
  for i in $(seq 1 $((WAIT / 10))); do
    listed && { say "identity made a new drill person for $AS (24 h), signed in on $CLIENT, $MACHINE listed after $((i * 10))s"; return; }
    sleep 10
  done
  bad "identity fail signed in again, but the hub does not list $MACHINE for $AS after ${WAIT}s: $LISTED_WHY"
}

# ---- pod: stable's node image -----------------------------------------------
pod_part() {
  local want have ctrs c
  command -v "$KUBECTL" >/dev/null 2>&1 || { say "pod skip no $KUBECTL here"; return; }
  [ -n "$stable" ] && [ -n "$repo" ] || { say "pod skip no stable to follow (--repo / --stable)"; return; }
  want=$($GH api "repos/$repo/commits/$stable/statuses?per_page=100" \
           --jq '[.[] | select(.context == "node image" and .state == "success")][0].description // ""' 2>/dev/null)
  case "$want" in *@sha256:[0-9a-f]*) ;; *) say "pod skip stable ${stable:0:7} carries no node image status (a train before #4180) — left as it is"; return ;; esac
  have=$("$KUBECTL" -n "$NS" get deploy "$MACHINE" -o jsonpath='{range .spec.template.spec.initContainers[*]}{.name}={.image}{"\n"}{end}{range .spec.template.spec.containers[*]}{.name}={.image}{"\n"}{end}' 2>/dev/null)
  if [ -z "$have" ]; then
    if [ -z "$MANIFEST" ] || [ ! -r "$MANIFEST" ]; then bad "pod fail no Deployment $NS/$MACHINE and no FLEET_CN_PROBE_POD_MANIFEST to make it from"; return; fi
    [ "$dry" = 0 ] || { say "pod fail no Deployment $NS/$MACHINE (ensure would apply $MANIFEST with $want)"; RC=1; return; }
    sed -E "s#image: [^ ]*fleet-managed-node@sha256:[0-9a-f]+#image: $want#" "$MANIFEST" | "$KUBECTL" apply -f - >/dev/null 2>&1 \
      || { bad "pod fail kubectl apply $MANIFEST"; return; }
    "$KUBECTL" -n "$NS" rollout status "deploy/$MACHINE" --timeout=600s >/dev/null 2>&1 \
      && say "pod made $NS/$MACHINE from $MANIFEST on ${want##*@}" || bad "pod fail $MACHINE applied, not rolled out in 600s"
    return
  fi
  if ! printf '%s\n' "$have" | grep -v "=$want\$" | grep -q .; then say "pod ok $MACHINE runs stable ${stable:0:7}'s node image"; return; fi
  [ "$dry" = 0 ] || { say "pod fail $MACHINE runs $(printf '%s\n' "$have" | head -n 1 | sed 's/.*@//' | cut -c1-19), stable's is ${want##*@} (ensure would roll it)"; RC=1; return; }
  ctrs=''
  for c in $(printf '%s\n' "$have" | cut -d= -f1 | sort -u); do ctrs="$ctrs $c=$want"; done
  # shellcheck disable=SC2086
  "$KUBECTL" -n "$NS" set image "deploy/$MACHINE" $ctrs >/dev/null 2>&1 || { bad "pod fail kubectl set image $MACHINE"; return; }
  "$KUBECTL" -n "$NS" rollout status "deploy/$MACHINE" --timeout=600s >/dev/null 2>&1 \
    && say "pod rolled $MACHINE to stable ${stable:0:7}'s node image ${want##*@}" || bad "pod fail $MACHINE set to ${want##*@}, not rolled out in 600s"
}

pod_part
client_part
identity_part
exit "$RC"
