#!/bin/bash
# fleet-cn-probe.sh — walk `fleet connect` end to end from a client in China,
# and say 通 / 不通 + the layer it stopped at (issue #4150).
#
#   bin/fleet-cn-probe.sh [--client user@host] [--key FILE] [--known-hosts FILE]
#                         [--as LOGIN] [--machine NAME] [--routes "entry relay …"]
#
# Segment checks (the door port answers, the hub carries the fix) once said
# "fixed" three times while a person in China still could not get in. This is
# the person's road, run for real: the INSTALLED client on a China machine
# (default the Shenzhen drill box, oss-drill, reached from this computer — its
# security group lets only this machine's egress in), as a signed-in test
# login, against a cluster user pod, every route forced in turn, each a real
# ssh that must run a command on the pod. Layers, in order:
#
#   client   this computer → the client box (ssh)
#   install  the client's `fleet` is there
#   hub      the hub answers /version from the client
#   cert     `fleet connect --cert-check` — the hub accepts its certificate
#   list     `fleet connect --pick <machine>` — the hub lists the machine
#   table    `fleet connect <machine> --verbose --retest` — every route measured
#            (TCP + SSH banner handshakes), the table printed as is
#   auto     the route `fleet connect` picks by itself runs `hostname` on the pod
#   <route>  each route forced (`--route <name>`) runs `hostname` on the pod
#
# door     (only when the door refuses the key, and this computer has kubectl)
#          the door's allow list, read — is the login on it?
#
# Host key: a route whose ssh says the host key is unknown / changed is FAIL.
# Prints `PASS|FAIL|INFO <layer> <detail>` lines, then ONE verdict line:
#   通：自动选 <route>；<route> 通 · <route> 通 …
#   不通：卡在 <layer> — <detail>
# Exit 0 通 (auto and every forced route) · 1 不通 · 2 usage.
#
# Nothing is written on the pod; the client keeps its own connect cache (that
# is the person's state). No credential is printed or passed in an argv.
set -uo pipefail

CLIENT=${FLEET_CN_PROBE_CLIENT:-root@47.119.157.4}
KEY=${FLEET_CN_PROBE_KEY:-$HOME/fleet-secrets/oss-drill/id_oss_drill}
KH=${FLEET_CN_PROBE_KNOWN_HOSTS:-$HOME/fleet-secrets/oss-drill/known_hosts}
AS=${FLEET_CN_PROBE_LOGIN:-drillcn}
MACHINE=${FLEET_CN_PROBE_MACHINE:-u-drillcn4150}
ROUTES=${FLEET_CN_PROBE_ROUTES:-}
TMO=${FLEET_CN_PROBE_TIMEOUT:-90}
KUBECTL=${FLEET_CN_PROBE_KUBECTL:-kubectl}
DOOR_NS=${FLEET_CN_PROBE_DOOR_NS:-fleet-workers}

while [ $# -gt 0 ]; do
  case "$1" in
    --client) CLIENT=${2:-}; shift 2 ;;
    --key) KEY=${2:-}; shift 2 ;;
    --known-hosts) KH=${2:-}; shift 2 ;;
    --as) AS=${2:-}; shift 2 ;;
    --machine) MACHINE=${2:-}; shift 2 ;;
    --routes) ROUTES=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "fleet-cn-probe: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
case "$AS" in ''|*[!a-z0-9_.-]*) echo "fleet-cn-probe: --as is a login name" >&2; exit 2 ;; esac
case "$MACHINE" in ''|*[!A-Za-z0-9_.-]*) echo "fleet-cn-probe: --machine is a machine name" >&2; exit 2 ;; esac

STUCK='' DETAIL='' OKS=''
say() { printf '%s\n' "$*"; }
pass() { say "PASS $1 $2"; }
fail() { say "FAIL $1 $2"; [ -n "$STUCK" ] || { STUCK=$1; DETAIL=$2; }; }
verdict() {
  if [ -z "$STUCK" ]; then say "通：$OKS"; exit 0; fi
  say "不通：卡在 $STUCK — $DETAIL"; exit 1
}

SSHO=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10)
[ -n "$KEY" ] && SSHO+=(-i "$KEY")
[ -n "$KH" ] && SSHO+=(-o "UserKnownHostsFile=$KH")
# on_client <command…> — run as the test login on the client, a login shell so
# ~/.local/bin is on PATH; the script travels on stdin, never in an argv
on_client() {
  printf '%s\n' "$*" | ssh "${SSHO[@]}" "$CLIENT" "su - $AS -s /bin/bash" 2>&1
}

# client
if ! out=$(ssh "${SSHO[@]}" "$CLIENT" true 2>&1); then fail client "ssh $CLIENT: $(printf '%s' "$out" | tail -1)"; verdict; fi
pass client "$CLIENT"

# install
out=$(on_client 'command -v fleet && cat ~/.claude/fleet/.release 2>/dev/null | head -1; grep -h "^export FLEET_HUB_URL=" ~/.config/claude-fleet/fleet.conf')
case "$out" in */fleet*) pass install "$(printf '%s' "$out" | tr '\n' ' ')" ;; *) fail install "no fleet for $AS: $out"; verdict ;; esac
HUB=$(printf '%s\n' "$out" | sed -n 's/^export FLEET_HUB_URL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | tail -1)

# hub
out=$(on_client "curl -sS -m 20 -o /dev/null -w '%{http_code} %{time_total}s' ${HUB:-https://claudefleet.24haowan.com}/version")
case "$out" in 200*) pass hub "$HUB $out" ;; *) fail hub "$HUB $out"; verdict ;; esac

# cert
out=$(on_client "timeout $TMO fleet connect --cert-check")
case "$out" in PASS*) pass cert "$(printf '%s' "$out" | cut -f2-)" ;;
  *) fail cert "$(printf '%s' "$out" | tr '\t\n' '  ')"; verdict ;; esac

# list
out=$(on_client "timeout $TMO fleet connect --pick $MACHINE")
case "$out" in *"\"machine\": \"$MACHINE\""*|*"\"hostname\": \"$MACHINE\""*) pass list "the hub lists $MACHINE for $AS" ;;
  *) fail list "the hub does not list $MACHINE for $AS: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; verdict ;; esac

# table + auto: one run, measured afresh. A forced route PINS the machine
# (`--route` = `fleet route <machine> <route>`, remembered), so every run here
# starts from and leaves the person's choice at auto.
unpin() { on_client "fleet route $MACHINE auto" >/dev/null 2>&1; }
unpin
out=$(on_client "timeout $TMO fleet connect $MACHINE --verbose --retest -- hostname; echo rc=\$?")
say "INFO table"
printf '%s\n' "$out" | sed -n '/^fleet connect · /,/^→ /p' | sed 's/^/     /'
picked=$(printf '%s\n' "$out" | sed -n 's/^→ 选中 //p' | tail -1)
[ -n "$ROUTES" ] || ROUTES=$(printf '%s\n' "$out" | sed -n '/^fleet connect · /,/^→ /p' | sed -n '3,$p' | grep -v '^→' | cut -c3- | awk '{print $1}' | tr '\n' ' ')
hostkey() { printf '%s' "$1" | grep -E 'REMOTE HOST IDENTIFICATION|Host key verification failed|主机钥匙' | head -1; }
if printf '%s\n' "$out" | grep -q '^rc=0$' && printf '%s\n' "$out" | grep -q "^$MACHINE"; then
  hk=$(hostkey "$out"); if [ -n "$hk" ]; then fail auto "host key: $hk"; else pass auto "picked ${picked:-?}"; OKS="自动选 ${picked:-?}"; fi
else
  fail auto "picked ${picked:-none}: $(printf '%s\n' "$out" | grep -v '^ \|^fleet connect · \|^→' | tail -3 | tr '\n' ' ')"
fi

# door_why — the door refused the key: read (never write) what the door was
# told, when this computer holds the cluster. A login missing from its allow
# list is the hub's door list (the person's entry home is not on the pod).
door_why() {
  command -v "$KUBECTL" >/dev/null 2>&1 || return 0
  local p st
  p=$("$KUBECTL" -n "$DOOR_NS" get pod -l app.kubernetes.io/name=fleet-door -o name 2>/dev/null | head -1)
  [ -n "$p" ] || return 0
  st=$("$KUBECTL" -n "$DOOR_NS" exec "$p" -- cat /var/db/fleet-node/entry/state.json 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(d.get("allow") or []), d.get("version"))' 2>/dev/null)
  case " ${st% *} " in
    *" $AS "*) say "INFO door $AS is on the door's list (v${st##* }) — the key it offered is not one the hub gave the door" ;;
    *) say "INFO door $AS is NOT on the door's list (v${st##* }: ${st% *}) — the hub routes only a person whose entry home is a user pod" ;;
  esac
}

# every route, forced
for r in $ROUTES; do
  case "$r" in *[!A-Za-z0-9_.:-]*) continue ;; esac
  out=$(on_client "timeout $TMO fleet connect $MACHINE --route $r -- hostname; echo rc=\$?")
  unpin
  hk=$(hostkey "$out")
  if printf '%s\n' "$out" | grep -q "^$MACHINE" && printf '%s\n' "$out" | grep -q '^rc=0$' && [ -z "$hk" ]; then
    pass "$r" "ran hostname on $(printf '%s\n' "$out" | grep "^$MACHINE" | head -1)"; OKS="$OKS；$r 通"
  else
    fail "$r" "${hk:-$(printf '%s\n' "$out" | grep -v '^rc=' | tail -3 | tr '\n' ' ')}"
    case "$r:$out" in entry:*'Permission denied (publickey)'*) door_why ;; esac
  fi
done
verdict
